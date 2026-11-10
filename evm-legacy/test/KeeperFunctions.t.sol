// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {MerchantVault} from "../src/MerchantVault.sol";
import {IMerchantVault} from "../src/interfaces/IMerchantVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {Errors} from "../src/libraries/Errors.sol";

contract KeeperFunctionsTest is Test {
    MockUSDC public usdc;

    address admin = makeAddr("admin");
    address agent = makeAddr("agent");
    address investor = makeAddr("investor");
    address keeper = makeAddr("keeper");  // permissionless caller

    uint256 constant TARGET = 50_000e6;
    uint256 constant DEADLINE_BUFFER = 30 days;
    uint256 constant GRACE = 7 days;

    function _makeVault(uint256 fundraisingDeadline, uint16 lateFeeBps, uint256 gracePeriodSeconds)
        internal
        returns (MerchantVault)
    {
        MerchantVault v = new MerchantVault(
            MerchantVault.VaultParams({
                usdc: address(usdc),
                agent: agent,
                admin: admin,
                factory: admin,
                targetAmount: TARGET,
                interestRateBps: 1200,
                durationSeconds: 180 days,
                numTranches: 3,
                platformFeeBps: 0,
                platformFeeRecipient: admin,
                lateFeeBps: lateFeeBps,
                gracePeriodSeconds: gracePeriodSeconds,
                fundraisingDeadline: fundraisingDeadline
            })
        );
        return v;
    }

    function setUp() public {
        usdc = new MockUSDC();
    }

    // ════════════════════════════════════════════════════════════════
    // autoCancelExpired
    // ════════════════════════════════════════════════════════════════

    function test_autoCancelExpired_underfunded() public {
        uint256 deadline = block.timestamp + DEADLINE_BUFFER;
        MerchantVault vault = _makeVault(deadline, 0, 0);

        // Invest only 50% (below 80% threshold)
        uint256 halfTarget = TARGET / 2;
        usdc.mint(investor, halfTarget);
        vm.startPrank(investor);
        usdc.approve(address(vault), halfTarget);
        vault.invest(halfTarget);
        vm.stopPrank();

        // Warp past deadline
        vm.warp(deadline + 1);

        // Anyone can call
        vm.prank(keeper);
        vault.autoCancelExpired();

        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Cancelled));
    }

    function test_autoCancelExpired_notExpired_reverts() public {
        uint256 deadline = block.timestamp + DEADLINE_BUFFER;
        MerchantVault vault = _makeVault(deadline, 0, 0);

        // Still within fundraising period
        vm.prank(keeper);
        vm.expectRevert(Errors.FundraisingNotExpired.selector);
        vault.autoCancelExpired();
    }

    function test_autoCancelExpired_aboveThreshold_reverts() public {
        uint256 deadline = block.timestamp + DEADLINE_BUFFER;
        MerchantVault vault = _makeVault(deadline, 0, 0);

        // Invest 90% (above 80%)
        uint256 ninetyPct = (TARGET * 90) / 100;
        usdc.mint(investor, ninetyPct);
        vm.startPrank(investor);
        usdc.approve(address(vault), ninetyPct);
        vault.invest(ninetyPct);
        vm.stopPrank();

        vm.warp(deadline + 1);

        vm.prank(keeper);
        vm.expectRevert(Errors.FundraisingAboveThreshold.selector);
        vault.autoCancelExpired();
    }

    // ════════════════════════════════════════════════════════════════
    // markDefault
    // ════════════════════════════════════════════════════════════════

    function test_markDefault_permissionless() public {
        MerchantVault vault = _makeVault(type(uint256).max, 100, GRACE);
        address fakeRouter = makeAddr("fakeRouter");

        vm.prank(admin);
        vault.setPaymentRouter(fakeRouter);

        // Fund vault to Active state
        usdc.mint(investor, TARGET);
        vm.startPrank(investor);
        usdc.approve(address(vault), TARGET);
        vault.invest(TARGET);
        vm.stopPrank();

        usdc.mint(fakeRouter, 1_000e6);
        vm.prank(fakeRouter);
        usdc.approve(address(vault), type(uint256).max);

        // Make a small repayment to get to Repaying state
        vm.prank(fakeRouter);
        vault.processRepayment(1_000e6);

        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Repaying));

        // Warp past nextPaymentDue + grace period
        uint256 due = vault.nextPaymentDue();
        vm.warp(due + GRACE + 1 seconds);

        assertTrue(vault.shouldDefault());

        // Keeper (permissionless) can mark default
        vm.prank(keeper);
        vault.markDefault();

        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Defaulted));
    }

    function test_markDefault_admin_force() public {
        // Admin can force default even without grace period elapsed
        MerchantVault vault = _makeVault(type(uint256).max, 100, GRACE);
        address fakeRouter = makeAddr("fakeRouter");

        vm.prank(admin);
        vault.setPaymentRouter(fakeRouter);

        usdc.mint(investor, TARGET);
        vm.startPrank(investor);
        usdc.approve(address(vault), TARGET);
        vault.invest(TARGET);
        vm.stopPrank();

        // shouldDefault() is false — but admin can still force
        assertFalse(vault.shouldDefault());

        vm.prank(admin);
        vault.markDefault();

        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Defaulted));
    }

    function test_markDefault_wrongState_reverts() public {
        MerchantVault vault = _makeVault(type(uint256).max, 0, 0);

        // Vault is in Fundraising state — markDefault should revert
        vm.prank(admin);
        vm.expectRevert(Errors.InvalidVaultState.selector);
        vault.markDefault();
    }

    // ════════════════════════════════════════════════════════════════
    // completeFundraisingManual
    // ════════════════════════════════════════════════════════════════

    function test_completeFundraisingManual_at80pct() public {
        MerchantVault vault = _makeVault(type(uint256).max, 0, 0);

        // Invest exactly 80%
        uint256 eightyPct = (TARGET * 80) / 100;
        usdc.mint(investor, eightyPct);
        vm.startPrank(investor);
        usdc.approve(address(vault), eightyPct);
        vault.invest(eightyPct);
        vm.stopPrank();

        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Fundraising));

        vm.prank(admin);
        vault.completeFundraisingManual();

        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Active));
        assertTrue(vault.totalToRepay() > 0); // Interest calculated on activation
    }
}
