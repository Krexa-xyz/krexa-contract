// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Errors — Custom error definitions for TigerPayX Base contracts
/// @notice Maps from Solana errors.rs — covers vault lifecycle, payments, access control, replay, rate limits
library Errors {
    // ── Vault Lifecycle ──
    error VaultNotActive();
    error VaultNotFundraising();
    error VaultNotRepaying();
    error VaultPaused();
    error VaultCancelled();
    error VaultAlreadyPaused();
    error VaultAlreadyCancelled();
    error VaultAlreadyCompleted();
    error VaultAlreadyDefaulted();
    error InvalidVaultState();
    error FundraisingDeadlinePassed();
    error FundraisingNotComplete();
    error MaxInvestorsReached();
    error InvestmentBelowMinimum();
    error InvestmentAboveMaximum();
    error TargetAmountExceeded();
    error NoTranchesRemaining();

    // ── Repayment ──
    error InvalidRepaymentAmount();
    error NoReturnsAvailable();
    error AlreadyRefunded();
    error AlreadyRecovered();

    // ── Liquidity Pools ──
    error PoolPaused();
    error PoolInsufficientBalance();
    error AllocationExceedsCap();
    error AllocationAlreadyExists();
    error AllocationNotFound();
    error WithdrawExceedsAvailable();

    // ── x402 / Settlement ──
    error SettlementNotActive();
    error SettlementAlreadyExists();
    error InvalidSignature();
    error SignatureExpired();
    error NonceAlreadyUsed();
    error RateLimitExceeded();
    error PaymentExceedsMax();
    error PaymentExpired();
    error InvalidPaymentAmount();

    // ── Agent Registry ──
    error AgentAlreadyRegistered();
    error AgentNotRegistered();
    error AgentNotActive();

    // ── Credit Scoring ──
    error CreditScoreOutOfRange();
    error CreditScoreExpired();
    error CreditTierTooLow();
    error InvalidKyaTier();
    error InvalidAgentType();
    error AgentAlreadyActive();
    error WalletAlreadyLinked();
    error NoOwnershipTransferPending();
    error NotProposedOwner();
    error NotAgentOrOwner();
    error OnlyOracle();
    error OnlyAdminOrOracle();

    // ── Milestones ──
    error MilestoneNotApproved();
    error MilestoneAlreadyVoted();
    error MilestoneNotPending();
    error InvalidMilestoneId();
    error MilestoneAlreadyFinalized();

    // ── Keeper / Lifecycle ──
    error FundraisingNotExpired();
    error FundraisingThresholdNotMet();
    error DefaultConditionsNotMet();
    error FundraisingAboveThreshold();

    // ── Access Control ──
    error Unauthorized();
    error OnlyFactory();
    error OnlyRouter();
    error OnlyAdmin();

    // ── Arithmetic ──
    error ArithmeticOverflow();
    error DivisionByZero();

    // ── General ──
    error ZeroAddress();
    error ZeroAmount();
    error PlatformPaused();
    error InvalidAmount();
    error InvalidMetadata();
    error InvalidTrancheCount();
    error ExceedsTarget();
    error AllTranchesReleased();
    error NothingToClaim();
    error FeeTooHigh();
    error VaultAlreadyExists();
    error PaymentTooLarge();
    error InsufficientBalance();
    error InsufficientPoolBalance();
    error ExceedsMaxAllocation();

    // ── Revenue Validation ──
    error ValidatorNotActive();
    error MaxSourcesReached();
    error SourceAlreadyRegistered();
    error SourceNotFound();
    error MaxAssociatedWalletsReached();
    error WalletAlreadyAssociated();
    error InvalidDecision();
    error PaymentIndexOutOfBounds();
    error NotQuarantined();
    error Blocklisted();
    error RevenueRejected();
    error ValidatorAlreadyExists();

    // ── Service Plan ──
    error PlanAlreadyExists();
    error PlanNotFound();
    error MaxMilestonesReached();
    error MilestoneSumExceedsCredit();
    error MilestoneOutOfBounds();
    error MilestoneAlreadyDisbursed();
    error MilestoneNotEligible();
    error MilestoneDelayed();
    error MilestoneNotActive_();
    error DisbursementsPaused();
    error InWindDown();
    error MaxExpenseDestsReached();
    error ExpenseDestNotActive();
    error ExceedsExpenseLimit();
    error ExpenseDestNotFound();
    error InvalidCategory();
    error WindDownAlreadyStarted();
    error WindDownNotActive();
    error GracePeriodNotElapsed();
    error InvalidWindDownTransition();
    error ZeroCredit();
    error HealthNotRed();

    // ── Execute ──
    error ExecuteFailed();
    error TargetNotWhitelisted();
}
