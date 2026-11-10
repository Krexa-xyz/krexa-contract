// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPaymentRouter} from "./interfaces/IPaymentRouter.sol";
import {IAgentRegistry} from "./interfaces/IAgentRegistry.sol";
import {IMerchantVault} from "./interfaces/IMerchantVault.sol";
import {SignatureLib} from "./libraries/SignatureLib.sol";
import {Errors} from "./libraries/Errors.sol";

/// @title PaymentRouter — x402 payment execution + revenue splitting + revenue validation
/// @notice Solana-parity: platform fee, 3-layer revenue source validation, blocklist/whitelist
contract PaymentRouter is IPaymentRouter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Constants (match krexa-common) ──────────────────────────────

    uint16 public constant MAX_SPLIT_BPS = 5_000;
    uint16 public constant MAX_PLATFORM_FEE_BPS = 1_000; // 10%
    uint16 public constant BPS_DENOMINATOR = 10_000;

    // Revenue validation constants (from krexa-common/constants.rs)
    uint8 public constant MAX_REVENUE_SOURCES = 30;
    uint8 public constant MAX_ASSOCIATED_WALLETS = 10;
    uint8 public constant PAYMENT_HISTORY_SIZE = 16;
    uint8 public constant OUTFLOW_HISTORY_SIZE = 8;
    uint16 public constant PATTERN_REJECT_THRESHOLD = 80;
    uint16 public constant PATTERN_QUARANTINE_THRESHOLD = 40;
    uint16 public constant ROUND_TRIP_SIMILARITY_BPS = 9_500; // 95%
    uint256 public constant ROUND_TRIP_WINDOW_SECONDS = 86_400; // 24h
    uint256 public constant AMOUNT_ANOMALY_MULTIPLIER = 10;
    uint256 public constant MODERATE_OVERSHOOT_MULTIPLIER = 5;
    uint256 public constant EXTREME_OVERSHOOT_MULTIPLIER = 20;
    uint16 public constant LARGE_PAYMENT_THRESHOLD_BPS = 5_000; // 50%

    // Classification codes
    uint8 public constant CLASSIFICATION_VERIFIED = 0;
    uint8 public constant CLASSIFICATION_REJECTED = 1;
    uint8 public constant CLASSIFICATION_QUARANTINED = 2;
    uint8 public constant CLASSIFICATION_PENDING_KEEPER = 3;

    // Rejection reason codes
    uint8 public constant REASON_NONE = 0;
    uint8 public constant REASON_SELF = 1;
    uint8 public constant REASON_OWNER = 2;
    uint8 public constant REASON_ASSOCIATED = 3;
    uint8 public constant REASON_BLOCKLIST = 5;
    uint8 public constant REASON_PATTERN = 6;
    uint8 public constant REASON_ECONOMIC = 7;

    // Review decision codes
    uint8 public constant DECISION_APPROVE = 0;
    uint8 public constant DECISION_REJECT = 1;
    uint8 public constant DECISION_APPROVE_AND_WHITELIST = 2;
    uint8 public constant DECISION_REJECT_AND_BLOCKLIST = 3;

    // ── Immutables ──────────────────────────────────────────────────

    IERC20 public immutable usdc;
    IAgentRegistry public immutable registry;

    // ── State ───────────────────────────────────────────────────────

    address public admin;
    address public oracle;
    address public factory;
    address public pendingAdmin;
    bool public paused;

    // Platform fee (Solana parity)
    uint16 public platformFeeBps;
    address public platformTreasury;

    // Settlements
    mapping(address => Settlement) private _settlements;
    mapping(address => mapping(uint256 => bool)) public usedNonces;
    mapping(address => bool) public approvedFacilitators;

    // Revenue validation (Solana parity)
    mapping(address => RevenueValidator) private _validators;
    mapping(address => address[]) private _registeredSources;
    mapping(address => address[]) private _associatedWallets;
    mapping(address => PaymentRecord[16]) private _paymentHistory;
    mapping(address => uint8) private _paymentHead;
    mapping(address => uint8) private _paymentCount;
    mapping(address => OutflowRecord[8]) private _outflowHistory;
    mapping(address => uint8) private _outflowHead;
    mapping(address => uint8) private _outflowCount;

    // Blocklist & whitelist (using mappings for O(1) lookup)
    mapping(address => bool) private _globalBlocklist;
    mapping(address => bool) private _platformWhitelist;

    // A2A payment stats
    mapping(address => uint256) private _a2aSent;
    mapping(address => uint256) private _a2aReceived;
    mapping(address => uint256) private _a2aTxCount;

    // ── Modifiers ───────────────────────────────────────────────────

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Errors.Unauthorized();
        _;
    }

    modifier onlyAdminOrFactory() {
        if (msg.sender != admin && msg.sender != factory) revert Errors.Unauthorized();
        _;
    }

    modifier onlyAdminOrOracle() {
        if (msg.sender != admin && msg.sender != oracle) revert Errors.OnlyAdminOrOracle();
        _;
    }

    modifier onlyOracle() {
        if (msg.sender != oracle) revert Errors.OnlyOracle();
        _;
    }

    modifier notPaused() {
        if (paused) revert Errors.PlatformPaused();
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────

    constructor(address _usdc, address _registry, address _admin, address _oracle) {
        if (_usdc == address(0) || _registry == address(0) || _admin == address(0) || _oracle == address(0))
            revert Errors.ZeroAddress();

        usdc = IERC20(_usdc);
        registry = IAgentRegistry(_registry);
        admin = _admin;
        oracle = _oracle;
    }

    // ── Admin Config ────────────────────────────────────────────────

    function setFactory(address _factory) external onlyAdmin {
        if (_factory == address(0)) revert Errors.ZeroAddress();
        address old = factory;
        factory = _factory;
        emit FactoryUpdated(old, _factory);
    }

    function setOracle(address _oracle) external onlyAdmin {
        if (_oracle == address(0)) revert Errors.ZeroAddress();
        address old = oracle;
        oracle = _oracle;
        emit OracleUpdated(old, _oracle);
    }

    function pause() external onlyAdmin {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyAdmin {
        paused = false;
        emit Unpaused(msg.sender);
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

    function setFacilitator(address facilitator, bool approved) external onlyAdmin {
        if (facilitator == address(0)) revert Errors.ZeroAddress();
        approvedFacilitators[facilitator] = approved;
    }

    // ── Platform Fee Config (Solana parity) ─────────────────────────

    function setPlatformTreasury(address _treasury) external onlyAdmin {
        if (_treasury == address(0)) revert Errors.ZeroAddress();
        address old = platformTreasury;
        platformTreasury = _treasury;
        emit PlatformTreasuryUpdated(old, _treasury);
    }

    function setPlatformFeeBps(uint16 _feeBps) external onlyAdmin {
        if (_feeBps > MAX_PLATFORM_FEE_BPS) revert Errors.FeeTooHigh();
        uint16 old = platformFeeBps;
        platformFeeBps = _feeBps;
        emit PlatformFeeUpdated(old, _feeBps);
    }

    // ── Execute Payment (x402) ──────────────────────────────────────

    function executePayment(X402Payment calldata payment, bytes calldata signature) external nonReentrant notPaused {
        // 1. Validate deadline
        if (block.timestamp > payment.deadline) revert Errors.PaymentExpired();

        // 2. Verify oracle signature
        bytes32 paymentHash = SignatureLib.paymentHash(
            payment.from, payment.to, payment.amount, payment.nonce, payment.deadline, payment.paymentId
        );
        if (!SignatureLib.verifyPaymentProof(paymentHash, signature, oracle))
            revert Errors.InvalidSignature();

        // 3. Replay protection
        if (usedNonces[payment.from][payment.nonce]) revert Errors.NonceAlreadyUsed();
        usedNonces[payment.from][payment.nonce] = true;

        // 4. Amount validation
        if (payment.amount == 0) revert Errors.InvalidAmount();

        // 5. Execute with platform fee + settlement split
        _executePaymentInternal(payment);
    }

    // ── Facilitated Payment ─────────────────────────────────────────

    function executeFacilitatedPayment(X402Payment calldata payment) external nonReentrant notPaused {
        if (!approvedFacilitators[msg.sender]) revert Errors.Unauthorized();
        if (block.timestamp > payment.deadline) revert Errors.PaymentExpired();
        if (usedNonces[msg.sender][payment.nonce]) revert Errors.NonceAlreadyUsed();
        usedNonces[msg.sender][payment.nonce] = true;
        if (payment.amount == 0) revert Errors.InvalidAmount();

        _executeFacilitatedInternal(payment);
    }

    // ── Internal Payment Logic ──────────────────────────────────────

    function _executePaymentInternal(X402Payment calldata payment) internal {
        Settlement storage settlement = _settlements[payment.to];

        // Platform fee (Solana parity)
        uint256 platformFee = 0;
        uint256 remainder = payment.amount;
        if (platformFeeBps > 0 && platformTreasury != address(0)) {
            platformFee = (payment.amount * platformFeeBps) / BPS_DENOMINATOR;
            remainder = payment.amount - platformFee;
        }

        uint256 repaymentAmount = 0;

        if (settlement.active) {
            // Rate limiting
            if (settlement.minPaymentInterval > 0) {
                if (block.timestamp < settlement.lastPaymentAt + settlement.minPaymentInterval)
                    revert Errors.RateLimitExceeded();
            }

            // Max payment cap
            if (settlement.maxSinglePayment > 0 && payment.amount > settlement.maxSinglePayment)
                revert Errors.PaymentTooLarge();

            // Calculate repayment from remainder (after platform fee)
            repaymentAmount = (remainder * settlement.repaymentRateBps) / BPS_DENOMINATOR;
            uint256 netAmount = remainder - repaymentAmount;

            // Pull full amount from payer
            usdc.safeTransferFrom(payment.from, address(this), payment.amount);

            // Platform fee to treasury
            if (platformFee > 0) {
                usdc.safeTransfer(platformTreasury, platformFee);
                emit PlatformFeeCollected(payment.to, platformFee);
            }

            // Repayment to vault
            if (repaymentAmount > 0) {
                usdc.forceApprove(settlement.vault, repaymentAmount);
                IMerchantVault(settlement.vault).processRepayment(repaymentAmount);
            }

            // Net to merchant
            if (netAmount > 0) {
                usdc.safeTransfer(payment.to, netAmount);
            }

            // Update stats
            settlement.totalRouted += repaymentAmount;
            settlement.totalPayments++;
            settlement.lastPaymentAt = block.timestamp;
        } else {
            // No active settlement
            if (platformFee > 0) {
                usdc.safeTransferFrom(payment.from, address(this), payment.amount);
                usdc.safeTransfer(platformTreasury, platformFee);
                usdc.safeTransfer(payment.to, remainder);
                emit PlatformFeeCollected(payment.to, platformFee);
            } else {
                usdc.safeTransferFrom(payment.from, payment.to, payment.amount);
            }
        }

        // Update agent stats
        try registry.incrementPaymentsSent(payment.from, payment.amount) {} catch {}
        try registry.incrementPaymentsReceived(payment.to, payment.amount) {} catch {}

        emit PaymentExecuted(
            payment.from, payment.to, payment.amount, repaymentAmount, payment.paymentId, payment.nonce
        );
    }

    function _executeFacilitatedInternal(X402Payment calldata payment) internal {
        Settlement storage settlement = _settlements[payment.to];

        // Platform fee
        uint256 platformFee = 0;
        uint256 remainder = payment.amount;
        if (platformFeeBps > 0 && platformTreasury != address(0)) {
            platformFee = (payment.amount * platformFeeBps) / BPS_DENOMINATOR;
            remainder = payment.amount - platformFee;
        }

        uint256 repaymentAmount = 0;

        if (settlement.active) {
            repaymentAmount = (remainder * settlement.repaymentRateBps) / BPS_DENOMINATOR;
            uint256 netAmount = remainder - repaymentAmount;

            usdc.safeTransferFrom(msg.sender, address(this), payment.amount);

            if (platformFee > 0) {
                usdc.safeTransfer(platformTreasury, platformFee);
                emit PlatformFeeCollected(payment.to, platformFee);
            }

            if (repaymentAmount > 0) {
                usdc.forceApprove(settlement.vault, repaymentAmount);
                IMerchantVault(settlement.vault).processRepayment(repaymentAmount);
            }

            if (netAmount > 0) {
                usdc.safeTransfer(payment.to, netAmount);
            }

            settlement.totalRouted += repaymentAmount;
            settlement.totalPayments++;
            settlement.lastPaymentAt = block.timestamp;
        } else {
            if (platformFee > 0) {
                usdc.safeTransferFrom(msg.sender, address(this), payment.amount);
                usdc.safeTransfer(platformTreasury, platformFee);
                usdc.safeTransfer(payment.to, remainder);
                emit PlatformFeeCollected(payment.to, platformFee);
            } else {
                usdc.safeTransferFrom(msg.sender, payment.to, payment.amount);
            }
        }

        try registry.incrementPaymentsSent(payment.from, payment.amount) {} catch {}
        try registry.incrementPaymentsReceived(payment.to, payment.amount) {} catch {}

        emit PaymentExecuted(
            payment.from, payment.to, payment.amount, repaymentAmount, payment.paymentId, payment.nonce
        );
    }

    // ── Settlement Management ───────────────────────────────────────

    function createSettlement(
        address agent,
        address vault,
        uint16 repaymentRateBps,
        uint64 minPaymentInterval,
        uint256 maxSinglePayment
    ) external onlyAdminOrFactory {
        if (agent == address(0) || vault == address(0)) revert Errors.ZeroAddress();
        if (repaymentRateBps > MAX_SPLIT_BPS) revert Errors.FeeTooHigh();

        _settlements[agent] = Settlement({
            vault: vault,
            repaymentRateBps: repaymentRateBps,
            totalRouted: 0,
            totalPayments: 0,
            lastPaymentAt: 0,
            minPaymentInterval: minPaymentInterval,
            maxSinglePayment: maxSinglePayment,
            active: true
        });

        emit SettlementCreated(agent, vault, repaymentRateBps);
    }

    function deactivateSettlement(address agent) external onlyAdmin {
        _settlements[agent].active = false;
        emit SettlementDeactivated(agent);
    }

    function updateSettlement(address agent, uint16 repaymentRateBps) external onlyAdmin {
        if (!_settlements[agent].active) revert Errors.SettlementNotActive();
        if (repaymentRateBps > MAX_SPLIT_BPS) revert Errors.FeeTooHigh();

        _settlements[agent].repaymentRateBps = repaymentRateBps;
        emit SettlementUpdated(agent, repaymentRateBps);
    }

    // ═════════════════════════════════════════════════════════════════
    // REVENUE SOURCE VALIDATION (Solana parity)
    // ═════════════════════════════════════════════════════════════════

    // ── Validator Lifecycle ──

    function createRevenueValidator(
        address merchant,
        address agentWallet,
        address agentOwner,
        uint256 expectedDailyRevenue,
        uint256 totalCredit
    ) external onlyAdminOrOracle {
        if (merchant == address(0)) revert Errors.ZeroAddress();
        if (_validators[merchant].isActive) revert Errors.ValidatorAlreadyExists();

        _validators[merchant] = RevenueValidator({
            merchant: merchant,
            agentWallet: agentWallet,
            agentOwner: agentOwner,
            expectedDailyRevenue: expectedDailyRevenue,
            totalCredit: totalCredit,
            cumulativeValidatedRevenue: 0,
            totalDisbursed: 0,
            planCreatedAt: block.timestamp,
            revenueIntegrityViolations: 0,
            isActive: true
        });

        emit ValidatorCreated(merchant);
    }

    function registerRevenueSource(address merchant, address source) external onlyAdminOrOracle {
        RevenueValidator storage v = _validators[merchant];
        if (!v.isActive) revert Errors.ValidatorNotActive();
        if (_registeredSources[merchant].length >= MAX_REVENUE_SOURCES) revert Errors.MaxSourcesReached();

        address[] storage sources = _registeredSources[merchant];
        for (uint256 i = 0; i < sources.length; i++) {
            if (sources[i] == source) revert Errors.SourceAlreadyRegistered();
        }
        sources.push(source);

        emit RevenueSourceRegistered(merchant, source);
    }

    function removeRevenueSource(address merchant, address source) external onlyAdminOrOracle {
        RevenueValidator storage v = _validators[merchant];
        if (!v.isActive) revert Errors.ValidatorNotActive();

        address[] storage sources = _registeredSources[merchant];
        bool found = false;
        for (uint256 i = 0; i < sources.length; i++) {
            if (sources[i] == source) {
                sources[i] = sources[sources.length - 1];
                sources.pop();
                found = true;
                break;
            }
        }
        if (!found) revert Errors.SourceNotFound();

        emit RevenueSourceRemoved(merchant, source);
    }

    function addAssociatedWallet(address merchant, address wallet) external onlyAdminOrOracle {
        RevenueValidator storage v = _validators[merchant];
        if (!v.isActive) revert Errors.ValidatorNotActive();
        if (_associatedWallets[merchant].length >= MAX_ASSOCIATED_WALLETS) revert Errors.MaxAssociatedWalletsReached();

        address[] storage wallets = _associatedWallets[merchant];
        for (uint256 i = 0; i < wallets.length; i++) {
            if (wallets[i] == wallet) revert Errors.WalletAlreadyAssociated();
        }
        wallets.push(wallet);

        emit AssociatedWalletAdded(merchant, wallet);
    }

    function updateValidatorParams(
        address merchant,
        uint256 expectedDailyRevenue,
        uint256 totalCredit,
        uint256 totalDisbursed
    ) external onlyAdminOrOracle {
        RevenueValidator storage v = _validators[merchant];
        if (!v.isActive) revert Errors.ValidatorNotActive();

        v.expectedDailyRevenue = expectedDailyRevenue;
        v.totalCredit = totalCredit;
        v.totalDisbursed = totalDisbursed;
    }

    // ── Revenue Validation ──

    function validateRevenue(
        address merchant,
        address source,
        uint256 amount,
        bool isX402
    ) external onlyAdminOrOracle notPaused {
        if (amount == 0) revert Errors.ZeroAmount();

        RevenueValidator storage v = _validators[merchant];
        if (!v.isActive) revert Errors.ValidatorNotActive();

        // Run 3-layer validation
        (uint8 classification, uint8 reason, uint16 patternScore) =
            _validateRevenueOnChain(source, amount, isX402, merchant);

        // Record in payment history ring buffer
        uint8 head = _paymentHead[merchant];
        _paymentHistory[merchant][head] = PaymentRecord({
            source: source,
            amount: amount,
            timestamp: block.timestamp,
            classification: classification,
            isX402: isX402,
            patternScore: patternScore
        });
        _paymentHead[merchant] = uint8((uint256(head) + 1) % PAYMENT_HISTORY_SIZE);
        if (_paymentCount[merchant] < PAYMENT_HISTORY_SIZE) {
            _paymentCount[merchant]++;
        }

        // Credit cumulative revenue for Verified and PendingKeeper
        if (classification == CLASSIFICATION_VERIFIED || classification == CLASSIFICATION_PENDING_KEEPER) {
            v.cumulativeValidatedRevenue += amount;
        }

        emit RevenueClassified(merchant, source, amount, classification, reason, patternScore);
    }

    function recordOutflow(
        address merchant,
        address destination,
        uint256 amount
    ) external onlyAdminOrOracle notPaused {
        uint8 head = _outflowHead[merchant];
        _outflowHistory[merchant][head] = OutflowRecord({
            destination: destination,
            amount: amount,
            timestamp: block.timestamp
        });
        _outflowHead[merchant] = uint8((uint256(head) + 1) % OUTFLOW_HISTORY_SIZE);
        if (_outflowCount[merchant] < OUTFLOW_HISTORY_SIZE) {
            _outflowCount[merchant]++;
        }

        emit OutflowRecorded(merchant, destination, amount);
    }

    // ── Quarantine Review ──

    function reviewQuarantined(
        address merchant,
        uint8 paymentIndex,
        uint8 decision
    ) external onlyAdminOrOracle notPaused {
        if (paymentIndex >= PAYMENT_HISTORY_SIZE) revert Errors.PaymentIndexOutOfBounds();
        if (decision > 3) revert Errors.InvalidDecision();

        PaymentRecord storage payment = _paymentHistory[merchant][paymentIndex];
        if (payment.classification != CLASSIFICATION_QUARANTINED &&
            payment.classification != CLASSIFICATION_PENDING_KEEPER) {
            revert Errors.NotQuarantined();
        }

        uint256 amount = payment.amount;
        bool wasPendingKeeper = payment.classification == CLASSIFICATION_PENDING_KEEPER;
        RevenueValidator storage v = _validators[merchant];

        if (decision == DECISION_APPROVE) {
            payment.classification = CLASSIFICATION_VERIFIED;
            if (!wasPendingKeeper) {
                v.cumulativeValidatedRevenue += amount;
            }
        } else if (decision == DECISION_REJECT) {
            payment.classification = CLASSIFICATION_REJECTED;
            if (wasPendingKeeper) {
                v.cumulativeValidatedRevenue -= amount;
                v.revenueIntegrityViolations++;
            }
        } else if (decision == DECISION_APPROVE_AND_WHITELIST) {
            payment.classification = CLASSIFICATION_VERIFIED;
            if (!wasPendingKeeper) {
                v.cumulativeValidatedRevenue += amount;
            }
            // Add source to registered sources
            address source = payment.source;
            if (_registeredSources[merchant].length < MAX_REVENUE_SOURCES) {
                _registeredSources[merchant].push(source);
            }
        } else if (decision == DECISION_REJECT_AND_BLOCKLIST) {
            payment.classification = CLASSIFICATION_REJECTED;
            if (wasPendingKeeper) {
                v.cumulativeValidatedRevenue -= amount;
                v.revenueIntegrityViolations++;
            }
            _globalBlocklist[payment.source] = true;
            emit BlocklistUpdated(payment.source, true);
        }

        emit QuarantineReviewed(merchant, paymentIndex, decision, amount);
    }

    function retroactiveReject(
        address merchant,
        uint8 paymentIndex
    ) external onlyAdminOrOracle notPaused {
        if (paymentIndex >= PAYMENT_HISTORY_SIZE) revert Errors.PaymentIndexOutOfBounds();

        PaymentRecord storage payment = _paymentHistory[merchant][paymentIndex];
        if (payment.classification != CLASSIFICATION_VERIFIED &&
            payment.classification != CLASSIFICATION_PENDING_KEEPER) {
            revert Errors.NotQuarantined();
        }

        uint256 amount = payment.amount;
        payment.classification = CLASSIFICATION_REJECTED;

        RevenueValidator storage v = _validators[merchant];
        uint256 oldCumulative = v.cumulativeValidatedRevenue;
        v.cumulativeValidatedRevenue -= amount;
        v.revenueIntegrityViolations++;

        emit RetroactiveRejection(
            merchant, amount, oldCumulative, v.cumulativeValidatedRevenue, v.revenueIntegrityViolations
        );
    }

    // ═════════════════════════════════════════════════════════════════
    // AGENT-TO-AGENT PAYMENTS (Monad-first)
    // ═════════════════════════════════════════════════════════════════

    /// @notice Agent-to-agent USDC payment with identity verification, platform fee,
    ///         revenue tracking, and settlement routing.
    /// @dev Caller must be the fromAgent (owner) or an approved facilitator.
    ///      fromAgent must have approved this contract for `amount` USDC.
    /// @param fromAgent Sending agent's registered address
    /// @param toAgent   Receiving agent's registered address
    /// @param amount    USDC amount (6 decimals)
    /// @param memo      Arbitrary 32-byte memo (invoice hash, service ID, etc.)
    function agentPay(
        address fromAgent,
        address toAgent,
        uint256 amount,
        bytes32 memo
    ) external nonReentrant notPaused {
        _executeAgentPay(fromAgent, toAgent, amount, memo);
    }

    /// @notice Batch agent-to-agent payments from a single sender.
    function agentPayBatch(
        address fromAgent,
        address[] calldata toAgents,
        uint256[] calldata amounts,
        bytes32[] calldata memos
    ) external nonReentrant notPaused {
        uint256 len = toAgents.length;
        if (len != amounts.length || len != memos.length) revert Errors.InvalidAmount();
        if (len == 0) revert Errors.InvalidAmount();

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < len; i++) {
            _executeAgentPay(fromAgent, toAgents[i], amounts[i], memos[i]);
            totalAmount += amounts[i];
        }

        emit AgentPaymentBatch(fromAgent, totalAmount, len);
    }

    /// @notice View A2A payment stats for an agent.
    function getA2AStats(address agent) external view returns (uint256 sent, uint256 received, uint256 txCount) {
        return (_a2aSent[agent], _a2aReceived[agent], _a2aTxCount[agent]);
    }

    // ── Internal A2A Logic ──

    function _executeAgentPay(
        address fromAgent,
        address toAgent,
        uint256 amount,
        bytes32 memo
    ) internal {
        // 1. Validate inputs
        if (fromAgent == address(0) || toAgent == address(0)) revert Errors.ZeroAddress();
        if (fromAgent == toAgent) revert Errors.InvalidAmount();
        if (amount == 0) revert Errors.ZeroAmount();

        // 2. Caller must be the sending agent or an approved facilitator
        if (msg.sender != fromAgent && !approvedFacilitators[msg.sender]) {
            revert Errors.Unauthorized();
        }

        // 3. Both agents must be registered and active
        if (!registry.isRegistered(fromAgent)) revert Errors.AgentNotRegistered();
        if (!registry.isRegistered(toAgent)) revert Errors.AgentNotRegistered();

        // 4. Blocklist check
        if (_globalBlocklist[fromAgent] || _globalBlocklist[toAgent]) revert Errors.Blocklisted();

        // 5. Resolve wallets
        //    Sender: always pull from the agent address (EOA) where USDC approval lives
        //    Receiver: deliver to linked wallet if exists, otherwise agent address
        address fromWallet = fromAgent;
        address toWallet = _resolveWallet(toAgent);

        // 6. Platform fee
        uint256 platformFee = 0;
        uint256 netAmount = amount;
        if (platformFeeBps > 0 && platformTreasury != address(0)) {
            platformFee = (amount * platformFeeBps) / BPS_DENOMINATOR;
            netAmount = amount - platformFee;
        }

        // 7. Pull USDC from sender
        usdc.safeTransferFrom(fromWallet, address(this), amount);

        // 8. Platform fee to treasury
        if (platformFee > 0) {
            usdc.safeTransfer(platformTreasury, platformFee);
            emit PlatformFeeCollected(fromAgent, platformFee);
        }

        // 9. Settlement routing for receiver (if active credit line)
        Settlement storage settlement = _settlements[toAgent];
        uint256 repaymentAmount = 0;

        if (settlement.active) {
            repaymentAmount = (netAmount * settlement.repaymentRateBps) / BPS_DENOMINATOR;
            uint256 merchantNet = netAmount - repaymentAmount;

            if (repaymentAmount > 0) {
                usdc.forceApprove(settlement.vault, repaymentAmount);
                IMerchantVault(settlement.vault).processRepayment(repaymentAmount);
            }

            if (merchantNet > 0) {
                usdc.safeTransfer(toWallet, merchantNet);
            }

            settlement.totalRouted += repaymentAmount;
            settlement.totalPayments++;
            settlement.lastPaymentAt = block.timestamp;
        } else {
            usdc.safeTransfer(toWallet, netAmount);
        }

        // 10. Update A2A stats
        _a2aSent[fromAgent] += amount;
        _a2aReceived[toAgent] += amount;
        _a2aTxCount[fromAgent]++;
        _a2aTxCount[toAgent]++;

        // 11. Update agent registry stats
        try registry.incrementPaymentsSent(fromAgent, amount) {} catch {}
        try registry.incrementPaymentsReceived(toAgent, amount) {} catch {}

        // 12. Credit receiver's revenue (if validator exists)
        RevenueValidator storage v = _validators[toAgent];
        if (v.isActive) {
            v.cumulativeValidatedRevenue += netAmount;
        }

        emit AgentPayment(fromAgent, toAgent, fromWallet, toWallet, amount, platformFee, memo);
    }

    /// @notice Resolve agent address to wallet contract address.
    ///         If agent has a linked wallet contract, use that. Otherwise use agent address.
    function _resolveWallet(address agent) internal view returns (address) {
        try registry.getAgent(agent) returns (IAgentRegistry.Agent memory a) {
            if (a.hasWallet && a.walletContract != address(0)) {
                return a.walletContract;
            }
        } catch {}
        return agent;
    }

    // ── Blocklist / Whitelist Management ──

    function addToBlocklist(address wallet) external onlyAdmin {
        _globalBlocklist[wallet] = true;
        emit BlocklistUpdated(wallet, true);
    }

    function removeFromBlocklist(address wallet) external onlyAdmin {
        _globalBlocklist[wallet] = false;
        emit BlocklistUpdated(wallet, false);
    }

    function addToPlatformWhitelist(address wallet) external onlyAdmin {
        _platformWhitelist[wallet] = true;
        emit PlatformWhitelistUpdated(wallet, true);
    }

    function removeFromPlatformWhitelist(address wallet) external onlyAdmin {
        _platformWhitelist[wallet] = false;
        emit PlatformWhitelistUpdated(wallet, false);
    }

    // ── View Functions ──────────────────────────────────────────────

    function getSettlement(address agent) external view returns (Settlement memory) {
        return _settlements[agent];
    }

    function isNonceUsed(address agent, uint256 nonce) external view returns (bool) {
        return usedNonces[agent][nonce];
    }

    function getValidator(address merchant) external view returns (RevenueValidator memory) {
        return _validators[merchant];
    }

    function getPaymentRecord(address merchant, uint8 index) external view returns (PaymentRecord memory) {
        if (index >= PAYMENT_HISTORY_SIZE) revert Errors.PaymentIndexOutOfBounds();
        return _paymentHistory[merchant][index];
    }

    function isBlocklisted(address wallet) external view returns (bool) {
        return _globalBlocklist[wallet];
    }

    function isPlatformWhitelisted(address wallet) external view returns (bool) {
        return _platformWhitelist[wallet];
    }

    function getRegisteredSources(address merchant) external view returns (address[] memory) {
        return _registeredSources[merchant];
    }

    function getAssociatedWallets(address merchant) external view returns (address[] memory) {
        return _associatedWallets[merchant];
    }

    // ── Internal: 3-Layer Revenue Validation ────────────────────────

    function _validateRevenueOnChain(
        address source,
        uint256 amount,
        bool isX402,
        address merchant
    ) internal view returns (uint8 classification, uint8 reason, uint16 patternScore) {
        RevenueValidator storage v = _validators[merchant];

        // Layer 1 — Source classification (hard rejects)
        if (source == v.agentWallet) {
            return (CLASSIFICATION_REJECTED, REASON_SELF, 0);
        }
        if (source == v.agentOwner) {
            return (CLASSIFICATION_REJECTED, REASON_OWNER, 0);
        }
        if (_isAssociatedWallet(merchant, source)) {
            return (CLASSIFICATION_REJECTED, REASON_ASSOCIATED, 0);
        }
        if (_globalBlocklist[source]) {
            return (CLASSIFICATION_REJECTED, REASON_BLOCKLIST, 0);
        }

        // Fast-path verifications
        if (isX402) {
            return (CLASSIFICATION_VERIFIED, REASON_NONE, 0);
        }
        if (_platformWhitelist[source]) {
            return (CLASSIFICATION_VERIFIED, REASON_NONE, 0);
        }
        if (_isRegisteredSource(merchant, source)) {
            return (CLASSIFICATION_VERIFIED, REASON_NONE, 0);
        }

        // Layer 2 + 3 — Pattern + economic risk scoring
        patternScore = 0;
        bool economicFlag = false;

        if (_isRoundTripSuspicious(source, amount, merchant)) {
            patternScore += 45;
        }

        if (v.expectedDailyRevenue > 0) {
            if (amount >= v.expectedDailyRevenue * AMOUNT_ANOMALY_MULTIPLIER) {
                patternScore += 40;
            }
            if (amount >= v.expectedDailyRevenue * MODERATE_OVERSHOOT_MULTIPLIER) {
                economicFlag = true;
                patternScore += 25;
            }
            if (amount >= v.expectedDailyRevenue * EXTREME_OVERSHOOT_MULTIPLIER) {
                return (
                    CLASSIFICATION_REJECTED,
                    REASON_ECONOMIC,
                    patternScore > PATTERN_REJECT_THRESHOLD ? patternScore : PATTERN_REJECT_THRESHOLD
                );
            }
        }

        if (v.totalCredit > 0) {
            if (amount * BPS_DENOMINATOR > v.totalCredit * LARGE_PAYMENT_THRESHOLD_BPS) {
                economicFlag = true;
                patternScore += 30;
            }
        }

        if (patternScore >= PATTERN_REJECT_THRESHOLD) {
            return (
                CLASSIFICATION_REJECTED,
                economicFlag ? REASON_ECONOMIC : REASON_PATTERN,
                patternScore
            );
        }
        if (patternScore >= PATTERN_QUARANTINE_THRESHOLD) {
            return (
                CLASSIFICATION_QUARANTINED,
                economicFlag ? REASON_ECONOMIC : REASON_PATTERN,
                patternScore
            );
        }

        return (CLASSIFICATION_PENDING_KEEPER, REASON_NONE, patternScore);
    }

    function _isRegisteredSource(address merchant, address source) internal view returns (bool) {
        address[] storage sources = _registeredSources[merchant];
        for (uint256 i = 0; i < sources.length; i++) {
            if (sources[i] == source) return true;
        }
        return false;
    }

    function _isAssociatedWallet(address merchant, address wallet) internal view returns (bool) {
        address[] storage wallets = _associatedWallets[merchant];
        for (uint256 i = 0; i < wallets.length; i++) {
            if (wallets[i] == wallet) return true;
        }
        return false;
    }

    function _isRoundTripSuspicious(
        address source,
        uint256 amount,
        address merchant
    ) internal view returns (bool) {
        uint8 count = _outflowCount[merchant];
        for (uint8 i = 0; i < count && i < OUTFLOW_HISTORY_SIZE; i++) {
            OutflowRecord storage outflow = _outflowHistory[merchant][i];
            if (outflow.destination != source) continue;
            if (outflow.timestamp > block.timestamp) continue;
            if (block.timestamp - outflow.timestamp > ROUND_TRIP_WINDOW_SECONDS) continue;

            // Check amount similarity (95% threshold)
            uint256 smaller = amount < outflow.amount ? amount : outflow.amount;
            uint256 larger = amount > outflow.amount ? amount : outflow.amount;
            if (smaller * BPS_DENOMINATOR >= larger * ROUND_TRIP_SIMILARITY_BPS) {
                return true;
            }
        }
        return false;
    }
}
