// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAgentRegistry — On-chain identity for AI agents (Solana-parity)
/// @notice Matches krexa-agent-registry Solana program 1:1.
///         Score range 200-850, KYA tiers 0-3, credit levels L0-L4, agent types 0-2.
interface IAgentRegistry {
    // ─── Enums ───────────────────────────────────────────────────────

    /// Credit levels derived from score + KYA tier (matches Solana calculate_level)
    enum CreditLevel { L0, L1, L2, L3, L4 }

    /// Agent enforcement type
    enum AgentType { Trader, Service, Hybrid }

    // ─── Structs ─────────────────────────────────────────────────────

    struct Agent {
        address wallet;
        address owner;
        string metadataURI;
        uint256 registeredAt;
        // Credit identity
        uint16 creditScore;       // 200-850
        CreditLevel creditLevel;  // L0-L4
        uint8 kyaTier;            // 0=Unverified, 1=Basic, 2=Enhanced, 3=Premium
        AgentType agentType;      // Trader/Service/Hybrid
        uint256 kyaVerifiedAt;
        uint256 scoreUpdatedAt;
        // Lifetime stats
        uint256 totalVolumeUsd;
        uint256 totalTrades;
        uint256 totalRepaid;
        uint256 totalBorrowed;
        uint8 liquidationCount;
        // Links
        address walletContract;   // linked AgentWallet contract
        bool hasWallet;
        bool hasActiveCreditLine;
        address vault;
        // Status
        bool active;
    }

    struct OwnershipTransfer {
        address proposedOwner;
        uint256 proposedAt;
    }

    // ─── Events ──────────────────────────────────────────────────────

    event AgentRegistered(address indexed wallet, address indexed owner, string metadataURI);
    event AgentUpdated(address indexed wallet, string metadataURI);
    event VaultLinked(address indexed wallet, address indexed vault);
    event WalletLinked(address indexed agent, address indexed walletContract);
    event AgentDeactivated(address indexed wallet);
    event AgentReactivated(address indexed wallet, CreditLevel newLevel);

    event KyaUpdated(address indexed wallet, uint8 oldTier, uint8 newTier, CreditLevel newLevel);
    event CreditScoreUpdated(address indexed wallet, uint16 oldScore, uint16 newScore, CreditLevel oldLevel, CreditLevel newLevel);
    event LiquidationRecorded(address indexed wallet, uint16 newScore, CreditLevel newLevel, uint8 liquidationCount);
    event AgentTypeSet(address indexed wallet, AgentType agentType);

    event ScoreAttested(address indexed wallet, bytes32 attestationHash, uint256 attestedAt);
    event LegalAgreementSigned(address indexed wallet, bytes32 agreementHash, uint256 signedAt);

    event OwnershipTransferProposed(address indexed agent, address indexed currentOwner, address indexed proposedOwner);
    event OwnershipTransferAccepted(address indexed agent, address indexed oldOwner, address indexed newOwner);
    event OwnershipTransferCancelled(address indexed agent, address indexed cancelledBy);

    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event WalletProgramUpdated(address indexed oldProgram, address indexed newProgram);
    event FactoryUpdated(address indexed oldFactory, address indexed newFactory);
    event PaymentRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event AdminTransferProposed(address indexed current, address indexed proposed);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    // ─── Agent Lifecycle ─────────────────────────────────────────────

    function registerAgent(string calldata metadataURI) external;
    function updateMetadata(string calldata metadataURI) external;
    function deactivateAgent(address agent) external;
    function reactivateAgent(address agent) external;

    // ─── Credit Identity (oracle/admin) ──────────────────────────────

    function updateKya(address agent, uint8 newTier) external;
    function updateCreditScore(address agent, uint16 newScore) external;
    function recordLiquidation(address agent) external;
    function setAgentType(address agent, AgentType agentType) external;
    function attestScore(address agent, bytes32 scoreHash) external;

    // ─── Legal ───────────────────────────────────────────────────────

    function signLegalAgreement(address agent, bytes32 agreementHash) external;

    // ─── Stats (authorized callers only) ─────────────────────────────

    function updateAgentStats(address agent, uint256 volume, uint256 trades, uint256 repaid, uint256 borrowed) external;
    function linkVault(address agent, address vault) external;
    function linkWallet(address agent, address walletContract) external;
    function incrementPaymentsSent(address agent, uint256 amount) external;
    function incrementPaymentsReceived(address agent, uint256 amount) external;

    // ─── Ownership Transfer ──────────────────────────────────────────

    function proposeOwnershipTransfer(address agent, address newOwner) external;
    function acceptOwnershipTransfer(address agent) external;
    function cancelOwnershipTransfer(address agent) external;

    // ─── Admin Config ────────────────────────────────────────────────

    function setOracle(address _oracle) external;
    function setWalletProgram(address _walletProgram) external;
    function setFactory(address _factory) external;
    function setPaymentRouter(address _router) external;
    function proposeAdmin(address _newAdmin) external;
    function acceptAdmin() external;
    function pause() external;
    function unpause() external;

    // ─── View Functions ──────────────────────────────────────────────

    function getAgent(address wallet) external view returns (Agent memory);
    function isRegistered(address wallet) external view returns (bool);
    function hasActiveCreditLine(address wallet) external view returns (bool);
    function getVault(address wallet) external view returns (address);
    function getAllAgents() external view returns (address[] memory);
    function getAgentCount() external view returns (uint256);
    function getCreditLevel(address wallet) external view returns (CreditLevel);
    function getKyaTier(address wallet) external view returns (uint8);
    function isCreditValid(address wallet) external view returns (bool);
    function isAgentEligible(address wallet, CreditLevel requiredLevel) external view returns (bool);
    function getOwnershipTransfer(address agent) external view returns (OwnershipTransfer memory);
    function calculateLevel(uint16 score, uint8 kyaTier) external pure returns (CreditLevel);
}
