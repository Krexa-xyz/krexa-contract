// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";
import {MerchantVault} from "../src/MerchantVault.sol";
import {IMerchantVault} from "../src/interfaces/IMerchantVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {Errors} from "../src/libraries/Errors.sol";

/// @notice Full LiquidityPool lifecycle: deposit → allocate → vault repays → processReturn → LP withdraws
contract LiquidityPoolLifecycleTest is Test {
    MockUSDC public usdc;
    LiquidityPool public alphaPool;   // isAlpha=true  → investSenior
    LiquidityPool public generalPool; // isAlpha=false → investFromPool

    address admin = makeAddr("admin");
    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");
    address feeRecipient = makeAddr("feeRecipient");
    address agent = makeAddr("translateBot");

    function setUp() public {
        usdc = new MockUSDC();
        alphaPool = new LiquidityPool(address(usdc), admin, true, 100_000e6);
        generalPool = new LiquidityPool(address(usdc), admin, false, 50_000e6);

        // Set utilization cap to 100% for lifecycle tests (default is 80%)
        vm.startPrank(admin);
        alphaPool.setUtilizationCap(10_000);
        generalPool.setUtilizationCap(10_000);
        vm.stopPrank();

        usdc.mint(lp1, 200_000e6);
        usdc.mint(lp2, 100_000e6);
    }

    // ─── Helper ──────────────────────────────────────────────────

    // Creates a vault with address(this) as router so tests can call processRepayment
    function _makeVault(uint256 target) internal returns (MerchantVault) {
        MerchantVault vault = new MerchantVault(MerchantVault.VaultParams({
            usdc: address(usdc),
            agent: agent,
            admin: admin,
            factory: address(this),
            targetAmount: target,
            interestRateBps: 1200,
            durationSeconds: 365 days,
            numTranches: 2,
            platformFeeBps: 200,
            platformFeeRecipient: feeRecipient,
            lateFeeBps: 0,
            gracePeriodSeconds: 0,
            fundraisingDeadline: type(uint256).max
        }));
        vm.prank(admin);
        vault.setPaymentRouter(address(this));
        return vault;
    }

    // ════════════════════════════════════════════════════════════════
    // 1. Alpha pool full lifecycle (investSenior path)
    // ════════════════════════════════════════════════════════════════

    function test_alphaPool_fullLifecycle() public {
        MerchantVault vault = _makeVault(20_000e6);

        // LP1 deposits 20K into alpha pool
        vm.startPrank(lp1);
        usdc.approve(address(alphaPool), 20_000e6);
        alphaPool.deposit(20_000e6);
        vm.stopPrank();

        assertEq(alphaPool.getTotalDeposits(), 20_000e6);
        assertEq(alphaPool.getAvailableBalance(), 20_000e6);

        // Admin allocates 20K to vault (calls vault.investSenior)
        vm.prank(admin);
        alphaPool.allocateToVault(address(vault), 20_000e6);

        // Vault should be funded and active
        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Active));
        assertEq(vault.seniorFunded(), 20_000e6);

        // Pool balance now allocated (not available)
        assertEq(alphaPool.getAvailableBalance(), 0);
        assertEq(alphaPool.getAllocation(address(vault)).amount, 20_000e6);
        assertTrue(alphaPool.getAllocation(address(vault)).active);

        // Simulate repayment: router sends 5K to vault
        usdc.mint(address(this), 5_000e6);
        usdc.approve(address(vault), 5_000e6);
        vault.processRepayment(5_000e6);

        assertTrue(vault.totalSeniorRepaid() > 0);

        // Now pool claims returns from vault — pool is a senior investor
        // alphaPool must call vault.claimReturns() to pull USDC back
        vm.prank(address(alphaPool));
        // Actually claimReturns must be called by the pool address directly
        // We simulate the pool receiving USDC by having admin call processReturn
        // with USDC minted to simulate vault returning capital
        uint256 claimable = vault.getClaimable(address(alphaPool));
        assertTrue(claimable > 0);

        // Simulate the pool pulling its claimable returns from vault
        // In practice: alphaPool.claimVaultReturns(vault) would call vault.claimReturns()
        // For now, simulate processReturn being called with USDC from the vault
        usdc.mint(admin, claimable);
        vm.startPrank(admin);
        usdc.approve(address(alphaPool), claimable);
        alphaPool.processReturn(address(vault), claimable);
        vm.stopPrank();

        // Pool balance should increase
        assertEq(alphaPool.getAvailableBalance(), claimable);

        // LP1 can withdraw their original deposit proportion
        uint256 lp1Before = usdc.balanceOf(lp1);
        vm.prank(lp1);
        alphaPool.withdraw(claimable); // withdraw the returned amount
        assertEq(usdc.balanceOf(lp1) - lp1Before, claimable);
    }

    // ════════════════════════════════════════════════════════════════
    // 2. General pool lifecycle (investFromPool path)
    // ════════════════════════════════════════════════════════════════

    function test_generalPool_investFromPool_investorTracking() public {
        MerchantVault vault = _makeVault(10_000e6);

        vm.startPrank(lp1);
        usdc.approve(address(generalPool), 10_000e6);
        generalPool.deposit(10_000e6);
        vm.stopPrank();

        vm.prank(admin);
        generalPool.allocateToVault(address(vault), 10_000e6);

        // investFromPool → tracked in poolFunded AND investorBalances (for claim path)
        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Active));
        assertEq(vault.poolFunded(), 10_000e6);
        assertEq(vault.getInvestorBalance(address(generalPool)), 10_000e6);
    }

    // ════════════════════════════════════════════════════════════════
    // 3. Multi-LP proportional balances
    // ════════════════════════════════════════════════════════════════

    function test_multiLP_deposits() public {
        vm.startPrank(lp1);
        usdc.approve(address(alphaPool), 60_000e6);
        alphaPool.deposit(60_000e6);
        vm.stopPrank();

        vm.startPrank(lp2);
        usdc.approve(address(alphaPool), 40_000e6);
        alphaPool.deposit(40_000e6);
        vm.stopPrank();

        assertEq(alphaPool.getTotalDeposits(), 100_000e6);
        assertEq(alphaPool.getDepositorBalance(lp1), 60_000e6);
        assertEq(alphaPool.getDepositorBalance(lp2), 40_000e6);
        assertEq(alphaPool.getAvailableBalance(), 100_000e6);
    }

    // ════════════════════════════════════════════════════════════════
    // 4. Allocation cap enforcement
    // ════════════════════════════════════════════════════════════════

    function test_allocation_cap_enforced() public {
        MerchantVault vault = _makeVault(200_000e6);

        vm.startPrank(lp1);
        usdc.approve(address(alphaPool), 200_000e6);
        alphaPool.deposit(200_000e6);
        vm.stopPrank();

        // maxAllocationPerVault = 100_000e6 (set in constructor)
        vm.prank(admin);
        vm.expectRevert(Errors.ExceedsMaxAllocation.selector);
        alphaPool.allocateToVault(address(vault), 100_001e6);
    }

    function test_setMaxAllocation_updatesLimit() public {
        vm.prank(admin);
        alphaPool.setMaxAllocation(200_000e6);
        assertEq(alphaPool.maxAllocationPerVault(), 200_000e6);
    }

    // ════════════════════════════════════════════════════════════════
    // 5. Withdraw only available (not allocated) balance
    // ════════════════════════════════════════════════════════════════

    function test_withdraw_onlyAvailableBalance() public {
        // Pool target is 50K, vault target must be large enough for 30K allocation
        MerchantVault vault = _makeVault(100_000e6);

        vm.startPrank(lp1);
        usdc.approve(address(alphaPool), 50_000e6);
        alphaPool.deposit(50_000e6);
        vm.stopPrank();

        vm.prank(admin);
        alphaPool.allocateToVault(address(vault), 30_000e6);

        // Only 20K available, can't withdraw 25K
        vm.prank(lp1);
        vm.expectRevert(Errors.InsufficientPoolBalance.selector);
        alphaPool.withdraw(25_000e6);

        // Can withdraw exactly available
        vm.prank(lp1);
        alphaPool.withdraw(20_000e6);
        assertEq(alphaPool.getAvailableBalance(), 0);
    }

    // ════════════════════════════════════════════════════════════════
    // 6. processReturn fully deactivates allocation
    // ════════════════════════════════════════════════════════════════

    function test_processReturn_fullReturn_deactivatesAllocation() public {
        MerchantVault vault = _makeVault(10_000e6);

        vm.startPrank(lp1);
        usdc.approve(address(alphaPool), 10_000e6);
        alphaPool.deposit(10_000e6);
        vm.stopPrank();

        vm.prank(admin);
        alphaPool.allocateToVault(address(vault), 10_000e6);

        // Return the full allocated amount
        usdc.mint(admin, 10_000e6);
        vm.startPrank(admin);
        usdc.approve(address(alphaPool), 10_000e6);
        alphaPool.processReturn(address(vault), 10_000e6);
        vm.stopPrank();

        // Allocation should be deactivated
        assertFalse(alphaPool.getAllocation(address(vault)).active);
        assertEq(alphaPool.totalAllocated(), 0);
        assertEq(alphaPool.getAvailableBalance(), 10_000e6);
    }

    // ════════════════════════════════════════════════════════════════
    // 7. Pause/unpause
    // ════════════════════════════════════════════════════════════════

    function test_pause_blocksDeposit() public {
        vm.prank(admin);
        alphaPool.pause();

        vm.startPrank(lp1);
        usdc.approve(address(alphaPool), 1_000e6);
        vm.expectRevert(Errors.PoolPaused.selector);
        alphaPool.deposit(1_000e6);
        vm.stopPrank();
    }

    function test_unpause_resumesDeposit() public {
        vm.prank(admin);
        alphaPool.pause();
        vm.prank(admin);
        alphaPool.unpause();

        vm.startPrank(lp1);
        usdc.approve(address(alphaPool), 1_000e6);
        alphaPool.deposit(1_000e6);
        vm.stopPrank();

        assertEq(alphaPool.getTotalDeposits(), 1_000e6);
    }
}
