// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";
import {MerchantVault} from "../src/MerchantVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {Errors} from "../src/libraries/Errors.sol";

contract LiquidityPoolTest is Test {
    MockUSDC public usdc;
    LiquidityPool public pool;
    MerchantVault public vault;

    address admin = makeAddr("admin");
    address lp1 = makeAddr("lp1");
    address feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        usdc = new MockUSDC();
        pool = new LiquidityPool(address(usdc), admin, false, 50_000e6);

        // Create a vault for allocation tests
        vault = new MerchantVault(MerchantVault.VaultParams({
            usdc: address(usdc),
            agent: makeAddr("agent"),
            admin: admin,
            factory: address(this),
            targetAmount: 50_000e6,
            interestRateBps: 1200,
            durationSeconds: 365 days,
            numTranches: 4,
            platformFeeBps: 200,
            platformFeeRecipient: feeRecipient,
            lateFeeBps: 0,
            gracePeriodSeconds: 0,
            fundraisingDeadline: type(uint256).max
        }));

        usdc.mint(lp1, 100_000e6);
    }

    function test_deposit() public {
        vm.startPrank(lp1);
        usdc.approve(address(pool), 10_000e6);
        pool.deposit(10_000e6);
        vm.stopPrank();

        assertEq(pool.getDepositorBalance(lp1), 10_000e6);
        assertEq(pool.getTotalDeposits(), 10_000e6);
        assertEq(pool.getAvailableBalance(), 10_000e6);
    }

    function test_withdraw() public {
        vm.startPrank(lp1);
        usdc.approve(address(pool), 10_000e6);
        pool.deposit(10_000e6);
        pool.withdraw(5_000e6);
        vm.stopPrank();

        assertEq(pool.getDepositorBalance(lp1), 5_000e6);
        assertEq(pool.getTotalDeposits(), 5_000e6);
    }

    function test_withdraw_insufficientBalance_reverts() public {
        vm.startPrank(lp1);
        usdc.approve(address(pool), 10_000e6);
        pool.deposit(10_000e6);

        vm.expectRevert(Errors.InsufficientBalance.selector);
        pool.withdraw(20_000e6);
        vm.stopPrank();
    }

    function test_allocateToVault() public {
        vm.startPrank(lp1);
        usdc.approve(address(pool), 10_000e6);
        pool.deposit(10_000e6);
        vm.stopPrank();

        vm.prank(admin);
        pool.allocateToVault(address(vault), 8_000e6);

        assertEq(pool.getAvailableBalance(), 2_000e6);
        assertEq(pool.getAllocation(address(vault)).amount, 8_000e6);
    }

    function test_allocateToVault_exceedsMax_reverts() public {
        vm.startPrank(lp1);
        usdc.approve(address(pool), 60_000e6);
        pool.deposit(60_000e6);
        vm.stopPrank();

        vm.prank(admin);
        vm.expectRevert(Errors.AllocationExceedsCap.selector);
        pool.allocateToVault(address(vault), 51_000e6);
    }

    function test_pause() public {
        vm.prank(admin);
        pool.pause();

        vm.startPrank(lp1);
        usdc.approve(address(pool), 1000e6);
        vm.expectRevert(Errors.PoolPaused.selector);
        pool.deposit(1000e6);
        vm.stopPrank();
    }
}
