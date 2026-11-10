// ─────────────────────────────────────────────────────────────────────────────
// Credit scoring
// ─────────────────────────────────────────────────────────────────────────────

pub const MAX_CREDIT_SCORE: u16 = 850;
pub const MIN_CREDIT_SCORE: u16 = 200;
pub const DEFAULT_CREDIT_SCORE: u16 = 400;

// ─────────────────────────────────────────────────────────────────────────────
// Health factor (basis points — 10000 = 1.0x)
// ─────────────────────────────────────────────────────────────────────────────

/// 1.5x — fully healthy, all operations allowed
pub const HF_HEALTHY: u16 = 15_000;
/// 1.3x — warn; restrict opening new positions
pub const HF_WARNING: u16 = 13_000;
/// 1.2x — auto-deleverage begins
pub const HF_DANGER: u16 = 12_000;
/// 1.05x — full liquidation triggered
pub const HF_LIQUIDATION: u16 = 10_500;
/// Baseline denominator (1.0x)
pub const HF_DECIMALS: u16 = 10_000;

// ─────────────────────────────────────────────────────────────────────────────
// Position limits (basis points of wallet balance)
// ─────────────────────────────────────────────────────────────────────────────

/// 20% of total wallet value per single trade
pub const MAX_PER_TRADE_BPS: u16 = 2_000;
/// 50% of total wallet value allocated to a single venue
pub const MAX_PER_VENUE_BPS: u16 = 5_000;
/// Vault balance must remain ≥ 120% of outstanding debt after any withdrawal
pub const WITHDRAWAL_BUFFER_BPS: u16 = 12_000;

// ─────────────────────────────────────────────────────────────────────────────
// Fee rates (basis points)
// ─────────────────────────────────────────────────────────────────────────────

/// 10% protocol fee on all incoming revenue (1,000 BPS)
pub const PROTOCOL_FEE_BPS: u16 = 1_000;
/// 0.5% of liquidated collateral → keeper reward
pub const LIQUIDATION_REWARD_BPS: u16 = 50;
/// 10% platform fee on outbound x402 payments (matches protocol fee)
pub const PLATFORM_FEE_BPS: u16 = 1_000;
/// Denominator for all BPS calculations
pub const BPS_DENOMINATOR: u16 = 10_000;

// ─────────────────────────────────────────────────────────────────────────────
// Time constants
// ─────────────────────────────────────────────────────────────────────────────

pub const SECONDS_PER_YEAR: u64 = 31_536_000;
/// Credit scores older than 90 days require re-verification
pub const SCORE_EXPIRY_SECONDS: i64 = 90 * 24 * 60 * 60;

// ─────────────────────────────────────────────────────────────────────────────
// Credit level — maximum credit line (USDC, 6 decimals)
// ─────────────────────────────────────────────────────────────────────────────

pub const LEVEL_0_MAX_CREDIT: u64 = 0;                   // Level 0: KYA only, no wallet
pub const LEVEL_1_MAX_CREDIT: u64 = 500_000_000;         // Level 1: $500 micro
pub const LEVEL_2_MAX_CREDIT: u64 = 20_000_000_000;      // Level 2: $20,000
pub const LEVEL_3_MAX_CREDIT: u64 = 50_000_000_000;      // Level 3: $50,000
pub const LEVEL_4_MAX_CREDIT: u64 = 500_000_000_000;     // Level 4: $500,000

// ─────────────────────────────────────────────────────────────────────────────
// Credit level — leverage ratios (credit = collateral * NUM / DEN)
//
// Level 1: no collateral required (micro credit)
// Level 2: 1:1  — deposit $1 → borrow $1 → $2 total purchasing power
// Level 3: 1:2  — deposit $1 → borrow $2 → $3 total
// Level 4: 1:5+ — deposit $1 → borrow $5 → $6 total (or zero collateral)
// ─────────────────────────────────────────────────────────────────────────────

pub const LEVEL_2_LEVERAGE_NUM: u64 = 1;
pub const LEVEL_2_LEVERAGE_DEN: u64 = 1;
pub const LEVEL_3_LEVERAGE_NUM: u64 = 2;
pub const LEVEL_3_LEVERAGE_DEN: u64 = 1;
pub const LEVEL_4_LEVERAGE_NUM: u64 = 5;
pub const LEVEL_4_LEVERAGE_DEN: u64 = 1;

