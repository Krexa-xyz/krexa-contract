// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPolicy} from "./interfaces/IERC7579Modules.sol";
import {PackedUserOperation} from "./interfaces/PackedUserOperation.sol";
import {ExecDecoder} from "./lib/ExecDecoder.sol";
import {SwapDecoder} from "./lib/SwapDecoder.sol";

/// @title KrexaSwapPolicy
/// @author Krexa
/// @notice UNAUDITED - do not deploy to mainnet with user funds before an external audit.
///
/// @notice ZeroDev Kernel v3.3 permission policy (module type 5) that confines a Krexa session key to
/// swapping USDC <-> allowlisted tokens through allowlisted routers, with the proceeds going back to the
/// smart account. Installed once per (wallet, permissionId); every check is keyed by `msg.sender` = the
/// Kernel account, because Kernel calls policies from the account (`ValidationManager._checkUserOpPolicy`,
/// ZeroDev Kernel v3.3 src/core/ValidationManager.sol).
///
/// STATIC ONLY. This policy runs in the ERC-4337 validation phase, so it is deliberately a pure function of
/// (UserOp calldata, the account's own config). It has no counters, no clock, no oracle and no external calls,
/// which keeps it valid on public ERC-7562 bundlers. Everything that needs time, price or mutable state (per-trade
/// cap, rolling 24h cap, ops/hour, slippage proof, daily loss, pause) lives in {KrexaRiskHook}, which runs in the
/// execution phase on the same calldata. Install both on the session permission.
///
/// Gas: the policy also bounds what a session UserOp can make the account pay. Self-paid ops (empty
/// `paymasterAndData`) need `(preVerificationGas + verificationGasLimit + callGasLimit) * maxFeePerGas <= maxOpWei`;
/// sponsored ops need the paymaster in the config's `paymasters`. Both are pure functions of the UserOp.
///
/// What a session UserOp may do (everything else reverts = denied):
///  - `execute(mode, calls)` in single or batch mode, default exec type only, native value always 0;
///  - ERC-20 `approve(spender, amount)` on an allowlisted token, spender in the spender allowlist;
///  - Permit2 `approve(token, spender, amount, expiry)` when Permit2 is an allowlisted target, token and
///    spender allowlisted;
///  - exact-input swaps (see {SwapDecoder}) on an allowlisted (router, selector), tokenIn/tokenOut allowlisted,
///    exactly one of them USDC, output recipient proven to be the account, amountIn > 0.
///  Targets equal to the account itself, this policy, or the configured hook are always denied (that is what
///  stops a session key calling `installModule`, `setConfig`, `unpause`, ...). `transfer`, `transferFrom` and
///  any selector not listed above have no code path to be allowed.
///
/// Expiry: `validUntil` is returned in `validationData` (`validUntil << 160`, validAfter 0, authorizer 0). The
/// EntryPoint enforces it; the policy never reads the clock.
///
/// Config updates: only the account itself can call {setConfig} (`msg.sender` = wallet). A session UserOp can
/// never reach it because a call whose target is this policy is denied above.
///
/// ---- ERC-7562 footprint of `checkUserOpPolicy` (enforced by test/evm-home/Erc7562.t.sol) ----
/// Opcodes used on the validation path: SLOAD, KECCAK256, CALLER, ADDRESS, CALLDATALOAD/CALLDATACOPY/CALLDATASIZE,
/// MLOAD/MSTORE/MCOPY, arithmetic/comparison/bit ops, JUMP*, REVERT/RETURN/STOP. The whole runtime code (not just
/// the validation path) contains NONE of: TIMESTAMP, NUMBER, BLOCKHASH, COINBASE, PREVRANDAO, GASLIMIT, GASPRICE,
/// BASEFEE, BLOBHASH, BLOBBASEFEE, ORIGIN, BALANCE, SELFBALANCE, GAS, CREATE, CREATE2, SELFDESTRUCT, EXTCODE*,
/// CALL, CALLCODE, DELEGATECALL, STATICCALL. SSTORE and LOG exist only in onInstall / onUninstall / setConfig
/// (execution phase); `checkUserOpPolicy` records zero writes.
/// Storage read: only this contract's slots of the form keccak256(pad32(wallet) . X) + n (n <= 1), i.e. slots
/// associated with the UserOp sender: `_cfg[id][wallet]` (3 words), `_gen[id][wallet]`, and `_allow[key][wallet]`
/// for the (target, selector), token, spender and paymaster keys of the calls being checked. The wallet is always the
/// innermost mapping key. No other contract is touched and nothing is written.
contract KrexaSwapPolicy is IPolicy {
    // ------------------------------------------------------------------ config ABI
    struct TargetCfg {
        address target;
        bytes4[] selectors;
    }

    /// @dev `onInstall` data = `bytes32 permissionId ++ abi.encode(PolicyConfig)`
    struct PolicyConfig {
        uint48 validUntil; // unix seconds, non-zero; returned to the EntryPoint in validationData
        address usdc; // the quote token
        address hook; // KrexaRiskHook (always denied as a target); address(0) if none
        address[] spenders; // approve spenders: routers, Permit2, AllowanceHolder
        TargetCfg[] targets; // routers / Permit2 / Settler with the selectors allowed on each
        address[] tokens; // non-USDC tokens the key may hold or trade
        // ---- appended fields (ABI order matters: new fields only ever go at the end)
        uint128 maxOpWei; // max prefund of one UserOp paid from the account's ETH (wei); 0 only with paymasters
        address[] paymasters; // paymasters a session UserOp may name; empty = self-paid UserOps only
    }

    // ------------------------------------------------------------------ storage
    struct Cfg {
        bool installed;
        uint48 validUntil;
        address usdc;
        address hook;
        uint128 maxOpWei;
    }

    uint8 private constant K_TARGET = 1;
    uint8 private constant K_SPENDER = 2;
    uint8 private constant K_TOKEN = 3;
    uint8 private constant K_PAYMASTER = 4;
    uint256 private constant MAX_LIST = 32;

    // The wallet is always the innermost mapping key (ERC-7562 associated storage).
    mapping(bytes32 id => mapping(address wallet => Cfg)) internal _cfg;
    mapping(bytes32 id => mapping(address wallet => uint32)) internal _gen;
    mapping(bytes32 key => mapping(address wallet => bool)) internal _allow;
    mapping(address wallet => uint256) internal _installedCount;

    // ------------------------------------------------------------------ events / errors
    event PolicyConfigured(address indexed wallet, bytes32 indexed id, uint32 generation);
    event PolicyRemoved(address indexed wallet, bytes32 indexed id);

    error OnlyInstalledWallet(address caller);
    error BadSender();
    error EmptyExecution();
    error ValueNotAllowed(uint256 value);
    error TargetForbidden(address target);
    error NotAllowed(address target, bytes4 selector);
    error TokenNotAllowed(address token);
    error SpenderNotAllowed(address spender);
    error BadCalldata();
    error ZeroAmount();
    error PairNotAllowed(address tokenIn, address tokenOut);
    error PrefundTooHigh(uint256 prefund, uint256 max);
    error PaymasterNotAllowed(address paymaster);
    error InvalidConfig(string why);

    // ------------------------------------------------------------------ IModule
    /// @notice Kernel calls this with `bytes32 permissionId ++ abi.encode(PolicyConfig)` when the permission is installed.
    function onInstall(bytes calldata data) external payable override {
        bytes32 id = bytes32(data[0:32]);
        if (_cfg[id][msg.sender].installed) revert AlreadyInitialized(msg.sender);
        _installedCount[msg.sender]++;
        _apply(id, msg.sender, abi.decode(data[32:], (PolicyConfig)));
    }

    /// @notice Kernel calls this with `bytes32 permissionId ++ ...` when the permission is uninstalled.
    function onUninstall(bytes calldata data) external payable override {
        bytes32 id = bytes32(data[0:32]);
        if (!_cfg[id][msg.sender].installed) revert NotInitialized(msg.sender);
        delete _cfg[id][msg.sender];
        _gen[id][msg.sender]++; // orphans every allowlist entry: a reinstall starts empty
        _installedCount[msg.sender]--;
        emit PolicyRemoved(msg.sender, id);
    }

    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == 5;
    }

    function isInitialized(address smartAccount) external view override returns (bool) {
        return _installedCount[smartAccount] > 0;
    }

    /// @notice Replace the config of an installed permission. Callable only by the account itself (owner
    /// path); allowlists are rebuilt from scratch.
    function setConfig(bytes32 id, PolicyConfig calldata cfg) external {
        if (!_cfg[id][msg.sender].installed) revert OnlyInstalledWallet(msg.sender);
        _gen[id][msg.sender]++;
        _apply(id, msg.sender, cfg);
    }

    // ------------------------------------------------------------------ IPolicy
    /// @notice Called by the Kernel account during UserOp validation. Reverts to deny. Reads only storage
    /// associated with `msg.sender`; writes nothing; reads no block data.
    /// @return validationData `validUntil << 160` (authorizer 0 = valid) for the EntryPoint to enforce.
    function checkUserOpPolicy(bytes32 id, PackedUserOperation calldata userOp)
        external
        payable
        override
        returns (uint256)
    {
        address wallet = msg.sender;
        Cfg memory c = _cfg[id][wallet];
        if (!c.installed) revert NotInitialized(wallet);
        if (userOp.sender != wallet) revert BadSender();

        _checkGas(id, c, wallet, userOp);

        ExecDecoder.Call[] memory calls = ExecDecoder.decode(userOp.callData);
        if (calls.length == 0) revert EmptyExecution();
        uint32 gen = _gen[id][wallet];
        for (uint256 i; i < calls.length; ++i) {
            _checkCall(id, gen, wallet, c, calls[i]);
        }
        return uint256(c.validUntil) << 160;
    }

    /// @notice ERC-1271 signatures by the session key are never allowed (they could sign Permit2 orders or
    /// arbitrary hashes). Returns SIG_VALIDATION_FAILED; Kernel turns a non-zero authorizer into `PolicyFailed`.
    function checkSignaturePolicy(bytes32, address, bytes32, bytes calldata) external pure override returns (uint256) {
        return 1;
    }

    // ------------------------------------------------------------------ views
    function getConfig(bytes32 id, address wallet) external view returns (Cfg memory) {
        return _cfg[id][wallet];
    }

    function isTargetAllowed(bytes32 id, address wallet, address target, bytes4 selector) external view returns (bool) {
        return _allow[_key(K_TARGET, id, _gen[id][wallet], target, selector)][wallet];
    }

    function isSpenderAllowed(bytes32 id, address wallet, address spender) external view returns (bool) {
        return _allow[_key(K_SPENDER, id, _gen[id][wallet], spender, bytes4(0))][wallet];
    }

    function isTokenAllowed(bytes32 id, address wallet, address token) external view returns (bool) {
        return _tokenAllowed(id, _gen[id][wallet], wallet, token);
    }

    // ------------------------------------------------------------------ gas / paymaster checks
    /// @dev Kernel pays `missingAccountFunds` from the account's ETH, so a key that controls the gas fields could
    /// drain it. Self-paid: the worst-case prefund must be <= `maxOpWei`. Sponsored: the paymaster must be allowlisted.
    function _checkGas(bytes32 id, Cfg memory c, address wallet, PackedUserOperation calldata op) private view {
        bytes calldata pm = op.paymasterAndData;
        if (pm.length == 0) {
            // accountGasLimits = verificationGasLimit(16) ++ callGasLimit(16); gasFees = maxPriorityFee(16) ++ maxFee(16)
            uint256 gas = op.preVerificationGas + uint128(uint256(op.accountGasLimits) >> 128)
                + uint128(uint256(op.accountGasLimits));
            uint256 prefund = gas * uint128(uint256(op.gasFees)); // checked math: an overflow reverts = deny
            if (prefund > c.maxOpWei) revert PrefundTooHigh(prefund, c.maxOpWei);
            return;
        }
        // paymasterAndData = paymaster(20) ++ paymasterVerificationGasLimit(16) ++ paymasterPostOpGasLimit(16) ++ data
        if (pm.length < 52) revert BadCalldata();
        address paymaster = address(bytes20(pm[:20]));
        if (!_allow[_key(K_PAYMASTER, id, _gen[id][wallet], paymaster, bytes4(0))][wallet]) {
            revert PaymasterNotAllowed(paymaster);
        }
    }

    // ------------------------------------------------------------------ call checks
    function _checkCall(bytes32 id, uint32 gen, address wallet, Cfg memory c, ExecDecoder.Call memory k) private view {
        if (k.value != 0) revert ValueNotAllowed(k.value);
        address t = k.target;
        if (t == wallet || t == address(this) || (c.hook != address(0) && t == c.hook)) revert TargetForbidden(t);
        if (k.data.length < 4) revert BadCalldata();
        bytes4 sel = bytes4(k.data);

        if (sel == SwapDecoder.ERC20_APPROVE && _tokenAllowed(id, gen, wallet, t)) {
            if (k.data.length != 68) revert BadCalldata();
            (address spender,) = abi.decode(_tail(k.data, 4), (address, uint256));
            _requireSpender(id, gen, wallet, spender);
            return;
        }

        if (!_allow[_key(K_TARGET, id, gen, t, sel)][wallet]) revert NotAllowed(t, sel);

        if (sel == SwapDecoder.PERMIT2_APPROVE) {
            if (k.data.length != 132) revert BadCalldata();
            (address token, address spender,,) = abi.decode(_tail(k.data, 4), (address, address, uint160, uint48));
            if (!_tokenAllowed(id, gen, wallet, token)) revert TokenNotAllowed(token);
            _requireSpender(id, gen, wallet, spender);
            return;
        }

        SwapDecoder.Swap[] memory swaps = SwapDecoder.decodeSwaps(wallet, sel, k.data);
        for (uint256 i; i < swaps.length; ++i) {
            _checkSwap(id, gen, wallet, c, swaps[i]);
        }
    }

    function _checkSwap(bytes32 id, uint32 gen, address wallet, Cfg memory c, SwapDecoder.Swap memory s) private view {
        if (s.amountIn == 0) revert ZeroAmount();
        if (
            s.inner != address(0)
                && !_allow[_key(K_TARGET, id, gen, s.inner, SwapDecoder.ZEROX_SETTLER_EXECUTE)][wallet]
        ) {
            revert NotAllowed(s.inner, SwapDecoder.ZEROX_SETTLER_EXECUTE);
        }
        if (!_tokenAllowed(id, gen, wallet, s.tokenIn)) revert TokenNotAllowed(s.tokenIn);
        if (!_tokenAllowed(id, gen, wallet, s.tokenOut)) revert TokenNotAllowed(s.tokenOut);
        if ((s.tokenIn == c.usdc) == (s.tokenOut == c.usdc)) revert PairNotAllowed(s.tokenIn, s.tokenOut);
    }

    function _requireSpender(bytes32 id, uint32 gen, address wallet, address spender) private view {
        if (!_allow[_key(K_SPENDER, id, gen, spender, bytes4(0))][wallet]) revert SpenderNotAllowed(spender);
    }

    function _tokenAllowed(bytes32 id, uint32 gen, address wallet, address token) private view returns (bool) {
        return _allow[_key(K_TOKEN, id, gen, token, bytes4(0))][wallet];
    }

    // ------------------------------------------------------------------ config
    function _apply(bytes32 id, address wallet, PolicyConfig memory p) private {
        if (p.usdc == address(0)) revert InvalidConfig("usdc");
        if (p.validUntil == 0) revert InvalidConfig("validUntil");
        if (p.targets.length == 0 || p.targets.length > MAX_LIST) revert InvalidConfig("targets");
        if (p.spenders.length > MAX_LIST || p.tokens.length > MAX_LIST || p.paymasters.length > MAX_LIST) {
            revert InvalidConfig("list size");
        }
        if (p.maxOpWei == 0 && p.paymasters.length == 0) revert InvalidConfig("maxOpWei");

        uint32 gen = _gen[id][wallet];
        _cfg[id][wallet] = Cfg({installed: true, validUntil: p.validUntil, usdc: p.usdc, hook: p.hook, maxOpWei: p.maxOpWei});

        _allow[_key(K_TOKEN, id, gen, p.usdc, bytes4(0))][wallet] = true;
        for (uint256 i; i < p.tokens.length; ++i) {
            address t = p.tokens[i];
            if (t == address(0) || t == p.usdc) revert InvalidConfig("token");
            _allow[_key(K_TOKEN, id, gen, t, bytes4(0))][wallet] = true;
        }
        for (uint256 i; i < p.spenders.length; ++i) {
            address s = p.spenders[i];
            if (s == address(0) || _forbiddenAddr(s, wallet, p)) revert InvalidConfig("spender");
            _allow[_key(K_SPENDER, id, gen, s, bytes4(0))][wallet] = true;
        }
        for (uint256 i; i < p.paymasters.length; ++i) {
            address m = p.paymasters[i];
            if (m == address(0)) revert InvalidConfig("paymaster");
            _allow[_key(K_PAYMASTER, id, gen, m, bytes4(0))][wallet] = true;
        }
        for (uint256 i; i < p.targets.length; ++i) {
            TargetCfg memory t = p.targets[i];
            if (t.target == address(0) || _forbiddenAddr(t.target, wallet, p) || t.selectors.length == 0) {
                revert InvalidConfig("target");
            }
            for (uint256 j; j < t.selectors.length; ++j) {
                if (!SwapDecoder.isKnownSelector(t.selectors[j])) revert InvalidConfig("selector");
                _allow[_key(K_TARGET, id, gen, t.target, t.selectors[j])][wallet] = true;
            }
        }
        emit PolicyConfigured(wallet, id, gen);
    }

    /// @dev the account, this policy, the hook, USDC and every listed token can never be a router or spender
    function _forbiddenAddr(address a, address wallet, PolicyConfig memory p) private view returns (bool) {
        if (a == wallet || a == address(this) || a == p.usdc || (p.hook != address(0) && a == p.hook)) return true;
        for (uint256 i; i < p.tokens.length; ++i) {
            if (a == p.tokens[i]) return true;
        }
        return false;
    }

    function _key(uint8 kind, bytes32 id, uint32 gen, address a, bytes4 sel) private pure returns (bytes32) {
        return keccak256(abi.encode(kind, id, gen, a, sel));
    }

    function _tail(bytes memory data, uint256 from) private pure returns (bytes memory out) {
        uint256 len = data.length - from;
        out = new bytes(len);
        assembly ("memory-safe") {
            mcopy(add(out, 0x20), add(add(data, 0x20), from), len)
        }
    }
}
