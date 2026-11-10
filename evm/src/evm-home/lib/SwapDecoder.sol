// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SwapDecoder
/// @notice Decodes exact-input swap calldata of the routers Krexa allows into (tokenIn, tokenOut, amountIn,
/// minOut) and PROVES the output recipient is the smart account. Anything it cannot prove reverts: the policy
/// treats a revert as "deny". Layouts are pinned to the router versions named below; a router upgrade that
/// changes a layout makes the decoder deny (fail closed), never mis-allow. That is enforced, not assumed: every
/// `abi.decode` below is followed by a re-encode that must equal the input bytes exactly (`_canon`), so trailing
/// words, extra array elements or a different struct layout (for example Uniswap main's v4 `ExactInputParams` with
/// `uint256[] minHopPriceX36`) revert `Malformed` instead of being misread into the wrong fields.
///
///  - Uniswap SwapRouter02 (swap-router-contracts): exactInputSingle 0x04e45aaf, exactInput 0xb858183f.
///    recipient must equal the wallet exactly (no address(1)/address(2) shortcuts).
///  - Uniswap Universal Router `execute(bytes,bytes[],uint256)` 0x3593564c. Allowed commands:
///    V3_SWAP_EXACT_IN 0x00, SWEEP 0x04, V2_SWAP_EXACT_IN 0x08, UNWRAP_WETH 0x0c, V4_SWAP 0x10
///    (ids: universal-router/contracts/libraries/Commands.sol). Everything else (PERMIT2_*, TRANSFER,
///    PAY_PORTION, WRAP_ETH, EXACT_OUT, sub-plans, allow-revert flag) is denied. Swap recipients must be the
///    wallet or MSG_SENDER (address(1)); ADDRESS_THIS (address(2)) is denied, so nothing is left in the router.
///    payerIsUser must be true. SWEEP/UNWRAP recipients: wallet or MSG_SENDER.
///    V4_SWAP actions (v4-periphery Actions.sol): SWAP_EXACT_IN_SINGLE 0x06, SWAP_EXACT_IN 0x07,
///    SETTLE_ALL 0x0c, TAKE_ALL 0x0f, TAKE 0x0e (recipient checked). Exactly one swap action, pool hooks must
///    be address(0). Struct layout is the pre-`minHopPriceX36` v4-periphery layout (the one deployed in 2025).
///  - 0x AllowanceHolder `exec(operator,token,amount,target,data)` 0x2213bc0b wrapping Settler
///    `execute((recipient,buyToken,minAmountOut),bytes[],bytes32)` 0x1fff991f. The Settler actions are opaque,
///    so safety rests on: operator == target (an allowlisted Settler, checked by the policy), recipient == wallet,
///    and a minAmountOut the policy proves against Chainlink (`strict`). Without that proof the call is denied.
library SwapDecoder {
    bytes4 internal constant SR02_EXACT_INPUT_SINGLE = 0x04e45aaf;
    bytes4 internal constant SR02_EXACT_INPUT = 0xb858183f;
    bytes4 internal constant UR_EXECUTE = 0x3593564c;
    bytes4 internal constant ZEROX_EXEC = 0x2213bc0b;
    bytes4 internal constant ZEROX_SETTLER_EXECUTE = 0x1fff991f;
    bytes4 internal constant ERC20_APPROVE = 0x095ea7b3;
    bytes4 internal constant PERMIT2_APPROVE = 0x87517c45;

    address internal constant UR_MSG_SENDER = address(1);

    // Universal Router commands
    uint8 private constant CMD_V3_SWAP_EXACT_IN = 0x00;
    uint8 private constant CMD_SWEEP = 0x04;
    uint8 private constant CMD_V2_SWAP_EXACT_IN = 0x08;
    uint8 private constant CMD_UNWRAP_WETH = 0x0c;
    uint8 private constant CMD_V4_SWAP = 0x10;
    // v4 router actions
    uint8 private constant V4_SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 private constant V4_SWAP_EXACT_IN = 0x07;
    uint8 private constant V4_TAKE = 0x0e;
    uint8 private constant V4_SETTLE_ALL = 0x0c;
    uint8 private constant V4_TAKE_ALL = 0x0f;

    struct Swap {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minOut;
        /// @dev true when the router's own calldata does not prove where value goes (0x); the policy then
        /// requires an oracle-proven minOut.
        bool strict;
        /// @dev extra contract the call executes through (0x Settler); the policy must allowlist it. 0 if none.
        address inner;
    }

    error SelectorUnsupported(bytes4 selector);
    error RecipientNotWallet(address recipient);
    error CommandNotAllowed(uint8 command);
    error ActionNotAllowed(uint8 action);
    error BadPath();
    error Malformed();
    error NotUserFunded();
    error PoolHookNotAllowed(address hooks);

    // ---------------------------------------------------------------- SwapRouter02 shapes
    struct SingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct PathParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    // ---------------------------------------------------------------- v4 shapes (pre-minHopPriceX36)
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct V4ExactInputSingle {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    struct V4PathKey {
        address intermediateCurrency;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        bytes hookData;
    }

    struct V4ExactInput {
        address currencyIn;
        V4PathKey[] path;
        uint128 amountIn;
        uint128 amountOutMinimum;
    }

    // ---------------------------------------------------------------- 0x
    struct Slippage {
        address recipient;
        address buyToken;
        uint256 minAmountOut;
    }

    function isSwapSelector(bytes4 s) internal pure returns (bool) {
        return s == SR02_EXACT_INPUT_SINGLE || s == SR02_EXACT_INPUT || s == UR_EXECUTE || s == ZEROX_EXEC;
    }

    /// @notice every selector an owner may list in a router's selector allowlist
    function isKnownSelector(bytes4 s) internal pure returns (bool) {
        return isSwapSelector(s) || s == ZEROX_SETTLER_EXECUTE || s == PERMIT2_APPROVE;
    }

    function decodeSwaps(address wallet, bytes4 sel, bytes memory data) internal pure returns (Swap[] memory swaps) {
        bytes memory a = _args(data);
        if (sel == SR02_EXACT_INPUT_SINGLE) {
            SingleParams memory p = abi.decode(a, (SingleParams));
            _canon(a, abi.encode(p));
            if (p.recipient != wallet) revert RecipientNotWallet(p.recipient);
            swaps = new Swap[](1);
            swaps[0] = Swap(p.tokenIn, p.tokenOut, p.amountIn, p.amountOutMinimum, false, address(0));
        } else if (sel == SR02_EXACT_INPUT) {
            PathParams memory p = abi.decode(a, (PathParams));
            _canon(a, abi.encode(p));
            if (p.recipient != wallet) revert RecipientNotWallet(p.recipient);
            (address tin, address tout) = _v3PathEnds(p.path);
            swaps = new Swap[](1);
            swaps[0] = Swap(tin, tout, p.amountIn, p.amountOutMinimum, false, address(0));
        } else if (sel == UR_EXECUTE) {
            swaps = _universalRouter(wallet, a);
        } else if (sel == ZEROX_EXEC) {
            swaps = _zeroEx(wallet, a);
        } else {
            revert SelectorUnsupported(sel);
        }
    }

    // ---------------------------------------------------------------- Universal Router
    function _universalRouter(address wallet, bytes memory a) private pure returns (Swap[] memory out) {
        (bytes memory commands, bytes[] memory inputs, uint256 deadline) = abi.decode(a, (bytes, bytes[], uint256));
        _canon(a, abi.encode(commands, inputs, deadline));
        uint256 n = commands.length;
        if (n == 0 || n != inputs.length) revert Malformed();
        Swap[] memory tmp = new Swap[](n);
        uint256 count;
        for (uint256 i; i < n; ++i) {
            uint8 c = uint8(commands[i]);
            // 0x80 = allow-revert (a failing leg would be skipped); 0x40 is a newer-router namespace. Deny both.
            if (c & 0xC0 != 0) revert CommandNotAllowed(c);
            if (c == CMD_V3_SWAP_EXACT_IN) {
                tmp[count++] = _urV3(inputs[i], wallet);
            } else if (c == CMD_V2_SWAP_EXACT_IN) {
                tmp[count++] = _urV2(inputs[i], wallet);
            } else if (c == CMD_V4_SWAP) {
                tmp[count++] = _v4(inputs[i], wallet);
            } else if (c == CMD_SWEEP) {
                (address tok, address r, uint160 min) = abi.decode(inputs[i], (address, address, uint160));
                _canon(inputs[i], abi.encode(tok, r, min));
                _urRecipient(r, wallet);
            } else if (c == CMD_UNWRAP_WETH) {
                (address r, uint256 min) = abi.decode(inputs[i], (address, uint256));
                _canon(inputs[i], abi.encode(r, min));
                _urRecipient(r, wallet);
            } else {
                revert CommandNotAllowed(c);
            }
        }
        out = new Swap[](count);
        for (uint256 i; i < count; ++i) {
            out[i] = tmp[i];
        }
    }

    function _urV3(bytes memory input, address wallet) private pure returns (Swap memory s) {
        (address r, uint256 amountIn, uint256 minOut, bytes memory path, bool payerIsUser) =
            abi.decode(input, (address, uint256, uint256, bytes, bool));
        _canon(input, abi.encode(r, amountIn, minOut, path, payerIsUser));
        _urRecipient(r, wallet);
        if (!payerIsUser) revert NotUserFunded();
        (address tin, address tout) = _v3PathEnds(path);
        s = Swap(tin, tout, amountIn, minOut, false, address(0));
    }

    function _urV2(bytes memory input, address wallet) private pure returns (Swap memory s) {
        (address r, uint256 amountIn, uint256 minOut, address[] memory path, bool payerIsUser) =
            abi.decode(input, (address, uint256, uint256, address[], bool));
        _canon(input, abi.encode(r, amountIn, minOut, path, payerIsUser));
        _urRecipient(r, wallet);
        if (!payerIsUser) revert NotUserFunded();
        if (path.length < 2) revert BadPath();
        s = Swap(path[0], path[path.length - 1], amountIn, minOut, false, address(0));
    }

    function _urRecipient(address r, address wallet) private pure {
        if (r != wallet && r != UR_MSG_SENDER) revert RecipientNotWallet(r);
    }

    function _v4(bytes memory input, address wallet) private pure returns (Swap memory s) {
        (bytes memory actions, bytes[] memory params) = abi.decode(input, (bytes, bytes[]));
        _canon(input, abi.encode(actions, params));
        if (actions.length == 0 || actions.length != params.length) revert Malformed();
        bool seen;
        for (uint256 i; i < actions.length; ++i) {
            uint8 act = uint8(actions[i]);
            if (act == V4_SWAP_EXACT_IN_SINGLE) {
                if (seen) revert Malformed();
                seen = true;
                V4ExactInputSingle memory p = abi.decode(params[i], (V4ExactInputSingle));
                _canon(params[i], abi.encode(p));
                if (p.poolKey.hooks != address(0)) revert PoolHookNotAllowed(p.poolKey.hooks);
                (address tin, address tout) = p.zeroForOne
                    ? (p.poolKey.currency0, p.poolKey.currency1)
                    : (p.poolKey.currency1, p.poolKey.currency0);
                s = Swap(tin, tout, p.amountIn, p.amountOutMinimum, false, address(0));
            } else if (act == V4_SWAP_EXACT_IN) {
                if (seen) revert Malformed();
                seen = true;
                V4ExactInput memory p = abi.decode(params[i], (V4ExactInput));
                _canon(params[i], abi.encode(p));
                if (p.path.length == 0) revert BadPath();
                for (uint256 j; j < p.path.length; ++j) {
                    if (p.path[j].hooks != address(0)) revert PoolHookNotAllowed(p.path[j].hooks);
                }
                s = Swap(
                    p.currencyIn,
                    p.path[p.path.length - 1].intermediateCurrency,
                    p.amountIn,
                    p.amountOutMinimum,
                    false,
                    address(0)
                );
            } else if (act == V4_SETTLE_ALL || act == V4_TAKE_ALL) {
                (address cur, uint256 amt) = abi.decode(params[i], (address, uint256));
                _canon(params[i], abi.encode(cur, amt));
            } else if (act == V4_TAKE) {
                (address cur, address r, uint256 amt) = abi.decode(params[i], (address, address, uint256));
                _canon(params[i], abi.encode(cur, r, amt));
                _urRecipient(r, wallet);
            } else {
                revert ActionNotAllowed(act);
            }
        }
        if (!seen) revert Malformed();
    }

    // ---------------------------------------------------------------- 0x
    function _zeroEx(address wallet, bytes memory a) private pure returns (Swap[] memory swaps) {
        (address operator, address token, uint256 amount, address target, bytes memory sdata) =
            abi.decode(a, (address, address, uint256, address, bytes));
        _canon(a, abi.encode(operator, token, amount, target, sdata));
        if (operator != target) revert Malformed();
        if (sdata.length < 4 || bytes4(sdata) != ZEROX_SETTLER_EXECUTE) revert SelectorUnsupported(bytes4(sdata));
        bytes memory sargs = _args(sdata);
        (Slippage memory sl, bytes[] memory acts, bytes32 aux) = abi.decode(sargs, (Slippage, bytes[], bytes32));
        _canon(sargs, abi.encode(sl, acts, aux));
        if (sl.recipient != wallet) revert RecipientNotWallet(sl.recipient);
        swaps = new Swap[](1);
        swaps[0] = Swap(token, sl.buyToken, amount, sl.minAmountOut, true, target);
    }

    // ---------------------------------------------------------------- helpers
    /// @dev `raw` must be exactly what a canonical encoder would write for the decoded value (`re`)
    function _canon(bytes memory raw, bytes memory re) private pure {
        if (keccak256(raw) != keccak256(re)) revert Malformed();
    }

    /// @dev first and last token of a Uniswap v3 packed path: token(20) [fee(3) token(20)]+
    function _v3PathEnds(bytes memory path) private pure returns (address first, address last) {
        uint256 len = path.length;
        if (len < 43 || (len - 20) % 23 != 0) revert BadPath();
        assembly ("memory-safe") {
            first := shr(96, mload(add(path, 0x20)))
            last := and(mload(add(path, len)), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    /// @dev calldata minus the 4-byte selector
    function _args(bytes memory data) private pure returns (bytes memory out) {
        if (data.length < 4) revert Malformed();
        uint256 len = data.length - 4;
        out = new bytes(len);
        assembly ("memory-safe") {
            mcopy(add(out, 0x20), add(data, 0x24), len)
        }
    }
}
