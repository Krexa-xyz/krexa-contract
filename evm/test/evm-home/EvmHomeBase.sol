// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KrexaSwapPolicy} from "../../src/evm-home/KrexaSwapPolicy.sol";
import {KrexaRiskHook} from "../../src/evm-home/KrexaRiskHook.sol";
import {PackedUserOperation} from "../../src/evm-home/interfaces/PackedUserOperation.sol";
import {ExecDecoder} from "../../src/evm-home/lib/ExecDecoder.sol";
import {SwapDecoder} from "../../src/evm-home/lib/SwapDecoder.sol";
import {MockERC20, MockFeed, MockSwapRouter, MockKernel} from "./mocks/Mocks.sol";

/// @dev Shared fixtures and calldata builders for the evm-home tests.
abstract contract EvmHomeBase is Test {
    KrexaSwapPolicy internal policy;
    KrexaRiskHook internal hook;
    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockERC20 internal junk; // a token that is NOT allowlisted
    MockFeed internal ethFeed;

    address internal wallet = makeAddr("wallet");
    address internal sr02 = makeAddr("sr02");
    address internal ur = makeAddr("universalRouter");
    address internal permit2 = makeAddr("permit2");
    address internal holder = makeAddr("allowanceHolder");
    address internal settler = makeAddr("settler");
    address internal attacker = makeAddr("attacker");
    address internal entryPoint = makeAddr("entryPoint");
    address internal paymaster = makeAddr("paymaster");
    uint128 internal constant MAX_OP_WEI = 0.002 ether;

    /// Kernel hands policies `bytes32(PermissionId)` where PermissionId is bytes4 (left aligned).
    bytes32 internal constant PID = bytes32(bytes4(0xabcd1234));
    uint256 internal constant U = 1e6; // 1 USDC

    uint256 internal constant T0 = 1_800_000_000; // 2027-01-15 08:00 UTC, an exact hour boundary

    function setUp() public virtual {
        vm.warp(T0);
        policy = new KrexaSwapPolicy();
        hook = new KrexaRiskHook();
        usdc = new MockERC20("USDC", 6);
        weth = new MockERC20("WETH", 18);
        junk = new MockERC20("JUNK", 18);
        ethFeed = new MockFeed(8, 2500e8);
        vm.prank(wallet);
        policy.onInstall(abi.encodePacked(PID, abi.encode(defaultConfig())));
    }

    // ---------------------------------------------------------------- config
    function defaultConfig() internal view returns (KrexaSwapPolicy.PolicyConfig memory c) {
        c.validUntil = uint48(block.timestamp + 7 days);
        c.usdc = address(usdc);
        c.hook = address(hook);
        c.spenders = new address[](4);
        c.spenders[0] = sr02;
        c.spenders[1] = ur;
        c.spenders[2] = permit2;
        c.spenders[3] = holder;
        c.targets = new KrexaSwapPolicy.TargetCfg[](5);
        c.targets[0] = _target(sr02, SwapDecoder.SR02_EXACT_INPUT_SINGLE, SwapDecoder.SR02_EXACT_INPUT);
        c.targets[1] = _target(ur, SwapDecoder.UR_EXECUTE, bytes4(0));
        c.targets[2] = _target(permit2, SwapDecoder.PERMIT2_APPROVE, bytes4(0));
        c.targets[3] = _target(holder, SwapDecoder.ZEROX_EXEC, bytes4(0));
        c.targets[4] = _target(settler, SwapDecoder.ZEROX_SETTLER_EXECUTE, bytes4(0));
        c.tokens = new address[](1);
        c.tokens[0] = address(weth);
        c.maxOpWei = MAX_OP_WEI;
        c.paymasters = new address[](1);
        c.paymasters[0] = paymaster;
    }

    function _target(address t, bytes4 a, bytes4 b) internal pure returns (KrexaSwapPolicy.TargetCfg memory c) {
        c.target = t;
        c.selectors = new bytes4[](b == bytes4(0) ? 1 : 2);
        c.selectors[0] = a;
        if (b != bytes4(0)) c.selectors[1] = b;
    }

    function hookConfig() internal view returns (KrexaRiskHook.HookConfig memory h) {
        h.maxDailyLossUsdc = uint128(50 * U);
        h.perTradeCapUsdc = uint128(100 * U);
        h.dailyCapUsdc = uint128(250 * U);
        h.maxOpsPerHour = 20;
        h.maxSlippageBps = 10_000; // 0 is rejected; 10000 = no minOut floor, tests that need a floor lower it
        h.maxOracleAge = 3600;
        h.usdc = address(usdc);
        h.tokens = new KrexaRiskHook.TokenFeed[](1);
        h.tokens[0] = KrexaRiskHook.TokenFeed(address(weth), address(ethFeed), 18);
    }

    // ---------------------------------------------------------------- calldata builders
    function _single(address target, uint256 value, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ExecDecoder.EXECUTE, bytes32(0), abi.encodePacked(target, value, data));
    }

    function _batch(address[] memory targets, bytes[] memory datas) internal pure returns (bytes memory) {
        ExecDecoder.Call[] memory calls = new ExecDecoder.Call[](targets.length);
        for (uint256 i; i < targets.length; ++i) {
            calls[i] = ExecDecoder.Call(targets[i], 0, datas[i]);
        }
        return abi.encodeWithSelector(ExecDecoder.EXECUTE, bytes32(bytes1(0x01)), abi.encode(calls));
    }

    function _batchCalls(ExecDecoder.Call[] memory calls) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ExecDecoder.EXECUTE, bytes32(bytes1(0x01)), abi.encode(calls));
    }

    function _wrapHooked(bytes memory executeCalldata) internal pure returns (bytes memory) {
        return bytes.concat(ExecDecoder.EXECUTE_USER_OP, executeCalldata);
    }

    function _userOp(address sender, bytes memory callData) internal pure returns (PackedUserOperation memory op) {
        op.sender = sender;
        op.callData = callData;
    }

    function _check(bytes memory callData) internal returns (uint256) {
        PackedUserOperation memory op = _userOp(wallet, callData);
        vm.prank(wallet);
        return policy.checkUserOpPolicy(PID, op);
    }

    function _try(bytes memory callData) internal returns (bool ok) {
        PackedUserOperation memory op = _userOp(wallet, callData);
        vm.prank(wallet);
        try policy.checkUserOpPolicy(PID, op) returns (uint256) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    // SwapRouter02
    function _sr02Single(address tin, address tout, address recipient, uint256 amountIn, uint256 minOut)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            SwapDecoder.SR02_EXACT_INPUT_SINGLE, SwapDecoder.SingleParams(tin, tout, 500, recipient, amountIn, minOut, 0)
        );
    }

    function _v3Path(address a, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, uint24(500), b);
    }

    function _sr02Path(bytes memory path, address recipient, uint256 amountIn, uint256 minOut)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            SwapDecoder.SR02_EXACT_INPUT, SwapDecoder.PathParams(path, recipient, amountIn, minOut)
        );
    }

    // Universal Router
    function _urExecute(bytes memory commands, bytes[] memory inputs) internal view returns (bytes memory) {
        return abi.encodeWithSelector(SwapDecoder.UR_EXECUTE, commands, inputs, uint256(block.timestamp + 600));
    }

    function _urV3In(address recipient, uint256 amountIn, uint256 minOut, bytes memory path, bool payerIsUser)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(recipient, amountIn, minOut, path, payerIsUser);
    }

    function _one(bytes memory x) internal pure returns (bytes[] memory a) {
        a = new bytes[](1);
        a[0] = x;
    }

    function _urBuy(address recipient, uint256 amountIn) internal view returns (bytes memory) {
        return _urExecute(
            hex"00", _one(_urV3In(recipient, amountIn, 0, _v3Path(address(usdc), address(weth)), true))
        );
    }

    // 0x
    function _zeroEx(address operator, address token, uint256 amount, address target, address recipient, address buy, uint256 minOut)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory sdata = abi.encodeWithSelector(
            SwapDecoder.ZEROX_SETTLER_EXECUTE,
            SwapDecoder.Slippage(recipient, buy, minOut),
            new bytes[](0),
            bytes32(0)
        );
        return abi.encodeWithSelector(SwapDecoder.ZEROX_EXEC, operator, token, amount, target, sdata);
    }

    function _approve(address spender, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(SwapDecoder.ERC20_APPROVE, spender, amount);
    }

    /// @dev a plain, valid USDC -> WETH buy of `amount` USDC base units through SwapRouter02
    function _buy(uint256 amount) internal view returns (bytes memory) {
        return _single(sr02, 0, _sr02Single(address(usdc), address(weth), wallet, amount, 0));
    }

    function _sell(uint256 wethAmount) internal view returns (bytes memory) {
        return _single(sr02, 0, _sr02Single(address(weth), address(usdc), wallet, wethAmount, 0));
    }
}
