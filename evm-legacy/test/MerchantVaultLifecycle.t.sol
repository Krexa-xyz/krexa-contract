// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {MerchantVault} from "../src/MerchantVault.sol";
import {IMerchantVault} from "../src/interfaces/IMerchantVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {Errors} from "../src/libraries/Errors.sol";

contract MerchantVaultLifecycleTest is Test {
    MockUSDC public usdc;

    address admin = makeAddr("admin");
    address agent = makeAddr("translateBot");
    address factory = makeAddr("factory");
    address feeRecipient = makeAddr("feeRecipient");

    address seniorInvestor = makeAddr("alphaVault");
    address communityInvestorA = makeAddr("yieldBotA");
    address communityInvestorB = makeAddr("yieldBotB");

    uint16 constant PLATFORM_FEE = 200; // 2%

    function setUp() public {
        usdc = new MockUSDC();
        usdc.mint(seniorInvestor, 500_000e6);
        usdc.mint(communityInvestorA, 100_000e6);
        usdc.mint(communityInvestorB, 100_000e6);
    }

    // ─── Helpers ─────────────────────────────────────────────────

    // Creates a vault with address(this) as the router so tests can call processRepayment
    function _makeVault(uint256 target, uint256 tranches) internal returns (MerchantVault) {
        MerchantVault vault = new MerchantVault(MerchantVault.VaultParams({
            usdc: address(usdc),
            agent: agent,
            admin: admin,
            factory: factory,
            targetAmount: target,
            interestRateBps: 1200,
            durationSeconds: 365 days,
            numTranches: tranches,
            platformFeeBps: PLATFORM_FEE,
            platformFeeRecipient: feeRecipient,
            lateFeeBps: 0,
            gracePeriodSeconds: 0,
            fundraisingDeadline: type(uint256).max
        }));
        vm.prank(admin);
        vault.setPaymentRouter(address(this));
        return vault;
    }

    // Fund entirely with senior capital
    function _fundSenior(MerchantVault vault, uint256 amount) internal {
        vm.startPrank(seniorInvestor);
        usdc.approve(address(vault), amount);
        vault.investSenior(amount);
        vm.stopPrank();
    }

    // Fund with senior + community split
    function _fundMixed(MerchantVault vault, uint256 seniorAmt, uint256 communityAmt) internal {
        vm.startPrank(seniorInvestor);
        usdc.approve(address(vault), seniorAmt);
        vault.investSenior(seniorAmt);
        vm.stopPrank();

        vm.startPrank(communityInvestorA);
        usdc.approve(address(vault), communityAmt);
        vault.invest(communityAmt);
        vm.stopPrank();
    }

    function _repay(MerchantVault vault, uint256 gross) internal {
        usdc.mint(address(this), gross);
        usdc.approve(address(vault), gross);
        vault.processRepayment(gross);
    }

    // ════════════════════════════════════════════════════════════════
    // 1. markDefault
    // ════════════════════════════════════════════════════════════════

    function test_markDefault_fromActive() public {
        MerchantVault vault = _makeVault(10_000e6, 2);
        _fundSenior(vault, 10_000e6); // activates vault

        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Active));

        vm.prank(admin);
        vault.markDefault();

        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Defaulted));
    }

    function test_markDefault_fromRepaying() public {
        MerchantVault vault = _makeVault(10_000e6, 2);
        _fundSenior(vault, 10_000e6);
        _repay(vault, 1_000e6); // transitions to Repaying

        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Repaying));

        vm.prank(admin);
        vault.markDefault();

        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Defaulted));
    }

    function test_markDefault_fromFundraising_reverts() public {
        MerchantVault vault = _makeVault(10_000e6, 2);
        // Not fully funded, still Fundraising

        vm.prank(admin);
        vm.expectRevert(Errors.InvalidVaultState.selector);
        vault.markDefault();
    }

    function test_markDefault_onlyAdmin_reverts() public {
        MerchantVault vault = _makeVault(10_000e6, 2);
        _fundSenior(vault, 10_000e6);

        vm.prank(agent);
        vm.expectRevert(Errors.DefaultConditionsNotMet.selector);
        vault.markDefault();
    }

    // ════════════════════════════════════════════════════════════════
    // 2. claimRefund after default — pro-rata of remaining balance
    // ════════════════════════════════════════════════════════════════

    function test_claimRefund_afterDefault_proRata() public {
        MerchantVault vault = _makeVault(10_000e6, 2);

        // Two community investors: A = 6K, B = 4K (total 10K, community-only)
        vm.startPrank(communityInvestorA);
        usdc.approve(address(vault), 6_000e6);
        vault.invest(6_000e6);
        vm.stopPrank();

        vm.startPrank(communityInvestorB);
        usdc.approve(address(vault), 4_000e6);
        vault.invest(4_000e6);
        vm.stopPrank();

        // Repay 2K (net 1960 after 2% fee) — vault balance = 10K + 1960 = 11960
        _repay(vault, 2_000e6);

        vm.prank(admin);
        vault.markDefault();

        // With snapshot fix: both A and B get refunds based on the SAME snapshot balance
        // Snapshot = 11960. A gets: (6000 * 11960) / 10000 = 7176, B gets: (4000 * 11960) / 10000 = 4784
        // Order-independent — both use defaultSnapshotBalance
        uint256 snapshot = vault.defaultSnapshotBalance();
        uint256 expectedA = (6_000e6 * snapshot) / 10_000e6;
        uint256 expectedB = (4_000e6 * snapshot) / 10_000e6;

        uint256 beforeA = usdc.balanceOf(communityInvestorA);
        vm.prank(communityInvestorA);
        vault.claimRefund();
        assertEq(usdc.balanceOf(communityInvestorA) - beforeA, expectedA);

        uint256 beforeB = usdc.balanceOf(communityInvestorB);
        vm.prank(communityInvestorB);
        vault.claimRefund();
        assertEq(usdc.balanceOf(communityInvestorB) - beforeB, expectedB);

        // Verify: claim order doesn't matter — same amounts regardless
        assertEq(expectedA, (6_000e6 * snapshot) / 10_000e6);
        assertEq(expectedB, (4_000e6 * snapshot) / 10_000e6);
    }

    function test_claimRefund_doubleClaimReverts() public {
        MerchantVault vault = _makeVault(10_000e6, 2);
        _fundSenior(vault, 10_000e6);

        vm.prank(admin);
        vault.markDefault();

        vm.prank(seniorInvestor);
        vault.claimRefund();

        vm.prank(seniorInvestor);
        vm.expectRevert(Errors.NothingToClaim.selector);
        vault.claimRefund();
    }

    // ════════════════════════════════════════════════════════════════
    // 3. claimReturns — senior investor
    // ════════════════════════════════════════════════════════════════

    function test_claimReturns_seniorInvestor() public {
        MerchantVault vault = _makeVault(10_000e6, 2);
        _fundSenior(vault, 10_000e6); // all senior

        uint256 gross = 3_000e6;
        _repay(vault, gross); // fee = 60, net = 2940 → all to senior (seniorOwed = 10K)

        uint256 expected = vault.getClaimable(seniorInvestor);
        assertTrue(expected > 0);

        uint256 before = usdc.balanceOf(seniorInvestor);
        vm.prank(seniorInvestor);
        vault.claimReturns();
        assertEq(usdc.balanceOf(seniorInvestor) - before, expected);

        // Claimed amount should now be zero
        assertEq(vault.getClaimable(seniorInvestor), 0);
    }

    function test_claimReturns_communityInvestor_afterSeniorCleared() public {
        // 4K senior, 6K community; total 10K
        // New model: no time elapsed → accruedInterest = 0, all repayment is principal
        // Platform fee = 2% of principal portion
        MerchantVault vault = _makeVault(10_000e6, 2);
        _fundMixed(vault, 4_000e6, 6_000e6);

        // Repay 5000 gross. No interest accrued (no time warp), so:
        // interestPortion = 0, principalPortion = 5000
        // Platform fee = 2% of 5000 = 100 → net principal credited = 5000
        // (platform fee is transferred OUT but principalPortion is still 5000 for waterfall)
        // Principal waterfall: senior gets min(5000, 4000) = 4000, community gets 1000
        _repay(vault, 5_000e6);

        assertEq(vault.totalSeniorRepaid(), 4_000e6);
        assertEq(vault.totalCommunityRepaid(), 1_000e6);

        // Senior can claim 4000
        uint256 seniorClaimable = vault.getClaimable(seniorInvestor);
        assertEq(seniorClaimable, 4_000e6);

        // Community can claim 1000
        uint256 communityClaimable = vault.getClaimable(communityInvestorA);
        assertEq(communityClaimable, 1_000e6);

        vm.prank(seniorInvestor);
        vault.claimReturns();

        vm.prank(communityInvestorA);
        vault.claimReturns();
    }

    function test_claimReturns_wrongState_reverts() public {
        MerchantVault vault = _makeVault(10_000e6, 2);
        _fundSenior(vault, 10_000e6); // Active, no repayments yet

        // Active state (not Repaying/Completed) → should revert
        vm.prank(seniorInvestor);
        vm.expectRevert(Errors.InvalidVaultState.selector);
        vault.claimReturns();
    }

    // ════════════════════════════════════════════════════════════════
    // 4. Vault auto-completes when fully repaid
    // ════════════════════════════════════════════════════════════════

    function test_processRepayment_autoCompletes() public {
        MerchantVault vault = _makeVault(10_000e6, 1);
        _fundSenior(vault, 10_000e6);

        // New model: completion when creditDrawn == 0 && accruedInterest == 0
        // No time warp → accruedInterest = 0, need to repay creditDrawn (= 10K)
        uint256 principal = vault.creditDrawn();
        _repay(vault, principal);

        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Completed));
    }

    function test_claimReturns_afterCompleted() public {
        MerchantVault vault = _makeVault(10_000e6, 1);
        _fundSenior(vault, 10_000e6);

        // Repay full principal (no interest accrued since no time passed)
        _repay(vault, vault.creditDrawn());

        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Completed));

        uint256 claimable = vault.getClaimable(seniorInvestor);
        assertTrue(claimable > 0);

        uint256 before = usdc.balanceOf(seniorInvestor);
        vm.prank(seniorInvestor);
        vault.claimReturns();
        assertTrue(usdc.balanceOf(seniorInvestor) - before > 0);
    }

    // ════════════════════════════════════════════════════════════════
    // 5. State transition guards
    // ════════════════════════════════════════════════════════════════

    function test_invest_whenActive_reverts() public {
        MerchantVault vault = _makeVault(10_000e6, 2);
        _fundSenior(vault, 10_000e6); // activates

        vm.startPrank(communityInvestorA);
        usdc.approve(address(vault), 1_000e6);
        vm.expectRevert(Errors.InvalidVaultState.selector);
        vault.invest(1_000e6);
        vm.stopPrank();
    }

    function test_releaseTranche_whenFundraising_reverts() public {
        MerchantVault vault = _makeVault(10_000e6, 2);
        // Partially funded, still Fundraising

        vm.startPrank(seniorInvestor);
        usdc.approve(address(vault), 5_000e6);
        vault.investSenior(5_000e6);
        vm.stopPrank();

        vm.prank(admin);
        vm.expectRevert(Errors.InvalidVaultState.selector);
        vault.releaseTranche();
    }

    function test_processRepayment_whenDefaulted_reverts() public {
        MerchantVault vault = _makeVault(10_000e6, 2);
        _fundSenior(vault, 10_000e6);

        vm.prank(admin);
        vault.markDefault();

        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(vault), 1_000e6);
        vm.expectRevert(Errors.InvalidVaultState.selector);
        vault.processRepayment(1_000e6);
    }

    function test_processRepayment_whenCancelled_reverts() public {
        MerchantVault vault = _makeVault(10_000e6, 2);

        vm.startPrank(seniorInvestor);
        usdc.approve(address(vault), 5_000e6);
        vault.investSenior(5_000e6);
        vm.stopPrank();

        vm.prank(admin);
        vault.cancel();

        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(vault), 1_000e6);
        vm.expectRevert(Errors.InvalidVaultState.selector);
        vault.processRepayment(1_000e6);
    }

    // ════════════════════════════════════════════════════════════════
    // 6. Multi-repayment incremental claims
    // ════════════════════════════════════════════════════════════════

    function test_claimReturns_incrementalRepayments() public {
        MerchantVault vault = _makeVault(10_000e6, 2);
        _fundSenior(vault, 10_000e6);

        // Three partial repayments. No time warp → all goes to principal.
        // Platform fee = 2% of principal. But principalPortion in waterfall = full amount.
        // Senior gets all (seniorFunded = 10K, all owed to senior)
        _repay(vault, 2_000e6);
        _repay(vault, 2_000e6);
        _repay(vault, 2_000e6);

        // Each 2K goes fully to senior principal repayment (no interest, no yield)
        uint256 claimable = vault.getClaimable(seniorInvestor);
        assertEq(claimable, 6_000e6);

        vm.prank(seniorInvestor);
        vault.claimReturns();

        assertEq(vault.getClaimable(seniorInvestor), 0);

        // More repayments → more to claim
        _repay(vault, 1_000e6);
        assertTrue(vault.getClaimable(seniorInvestor) > 0);
    }
}
