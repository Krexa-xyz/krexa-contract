// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {MerchantVault} from "../src/MerchantVault.sol";
import {IMerchantVault} from "../src/interfaces/IMerchantVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {Errors} from "../src/libraries/Errors.sol";

contract LateFeesTest is Test {
    MerchantVault public vault;
    MockUSDC public usdc;

    address admin = makeAddr("admin");
    address agent = makeAddr("agent");
    address investor = makeAddr("investor");
    address fakeRouter = makeAddr("fakeRouter");

    uint256 constant TARGET = 60_000e6;    // 60k USDC
    uint256 constant DURATION = 180 days;   // 6 months = 6 periods
    uint16 constant LATE_FEE_BPS = 100;     // 1% per day on shortfall
    uint256 constant GRACE = 7 days;

    function setUp() public {
        usdc = new MockUSDC();

        vault = new MerchantVault(
            MerchantVault.VaultParams({
                usdc: address(usdc),
                agent: agent,
                admin: admin,
                factory: admin,
                targetAmount: TARGET,
                interestRateBps: 1200,   // 12%
                durationSeconds: DURATION,
                numTranches: 3,
                platformFeeBps: 0,       // Zero platform fee for clean math
                platformFeeRecipient: admin,
                lateFeeBps: LATE_FEE_BPS,
                gracePeriodSeconds: GRACE,
                fundraisingDeadline: type(uint256).max
            })
        );

        vm.prank(admin);
        vault.setPaymentRouter(fakeRouter);

        // Fund vault to Active state
        usdc.mint(investor, TARGET);
        vm.startPrank(investor);
        usdc.approve(address(vault), TARGET);
        vault.invest(TARGET);
        vm.stopPrank();

        // Approve router to pull USDC for repayments
        usdc.mint(fakeRouter, 1_000_000e6);
        vm.prank(fakeRouter);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ════════════════════════════════════════════════════════════════
    // Basic Late Fee Logic
    // ════════════════════════════════════════════════════════════════

    function test_noLateFee_whenOnTime() public {
        // Repay before nextPaymentDue — no late fee
        uint256 repayAmount = 10_000e6;
        uint256 totalToRepayBefore = vault.totalToRepay();

        vm.prank(fakeRouter);
        vault.processRepayment(repayAmount);

        assertEq(vault.totalToRepay(), totalToRepayBefore); // Unchanged
        assertEq(vault.totalLateFees(), 0);
    }

    function test_lateFee_calculatedCorrectly() public {
        // Warp past first payment due date by 5 days
        uint256 due = vault.nextPaymentDue();
        vm.warp(due + 5 days);

        uint256 fee = vault.calculateLateFee();
        assertTrue(fee > 0, "Expected non-zero late fee");

        // Verify formula: shortfall * lateFeeBps * daysLate / 10_000
        // periods elapsed = (due + 5 days - activatedAt) / 30 days = 1 (approx)
        // expectedCumulative = 1 * expectedRepaymentPerPeriod
        // shortfall = expectedCumulative - 0 (no repayments yet)
        // daysLate = 5 (capped at 30)
        uint256 periods = (block.timestamp - vault.activatedAt()) / vault.REPAYMENT_INTERVAL();
        uint256 expectedCumulative = periods * vault.expectedRepaymentPerPeriod();
        if (expectedCumulative > vault.totalToRepay()) expectedCumulative = vault.totalToRepay();
        uint256 shortfall = expectedCumulative - vault.totalRepaid();
        uint256 daysLate = (block.timestamp - due) / 1 days;
        uint256 expectedFee = (shortfall * LATE_FEE_BPS * daysLate) / 10_000;

        assertEq(fee, expectedFee);
    }

    function test_lateFee_appliedInProcessRepayment() public {
        uint256 due = vault.nextPaymentDue();
        vm.warp(due + 5 days);

        uint256 lateFee = vault.calculateLateFee();
        assertTrue(lateFee > 0);

        vm.expectEmit(false, false, false, false); // just check it fires
        emit IMerchantVault.LateFeeApplied(lateFee, lateFee);

        vm.prank(fakeRouter);
        vault.processRepayment(1_000e6);

        // New model: late fees go to accruedInterest, not totalToRepay
        assertEq(vault.totalLateFees(), lateFee);
        // totalToRepay unchanged (it's a static estimate from activation)
    }

    function test_lateFee_multiplePeriodsLate() public {
        // Warp 65 days past the first nextPaymentDue (2+ full periods late)
        uint256 due = vault.nextPaymentDue();
        vm.warp(due + 65 days);

        uint256 fee = vault.calculateLateFee();

        // daysLate should be capped at 30 (REPAYMENT_INTERVAL / 1 days)
        // Manually compute: daysLate raw = 65, but capped at 30
        uint256 periods = (block.timestamp - vault.activatedAt()) / vault.REPAYMENT_INTERVAL();
        uint256 expectedCumulative = periods * vault.expectedRepaymentPerPeriod();
        if (expectedCumulative > vault.totalToRepay()) expectedCumulative = vault.totalToRepay();
        uint256 shortfall = expectedCumulative;
        uint256 cappedDaysLate = 30; // cap
        uint256 expectedFee = (shortfall * LATE_FEE_BPS * cappedDaysLate) / 10_000;

        assertEq(fee, expectedFee, "Fee should use capped daysLate");
    }

    function test_nextPaymentDue_advances() public {
        uint256 due = vault.nextPaymentDue();
        vm.warp(due + 5 days);

        vm.prank(fakeRouter);
        vault.processRepayment(1_000e6);

        // nextPaymentDue should have advanced past block.timestamp
        assertTrue(vault.nextPaymentDue() > block.timestamp);
    }

    function test_lateFee_zeroWhenNotConfigured() public {
        // Create a vault with lateFeeBps = 0
        MerchantVault noFeeVault = new MerchantVault(
            MerchantVault.VaultParams({
                usdc: address(usdc),
                agent: agent,
                admin: admin,
                factory: admin,
                targetAmount: TARGET,
                interestRateBps: 1200,
                durationSeconds: DURATION,
                numTranches: 3,
                platformFeeBps: 0,
                platformFeeRecipient: admin,
                lateFeeBps: 0,          // No late fees
                gracePeriodSeconds: GRACE,
                fundraisingDeadline: type(uint256).max
            })
        );

        // Fund it
        usdc.mint(investor, TARGET);
        vm.startPrank(investor);
        usdc.approve(address(noFeeVault), TARGET);
        noFeeVault.invest(TARGET);
        vm.stopPrank();

        // Warp way past due
        vm.warp(block.timestamp + 60 days);
        assertEq(noFeeVault.calculateLateFee(), 0);
    }

    // ════════════════════════════════════════════════════════════════
    // shouldDefault
    // ════════════════════════════════════════════════════════════════

    function test_shouldDefault_afterGracePeriod() public {
        uint256 due = vault.nextPaymentDue();
        vm.warp(due + GRACE + 1 seconds);
        assertTrue(vault.shouldDefault());
    }

    function test_shouldNotDefault_withinGracePeriod() public {
        uint256 due = vault.nextPaymentDue();
        // Warp past due but within grace period
        vm.warp(due + GRACE - 1 seconds);
        assertFalse(vault.shouldDefault());
    }
}
