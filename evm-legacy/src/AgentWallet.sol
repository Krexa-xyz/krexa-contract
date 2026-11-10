// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAgentWallet} from "./interfaces/IAgentWallet.sol";
import {IAgentRegistry} from "./interfaces/IAgentRegistry.sol";
import {Errors} from "./libraries/Errors.sol";

/// @title AgentWallet — Human-controlled, AI-operated smart wallet with 8-layer safety
/// @notice Matches krexa-agent-wallet Solana program: NAV health checks, per-trade limits,
///         venue exposure tracking, collateral, credit lines, and permissionless liquidation.
contract AgentWallet is IAgentWallet, IERC1271, IERC1155Receiver, IERC721Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Constants (match krexa-common/constants.rs) ─────────────────

    uint16 public constant BPS = 10_000;
    uint16 public constant MAX_PER_TRADE_BPS = 2_000;       // 20% of balance per trade
    uint16 public constant MAX_PER_VENUE_BPS = 5_000;       // 50% of balance per venue
    uint16 public constant WITHDRAWAL_BUFFER_BPS = 12_000;  // 120% of debt must remain
    uint16 public constant LIQUIDATION_REWARD_BPS = 50;     // 0.5% keeper reward

    // NAV liquidation triggers per credit level (L1=90%, L2=85%, L3=80%, L4=80%)
    uint16 public constant L1_NAV_TRIGGER = 9_000;
    uint16 public constant L2_NAV_TRIGGER = 8_500;
    uint16 public constant L3_NAV_TRIGGER = 8_000;
    uint16 public constant L4_NAV_TRIGGER = 8_000;
    uint16 public constant NAV_WARNING_BUFFER = 500; // warning = trigger + 5%

    // Credit limits per level (6 decimals USDC)
    uint256 public constant L1_MAX_CREDIT = 500e6;       // $500
    uint256 public constant L2_MAX_CREDIT = 20_000e6;    // $20,000
    uint256 public constant L3_MAX_CREDIT = 50_000e6;    // $50,000
    uint256 public constant L4_MAX_CREDIT = 500_000e6;   // $500,000

    // Leverage multipliers (numerator/denominator)
    // L2: 1x collateral, L3: 2x, L4: 5x
    uint256 public constant L2_LEVERAGE = 1;
    uint256 public constant L3_LEVERAGE = 2;
    uint256 public constant L4_LEVERAGE = 5;

    // ─── Immutables ──────────────────────────────────────────────────

    IERC20 public immutable usdc;
    IAgentRegistry public immutable registry;

    // ─── Identity ────────────────────────────────────────────────────

    address public owner;
    address public operator;
    address public pendingOwner;
    uint8 public ownerType;       // 0 = EOA, 1 = Gnosis Safe
    uint8 public pendingOwnerType;

    // ─── Spending Limits ─────────────────────────────────────────────

    uint256 public dailyLimit;
    uint256 public perTxLimit;
    uint256 public spentToday;
    uint256 public dayStartTimestamp;

    // ─── Whitelist ───────────────────────────────────────────────────

    mapping(address => bool) public whitelisted;
    bool public whitelistEnabled;

    // ─── Credit State ────────────────────────────────────────────────

    address public creditVault;             // linked credit vault contract
    uint256 public collateralAmount;        // USDC deposited as collateral
    uint256 public creditLimit;             // max credit approved (C₀)
    uint256 public creditDrawn;             // principal outstanding
    uint256 public totalDebt;               // creditDrawn + accrued interest
    uint8 public creditLevel;               // copy from registry at credit time

    // ─── Health Monitoring ───────────────────────────────────────────

    uint16 public healthFactorBps;          // NAV * 10_000 (10000 = 1.0x)
    uint256 public lastHealthCheck;
    bool public frozen;
    bool public isLiquidating;

    // ─── Guardrail (Polygon: Polymarket exposure monitor) ─────────────

    address public guardrailContract;

    // ─── Venue Exposure (safety check 5) ─────────────────────────────

    mapping(address => uint256) public venueExposure;

    // ─── Lifetime Stats ──────────────────────────────────────────────

    uint256 public totalTrades;
    uint256 public totalVolume;
    uint256 public totalRepaid;
    uint256 public createdAt;

    // ─── Modifiers ───────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert Errors.Unauthorized();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert Errors.Unauthorized();
        _;
    }

    modifier onlyOwnerOrOperator() {
        if (msg.sender != owner && msg.sender != operator) revert Errors.Unauthorized();
        _;
    }

    modifier onlyOwnerOrGuardrail() {
        if (msg.sender != owner && msg.sender != guardrailContract) revert Errors.Unauthorized();
        _;
    }

    modifier notFrozen() {
        if (frozen) revert Errors.VaultPaused();
        _;
    }

    modifier notLiquidating() {
        if (isLiquidating) revert Errors.VaultPaused();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────

    constructor(
        address _usdc,
        address _registry,
        address _owner,
        address _operator,
        uint256 _dailyLimit,
        uint256 _perTxLimit
    ) {
        if (_usdc == address(0) || _owner == address(0) || _registry == address(0)) {
            revert Errors.ZeroAddress();
        }
        usdc = IERC20(_usdc);
        registry = IAgentRegistry(_registry);
        owner = _owner;
        operator = _operator;
        dailyLimit = _dailyLimit;
        perTxLimit = _perTxLimit;
        dayStartTimestamp = block.timestamp;
        healthFactorBps = type(uint16).max; // no credit = infinite NAV
        createdAt = block.timestamp;
    }

    // ═════════════════════════════════════════════════════════════════
    // OPERATOR: Transfer with 8-layer safety
    // ═════════════════════════════════════════════════════════════════

    /// @notice Transfer USDC — enforces all 8 safety layers from Solana execute_trade
    function transfer(address to, uint256 amount)
        external
        onlyOperator
        notFrozen
        notLiquidating
        nonReentrant
    {
        if (amount == 0) revert Errors.InvalidAmount();
        if (to == address(0)) revert Errors.ZeroAddress();

        uint256 balance = usdc.balanceOf(address(this));

        // Safety 1: Whitelist check (venue authorization)
        if (whitelistEnabled && !whitelisted[to]) revert Errors.Unauthorized();

        // Safety 2: Per-tx limit (owner-set absolute cap)
        if (perTxLimit > 0 && amount > perTxLimit) revert Errors.PaymentTooLarge();

        // Safety 3: Per-trade limit (20% of wallet balance)
        if (balance > 0) {
            uint256 maxPerTrade = (balance * MAX_PER_TRADE_BPS) / BPS;
            if (amount > maxPerTrade) revert Errors.PaymentTooLarge();
        }

        // Safety 4: Daily spend limit
        _resetDailyIfNeeded();
        if (dailyLimit > 0 && spentToday + amount > dailyLimit) revert Errors.PaymentTooLarge();

        // Safety 5: Per-venue exposure limit (50% of balance)
        if (balance > 0) {
            uint256 newVenueTotal = venueExposure[to] + amount;
            uint256 maxVenue = (balance * MAX_PER_VENUE_BPS) / BPS;
            if (newVenueTotal > maxVenue) revert Errors.ExceedsMaxAllocation();
        }

        // Safety 6: NAV health check (if credit is active)
        if (creditLimit > 0) {
            uint16 postNav = _computeNavAfterSpend(balance, amount);
            uint16 warning = _navWarningForLevel(creditLevel);
            if (postNav < warning) revert Errors.InsufficientBalance();
        }

        // Execute transfer
        spentToday += amount;
        venueExposure[to] += amount;
        totalTrades += 1;
        totalVolume += amount;

        usdc.safeTransfer(to, amount);

        // Update health factor post-trade
        uint16 newHealth = _computeCurrentNav();
        healthFactorBps = newHealth;
        lastHealthCheck = block.timestamp;

        emit PaymentExecuted(to, amount, newHealth, spentToday);
        emit VenueExposureUpdated(address(this), to, venueExposure[to]);
    }

    // ═════════════════════════════════════════════════════════════════
    // CREDIT OPERATIONS
    // ═════════════════════════════════════════════════════════════════

    /// @notice Deposit USDC as collateral (improves NAV, enables credit)
    function depositCollateral(uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        if (amount == 0) revert Errors.ZeroAmount();
        collateralAmount += amount;
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit CollateralDeposited(address(this), amount, collateralAmount);
    }

    /// @notice Withdraw collateral — blocked if credit is active
    function withdrawCollateral(uint256 amount)
        external
        onlyOwner
        notLiquidating
        nonReentrant
    {
        if (amount == 0) revert Errors.ZeroAmount();
        if (amount > collateralAmount) revert Errors.InsufficientBalance();

        // Cannot withdraw collateral while credit line is active
        if (creditDrawn > 0 || totalDebt > 0) {
            // Check withdrawal buffer: must keep 120% of debt covered
            uint256 walletUsdc = usdc.balanceOf(address(this));
            uint256 postCollateral = collateralAmount - amount;
            uint256 totalValue = walletUsdc + postCollateral - amount; // amount leaves wallet
            uint256 minRequired = (totalDebt * WITHDRAWAL_BUFFER_BPS) / BPS;
            if (totalValue < minRequired) revert Errors.InsufficientBalance();
        }

        collateralAmount -= amount;
        usdc.safeTransfer(owner, amount);
        emit CollateralWithdrawn(address(this), amount, collateralAmount);
    }

    /// @notice Draw credit from linked vault. Oracle must have set KYA + score.
    /// @param amount USDC to borrow
    /// @param rateBps Interest rate in BPS (stored for reference)
    /// @param _creditLevel Requested credit level (validated against registry)
    function requestCredit(uint256 amount, uint16 rateBps, uint8 _creditLevel)
        external
        onlyOwner
        notFrozen
        notLiquidating
        nonReentrant
    {
        if (amount == 0) revert Errors.ZeroAmount();
        if (_creditLevel == 0) revert Errors.CreditTierTooLow();
        if (creditDrawn > 0) revert Errors.InvalidAmount(); // only one active line

        // Validate against on-chain registry
        IAgentRegistry.CreditLevel requiredLevel = IAgentRegistry.CreditLevel(_creditLevel);
        if (!registry.isAgentEligible(owner, requiredLevel)) revert Errors.CreditTierTooLow();

        // Compute credit limit from level + collateral
        uint256 limit = _creditLimitForLevel(_creditLevel, collateralAmount);
        if (amount > limit) revert Errors.PaymentTooLarge();

        // Store credit state
        creditLimit = limit;
        creditDrawn = amount;
        totalDebt = amount;
        creditLevel = _creditLevel;

        // Update health
        uint16 hf = _computeCurrentNav();
        healthFactorBps = hf;
        lastHealthCheck = block.timestamp;

        emit CreditReceived(address(this), amount, rateBps, limit, hf);
    }

    /// @notice Repay credit — reduces debt, clears credit line when fully repaid
    function repay(uint256 amount)
        external
        notLiquidating
        nonReentrant
    {
        if (amount == 0) revert Errors.ZeroAmount();
        if (creditDrawn == 0 && totalDebt == 0) revert Errors.InvalidAmount();
        if (usdc.balanceOf(address(this)) < amount) revert Errors.InsufficientBalance();

        // Allow both owner and operator to repay
        if (msg.sender != owner && msg.sender != operator) revert Errors.Unauthorized();

        // Apply repayment
        if (amount >= totalDebt) {
            // Fully repaid
            uint256 repayAmount = totalDebt;
            creditDrawn = 0;
            totalDebt = 0;
            creditLimit = 0;
            creditLevel = 0;
            totalRepaid += repayAmount;

            // Transfer only what's owed
            usdc.safeTransfer(creditVault, repayAmount);

            healthFactorBps = type(uint16).max;
            lastHealthCheck = block.timestamp;

            emit Repaid(address(this), repayAmount, 0, true);
        } else {
            // Partial repayment — apply to principal first
            if (amount <= creditDrawn) {
                creditDrawn -= amount;
            } else {
                creditDrawn = 0;
            }
            totalDebt -= amount;
            totalRepaid += amount;

            usdc.safeTransfer(creditVault, amount);

            uint16 hf = _computeCurrentNav();
            healthFactorBps = hf;
            lastHealthCheck = block.timestamp;

            emit Repaid(address(this), amount, totalDebt, false);
        }

        // Update registry stats
        try registry.updateAgentStats(owner, 0, 0, amount, 0) {} catch {}
    }

    // ═════════════════════════════════════════════════════════════════
    // HEALTH & LIQUIDATION
    // ═════════════════════════════════════════════════════════════════

    /// @notice Permissionless health check — auto-freezes if NAV drops below warning
    function checkHealth() external {
        uint16 nav = _computeCurrentNav();
        healthFactorBps = nav;
        lastHealthCheck = block.timestamp;

        uint256 walletUsdc = usdc.balanceOf(address(this));

        if (creditLimit > 0) {
            uint16 warning = _navWarningForLevel(creditLevel);
            // Auto-freeze when NAV below warning
            if (nav < warning && !frozen) {
                frozen = true;
                emit Frozen(address(this));
            }
            // Auto-unfreeze when NAV recovers above trigger + 10%
            uint16 healthy = navTriggerForLevel(creditLevel) + 1_000;
            if (nav >= healthy && frozen && !isLiquidating) {
                frozen = false;
                emit Unfrozen(address(this));
            }
        }

        emit HealthChecked(address(this), nav, walletUsdc, collateralAmount, totalDebt);
    }

    /// @notice Permissionless liquidation — anyone can trigger if NAV < trigger
    /// @dev Canonical 6-step: freeze → calculate → distribute → update registry → return surplus
    function liquidate() external nonReentrant {
        if (creditLimit == 0) revert Errors.InvalidAmount(); // no credit to liquidate

        uint16 nav = _computeCurrentNav();
        uint16 trigger = navTriggerForLevel(creditLevel);
        if (nav >= trigger) revert Errors.InvalidAmount(); // health above liquidation threshold

        // Step 1: Freeze
        frozen = true;
        isLiquidating = true;

        // Step 3: Calculate amounts
        uint256 walletBalance = usdc.balanceOf(address(this));
        uint256 keeperReward = (walletBalance * LIQUIDATION_REWARD_BPS) / BPS;
        uint256 availableForRepay = walletBalance - keeperReward;
        uint256 repayAmount = availableForRepay < totalDebt ? availableForRepay : totalDebt;
        uint256 shortfall = totalDebt - repayAmount;
        uint256 returnedToOwner = walletBalance - keeperReward - repayAmount;

        // Step 4: Distribute — repayment to vault
        if (repayAmount > 0 && creditVault != address(0)) {
            usdc.safeTransfer(creditVault, repayAmount);
        }

        // Step 4: Distribute — keeper reward (0.5%)
        if (keeperReward > 0) {
            usdc.safeTransfer(msg.sender, keeperReward);
        }

        // Step 6: Return surplus to owner
        if (returnedToOwner > 0) {
            usdc.safeTransfer(owner, returnedToOwner);
        }

        // Step 5: Update registry — record liquidation (-40 score penalty)
        try registry.recordLiquidation(owner) {} catch {}

        // Step 5: Update wallet state
        isLiquidating = false;
        // frozen stays true — admin must manually unfreeze after review
        creditDrawn = 0;
        creditLimit = 0;
        totalDebt = shortfall; // residual bad debt
        healthFactorBps = type(uint16).max;
        lastHealthCheck = block.timestamp;

        emit Liquidated(address(this), repayAmount, keeperReward, returnedToOwner, shortfall);
    }

    // ═════════════════════════════════════════════════════════════════
    // OWNER FUNCTIONS
    // ═════════════════════════════════════════════════════════════════

    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert Errors.ZeroAddress();
        address old = operator;
        operator = newOperator;
        emit OperatorSet(old, newOperator);
    }

    function setLimits(uint256 newDailyLimit, uint256 newPerTxLimit) external onlyOwner {
        dailyLimit = newDailyLimit;
        perTxLimit = newPerTxLimit;
        emit LimitsUpdated(newDailyLimit, newPerTxLimit);
    }

    function setWhitelist(address recipient, bool allowed) external onlyOwner {
        whitelisted[recipient] = allowed;
        emit WhitelistUpdated(recipient, allowed);
    }

    function toggleWhitelist(bool enabled) external onlyOwner {
        whitelistEnabled = enabled;
        emit WhitelistToggled(enabled);
    }

    function linkCreditVault(address vault) external onlyOwner {
        creditVault = vault;
        emit CreditVaultLinked(vault);
    }

    function setGuardrail(address _guardrail) external onlyOwner {
        guardrailContract = _guardrail;
    }

    function freeze() external onlyOwnerOrGuardrail {
        frozen = true;
        emit Frozen(msg.sender);
    }

    function unfreeze() external onlyOwner {
        if (isLiquidating) revert Errors.VaultPaused();
        frozen = false;
        emit Unfrozen(msg.sender);
    }

    function proposeOwnershipTransfer(address newOwner, uint8 newOwnerType) external onlyOwner {
        if (newOwner == address(0)) revert Errors.ZeroAddress();
        if (newOwnerType > 1) revert Errors.InvalidAmount();
        pendingOwner = newOwner;
        pendingOwnerType = newOwnerType;
        emit OwnershipTransferProposed(owner, newOwner, newOwnerType);
    }

    function acceptOwnershipTransfer() external {
        if (msg.sender != pendingOwner) revert Errors.Unauthorized();
        address oldOwner = owner;
        owner = pendingOwner;
        ownerType = pendingOwnerType;
        pendingOwner = address(0);
        pendingOwnerType = 0;
        emit OwnershipTransferAccepted(oldOwner, owner, ownerType);
    }

    function cancelOwnershipTransfer() external onlyOwner {
        address cancelled = pendingOwner;
        pendingOwner = address(0);
        pendingOwnerType = 0;
        emit OwnershipTransferCancelled(cancelled);
    }

    /// @notice Emergency withdraw — only when no active credit line
    function emergencyWithdraw(address to) external onlyOwner {
        if (to == address(0)) revert Errors.ZeroAddress();
        if (creditDrawn > 0 || totalDebt > 0) revert Errors.InvalidAmount();
        uint256 balance = usdc.balanceOf(address(this));
        if (balance == 0) revert Errors.InsufficientBalance();
        usdc.safeTransfer(to, balance);
        emit EmergencyWithdrawal(to, balance);
    }

    // ═════════════════════════════════════════════════════════════════
    // GENERIC EXECUTE (Polymarket, DEX, any whitelisted target)
    // ═════════════════════════════════════════════════════════════════

    /// @notice Execute an arbitrary call to a whitelisted target.
    ///         Enables Polymarket CTF interactions (approve, placeTrade, etc.)
    ///         and any future protocol integrations without contract upgrades.
    /// @param target The contract to call (must be whitelisted)
    /// @param value  ETH value to send (usually 0 for USDC-denominated protocols)
    /// @param data   Calldata to forward
    /// @return result The return data from the call
    function execute(address target, uint256 value, bytes calldata data)
        external
        onlyOwnerOrOperator
        notFrozen
        notLiquidating
        nonReentrant
        returns (bytes memory result)
    {
        if (target == address(0)) revert Errors.ZeroAddress();

        // Safety 1: Whitelist check — target must be an approved venue
        if (!whitelistEnabled) revert Errors.TargetNotWhitelisted();
        if (!whitelisted[target]) revert Errors.TargetNotWhitelisted();

        // Safety 2: Per-tx limit (applied to ETH value if nonzero)
        if (value > 0 && perTxLimit > 0 && value > perTxLimit) revert Errors.PaymentTooLarge();

        // Safety 3: Daily spend tracking (ETH value)
        if (value > 0) {
            _resetDailyIfNeeded();
            if (dailyLimit > 0 && spentToday + value > dailyLimit) revert Errors.PaymentTooLarge();
            spentToday += value;
        }

        // Safety 4: Per-venue exposure tracking
        if (value > 0) {
            uint256 balance = address(this).balance;
            if (balance > 0) {
                uint256 newVenueTotal = venueExposure[target] + value;
                uint256 maxVenue = (balance * MAX_PER_VENUE_BPS) / BPS;
                if (newVenueTotal > maxVenue) revert Errors.ExceedsMaxAllocation();
            }
            venueExposure[target] += value;
        }

        // Safety 5: NAV health check (if credit is active)
        if (creditLimit > 0 && value > 0) {
            uint256 walletUsdc = usdc.balanceOf(address(this));
            uint16 postNav = _computeNavAfterSpend(walletUsdc, 0); // USDC not spent, ETH is
            uint16 warning = _navWarningForLevel(creditLevel);
            if (postNav < warning) revert Errors.InsufficientBalance();
        }

        // Execute the call
        bool success;
        (success, result) = target.call{value: value}(data);
        if (!success) revert Errors.ExecuteFailed();

        totalTrades += 1;

        // Update health factor after execution
        uint16 newHealth = _computeCurrentNav();
        healthFactorBps = newHealth;
        lastHealthCheck = block.timestamp;

        emit Executed(target, value, data, result);
    }

    /// @notice Execute multiple calls atomically (e.g. approve + trade on Polymarket).
    ///         All targets must be whitelisted. Reverts entirely if any call fails.
    /// @param targets  Array of contract addresses to call
    /// @param values   Array of ETH values per call
    /// @param calldatas Array of calldata per call
    function batchExecute(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas
    )
        external
        onlyOwnerOrOperator
        notFrozen
        notLiquidating
        nonReentrant
    {
        uint256 len = targets.length;
        if (len != values.length || len != calldatas.length) revert Errors.InvalidAmount();
        if (len == 0) revert Errors.InvalidAmount();

        for (uint256 i = 0; i < len; i++) {
            address target = targets[i];
            if (target == address(0)) revert Errors.ZeroAddress();
            if (!whitelistEnabled) revert Errors.TargetNotWhitelisted();
            if (!whitelisted[target]) revert Errors.TargetNotWhitelisted();

            (bool success, ) = target.call{value: values[i]}(calldatas[i]);
            if (!success) revert Errors.ExecuteFailed();
        }

        totalTrades += len;

        uint16 newHealth = _computeCurrentNav();
        healthFactorBps = newHealth;
        lastHealthCheck = block.timestamp;

        emit BatchExecuted(targets, values);
    }

    // ═════════════════════════════════════════════════════════════════
    // ERC-1271: Smart Contract Signature Validation
    // ═════════════════════════════════════════════════════════════════

    /// @notice Validates signatures on behalf of the wallet (e.g. Polymarket order signing).
    ///         Accepts signatures from both owner AND operator — the operator (AI agent / HeyAnna)
    ///         needs to sign CLOB limit orders on Polymarket without requiring human co-sign.
    ///         For EOA signers: recovers via ECDSA. For contract signers: forwards ERC1271.
    function isValidSignature(bytes32 hash, bytes memory signature)
        external
        view
        override
        returns (bytes4)
    {
        // Owner signature is always valid
        if (SignatureChecker.isValidSignatureNow(owner, hash, signature)) {
            return IERC1271.isValidSignature.selector; // 0x1626ba7e
        }
        // Operator signature is valid (enables AI agent to sign Polymarket orders)
        if (operator != address(0) && SignatureChecker.isValidSignatureNow(operator, hash, signature)) {
            return IERC1271.isValidSignature.selector;
        }
        return 0xffffffff;
    }

    // ═════════════════════════════════════════════════════════════════
    // ERC-1155 Receiver (CTF position tokens)
    // ═════════════════════════════════════════════════════════════════

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    // ═════════════════════════════════════════════════════════════════
    // ERC-721 Receiver (Uniswap V3 LP positions, NFTs)
    // ═════════════════════════════════════════════════════════════════

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }

    // ═════════════════════════════════════════════════════════════════
    // ERC-165: Interface Detection
    // ═════════════════════════════════════════════════════════════════

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId
            || interfaceId == type(IERC721Receiver).interfaceId
            || interfaceId == type(IERC1271).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    // ═════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═════════════════════════════════════════════════════════════════

    function getRemainingDaily() external view returns (uint256) {
        if (dailyLimit == 0) return type(uint256).max;
        if (block.timestamp >= dayStartTimestamp + 1 days) return dailyLimit;
        if (spentToday >= dailyLimit) return 0;
        return dailyLimit - spentToday;
    }

    /// @notice Current NAV in BPS (10000 = 1.0x). Returns max uint16 if no credit.
    function computeNav() external view returns (uint16) {
        return _computeCurrentNav();
    }

    /// @notice NAV liquidation trigger for a given credit level
    function navTriggerForLevel(uint8 level) public pure returns (uint16) {
        if (level == 1) return L1_NAV_TRIGGER;
        if (level == 2) return L2_NAV_TRIGGER;
        if (level == 3) return L3_NAV_TRIGGER;
        if (level == 4) return L4_NAV_TRIGGER;
        return BPS; // L0 = 100% trigger (immediate)
    }

    /// @notice Accept ETH (needed for protocol interactions that refund ETH)
    receive() external payable {}

    // ═════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═════════════════════════════════════════════════════════════════

    function _resetDailyIfNeeded() internal {
        if (block.timestamp >= dayStartTimestamp + 1 days) {
            spentToday = 0;
            dayStartTimestamp = block.timestamp;
        }
    }

    /// @notice NAV = V(t) / C₀ where V(t) = walletUSDC + collateral, C₀ = creditLimit
    function _computeCurrentNav() internal view returns (uint16) {
        if (creditLimit == 0) return type(uint16).max;
        uint256 totalValue = usdc.balanceOf(address(this)) + collateralAmount;
        uint256 nav = (totalValue * BPS) / creditLimit;
        if (nav > type(uint16).max) return type(uint16).max;
        return uint16(nav);
    }

    /// @notice Projected NAV after spending `amount` from wallet
    function _computeNavAfterSpend(uint256 currentBalance, uint256 spendAmount) internal view returns (uint16) {
        if (creditLimit == 0) return type(uint16).max;
        uint256 projectedBalance = currentBalance - spendAmount;
        uint256 totalValue = projectedBalance + collateralAmount;
        uint256 nav = (totalValue * BPS) / creditLimit;
        if (nav > type(uint16).max) return type(uint16).max;
        return uint16(nav);
    }

    /// @notice NAV warning threshold = trigger + 5% buffer
    function _navWarningForLevel(uint8 level) internal pure returns (uint16) {
        return navTriggerForLevel(level) + NAV_WARNING_BUFFER;
    }

    /// @notice Credit limit from level + collateral (matches Solana credit_limit_for_level)
    ///   L1: $500 fixed
    ///   L2: min(collateral × 1, $20,000)
    ///   L3: min(collateral × 2, $50,000)
    ///   L4: $500,000 fixed
    function _creditLimitForLevel(uint8 level, uint256 collateral) internal pure returns (uint256) {
        if (level == 1) return L1_MAX_CREDIT;
        if (level == 2) {
            uint256 leveraged = collateral * L2_LEVERAGE;
            return leveraged < L2_MAX_CREDIT ? leveraged : L2_MAX_CREDIT;
        }
        if (level == 3) {
            uint256 leveraged = collateral * L3_LEVERAGE;
            return leveraged < L3_MAX_CREDIT ? leveraged : L3_MAX_CREDIT;
        }
        if (level == 4) return L4_MAX_CREDIT;
        return 0;
    }
}
