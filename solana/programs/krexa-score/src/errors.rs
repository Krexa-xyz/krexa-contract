use anchor_lang::prelude::*;

#[error_code]
pub enum KrexaScoreError {
    #[msg("Not admin")]
    NotAdmin,
    #[msg("Not oracle")]
    NotOracle,
    #[msg("Not admin or oracle")]
    NotAdminOrOracle,
    #[msg("Program is paused")]
    Paused,
    #[msg("Score must be between 200 and 850")]
    ScoreOutOfRange,
    #[msg("Credit level must be 1-4")]
    InvalidLevel,
    #[msg("Component score must be 0-10000 BPS")]
    ComponentOutOfRange,
    #[msg("Score change exceeds maximum allowed delta")]
    ScoreChangeTooLarge,
    #[msg("Agent is blacklisted — score is permanently frozen")]
    AgentBlacklisted,
    #[msg("Score cannot be updated more than once per 60 seconds")]
    UpdateTooFrequent,
    #[msg("Liquidation penalty of -40 points was not applied")]
    LiquidationPenaltyNotApplied,
    #[msg("KYA tier can only increase, never decrease")]
    KYACannotDegrade,
    #[msg("Invalid KYA tier (must be 0-3)")]
    InvalidKYATier,
    #[msg("Arithmetic overflow")]
    Overflow,
    #[msg("Invalid agent type (must be 0-2)")]
    InvalidAgentType,
    #[msg("Not authorized caller")]
    NotAuthorizedCaller,
}
