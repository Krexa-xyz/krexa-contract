use anchor_lang::prelude::*;

#[error_code]
pub enum KrexaError {
    // ── Auth ─────────────────────────────────────────────────────────────────
    #[msg("Unauthorized")]
    Unauthorized,

    // ── Identity ─────────────────────────────────────────────────────────────
    #[msg("Agent not registered")]
    AgentNotRegistered,

    #[msg("Agent not active")]
    AgentNotActive,

    #[msg("Credit score expired (>90 days) — re-verify KYA")]
    ScoreExpired,

    #[msg("KYA verification required for this credit level")]
    KyaRequired,

    #[msg("Not eligible for requested level")]
    NotEligibleForLevel,

    // ── Wallet / credit line ─────────────────────────────────────────────────
    #[msg("Agent wallet is frozen")]
    WalletFrozen,

    #[msg("Wallet is being liquidated")]
    WalletLiquidating,

    #[msg("Credit line already active")]
    CreditLineAlreadyActive,

    #[msg("No active credit line")]
    NoCreditLine,

    #[msg("Credit level insufficient for requested amount")]
    CreditLevelInsufficient,

    #[msg("Exceeds max credit line for this level")]
    ExceedsMaxCreditLine,

    #[msg("Insufficient collateral for requested credit level")]
    InsufficientCollateral,

    // ── Health / risk ────────────────────────────────────────────────────────
    #[msg("Health factor too low for this operation")]
    HealthFactorTooLow,

    #[msg("Health factor above liquidation threshold — not liquidatable")]
    NotLiquidatable,

    #[msg("Health factor above deleverage threshold — not deleverageable")]
    NotDeleverageable,

    // ── Trade / payment limits ───────────────────────────────────────────────
    #[msg("Venue not whitelisted")]
    VenueNotWhitelisted,

    #[msg("Exceeds per-trade limit (20% of wallet)")]
    ExceedsPerTradeLimit,

    #[msg("Exceeds per-venue limit (50% of wallet)")]
    ExceedsPerVenueLimit,

    #[msg("Exceeds daily spending limit")]
    ExceedsDailyLimit,

    // ── Withdrawal ───────────────────────────────────────────────────────────
    #[msg("Withdrawal would put vault below 120% of debt")]
    WithdrawalExceedsAvailable,

    #[msg("Must repay debt before full withdrawal")]
    MustRepayFirst,

    // ── Pool ─────────────────────────────────────────────────────────────────
    #[msg("Vault is paused")]
    VaultPaused,

    #[msg("Utilization cap exceeded")]
    UtilizationCapExceeded,

    #[msg("Insufficient vault liquidity")]
    InsufficientLiquidity,

    // ── Misc ─────────────────────────────────────────────────────────────────
    #[msg("Invalid amount — must be greater than zero")]
    InvalidAmount,

    #[msg("Already initialized")]
    AlreadyInitialized,

    #[msg("Nonce too low — possible replay attack")]
    NonceTooLow,

    #[msg("Lockup period has not elapsed")]
    LockupNotElapsed,

    #[msg("Arithmetic overflow")]
    Overflow,
}
