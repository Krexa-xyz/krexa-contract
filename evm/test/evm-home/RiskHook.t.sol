// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EvmHomeBase} from "./EvmHomeBase.sol";
import {KrexaRiskHook} from "../../src/evm-home/KrexaRiskHook.sol";
import {ExecDecoder} from "../../src/evm-home/lib/ExecDecoder.sol";

/// @notice Unit tests for KrexaRiskHook. Calls are made as the account (`vm.prank(wallet)`) because Kernel calls
/// hooks from the account: `msg.sender` inside the hook is the Kernel account, `msgSender` (arg 1) is the EntryPoint.
/// Ported in spirit from AgentWallet.t.sol freeze/unfreeze/NAV tests and SecurityHardening.t.sol pause tests.
contract RiskHookTest is EvmHomeBase {
    uint256 internal constant DAY0 = 1_799_971_200; // 00:00 UTC of T0's day
    uint256 internal constant MIDNIGHT = DAY0 + 1 days;

    function setUp() public override {
        super.setUp();
        vm.prank(wallet);
        hook.onInstall(abi.encode(hookConfig()));
        usdc.mint(wallet, 500 * U);
        weth.mint(wallet, 0.2e18); // 0.2 * $2500 = $500 -> NAV $1000
    }

    // ---------------------------------------------------------------- helpers
    function _pre(bytes memory cd) internal returns (bytes memory) {
        vm.prank(wallet);
        return hook.preCheck(entryPoint, 0, cd);
    }

    function _post(bytes memory data) internal {
        vm.prank(wallet);
        hook.postCheck(data);
    }

    /// @dev a harmless op (approve) that exercises only the NAV gate: buys through a stale feed revert earlier
    function _probe() internal view returns (bytes memory) {
        return _single(address(usdc), 0, _approve(sr02, 1));
    }

    function _blocked(bytes memory data) internal pure returns (bool b) {
        (b,) = abi.decode(data, (bool, uint256[]));
    }

    function _simBuy(uint256 usdcSpent, uint256 wethGot) internal {
        usdc.burn(wallet, usdcSpent);
        weth.mint(wallet, wethGot);
    }

    function _simSell(uint256 wethSold, uint256 usdcGot) internal {
        weth.burn(wallet, wethSold);
        usdc.mint(wallet, usdcGot);
    }

    // ---------------------------------------------------------------- install
    function test_installAndViews() public view {
        assertTrue(hook.isInitialized(wallet));
        assertFalse(hook.isInitialized(attacker));
        assertTrue(hook.isModuleType(4));
        assertFalse(hook.isModuleType(5));
        KrexaRiskHook.State memory s = hook.getState(wallet);
        assertEq(s.maxDailyLossUsdc, 50 * U);
        assertEq(s.usdc, address(usdc));
        assertFalse(s.paused);
        assertEq(hook.getTokens(wallet).length, 1);
    }

    function test_installTwiceReverts() public {
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSignature("AlreadyInitialized(address)", wallet));
        hook.onInstall(abi.encode(hookConfig()));
    }

    function test_uninstallFailsClosed() public {
        vm.prank(wallet);
        hook.onUninstall("");
        assertFalse(hook.isInitialized(wallet));
        // a permission that still points at an uninstalled hook cannot run
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSignature("NotInitialized(address)", wallet));
        hook.preCheck(entryPoint, 0, _buy(U));
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSignature("NotInitialized(address)", wallet));
        hook.onUninstall("");
    }

    function test_notInstalledReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("NotInitialized(address)", attacker));
        hook.preCheck(entryPoint, 0, _buy(U));
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("NotInitialized(address)", attacker));
        hook.postCheck(abi.encode(true, new uint256[](1)));
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("NotInitialized(address)", attacker));
        hook.pause();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("NotInitialized(address)", attacker));
        hook.setConfig(hookConfig());
    }

    function test_invalidConfigs() public {
        KrexaRiskHook.HookConfig memory h = hookConfig();
        h.usdc = address(0);
        _expectInvalid(h, "usdc");
        h = hookConfig();
        h.maxDailyLossUsdc = 0;
        _expectInvalid(h, "maxDailyLossUsdc");
        h = hookConfig();
        h.maxOracleAge = 0;
        _expectInvalid(h, "maxOracleAge");
        h = hookConfig();
        h.tokens = new KrexaRiskHook.TokenFeed[](17);
        _expectInvalid(h, "tokens");
        h = hookConfig();
        h.tokens[0].feed = address(0);
        _expectInvalid(h, "token");
        h = hookConfig();
        h.tokens[0].token = address(usdc);
        _expectInvalid(h, "token");
        h = hookConfig();
        h.tokens[0].token = address(0);
        _expectInvalid(h, "token");
        h = hookConfig();
        h.tokens[0].decimals = 37;
        _expectInvalid(h, "token");
    }

    function _expectInvalid(KrexaRiskHook.HookConfig memory h, string memory why) internal {
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.InvalidConfig.selector, why));
        hook.setConfig(h);
    }

    // ---------------------------------------------------------------- NAV snapshot
    function test_snapshotAtFirstValuationOfTheDay() public {
        assertEq(hook.getState(wallet).snapDay, 0);
        _pre(_buy(U));
        KrexaRiskHook.State memory s = hook.getState(wallet);
        assertEq(s.snapDay, uint32(T0 / 1 days));
        assertEq(s.startNav, 1000 * U);
        // later valuations in the same UTC day do not move the baseline
        ethFeed.set(2400e8);
        _pre(_buy(U));
        assertEq(hook.getState(wallet).startNav, 1000 * U);
    }

    function test_snapshotRollsAtUtcMidnight() public {
        _pre(_buy(U));
        vm.warp(MIDNIGHT - 1);
        ethFeed.set(2500e8);
        _pre(_buy(U));
        assertEq(hook.getState(wallet).snapDay, uint32(DAY0 / 1 days)); // still yesterday's snapshot
        vm.warp(MIDNIGHT);
        ethFeed.set(2000e8); // NAV now 500 + 0.2*2000 = 900
        _pre(_buy(U));
        assertEq(hook.getState(wallet).snapDay, uint32(MIDNIGHT / 1 days));
        assertEq(hook.getState(wallet).startNav, 900 * U);
    }

    // ---------------------------------------------------------------- daily loss
    function test_dailyLossBlocksBuys_allowsSells() public {
        _pre(_buy(U)); // snapshot: NAV 1000
        ethFeed.set(2400e8); // NAV 980, loss 20 < 50: buys still fine
        bytes memory d = _pre(_buy(U));
        assertFalse(_blocked(d));
        _simBuy(10 * U, 0.004e18);
        _post(d);

        ethFeed.set(2000e8); // NAV ~ 490 + 0.204*2000 = 898: loss > 50
        (bool blockBuys,, uint256 nav, uint256 startNav, uint256 loss) = hook.riskState(wallet);
        assertTrue(blockBuys);
        assertEq(startNav, 1000 * U);
        assertEq(loss, startNav - nav);

        // a buy (USDC down, WETH up) is rejected after the fact, so the whole UserOp reverts
        d = _pre(_buy(U));
        assertTrue(_blocked(d));
        _simBuy(20 * U, 0.01e18);
        vm.prank(wallet);
        vm.expectRevert(KrexaRiskHook.BuysBlocked.selector);
        hook.postCheck(d);
        _simSell(0.01e18, 20 * U); // undo the simulated buy

        // a sell (WETH down, USDC up) is allowed
        d = _pre(_sell(1e18));
        assertTrue(_blocked(d));
        _simSell(0.05e18, 100 * U);
        _post(d);

        // a no-op (approve) is allowed
        d = _pre(_single(address(usdc), 0, _approve(sr02, 1)));
        _post(d);
    }

    function test_lossExactlyAtLimitBlocks() public {
        _pre(_buy(U));
        usdc.burn(wallet, 50 * U - 1);
        assertFalse(_blocked(_pre(_buy(U)))); // loss 49.999999
        usdc.burn(wallet, 1);
        assertTrue(_blocked(_pre(_buy(U)))); // loss 50.000000 >= limit
    }

    function test_hiddenBuyInsideBatchIsCaught() public {
        _pre(_buy(U));
        ethFeed.set(1000e8); // heavy loss: blocked
        bytes memory d = _pre(_buy(U));
        assertTrue(_blocked(d));
        // sell 0.05 WETH for 50 USDC, then buy 0.06 WETH for 60 USDC in the same UserOp:
        // USDC ends lower and WETH ends higher than before
        _simSell(0.05e18, 50 * U);
        _simBuy(60 * U, 0.06e18);
        vm.prank(wallet);
        vm.expectRevert(KrexaRiskHook.BuysBlocked.selector);
        hook.postCheck(d);
    }

    function test_usdcOutflowAloneIsABuy() public {
        _pre(_buy(U));
        ethFeed.set(1000e8); // blocked
        bytes memory d = _pre(_buy(U));
        // USDC leaves the account but no allowlisted token arrives (e.g. a swap into an unlisted token)
        usdc.burn(wallet, 5 * U);
        vm.prank(wallet);
        vm.expectRevert(KrexaRiskHook.BuysBlocked.selector);
        hook.postCheck(d);
    }

    function test_withdrawalCountsTowardLoss() public {
        _pre(_buy(U)); // NAV 1000
        // owner (root validator, not hooked) withdraws 49 USDC: loss 49 < 50
        vm.prank(wallet);
        usdc.transfer(attacker, 49 * U);
        assertFalse(_blocked(_pre(_buy(U))));
        // one more dollar and withdrawn money reads as loss >= limit: buys blocked, sells open
        vm.prank(wallet);
        usdc.transfer(attacker, 1 * U);
        bytes memory d = _pre(_buy(U));
        assertTrue(_blocked(d));
        _simSell(0.01e18, 25 * U);
        _post(d);
    }

    function test_depositsOffsetEarlierLossLikeTheOffchainEngine() public {
        _pre(_buy(U));
        ethFeed.set(2000e8); // NAV 900, loss 100: blocked
        assertTrue(_blocked(_pre(_buy(U))));
        usdc.mint(wallet, 100 * U); // owner deposits 100: NAV back to 1000
        assertFalse(_blocked(_pre(_buy(U))));
    }

    function test_newUtcDayResetsLossWindow() public {
        _pre(_buy(U));
        ethFeed.set(2000e8);
        assertTrue(_blocked(_pre(_buy(U))));
        vm.warp(MIDNIGHT - 1);
        ethFeed.set(2000e8);
        assertTrue(_blocked(_pre(_buy(U)))); // same day: yesterday's loss still counts
        vm.warp(MIDNIGHT);
        ethFeed.set(2000e8);
        assertFalse(_blocked(_pre(_buy(U)))); // new day: baseline = today's first valuation
    }

    // ---------------------------------------------------------------- oracle
    function test_staleOracleDeniesBuys() public {
        _pre(_buy(U));
        vm.warp(T0 + 2 hours); // feed older than maxOracleAge, wallet holds WETH
        (bool blockBuys, bool fresh,,,) = hook.riskState(wallet);
        assertTrue(blockBuys);
        assertFalse(fresh);

        // a buy of the stale token is refused up front; a buy of anything else is caught after the fact
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.StaleOracle.selector, address(ethFeed)));
        hook.preCheck(entryPoint, 0, _buy(U));
        bytes memory d = _pre(_probe());
        assertTrue(_blocked(d));
        _simBuy(10 * U, 0.004e18);
        vm.prank(wallet);
        vm.expectRevert(KrexaRiskHook.BuysBlocked.selector);
        hook.postCheck(d);
        _simSell(0.004e18, 10 * U);

        // the session key cannot sell while the oracle is stale (the owner path can)
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.StaleOracle.selector, address(ethFeed)));
        hook.preCheck(entryPoint, 0, _sell(1e18));
        // stale oracle never wrote a snapshot or lowered the baseline
        assertEq(hook.getState(wallet).startNav, 1000 * U);
    }

    function test_noHeldTokenMeansNoOracleNeeded() public {
        weth.burn(wallet, weth.balanceOf(wallet)); // only USDC left
        vm.warp(T0 + 2 hours);
        assertFalse(_blocked(_pre(_probe()))); // feed is stale but nothing needs pricing
        (, bool fresh,,,) = hook.riskState(wallet);
        assertTrue(fresh);
    }

    function test_staleFirstValuationOfDayTakesNoSnapshot() public {
        vm.warp(MIDNIGHT + 3 hours); // feed from T0 is long stale
        bytes memory d = _pre(_probe());
        assertTrue(_blocked(d));
        assertEq(hook.getState(wallet).snapDay, 0);
        ethFeed.set(2500e8);
        d = _pre(_buy(U));
        assertFalse(_blocked(d));
        assertEq(hook.getState(wallet).startNav, 1000 * U);
    }

    // ---------------------------------------------------------------- pause
    function test_pausedBlocksAll() public {
        vm.prank(wallet);
        hook.pause();
        assertTrue(hook.getState(wallet).paused);
        vm.prank(wallet);
        vm.expectRevert(KrexaRiskHook.HookPaused.selector);
        hook.preCheck(entryPoint, 0, _buy(U));
        vm.prank(wallet);
        vm.expectRevert(KrexaRiskHook.HookPaused.selector);
        hook.preCheck(entryPoint, 0, _sell(1)); // sells too
        vm.prank(wallet);
        vm.expectRevert(KrexaRiskHook.HookPaused.selector);
        hook.preCheck(entryPoint, 0, _single(address(usdc), 0, _approve(sr02, 1)));
    }

    function test_onlyOwnerUnpauses() public {
        vm.prank(wallet);
        hook.pause();
        // anyone but the account itself: not an installed account, so every owner-only entry point reverts
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("NotInitialized(address)", attacker));
        hook.unpause();
        // pausing another account's hook state is impossible too (state is keyed by msg.sender)
        assertTrue(hook.getState(wallet).paused);
        vm.prank(wallet);
        hook.unpause();
        assertFalse(hook.getState(wallet).paused);
        _pre(_buy(U));
    }

    function test_setConfigKeepsPauseAndSnapshot() public {
        _pre(_buy(U));
        vm.prank(wallet);
        hook.pause();
        KrexaRiskHook.HookConfig memory h = hookConfig();
        h.maxDailyLossUsdc = uint128(10 * U);
        vm.prank(wallet);
        hook.setConfig(h);
        KrexaRiskHook.State memory s = hook.getState(wallet);
        assertTrue(s.paused);
        assertEq(s.startNav, 1000 * U);
        assertEq(s.maxDailyLossUsdc, 10 * U);
    }

    // ---------------------------------------------------------------- what a session op may contain
    function test_valueRejected() public {
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.ValueNotAllowed.selector, 1));
        hook.preCheck(entryPoint, 1, _buy(U));
    }

    function test_callsToHookOrAccountRejected() public {
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.TargetForbidden.selector, address(hook)));
        hook.preCheck(entryPoint, 0, _single(address(hook), 0, abi.encodeWithSignature("unpause()")));
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.TargetForbidden.selector, wallet));
        hook.preCheck(entryPoint, 0, _single(wallet, 0, hex"12345678"));
        // hidden in a batch
        address[] memory t = new address[](2);
        bytes[] memory d = new bytes[](2);
        t[0] = sr02;
        d[0] = hex"11111111";
        t[1] = address(hook);
        d[1] = abi.encodeWithSignature("pause()");
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.TargetForbidden.selector, address(hook)));
        hook.preCheck(entryPoint, 0, _batch(t, d));
    }

    function test_onlyExecuteCalldata() public {
        vm.prank(wallet);
        vm.expectRevert(ExecDecoder.NotExecute.selector);
        hook.preCheck(entryPoint, 0, abi.encodeWithSignature("upgradeTo(address)", attacker));
        // the 4-byte executeUserOp wrapper is accepted too
        _pre(_wrapHooked(_buy(U)));
    }

    // ---------------------------------------------------------------- valuation maths
    function test_navMathWithOddDecimals() public {
        // WBTC-like: 8 decimals, $60,000 feed with 8 decimals
        MockToken wbtc = new MockToken();
        wbtc.mint(wallet, 2e8); // 2 BTC = $120,000
        MockFeedLike f = new MockFeedLike();
        KrexaRiskHook.HookConfig memory h = hookConfig();
        h.tokens = new KrexaRiskHook.TokenFeed[](2);
        h.tokens[0] = KrexaRiskHook.TokenFeed(address(weth), address(ethFeed), 18);
        h.tokens[1] = KrexaRiskHook.TokenFeed(address(wbtc), address(f), 8);
        vm.prank(wallet);
        hook.setConfig(h);
        (, bool fresh, uint256 nav,,) = hook.riskState(wallet);
        assertTrue(fresh);
        assertEq(nav, 500 * U + 500 * U + 120_000 * U);
    }

    function test_riskStateBeforeAnySnapshot() public view {
        (bool blockBuys, bool fresh, uint256 nav, uint256 startNav, uint256 loss) = hook.riskState(wallet);
        assertFalse(blockBuys);
        assertTrue(fresh);
        assertEq(nav, 1000 * U);
        assertEq(startNav, nav);
        assertEq(loss, 0);
    }
}

contract MockToken {
    uint8 public constant decimals = 8;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }
}

contract MockFeedLike {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 60_000e8, block.timestamp, block.timestamp, 1);
    }
}
