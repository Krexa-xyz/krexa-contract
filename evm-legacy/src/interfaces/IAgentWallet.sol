// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAgentWallet — Solana-parity agent wallet with 8-layer safety
/// @notice Matches krexa-agent-wallet: NAV health checks, per-trade/venue limits,
///         collateral tracking, credit lines, and permissionless liquidation.
interface IAgentWallet {
    // ─── Events ──────────────────────────────────────────────────────

    event OperatorSet(address indexed oldOperator, address indexed newOperator);
    event LimitsUpdated(uint256 dailyLimit, uint256 perTxLimit);
    event WhitelistUpdated(address indexed recipient, bool allowed);
    event WhitelistToggled(bool enabled);
    event CreditVaultLinked(address indexed vault);
    event Frozen(address indexed by);
    event Unfrozen(address indexed by);
    event PaymentExecuted(address indexed to, uint256 amount, uint16 healthAfterBps, uint256 dailySpent);
    event EmergencyWithdrawal(address indexed to, uint256 amount);
    event OwnershipTransferProposed(address indexed currentOwner, address indexed proposedOwner, uint8 ownerType);
    event OwnershipTransferAccepted(address indexed oldOwner, address indexed newOwner, uint8 ownerType);
    event OwnershipTransferCancelled(address indexed cancelledOwner);

    // Credit events
    event CreditReceived(address indexed agent, uint256 amount, uint16 rateBps, uint256 creditLimit, uint16 healthBps);
    event Repaid(address indexed agent, uint256 amount, uint256 remainingDebt, bool creditCleared);
    event CollateralDeposited(address indexed agent, uint256 amount, uint256 totalCollateral);
    event CollateralWithdrawn(address indexed agent, uint256 amount, uint256 totalCollateral);

    // Health & liquidation events
    event HealthChecked(address indexed agent, uint16 healthBps, uint256 walletUsdc, uint256 collateralValue, uint256 totalDebt);
    event Liquidated(address indexed agent, uint256 debtRepaid, uint256 keeperReward, uint256 returnedToOwner, uint256 shortfall);
    event VenueExposureUpdated(address indexed agent, address indexed venue, uint256 totalSent);
    event Executed(address indexed target, uint256 value, bytes data, bytes result);
    event BatchExecuted(address[] targets, uint256[] values);

    // ─── Operator Functions ──────────────────────────────────────────

    function transfer(address to, uint256 amount) external;
    function execute(address target, uint256 value, bytes calldata data) external returns (bytes memory);
    function batchExecute(address[] calldata targets, uint256[] calldata values, bytes[] calldata calldatas) external;

    // ─── Owner Functions ─────────────────────────────────────────────

    function setOperator(address newOperator) external;
    function setLimits(uint256 newDailyLimit, uint256 newPerTxLimit) external;
    function setWhitelist(address recipient, bool allowed) external;
    function toggleWhitelist(bool enabled) external;
    function linkCreditVault(address vault) external;
    function setGuardrail(address _guardrail) external;
    function freeze() external;
    function unfreeze() external;
    function emergencyWithdraw(address to) external;
    function proposeOwnershipTransfer(address newOwner, uint8 newOwnerType) external;
    function acceptOwnershipTransfer() external;
    function cancelOwnershipTransfer() external;

    // ─── Credit Operations ───────────────────────────────────────────

    function depositCollateral(uint256 amount) external;
    function withdrawCollateral(uint256 amount) external;
    function requestCredit(uint256 amount, uint16 rateBps, uint8 creditLevel) external;
    function repay(uint256 amount) external;

    // ─── Health & Liquidation ────────────────────────────────────────

    function checkHealth() external;
    function liquidate() external;

    // ─── View Functions ──────────────────────────────────────────────

    function owner() external view returns (address);
    function operator() external view returns (address);
    function dailyLimit() external view returns (uint256);
    function perTxLimit() external view returns (uint256);
    function spentToday() external view returns (uint256);
    function frozen() external view returns (bool);
    function whitelistEnabled() external view returns (bool);
    function creditVault() external view returns (address);
    function pendingOwner() external view returns (address);
    function ownerType() external view returns (uint8);
    function guardrailContract() external view returns (address);
    function getRemainingDaily() external view returns (uint256);

    // Credit state
    function collateralAmount() external view returns (uint256);
    function creditLimit() external view returns (uint256);
    function creditDrawn() external view returns (uint256);
    function totalDebt() external view returns (uint256);
    function healthFactorBps() external view returns (uint16);
    function isLiquidating() external view returns (bool);
    function creditLevel() external view returns (uint8);

    // Venue exposure
    function venueExposure(address venue) external view returns (uint256);

    // NAV computation
    function computeNav() external view returns (uint16);
    function navTriggerForLevel(uint8 level) external pure returns (uint16);
}
