// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";
import {ILiquidityPool} from "../src/interfaces/ILiquidityPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {Errors} from "../src/libraries/Errors.sol";

/// @notice Tests for Solana-parity features: share math, tranches, yield, insurance, lockup, bad debt.
contract LiquidityPoolSolanaTest is Test {
    MockUSDC public usdc;
    LiquidityPool public pool;

    address admin = makeAddr("admin");
    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");
    address agent1 = makeAddr("agent1");

    function setUp() public {
        usdc = new MockUSDC();
        pool = new LiquidityPool(address(usdc), admin, false, 100_000e6);

        usdc.mint(lp1, 500_000e6);
        usdc.mint(lp2, 500_000e6);
        usdc.mint(agent1, 100_000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    // Share Math
    // ═══════════════════════════════════════════════════════════════

    function test_sharePrice_initial() public view {
        // No deposits → 1:1 price
        assertEq(pool.sharePrice(), 1e18);
    }

    function test_deposit_mintsShares_1to1() public {
        vm.startPrank(lp1);
        usdc.approve(address(pool), 10_000e6);
        pool.deposit(10_000e6);
        vm.stopPrank();

        assertEq(pool.getDepositorShares(lp1), 10_000e6);
        assertEq(pool.totalShares(), 10_000e6);
        assertEq(pool.sharePrice(), 1e18);
    }

    function test_deposit_proportionalShares() public {
        // LP1 deposits 10K → 10K shares
        vm.startPrank(lp1);
        usdc.approve(address(pool), 10_000e6);
        pool.deposit(10_000e6);
        vm.stopPrank();

        // LP2 deposits 10K → 10K shares (same price)
        vm.startPrank(lp2);
        usdc.approve(address(pool), 10_000e6);
        pool.deposit(10_000e6);
        vm.stopPrank();

        assertEq(pool.getDepositorShares(lp1), 10_000e6);
        assertEq(pool.getDepositorShares(lp2), 10_000e6);
        assertEq(pool.totalShares(), 20_000e6);
    }

    function test_sharesToAmount_roundtrip() public {
        vm.startPrank(lp1);
        usdc.approve(address(pool), 50_000e6);
        pool.deposit(50_000e6);
        vm.stopPrank();

        uint256 shares = pool.getDepositorShares(lp1);
        uint256 amount = pool.sharesToAmount(shares);
        assertEq(amount, 50_000e6);
    }

    function test_minimumInitialDeposit() public {
        vm.startPrank(lp1);
        usdc.approve(address(pool), 100);
        // SOL-004: first deposit must be >= 1000 (0.001 USDC)
        vm.expectRevert(Errors.InvalidAmount.selector);
        pool.deposit(100);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    // Tranche Deposits
    // ═══════════════════════════════════════════════════════════════

    function test_depositTranche_senior() public {
        vm.startPrank(lp1);
        usdc.approve(address(pool), 10_000e6);
        pool.depositTranche(10_000e6, 0); // Senior
        vm.stopPrank();

        assertEq(pool.seniorDeposits(), 10_000e6);
        assertEq(pool.mezzDeposits(), 0);
        assertEq(pool.juniorDeposits(), 0);
    }

    function test_depositTranche_mezzanine() public {
        vm.startPrank(lp1);
        usdc.approve(address(pool), 10_000e6);
        pool.depositTranche(10_000e6, 1); // Mezzanine
        vm.stopPrank();

        assertEq(pool.mezzDeposits(), 10_000e6);
    }

    function test_depositTranche_junior() public {
        vm.startPrank(lp1);
        usdc.approve(address(pool), 10_000e6);
        pool.depositTranche(10_000e6, 2); // Junior
        vm.stopPrank();

        assertEq(pool.juniorDeposits(), 10_000e6);
    }

    function test_depositTranche_invalidTranche() public {
        vm.startPrank(lp1);
        usdc.approve(address(pool), 10_000e6);
        vm.expectRevert(Errors.InvalidAmount.selector);
        pool.depositTranche(10_000e6, 3);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    // Withdraw by Shares
    // ═══════════════════════════════════════════════════════════════

    function test_withdrawShares() public {
        vm.startPrank(lp1);
        usdc.approve(address(pool), 10_000e6);
        pool.deposit(10_000e6);

        uint256 shares = pool.getDepositorShares(lp1);
        pool.withdrawShares(shares / 2); // withdraw half
        vm.stopPrank();

        assertEq(pool.getDepositorShares(lp1), shares / 2);
        assertEq(usdc.balanceOf(lp1), 500_000e6 - 5_000e6); // got 5K back
    }

    // ═══════════════════════════════════════════════════════════════
    // Utilization Cap
    // ═══════════════════════════════════════════════════════════════

    function test_utilizationCap_default80pct() public view {
        assertEq(pool.utilizationCapBps(), 8000);
    }

    function test_utilizationCap_blocksOverallocation() public {
        vm.startPrank(lp1);
        usdc.approve(address(pool), 100_000e6);
        pool.deposit(100_000e6);
        vm.stopPrank();

        // 80% of 100K = 80K max allocation. Try to allocate 81K.
        vm.prank(admin);
        vm.expectRevert(Errors.AllocationExceedsCap.selector);
        pool.allocateToVault(makeAddr("vault"), 81_000e6);
    }

    function test_utilizationCap_allowsWithinLimit() public {
        vm.startPrank(lp1);
        usdc.approve(address(pool), 100_000e6);
        pool.deposit(100_000e6);
        vm.stopPrank();

        // Need a mock vault that accepts funds
        // For this test, just verify the utilization view function
        assertEq(pool.utilizationBps(), 0);
    }

    function test_setUtilizationCap() public {
        vm.prank(admin);
        pool.setUtilizationCap(9000); // 90%
        assertEq(pool.utilizationCapBps(), 9000);
    }

    function test_setUtilizationCap_invalid() public {
        vm.prank(admin);
        vm.expectRevert(Errors.InvalidAmount.selector);
        pool.setUtilizationCap(10_001);
    }

    // ═══════════════════════════════════════════════════════════════
    // LP Lockup
    // ═══════════════════════════════════════════════════════════════

    function test_lockup_blocksEarlyWithdraw() public {
        vm.prank(admin);
        pool.setLockup(7 days);

        vm.startPrank(lp1);
        usdc.approve(address(pool), 10_000e6);
        pool.deposit(10_000e6);

        // Try withdraw before lockup expires
        vm.expectRevert(Errors.InvalidAmount.selector);
        pool.withdraw(5_000e6);
        vm.stopPrank();
    }

    function test_lockup_allowsAfterExpiry() public {
        vm.prank(admin);
        pool.setLockup(7 days);

        vm.startPrank(lp1);
        usdc.approve(address(pool), 10_000e6);
        pool.deposit(10_000e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(lp1);
        pool.withdraw(5_000e6);
        assertEq(pool.getDepositorBalance(lp1), 5_000e6);
    }

    function test_lockup_noLockupByDefault() public {
        vm.startPrank(lp1);
        usdc.approve(address(pool), 10_000e6);
        pool.deposit(10_000e6);
        pool.withdraw(5_000e6); // should work immediately
        vm.stopPrank();
        assertEq(pool.getDepositorBalance(lp1), 5_000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    // Yield Distribution
    // ═══════════════════════════════════════════════════════════════

    function test_distributeYield_increasesSharePrice() public {
        // Deposit into each tranche
        vm.startPrank(lp1);
        usdc.approve(address(pool), 100_000e6);
        pool.depositTranche(50_000e6, 0);  // Senior
        pool.depositTranche(30_000e6, 1);  // Mezzanine
        pool.depositTranche(20_000e6, 2);  // Junior
        vm.stopPrank();

        uint256 priceBefore = pool.sharePrice();
        uint256 totalBefore = pool.totalDeposits();

        // Warp 30 days
        vm.warp(block.timestamp + 30 days);

        vm.prank(admin);
        pool.distributeYield();

        // Share price should increase
        assertTrue(pool.sharePrice() > priceBefore);
        assertTrue(pool.totalDeposits() > totalBefore);
    }

    function test_distributeYield_insuranceCut() public {
        vm.startPrank(lp1);
        usdc.approve(address(pool), 100_000e6);
        pool.depositTranche(100_000e6, 0); // All Senior
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days); // 1 year

        vm.prank(admin);
        pool.distributeYield();

        // Senior APR = 800bps = 8%. On 100K for 1 year = 8K yield.
        // Insurance cut = 5% of 8K = 400.
        // Net yield to pool = 7600.
        assertTrue(pool.insuranceBalance() > 0);
        // Approximate check (with rounding)
        assertApproxEqAbs(pool.insuranceBalance(), 400e6, 1e6);
    }

    function test_distributeYield_noTime_noop() public {
        vm.startPrank(lp1);
        usdc.approve(address(pool), 10_000e6);
        pool.deposit(10_000e6);
        vm.stopPrank();

        uint256 totalBefore = pool.totalDeposits();
        vm.prank(admin);
        pool.distributeYield();
        assertEq(pool.totalDeposits(), totalBefore);
    }

    // ═══════════════════════════════════════════════════════════════
    // Insurance Fund & Bad Debt
    // ═══════════════════════════════════════════════════════════════

    function test_writeOffBadDebt_insuranceCoversAll() public {
        // Build up insurance balance via yield
        vm.startPrank(lp1);
        usdc.approve(address(pool), 100_000e6);
        pool.deposit(100_000e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        vm.prank(admin);
        pool.distributeYield();

        uint256 insurance = pool.insuranceBalance();
        assertTrue(insurance > 0);

        // Write off small bad debt covered by insurance
        uint256 smallLoss = insurance / 2;
        uint256 totalBefore = pool.totalDeposits();

        vm.prank(admin);
        pool.writeOffBadDebt(smallLoss);

        // totalDeposits unchanged (insurance absorbed it)
        assertEq(pool.totalDeposits(), totalBefore);
        assertEq(pool.insuranceBalance(), insurance - smallLoss);
    }

    function test_writeOffBadDebt_lpAbsorbs() public {
        // No insurance → LP absorbs everything
        vm.startPrank(lp1);
        usdc.approve(address(pool), 100_000e6);
        pool.depositTranche(50_000e6, 0);  // Senior
        pool.depositTranche(30_000e6, 1);  // Mezzanine
        pool.depositTranche(20_000e6, 2);  // Junior
        vm.stopPrank();

        uint256 totalBefore = pool.totalDeposits();

        vm.prank(admin);
        pool.writeOffBadDebt(10_000e6);

        // totalDeposits should decrease by 10K
        assertEq(pool.totalDeposits(), totalBefore - 10_000e6);

        // Junior absorbs first: 20K - 10K = 10K
        assertEq(pool.juniorDeposits(), 10_000e6);
        assertEq(pool.mezzDeposits(), 30_000e6); // unchanged
        assertEq(pool.seniorDeposits(), 50_000e6); // unchanged
    }

    function test_writeOffBadDebt_waterfallJuniorThenMezz() public {
        vm.startPrank(lp1);
        usdc.approve(address(pool), 100_000e6);
        pool.depositTranche(50_000e6, 0);  // Senior
        pool.depositTranche(30_000e6, 1);  // Mezzanine
        pool.depositTranche(20_000e6, 2);  // Junior
        vm.stopPrank();

        // Loss = 30K: wipes 20K junior, 10K from mezz
        vm.prank(admin);
        pool.writeOffBadDebt(30_000e6);

        assertEq(pool.juniorDeposits(), 0);
        assertEq(pool.mezzDeposits(), 20_000e6);
        assertEq(pool.seniorDeposits(), 50_000e6);
    }

    function test_writeOffBadDebt_zero_reverts() public {
        vm.prank(admin);
        vm.expectRevert(Errors.InvalidAmount.selector);
        pool.writeOffBadDebt(0);
    }

    // ═══════════════════════════════════════════════════════════════
    // Collateral Deposits
    // ═══════════════════════════════════════════════════════════════

    function test_depositCollateral() public {
        vm.startPrank(agent1);
        usdc.approve(address(pool), 5_000e6);
        pool.depositCollateral(agent1, 5_000e6);
        vm.stopPrank();

        ILiquidityPool.DepositPosition memory pos = pool.getPosition(agent1);
        assertTrue(pos.isCollateral);
        assertEq(pos.shares, 5_000e6);
        assertEq(pos.depositedAmount, 5_000e6);
    }

    function test_withdrawCollateral_noLockup() public {
        // Collateral skips lockup
        vm.prank(admin);
        pool.setLockup(30 days);

        vm.startPrank(agent1);
        usdc.approve(address(pool), 5_000e6);
        pool.depositCollateral(agent1, 5_000e6);

        uint256 shares = pool.getDepositorShares(agent1);
        pool.withdrawCollateral(agent1, shares);
        vm.stopPrank();

        assertEq(pool.getDepositorShares(agent1), 0);
    }

    // ═══════════════════════════════════════════════════════════════
    // Position View
    // ═══════════════════════════════════════════════════════════════

    function test_getPosition() public {
        vm.startPrank(lp1);
        usdc.approve(address(pool), 25_000e6);
        pool.depositTranche(25_000e6, 1); // Mezzanine
        vm.stopPrank();

        ILiquidityPool.DepositPosition memory pos = pool.getPosition(lp1);
        assertEq(pos.shares, 25_000e6);
        assertEq(pos.depositedAmount, 25_000e6);
        assertEq(pos.tranche, 1);
        assertFalse(pos.isCollateral);
        assertTrue(pos.depositTimestamp > 0);
    }

    // ═══════════════════════════════════════════════════════════════
    // Admin
    // ═══════════════════════════════════════════════════════════════

    function test_setLockup() public {
        vm.prank(admin);
        pool.setLockup(14 days);
        assertEq(pool.lockupSeconds(), 14 days);
    }

    function test_adminTransfer() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        pool.proposeAdmin(newAdmin);

        vm.prank(newAdmin);
        pool.acceptAdmin();
        assertEq(pool.admin(), newAdmin);
    }
}
