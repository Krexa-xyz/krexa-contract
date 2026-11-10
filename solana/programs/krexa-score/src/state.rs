use anchor_lang::prelude::*;

/// Seeds: [b"krexit_score", agent_profile_key.as_ref()]
#[account]
pub struct KrexitScore {
    // === Identity ===
    pub agent: Pubkey,
    pub owner: Pubkey,

    // === Composite Score ===
    pub score: u16,           // 200-850
    pub credit_level: u8,     // 1-4
    pub kya_tier: u8,         // 0-3

    // === Component Scores (0-10000 BPS = 0.00-1.00) ===
    pub c1_repayment: u16,       // weight 30%
    pub c2_profitability: u16,   // weight 25%
    pub c3_behavioral: u16,      // weight 20%
    pub c4_usage: u16,           // weight 15%
    pub c5_maturity: u16,        // weight 10%

    // === Event Counters (lifetime) ===
    pub on_time_repayments: u32,
    pub late_repayments: u16,
    pub missed_repayments: u16,
    pub liquidations: u16,
    pub defaults: u16,
    pub credit_cycles_completed: u32,

    // === Financial Metrics (current) ===
    pub cumulative_borrowed: u64,
    pub cumulative_repaid: u64,
    pub current_debt: u64,
    pub pnl_ratio_bps: i32,
    pub max_drawdown_bps: u16,
    pub sharpe_ratio_bps: i16,

    // === Behavioral Metrics ===
    pub green_time_bps: u16,
    pub yellow_time_bps: u16,
    pub orange_time_bps: u16,
    pub red_time_bps: u16,

    // === Usage Metrics ===
    pub venue_entropy_bps: u16,
    pub unique_venues: u8,
    pub total_transactions: u32,
    pub avg_daily_volume: u64,

    // === Timestamps ===
    pub registered_at: i64,
    pub last_score_update: i64,
    pub last_critical_event: i64,
    pub last_repayment: i64,

    // === Score History (ring buffer) ===
    pub history: [ScoreHistoryEntry; 30],
    pub history_index: u8,

    // === Agent Type ===
    pub agent_type: u8,     // 0=Trader, 1=Service, 2=Hybrid

    // === Type B Specific ===
    pub revenue_health_bps: u16,
    pub milestone_completion_rate_bps: u16,

    // === Flags ===
    pub is_active: bool,
    pub is_blacklisted: bool,

    pub bump: u8,
}

impl KrexitScore {
    pub const SEED: &'static [u8] = b"krexit_score";

    // 8 discriminator + fields
    pub const LEN: usize = 8
        + 32 + 32                                    // agent, owner
        + 2 + 1 + 1                                  // score, credit_level, kya_tier
        + 2 * 5                                      // c1-c5
        + 4 + 2 + 2 + 2 + 2 + 4                     // event counters
        + 8 + 8 + 8 + 4 + 2 + 2                     // financial metrics
        + 2 * 4                                      // behavioral metrics
        + 2 + 1 + 4 + 8                              // usage metrics
        + 8 * 4                                      // timestamps
        + (ScoreHistoryEntry::LEN * 30) + 1          // history + index
        + 1                                          // agent_type
        + 2 + 2                                      // type B specific
        + 1 + 1                                      // flags
        + 1;                                         // bump
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Default)]
pub struct ScoreHistoryEntry {
    pub timestamp: i64,
    pub old_score: u16,
    pub new_score: u16,
    pub event_type: u8,
    pub delta_bps: i16,
}

impl ScoreHistoryEntry {
    pub const LEN: usize = 8 + 2 + 2 + 1 + 2; // 15
}

/// Score event types stored as u8
pub mod score_event_type {
    pub const DAILY_UPDATE: u8 = 0;
    pub const ON_TIME_REPAYMENT: u8 = 1;
    pub const EARLY_REPAYMENT: u8 = 2;
    pub const LATE_REPAYMENT: u8 = 3;
    pub const MISSED_REPAYMENT: u8 = 4;
    pub const LIQUIDATION: u8 = 5;
    pub const DEFAULT: u8 = 6;
    pub const CREDIT_CYCLE_COMPLETE: u8 = 7;
    pub const LEVEL_CHANGE: u8 = 8;
    pub const KYA_UPGRADE: u8 = 9;
    pub const MILESTONE_COMPLETE: u8 = 10;
    pub const REVENUE_HEALTH_CHANGE: u8 = 11;
    pub const WINDDOWN: u8 = 12;
    pub const MANUAL_ADJUSTMENT: u8 = 13;
}

/// Score oracle configuration singleton
/// Seeds: [b"score_config"]
#[account]
pub struct ScoreConfig {
    pub admin: Pubkey,
    pub oracle: Pubkey,
    pub registry_program: Pubkey,
    pub wallet_program: Pubkey,
    pub vault_program: Pubkey,
    pub is_paused: bool,
    pub bump: u8,
}

impl ScoreConfig {
    pub const SEED: &'static [u8] = b"score_config";
    pub const LEN: usize = 8 + 32 * 5 + 1 + 1;
}

/// Input enum for credit events via CPI
#[derive(AnchorSerialize, AnchorDeserialize)]
pub enum CreditEventInput {
    Borrowed { amount: u64 },
    Repaid { amount: u64 },
    DebtUpdated { new_debt: u64 },
}
