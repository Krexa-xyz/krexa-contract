// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {MerchantVault} from "../src/MerchantVault.sol";
import {IMerchantVault} from "../src/interfaces/IMerchantVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {Errors} from "../src/libraries/Errors.sol";

/// @notice Tests for Solana-parity features: continuous interest accrual,
///         tranche yield waterfall, insurance fund, credit freeze, treasury.
contract MerchantVaultSolanaTest is Test {
    MockUSDC public usdc;
    MerchantVault public vault;

    address admin = makeAddr("admin");
    address agent = makeAddr("translateBot");
    address router = makeAddr("router");
    address feeRecipient = makeAddr("feeRecipient");
    address treasuryAddr = makeAddr("treasury");
    address senior = makeAddr("alphaVault");
    address poolInvestor = makeAddr("poolLP");
    address community = makeAddr("yieldBot");

    uint256 constant TARGET = 50_000e6;

    function setUp() public {
        usdc = new MockUSDC();
        vault = new MerchantVault(MerchantVault.VaultParams({
            usdc: address(usdc),
            agent: agent,
            admin: admin,
            factory: address(this),
            targetAmount: TARGET,
            interestRateBps: 1200,
            durationSeconds: 365 days,
            numTranches: 4,
            platformFeeBps: 0,
            platformFeeRecipient: feeRecipient,
            lateFeeBps: 0,
            gracePeriodSeconds: 0,
            fundraisingDeadline: type(uint256).max
        }));

        vm.startPrank(admin);
        vault.setPaymentRouter(router);
        vault.setTreasury(treasuryAddr);
        vm.stopPrank();

        usdc.mint(senior, 200_000e6);
        usdc.mint(poolInvestor, 200_000e6);
        usdc.mint(community, 200_000e6);
        usdc.mint(router, 500_000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════

    function _fundVault() internal {
        vm.startPrank(senior);
        usdc.approve(address(vault), 30_000e6);
        vault.investSenior(30_000e6);
        vm.stopPrank();

        vm.startPrank(poolInvestor);
        usdc.approve(address(vault), 15_000e6);
        vault.investFromPool(15_000e6);
        vm.stopPrank();

        vm.startPrank(community);
        usdc.approve(address(vault), 5_000e6);
        vault.invest(5_000e6);
        vm.stopPrank();
    }

    function _repay(uint256 amount) internal {
        vm.startPrank(router);
        usdc.approve(address(vault), amount);
        vault.processRepayment(amount);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    // Continuous Interest Accrual
    // ═══════════════════════════════════════════════════════════════

    function test_accrueInterest_initial() public {
        _fundVault();
        assertEq(vault.accruedInterest(), 0);
        assertEq(vault.creditDrawn(), TARGET);
    }

    function test_accrueInterest_afterTime() public {
        _fundVault();
        vm.warp(block.timestamp + 30 days);
        vault.accrueInterest();

        uint256 expected = (TARGET * 1200 * 30 days) / (10_000 * 365 days);
        assertEq(vault.accruedInterest(), expected);
    }

    function test_accrueInterest_permissionless() public {
        _fundVault();
        vm.warp(block.timestamp + 1 days);
        vm.prank(makeAddr("random"));
        vault.accrueInterest();
        assertTrue(vault.accruedInterest() > 0);
    }

    function test_accrueInterest_idempotent() public {
        _fundVault();
        vm.warp(block.timestamp + 30 days);
        vault.accrueInterest();
        uint256 first = vault.accruedInterest();
        vault.accrueInterest();
        assertEq(vault.accruedInterest(), first);
    }

    function test_accrueInterest_cumulative() public {
        _fundVault();
        uint256 t0 = block.timestamp;

        vm.warp(t0 + 30 days);
        vault.accrueInterest();
        uint256 after30 = vault.accruedInterest();
        assertTrue(after30 > 0);
        assertEq(vault.lastAccrualTimestamp(), t0 + 30 days);

        vm.warp(t0 + 60 days);
        vault.accrueInterest();
        uint256 after60 = vault.accruedInterest();
        // Second period adds more interest
        assertTrue(after60 > after30);
    }

    function test_accrueInterest_noopInFundraising() public {
        vault.accrueInterest();
        assertEq(vault.accruedInterest(), 0);
    }

    function test_totalDebt() public {
        _fundVault();
        vm.warp(block.timestamp + 30 days);
        vault.accrueInterest();
        assertEq(vault.totalDebt(), vault.creditDrawn() + vault.accruedInterest());
    }

    // ═══════════════════════════════════════════════════════════════
    // Repayment — Interest vs Principal
    // ═══════════════════════════════════════════════════════════════

    function test_repayment_interestFirst() public {
        _fundVault();
        vm.warp(block.timestamp + 30 days);

        uint256 creditBefore = vault.creditDrawn();
        _repay(100e6);

        // Small repayment only covers interest — principal unchanged
        assertEq(vault.creditDrawn(), creditBefore);
    }

    function test_repayment_principalAfterInterest() public {
        _fundVault();
        vm.warp(block.timestamp + 30 days);
        vault.accrueInterest();
        uint256 interest = vault.accruedInterest();

        _repay(interest + 1_000e6);

        assertEq(vault.accruedInterest(), 0);
        assertEq(vault.creditDrawn(), TARGET - 1_000e6);
    }

    function test_repayment_protocolFee() public {
        _fundVault();
        vm.warp(block.timestamp + 30 days);
        vault.accrueInterest();

        uint256 insuranceBefore = vault.insuranceBalance();
        _repay(vault.accruedInterest());

        assertTrue(vault.insuranceBalance() > insuranceBefore);
    }

    function test_repayment_completion() public {
        _fundVault();
        vm.warp(block.timestamp + 30 days);
        vault.accrueInterest();

        _repay(vault.creditDrawn() + vault.accruedInterest());

        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Completed));
        assertEq(vault.creditDrawn(), 0);
        assertEq(vault.accruedInterest(), 0);
    }

    function test_repay_zeroReverts() public {
        _fundVault();
        vm.prank(router);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.processRepayment(0);
    }

    function test_repay_onlyRouter() public {
        _fundVault();
        vm.prank(senior);
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.processRepayment(1_000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    // Tranche Yield Waterfall
    // ═══════════════════════════════════════════════════════════════

    function test_trancheYield_seniorPaid() public {
        _fundVault();
        vm.warp(block.timestamp + 90 days);
        vault.accrueInterest();
        _repay(vault.accruedInterest());
        assertTrue(vault.seniorYieldPaid() > 0);
    }

    function test_trancheYield_poolPaid() public {
        _fundVault();
        vm.warp(block.timestamp + 90 days);
        vault.accrueInterest();
        _repay(vault.accruedInterest());
        assertTrue(vault.poolYieldPaid() > 0);
    }

    function test_trancheYield_communityPaid() public {
        _fundVault();
        vm.warp(block.timestamp + 90 days);
        vault.accrueInterest();
        _repay(vault.accruedInterest());
        assertTrue(vault.communityYieldPaid() > 0);
    }

    function test_trancheYield_seniorFirst() public {
        _fundVault();
        vm.warp(block.timestamp + 90 days);
        // Small repayment — only enough for partial senior yield
        _repay(50e6);
        assertTrue(vault.seniorYieldPaid() > 0);
    }

    function test_trancheYield_1yr_seniorAmount() public {
        _fundVault();
        vm.warp(block.timestamp + 365 days);
        vault.accrueInterest();
        _repay(vault.accruedInterest());
        // Senior: 30K * 8% = 2400
        assertApproxEqAbs(vault.seniorYieldPaid(), 2_400e6, 10e6);
    }

    function test_trancheYield_1yr_poolAmount() public {
        _fundVault();
        vm.warp(block.timestamp + 365 days);
        vault.accrueInterest();
        _repay(vault.accruedInterest());
        // Pool: 15K * 12% = 1800
        assertApproxEqAbs(vault.poolYieldPaid(), 1_800e6, 10e6);
    }

    function test_trancheYield_1yr_communityAmount() public {
        _fundVault();
        vm.warp(block.timestamp + 365 days);
        vault.accrueInterest();
        _repay(vault.accruedInterest());
        // Community: 5K * 20% = 1000
        assertApproxEqAbs(vault.communityYieldPaid(), 1_000e6, 10e6);
    }

    // ═══════════════════════════════════════════════════════════════
    // Insurance Fund
    // ═══════════════════════════════════════════════════════════════

    function test_insurance_builtFromRepayment() public {
        _fundVault();
        vm.warp(block.timestamp + 90 days);
        vault.accrueInterest();
        _repay(vault.accruedInterest());
        assertTrue(vault.insuranceBalance() > 0);
    }

    function test_insurance_protocolFeeIs10pct() public {
        _fundVault();
        vm.warp(block.timestamp + 365 days);
        vault.accrueInterest();
        // 50K * 12% = ~6000e6
        assertApproxEqAbs(vault.accruedInterest(), 6_000e6, 1e6);

        _repay(vault.accruedInterest());
        // Protocol fee = 10% of 6000 = 600 → insurance gets at least that
        assertTrue(vault.insuranceBalance() >= 590e6);
    }

    function test_insurance_treasuryReceivesSurplus() public {
        _fundVault();
        vm.warp(block.timestamp + 365 days);
        vault.accrueInterest();

        uint256 treasuryBefore = usdc.balanceOf(treasuryAddr);
        _repay(vault.accruedInterest());

        assertTrue(usdc.balanceOf(treasuryAddr) > treasuryBefore);
    }

    // ═══════════════════════════════════════════════════════════════
    // Credit Freeze
    // ═══════════════════════════════════════════════════════════════

    function test_freeze_adminOnly() public {
        vm.expectRevert(Errors.Unauthorized.selector);
        vm.prank(makeAddr("random"));
        vault.freezeCredit();
    }

    function test_freeze_blocksTrancheRelease() public {
        _fundVault();
        vm.prank(admin);
        vault.freezeCredit();
        assertTrue(vault.isFrozen());

        vm.prank(admin);
        vm.expectRevert(Errors.VaultPaused.selector);
        vault.releaseTranche();
    }

    function test_unfreeze_allowsRelease() public {
        _fundVault();
        vm.prank(admin);
        vault.freezeCredit();
        vm.prank(admin);
        vault.unfreezeCredit();
        assertFalse(vault.isFrozen());

        vm.prank(admin);
        vault.releaseTranche();
        assertEq(vault.tranchesReleased(), 1);
    }

    function test_freeze_repaymentStillWorks() public {
        _fundVault();
        vm.prank(admin);
        vault.freezeCredit();
        vm.warp(block.timestamp + 30 days);
        _repay(1_000e6);
        assertTrue(vault.totalRepaid() > 0);
    }

    // ═══════════════════════════════════════════════════════════════
    // Treasury
    // ═══════════════════════════════════════════════════════════════

    function test_setTreasury() public {
        address t2 = makeAddr("t2");
        vm.prank(admin);
        vault.setTreasury(t2);
        assertEq(vault.treasury(), t2);
    }

    function test_setTreasury_zeroReverts() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.setTreasury(address(0));
    }

    function test_setTreasury_onlyAdmin() public {
        vm.expectRevert(Errors.Unauthorized.selector);
        vm.prank(makeAddr("x"));
        vault.setTreasury(makeAddr("y"));
    }

    // ═══════════════════════════════════════════════════════════════
    // Constants
    // ═══════════════════════════════════════════════════════════════

    function test_trancheAPRs() public view {
        assertEq(vault.seniorAprBps(), 800);
        assertEq(vault.poolAprBps(), 1200);
        assertEq(vault.communityAprBps(), 2000);
    }

    function test_protocolFeeBps() public view {
        assertEq(vault.PROTOCOL_FEE_BPS(), 1000);
    }

    // ═══════════════════════════════════════════════════════════════
    // Claim Returns with Yield
    // ═══════════════════════════════════════════════════════════════

    function test_claimReturns_seniorGetsYield() public {
        _fundVault();
        vm.warp(block.timestamp + 180 days);
        vault.accrueInterest();
        _repay(vault.creditDrawn() + vault.accruedInterest());

        uint256 before = usdc.balanceOf(senior);
        vm.prank(senior);
        vault.claimReturns();
        assertTrue(usdc.balanceOf(senior) - before > 0);
    }

    function test_claimReturns_communityGetsYield() public {
        _fundVault();
        vm.warp(block.timestamp + 180 days);
        vault.accrueInterest();
        _repay(vault.creditDrawn() + vault.accruedInterest());

        uint256 before = usdc.balanceOf(community);
        vm.prank(community);
        vault.claimReturns();
        assertTrue(usdc.balanceOf(community) - before > 0);
    }

    function test_claimReturns_poolGetsYield() public {
        _fundVault();
        vm.warp(block.timestamp + 180 days);
        vault.accrueInterest();
        _repay(vault.creditDrawn() + vault.accruedInterest());

        uint256 before = usdc.balanceOf(poolInvestor);
        vm.prank(poolInvestor);
        vault.claimReturns();
        assertTrue(usdc.balanceOf(poolInvestor) - before > 0);
    }

    // ═══════════════════════════════════════════════════════════════
    // Default with Accrual
    // ═══════════════════════════════════════════════════════════════

    function test_markDefault_accruesToCurrent() public {
        _fundVault();
        vm.warp(block.timestamp + 90 days);
        vm.prank(admin);
        vault.markDefault();
        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Defaulted));
    }

    // ═══════════════════════════════════════════════════════════════
    // Backward Compatibility
    // ═══════════════════════════════════════════════════════════════

    function test_compat_totalToRepay() public {
        _fundVault();
        uint256 expected = TARGET + (TARGET * 1200 * 365 days) / (10_000 * 365 days);
        assertEq(vault.getTotalToRepay(), expected);
    }

    function test_compat_waterfallState() public {
        _fundVault();
        (uint256 s, uint256 p, uint256 u, , , ) = vault.getWaterfallState();
        assertEq(s, 30_000e6);
        assertEq(p, 15_000e6);
        assertEq(u, 5_000e6);
    }

    function test_compat_principalWaterfall() public {
        _fundVault();
        vm.warp(block.timestamp + 30 days);
        vault.accrueInterest();
        _repay(vault.accruedInterest() + 10_000e6);
        assertTrue(vault.totalSeniorRepaid() > 0);
    }

    // ═══════════════════════════════════════════════════════════════
    // Edge Cases
    // ═══════════════════════════════════════════════════════════════

    function test_accrueInterest_noCreditDrawn() public {
        _fundVault();
        vm.warp(block.timestamp + 30 days);
        vault.accrueInterest();
        _repay(vault.creditDrawn() + vault.accruedInterest());

        vm.warp(block.timestamp + 30 days);
        vault.accrueInterest();
        assertEq(vault.accruedInterest(), 0);
    }

    function test_noTreasurySet_doesNotRevert() public {
        MerchantVault v2 = new MerchantVault(MerchantVault.VaultParams({
            usdc: address(usdc),
            agent: agent,
            admin: admin,
            factory: address(this),
            targetAmount: 10_000e6,
            interestRateBps: 1200,
            durationSeconds: 365 days,
            numTranches: 2,
            platformFeeBps: 0,
            platformFeeRecipient: feeRecipient,
            lateFeeBps: 0,
            gracePeriodSeconds: 0,
            fundraisingDeadline: type(uint256).max
        }));
        vm.prank(admin);
        v2.setPaymentRouter(router);

        vm.startPrank(senior);
        usdc.approve(address(v2), 10_000e6);
        v2.investSenior(10_000e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 90 days);
        v2.accrueInterest();

        vm.startPrank(router);
        usdc.approve(address(v2), v2.accruedInterest());
        v2.processRepayment(v2.accruedInterest());
        vm.stopPrank();

        assertEq(v2.treasury(), address(0));
    }

    // ═══════════════════════════════════════════════════════════════
    // Full Lifecycle
    // ═══════════════════════════════════════════════════════════════

    function test_fullLifecycle() public {
        _fundVault();

        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Active));
        assertEq(vault.creditDrawn(), TARGET);

        // Release tranche 1
        vm.prank(admin);
        vault.releaseTranche();

        // Partial repay after 90 days
        vm.warp(block.timestamp + 90 days);
        _repay(20_000e6);
        assertTrue(vault.insuranceBalance() > 0);

        // Repay remaining after 180 days
        vm.warp(block.timestamp + 90 days);
        vault.accrueInterest();
        _repay(vault.creditDrawn() + vault.accruedInterest());
        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Completed));

        // All investors claim
        vm.prank(senior);
        vault.claimReturns();
        vm.prank(poolInvestor);
        vault.claimReturns();
        vm.prank(community);
        vault.claimReturns();
    }
}
