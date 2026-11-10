// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {MerchantVault} from "../src/MerchantVault.sol";
import {IMerchantVault} from "../src/interfaces/IMerchantVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {Errors} from "../src/libraries/Errors.sol";

contract MerchantVaultTest is Test {
    MockUSDC public usdc;
    MerchantVault public vault;

    address admin = makeAddr("admin");
    address agent = makeAddr("translateBot");
    address factory = makeAddr("factory");
    address router = makeAddr("router");
    address feeRecipient = makeAddr("feeRecipient");
    address seniorInvestor = makeAddr("alphaVault");
    address communityInvestor = makeAddr("yieldBot");

    uint256 constant TARGET = 50_000e6; // 50K USDC
    uint256 constant INTEREST_BPS = 1200; // 12%
    uint256 constant DURATION = 365 days;
    uint256 constant TRANCHES = 4;
    uint16 constant PLATFORM_FEE = 200; // 2%

    function setUp() public {
        usdc = new MockUSDC();
        vault = new MerchantVault(MerchantVault.VaultParams({
            usdc: address(usdc),
            agent: agent,
            admin: admin,
            factory: factory,
            targetAmount: TARGET,
            interestRateBps: INTEREST_BPS,
            durationSeconds: DURATION,
            numTranches: TRANCHES,
            platformFeeBps: PLATFORM_FEE,
            platformFeeRecipient: feeRecipient,
            lateFeeBps: 0,
            gracePeriodSeconds: 0,
            fundraisingDeadline: type(uint256).max
        }));

        vm.prank(admin);
        vault.setPaymentRouter(router);

        // Fund investors
        usdc.mint(seniorInvestor, 100_000e6);
        usdc.mint(communityInvestor, 100_000e6);
    }

    function test_invest_fundraising() public {
        vm.startPrank(seniorInvestor);
        usdc.approve(address(vault), 40_000e6);
        vault.investSenior(40_000e6);
        vm.stopPrank();

        assertEq(vault.totalRaised(), 40_000e6);
        assertEq(vault.seniorFunded(), 40_000e6);
        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Fundraising));
    }

    function test_invest_autoActivate() public {
        _fundVault();
        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Active));
        assertTrue(vault.totalToRepay() > TARGET); // principal + interest
    }

    function test_invest_exceedsTarget_reverts() public {
        vm.startPrank(seniorInvestor);
        usdc.approve(address(vault), TARGET + 1);
        vm.expectRevert(Errors.ExceedsTarget.selector);
        vault.investSenior(TARGET + 1);
        vm.stopPrank();
    }

    function test_releaseTranche() public {
        _fundVault();

        uint256 agentBefore = usdc.balanceOf(agent);
        vm.prank(admin);
        vault.releaseTranche();

        assertEq(vault.tranchesReleased(), 1);
        assertEq(usdc.balanceOf(agent) - agentBefore, TARGET / TRANCHES);
    }

    function test_processRepayment_waterfall() public {
        _fundVault();

        uint256 repayAmount = 10_000e6;
        usdc.mint(router, repayAmount);

        vm.startPrank(router);
        usdc.approve(address(vault), repayAmount);
        vault.processRepayment(repayAmount);
        vm.stopPrank();

        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Repaying));
        assertTrue(vault.totalRepaid() > 0);
        // Senior should get paid first
        assertTrue(vault.totalSeniorRepaid() > 0);
    }

    function test_processRepayment_onlyRouter() public {
        _fundVault();

        vm.prank(seniorInvestor);
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.processRepayment(1000e6);
    }

    function test_cancel_refund() public {
        // Partial fundraise
        vm.startPrank(seniorInvestor);
        usdc.approve(address(vault), 20_000e6);
        vault.investSenior(20_000e6);
        vm.stopPrank();

        // Cancel
        vm.prank(admin);
        vault.cancel();
        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Cancelled));

        // Claim refund
        uint256 before = usdc.balanceOf(seniorInvestor);
        vm.prank(seniorInvestor);
        vault.claimRefund();
        assertEq(usdc.balanceOf(seniorInvestor) - before, 20_000e6);
    }

    function test_pause_unpause() public {
        vm.prank(admin);
        vault.pause();
        assertTrue(vault.paused());

        vm.startPrank(seniorInvestor);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert(Errors.VaultPaused.selector);
        vault.investSenior(1000e6);
        vm.stopPrank();

        vm.prank(admin);
        vault.unpause();
        assertFalse(vault.paused());
    }

    // ─── Helpers ─────────────────────────────────────────────────

    function _fundVault() internal {
        vm.startPrank(seniorInvestor);
        usdc.approve(address(vault), 40_000e6);
        vault.investSenior(40_000e6);
        vm.stopPrank();

        vm.startPrank(communityInvestor);
        usdc.approve(address(vault), 10_000e6);
        vault.invest(10_000e6);
        vm.stopPrank();
    }
}
