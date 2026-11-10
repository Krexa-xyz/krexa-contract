// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ServicePlan} from "../src/ServicePlan.sol";
import {IServicePlan} from "../src/interfaces/IServicePlan.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {Errors} from "../src/libraries/Errors.sol";

contract ServicePlanTest is Test {
    MockUSDC public usdc;
    ServicePlan public sp;

    address admin = makeAddr("admin");
    address oracle = makeAddr("oracle");
    address agentWallet = makeAddr("agentWallet");
    address vendor1 = makeAddr("vendor1");
    address vendor2 = makeAddr("vendor2");
    address funder = makeAddr("funder");

    function setUp() public {
        usdc = new MockUSDC();
        sp = new ServicePlan(address(usdc), admin, oracle);
    }

    // ════════════════════════════════════════════════════════════════
    // 1. Plan Creation
    // ════════════════════════════════════════════════════════════════

    function test_createPlan_basic() public {
        _createDefaultPlan();

        IServicePlan.Plan memory plan = sp.getPlan(agentWallet);
        assertEq(plan.agentWallet, agentWallet);
        assertEq(plan.totalCredit, 10_000e6);
        assertEq(plan.milestoneCount, 3);
        assertEq(uint8(plan.health), uint8(IServicePlan.ServiceHealth.Green));
        assertEq(uint8(plan.windDownState), uint8(IServicePlan.WindDownState.None));
        assertEq(plan.totalDisbursed, 0);
    }

    function test_createPlan_duplicateReverts() public {
        _createDefaultPlan();

        IServicePlan.MilestoneInput[] memory ms = new IServicePlan.MilestoneInput[](1);
        ms[0] = IServicePlan.MilestoneInput(1000e6, keccak256("m1"), block.timestamp);

        vm.prank(oracle);
        vm.expectRevert(Errors.PlanAlreadyExists.selector);
        sp.createPlan(agentWallet, 10_000e6, ms);
    }

    function test_createPlan_sumExceedsCreditReverts() public {
        IServicePlan.MilestoneInput[] memory ms = new IServicePlan.MilestoneInput[](2);
        ms[0] = IServicePlan.MilestoneInput(6000e6, keccak256("m1"), block.timestamp);
        ms[1] = IServicePlan.MilestoneInput(6000e6, keccak256("m2"), block.timestamp);

        vm.prank(oracle);
        vm.expectRevert(Errors.MilestoneSumExceedsCredit.selector);
        sp.createPlan(agentWallet, 10_000e6, ms);
    }

    function test_createPlan_maxMilestonesReverts() public {
        IServicePlan.MilestoneInput[] memory ms = new IServicePlan.MilestoneInput[](9);
        for (uint256 i = 0; i < 9; i++) {
            ms[i] = IServicePlan.MilestoneInput(100e6, keccak256(abi.encodePacked(i)), block.timestamp);
        }

        vm.prank(oracle);
        vm.expectRevert(Errors.MaxMilestonesReached.selector);
        sp.createPlan(agentWallet, 10_000e6, ms);
    }

    function test_createPlan_onlyAdminOrOracle() public {
        IServicePlan.MilestoneInput[] memory ms = new IServicePlan.MilestoneInput[](0);

        vm.prank(funder);
        vm.expectRevert(Errors.OnlyAdminOrOracle.selector);
        sp.createPlan(agentWallet, 10_000e6, ms);
    }

    // ════════════════════════════════════════════════════════════════
    // 2. Fund Plan
    // ════════════════════════════════════════════════════════════════

    function test_fundPlan() public {
        _createDefaultPlan();

        usdc.mint(funder, 10_000e6);
        vm.startPrank(funder);
        usdc.approve(address(sp), 10_000e6);
        sp.fundPlan(agentWallet, 10_000e6);
        vm.stopPrank();

        assertEq(sp.getPlanBalance(agentWallet), 10_000e6);
    }

    function test_fundPlan_notFoundReverts() public {
        vm.expectRevert(Errors.PlanNotFound.selector);
        sp.fundPlan(makeAddr("nobody"), 1000e6);
    }

    // ════════════════════════════════════════════════════════════════
    // 3. Milestone Disbursement
    // ════════════════════════════════════════════════════════════════

    function test_disburseMilestone_success() public {
        _createAndFundPlan();

        // Milestone 0 is eligible at block.timestamp, so it should disburse
        vm.prank(oracle);
        sp.disburseMilestone(agentWallet, 0);

        IServicePlan.MilestoneData memory ms = sp.getMilestone(agentWallet, 0);
        assertTrue(ms.disbursed);
        assertTrue(ms.disbursedAt > 0);

        IServicePlan.Plan memory plan = sp.getPlan(agentWallet);
        assertEq(plan.totalDisbursed, 3000e6);

        assertEq(usdc.balanceOf(agentWallet), 3000e6);
        assertEq(sp.getPlanBalance(agentWallet), 7000e6);
    }

    function test_disburseMilestone_notEligibleReverts() public {
        _createAndFundPlan();

        // Milestone 2 has eligibleAt = block.timestamp + 90 days
        vm.prank(oracle);
        vm.expectRevert(Errors.MilestoneNotEligible.selector);
        sp.disburseMilestone(agentWallet, 2);
    }

    function test_disburseMilestone_alreadyDisbursedReverts() public {
        _createAndFundPlan();

        vm.prank(oracle);
        sp.disburseMilestone(agentWallet, 0);

        vm.prank(oracle);
        vm.expectRevert(Errors.MilestoneAlreadyDisbursed.selector);
        sp.disburseMilestone(agentWallet, 0);
    }

    function test_disburseMilestone_orangeHealthBlocked() public {
        _createAndFundPlan();
        _setHealthTo(IServicePlan.ServiceHealth.Orange);

        vm.prank(oracle);
        vm.expectRevert(Errors.DisbursementsPaused.selector);
        sp.disburseMilestone(agentWallet, 0);
    }

    function test_disburseMilestone_redHealthBlocked() public {
        _createAndFundPlan();
        _setHealthTo(IServicePlan.ServiceHealth.Red);

        vm.prank(oracle);
        vm.expectRevert(Errors.DisbursementsPaused.selector);
        sp.disburseMilestone(agentWallet, 0);
    }

    function test_disburseMilestone_yellowDelays7Days() public {
        _createAndFundPlan();
        _setHealthTo(IServicePlan.ServiceHealth.Yellow);

        // Milestone 0 eligible at block.timestamp, but Yellow adds 7-day delay
        vm.prank(oracle);
        vm.expectRevert(Errors.MilestoneDelayed.selector);
        sp.disburseMilestone(agentWallet, 0);

        // Warp past the delay
        vm.warp(block.timestamp + 604_801);

        vm.prank(oracle);
        sp.disburseMilestone(agentWallet, 0);

        assertTrue(sp.getMilestone(agentWallet, 0).disbursed);
    }

    function test_disburseMilestone_windDownBlocked() public {
        _createAndFundPlan();
        _setHealthTo(IServicePlan.ServiceHealth.Red);

        vm.prank(oracle);
        sp.startWindDown(agentWallet);

        // Try to disburse during wind-down
        // First fix health back to allow disburse check to reach windDown check
        // Actually windDown check comes first, so it reverts InWindDown
        vm.prank(oracle);
        vm.expectRevert(Errors.InWindDown.selector);
        sp.disburseMilestone(agentWallet, 0);
    }

    function test_disburseMilestone_onlyOracle() public {
        _createAndFundPlan();

        vm.prank(funder);
        vm.expectRevert(Errors.OnlyOracle.selector);
        sp.disburseMilestone(agentWallet, 0);
    }

    // ════════════════════════════════════════════════════════════════
    // 4. Expense Destinations
    // ════════════════════════════════════════════════════════════════

    function test_addExpenseDestination() public {
        _createDefaultPlan();

        vm.prank(oracle);
        sp.addExpenseDestination(agentWallet, vendor1, keccak256("AWS"), 0, 500e6);

        IServicePlan.ExpenseDestination memory dest = sp.getExpenseDestination(agentWallet, vendor1);
        assertTrue(dest.isActive);
        assertEq(dest.category, 0); // infrastructure
        assertEq(dest.maxAmount, 500e6);

        IServicePlan.Plan memory plan = sp.getPlan(agentWallet);
        assertEq(plan.expenseDestCount, 1);
    }

    function test_removeExpenseDestination() public {
        _createDefaultPlan();

        vm.prank(oracle);
        sp.addExpenseDestination(agentWallet, vendor1, keccak256("AWS"), 0, 500e6);

        vm.prank(oracle);
        sp.removeExpenseDestination(agentWallet, vendor1);

        IServicePlan.ExpenseDestination memory dest = sp.getExpenseDestination(agentWallet, vendor1);
        assertFalse(dest.isActive);

        assertEq(sp.getPlan(agentWallet).expenseDestCount, 0);
    }

    function test_executeExpense() public {
        _createDefaultPlan();

        vm.prank(oracle);
        sp.addExpenseDestination(agentWallet, vendor1, keccak256("AWS"), 0, 500e6);

        // Fund agent wallet with USDC and approve ServicePlan
        usdc.mint(agentWallet, 1000e6);
        vm.prank(agentWallet);
        usdc.approve(address(sp), 1000e6);

        // Oracle executes expense
        vm.prank(oracle);
        sp.executeExpense(agentWallet, vendor1, 200e6);

        assertEq(usdc.balanceOf(vendor1), 200e6);

        IServicePlan.ExpenseDestination memory dest = sp.getExpenseDestination(agentWallet, vendor1);
        assertEq(dest.totalSent, 200e6);
    }

    function test_executeExpense_exceedsLimitReverts() public {
        _createDefaultPlan();

        vm.prank(oracle);
        sp.addExpenseDestination(agentWallet, vendor1, keccak256("AWS"), 0, 500e6);

        usdc.mint(agentWallet, 1000e6);
        vm.prank(agentWallet);
        usdc.approve(address(sp), 1000e6);

        vm.prank(oracle);
        vm.expectRevert(Errors.ExceedsExpenseLimit.selector);
        sp.executeExpense(agentWallet, vendor1, 501e6);
    }

    function test_executeExpense_inactiveDestReverts() public {
        _createDefaultPlan();

        vm.prank(oracle);
        vm.expectRevert(Errors.ExpenseDestNotActive.selector);
        sp.executeExpense(agentWallet, vendor1, 100e6);
    }

    function test_executeExpense_windDownExecutingBlocked() public {
        _createAndFundPlan();
        _setHealthTo(IServicePlan.ServiceHealth.Red);

        vm.prank(oracle);
        sp.addExpenseDestination(agentWallet, vendor1, keccak256("AWS"), 0, 0);

        vm.prank(oracle);
        sp.startWindDown(agentWallet);

        // Advance to Executing
        vm.warp(block.timestamp + 172_801);
        sp.advanceWindDown(agentWallet);

        vm.prank(oracle);
        vm.expectRevert(Errors.InWindDown.selector);
        sp.executeExpense(agentWallet, vendor1, 100e6);
    }

    function test_addExpenseDestination_invalidCategoryReverts() public {
        _createDefaultPlan();

        vm.prank(oracle);
        vm.expectRevert(Errors.InvalidCategory.selector);
        sp.addExpenseDestination(agentWallet, vendor1, keccak256("bad"), 5, 0);
    }

    // ════════════════════════════════════════════════════════════════
    // 5. Revenue Monitoring & Health Zones
    // ════════════════════════════════════════════════════════════════

    function test_computeHealth_green() public view {
        // 80%+ of projected → Green
        assertEq(uint8(sp.computeHealth(8000, 10000, 0)), uint8(IServicePlan.ServiceHealth.Green));
    }

    function test_computeHealth_yellow() public view {
        // 50-79% → Yellow
        assertEq(uint8(sp.computeHealth(5000, 10000, 0)), uint8(IServicePlan.ServiceHealth.Yellow));
    }

    function test_computeHealth_orange() public view {
        // 25-49% → Orange
        assertEq(uint8(sp.computeHealth(2500, 10000, 0)), uint8(IServicePlan.ServiceHealth.Orange));
    }

    function test_computeHealth_red() public view {
        // < 25% → Red
        assertEq(uint8(sp.computeHealth(2499, 10000, 0)), uint8(IServicePlan.ServiceHealth.Red));
    }

    function test_computeHealth_zeroRevenueOrange() public view {
        // 7 zero-revenue days → Orange (overrides revenue ratio)
        assertEq(uint8(sp.computeHealth(10000, 10000, 7)), uint8(IServicePlan.ServiceHealth.Orange));
    }

    function test_computeHealth_zeroRevenueRed() public view {
        // 14 zero-revenue days → Red
        assertEq(uint8(sp.computeHealth(10000, 10000, 14)), uint8(IServicePlan.ServiceHealth.Red));
    }

    function test_computeHealth_noProjectionGreen() public view {
        // No projection set → always Green
        assertEq(uint8(sp.computeHealth(0, 0, 0)), uint8(IServicePlan.ServiceHealth.Green));
    }

    function test_recordRevenue_updatesHealth() public {
        _createDefaultPlan();

        // Set projected revenue
        vm.prank(oracle);
        sp.setProjectedRevenue(agentWallet, 10_000e6);

        // Record 8000 → should be Green (80%)
        vm.prank(oracle);
        sp.recordRevenue(agentWallet, 8000e6);

        IServicePlan.Plan memory plan = sp.getPlan(agentWallet);
        assertEq(plan.actualRevenueThisPeriod, 8000e6);
        assertEq(uint8(plan.health), uint8(IServicePlan.ServiceHealth.Green));
        assertEq(plan.zeroRevenueDays, 0);
    }

    function test_recordRevenue_lowRevenueYellow() public {
        _createDefaultPlan();

        vm.prank(oracle);
        sp.setProjectedRevenue(agentWallet, 10_000e6);

        // Record 5000 → Yellow (50%)
        vm.prank(oracle);
        sp.recordRevenue(agentWallet, 5000e6);

        assertEq(uint8(sp.getPlan(agentWallet).health), uint8(IServicePlan.ServiceHealth.Yellow));
    }

    function test_updateZeroRevenueDays_triggersHealthChange() public {
        _createDefaultPlan();

        vm.prank(oracle);
        sp.setProjectedRevenue(agentWallet, 10_000e6);

        // Record enough revenue to be green
        vm.prank(oracle);
        sp.recordRevenue(agentWallet, 10_000e6);

        // 14 zero-revenue days → Red override
        vm.prank(oracle);
        sp.updateZeroRevenueDays(agentWallet, 14);

        assertEq(uint8(sp.getPlan(agentWallet).health), uint8(IServicePlan.ServiceHealth.Red));
    }

    function test_setProjectedRevenue_resetsPeriod() public {
        _createDefaultPlan();

        vm.prank(oracle);
        sp.setProjectedRevenue(agentWallet, 10_000e6);

        vm.prank(oracle);
        sp.recordRevenue(agentWallet, 5000e6);

        // Start new period → resets actual revenue
        vm.prank(oracle);
        sp.setProjectedRevenue(agentWallet, 20_000e6);

        IServicePlan.Plan memory plan = sp.getPlan(agentWallet);
        assertEq(plan.actualRevenueThisPeriod, 0);
        assertEq(plan.projectedMonthlyRevenue, 20_000e6);
    }

    function test_recordRevenue_onlyOracle() public {
        _createDefaultPlan();

        vm.prank(funder);
        vm.expectRevert(Errors.OnlyOracle.selector);
        sp.recordRevenue(agentWallet, 1000e6);
    }

    // ════════════════════════════════════════════════════════════════
    // 6. Wind-Down
    // ════════════════════════════════════════════════════════════════

    function test_windDown_fullLifecycle() public {
        _createAndFundPlan();
        _setHealthTo(IServicePlan.ServiceHealth.Red);

        // Start wind-down
        vm.prank(oracle);
        sp.startWindDown(agentWallet);

        IServicePlan.Plan memory plan = sp.getPlan(agentWallet);
        assertEq(uint8(plan.windDownState), uint8(IServicePlan.WindDownState.Grace));

        // Cannot advance before grace period
        vm.expectRevert(Errors.GracePeriodNotElapsed.selector);
        sp.advanceWindDown(agentWallet);

        // Warp past 48h grace
        vm.warp(block.timestamp + 172_801);

        // Grace → Executing (permissionless)
        sp.advanceWindDown(agentWallet);
        assertEq(uint8(sp.getPlan(agentWallet).windDownState), uint8(IServicePlan.WindDownState.Executing));

        // Executing → Completed
        sp.advanceWindDown(agentWallet);
        assertEq(uint8(sp.getPlan(agentWallet).windDownState), uint8(IServicePlan.WindDownState.Completed));

        // Cannot advance further
        vm.expectRevert(Errors.InvalidWindDownTransition.selector);
        sp.advanceWindDown(agentWallet);
    }

    function test_windDown_requiresRedHealth() public {
        _createDefaultPlan();

        vm.prank(oracle);
        vm.expectRevert(Errors.HealthNotRed.selector);
        sp.startWindDown(agentWallet);
    }

    function test_windDown_doubleStartReverts() public {
        _createAndFundPlan();
        _setHealthTo(IServicePlan.ServiceHealth.Red);

        vm.prank(oracle);
        sp.startWindDown(agentWallet);

        vm.prank(oracle);
        vm.expectRevert(Errors.WindDownAlreadyStarted.selector);
        sp.startWindDown(agentWallet);
    }

    function test_windDown_graceAllowsExpenses() public {
        _createAndFundPlan();

        vm.prank(oracle);
        sp.addExpenseDestination(agentWallet, vendor1, keccak256("AWS"), 0, 0);

        usdc.mint(agentWallet, 1000e6);
        vm.prank(agentWallet);
        usdc.approve(address(sp), 1000e6);

        _setHealthTo(IServicePlan.ServiceHealth.Red);

        vm.prank(oracle);
        sp.startWindDown(agentWallet);

        // Grace state still allows expenses
        vm.prank(oracle);
        sp.executeExpense(agentWallet, vendor1, 100e6);
        assertEq(usdc.balanceOf(vendor1), 100e6);
    }

    // ════════════════════════════════════════════════════════════════
    // 7. Pause
    // ════════════════════════════════════════════════════════════════

    function test_pause_blocksOperations() public {
        _createDefaultPlan();

        vm.prank(admin);
        sp.pause();

        vm.prank(oracle);
        vm.expectRevert(Errors.PlatformPaused.selector);
        sp.recordRevenue(agentWallet, 100e6);
    }

    function test_unpause_resumesOperations() public {
        _createDefaultPlan();

        vm.prank(admin);
        sp.pause();
        vm.prank(admin);
        sp.unpause();

        vm.prank(oracle);
        sp.recordRevenue(agentWallet, 100e6); // should succeed
    }

    // ════════════════════════════════════════════════════════════════
    // 8. Milestone Views
    // ════════════════════════════════════════════════════════════════

    function test_getMilestone_allSlots() public {
        _createDefaultPlan();

        IServicePlan.MilestoneData memory ms0 = sp.getMilestone(agentWallet, 0);
        assertEq(ms0.amount, 3000e6);
        assertTrue(ms0.isActive);
        assertFalse(ms0.disbursed);

        IServicePlan.MilestoneData memory ms1 = sp.getMilestone(agentWallet, 1);
        assertEq(ms1.amount, 3000e6);

        IServicePlan.MilestoneData memory ms2 = sp.getMilestone(agentWallet, 2);
        assertEq(ms2.amount, 4000e6);
    }

    function test_getMilestone_outOfBoundsReverts() public {
        vm.expectRevert(Errors.MilestoneOutOfBounds.selector);
        sp.getMilestone(agentWallet, 8);
    }

    // ════════════════════════════════════════════════════════════════
    // Helpers
    // ════════════════════════════════════════════════════════════════

    function _createDefaultPlan() internal {
        IServicePlan.MilestoneInput[] memory ms = new IServicePlan.MilestoneInput[](3);
        ms[0] = IServicePlan.MilestoneInput(3000e6, keccak256("Phase 1"), block.timestamp);
        ms[1] = IServicePlan.MilestoneInput(3000e6, keccak256("Phase 2"), block.timestamp + 30 days);
        ms[2] = IServicePlan.MilestoneInput(4000e6, keccak256("Phase 3"), block.timestamp + 90 days);

        vm.prank(oracle);
        sp.createPlan(agentWallet, 10_000e6, ms);
    }

    function _createAndFundPlan() internal {
        _createDefaultPlan();

        usdc.mint(funder, 10_000e6);
        vm.startPrank(funder);
        usdc.approve(address(sp), 10_000e6);
        sp.fundPlan(agentWallet, 10_000e6);
        vm.stopPrank();
    }

    function _setHealthTo(IServicePlan.ServiceHealth health) internal {
        vm.startPrank(oracle);
        sp.setProjectedRevenue(agentWallet, 10_000e6);

        if (health == IServicePlan.ServiceHealth.Green) {
            sp.recordRevenue(agentWallet, 8000e6);
        } else if (health == IServicePlan.ServiceHealth.Yellow) {
            sp.recordRevenue(agentWallet, 5000e6);
        } else if (health == IServicePlan.ServiceHealth.Orange) {
            sp.recordRevenue(agentWallet, 2500e6);
        } else {
            sp.recordRevenue(agentWallet, 1000e6); // < 25% → Red
        }
        vm.stopPrank();
    }
}
