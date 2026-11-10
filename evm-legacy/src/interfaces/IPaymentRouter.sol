// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPaymentRouter {
    struct X402Payment {
        address from;
        address to;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
        bytes32 paymentId;
    }

    struct Settlement {
        address vault;
        uint16 repaymentRateBps;
        uint256 totalRouted;
        uint256 totalPayments;
        uint256 lastPaymentAt;
        uint64 minPaymentInterval;
        uint256 maxSinglePayment;
        bool active;
    }

    // ── Revenue Validation Structs (Solana parity) ──

    struct RevenueValidator {
        address merchant;
        address agentWallet;
        address agentOwner;
        uint256 expectedDailyRevenue;
        uint256 totalCredit;
        uint256 cumulativeValidatedRevenue;
        uint256 totalDisbursed;
        uint256 planCreatedAt;
        uint8 revenueIntegrityViolations;
        bool isActive;
    }

    struct PaymentRecord {
        address source;
        uint256 amount;
        uint256 timestamp;
        uint8 classification; // 0=Verified, 1=Rejected, 2=Quarantined, 3=PendingKeeper
        bool isX402;
        uint16 patternScore;
    }

    struct OutflowRecord {
        address destination;
        uint256 amount;
        uint256 timestamp;
    }

    // ── Original Events ──

    event PaymentExecuted(
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 repaymentAmount,
        bytes32 indexed paymentId,
        uint256 nonce
    );
    event SettlementCreated(address indexed agent, address indexed vault, uint16 repaymentRateBps);
    event SettlementDeactivated(address indexed agent);
    event SettlementUpdated(address indexed agent, uint16 repaymentRateBps);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event FactoryUpdated(address indexed oldFactory, address indexed newFactory);
    event AdminTransferProposed(address indexed current, address indexed proposed);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    // ── Platform Fee Events (Solana parity) ──

    event PlatformFeeCollected(address indexed merchant, uint256 fee);
    event PlatformTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event PlatformFeeUpdated(uint16 oldBps, uint16 newBps);

    // ── Revenue Validation Events (Solana parity) ──

    event RevenueClassified(
        address indexed merchant,
        address indexed source,
        uint256 amount,
        uint8 classification,
        uint8 reason,
        uint16 patternScore
    );
    event RevenueSourceRegistered(address indexed merchant, address source);
    event RevenueSourceRemoved(address indexed merchant, address source);
    event AssociatedWalletAdded(address indexed merchant, address wallet);
    event QuarantineReviewed(address indexed merchant, uint8 paymentIndex, uint8 decision, uint256 amount);
    event RetroactiveRejection(
        address indexed merchant,
        uint256 amount,
        uint256 oldCumulative,
        uint256 newCumulative,
        uint8 violations
    );
    event OutflowRecorded(address indexed merchant, address destination, uint256 amount);
    event BlocklistUpdated(address wallet, bool added);
    event PlatformWhitelistUpdated(address wallet, bool added);
    event ValidatorCreated(address indexed merchant);

    // ── A2A Payment Events ──

    event AgentPayment(
        address indexed fromAgent,
        address indexed toAgent,
        address fromWallet,
        address toWallet,
        uint256 amount,
        uint256 platformFee,
        bytes32 memo
    );
    event AgentPaymentBatch(address indexed fromAgent, uint256 totalAmount, uint256 count);

    // ── Original Functions ──

    function executePayment(X402Payment calldata payment, bytes calldata signature) external;
    function executeFacilitatedPayment(X402Payment calldata payment) external;
    function createSettlement(
        address agent,
        address vault,
        uint16 repaymentRateBps,
        uint64 minPaymentInterval,
        uint256 maxSinglePayment
    ) external;
    function deactivateSettlement(address agent) external;
    function updateSettlement(address agent, uint16 repaymentRateBps) external;
    function setFactory(address _factory) external;
    function setOracle(address _oracle) external;
    function pause() external;
    function unpause() external;
    function proposeAdmin(address _newAdmin) external;
    function acceptAdmin() external;
    function getSettlement(address agent) external view returns (Settlement memory);
    function isNonceUsed(address agent, uint256 nonce) external view returns (bool);

    // ── Revenue Validation Functions (Solana parity) ──

    function setPlatformTreasury(address treasury) external;
    function setPlatformFeeBps(uint16 feeBps) external;
    function createRevenueValidator(
        address merchant,
        address agentWallet,
        address agentOwner,
        uint256 expectedDailyRevenue,
        uint256 totalCredit
    ) external;
    function registerRevenueSource(address merchant, address source) external;
    function removeRevenueSource(address merchant, address source) external;
    function addAssociatedWallet(address merchant, address wallet) external;
    function updateValidatorParams(
        address merchant,
        uint256 expectedDailyRevenue,
        uint256 totalCredit,
        uint256 totalDisbursed
    ) external;
    function validateRevenue(address merchant, address source, uint256 amount, bool isX402) external;
    function recordOutflow(address merchant, address destination, uint256 amount) external;
    function reviewQuarantined(address merchant, uint8 paymentIndex, uint8 decision) external;
    function retroactiveReject(address merchant, uint8 paymentIndex) external;
    function addToBlocklist(address wallet) external;
    function removeFromBlocklist(address wallet) external;
    function addToPlatformWhitelist(address wallet) external;
    function removeFromPlatformWhitelist(address wallet) external;

    // ── A2A Payment Functions ──

    function agentPay(
        address fromAgent,
        address toAgent,
        uint256 amount,
        bytes32 memo
    ) external;

    function agentPayBatch(
        address fromAgent,
        address[] calldata toAgents,
        uint256[] calldata amounts,
        bytes32[] calldata memos
    ) external;

    function getA2AStats(address agent) external view returns (uint256 sent, uint256 received, uint256 txCount);

    // ── Revenue Validation Views ──

    function getValidator(address merchant) external view returns (RevenueValidator memory);
    function getPaymentRecord(address merchant, uint8 index) external view returns (PaymentRecord memory);
    function isBlocklisted(address wallet) external view returns (bool);
    function isPlatformWhitelisted(address wallet) external view returns (bool);
    function platformFeeBps() external view returns (uint16);
    function platformTreasury() external view returns (address);
}