// ─────────────────────────────────────────────────────────────────────────────
// Credit level — canonical interest rates (annual, basis points)
// Source: Investor Memo, March 2026
// ─────────────────────────────────────────────────────────────────────────────

/// L1 Micro:    0.10%/day = 36.50% APR
pub const LEVEL_1_RATE_BPS: u16 = 3_650;
/// L2 Standard: 0.08%/day = 29.20% APR
pub const LEVEL_2_RATE_BPS: u16 = 2_920;
/// L3 Growth:   0.07%/day = 25.55% APR
pub const LEVEL_3_RATE_BPS: u16 = 2_555;
/// L4 Prime:    0.06%/day = 21.90% APR
pub const LEVEL_4_RATE_BPS: u16 = 2_190;

// ─────────────────────────────────────────────────────────────────────────────
// Credit level — NAV liquidation triggers (basis points of original credit)
// NAV(t) = V(t) / C₀; liquidation fires when NAV < trigger
// ─────────────────────────────────────────────────────────────────────────────

/// L1 trigger: 90%
pub const LEVEL_1_NAV_TRIGGER_BPS: u16 = 9_000;
/// L2 trigger: 85%
pub const LEVEL_2_NAV_TRIGGER_BPS: u16 = 8_500;
/// L3 trigger: 80%
pub const LEVEL_3_NAV_TRIGGER_BPS: u16 = 8_000;
/// L4 trigger: 80%
pub const LEVEL_4_NAV_TRIGGER_BPS: u16 = 8_000;

// ─────────────────────────────────────────────────────────────────────────────
// Vault / pool parameters
// ─────────────────────────────────────────────────────────────────────────────

/// Maximum utilization: 80% of pool can be lent out
pub const UTILIZATION_CAP_BPS: u16 = 8_000;
/// Insurance target: 20% of deployed capital
pub const INSURANCE_TARGET_BPS: u16 = 2_000;
/// Pre-target surplus split: 40% to insurance
pub const INSURANCE_SURPLUS_BPS: u16 = 4_000;
/// Pre-target surplus split: 60% to treasury
pub const TREASURY_SURPLUS_BPS: u16 = 6_000;
/// Post-target surplus split: 10% to insurance
pub const INSURANCE_POST_TARGET_BPS: u16 = 1_000;
/// Post-target surplus split: 90% to treasury
pub const TREASURY_POST_TARGET_BPS: u16 = 9_000;
/// Slippage tolerance for Jupiter liquidations: 2%
pub const SLIPPAGE_TOLERANCE_BPS: u16 = 200;
/// Liquidation score penalty: -40 points (IMMUTABLE)
pub const LIQUIDATION_SCORE_PENALTY: u16 = 40;
/// NAV band floor: 50% — collateral accelerator cannot push trigger below this
pub const NAV_BAND_FLOOR_BPS: u16 = 5_000;
/// Daily rate floor: 0.048%/day = breakeven (17.52% APR)
pub const DAILY_RATE_FLOOR_BPS: u16 = 1_752;
/// Collateral curve steepness k = 2.5 (stored as fixed-point: 250 / 100)
pub const COLLATERAL_CURVE_K_NUM: u16 = 250;
pub const COLLATERAL_CURVE_K_DEN: u16 = 100;
/// Collateral NAV scaling factor: 0.50
pub const COLLATERAL_NAV_SCALING_BPS: u16 = 5_000;
/// Collateral limit scaling factor: 1.50
pub const COLLATERAL_LIMIT_SCALING_BPS: u16 = 15_000;

// ─────────────────────────────────────────────────────────────────────────────
// Tranche APRs (basis points)
// ─────────────────────────────────────────────────────────────────────────────

/// Senior tranche: 10% APR
pub const SENIOR_APR_BPS: u16 = 1_000;
/// Mezzanine tranche: 12% APR
pub const MEZZANINE_APR_BPS: u16 = 1_200;
/// Junior tranche: 20% APR
pub const JUNIOR_APR_BPS: u16 = 2_000;
/// Senior share: 50%
pub const SENIOR_SHARE_BPS: u16 = 5_000;
/// Mezzanine share: 30%
pub const MEZZANINE_SHARE_BPS: u16 = 3_000;
/// Junior share: 20%
pub const JUNIOR_SHARE_BPS: u16 = 2_000;

