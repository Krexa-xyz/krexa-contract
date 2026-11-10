// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IMilestoneRegistry {
    enum MilestoneStatus {
        Pending,
        Submitted,
        Approved,
        Rejected
    }

    struct Milestone {
        address vault;
        uint256 trancheIndex;
        bytes32 evidenceHash;
        MilestoneStatus status;
        uint256 approvalCount;
        uint256 rejectionCount;
        uint256 requiredApprovals;
        uint256 submittedAt;
    }

    event MilestoneInitialized(address indexed vault, uint256 indexed trancheIndex, uint256 requiredApprovals);
    event MilestoneSubmitted(address indexed vault, uint256 indexed trancheIndex, bytes32 evidenceHash);
    event MilestoneVoted(address indexed vault, uint256 indexed trancheIndex, address indexed verifier, bool approved);
    event MilestoneApproved(address indexed vault, uint256 indexed trancheIndex);
    event MilestoneRejected(address indexed vault, uint256 indexed trancheIndex);
    event VerifierAdded(address indexed verifier);
    event VerifierRemoved(address indexed verifier);
    event AdminTransferProposed(address indexed current, address indexed proposed);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    function initializeMilestone(address vault, uint256 trancheIndex, uint256 requiredApprovals) external;
    function submitMilestone(address vault, uint256 trancheIndex, bytes32 evidenceHash) external;
    function voteMilestone(address vault, uint256 trancheIndex, bool approve) external;
    function addVerifier(address verifier) external;
    function removeVerifier(address verifier) external;
    function proposeAdmin(address _newAdmin) external;
    function acceptAdmin() external;

    function getMilestone(address vault, uint256 trancheIndex) external view returns (Milestone memory);
    function isMilestoneApproved(address vault, uint256 trancheIndex) external view returns (bool);
    function isVerifier(address account) external view returns (bool);
}
