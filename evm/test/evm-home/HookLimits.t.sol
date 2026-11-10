// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EvmHomeBase} from "./EvmHomeBase.sol";
import {KrexaRiskHook} from "../../src/evm-home/KrexaRiskHook.sol";
import {ExecDecoder} from "../../src/evm-home/lib/ExecDecoder.sol";
import {SwapDecoder} from "../../src/evm-home/lib/SwapDecoder.sol";

/// @notice The limits that need a clock, a price or a counter. They used to be in the policy; they now live in
/// KrexaRiskHook.preCheck (execution phase) so the policy stays static for ERC-7562 bundlers. Calls are made as
/// the account (`vm.prank(wallet)`): Kernel calls hooks from the account.
/// Ported from the old SwapPolicy tests: per-trade cap, rolling daily budget, ops/hour, stale oracle, slippage proof.
contract HookLimitsTest is EvmHomeBase {
    function setUp() public override {
        super.setUp();
        vm.prank(wallet);
        hook.onInstall(abi.encode(hookConfig()));
    }

    // ---------------------------------------------------------------- helpers
    function _pre(bytes memory cd) internal returns (bytes memory) {
        vm.prank(wallet);
        return hook.preCheck(entryPoint, 0, cd);
    }

    function _tryPre(bytes memory cd) internal returns (bool ok) {
        vm.prank(wallet);
        try hook.preCheck(entryPoint, 0, cd) returns (bytes memory) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function _setHook(KrexaRiskHook.HookConfig memory h) internal {
        vm.prank(wallet);
        hook.setConfig(h);
    }

    /// @dev time-travelling tests: keep the oracle alive and the rate limit out of the way
    function _longLived() internal {
        KrexaRiskHook.HookConfig memory h = hookConfig();
        h.maxOracleAge = uint32(400 days);
        h.maxOpsPerHour = 1000;
        _setHook(h);
    }

    function _slip500() internal {
        KrexaRiskHook.HookConfig memory h = hookConfig();
        h.maxSlippageBps = 500; // 5%
        _setHook(h);
    }

    // ================================================================ per-trade cap
    function test_perTradeCap() public {
        _pre(_buy(100 * U)); // exactly at the cap
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.PerTradeCapExceeded.selector, 100 * U + 1, 100 * U));
        _pre(_buy(100 * U + 1));
    }

    function test_perTradeCapAppliesToWholeUserOp() public {
        address[] memory t = new address[](2);
        bytes[] memory d = new bytes[](2);
        t[0] = sr02;
        d[0] = _sr02Single(address(usdc), address(weth), wallet, 60 * U, 0);
        t[1] = sr02;
        d[1] = _sr02Single(address(usdc), address(weth), wallet, 60 * U, 0);
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.PerTradeCapExceeded.selector, 120 * U, 100 * U));
        _pre(_batch(t, d));
    }

    function testFuzz_perTradeCap(uint128 amount) public {
        amount = uint128(bound(amount, 1, 1_000_000 * U));
        assertEq(_tryPre(_buy(amount)), amount <= 100 * U);
    }

    function test_sellsAreNeverCappedNorCounted() public {
        _pre(_sell(1000e18));
        assertEq(hook.spentInWindow(wallet), 0);
        assertEq(hook.remainingDaily(wallet), 250 * U);
    }

    function test_zeroAmountRejected() public {
        vm.expectRevert(KrexaRiskHook.ZeroAmount.selector);
        _pre(_buy(0));
    }

    // ================================================================ rolling daily budget
    function test_dailyBudgetCap() public {
        _pre(_buy(100 * U));
        _pre(_buy(100 * U));
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.DailyCapExceeded.selector, 100 * U, 50 * U));
        _pre(_buy(100 * U));
        _pre(_buy(50 * U));
        assertEq(hook.remainingDaily(wallet), 0);
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.DailyCapExceeded.selector, 1, 0));
        _pre(_buy(1));
    }

    function test_dailyBudgetRolls() public {
        _longLived();
        _pre(_buy(100 * U));
        _pre(_buy(100 * U));
        _pre(_buy(50 * U));
        // the hour-H bucket counts through hour H+24 inclusive (25 buckets): a buy made at the END of hour H is still
        // inside its 24h
        vm.warp(T0 + 25 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.DailyCapExceeded.selector, 1, 0));
        _pre(_buy(1));
        assertEq(hook.spentInWindow(wallet), 250 * U);
        // hour H+25: the bucket has rolled off
        vm.warp(T0 + 25 hours);
        assertEq(hook.spentInWindow(wallet), 0);
        _pre(_buy(100 * U));
        assertEq(hook.spentInWindow(wallet), 100 * U);
    }

    function test_dailyBudgetRollsBucketByBucket() public {
        _longLived();
        _pre(_buy(100 * U)); // hour H
        vm.warp(T0 + 10 hours);
        _pre(_buy(100 * U)); // hour H+10
        vm.warp(T0 + 25 hours); // first bucket gone, second alive
        assertEq(hook.spentInWindow(wallet), 100 * U);
        _pre(_buy(100 * U));
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.DailyCapExceeded.selector, 100 * U, 50 * U));
        _pre(_buy(100 * U));
        _pre(_buy(50 * U));
        vm.warp(T0 + 35 hours); // H+10 bucket gone too
        assertEq(hook.spentInWindow(wallet), 150 * U);
        _pre(_buy(100 * U));
        assertEq(hook.spentInWindow(wallet), 250 * U);
    }

    function test_dailyBudgetLongIdleResets() public {
        _longLived();
        _pre(_buy(100 * U));
        vm.warp(T0 + 30 days);
        assertEq(hook.spentInWindow(wallet), 0);
        _pre(_buy(100 * U));
        _pre(_buy(100 * U));
        assertEq(hook.spentInWindow(wallet), 200 * U);
    }

    function test_sameHourBucketAccumulates() public {
        _longLived();
        _pre(_buy(10 * U));
        _pre(_buy(15 * U));
        assertEq(hook.spentInWindow(wallet), 25 * U);
        vm.warp(T0 + 25 hours);
        assertEq(hook.spentInWindow(wallet), 0);
    }

    /// @dev reference model: a buy in hour h counts while h_now <= h + 24 (same bucket semantics)
    function testFuzz_dailyBudgetRolls(uint96[10] memory amounts, uint32[10] memory gaps) public {
        _longLived();
        uint256[] memory hrs = new uint256[](10);
        uint256[] memory amts = new uint256[](10);
        uint256 n;
        for (uint256 i; i < 10; ++i) {
            vm.warp(block.timestamp + (gaps[i] % (30 hours)));
            ethFeed.set(2500e8);
            uint256 a = bound(amounts[i], 1, 120 * U);
            uint256 h = block.timestamp / 1 hours;
            uint256 sum;
            for (uint256 j; j < n; ++j) {
                if (hrs[j] + 25 > h) sum += amts[j];
            }
            bool expectOk = a <= 100 * U && sum + a <= 250 * U;
            bool ok = _tryPre(_buy(a));
            assertEq(ok, expectOk, "hook disagrees with reference window");
            if (ok) {
                hrs[n] = h;
                amts[n] = a;
                n++;
            }
            uint256 live;
            for (uint256 j; j < n; ++j) {
                if (hrs[j] + 25 > h) live += amts[j];
            }
            assertEq(hook.spentInWindow(wallet), live);
        }
    }

    // ================================================================ ops per hour
    function test_opsPerHour() public {
        KrexaRiskHook.HookConfig memory h = hookConfig();
        h.maxOpsPerHour = 3;
        _setHook(h);
        _pre(_sell(1));
        _pre(_sell(1));
        assertEq(hook.opsThisHour(wallet), 2);
        _pre(_sell(1));
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.OpsPerHourExceeded.selector, uint32(3)));
        _pre(_sell(1));
        vm.warp(T0 + 1 hours);
        assertEq(hook.opsThisHour(wallet), 0);
        _pre(_sell(1));
        assertEq(hook.opsThisHour(wallet), 1);
    }

    function test_deniedOpDoesNotConsumeBudgetOrOps() public {
        vm.expectRevert();
        _pre(_buy(101 * U));
        assertEq(hook.opsThisHour(wallet), 0);
        assertEq(hook.spentInWindow(wallet), 0);
    }

    function test_uninstallClearsCountersAndReinstallStartsFresh() public {
        _pre(_buy(10 * U));
        vm.prank(wallet);
        hook.onUninstall("");
        vm.prank(wallet);
        hook.onInstall(abi.encode(hookConfig()));
        assertEq(hook.spentInWindow(wallet), 0);
        assertEq(hook.opsThisHour(wallet), 0);
    }

    // ================================================================ tokens / pairs
    function test_tokenNotAllowed() public {
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.TokenNotAllowed.selector, address(junk)));
        _pre(_single(sr02, 0, _sr02Single(address(usdc), address(junk), wallet, U, 0)));
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.TokenNotAllowed.selector, address(junk)));
        _pre(_single(sr02, 0, _sr02Single(address(junk), address(usdc), wallet, U, 0)));
    }

    function test_pairMustContainExactlyOneUsdc() public {
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.PairNotAllowed.selector, address(usdc), address(usdc)));
        _pre(_single(sr02, 0, _sr02Single(address(usdc), address(usdc), wallet, U, 0)));
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.PairNotAllowed.selector, address(weth), address(weth)));
        _pre(_single(sr02, 0, _sr02Single(address(weth), address(weth), wallet, U, 0)));
    }

    function test_nonSwapCallsAreIgnoredByLimits() public {
        _pre(_single(address(usdc), 0, _approve(sr02, type(uint256).max)));
        _pre(_single(sr02, 0, hex"01")); // too short to carry a selector: the policy is the one that denies it
        _pre(_single(sr02, 0, hex"11111111")); // unknown selector
        assertEq(hook.spentInWindow(wallet), 0);
        assertEq(hook.opsThisHour(wallet), 3);
    }

    function test_callValueRejected() public {
        ExecDecoder.Call[] memory calls = new ExecDecoder.Call[](1);
        calls[0] = ExecDecoder.Call(sr02, 1 ether, _sr02Single(address(usdc), address(weth), wallet, U, 0));
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.ValueNotAllowed.selector, 1 ether));
        _pre(_batchCalls(calls));
    }

    function test_recipientProofRunsInTheHookToo() public {
        vm.expectRevert(abi.encodeWithSelector(SwapDecoder.RecipientNotWallet.selector, attacker));
        _pre(_single(sr02, 0, _sr02Single(address(usdc), address(weth), attacker, U, 0)));
    }

    // ================================================================ oracle
    function test_staleOracleDeniesBuys() public {
        vm.warp(T0 + 2 hours); // feed last updated at T0, maxOracleAge = 1h
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.StaleOracle.selector, address(ethFeed)));
        _pre(_buy(10 * U));
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.StaleOracle.selector, address(ethFeed)));
        _pre(_sell(1e18)); // sells too: no price, no minOut check (owner path still exits)
        ethFeed.set(2500e8); // fresh again
        _pre(_sell(1e18));
        _pre(_buy(10 * U));
    }

    function test_badFeedsDenyBuys() public {
        bytes memory err = abi.encodeWithSelector(KrexaRiskHook.StaleOracle.selector, address(ethFeed));
        ethFeed.setBroken(true);
        vm.expectRevert(err);
        _pre(_buy(U));
        ethFeed.setBroken(false);

        ethFeed.setShort(true);
        vm.expectRevert(err);
        _pre(_buy(U));
        ethFeed.setShort(false);

        ethFeed.set(0);
        vm.expectRevert(err);
        _pre(_buy(U));
        ethFeed.set(-5);
        vm.expectRevert(err);
        _pre(_buy(U));

        ethFeed.set(2500e8);
        ethFeed.setUpdatedAt(block.timestamp + 1); // from the future
        vm.expectRevert(err);
        _pre(_buy(U));
        ethFeed.setUpdatedAt(0);
        vm.expectRevert(err);
        _pre(_buy(U));

        ethFeed.set(2500e8);
        ethFeed.setDecimals(40);
        vm.expectRevert(err);
        _pre(_buy(U));
    }

    // ================================================================ slippage / minOut proof
    function test_slippageProofSwapRouter() public {
        _slip500();
        // 100 USDC at $2500 = 0.04 WETH; 5% slippage => minOut >= 0.038 WETH
        _pre(_single(sr02, 0, _sr02Single(address(usdc), address(weth), wallet, 100 * U, 0.038e18)));
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.MinOutTooLow.selector, 100 * U, 94_999_997));
        _pre(_single(sr02, 0, _sr02Single(address(usdc), address(weth), wallet, 100 * U, 0.037999999e18)));
        vm.expectRevert(); // minOut 0 is never acceptable once slippage is enforced
        _pre(_buy(10 * U));

        // sell 0.04 WETH (= 100 USDC) for at least 95 USDC
        _pre(_single(sr02, 0, _sr02Single(address(weth), address(usdc), wallet, 0.04e18, 95 * U)));
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.MinOutTooLow.selector, 100 * U, 94 * U));
        _pre(_single(sr02, 0, _sr02Single(address(weth), address(usdc), wallet, 0.04e18, 94 * U)));

        // stale price: the session key cannot sell, least of all with minOut 0
        vm.warp(T0 + 3 hours);
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.StaleOracle.selector, address(ethFeed)));
        _pre(_single(sr02, 0, _sr02Single(address(weth), address(usdc), wallet, 0.04e18, 0)));
    }

    function test_slippageMaxBpsConfig() public {
        KrexaRiskHook.HookConfig memory h = hookConfig();
        h.maxSlippageBps = 10_000; // any minOut allowed, but the check still needs a fresh price for buys
        _setHook(h);
        _pre(_buy(U));
    }

    // ================================================================ multi swap / router paths accumulate
    function test_universalRouterMultipleSwapsAccumulate() public {
        bytes[] memory in_ = new bytes[](2);
        in_[0] = _urV3In(wallet, 30 * U, 0, _v3Path(address(usdc), address(weth)), true);
        in_[1] = _urV3In(wallet, 40 * U, 0, _v3Path(address(usdc), address(weth)), true);
        _pre(_single(ur, 0, _urExecute(hex"0000", in_)));
        assertEq(hook.spentInWindow(wallet), 70 * U);
        // 70 + 40 + 40 > per-trade cap of 100 in one op
        in_ = new bytes[](3);
        in_[0] = _urV3In(wallet, 30 * U, 0, _v3Path(address(usdc), address(weth)), true);
        in_[1] = in_[0];
        in_[2] = _urV3In(wallet, 41 * U, 0, _v3Path(address(usdc), address(weth)), true);
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.PerTradeCapExceeded.selector, 101 * U, 100 * U));
        _pre(_single(ur, 0, _urExecute(hex"000000", in_)));
    }

    function test_universalRouterV2BuyCounted() public {
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);
        bytes[] memory in_ = _one(abi.encode(wallet, U, uint256(0), path, true));
        _pre(_single(ur, 0, _urExecute(hex"08", in_)));
        assertEq(hook.spentInWindow(wallet), U);
    }

    function test_universalRouterV4BuyAndSellCounted() public {
        bytes[] memory params = new bytes[](3);
        params[1] = abi.encode(address(usdc), uint256(10 * U));
        params[2] = abi.encode(address(weth), uint256(0));
        params[0] = abi.encode(
            SwapDecoder.V4ExactInputSingle(
                SwapDecoder.PoolKey(address(usdc), address(weth), 500, 10, address(0)), true, uint128(10 * U), 0, ""
            )
        );
        _pre(_single(ur, 0, _urExecute(hex"10", _one(abi.encode(hex"060c0f", params)))));
        assertEq(hook.spentInWindow(wallet), 10 * U);
        // oneForZero: sell WETH for USDC, not counted
        params[0] = abi.encode(
            SwapDecoder.V4ExactInputSingle(
                SwapDecoder.PoolKey(address(usdc), address(weth), 500, 10, address(0)), false, uint128(1e18), 0, ""
            )
        );
        _pre(_single(ur, 0, _urExecute(hex"10", _one(abi.encode(hex"060c0f", params)))));
        assertEq(hook.spentInWindow(wallet), 10 * U);
    }

    // ================================================================ 0x AllowanceHolder
    function test_zeroExBuyCountedAndProven() public {
        _slip500();
        bytes memory ok = _zeroEx(settler, address(usdc), 100 * U, settler, wallet, address(weth), 0.038e18);
        _pre(_single(holder, 0, ok));
        assertEq(hook.spentInWindow(wallet), 100 * U);
        vm.expectRevert(abi.encodeWithSelector(SwapDecoder.RecipientNotWallet.selector, attacker));
        _pre(_single(holder, 0, _zeroEx(settler, address(usdc), U, settler, attacker, address(weth), 0.038e18)));
    }

    function test_zeroExRequiresProvableMinOut() public {
        _slip500();
        // minOut too low
        vm.expectRevert();
        _pre(_single(holder, 0, _zeroEx(settler, address(usdc), 100 * U, settler, wallet, address(weth), 1)));
        // exit through 0x with a stale price cannot be proven: denied (unlike native router sells)
        vm.warp(T0 + 3 hours);
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.StaleOracle.selector, address(ethFeed)));
        _pre(_single(holder, 0, _zeroEx(settler, address(weth), 1e18, settler, wallet, address(usdc), 2400 * U)));
        ethFeed.set(2500e8);
        _pre(_single(holder, 0, _zeroEx(settler, address(weth), 1e18, settler, wallet, address(usdc), 2400 * U)));
    }

    // ================================================================ config
    function test_invalidLimitConfigs() public {
        KrexaRiskHook.HookConfig memory h = hookConfig();
        h.maxOpsPerHour = 0;
        _expectInvalid(h, "maxOpsPerHour");
        h = hookConfig();
        h.maxSlippageBps = 10_001;
        _expectInvalid(h, "maxSlippageBps");
        h.maxSlippageBps = 0; // M1: 0 would switch the minOut proof off
        _expectInvalid(h, "maxSlippageBps");
        h = hookConfig();
        h.perTradeCapUsdc = 0;
        _expectInvalid(h, "caps");
        h = hookConfig();
        h.dailyCapUsdc = h.perTradeCapUsdc - 1;
        _expectInvalid(h, "caps");
    }

    function _expectInvalid(KrexaRiskHook.HookConfig memory h, string memory why) internal {
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.InvalidConfig.selector, why));
        hook.setConfig(h);
    }

    function test_setConfigTightensCapsKeepsCounters() public {
        _pre(_buy(60 * U));
        KrexaRiskHook.HookConfig memory h = hookConfig();
        h.perTradeCapUsdc = uint128(10 * U);
        h.dailyCapUsdc = uint128(70 * U);
        _setHook(h);
        assertEq(hook.spentInWindow(wallet), 60 * U); // the counters survive a config change
        assertEq(hook.remainingDaily(wallet), 10 * U);
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.PerTradeCapExceeded.selector, 11 * U, 10 * U));
        _pre(_buy(11 * U));
        // cap lowered below what was already spent: remaining is 0, not an underflow
        h.perTradeCapUsdc = uint128(5 * U);
        h.dailyCapUsdc = uint128(50 * U);
        _setHook(h);
        assertEq(hook.remainingDaily(wallet), 0);
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.DailyCapExceeded.selector, 5 * U, 0));
        _pre(_buy(5 * U));
    }

    function testFuzz_randomCalldataNeverCrashesUnexpectedly(bytes memory junkData) public {
        // the hook either accepts or reverts; it must never write counters on a revert
        uint32 opsBefore = hook.opsThisHour(wallet);
        if (!_tryPre(junkData)) assertEq(hook.opsThisHour(wallet), opsBefore);
    }
}
