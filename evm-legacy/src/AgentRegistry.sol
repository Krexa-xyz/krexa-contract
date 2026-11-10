// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentRegistry} from "./interfaces/IAgentRegistry.sol";
import {Errors} from "./libraries/Errors.sol";

/// @title AgentRegistry — On-chain identity for AI agents (Solana-parity)
/// @notice Matches krexa-agent-registry Solana program: score 200-850, KYA 0-3,
///         credit levels L0-L4, agent types, liquidation tracking, ownership transfer.
contract AgentRegistry is IAgentRegistry {
    // ─── Constants (match krexa-common/constants.rs) ─────────────────

    uint16 public constant MIN_CREDIT_SCORE = 200;
    uint16 public constant MAX_CREDIT_SCORE = 850;
    uint16 public constant DEFAULT_CREDIT_SCORE = 350;
    uint256 public constant SCORE_EXPIRY_SECONDS = 30 days;
    uint8 public constant LIQUIDATION_SCORE_PENALTY = 40;

    // ─── Storage ─────────────────────────────────────────────────────

    mapping(address => Agent) private _agents;
    mapping(address => OwnershipTransfer) private _ownershipTransfers;
    address[] private _allAgents;

    address public admin;
    address public pendingAdmin;
    address public oracle;
    address public walletProgram;  // authorized AgentWallet contract
    address public factory;
    address public paymentRouter;
    bool public isPaused;

    // ─── Modifiers ───────────────────────────────────────────────────

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Errors.Unauthorized();
        _;
    }

    modifier onlyOracle() {
        if (msg.sender != oracle) revert Errors.OnlyOracle();
        _;
    }

    modifier onlyAdminOrOracle() {
        if (msg.sender != admin && msg.sender != oracle) revert Errors.OnlyAdminOrOracle();
        _;
    }

    modifier onlyAuthorized() {
        if (
            msg.sender != factory &&
            msg.sender != paymentRouter &&
            msg.sender != walletProgram &&
            msg.sender != admin
        ) revert Errors.Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (isPaused) revert Errors.PlatformPaused();
        _;
    }

    modifier agentExists(address agent) {
        if (_agents[agent].registeredAt == 0) revert Errors.AgentNotRegistered();
        _;
    }

    modifier agentIsActive(address agent) {
        if (!_agents[agent].active) revert Errors.AgentNotActive();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────

    constructor(address _admin, address _oracle) {
        if (_admin == address(0)) revert Errors.ZeroAddress();
        if (_oracle == address(0)) revert Errors.ZeroAddress();
        admin = _admin;
        oracle = _oracle;
    }

    // ─── Agent Lifecycle ─────────────────────────────────────────────

    function registerAgent(string calldata metadataURI) external whenNotPaused {
        if (_agents[msg.sender].registeredAt != 0) revert Errors.AgentAlreadyRegistered();
        if (bytes(metadataURI).length == 0) revert Errors.InvalidMetadata();

        Agent storage a = _agents[msg.sender];
        a.wallet = msg.sender;
        a.owner = msg.sender;
        a.metadataURI = metadataURI;
        a.registeredAt = block.timestamp;
        a.creditScore = DEFAULT_CREDIT_SCORE;
        a.creditLevel = CreditLevel.L0;
        a.scoreUpdatedAt = block.timestamp;
        a.active = true;

        _allAgents.push(msg.sender);
        emit AgentRegistered(msg.sender, msg.sender, metadataURI);
    }

    function updateMetadata(string calldata metadataURI) external agentExists(msg.sender) {
        if (bytes(metadataURI).length == 0) revert Errors.InvalidMetadata();
        _agents[msg.sender].metadataURI = metadataURI;
        emit AgentUpdated(msg.sender, metadataURI);
    }

    function deactivateAgent(address agent)
        external
        onlyAdmin
        agentExists(agent)
    {
        _agents[agent].active = false;
        _agents[agent].creditLevel = CreditLevel.L0;
        emit AgentDeactivated(agent);
    }

    function reactivateAgent(address agent)
        external
        onlyAdmin
        agentExists(agent)
    {
        if (_agents[agent].active) revert Errors.AgentAlreadyActive();
        _agents[agent].active = true;
        CreditLevel newLevel = _calculateLevel(_agents[agent].creditScore, _agents[agent].kyaTier);
        _agents[agent].creditLevel = newLevel;
        emit AgentReactivated(agent, newLevel);
    }

    // ─── Credit Identity ─────────────────────────────────────────────

    /// @notice Oracle or admin updates KYA tier. Auto-recalculates credit level.
    function updateKya(address agent, uint8 newTier)
        external
        whenNotPaused
        onlyAdminOrOracle
        agentExists(agent)
        agentIsActive(agent)
    {
        if (newTier > 3) revert Errors.InvalidKyaTier();

        Agent storage a = _agents[agent];
        uint8 oldTier = a.kyaTier;
        a.kyaTier = newTier;
        a.kyaVerifiedAt = block.timestamp;
        a.scoreUpdatedAt = block.timestamp;

        CreditLevel newLevel = _calculateLevel(a.creditScore, newTier);
        a.creditLevel = newLevel;

        emit KyaUpdated(agent, oldTier, newTier, newLevel);
    }

    /// @notice Oracle updates credit score (200-850) and recalculates level.
    function updateCreditScore(address agent, uint16 newScore)
        external
        whenNotPaused
        onlyOracle
        agentExists(agent)
        agentIsActive(agent)
    {
        if (newScore < MIN_CREDIT_SCORE || newScore > MAX_CREDIT_SCORE) {
            revert Errors.CreditScoreOutOfRange();
        }

        Agent storage a = _agents[agent];
        uint16 oldScore = a.creditScore;
        CreditLevel oldLevel = a.creditLevel;

        a.creditScore = newScore;
        a.scoreUpdatedAt = block.timestamp;
        CreditLevel newLevel = _calculateLevel(newScore, a.kyaTier);
        a.creditLevel = newLevel;

        emit CreditScoreUpdated(agent, oldScore, newScore, oldLevel, newLevel);
    }

    /// @notice Record a liquidation. -40 point penalty (immutable, floor 200). Called by wallet program.
    function recordLiquidation(address agent)
        external
        onlyAuthorized
        agentExists(agent)
    {
        Agent storage a = _agents[agent];
        a.liquidationCount += 1;

        uint16 newScore = a.creditScore;
        if (newScore > MIN_CREDIT_SCORE + LIQUIDATION_SCORE_PENALTY) {
            newScore -= LIQUIDATION_SCORE_PENALTY;
        } else {
            newScore = MIN_CREDIT_SCORE;
        }
        a.creditScore = newScore;

        CreditLevel newLevel = _calculateLevel(newScore, a.kyaTier);
        a.creditLevel = newLevel;

        emit LiquidationRecorded(agent, newScore, newLevel, a.liquidationCount);
    }

    /// @notice Admin or oracle sets the agent enforcement type.
    function setAgentType(address agent, AgentType agentType)
        external
        whenNotPaused
        onlyAdminOrOracle
        agentExists(agent)
        agentIsActive(agent)
    {
        _agents[agent].agentType = agentType;
        emit AgentTypeSet(agent, agentType);
    }

    /// @notice Oracle stores keccak256(agent, score, level, timestamp) for third-party verification.
    function attestScore(address agent, bytes32 scoreHash)
        external
        onlyOracle
        agentExists(agent)
        agentIsActive(agent)
    {
        emit ScoreAttested(agent, scoreHash, block.timestamp);
    }

    // ─── Legal ───────────────────────────────────────────────────────

    /// @notice Agent or owner signs a legal credit agreement. Required for L3-L4.
    function signLegalAgreement(address agent, bytes32 agreementHash)
        external
        agentExists(agent)
        agentIsActive(agent)
    {
        Agent storage a = _agents[agent];
        if (msg.sender != a.wallet && msg.sender != a.owner) revert Errors.NotAgentOrOwner();
        emit LegalAgreementSigned(agent, agreementHash, block.timestamp);
    }

    // ─── Stats & Links (authorized callers) ──────────────────────────

    /// @notice Increment lifetime stats. Called by AgentWallet contract.
    function updateAgentStats(
        address agent,
        uint256 volume,
        uint256 trades,
        uint256 repaid,
        uint256 borrowed
    ) external onlyAuthorized agentExists(agent) {
        Agent storage a = _agents[agent];
        a.totalVolumeUsd += volume;
        a.totalTrades += trades;
        a.totalRepaid += repaid;
        a.totalBorrowed += borrowed;
    }

    function linkVault(address agent, address vault)
        external
        onlyAuthorized
        agentExists(agent)
    {
        if (vault == address(0)) revert Errors.ZeroAddress();
        _agents[agent].hasActiveCreditLine = true;
        _agents[agent].vault = vault;
        emit VaultLinked(agent, vault);
    }

    /// @notice One-time wallet link. Called by AgentWallet/Factory on creation.
    function linkWallet(address agent, address walletContract)
        external
        onlyAuthorized
        agentExists(agent)
    {
        if (_agents[agent].hasWallet) revert Errors.WalletAlreadyLinked();
        if (walletContract == address(0)) revert Errors.ZeroAddress();
        _agents[agent].walletContract = walletContract;
        _agents[agent].hasWallet = true;
        emit WalletLinked(agent, walletContract);
    }

    function incrementPaymentsSent(address agent, uint256 amount)
        external
        onlyAuthorized
        agentExists(agent)
    {
        _agents[agent].totalVolumeUsd += amount;
    }

    function incrementPaymentsReceived(address agent, uint256 amount)
        external
        onlyAuthorized
        agentExists(agent)
    {
        _agents[agent].totalVolumeUsd += amount;
    }

    // ─── Ownership Transfer (2-step) ─────────────────────────────────

    function proposeOwnershipTransfer(address agent, address newOwner)
        external
        agentExists(agent)
    {
        if (msg.sender != _agents[agent].owner) revert Errors.Unauthorized();
        if (newOwner == address(0)) revert Errors.ZeroAddress();

        _ownershipTransfers[agent] = OwnershipTransfer({
            proposedOwner: newOwner,
            proposedAt: block.timestamp
        });

        emit OwnershipTransferProposed(agent, msg.sender, newOwner);
    }

    function acceptOwnershipTransfer(address agent)
        external
        agentExists(agent)
    {
        OwnershipTransfer storage t = _ownershipTransfers[agent];
        if (t.proposedAt == 0) revert Errors.NoOwnershipTransferPending();
        if (msg.sender != t.proposedOwner) revert Errors.NotProposedOwner();

        address oldOwner = _agents[agent].owner;
        _agents[agent].owner = t.proposedOwner;
        delete _ownershipTransfers[agent];

        emit OwnershipTransferAccepted(agent, oldOwner, msg.sender);
    }

    function cancelOwnershipTransfer(address agent)
        external
        agentExists(agent)
    {
        if (msg.sender != _agents[agent].owner) revert Errors.Unauthorized();
        if (_ownershipTransfers[agent].proposedAt == 0) revert Errors.NoOwnershipTransferPending();
        delete _ownershipTransfers[agent];

        emit OwnershipTransferCancelled(agent, msg.sender);
    }

    // ─── Admin Config ────────────────────────────────────────────────

    function setOracle(address _oracle) external onlyAdmin {
        if (_oracle == address(0)) revert Errors.ZeroAddress();
        address old = oracle;
        oracle = _oracle;
        emit OracleUpdated(old, _oracle);
    }

    function setWalletProgram(address _walletProgram) external onlyAdmin {
        if (_walletProgram == address(0)) revert Errors.ZeroAddress();
        address old = walletProgram;
        walletProgram = _walletProgram;
        emit WalletProgramUpdated(old, _walletProgram);
    }

    function setFactory(address _factory) external onlyAdmin {
        if (_factory == address(0)) revert Errors.ZeroAddress();
        address old = factory;
        factory = _factory;
        emit FactoryUpdated(old, _factory);
    }

    function setPaymentRouter(address _router) external onlyAdmin {
        if (_router == address(0)) revert Errors.ZeroAddress();
        address old = paymentRouter;
        paymentRouter = _router;
        emit PaymentRouterUpdated(old, _router);
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

    function pause() external onlyAdmin {
        isPaused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyAdmin {
        isPaused = false;
        emit Unpaused(msg.sender);
    }

    // ─── View Functions ──────────────────────────────────────────────

    function getAgent(address wallet) external view returns (Agent memory) {
        return _agents[wallet];
    }

    function isRegistered(address wallet) external view returns (bool) {
        return _agents[wallet].registeredAt != 0;
    }

    function hasActiveCreditLine(address wallet) external view returns (bool) {
        return _agents[wallet].hasActiveCreditLine;
    }

    function getVault(address wallet) external view returns (address) {
        return _agents[wallet].vault;
    }

    function getAllAgents() external view returns (address[] memory) {
        return _allAgents;
    }

    function getAgentCount() external view returns (uint256) {
        return _allAgents.length;
    }

    function getCreditLevel(address wallet) external view returns (CreditLevel) {
        return _agents[wallet].creditLevel;
    }

    function getKyaTier(address wallet) external view returns (uint8) {
        return _agents[wallet].kyaTier;
    }

    /// @notice Returns true if the agent's credit score has been updated within SCORE_EXPIRY_SECONDS.
    function isCreditValid(address wallet) external view returns (bool) {
        uint256 updatedAt = _agents[wallet].scoreUpdatedAt;
        if (updatedAt == 0) return false;
        return block.timestamp <= updatedAt + SCORE_EXPIRY_SECONDS;
    }

    /// @notice Returns true if the agent is eligible for the requested credit level.
    ///         Matches Solana is_agent_eligible: active + level >= required + score not expired.
    function isAgentEligible(address wallet, CreditLevel requiredLevel) external view returns (bool) {
        Agent storage a = _agents[wallet];
        if (!a.active) return false;
        if (a.creditLevel < requiredLevel) return false;
        if (a.scoreUpdatedAt > 0 && block.timestamp > a.scoreUpdatedAt + SCORE_EXPIRY_SECONDS) {
            return false;
        }
        return true;
    }

    function getOwnershipTransfer(address agent) external view returns (OwnershipTransfer memory) {
        return _ownershipTransfers[agent];
    }

    /// @notice Pure credit level calculation matching Solana calculate_level exactly.
    ///         L4: score >= 750 && KYA >= 2 (Enhanced)
    ///         L3: score >= 650 && KYA >= 2 (Enhanced)
    ///         L2: score >= 500 && KYA >= 1 (Basic)
    ///         L1: any score   && KYA >= 1 (Basic)
    ///         L0: KYA == 0
    function calculateLevel(uint16 score, uint8 kyaTier) external pure returns (CreditLevel) {
        return _calculateLevel(score, kyaTier);
    }

    // ─── Internal ────────────────────────────────────────────────────

    function _calculateLevel(uint16 score, uint8 kyaTier) internal pure returns (CreditLevel) {
        if (score >= 750 && kyaTier >= 2) return CreditLevel.L4;
        if (score >= 650 && kyaTier >= 2) return CreditLevel.L3;
        if (score >= 500 && kyaTier >= 1) return CreditLevel.L2;
        if (kyaTier >= 1) return CreditLevel.L1;
        return CreditLevel.L0;
    }
}
