// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMilestoneRegistry} from "./interfaces/IMilestoneRegistry.sol";
import {IMerchantVault} from "./interfaces/IMerchantVault.sol";
import {Errors} from "./libraries/Errors.sol";

/// @title MilestoneRegistry — Evidence-based gating for tranche releases
/// @notice Verifiers vote on milestone evidence before tranches can be released
contract MilestoneRegistry is IMilestoneRegistry {
    address public admin;
    address public pendingAdmin;

    mapping(address => bool) public verifiers;
    // vault => trancheIndex => Milestone
    mapping(address => mapping(uint256 => Milestone)) private _milestones;
    // vault => trancheIndex => verifier => voted
    mapping(address => mapping(uint256 => mapping(address => bool))) public hasVoted;

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Errors.Unauthorized();
        _;
    }

    modifier onlyVerifier() {
        if (!verifiers[msg.sender]) revert Errors.Unauthorized();
        _;
    }

    constructor(address _admin) {
        if (_admin == address(0)) revert Errors.ZeroAddress();
        admin = _admin;
    }

    // ─── Admin ───────────────────────────────────────────────────

    function addVerifier(address verifier) external onlyAdmin {
        if (verifier == address(0)) revert Errors.ZeroAddress();
        verifiers[verifier] = true;
        emit VerifierAdded(verifier);
    }

    function removeVerifier(address verifier) external onlyAdmin {
        verifiers[verifier] = false;
        emit VerifierRemoved(verifier);
    }

    function proposeAdmin(address _newAdmin) external onlyAdmin {
        if (_newAdmin == address(0)) revert Errors.ZeroAddress();
        pendingAdmin = _newAdmin;
        emit AdminTransferProposed(admin, _newAdmin);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert Errors.Unauthorized();
        address old = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferred(old, admin);
    }

    // ─── Milestone Lifecycle ─────────────────────────────────────

    function initializeMilestone(
        address vault,
        uint256 trancheIndex,
        uint256 requiredApprovals
    ) external onlyAdmin {
        if (vault == address(0)) revert Errors.ZeroAddress();
        if (requiredApprovals == 0) revert Errors.InvalidAmount();

        Milestone storage m = _milestones[vault][trancheIndex];
        if (m.requiredApprovals != 0) revert Errors.MilestoneAlreadyFinalized();

        m.vault = vault;
        m.trancheIndex = trancheIndex;
        m.requiredApprovals = requiredApprovals;
        m.status = MilestoneStatus.Pending;

        emit MilestoneInitialized(vault, trancheIndex, requiredApprovals);
    }

    function submitMilestone(
        address vault,
        uint256 trancheIndex,
        bytes32 evidenceHash
    ) external {
        Milestone storage m = _milestones[vault][trancheIndex];
        if (m.requiredApprovals == 0) revert Errors.InvalidMilestoneId();
        if (m.status != MilestoneStatus.Pending) revert Errors.MilestoneNotPending();

        // Only the vault's agent can submit evidence
        address agent = IMerchantVault(vault).getAgent();
        if (msg.sender != agent) revert Errors.Unauthorized();

        m.evidenceHash = evidenceHash;
        m.status = MilestoneStatus.Submitted;
        m.submittedAt = block.timestamp;

        emit MilestoneSubmitted(vault, trancheIndex, evidenceHash);
    }

    function voteMilestone(
        address vault,
        uint256 trancheIndex,
        bool approve
    ) external onlyVerifier {
        Milestone storage m = _milestones[vault][trancheIndex];
        if (m.status != MilestoneStatus.Submitted) revert Errors.MilestoneNotPending();
        if (hasVoted[vault][trancheIndex][msg.sender]) revert Errors.MilestoneAlreadyVoted();

        hasVoted[vault][trancheIndex][msg.sender] = true;

        if (approve) {
            m.approvalCount++;
            emit MilestoneVoted(vault, trancheIndex, msg.sender, true);

            if (m.approvalCount >= m.requiredApprovals) {
                m.status = MilestoneStatus.Approved;
                emit MilestoneApproved(vault, trancheIndex);
            }
        } else {
            m.rejectionCount++;
            emit MilestoneVoted(vault, trancheIndex, msg.sender, false);

            if (m.rejectionCount >= m.requiredApprovals) {
                m.status = MilestoneStatus.Rejected;
                emit MilestoneRejected(vault, trancheIndex);
            }
        }
    }

    // ─── View ────────────────────────────────────────────────────

    function getMilestone(address vault, uint256 trancheIndex) external view returns (Milestone memory) {
        return _milestones[vault][trancheIndex];
    }

    function isMilestoneApproved(address vault, uint256 trancheIndex) external view returns (bool) {
        return _milestones[vault][trancheIndex].status == MilestoneStatus.Approved;
    }

    function isVerifier(address account) external view returns (bool) {
        return verifiers[account];
    }
}