// ─────────────────────────────────────────────────────────────────────────────
// USDC
// ─────────────────────────────────────────────────────────────────────────────

/// Devnet: use a custom SPL mint. Mainnet: the real USDC mint.
pub const USDC_MAINNET: &str = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
pub const USDC_DECIMALS: u8 = 6;
pub const USDC_ONE: u64 = 1_000_000; // 1 USDC in base units

// ─────────────────────────────────────────────────────────────────────────────
// Type B Service Agent — revenue velocity thresholds (basis points)
// ─────────────────────────────────────────────────────────────────────────────

/// Green zone: revenue ≥ 80% of projected
pub const REVENUE_GREEN_BPS: u16 = 8_000;
/// Yellow zone: revenue 50–80% of projected
pub const REVENUE_YELLOW_BPS: u16 = 5_000;
/// Orange zone: revenue 25–50% of projected
pub const REVENUE_ORANGE_BPS: u16 = 2_500;

/// Zero-revenue days before auto-transition to Orange
pub const ZERO_REVENUE_ORANGE_DAYS: u8 = 7;
/// Zero-revenue days before auto-transition to Red (wind-down)
pub const ZERO_REVENUE_RED_DAYS: u8 = 14;

/// Wind-down grace period: 48 hours
pub const WIND_DOWN_GRACE_SECONDS: i64 = 172_800;

/// Maximum milestones per service plan (fixed array size)
pub const MAX_MILESTONES: usize = 8;
/// Maximum expense destinations per agent
pub const MAX_EXPENSE_DESTINATIONS: u8 = 20;

/// Yellow zone: milestone disbursement delayed by 7 days
pub const YELLOW_MILESTONE_DELAY_SECONDS: i64 = 604_800;

// ─────────────────────────────────────────────────────────────────────────────
// Revenue Source Validation — configurable parameters
// ─────────────────────────────────────────────────────────────────────────────

/// Pattern score threshold for auto-rejection (≥ this = rejected)
pub const PATTERN_REJECT_THRESHOLD: u16 = 80;
/// Pattern score threshold for quarantine (≥ this but < reject = quarantine)
pub const PATTERN_QUARANTINE_THRESHOLD: u16 = 40;
/// Round-trip detection: amount similarity threshold (95% = 9500 BPS)
pub const ROUND_TRIP_SIMILARITY_BPS: u16 = 9_500;
/// Round-trip detection: time window (24 hours)
pub const ROUND_TRIP_WINDOW_SECONDS: i64 = 86_400;
/// Amount anomaly: flag if single payment > 10x expected daily revenue
pub const AMOUNT_ANOMALY_MULTIPLIER: u64 = 10;
/// Single payment > 50% of total credit line = flagged
pub const LARGE_PAYMENT_THRESHOLD_BPS: u16 = 5_000;
/// Revenue overshoot: > 20x declared expectation = rejected
pub const EXTREME_OVERSHOOT_MULTIPLIER: u64 = 20;
/// Revenue overshoot: > 5x declared expectation = warning
pub const MODERATE_OVERSHOOT_MULTIPLIER: u64 = 5;
/// Rapid return: revenue > 3x disbursed within 7 days = suspicious
pub const RAPID_RETURN_RATIO: u64 = 3;
/// Rapid return: window in days
pub const RAPID_RETURN_WINDOW_DAYS: u64 = 7;
/// Max registered revenue sources per agent
pub const MAX_REVENUE_SOURCES: usize = 30;
/// Max associated wallets (owner-linked, auto-rejected)
pub const MAX_ASSOCIATED_WALLETS: usize = 10;
/// Payment history ring buffer size
pub const PAYMENT_HISTORY_SIZE: usize = 16;
/// Outflow history ring buffer size
pub const OUTFLOW_HISTORY_SIZE: usize = 8;
/// Revenue integrity violations before auto-Orange health
pub const REVENUE_VIOLATION_CAP: u8 = 5;
/// Oracle review window: 24 hours
pub const ORACLE_REVIEW_WINDOW_SECONDS: i64 = 86_400;
/// Auto-reject timeout: 72 hours with no oracle review
pub const QUARANTINE_AUTO_REJECT_SECONDS: i64 = 259_200;
/// Auto-approve score threshold (quarantined below this → auto-approved after timeout)
pub const QUARANTINE_AUTO_APPROVE_SCORE: u16 = 60;
