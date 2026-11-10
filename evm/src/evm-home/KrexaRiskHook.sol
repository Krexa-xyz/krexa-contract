// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHook} from "./interfaces/IERC7579Modules.sol";
import {ExecDecoder} from "./lib/ExecDecoder.sol";
import {OracleLib} from "./lib/OracleLib.sol";
import {SwapDecoder} from "./lib/SwapDecoder.sol";

interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}

/// @title KrexaRiskHook
/// @author Krexa
/// @notice UNAUDITED - do not deploy to mainnet with user funds before an external audit.
///
/// @notice ERC-7579 hook (module type 4) for a Kernel v3.3 account. It guards the Krexa SESSION permission and
/// is where ALL stateful and time/price dependent limits live. {KrexaSwapPolicy} is static (allowlists, recipient
/// proof, expiry through validationData) so it stays valid on public ERC-7562 bundlers; this hook runs in the
/// execution phase, where TIMESTAMP, Chainlink reads and mutable counters are allowed. Install BOTH on the session
/// permission: the policy alone has no spend caps, no rate limit, no oracle and no slippage proof.
///  0. per-op limits (same calldata the policy checked, decoded again with {ExecDecoder} and {SwapDecoder}):
///     per-trade USDC cap (sum of all buy inputs in the UserOp), rolling 24h USDC cap (25 hourly buckets, see BUCKETS),
///     ops per UTC hour, fresh Chainlink price for the bought token, and the slippage / minOut proof
///     (`maxSlippageBps`, always on and mandatory for opaque 0x Settler swaps). Sells are never capped or counted for spend.
///  1. daily loss: NAV (USDC + allowlisted tokens x Chainlink) is snapshotted at the first valuation after
///     00:00 UTC; once `startNav - nav >= maxDailyLossUsdc` BUYS are denied and SELLS stay allowed;
///  2. stale oracle: if any held token cannot be priced (stale, zero, missing feed) BUYS are denied; a swap of the
///     unpriced token itself is denied too (no price, no minOut check); the owner path still exits;
///  3. owner pause: while paused every session op reverts; only the account itself can pause/unpause.
///
/// "Buy" detection is balance based, not calldata based: in a blocked state the op must not decrease the
/// account's USDC balance and must not increase the balance of any allowlisted token (checked in `postCheck`).
/// That also catches a buy hidden inside a batch next to a sell.
///
/// Withdrawals: NAV is an equity measure, so money the owner withdrew after the day's snapshot lowers NAV and
/// counts toward the loss, exactly like the off-chain engine ("money withdrawn that day counts toward it").
/// There is no separate `withdrawnToday` counter, because adding one would count the same dollars twice. The
/// hook cannot see owner-path withdrawals directly (see "Owner vs session" below); it sees their effect on NAV.
/// Deposits raise NAV and so offset earlier losses the same way (same as the off-chain engine).
///
/// Owner vs session (read this before wiring it up). Source: ZeroDev Kernel v3.3
/// `src/Kernel.sol` (`validateUserOp`, `executeUserOp`) and `src/core/HookManager.sol`:
///  - A hook is stored per validation id, `validationConfig[vId].hook` (`ValidationManager.sol`). In
///    `executeUserOp` Kernel loads `executionHook[userOpHash]` and calls `hook.preCheck(msg.sender, value,
///    userOp.callData[4:])` and `hook.postCheck(context)` ONLY when that validation's hook is not address(1).
///  - `msg.sender` seen by `preCheck` is therefore ALWAYS the EntryPoint, for owner and session ops alike,
///    and the calldata carries no validator id. A hook cannot tell the two apart by inspecting arguments.
///  - So the split is structural: install this hook on the SESSION permission only
///    (`ValidationConfig.hook = KrexaRiskHook`) and never on the root (owner) validator. Owner UserOps run
///    through the root validator with no hook, so `pause`, `unpause`, `setConfig` and withdrawals always work.
///    Inside hooks `msg.sender` is the Kernel account, so state is keyed by `msg.sender`.
///  - Session ops cannot call `pause/unpause/setConfig`: the account calls them with `msg.sender == account`, so
///    the barrier is that a session UserOp may not target this hook. Both {KrexaSwapPolicy} (target allowlist
///    + explicit hook deny) and `preCheck` here (any call to this hook or to the account itself reverts) enforce it.
///  - If the hook is ever uninstalled while the permission still points at it, `preCheck` reverts (not
///    initialised): fail closed.
///
/// Oracle reads happen in the execution phase, so ERC-7562 validation rules do not apply to this hook.
contract KrexaRiskHook is IHook {
    // ------------------------------------------------------------------ config ABI
    struct TokenFeed {
        address token;
        address feed; // Chainlink token/USD
        uint8 decimals; // must equal token.decimals(), checked at install
    }

    /// @dev `onInstall` data (after Kernel strips its flag byte) = `abi.encode(HookConfig)`
    struct HookConfig {
        uint128 maxDailyLossUsdc; // 6 decimals, must be > 0
        uint128 perTradeCapUsdc; // 6 decimals, sum of buy inputs per UserOp, must be > 0
        uint128 dailyCapUsdc; // 6 decimals, rolling 24h, must be >= perTradeCapUsdc
        uint32 maxOpsPerHour; // per UTC hour, must be > 0
        uint32 maxOracleAge; // seconds, must be > 0
        uint16 maxSlippageBps; // 1..10000; 0 is rejected (a zero would switch the minOut proof off)
        address usdc; // decimals() must be 6, valued 1:1; must be the same token as the policy's usdc
        TokenFeed[] tokens; // non-USDC tokens the key may trade (no duplicates); counted in NAV; the hook's own token allowlist
    }

    struct State {
        bool installed;
        bool paused;
        uint16 maxSlippageBps;
        uint32 maxOracleAge;
        uint32 maxOpsPerHour;
        uint32 snapDay; // unix day of the NAV snapshot
        uint128 maxDailyLossUsdc;
        uint128 startNav; // NAV at the day's first valuation
        uint128 perTradeCapUsdc;
        uint128 dailyCapUsdc;
        address usdc;
    }

    struct Ops {
        uint40 hour; // unix hour of the counter
        uint32 count;
    }

    uint256 private constant MAX_TOKENS = 16;
    /// @dev 25 hourly buckets: a buy in hour h is counted through hour h+24 (inclusive), so even a buy made in the last
    /// second of hour h is counted for a full 24h. The cost is that a buy stays counted for up to 25h (never looser).
    uint256 private constant BUCKETS = 25;

    mapping(address wallet => State) internal _s;
    mapping(address wallet => TokenFeed[]) internal _tokens;
    mapping(address wallet => Ops) internal _ops;
    /// @dev ring of 25 hourly buckets, slot = hour % 25, value = hour << 128 | amount
    mapping(address wallet => uint256[BUCKETS]) internal _buckets;

    event Paused(address indexed wallet);
    event Unpaused(address indexed wallet);
    event NavSnapshot(address indexed wallet, uint32 indexed day, uint256 nav);
    event HookConfigured(address indexed wallet);

    error HookPaused();
    error ValueNotAllowed(uint256 value);
    error TargetForbidden(address target);
    error BuysBlocked();
    error InvalidConfig(string why);
    error ZeroAmount();
    error PairNotAllowed(address tokenIn, address tokenOut);
    error TokenNotAllowed(address token);
    error PerTradeCapExceeded(uint256 requested, uint256 cap);
    error DailyCapExceeded(uint256 requested, uint256 remaining);
    error OpsPerHourExceeded(uint32 max);
    error StaleOracle(address feed);
    error MinOutTooLow(uint256 fairUsdc, uint256 minOutUsdc);

    // ------------------------------------------------------------------ IModule
    function onInstall(bytes calldata data) external payable override {
        if (_s[msg.sender].installed) revert AlreadyInitialized(msg.sender);
        _apply(msg.sender, abi.decode(data, (HookConfig)), false, 0, 0);
    }

    function onUninstall(bytes calldata) external payable override {
        if (!_s[msg.sender].installed) revert NotInitialized(msg.sender);
        delete _s[msg.sender];
        delete _tokens[msg.sender];
        delete _ops[msg.sender];
        delete _buckets[msg.sender];
    }

    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == 4;
    }

    function isInitialized(address smartAccount) external view override returns (bool) {
        return _s[smartAccount].installed;
    }

    // ------------------------------------------------------------------ owner path (msg.sender == account)
    /// @notice Block every session op. Callable only by the account itself (owner path).
    function pause() external {
        State storage s = _s[msg.sender];
        if (!s.installed) revert NotInitialized(msg.sender);
        s.paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Re-enable session ops. Callable only by the account itself; a session UserOp cannot target this hook.
    function unpause() external {
        State storage s = _s[msg.sender];
        if (!s.installed) revert NotInitialized(msg.sender);
        s.paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Replace limits and token list. Keeps the pause flag and the day's NAV snapshot.
    function setConfig(HookConfig calldata cfg) external {
        State memory s = _s[msg.sender];
        if (!s.installed) revert NotInitialized(msg.sender);
        _apply(msg.sender, cfg, s.paused, s.snapDay, s.startNav);
    }

    // ------------------------------------------------------------------ IHook
    /// @inheritdoc IHook
    /// @dev `msg.sender` = the Kernel account. The first argument (EntryPoint) is ignored: see "Owner vs session".
    /// Returns `abi.encode(bool blockBuys, uint256[] balancesBefore)`; balances[0] = USDC, [i+1] = tokens[i].
    function preCheck(address, uint256 msgValue, bytes calldata msgData)
        external
        payable
        override
        returns (bytes memory hookData)
    {
        address wallet = msg.sender;
        State memory s = _s[wallet];
        if (!s.installed) revert NotInitialized(wallet);
        if (s.paused) revert HookPaused();
        if (msgValue != 0) revert ValueNotAllowed(msgValue);

        uint256 buyTotal = _checkCalls(wallet, s, ExecDecoder.decode(msgData));
        _countOp(wallet, s.maxOpsPerHour);
        if (buyTotal != 0) {
            if (buyTotal > s.perTradeCapUsdc) revert PerTradeCapExceeded(buyTotal, s.perTradeCapUsdc);
            _spend(wallet, buyTotal, s.dailyCapUsdc);
        }
        return _navGate(wallet, s);
    }

    /// @inheritdoc IHook
    function postCheck(bytes calldata hookData) external payable override {
        (bool blockBuys, uint256[] memory before) = abi.decode(hookData, (bool, uint256[]));
        if (!blockBuys) return;
        State memory s = _s[msg.sender];
        if (!s.installed) revert NotInitialized(msg.sender);
        if (IERC20Balance(s.usdc).balanceOf(msg.sender) < before[0]) revert BuysBlocked();
        TokenFeed[] storage toks = _tokens[msg.sender];
        for (uint256 i; i < toks.length; ++i) {
            if (IERC20Balance(toks[i].token).balanceOf(msg.sender) > before[i + 1]) revert BuysBlocked();
        }
    }

    // ------------------------------------------------------------------ views
    function getState(address wallet) external view returns (State memory) {
        return _s[wallet];
    }

    function getTokens(address wallet) external view returns (TokenFeed[] memory) {
        return _tokens[wallet];
    }

    /// @notice What `preCheck` would decide right now (without writing the snapshot).
    /// @return blockBuys true when buys are denied (stale oracle or loss limit reached)
    /// @return fresh false when some held token could not be priced
    /// @return nav current NAV in USDC base units (partial if `fresh` is false)
    /// @return startNav the NAV the loss is measured against (current NAV when a new day has not been snapshotted)
    /// @return loss `startNav - nav`, floored at 0
    function riskState(address wallet)
        external
        view
        returns (bool blockBuys, bool fresh, uint256 nav, uint256 startNav, uint256 loss)
    {
        State memory s = _s[wallet];
        (fresh, nav,) = _valuate(wallet, s);
        startNav = s.snapDay == uint32(block.timestamp / 1 days) ? s.startNav : nav;
        loss = startNav > nav ? startNav - nav : 0;
        blockBuys = !fresh || (s.maxDailyLossUsdc != 0 && loss >= s.maxDailyLossUsdc);
    }

    /// @notice USDC spent on buys inside the rolling window: a bucket of hour h counts while the current hour is <= h+24,
    /// so every buy is counted for at least 24h (and up to 25h).
    function spentInWindow(address wallet) public view returns (uint256 total) {
        uint256 h = block.timestamp / 1 hours;
        uint256[BUCKETS] storage b = _buckets[wallet];
        for (uint256 i; i < BUCKETS; ++i) {
            uint256 v = b[i];
            if (v != 0 && (v >> 128) + BUCKETS > h) total += uint128(v);
        }
    }

    function remainingDaily(address wallet) external view returns (uint256) {
        uint256 spent = spentInWindow(wallet);
        uint256 cap = _s[wallet].dailyCapUsdc;
        return spent >= cap ? 0 : cap - spent;
    }

    /// @notice ops counted in the current UTC hour
    function opsThisHour(address wallet) external view returns (uint32) {
        Ops memory o = _ops[wallet];
        return o.hour == uint40(block.timestamp / 1 hours) ? o.count : 0;
    }

    // ------------------------------------------------------------------ internals
    /// @dev returns the sum of all USDC buy inputs in the UserOp
    function _checkCalls(address wallet, State memory s, ExecDecoder.Call[] memory calls)
        private
        view
        returns (uint256 buyTotal)
    {
        for (uint256 i; i < calls.length; ++i) {
            ExecDecoder.Call memory k = calls[i];
            if (k.value != 0) revert ValueNotAllowed(k.value);
            if (k.target == address(this) || k.target == wallet) revert TargetForbidden(k.target);
            if (k.data.length < 4) continue;
            bytes4 sel = bytes4(k.data);
            if (!SwapDecoder.isSwapSelector(sel)) continue; // approvals etc. are the policy's business
            SwapDecoder.Swap[] memory swaps = SwapDecoder.decodeSwaps(wallet, sel, k.data);
            for (uint256 j; j < swaps.length; ++j) {
                buyTotal += _checkSwap(wallet, s, swaps[j]);
            }
        }
    }

    /// @dev returns the USDC amount spent when the swap is a buy, 0 for a sell
    function _checkSwap(address wallet, State memory s, SwapDecoder.Swap memory sw) private view returns (uint256) {
        if (sw.amountIn == 0) revert ZeroAmount();
        bool buy = sw.tokenIn == s.usdc;
        if (buy == (sw.tokenOut == s.usdc)) revert PairNotAllowed(sw.tokenIn, sw.tokenOut);
        address token = buy ? sw.tokenOut : sw.tokenIn;
        TokenFeed memory tf = _find(wallet, token);
        if (tf.token == address(0)) revert TokenNotAllowed(token);

        // every swap needs a fresh price. A stale-price sell used to pass with no minOut check, so the session key
        // could dump a position for dust through a pool it made; the owner path still exits with no price at all
        (bool ok, uint256 answer, uint8 fd) = OracleLib.read(tf.feed, s.maxOracleAge);
        if (!ok) revert StaleOracle(tf.feed);
        uint256 fair = buy ? sw.amountIn : OracleLib.toUsdc(sw.amountIn, tf.decimals, answer, fd);
        uint256 got = buy ? OracleLib.toUsdc(sw.minOut, tf.decimals, answer, fd) : sw.minOut;
        if (got * 10_000 < fair * (10_000 - s.maxSlippageBps)) revert MinOutTooLow(fair, got);
        return buy ? sw.amountIn : 0;
    }

    function _find(address wallet, address token) private view returns (TokenFeed memory tf) {
        TokenFeed[] storage toks = _tokens[wallet];
        for (uint256 i; i < toks.length; ++i) {
            if (toks[i].token == token) return toks[i];
        }
    }

    function _countOp(address wallet, uint32 max) private {
        uint40 h = uint40(block.timestamp / 1 hours);
        Ops memory o = _ops[wallet];
        if (o.hour != h) o = Ops(h, 0);
        if (o.count >= max) revert OpsPerHourExceeded(max);
        o.count++;
        _ops[wallet] = o;
    }

    function _spend(address wallet, uint256 amount, uint256 cap) private {
        uint256 spent = spentInWindow(wallet);
        if (spent + amount > cap) revert DailyCapExceeded(amount, cap > spent ? cap - spent : 0);
        uint256 h = block.timestamp / 1 hours;
        uint256[BUCKETS] storage b = _buckets[wallet];
        uint256 slot = h % BUCKETS;
        uint256 v = b[slot];
        // a bucket in this slot from the same hour accumulates; an older one is already outside the window
        uint256 prev = (v != 0 && (v >> 128) == h) ? uint128(v) : 0;
        b[slot] = (h << 128) | (prev + amount);
    }

    /// @dev daily-loss / stale-oracle gate; writes the NAV snapshot on the first fresh valuation of a UTC day
    function _navGate(address wallet, State memory s) private returns (bytes memory hookData) {
        (bool fresh, uint256 nav, uint256[] memory bals) = _valuate(wallet, s);
        bool blockBuys = !fresh;
        if (fresh) {
            uint32 day = uint32(block.timestamp / 1 days);
            if (s.snapDay != day) {
                _s[wallet].snapDay = day;
                _s[wallet].startNav = uint128(nav);
                emit NavSnapshot(wallet, day, nav);
            } else if (s.startNav > nav && s.startNav - nav >= s.maxDailyLossUsdc) {
                blockBuys = true;
            }
        }
        hookData = blockBuys ? abi.encode(true, bals) : abi.encode(false, new uint256[](0));
    }

    function _valuate(address wallet, State memory s)
        private
        view
        returns (bool fresh, uint256 nav, uint256[] memory bals)
    {
        TokenFeed[] storage toks = _tokens[wallet];
        bals = new uint256[](toks.length + 1);
        bals[0] = IERC20Balance(s.usdc).balanceOf(wallet);
        nav = bals[0];
        fresh = true;
        for (uint256 i; i < toks.length; ++i) {
            TokenFeed memory t = toks[i];
            uint256 bal = IERC20Balance(t.token).balanceOf(wallet);
            bals[i + 1] = bal;
            if (bal == 0) continue;
            (bool ok, uint256 answer, uint8 fd) = OracleLib.read(t.feed, s.maxOracleAge);
            if (!ok) {
                fresh = false;
                continue;
            }
            nav += OracleLib.toUsdc(bal, t.decimals, answer, fd);
        }
    }

    /// @dev token.decimals(), or 256 when the call fails or returns something that is not one uint8 word
    function _decimalsOf(address token) private view returns (uint256) {
        (bool ok, bytes memory r) = token.staticcall(abi.encodeWithSelector(0x313ce567));
        if (!ok || r.length != 32) return 256;
        return abi.decode(r, (uint256));
    }

    function _apply(address wallet, HookConfig memory c, bool paused, uint32 snapDay, uint128 startNav) private {
        if (c.usdc == address(0)) revert InvalidConfig("usdc");
        if (c.maxDailyLossUsdc == 0) revert InvalidConfig("maxDailyLossUsdc");
        if (c.maxOracleAge == 0) revert InvalidConfig("maxOracleAge");
        if (c.maxOpsPerHour == 0) revert InvalidConfig("maxOpsPerHour");
        if (c.maxSlippageBps == 0 || c.maxSlippageBps > 10_000) revert InvalidConfig("maxSlippageBps");
        if (c.perTradeCapUsdc == 0 || c.dailyCapUsdc < c.perTradeCapUsdc) revert InvalidConfig("caps");
        if (c.tokens.length > MAX_TOKENS) revert InvalidConfig("tokens");
        if (_decimalsOf(c.usdc) != 6) revert InvalidConfig("usdc decimals");
        delete _tokens[wallet];
        for (uint256 i; i < c.tokens.length; ++i) {
            TokenFeed memory t = c.tokens[i];
            if (t.token == address(0) || t.token == c.usdc || t.feed == address(0) || t.decimals > 36) {
                revert InvalidConfig("token");
            }
            // install is the execution phase: external reads are fine here. A wrong decimals value would misprice NAV.
            if (_decimalsOf(t.token) != t.decimals) revert InvalidConfig("token decimals");
            for (uint256 j; j < i; ++j) {
                if (c.tokens[j].token == t.token) revert InvalidConfig("duplicate token");
            }
            _tokens[wallet].push(t);
        }
        _s[wallet] = State({
            installed: true,
            paused: paused,
            maxSlippageBps: c.maxSlippageBps,
            maxOracleAge: c.maxOracleAge,
            maxOpsPerHour: c.maxOpsPerHour,
            snapDay: snapDay,
            maxDailyLossUsdc: c.maxDailyLossUsdc,
            startNav: startNav,
            perTradeCapUsdc: c.perTradeCapUsdc,
            dailyCapUsdc: c.dailyCapUsdc,
            usdc: c.usdc
        });
        emit HookConfigured(wallet);
    }
}
