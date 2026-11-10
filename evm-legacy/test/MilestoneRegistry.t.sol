// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {MilestoneRegistry} from "../src/MilestoneRegistry.sol";
import {IMilestoneRegistry} from "../src/interfaces/IMilestoneRegistry.sol";
import {MerchantVault} from "../src/MerchantVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {Errors} from "../src/libraries/Errors.sol";

contract MilestoneRegistryTest is Test {
    MilestoneRegistry public milestones;
    MerchantVault public vault;
    MockUSDC public usdc;

    address admin = makeAddr("admin");
    address agent = makeAddr("agent");
    address verifier1 = makeAddr("verifier1");
    address verifier2 = makeAddr("verifier2");
    address verifier3 = makeAddr("verifier3");
    address newAdmin = makeAddr("newAdmin");
    address fakeRouter = makeAddr("fakeRouter");

    uint256 constant TARGET = 50_000e6;
    bytes32 constant EVIDENCE = keccak256("ipfs://evidence-hash");

    function setUp() public {
        usdc = new MockUSDC();
        milestones = new MilestoneRegistry(admin);

        // Create a funded vault so milestone can call vault.getAgent()
        vault = new MerchantVault(
            MerchantVault.VaultParams({
                usdc: address(usdc),
                agent: agent,
                admin: admin,
                factory: admin, // admin acts as factory in unit tests
                targetAmount: TARGET,
                interestRateBps: 1200,
                durationSeconds: 180 days,
                numTranches: 3,
                platformFeeBps: 200,
                platformFeeRecipient: admin,
                lateFeeBps: 0,
                gracePeriodSeconds: 0,
                fundraisingDeadline: type(uint256).max
            })
        );

        // Wire milestone registry to vault
        vm.prank(admin);
        vault.setMilestoneRegistry(address(milestones));

        // Fund vault to get to Active state
        usdc.mint(admin, TARGET);
        vm.startPrank(admin);
        usdc.approve(address(vault), TARGET);
        vault.investSenior(TARGET);
        vm.stopPrank();

        // Add verifiers
        vm.startPrank(admin);
        milestones.addVerifier(verifier1);
        milestones.addVerifier(verifier2);
        milestones.addVerifier(verifier3);
        vm.stopPrank();
    }

    // ════════════════════════════════════════════════════════════════
    // Initialize Milestone
    // ════════════════════════════════════════════════════════════════

    function test_initializeMilestone_setsPending() public {
        vm.prank(admin);
        milestones.initializeMilestone(address(vault), 1, 2);

        IMilestoneRegistry.Milestone memory m = milestones.getMilestone(address(vault), 1);
        assertEq(m.vault, address(vault));
        assertEq(m.trancheIndex, 1);
        assertEq(m.requiredApprovals, 2);
        assertEq(uint8(m.status), uint8(IMilestoneRegistry.MilestoneStatus.Pending));
        assertEq(m.approvalCount, 0);
    }

    function test_initializeMilestone_onlyAdmin() public {
        vm.prank(agent);
        vm.expectRevert(Errors.Unauthorized.selector);
        milestones.initializeMilestone(address(vault), 1, 2);
    }

    function test_initializeMilestone_duplicate_reverts() public {
        vm.prank(admin);
        milestones.initializeMilestone(address(vault), 1, 2);

        vm.prank(admin);
        vm.expectRevert(Errors.MilestoneAlreadyFinalized.selector);
        milestones.initializeMilestone(address(vault), 1, 2);
    }

    // ════════════════════════════════════════════════════════════════
    // Submit Milestone
    // ════════════════════════════════════════════════════════════════

    function test_submitMilestone_updatesStatus() public {
        vm.prank(admin);
        milestones.initializeMilestone(address(vault), 1, 2);

        vm.prank(agent);
        milestones.submitMilestone(address(vault), 1, EVIDENCE);

        IMilestoneRegistry.Milestone memory m = milestones.getMilestone(address(vault), 1);
        assertEq(uint8(m.status), uint8(IMilestoneRegistry.MilestoneStatus.Submitted));
        assertEq(m.evidenceHash, EVIDENCE);
        assertTrue(m.submittedAt > 0);
    }

    function test_submitMilestone_onlyAgent() public {
        vm.prank(admin);
        milestones.initializeMilestone(address(vault), 1, 2);

        vm.prank(verifier1);
        vm.expectRevert(Errors.Unauthorized.selector);
        milestones.submitMilestone(address(vault), 1, EVIDENCE);
    }

    function test_submitMilestone_notPending_reverts() public {
        vm.prank(admin);
        milestones.initializeMilestone(address(vault), 1, 2);

        vm.prank(agent);
        milestones.submitMilestone(address(vault), 1, EVIDENCE);

        // Second submit on already-submitted milestone
        vm.prank(agent);
        vm.expectRevert(Errors.MilestoneNotPending.selector);
        milestones.submitMilestone(address(vault), 1, EVIDENCE);
    }

    // ════════════════════════════════════════════════════════════════
    // Vote Milestone
    // ════════════════════════════════════════════════════════════════

    function test_voteMilestone_incrementsApproval() public {
        _submitMilestone(1);

        vm.prank(verifier1);
        milestones.voteMilestone(address(vault), 1, true);

        IMilestoneRegistry.Milestone memory m = milestones.getMilestone(address(vault), 1);
        assertEq(m.approvalCount, 1);
        assertEq(uint8(m.status), uint8(IMilestoneRegistry.MilestoneStatus.Submitted));
    }

    function test_voteMilestone_reachesThreshold_approves() public {
        _submitMilestone(1);

        vm.prank(verifier1);
        milestones.voteMilestone(address(vault), 1, true);

        // Second vote reaches threshold — this is where MilestoneApproved fires
        vm.expectEmit(true, true, false, false);
        emit IMilestoneRegistry.MilestoneApproved(address(vault), 1);

        vm.prank(verifier2);
        milestones.voteMilestone(address(vault), 1, true); // requiredApprovals = 2

        IMilestoneRegistry.Milestone memory m = milestones.getMilestone(address(vault), 1);
        assertEq(uint8(m.status), uint8(IMilestoneRegistry.MilestoneStatus.Approved));
        assertTrue(milestones.isMilestoneApproved(address(vault), 1));
    }

    function test_voteMilestone_rejection() public {
        _submitMilestone(1);

        vm.prank(verifier1);
        milestones.voteMilestone(address(vault), 1, false);
        vm.prank(verifier2);
        milestones.voteMilestone(address(vault), 1, false); // 2 rejections = requiredApprovals

        IMilestoneRegistry.Milestone memory m = milestones.getMilestone(address(vault), 1);
        assertEq(uint8(m.status), uint8(IMilestoneRegistry.MilestoneStatus.Rejected));
        assertFalse(milestones.isMilestoneApproved(address(vault), 1));
    }

    function test_voteMilestone_doubleVote_reverts() public {
        _submitMilestone(1);

        vm.prank(verifier1);
        milestones.voteMilestone(address(vault), 1, true);

        vm.prank(verifier1);
        vm.expectRevert(Errors.MilestoneAlreadyVoted.selector);
        milestones.voteMilestone(address(vault), 1, true);
    }

    function test_voteMilestone_onlyVerifier() public {
        _submitMilestone(1);

        vm.prank(agent);
        vm.expectRevert(Errors.Unauthorized.selector);
        milestones.voteMilestone(address(vault), 1, true);
    }

    // ════════════════════════════════════════════════════════════════
    // Tranche Release Gate
    // ════════════════════════════════════════════════════════════════

    function test_releaseTranche_requiresMilestone() public {
        // Milestone registry is set but milestone 1 is not approved
        vm.prank(admin);
        milestones.initializeMilestone(address(vault), 1, 2);

        vm.prank(admin);
        vm.expectRevert(Errors.MilestoneNotApproved.selector);
        vault.releaseTranche();
    }

    function test_releaseTranche_withApprovedMilestone() public {
        // Initialize, submit and approve milestone 1 (gates first tranche release)
        _submitMilestone(1);
        vm.prank(verifier1);
        milestones.voteMilestone(address(vault), 1, true);
        vm.prank(verifier2);
        milestones.voteMilestone(address(vault), 1, true);

        assertTrue(milestones.isMilestoneApproved(address(vault), 1));

        // Release should succeed now
        vm.prank(admin);
        vault.releaseTranche();
        assertEq(vault.tranchesReleased(), 1);
    }

    // ════════════════════════════════════════════════════════════════
    // Verifier Management
    // ════════════════════════════════════════════════════════════════

    function test_addRemoveVerifier() public {
        address newVerifier = makeAddr("newVerifier");

        vm.expectEmit(true, false, false, false);
        emit IMilestoneRegistry.VerifierAdded(newVerifier);

        vm.prank(admin);
        milestones.addVerifier(newVerifier);
        assertTrue(milestones.isVerifier(newVerifier));

        vm.expectEmit(true, false, false, false);
        emit IMilestoneRegistry.VerifierRemoved(newVerifier);

        vm.prank(admin);
        milestones.removeVerifier(newVerifier);
        assertFalse(milestones.isVerifier(newVerifier));
    }

    // ════════════════════════════════════════════════════════════════
    // Admin Transfer
    // ════════════════════════════════════════════════════════════════

    function test_adminTransfer_milestone() public {
        vm.prank(admin);
        milestones.proposeAdmin(newAdmin);

        vm.prank(newAdmin);
        milestones.acceptAdmin();

        assertEq(milestones.admin(), newAdmin);

        // Old admin can no longer call admin functions
        vm.prank(admin);
        vm.expectRevert(Errors.Unauthorized.selector);
        milestones.addVerifier(makeAddr("x"));
    }

    // ════════════════════════════════════════════════════════════════
    // Helpers
    // ════════════════════════════════════════════════════════════════

    function _submitMilestone(uint256 trancheIndex) internal {
        vm.prank(admin);
        milestones.initializeMilestone(address(vault), trancheIndex, 2);
        vm.prank(agent);
        milestones.submitMilestone(address(vault), trancheIndex, EVIDENCE);
    }
}
