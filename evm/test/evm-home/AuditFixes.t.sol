// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EvmHomeBase} from "./EvmHomeBase.sol";
import {MockERC20} from "./mocks/Mocks.sol";
import {KrexaSwapPolicy} from "../../src/evm-home/KrexaSwapPolicy.sol";
import {KrexaRiskHook} from "../../src/evm-home/KrexaRiskHook.sol";
import {PackedUserOperation} from "../../src/evm-home/interfaces/PackedUserOperation.sol";
import {SwapDecoder} from "../../src/evm-home/lib/SwapDecoder.sol";

/// @notice Regression tests for the audit findings H1, H2, M1, L1, L2 (PoCs: AuditPoc / AuditPoc2).
contract AuditFixesTest is EvmHomeBase {
    function setUp() public override {
        super.setUp();
        vm.prank(wallet);
        hook.onInstall(abi.encode(hookConfig()));
        usdc.mint(wallet, 1_000_000 * U);
        weth.mint(wallet, 10e18);
    }

    function _pre(bytes memory cd) internal returns (bytes memory) {
        vm.prank(wallet);
        return hook.preCheck(entryPoint, 0, cd);
    }

    // ================================================================ H1: decoders re-encode and compare
    /// Uniswap main's v4 ExactInputParams: adds `uint256[] minHopPriceX36` after `path`.
    struct NewV4ExactInput {
        address currencyIn;
        SwapDecoder.V4PathKey[] path;
        uint256[] minHopPriceX36;
        uint128 amountIn;
        uint128 amountOutMinimum;
    }

    /// Uniswap main's v4 ExactInputSingleParams: adds `uint256 minHopPriceX36` before `hookData`.
    struct NewV4Single {
        SwapDecoder.PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    function _denied(bytes memory cd) internal {
        vm.expectRevert(SwapDecoder.Malformed.selector);
        _check(cd);
    }

    function _v4Call(bytes memory actions, bytes[] memory params) internal view returns (bytes memory) {
        return _single(ur, 0, _urExecute(hex"10", _one(abi.encode(actions, params))));
    }

    function _v4Params(bytes memory swap) internal view returns (bytes[] memory params) {
        params = new bytes[](3);
        params[0] = swap;
        params[1] = abi.encode(address(usdc), uint256(900_000 * U));
        params[2] = abi.encode(address(weth), uint256(0));
    }

    function test_H1_v4MultiHopNewLayoutIsDenied() public {
        SwapDecoder.V4PathKey[] memory path = new SwapDecoder.V4PathKey[](1);
        path[0] = SwapDecoder.V4PathKey(address(weth), 500, 10, address(0), "");
        NewV4ExactInput memory p = NewV4ExactInput(address(usdc), path, new uint256[](0), uint128(900_000 * U), 0);
        // the PoC calldata: the old decoder read dust as amountIn and the hook counted ~0 toward the caps
        bytes memory cd = _v4Call(hex"070c0f", _v4Params(abi.encode(p)));
        _denied(cd);
        vm.expectRevert(SwapDecoder.Malformed.selector);
        _pre(cd);
        assertEq(hook.spentInWindow(wallet), 0);
    }

    function test_H1_v4SingleNewLayoutIsDenied() public {
        // minHopPriceX36 == 0x140 == the offset the old layout expects for hookData: the old decoder parses it
        NewV4Single memory p = NewV4Single(
            SwapDecoder.PoolKey(address(usdc), address(weth), 500, 10, address(0)), true, uint128(50 * U), 0, 0x140, ""
        );
        _denied(_v4Call(hex"060c0f", _v4Params(abi.encode(p))));
    }

    function test_H1_v3SixWordUniversalRouterInputIsDenied() public {
        bytes memory in_ =
            abi.encode(wallet, 50 * U, uint256(0), _v3Path(address(usdc), address(weth)), true, new uint256[](0));
        _denied(_single(ur, 0, _urExecute(hex"00", _one(in_))));
    }

    function test_H1_trailingBytesAreDeniedOnEveryShape() public {
        address[] memory v2path = new address[](2);
        v2path[0] = address(usdc);
        v2path[1] = address(weth);
        bytes memory more = abi.encodePacked(uint256(7));

        // SwapRouter02 exactInputSingle / exactInput
        bytes memory c = _sr02Single(address(usdc), address(weth), wallet, 5 * U, 0);
        assertTrue(_try(_single(sr02, 0, c)));
        _denied(_single(sr02, 0, bytes.concat(c, more)));
        c = _sr02Path(_v3Path(address(usdc), address(weth)), wallet, 5 * U, 0);
        assertTrue(_try(_single(sr02, 0, c)));
        _denied(_single(sr02, 0, bytes.concat(c, more)));

        // Universal Router: outer args, V3, V2, SWEEP, UNWRAP_WETH inputs
        c = _urExecute(hex"00", _one(_urV3In(wallet, 5 * U, 0, _v3Path(address(usdc), address(weth)), true)));
        assertTrue(_try(_single(ur, 0, c)));
        _denied(_single(ur, 0, bytes.concat(c, more)));
        bytes memory in_ = bytes.concat(_urV3In(wallet, 5 * U, 0, _v3Path(address(usdc), address(weth)), true), more);
        _denied(_single(ur, 0, _urExecute(hex"00", _one(in_))));
        in_ = abi.encode(wallet, 5 * U, uint256(0), v2path, true);
        assertTrue(_try(_single(ur, 0, _urExecute(hex"08", _one(in_)))));
        _denied(_single(ur, 0, _urExecute(hex"08", _one(bytes.concat(in_, more)))));
        in_ = abi.encode(address(weth), wallet, uint160(0));
        assertTrue(_try(_single(ur, 0, _urExecute(hex"04", _one(in_)))));
        _denied(_single(ur, 0, _urExecute(hex"04", _one(bytes.concat(in_, more)))));
        in_ = abi.encode(wallet, uint256(0));
        assertTrue(_try(_single(ur, 0, _urExecute(hex"0c", _one(in_)))));
        _denied(_single(ur, 0, _urExecute(hex"0c", _one(bytes.concat(in_, more)))));

        // v4: outer (actions, params), the two swap structs, SETTLE_ALL/TAKE_ALL, TAKE
        SwapDecoder.PoolKey memory key = SwapDecoder.PoolKey(address(usdc), address(weth), 500, 10, address(0));
        bytes[] memory params = _v4Params(abi.encode(SwapDecoder.V4ExactInputSingle(key, true, uint128(5 * U), 0, "")));
        assertTrue(_try(_v4Call(hex"060c0f", params)));
        in_ = abi.encode(hex"060c0f", params);
        _denied(_single(ur, 0, _urExecute(hex"10", _one(bytes.concat(in_, more)))));
        bytes memory good = params[0];
        params[0] = bytes.concat(good, more);
        _denied(_v4Call(hex"060c0f", params));
        params[0] = good;
        params[1] = bytes.concat(params[1], more); // SETTLE_ALL
        _denied(_v4Call(hex"060c0f", params));
        params[1] = abi.encode(address(usdc), uint256(5 * U));
        params[2] = bytes.concat(params[2], more); // TAKE_ALL
        _denied(_v4Call(hex"060c0f", params));

        SwapDecoder.V4PathKey[] memory path = new SwapDecoder.V4PathKey[](1);
        path[0] = SwapDecoder.V4PathKey(address(weth), 500, 10, address(0), "");
        params = _v4Params(abi.encode(SwapDecoder.V4ExactInput(address(usdc), path, uint128(5 * U), 0)));
        params[1] = abi.encode(address(usdc), uint256(5 * U));
        assertTrue(_try(_v4Call(hex"070c0f", params)));
        params[0] = bytes.concat(params[0], more);
        _denied(_v4Call(hex"070c0f", params));

        params = new bytes[](2);
        params[0] = abi.encode(SwapDecoder.V4ExactInputSingle(key, true, uint128(5 * U), 0, ""));
        params[1] = abi.encode(address(weth), wallet, uint256(0)); // TAKE
        assertTrue(_try(_v4Call(hex"060e", params)));
        params[1] = bytes.concat(params[1], more);
        _denied(_v4Call(hex"060e", params));

        // 0x: exec args and the Settler args
        c = _zeroEx(settler, address(usdc), 5 * U, settler, wallet, address(weth), 1);
        assertTrue(_try(_single(holder, 0, c)));
        _denied(_single(holder, 0, bytes.concat(c, more)));
        bytes memory sdata = abi.encodeWithSelector(
            SwapDecoder.ZEROX_SETTLER_EXECUTE,
            SwapDecoder.Slippage(wallet, address(weth), 1),
            new bytes[](0),
            bytes32(0)
        );
        c = abi.encodeWithSelector(
            SwapDecoder.ZEROX_EXEC, settler, address(usdc), 5 * U, settler, bytes.concat(sdata, more)
        );
        _denied(_single(holder, 0, c));
    }

    function test_H1_nonCanonicalPointerLayoutIsDenied() public {
        // exactInput with the `path` offset pushed 32 bytes down and a gap word inserted: a lax parser reads the
        // same fields, the router and this decoder must never be able to disagree, so it is denied
        bytes memory path = _v3Path(address(usdc), address(weth));
        bytes memory cd = abi.encodePacked(
            SwapDecoder.SR02_EXACT_INPUT,
            uint256(0x20), // the struct is dynamic: tuple offset
            uint256(0xa0), // path offset inside the struct (canonical is 0x80)
            uint256(uint160(wallet)),
            uint256(5 * U),
            uint256(0),
            uint256(0xdead),
            path.length,
            path,
            new bytes(32 - path.length % 32)
        );
        _denied(_single(sr02, 0, cd));
    }

    // ================================================================ H2: gas fields and paymaster
    function _gasOp(uint256 pvg, uint128 vgl, uint128 cgl, uint128 maxFee)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op = _userOp(wallet, _wrapHooked(_buy(10 * U)));
        op.preVerificationGas = pvg;
        op.accountGasLimits = bytes32(abi.encodePacked(vgl, cgl));
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), maxFee));
    }

    function _run(PackedUserOperation memory op) internal returns (uint256) {
        vm.prank(wallet);
        return policy.checkUserOpPolicy(PID, op);
    }

    function test_H2_hugeGasFieldsCannotDrainTheAccount() public {
        PackedUserOperation memory op = _gasOp(1e12, 30_000_000, 30_000_000, uint128(1000 gwei));
        uint256 prefund = (1e12 + 60_000_000) * 1000 gwei;
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.PrefundTooHigh.selector, prefund, MAX_OP_WEI));
        _run(op);
    }

    function test_H2_prefundBoundary() public {
        // 1,000,000 gas * 2 gwei == maxOpWei exactly
        PackedUserOperation memory op = _gasOp(200_000, 300_000, 500_000, 2 gwei);
        assertGt(_run(op), 0);
        op = _gasOp(200_001, 300_000, 500_000, 2 gwei);
        vm.expectRevert(
            abi.encodeWithSelector(KrexaSwapPolicy.PrefundTooHigh.selector, 1_000_001 * 2 gwei, MAX_OP_WEI)
        );
        _run(op);
        // every gas field counts on its own
        vm.expectRevert();
        _run(_gasOp(0, uint128(MAX_OP_WEI), 1, 1 gwei));
        vm.expectRevert();
        _run(_gasOp(0, 1, uint128(MAX_OP_WEI), 1 gwei));
        vm.expectRevert();
        _run(_gasOp(MAX_OP_WEI, 0, 0, 2 gwei));
    }

    function test_H2_overflowIsDeniedNotWrapped() public {
        PackedUserOperation memory op = _gasOp(type(uint256).max, 1, 1, 1 gwei);
        vm.expectRevert(); // checked arithmetic: Panic(0x11)
        _run(op);
        op = _gasOp(type(uint256).max / 2, 1, 1, type(uint128).max);
        vm.expectRevert();
        _run(op);
    }

    function _withPaymaster(address pm, uint256 len) internal view returns (PackedUserOperation memory op) {
        op = _gasOp(1e12, 30_000_000, 30_000_000, uint128(1000 gwei)); // huge gas is the paymaster's problem
        bytes memory raw = abi.encodePacked(pm, uint128(100_000), uint128(50_000), hex"cafe");
        op.paymasterAndData = new bytes(len);
        for (uint256 i; i < len && i < raw.length; ++i) {
            op.paymasterAndData[i] = raw[i];
        }
    }

    function test_H2_paymasterMustBeAllowlisted() public {
        assertGt(_run(_withPaymaster(paymaster, 54)), 0);
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.PaymasterNotAllowed.selector, attacker));
        _run(_withPaymaster(attacker, 54));
        // too short to hold paymaster ++ two gas limits
        vm.expectRevert(KrexaSwapPolicy.BadCalldata.selector);
        _run(_withPaymaster(paymaster, 51));
        vm.expectRevert(KrexaSwapPolicy.BadCalldata.selector);
        _run(_withPaymaster(paymaster, 20));
        assertGt(_run(_withPaymaster(paymaster, 52)), 0);
    }

    function test_H2_setConfigRebuildsPaymasterAllowlist() public {
        KrexaSwapPolicy.PolicyConfig memory c = defaultConfig();
        c.paymasters = new address[](1);
        c.paymasters[0] = attacker;
        vm.prank(wallet);
        policy.setConfig(PID, c);
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.PaymasterNotAllowed.selector, paymaster));
        _run(_withPaymaster(paymaster, 54));
        assertGt(_run(_withPaymaster(attacker, 54)), 0);
        assertEq(policy.getConfig(PID, wallet).maxOpWei, MAX_OP_WEI);
    }

    function test_H2_paymasterOnlyConfigDeniesSelfPaidOps() public {
        KrexaSwapPolicy.PolicyConfig memory c = defaultConfig();
        c.maxOpWei = 0;
        vm.prank(wallet);
        policy.setConfig(PID, c);
        assertGt(_run(_withPaymaster(paymaster, 54)), 0);
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.PrefundTooHigh.selector, 100_000 * 1 gwei, 0));
        _run(_gasOp(0, 50_000, 50_000, 1 gwei));
    }

    function test_H2_invalidConfigs() public {
        KrexaSwapPolicy.PolicyConfig memory c = defaultConfig();
        c.maxOpWei = 0;
        c.paymasters = new address[](0);
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.InvalidConfig.selector, "maxOpWei"));
        policy.setConfig(PID, c);

        c = defaultConfig();
        c.paymasters[0] = address(0);
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.InvalidConfig.selector, "paymaster"));
        policy.setConfig(PID, c);

        c = defaultConfig();
        c.paymasters = new address[](33);
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.InvalidConfig.selector, "list size"));
        policy.setConfig(PID, c);
    }

    function test_H1_secondV4SwapActionIsDeniedWhateverTheOrder() public {
        // 0x06 then 0x07 (the order the existing test covers is 0x06,0x06): one swap action per V4_SWAP
        SwapDecoder.PoolKey memory key = SwapDecoder.PoolKey(address(usdc), address(weth), 500, 10, address(0));
        SwapDecoder.V4PathKey[] memory path = new SwapDecoder.V4PathKey[](1);
        path[0] = SwapDecoder.V4PathKey(address(weth), 500, 10, address(0), "");
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(SwapDecoder.V4ExactInputSingle(key, true, uint128(5 * U), 0, ""));
        params[1] = abi.encode(SwapDecoder.V4ExactInput(address(usdc), path, uint128(5 * U), 0));
        _denied(_v4Call(hex"0607", params));
    }

    /// @dev an allowlisted token arriving while buys are blocked counts as a buy, even if USDC did not move
    function test_postCheckCatchesATokenIncreaseWithoutUsdcOutflow() public {
        _pre(_buy(U)); // day snapshot
        ethFeed.set(1000e8); // 10 WETH lose $15,000: buys blocked
        bytes memory d = _pre(_buy(U));
        weth.mint(wallet, 1);
        vm.prank(wallet);
        vm.expectRevert(KrexaRiskHook.BuysBlocked.selector);
        hook.postCheck(d);
    }

    // ================================================================ M1: maxSlippageBps == 0 is rejected
    function test_M1_zeroSlippageIsRejectedOnInstallAndSetConfig() public {
        KrexaRiskHook.HookConfig memory h = hookConfig();
        h.maxSlippageBps = 0;
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.InvalidConfig.selector, "maxSlippageBps"));
        hook.setConfig(h);

        address other = makeAddr("other");
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.InvalidConfig.selector, "maxSlippageBps"));
        hook.onInstall(abi.encode(h));
    }

    function test_M1_everySwapNeedsAMinOutProof() public {
        KrexaRiskHook.HookConfig memory h = hookConfig();
        h.maxSlippageBps = 100;
        h.maxOpsPerHour = 1000;
        vm.prank(wallet);
        hook.setConfig(h);
        // PoC F4: selling the whole inventory with minOut 0 used to pass; a buy with minOut 0 too
        vm.expectRevert();
        _pre(_sell(10e18));
        vm.expectRevert();
        _pre(_buy(100 * U));
        // 0.04 WETH ~= 100 USDC at 2500; 99% of it is accepted
        _pre(_single(sr02, 0, _sr02Single(address(usdc), address(weth), wallet, 100 * U, 0.0396e18)));
        _pre(_single(sr02, 0, _sr02Single(address(weth), address(usdc), wallet, 0.04e18, 99 * U)));
    }

    // ================================================================ L1: the window covers a full 24h
    function test_L1_noDoubleCapInside24Hours() public {
        KrexaRiskHook.HookConfig memory h = hookConfig();
        h.maxOracleAge = uint32(400 days);
        h.maxOpsPerHour = 1000;
        vm.prank(wallet);
        hook.setConfig(h);
        ethFeed.set(2500e8);
        uint256 hourStart = (block.timestamp / 1 hours) * 1 hours;
        vm.warp(hourStart + 3599); // last second of hour H
        _pre(_buy(100 * U));
        _pre(_buy(100 * U));
        _pre(_buy(50 * U)); // 250 = dailyCap
        vm.expectRevert();
        _pre(_buy(1));

        vm.warp(hourStart + 3599 + 23 hours + 1); // PoC F3: 23h00m01s later the old bucket had expired
        ethFeed.set(2500e8);
        assertEq(hook.spentInWindow(wallet), 250 * U);
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.DailyCapExceeded.selector, 1, 0));
        _pre(_buy(1));

        vm.warp(hourStart + 3599 + 24 hours); // exactly 24h later: still counted, conservative
        ethFeed.set(2500e8);
        assertEq(hook.spentInWindow(wallet), 250 * U);

        vm.warp(hourStart + 25 hours); // hour H+25: the bucket is gone
        ethFeed.set(2500e8);
        assertEq(hook.spentInWindow(wallet), 0);
        _pre(_buy(100 * U));
    }

    // ================================================================ L2: token decimals and duplicates
    function _expectHookInvalid(KrexaRiskHook.HookConfig memory h, string memory why) internal {
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.InvalidConfig.selector, why));
        hook.setConfig(h);
    }

    function test_L2_tokenDecimalsMustMatchTheToken() public {
        KrexaRiskHook.HookConfig memory h = hookConfig();
        h.tokens[0].decimals = 6; // WETH has 18: NAV would be off by 1e12
        _expectHookInvalid(h, "token decimals");
        h.tokens[0] = KrexaRiskHook.TokenFeed(makeAddr("eoa"), address(ethFeed), 18); // no code
        _expectHookInvalid(h, "token decimals");
        h.tokens[0] = KrexaRiskHook.TokenFeed(address(this), address(ethFeed), 18); // no decimals(): call reverts
        _expectHookInvalid(h, "token decimals");
    }

    function test_L2_usdcMustHaveSixDecimals() public {
        MockERC20 usdc18 = new MockERC20("USDC18", 18);
        KrexaRiskHook.HookConfig memory h = hookConfig();
        h.usdc = address(usdc18);
        _expectHookInvalid(h, "usdc decimals");
    }

    function test_L2_duplicateTokensAreRejected() public {
        MockERC20 wbtc = new MockERC20("WBTC", 8);
        KrexaRiskHook.HookConfig memory h = hookConfig();
        h.tokens = new KrexaRiskHook.TokenFeed[](3);
        h.tokens[0] = KrexaRiskHook.TokenFeed(address(weth), address(ethFeed), 18);
        h.tokens[1] = KrexaRiskHook.TokenFeed(address(wbtc), address(ethFeed), 8);
        h.tokens[2] = KrexaRiskHook.TokenFeed(address(weth), address(ethFeed), 18);
        _expectHookInvalid(h, "duplicate token");
        h.tokens[2] = KrexaRiskHook.TokenFeed(address(junk), address(ethFeed), 18);
        vm.prank(wallet);
        hook.setConfig(h); // three distinct, correctly described tokens install
        assertEq(hook.getTokens(wallet).length, 3);
    }
}
