use anchor_lang::prelude::*;

#[error_code]
pub enum WalletError {
    #[msg("Not admin")]
    NotAdmin,
    #[msg("Not keeper")]
    NotKeeper,
    #[msg("Not oracle")]
    NotOracle,
    #[msg("Vault is paused")]
    Paused,
    #[msg("Wallet is frozen")]
    WalletFrozen,
    #[msg("Wallet is in liquidation")]
    WalletLiquidating,
    #[msg("Only the agent keypair may sign this")]
    UnauthorizedAgent,
    #[msg("Only the owner may sign this")]
    UnauthorizedOwner,
    #[msg("Agent is not registered or does not meet credit level requirements")]
    AgentNotEligible,
    #[msg("Agent already has a wallet")]
    WalletAlreadyExists,
    #[msg("Credit level too low for this operation")]
    CreditLevelTooLow,
    #[msg("Amount exceeds per-trade limit (20% of balance)")]
    ExceedsPerTradeLimit,
    #[msg("Daily spend limit would be exceeded")]
    DailyLimitExceeded,
    #[msg("Trade would push health factor below warning threshold")]
    HealthTooLow,
    #[msg("Withdrawal would violate 120% collateral buffer")]
    WithdrawalGate,
    #[msg("Insufficient USDC balance in wallet")]
    InsufficientBalance,
    #[msg("Amount must be > 0")]
    ZeroAmount,
    #[msg("Venue is not whitelisted or is inactive")]
    VenueNotWhitelisted,
    #[msg("No active credit line for this agent")]
    NoCreditLine,
    #[msg("Health factor is not low enough to trigger deleverage")]
    HealthFactorHealthy,
    #[msg("Health factor is not low enough to trigger liquidation")]
    HealthAboveLiquidation,
    #[msg("Arithmetic overflow")]
    Overflow,
    #[msg("Credit already drawn — repay first")]
    CreditAlreadyDrawn,
    #[msg("Existing credit line not fully repaid")]
    CreditLineActive,
    #[msg("Legal agreement must be signed for L3-L4 credit")]
    LegalAgreementNotSigned,
    #[msg("No pending ownership transfer for this wallet")]
    NoPendingTransfer,
    #[msg("Signer is not the proposed new owner")]
    NotPendingOwner,
    #[msg("Invalid owner type — must be 0 (EOA) or 1 (Multisig)")]
    InvalidOwnerType,
    #[msg("An ownership transfer is already pending for this wallet")]
    TransferAlreadyPending,
    #[msg("Multisig ownership required for L3-L4 credit lines")]
    MultisigRequired,
    #[msg("Trade would exceed 50% per-venue exposure limit")]
    ExceedsVenueLimit,
    #[msg("Invalid platform treasury account")]
    InvalidTreasury,
    #[msg("Facilitator token account owner must match facilitator pubkey")]
    InvalidFacilitatorToken,
    #[msg("Address cannot be the zero/default pubkey")]
    InvalidAddress,
}
