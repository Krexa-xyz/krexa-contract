//! # krexa-payment-router
//!
//! **Program 5 — x402 Revenue Routing + Revenue Source Validation**
//!
//! When an agent sells services via x402, buyers pay through this router.
//! The router splits incoming revenue across three destinations atomically:
//!
//!   1. Platform fee  → Krexa treasury
//!   2. Repayment cut → krexa-credit-vault (CPI `receive_repayment`)
//!   3. Net amount    → merchant (agent's wallet or agent wallet PDA)
//!
//! For Type B (service) agents, the router also runs a three-layer revenue
//! source validation system to prevent wash trading:
//!   - Layer 1: Source classification (on-chain Pubkey checks)
//!   - Layer 2: Pattern detection (on-chain round-trip + amount anomaly)
//!   - Layer 3: Economic validation (on-chain payment size checks)
//!
//! ## PDA layout
//! - `RouterConfig`           [`router_config`]
//! - `MerchantSettlement`     [`settlement`, merchant]
//! - `RevenueValidator`       [`rev_validator`, merchant]
//! - `PaymentHistory`         [`payment_history`, merchant]
//! - `GlobalBlocklist`        [`global_blocklist`]
//! - `PlatformWhitelist`      [`platform_whitelist`]

use anchor_lang::prelude::*;
use anchor_spl::token::{self, Mint, Token, TokenAccount, Transfer};
use krexa_common::constants::*;
use krexa_credit_vault::program::KrexaCreditVault;

declare_id!("Hx1fkePyNggZDjL4mwVWYyd3K3vqg7iWAEtb5xuGBHVL");

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

/// Maximum repayment split a merchant can configure (50 %).
pub const MAX_SPLIT_BPS: u16 = 5_000;
/// Maximum platform fee (10 %).
pub const MAX_PLATFORM_FEE_BPS: u16 = 1_000;
/// Maximum entries in global blocklist PDA
pub const MAX_BLOCKLIST_SIZE: usize = 50;
/// Maximum entries in platform whitelist PDA
pub const MAX_PLATFORM_WHITELIST_SIZE: usize = 20;

// ─────────────────────────────────────────────────────────────────────────────
// Accounts — original
// ─────────────────────────────────────────────────────────────────────────────

#[account]
pub struct RouterConfig {
    pub admin: Pubkey,
    pub oracle: Pubkey,            // signs every execute_payment
    pub usdc_mint: Pubkey,
    pub platform_treasury: Pubkey, // receives platform fees
    pub platform_fee_bps: u16,
    pub is_paused: bool,
    pub bump: u8,
}

impl RouterConfig {
    // 8 + 4*32 + 2 + 1 + 1 + 9 pad
    pub const LEN: usize = 8 + 128 + 2 + 1 + 1 + 9;
    pub const SEED: &'static [u8] = b"router_config";
}

#[account]
pub struct MerchantSettlement {
    pub merchant: Pubkey,              // the agent/merchant earning payments
    pub agent_wallet_pda: Pubkey,      // linked AgentWallet PDA (default if none)
    pub has_active_credit: bool,       // if true → apply split_bps to repayment
    pub split_bps: u16,               // % of remainder sent to vault (0–5000)
    pub total_routed: u64,             // gross amount processed
    pub total_repaid: u64,             // cumulative vault repayments
    pub total_merchant_received: u64,  // cumulative net to merchant
    pub nonce: u64,                    // replay guard — must strictly increase
    pub is_active: bool,
    pub bump: u8,
}

impl MerchantSettlement {
    // 8 + 2*32 + 1 + 2 + 3*8 + 8 + 1 + 1 + 6 pad
    pub const LEN: usize = 8 + 64 + 1 + 2 + 24 + 8 + 1 + 1 + 6;
    pub const SEED: &'static [u8] = b"settlement";
}

// ─────────────────────────────────────────────────────────────────────────────
// Accounts — Revenue Source Validation
// ─────────────────────────────────────────────────────────────────────────────

/// Per-agent payment record stored in the ring buffer.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Default)]
pub struct PaymentRecord {
    /// Who sent the payment
    pub source: Pubkey,
    /// USDC amount (6 decimals)
    pub amount: u64,
    /// Unix timestamp
    pub timestamp: i64,
    /// 0=Verified, 1=Rejected, 2=Quarantined, 3=PendingKeeper
    pub classification: u8,
    /// Was this an x402 payment?
    pub is_x402: bool,
    /// Layer 2 pattern score (0 = not yet checked by keeper)
    pub pattern_score: u16,
}

impl PaymentRecord {
    pub const LEN: usize = 32 + 8 + 8 + 1 + 1 + 2; // 52 bytes
}

/// Per-agent outflow record for round-trip detection.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Default)]
pub struct OutflowRecord {
    /// Where the money went
    pub destination: Pubkey,
    /// Amount sent
    pub amount: u64,
    /// When sent
    pub timestamp: i64,
}

impl OutflowRecord {
    pub const LEN: usize = 32 + 8 + 8; // 48 bytes
}

/// Revenue validation state per merchant. Holds registered sources,
/// associated wallets, and validation parameters.
/// Seeds: ["rev_validator", merchant]
#[account]
pub struct RevenueValidator {
    pub merchant: Pubkey,
    /// Agent's PDA wallet — self-transfers are rejected
    pub agent_wallet_pda: Pubkey,
    /// Agent owner — owner transfers are rejected
    pub agent_owner: Pubkey,

    /// Oracle-approved customer addresses (auto-verified)
    pub registered_sources: [Pubkey; 30],  // MAX_REVENUE_SOURCES
    pub num_registered_sources: u8,

    /// Known associated wallets of the agent owner (auto-rejected)
    pub associated_wallets: [Pubkey; 10],  // MAX_ASSOCIATED_WALLETS
    pub num_associated_wallets: u8,

    /// Expected daily revenue in USDC (set during plan creation)
    pub expected_daily_revenue: u64,
    /// Total credit line (for economic checks)
    pub total_credit: u64,
    /// Cumulative validated revenue (only counts Verified payments)
    pub cumulative_validated_revenue: u64,
    /// Total disbursed from milestones
    pub total_disbursed: u64,
    /// Plan creation timestamp
    pub plan_created_at: i64,

    /// Revenue integrity violations (retroactive rejections of credited payments)
    pub revenue_integrity_violations: u8,
    /// Whether this validator is active
    pub is_active: bool,
    pub bump: u8,
}

impl RevenueValidator {
    // 8 disc + 3*32 keys + 30*32 sources + 1 + 10*32 assoc + 1
    // + 5*8 financials + 1 + 1 + 1 = 8 + 96 + 960 + 1 + 320 + 1 + 40 + 3 = 1429
    pub const LEN: usize = 8 + 96 + 960 + 1 + 320 + 1 + 40 + 3;
    pub const SEED: &'static [u8] = b"rev_validator";
}

/// Ring buffer of recent payments and outflows for pattern detection.
/// Seeds: ["payment_history", merchant]
#[account]
pub struct PaymentHistory {
    pub merchant: Pubkey,
    /// Ring buffer of recent incoming payments
    pub payments: [PaymentRecord; PAYMENT_HISTORY_SIZE],
    pub payment_head: u8,              // next write position
    pub payment_count: u8,             // entries filled (max PAYMENT_HISTORY_SIZE)
    /// Ring buffer of recent outflows (for round-trip detection)
    pub outflows: [OutflowRecord; OUTFLOW_HISTORY_SIZE],
    pub outflow_head: u8,
    pub outflow_count: u8,
    pub bump: u8,
}

impl PaymentHistory {
    pub const LEN: usize = 8
        + 32
        + (PAYMENT_HISTORY_SIZE * PaymentRecord::LEN)
        + 2
        + (OUTFLOW_HISTORY_SIZE * OutflowRecord::LEN)
        + 3;
    pub const SEED: &'static [u8] = b"payment_history";
}

/// Global blocklist of known bad actor wallets (shared across all agents).
/// Seeds: ["global_blocklist"]
#[account]
pub struct GlobalBlocklist {
    pub entries: [Pubkey; 50],  // MAX_BLOCKLIST_SIZE
    pub count: u8,
    pub bump: u8,
}

impl GlobalBlocklist {
    pub const LEN: usize = 8 + 50 * 32 + 1 + 1; // 1610
    pub const SEED: &'static [u8] = b"global_blocklist";
}

/// Platform whitelist of known payment aggregators / commerce platforms.
/// Seeds: ["platform_whitelist"]
#[account]
pub struct PlatformWhitelist {
    pub entries: [Pubkey; 20],  // MAX_PLATFORM_WHITELIST_SIZE
    pub count: u8,
    pub bump: u8,
}

impl PlatformWhitelist {
    pub const LEN: usize = 8 + 20 * 32 + 1 + 1; // 650
    pub const SEED: &'static [u8] = b"platform_whitelist";
}

// ─────────────────────────────────────────────────────────────────────────────
// Events — original
// ─────────────────────────────────────────────────────────────────────────────

#[event]
pub struct RouterInitialized {
    pub admin: Pubkey,
    pub oracle: Pubkey,
    pub platform_fee_bps: u16,
}

#[event]
pub struct SettlementActivated {
    pub merchant: Pubkey,
    pub split_bps: u16,
    pub has_active_credit: bool,
    pub agent_wallet_pda: Pubkey,
}

#[event]
pub struct PaymentRouted {
    pub merchant: Pubkey,
    pub total: u64,
    pub platform_fee: u64,
    pub repayment: u64,
    pub merchant_received: u64,
    pub nonce: u64,
}

#[event]
pub struct SplitUpdated {
    pub merchant: Pubkey,
    pub old_bps: u16,
    pub new_bps: u16,
}

#[event]
pub struct SettlementDeactivated {
    pub merchant: Pubkey,
}

// ─────────────────────────────────────────────────────────────────────────────
// Events — Revenue Validation
// ─────────────────────────────────────────────────────────────────────────────

#[event]
pub struct RevenueClassified {
    pub merchant: Pubkey,
    pub source: Pubkey,
    pub amount: u64,
    /// 0=Verified, 1=Rejected, 2=Quarantined, 3=PendingKeeper
    pub classification: u8,
    /// Rejection reason code (0=none, 1=self, 2=owner, 3=associated, 4=krexa_pda, 5=blocklist, 6=pattern, 7=economic)
    pub reason: u8,
    pub pattern_score: u16,
}

#[event]
pub struct RevenueSourceRegistered {
    pub merchant: Pubkey,
    pub source: Pubkey,
}

#[event]
pub struct RevenueSourceRemoved {
    pub merchant: Pubkey,
    pub source: Pubkey,
}

#[event]
pub struct AssociatedWalletAdded {
    pub merchant: Pubkey,
    pub wallet: Pubkey,
}

#[event]
pub struct QuarantineReviewed {
    pub merchant: Pubkey,
    pub payment_index: u8,
    /// 0=Approve, 1=Reject, 2=ApproveAndWhitelist, 3=RejectAndBlocklist
    pub decision: u8,
    pub amount: u64,
}

#[event]
pub struct RetroactiveRejection {
    pub merchant: Pubkey,
    pub amount: u64,
    pub old_cumulative: u64,
    pub new_cumulative: u64,
    pub violations: u8,
}

#[event]
pub struct OutflowRecorded {
    pub merchant: Pubkey,
    pub destination: Pubkey,
    pub amount: u64,
}

#[event]
pub struct BlocklistUpdated {
    pub wallet: Pubkey,
    pub added: bool,
}

#[event]
pub struct PlatformWhitelistUpdated {
    pub wallet: Pubkey,
    pub added: bool,
}

// ─────────────────────────────────────────────────────────────────────────────
// Errors
// ─────────────────────────────────────────────────────────────────────────────

#[error_code]
pub enum RouterError {
    #[msg("Not admin")]
    NotAdmin,
    #[msg("Not oracle")]
    NotOracle,
    #[msg("Router is paused")]
    Paused,
    #[msg("Settlement is not active")]
    SettlementInactive,
    #[msg("Settlement is already active")]
    SettlementAlreadyActive,
    #[msg("Nonce must be strictly greater than the last recorded nonce")]
    InvalidNonce,
    #[msg("Split bps exceeds maximum of 5000 (50%)")]
    SplitTooHigh,
    #[msg("Amount must be > 0")]
    ZeroAmount,
    #[msg("Arithmetic overflow")]
    Overflow,
    #[msg("Merchant USDC account does not belong to the settlement merchant")]
    InvalidMerchantAccount,
    #[msg("Vault config account is not owned by the vault program")]
    InvalidVaultConfig,
    #[msg("Payer USDC account does not belong to the oracle")]
    InvalidPayerAccount,
    #[msg("Address cannot be the zero/default pubkey")]
    InvalidAddress,
    #[msg("Platform fee exceeds maximum (20%)")]
    InvalidFee,
    #[msg("Fee too high")]
    FeeTooHigh,
    #[msg("Blocklist is full")]
    BlocklistFull,
    #[msg("Whitelist is full")]
    WhitelistFull,
    #[msg("Validator is not active")]
    ValidatorNotActive,
    #[msg("Maximum registered sources reached")]
    MaxSourcesReached,
    #[msg("Source already registered")]
    SourceAlreadyRegistered,
    #[msg("Source not found")]
    SourceNotFound,
    #[msg("Maximum associated wallets reached")]
    MaxAssociatedWalletsReached,
    #[msg("Wallet already associated")]
    WalletAlreadyAssociated,
    #[msg("Invalid decision")]
    InvalidDecision,
    #[msg("Payment index out of bounds")]
    PaymentIndexOutOfBounds,
    #[msg("Payment is not quarantined")]
    NotQuarantined,
}

// ─────────────────────────────────────────────────────────────────────────────
// Revenue validation helpers
// ─────────────────────────────────────────────────────────────────────────────

const CLASSIFICATION_VERIFIED: u8 = 0;
const CLASSIFICATION_REJECTED: u8 = 1;
const CLASSIFICATION_QUARANTINED: u8 = 2;
const CLASSIFICATION_PENDING_KEEPER: u8 = 3;

const REASON_NONE: u8 = 0;
const REASON_SELF: u8 = 1;
const REASON_OWNER: u8 = 2;
const REASON_ASSOCIATED: u8 = 3;
const REASON_BLOCKLIST: u8 = 5;
const REASON_PATTERN: u8 = 6;
const REASON_ECONOMIC: u8 = 7;

pub const DECISION_APPROVE: u8 = 0;
pub const DECISION_REJECT: u8 = 1;
pub const DECISION_APPROVE_AND_WHITELIST: u8 = 2;
pub const DECISION_REJECT_AND_BLOCKLIST: u8 = 3;

fn list_contains(entries: &[Pubkey], count: u8, target: &Pubkey) -> bool {
    let capped = (count as usize).min(entries.len());
    entries[..capped].iter().any(|k| k == target)
}

fn is_round_trip_suspicious(
    source: &Pubkey,
    amount: u64,
    now: i64,
    history: &PaymentHistory,
) -> bool {
    let capped = (history.outflow_count as usize).min(history.outflows.len());
    for outflow in history.outflows[..capped].iter() {
        if outflow.destination != *source {
            continue;
        }
        if outflow.timestamp > now {
            continue;
        }
        if now.saturating_sub(outflow.timestamp) > ROUND_TRIP_WINDOW_SECONDS {
            continue;
        }

        let smaller = amount.min(outflow.amount) as u128;
        let larger = amount.max(outflow.amount) as u128;
        let lhs = smaller.saturating_mul(BPS_DENOMINATOR as u128);
        let rhs = larger.saturating_mul(ROUND_TRIP_SIMILARITY_BPS as u128);
        if lhs >= rhs {
            return true;
        }
    }
    false
}

fn validate_revenue_on_chain(
    source: &Pubkey,
    amount: u64,
    now: i64,
    is_x402: bool,
    validator: &RevenueValidator,
    history: &PaymentHistory,
    blocklist: &GlobalBlocklist,
    platform_whitelist: &PlatformWhitelist,
) -> (u8, u8, u16) {
    // Layer 1 — source classification (hard rejects)
    if *source == validator.agent_wallet_pda {
        return (CLASSIFICATION_REJECTED, REASON_SELF, 0);
    }
    if *source == validator.agent_owner {
        return (CLASSIFICATION_REJECTED, REASON_OWNER, 0);
    }
    if list_contains(
        &validator.associated_wallets,
        validator.num_associated_wallets,
        source,
    ) {
        return (CLASSIFICATION_REJECTED, REASON_ASSOCIATED, 0);
    }
    if list_contains(&blocklist.entries, blocklist.count, source) {
        return (CLASSIFICATION_REJECTED, REASON_BLOCKLIST, 0);
    }

    // Fast-path verifications
    if is_x402 {
        return (CLASSIFICATION_VERIFIED, REASON_NONE, 0);
    }
    if list_contains(
        &platform_whitelist.entries,
        platform_whitelist.count,
        source,
    ) {
        return (CLASSIFICATION_VERIFIED, REASON_NONE, 0);
    }
    if list_contains(
        &validator.registered_sources,
        validator.num_registered_sources,
        source,
    ) {
        return (CLASSIFICATION_VERIFIED, REASON_NONE, 0);
    }

    // Layer 2 + Layer 3 — pattern + economic risk scoring
    let mut pattern_score: u16 = 0;
    let mut economic_flag = false;

    if is_round_trip_suspicious(source, amount, now, history) {
        pattern_score = pattern_score.saturating_add(45);
    }

    let amount_u128 = amount as u128;
    let expected_daily = validator.expected_daily_revenue as u128;
    if expected_daily > 0 {
        if amount_u128 >= expected_daily.saturating_mul(AMOUNT_ANOMALY_MULTIPLIER as u128) {
            pattern_score = pattern_score.saturating_add(40);
        }
        if amount_u128 >= expected_daily.saturating_mul(MODERATE_OVERSHOOT_MULTIPLIER as u128) {
            economic_flag = true;
            pattern_score = pattern_score.saturating_add(25);
        }
        if amount_u128 >= expected_daily.saturating_mul(EXTREME_OVERSHOOT_MULTIPLIER as u128) {
            return (
                CLASSIFICATION_REJECTED,
                REASON_ECONOMIC,
                pattern_score.max(PATTERN_REJECT_THRESHOLD),
            );
        }
    }

    if validator.total_credit > 0 {
        let lhs = amount_u128.saturating_mul(BPS_DENOMINATOR as u128);
        let rhs = (validator.total_credit as u128)
            .saturating_mul(LARGE_PAYMENT_THRESHOLD_BPS as u128);
        if lhs > rhs {
            economic_flag = true;
            pattern_score = pattern_score.saturating_add(30);
        }
    }

    if pattern_score >= PATTERN_REJECT_THRESHOLD {
        return (
            CLASSIFICATION_REJECTED,
            if economic_flag { REASON_ECONOMIC } else { REASON_PATTERN },
            pattern_score,
        );
    }
    if pattern_score >= PATTERN_QUARANTINE_THRESHOLD {
        return (
            CLASSIFICATION_QUARANTINED,
            if economic_flag { REASON_ECONOMIC } else { REASON_PATTERN },
            pattern_score,
        );
    }

    // Unknown but not suspicious: let keeper review while tentatively counting revenue.
    (CLASSIFICATION_PENDING_KEEPER, REASON_NONE, pattern_score)
}

// ─────────────────────────────────────────────────────────────────────────────
// Program
// ─────────────────────────────────────────────────────────────────────────────

#[program]
pub mod krexa_payment_router {
    use super::*;

    // ── 1. initialize ──────────────────────────────────────────────────────

    pub fn initialize(ctx: Context<Initialize>, platform_fee_bps: u16) -> Result<()> {
        require!(platform_fee_bps <= MAX_PLATFORM_FEE_BPS, RouterError::FeeTooHigh);
        let cfg = &mut ctx.accounts.config;
        cfg.admin = ctx.accounts.admin.key();
        cfg.oracle = ctx.accounts.oracle.key();
        cfg.usdc_mint = ctx.accounts.usdc_mint.key();
        cfg.platform_treasury = ctx.accounts.platform_treasury.key();
        cfg.platform_fee_bps = platform_fee_bps;
        cfg.is_paused = false;
        cfg.bump = ctx.bumps.config;

        emit!(RouterInitialized {
            admin: cfg.admin,
            oracle: cfg.oracle,
            platform_fee_bps,
        });
        Ok(())
    }

    // ── 2. activate_settlement ─────────────────────────────────────────────

    pub fn activate_settlement(
        ctx: Context<ActivateSettlement>,
        merchant: Pubkey,
        split_bps: u16,
        agent_wallet_pda: Pubkey,
    ) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, RouterError::Paused);
        require!(split_bps <= MAX_SPLIT_BPS, RouterError::SplitTooHigh);

        let has_active_credit = agent_wallet_pda != Pubkey::default();

        let s = &mut ctx.accounts.settlement;
        s.merchant = merchant;
        s.agent_wallet_pda = agent_wallet_pda;
        s.has_active_credit = has_active_credit;
        s.split_bps = split_bps;
        s.total_routed = 0;
        s.total_repaid = 0;
        s.total_merchant_received = 0;
        s.nonce = 0;
        s.is_active = true;
        s.bump = ctx.bumps.settlement;

        emit!(SettlementActivated {
            merchant,
            split_bps,
            has_active_credit,
            agent_wallet_pda,
        });
        Ok(())
    }

    // ── 3. execute_payment ─────────────────────────────────────────────────

    pub fn execute_payment(
        ctx: Context<ExecutePayment>,
        merchant: Pubkey,
        amount: u64,
        nonce: u64,
    ) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, RouterError::Paused);
        require!(amount > 0, RouterError::ZeroAmount);
        require!(ctx.accounts.settlement.is_active, RouterError::SettlementInactive);
        require!(nonce > ctx.accounts.settlement.nonce, RouterError::InvalidNonce);

        let cfg = &ctx.accounts.config;
        let split = &ctx.accounts.settlement;

        // ── fee maths ─────────────────────────────────────────────────────
        let platform_fee = (amount as u128)
            .checked_mul(cfg.platform_fee_bps as u128)
            .ok_or(RouterError::Overflow)?
            .checked_div(BPS_DENOMINATOR as u128)
            .ok_or(RouterError::Overflow)? as u64;

        let remainder = amount.saturating_sub(platform_fee);

        let (repayment, merchant_amount) =
            if split.has_active_credit && split.split_bps > 0 {
                let r = (remainder as u128)
                    .checked_mul(split.split_bps as u128)
                    .ok_or(RouterError::Overflow)?
                    .checked_div(BPS_DENOMINATOR as u128)
                    .ok_or(RouterError::Overflow)? as u64;
                (r, remainder.saturating_sub(r))
            } else {
                (0u64, remainder)
            };

        // ── a) platform fee → treasury ────────────────────────────────────
        if platform_fee > 0 {
            token::transfer(
                CpiContext::new(
                    ctx.accounts.token_program.to_account_info(),
                    Transfer {
                        from: ctx.accounts.payer_usdc.to_account_info(),
                        to: ctx.accounts.platform_treasury_token.to_account_info(),
                        authority: ctx.accounts.oracle.to_account_info(),
                    },
                ),
                platform_fee,
            )?;
        }

        // ── b) repayment → vault + CPI receive_repayment ─────────────────
        if repayment > 0 {
            token::transfer(
                CpiContext::new(
                    ctx.accounts.token_program.to_account_info(),
                    Transfer {
                        from: ctx.accounts.payer_usdc.to_account_info(),
                        to: ctx.accounts.vault_token.to_account_info(),
                        authority: ctx.accounts.oracle.to_account_info(),
                    },
                ),
                repayment,
            )?;

            let bump = ctx.accounts.config.bump;
            let config_seeds: &[&[&[u8]]] = &[&[RouterConfig::SEED, &[bump]]];

            krexa_credit_vault::cpi::receive_repayment(
                CpiContext::new_with_signer(
                    ctx.accounts.vault_program.to_account_info(),
                    krexa_credit_vault::cpi::accounts::ReceiveRepayment {
                        config: ctx.accounts.vault_config.to_account_info(),
                        vault_token: ctx.accounts.vault_token.to_account_info(),
                        insurance_token: ctx.accounts.insurance_token.to_account_info(),
                        credit_line: ctx.accounts.credit_line.to_account_info(),
                        wallet_program_authority: ctx.accounts.config.to_account_info(),
                        token_program: ctx.accounts.token_program.to_account_info(),
                    },
                    config_seeds,
                ),
                merchant,
                repayment,
            )?;
        }

        // ── c) net → merchant ─────────────────────────────────────────────
        if merchant_amount > 0 {
            token::transfer(
                CpiContext::new(
                    ctx.accounts.token_program.to_account_info(),
                    Transfer {
                        from: ctx.accounts.payer_usdc.to_account_info(),
                        to: ctx.accounts.merchant_usdc.to_account_info(),
                        authority: ctx.accounts.oracle.to_account_info(),
                    },
                ),
                merchant_amount,
            )?;
        }

        // ── d) update state ───────────────────────────────────────────────
        let s = &mut ctx.accounts.settlement;
        s.nonce = nonce;
        s.total_routed = s.total_routed.saturating_add(amount);
        s.total_repaid = s.total_repaid.saturating_add(repayment);
        s.total_merchant_received = s.total_merchant_received.saturating_add(merchant_amount);

        // ── e) event ──────────────────────────────────────────────────────
        emit!(PaymentRouted {
            merchant,
            total: amount,
            platform_fee,
            repayment,
            merchant_received: merchant_amount,
            nonce,
        });
        Ok(())
    }

    // ── 4. update_split ────────────────────────────────────────────────────

    pub fn update_split(
        ctx: Context<OracleAction>,
        merchant: Pubkey,
        new_split_bps: u16,
    ) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, RouterError::Paused);
        require!(new_split_bps <= MAX_SPLIT_BPS, RouterError::SplitTooHigh);
        let s = &mut ctx.accounts.settlement;
        let old_bps = s.split_bps;
        s.split_bps = new_split_bps;
        s.has_active_credit = s.agent_wallet_pda != Pubkey::default() && new_split_bps > 0;
        emit!(SplitUpdated { merchant, old_bps, new_bps: new_split_bps });
        Ok(())
    }

    // ── 5. deactivate_settlement ───────────────────────────────────────────

    pub fn deactivate_settlement(
        ctx: Context<AdminAction>,
        merchant: Pubkey,
    ) -> Result<()> {
        require!(ctx.accounts.settlement.is_active, RouterError::SettlementInactive);
        ctx.accounts.settlement.is_active = false;
        emit!(SettlementDeactivated { merchant });
        Ok(())
    }

    // ── 5b. reactivate_settlement ─────────────────────────────────────────

    pub fn reactivate_settlement(
        ctx: Context<OracleAction>,
        _merchant: Pubkey,
    ) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, RouterError::Paused);
        require!(!ctx.accounts.settlement.is_active, RouterError::SettlementAlreadyActive);
        ctx.accounts.settlement.is_active = true;
        Ok(())
    }

    // ── 6. set_paused ──────────────────────────────────────────────────────

    pub fn set_paused(ctx: Context<AdminConfig>, paused: bool) -> Result<()> {
        ctx.accounts.config.is_paused = paused;
        Ok(())
    }

    // ── 7. update_config ───────────────────────────────────────────────────

    pub fn update_config(
        ctx: Context<AdminConfig>,
        new_admin: Option<Pubkey>,
        new_oracle: Option<Pubkey>,
        new_platform_treasury: Option<Pubkey>,
        new_platform_fee_bps: Option<u16>,
    ) -> Result<()> {
        let cfg = &mut ctx.accounts.config;
        // SOL-075 fix: prevent permanent lockout via zero-address
        if let Some(admin) = new_admin {
            require!(admin != Pubkey::default(), RouterError::InvalidAddress);
            cfg.admin = admin;
        }
        if let Some(oracle) = new_oracle {
            require!(oracle != Pubkey::default(), RouterError::InvalidAddress);
            cfg.oracle = oracle;
        }
        if let Some(treasury) = new_platform_treasury {
            cfg.platform_treasury = treasury;
        }
        // SOL-078 fix: cap platform fee at 20%
        if let Some(fee) = new_platform_fee_bps {
            require!(fee <= 2000, RouterError::InvalidFee);
            cfg.platform_fee_bps = fee;
        }
        Ok(())
    }

    // ═════════════════════════════════════════════════════════════════════════
    // REVENUE SOURCE VALIDATION INSTRUCTIONS
    // ═════════════════════════════════════════════════════════════════════════

    // ── 8. create_revenue_validator ────────────────────────────────────────
    /// Oracle creates a RevenueValidator PDA for a Type B agent.

    pub fn create_revenue_validator(
        ctx: Context<CreateRevenueValidator>,
        merchant: Pubkey,
        agent_wallet_pda: Pubkey,
        agent_owner: Pubkey,
        expected_daily_revenue: u64,
        total_credit: u64,
    ) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, RouterError::Paused);

        let now = Clock::get()?.unix_timestamp;
        let v = &mut ctx.accounts.validator;
        v.merchant = merchant;
        v.agent_wallet_pda = agent_wallet_pda;
        v.agent_owner = agent_owner;
        v.registered_sources = [Pubkey::default(); 30];
        v.num_registered_sources = 0;
        v.associated_wallets = [Pubkey::default(); 10];
        v.num_associated_wallets = 0;
        v.expected_daily_revenue = expected_daily_revenue;
        v.total_credit = total_credit;
        v.cumulative_validated_revenue = 0;
        v.total_disbursed = 0;
        v.plan_created_at = now;
        v.revenue_integrity_violations = 0;
        v.is_active = true;
        v.bump = ctx.bumps.validator;
        Ok(())
    }

    // ── 9. create_payment_history ──────────────────────────────────────────
    /// Oracle creates a PaymentHistory PDA for a Type B agent.

    pub fn create_payment_history(
        ctx: Context<CreatePaymentHistory>,
        merchant: Pubkey,
    ) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, RouterError::Paused);

        let h = &mut ctx.accounts.history;
        h.merchant = merchant;
        h.payments = [PaymentRecord::default(); PAYMENT_HISTORY_SIZE];
        h.payment_head = 0;
        h.payment_count = 0;
        h.outflows = [OutflowRecord::default(); OUTFLOW_HISTORY_SIZE];
        h.outflow_head = 0;
        h.outflow_count = 0;
        h.bump = ctx.bumps.history;
        Ok(())
    }

    // ── 10. initialize_blocklist ───────────────────────────────────────────

    pub fn initialize_blocklist(ctx: Context<InitBlocklist>) -> Result<()> {
        let b = &mut ctx.accounts.blocklist;
        b.entries = [Pubkey::default(); 50];
        b.count = 0;
        b.bump = ctx.bumps.blocklist;
        Ok(())
    }

    // ── 11. initialize_platform_whitelist ──────────────────────────────────

    pub fn initialize_platform_whitelist(ctx: Context<InitPlatformWhitelist>) -> Result<()> {
        let w = &mut ctx.accounts.whitelist;
        w.entries = [Pubkey::default(); 20];
        w.count = 0;
        w.bump = ctx.bumps.whitelist;
        Ok(())
    }

    // ── 12. add_to_blocklist ──────────────────────────────────────────────

    pub fn add_to_blocklist(ctx: Context<AdminBlocklist>, wallet: Pubkey) -> Result<()> {
        let b = &mut ctx.accounts.blocklist;
        require!((b.count as usize) < MAX_BLOCKLIST_SIZE, RouterError::BlocklistFull);
        let idx = b.count as usize;
        b.entries[idx] = wallet;
        b.count += 1;
        emit!(BlocklistUpdated { wallet, added: true });
        Ok(())
    }

    // ── 13. add_to_platform_whitelist ─────────────────────────────────────

    pub fn add_to_platform_whitelist(ctx: Context<AdminPlatformWhitelist>, wallet: Pubkey) -> Result<()> {
        let w = &mut ctx.accounts.whitelist;
        require!((w.count as usize) < MAX_PLATFORM_WHITELIST_SIZE, RouterError::WhitelistFull);
        let idx = w.count as usize;
        w.entries[idx] = wallet;
        w.count += 1;
        emit!(PlatformWhitelistUpdated { wallet, added: true });
        Ok(())
    }

    // ── 14. register_revenue_source ───────────────────────────────────────
    /// Oracle adds a verified customer address to the agent's registered sources.

    pub fn register_revenue_source(
        ctx: Context<ManageRevenueSource>,
        _merchant: Pubkey,
        source: Pubkey,
    ) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, RouterError::Paused);
        let v = &mut ctx.accounts.validator;
        require!(v.is_active, RouterError::ValidatorNotActive);
        require!(
            (v.num_registered_sources as usize) < MAX_REVENUE_SOURCES,
            RouterError::MaxSourcesReached
        );

        // Check for duplicates
        for i in 0..v.num_registered_sources as usize {
            require!(v.registered_sources[i] != source, RouterError::SourceAlreadyRegistered);
        }

        let idx = v.num_registered_sources as usize;
        v.registered_sources[idx] = source;
        v.num_registered_sources += 1;

        emit!(RevenueSourceRegistered {
            merchant: v.merchant,
            source,
        });
        Ok(())
    }

    // ── 15. remove_revenue_source ─────────────────────────────────────────

    pub fn remove_revenue_source(
        ctx: Context<ManageRevenueSource>,
        _merchant: Pubkey,
        source: Pubkey,
    ) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, RouterError::Paused);
        let v = &mut ctx.accounts.validator;
        require!(v.is_active, RouterError::ValidatorNotActive);

        let mut found = false;
        for i in 0..v.num_registered_sources as usize {
            if v.registered_sources[i] == source {
                // Swap with last and decrement
                let last_idx = (v.num_registered_sources - 1) as usize;
                v.registered_sources[i] = v.registered_sources[last_idx];
                v.registered_sources[last_idx] = Pubkey::default();
                v.num_registered_sources -= 1;
                found = true;
                break;
            }
        }
        require!(found, RouterError::SourceNotFound);

        emit!(RevenueSourceRemoved {
            merchant: v.merchant,
            source,
        });
        Ok(())
    }

    // ── 16. add_associated_wallet ─────────────────────────────────────────
    /// Oracle adds a known associated wallet of the agent owner (auto-rejected).

    pub fn add_associated_wallet(
        ctx: Context<ManageRevenueSource>,
        _merchant: Pubkey,
        wallet: Pubkey,
    ) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, RouterError::Paused);
        let v = &mut ctx.accounts.validator;
        require!(v.is_active, RouterError::ValidatorNotActive);
        require!(
            (v.num_associated_wallets as usize) < MAX_ASSOCIATED_WALLETS,
            RouterError::MaxAssociatedWalletsReached
        );

        for i in 0..v.num_associated_wallets as usize {
            require!(v.associated_wallets[i] != wallet, RouterError::WalletAlreadyAssociated);
        }

        let idx = v.num_associated_wallets as usize;
        v.associated_wallets[idx] = wallet;
        v.num_associated_wallets += 1;

        emit!(AssociatedWalletAdded {
            merchant: v.merchant,
            wallet,
        });
        Ok(())
    }

    // ── 17. validate_revenue ──────────────────────────────────────────────
    /// Run on-chain revenue validation for an incoming payment.
    /// Called by oracle alongside or after execute_payment.
    /// Classifies the payment, records it in history, and updates cumulative revenue.

    pub fn validate_revenue(
        ctx: Context<ValidateRevenue>,
        _merchant: Pubkey,
        source: Pubkey,
        amount: u64,
        is_x402: bool,
    ) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, RouterError::Paused);
        require!(amount > 0, RouterError::ZeroAmount);

        let now = Clock::get()?.unix_timestamp;

        // Run combined on-chain validation
        let (classification, reason, pattern_score) = validate_revenue_on_chain(
            &source,
            amount,
            now,
            is_x402,
            &ctx.accounts.validator,
            &ctx.accounts.history,
            &ctx.accounts.blocklist,
            &ctx.accounts.platform_whitelist,
        );

        // Record in payment history ring buffer
        let history = &mut ctx.accounts.history;
        let head = history.payment_head as usize;
        history.payments[head] = PaymentRecord {
            source,
            amount,
            timestamp: now,
            classification,
            is_x402,
            pattern_score,
        };
        history.payment_head = ((head + 1) % PAYMENT_HISTORY_SIZE) as u8;
        if (history.payment_count as usize) < PAYMENT_HISTORY_SIZE {
            history.payment_count += 1;
        }

        // Update cumulative revenue ONLY for verified payments
        let validator = &mut ctx.accounts.validator;
        if classification == 0 {
            // Verified — credit immediately
            validator.cumulative_validated_revenue = validator
                .cumulative_validated_revenue
                .saturating_add(amount);
        }
        // Rejected (1): not credited
        // Quarantined (2): not credited yet, awaiting oracle
        // PendingKeeper (3): tentatively credited (keeper can revoke)
        if classification == 3 {
            validator.cumulative_validated_revenue = validator
                .cumulative_validated_revenue
                .saturating_add(amount);
        }

        emit!(RevenueClassified {
            merchant: validator.merchant,
            source,
            amount,
            classification,
            reason,
            pattern_score,
        });

        Ok(())
    }

    // ── 18. record_outflow ────────────────────────────────────────────────
    /// Record an outflow from the agent's PDA for round-trip detection.
    /// Called by keeper or oracle when the agent sends money out.

    pub fn record_outflow(
        ctx: Context<RecordOutflow>,
        _merchant: Pubkey,
        destination: Pubkey,
        amount: u64,
    ) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, RouterError::Paused);

        let now = Clock::get()?.unix_timestamp;
        let history = &mut ctx.accounts.history;

        let head = history.outflow_head as usize;
        history.outflows[head] = OutflowRecord {
            destination,
            amount,
            timestamp: now,
        };
        history.outflow_head = ((head + 1) % OUTFLOW_HISTORY_SIZE) as u8;
        if (history.outflow_count as usize) < OUTFLOW_HISTORY_SIZE {
            history.outflow_count += 1;
        }

        emit!(OutflowRecorded {
            merchant: history.merchant,
            destination,
            amount,
        });
        Ok(())
    }

    // ── 19. review_quarantined ─────────────────────────────────────────────
    /// Oracle reviews a quarantined payment and makes a decision.

    pub fn review_quarantined(
        ctx: Context<ReviewQuarantined>,
        _merchant: Pubkey,
        payment_index: u8,
        decision: u8,
    ) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, RouterError::Paused);
        require!(decision <= 3, RouterError::InvalidDecision);
        require!(
            (payment_index as usize) < PAYMENT_HISTORY_SIZE,
            RouterError::PaymentIndexOutOfBounds
        );

        let history = &mut ctx.accounts.history;
        let payment = &mut history.payments[payment_index as usize];

        require!(
            payment.classification == 2 || payment.classification == 3,
            RouterError::NotQuarantined
        );

        let amount = payment.amount;
        let was_pending_keeper = payment.classification == 3;

        match decision {
            DECISION_APPROVE => {
                payment.classification = 0; // Verified
                if !was_pending_keeper {
                    // Was quarantined (not tentatively credited) → credit now
                    let v = &mut ctx.accounts.validator;
                    v.cumulative_validated_revenue = v
                        .cumulative_validated_revenue
                        .saturating_add(amount);
                }
            }
            DECISION_REJECT => {
                payment.classification = 1; // Rejected
                if was_pending_keeper {
                    // Was tentatively credited → must decrement
                    let v = &mut ctx.accounts.validator;
                    v.cumulative_validated_revenue = v
                        .cumulative_validated_revenue
                        .saturating_sub(amount);
                    v.revenue_integrity_violations = v
                        .revenue_integrity_violations
                        .saturating_add(1);
                }
            }
            DECISION_APPROVE_AND_WHITELIST => {
                payment.classification = 0; // Verified
                if !was_pending_keeper {
                    let v = &mut ctx.accounts.validator;
                    v.cumulative_validated_revenue = v
                        .cumulative_validated_revenue
                        .saturating_add(amount);
                }
                // Add source to registered_revenue_sources
                let source = payment.source;
                let v = &mut ctx.accounts.validator;
                if (v.num_registered_sources as usize) < MAX_REVENUE_SOURCES {
                    let idx = v.num_registered_sources as usize;
                    v.registered_sources[idx] = source;
                    v.num_registered_sources += 1;
                }
            }
            DECISION_REJECT_AND_BLOCKLIST => {
                payment.classification = 1; // Rejected
                if was_pending_keeper {
                    let v = &mut ctx.accounts.validator;
                    v.cumulative_validated_revenue = v
                        .cumulative_validated_revenue
                        .saturating_sub(amount);
                    v.revenue_integrity_violations = v
                        .revenue_integrity_violations
                        .saturating_add(1);
                }
                // Add to global blocklist
                let source = payment.source;
                let b = &mut ctx.accounts.blocklist;
                if (b.count as usize) < MAX_BLOCKLIST_SIZE {
                    let idx = b.count as usize;
                    b.entries[idx] = source;
                    b.count += 1;
                }
            }
            _ => unreachable!(),
        }

        emit!(QuarantineReviewed {
            merchant: ctx.accounts.validator.merchant,
            payment_index,
            decision,
            amount,
        });
        Ok(())
    }

    // ── 20. retroactive_reject ─────────────────────────────────────────────
    /// Keeper/oracle retroactively rejects a previously credited payment.
    /// Decrements cumulative_validated_revenue and increments violation counter.

    pub fn retroactive_reject(
        ctx: Context<RetroactiveReject>,
        _merchant: Pubkey,
        payment_index: u8,
    ) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, RouterError::Paused);
        require!(
            (payment_index as usize) < PAYMENT_HISTORY_SIZE,
            RouterError::PaymentIndexOutOfBounds
        );

        let history = &mut ctx.accounts.history;
        let payment = &mut history.payments[payment_index as usize];

        // Can only retroactively reject Verified or PendingKeeper payments
        require!(
            payment.classification == 0 || payment.classification == 3,
            RouterError::NotQuarantined
        );

        let amount = payment.amount;
        payment.classification = 1; // Rejected

        let validator = &mut ctx.accounts.validator;
        let old_cumulative = validator.cumulative_validated_revenue;
        validator.cumulative_validated_revenue = validator
            .cumulative_validated_revenue
            .saturating_sub(amount);
        validator.revenue_integrity_violations = validator
            .revenue_integrity_violations
            .saturating_add(1);

        emit!(RetroactiveRejection {
            merchant: validator.merchant,
            amount,
            old_cumulative,
            new_cumulative: validator.cumulative_validated_revenue,
            violations: validator.revenue_integrity_violations,
        });

        Ok(())
    }

    // ── 21. update_validator_params ────────────────────────────────────────
    /// Oracle updates validator parameters (expected revenue, disbursed, etc.)

    pub fn update_validator_params(
        ctx: Context<ManageRevenueSource>,
        _merchant: Pubkey,
        expected_daily_revenue: Option<u64>,
        total_credit: Option<u64>,
        total_disbursed: Option<u64>,
    ) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, RouterError::Paused);
        let v = &mut ctx.accounts.validator;
        require!(v.is_active, RouterError::ValidatorNotActive);

        if let Some(edr) = expected_daily_revenue {
            v.expected_daily_revenue = edr;
        }
        if let Some(tc) = total_credit {
            v.total_credit = tc;
        }
        if let Some(td) = total_disbursed {
            v.total_disbursed = td;
        }
        Ok(())
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Contexts — original
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(
        init,
        payer = admin,
        space = RouterConfig::LEN,
        seeds = [RouterConfig::SEED],
        bump,
    )]
    pub config: Account<'info, RouterConfig>,

    pub usdc_mint: Account<'info, Mint>,

    #[account(token::mint = usdc_mint)]
    pub platform_treasury: Account<'info, TokenAccount>,

    /// CHECK: pubkey only stored, no signature needed at init time.
    pub oracle: UncheckedAccount<'info>,

    #[account(mut)]
    pub admin: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(merchant: Pubkey)]
pub struct ActivateSettlement<'info> {
    #[account(
        seeds = [RouterConfig::SEED],
        bump = config.bump,
        has_one = oracle @ RouterError::NotOracle,
    )]
    pub config: Account<'info, RouterConfig>,

    #[account(
        init,
        payer = oracle,
        space = MerchantSettlement::LEN,
        seeds = [MerchantSettlement::SEED, merchant.as_ref()],
        bump,
    )]
    pub settlement: Account<'info, MerchantSettlement>,

    #[account(mut)]
    pub oracle: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(merchant: Pubkey, amount: u64, nonce: u64)]
pub struct ExecutePayment<'info> {
    #[account(
        seeds = [RouterConfig::SEED],
        bump = config.bump,
        has_one = oracle @ RouterError::NotOracle,
    )]
    pub config: Box<Account<'info, RouterConfig>>,

    #[account(
        mut,
        seeds = [MerchantSettlement::SEED, merchant.as_ref()],
        bump = settlement.bump,
    )]
    pub settlement: Box<Account<'info, MerchantSettlement>>,

    // ── Payment accounts ──────────────────────────────────────────────────
    /// Buyer's USDC — oracle must have delegate authority (or hold in escrow).
    /// SOL-064 fix: explicit owner constraint to prevent future refactoring mistakes.
    #[account(
        mut,
        token::mint = config.usdc_mint,
        constraint = payer_usdc.owner == oracle.key() @ RouterError::InvalidPayerAccount,
    )]
    pub payer_usdc: Box<Account<'info, TokenAccount>>,

    #[account(
        mut,
        token::mint = config.usdc_mint,
        constraint = merchant_usdc.owner == settlement.merchant
            || merchant_usdc.owner == settlement.agent_wallet_pda
            @ RouterError::InvalidMerchantAccount,
    )]
    pub merchant_usdc: Box<Account<'info, TokenAccount>>,

    #[account(
        mut,
        address = config.platform_treasury,
    )]
    pub platform_treasury_token: Box<Account<'info, TokenAccount>>,

    /// CHECK: validated by vault program via PDA seeds during CPI.
    #[account(
        mut,
        constraint = *vault_config.owner == vault_program.key() @ RouterError::InvalidVaultConfig,
    )]
    pub vault_config: UncheckedAccount<'info>,

    #[account(mut)]
    pub vault_token: Box<Account<'info, TokenAccount>>,

    #[account(mut)]
    pub insurance_token: Box<Account<'info, TokenAccount>>,

    /// CHECK: validated by vault program (seeds = [b"credit_line", merchant])
    #[account(mut)]
    pub credit_line: UncheckedAccount<'info>,

    #[account(mut)]
    pub oracle: Signer<'info>,

    pub vault_program: Program<'info, KrexaCreditVault>,
    pub token_program: Program<'info, Token>,
}

#[derive(Accounts)]
#[instruction(merchant: Pubkey)]
pub struct OracleAction<'info> {
    #[account(
        seeds = [RouterConfig::SEED],
        bump = config.bump,
        has_one = oracle @ RouterError::NotOracle,
    )]
    pub config: Account<'info, RouterConfig>,

    #[account(
        mut,
        seeds = [MerchantSettlement::SEED, merchant.as_ref()],
        bump = settlement.bump,
    )]
    pub settlement: Account<'info, MerchantSettlement>,

    pub oracle: Signer<'info>,
}

#[derive(Accounts)]
#[instruction(merchant: Pubkey)]
pub struct AdminAction<'info> {
    #[account(
        seeds = [RouterConfig::SEED],
        bump = config.bump,
        has_one = admin @ RouterError::NotAdmin,
    )]
    pub config: Account<'info, RouterConfig>,

    #[account(
        mut,
        seeds = [MerchantSettlement::SEED, merchant.as_ref()],
        bump = settlement.bump,
    )]
    pub settlement: Account<'info, MerchantSettlement>,

    pub admin: Signer<'info>,
}

#[derive(Accounts)]
pub struct AdminConfig<'info> {
    #[account(
        mut,
        seeds = [RouterConfig::SEED],
        bump = config.bump,
        has_one = admin @ RouterError::NotAdmin,
    )]
    pub config: Account<'info, RouterConfig>,

    pub admin: Signer<'info>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Contexts — Revenue Validation
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Accounts)]
#[instruction(merchant: Pubkey)]
pub struct CreateRevenueValidator<'info> {
    #[account(
        seeds = [RouterConfig::SEED],
        bump = config.bump,
        has_one = oracle @ RouterError::NotOracle,
    )]
    pub config: Box<Account<'info, RouterConfig>>,

    #[account(
        init,
        payer = oracle,
        space = RevenueValidator::LEN,
        seeds = [RevenueValidator::SEED, merchant.as_ref()],
        bump,
    )]
    pub validator: Box<Account<'info, RevenueValidator>>,

    #[account(mut)]
    pub oracle: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(merchant: Pubkey)]
pub struct CreatePaymentHistory<'info> {
    #[account(
        seeds = [RouterConfig::SEED],
        bump = config.bump,
        has_one = oracle @ RouterError::NotOracle,
    )]
    pub config: Box<Account<'info, RouterConfig>>,

    #[account(
        init,
        payer = oracle,
        space = PaymentHistory::LEN,
        seeds = [PaymentHistory::SEED, merchant.as_ref()],
        bump,
    )]
    pub history: Box<Account<'info, PaymentHistory>>,

    #[account(mut)]
    pub oracle: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct InitBlocklist<'info> {
    #[account(
        seeds = [RouterConfig::SEED],
        bump = config.bump,
        has_one = admin @ RouterError::NotAdmin,
    )]
    pub config: Box<Account<'info, RouterConfig>>,

    #[account(
        init,
        payer = admin,
        space = GlobalBlocklist::LEN,
        seeds = [GlobalBlocklist::SEED],
        bump,
    )]
    pub blocklist: Box<Account<'info, GlobalBlocklist>>,

    #[account(mut)]
    pub admin: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct InitPlatformWhitelist<'info> {
    #[account(
        seeds = [RouterConfig::SEED],
        bump = config.bump,
        has_one = admin @ RouterError::NotAdmin,
    )]
    pub config: Account<'info, RouterConfig>,

    #[account(
        init,
        payer = admin,
        space = PlatformWhitelist::LEN,
        seeds = [PlatformWhitelist::SEED],
        bump,
    )]
    pub whitelist: Account<'info, PlatformWhitelist>,

    #[account(mut)]
    pub admin: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct AdminBlocklist<'info> {
    #[account(
        seeds = [RouterConfig::SEED],
        bump = config.bump,
        has_one = admin @ RouterError::NotAdmin,
    )]
    pub config: Box<Account<'info, RouterConfig>>,

    #[account(
        mut,
        seeds = [GlobalBlocklist::SEED],
        bump = blocklist.bump,
    )]
    pub blocklist: Box<Account<'info, GlobalBlocklist>>,

    pub admin: Signer<'info>,
}

#[derive(Accounts)]
pub struct AdminPlatformWhitelist<'info> {
    #[account(
        seeds = [RouterConfig::SEED],
        bump = config.bump,
        has_one = admin @ RouterError::NotAdmin,
    )]
    pub config: Box<Account<'info, RouterConfig>>,

    #[account(
        mut,
        seeds = [PlatformWhitelist::SEED],
        bump = whitelist.bump,
    )]
    pub whitelist: Box<Account<'info, PlatformWhitelist>>,

    pub admin: Signer<'info>,
}

#[derive(Accounts)]
#[instruction(merchant: Pubkey)]
pub struct ManageRevenueSource<'info> {
    #[account(
        seeds = [RouterConfig::SEED],
        bump = config.bump,
        has_one = oracle @ RouterError::NotOracle,
    )]
    pub config: Box<Account<'info, RouterConfig>>,

    #[account(
        mut,
        seeds = [RevenueValidator::SEED, merchant.as_ref()],
        bump = validator.bump,
    )]
    pub validator: Box<Account<'info, RevenueValidator>>,

    pub oracle: Signer<'info>,
}

#[derive(Accounts)]
#[instruction(merchant: Pubkey)]
pub struct ValidateRevenue<'info> {
    #[account(
        seeds = [RouterConfig::SEED],
        bump = config.bump,
        has_one = oracle @ RouterError::NotOracle,
    )]
    pub config: Box<Account<'info, RouterConfig>>,

    #[account(
        mut,
        seeds = [RevenueValidator::SEED, merchant.as_ref()],
        bump = validator.bump,
    )]
    pub validator: Box<Account<'info, RevenueValidator>>,

    #[account(
        mut,
        seeds = [PaymentHistory::SEED, merchant.as_ref()],
        bump = history.bump,
    )]
    pub history: Box<Account<'info, PaymentHistory>>,

    #[account(
        seeds = [GlobalBlocklist::SEED],
        bump = blocklist.bump,
    )]
    pub blocklist: Box<Account<'info, GlobalBlocklist>>,

    #[account(
        seeds = [PlatformWhitelist::SEED],
        bump = platform_whitelist.bump,
    )]
    pub platform_whitelist: Box<Account<'info, PlatformWhitelist>>,

    pub oracle: Signer<'info>,
}

#[derive(Accounts)]
#[instruction(merchant: Pubkey)]
pub struct RecordOutflow<'info> {
    #[account(
        seeds = [RouterConfig::SEED],
        bump = config.bump,
        has_one = oracle @ RouterError::NotOracle,
    )]
    pub config: Box<Account<'info, RouterConfig>>,

    #[account(
        mut,
        seeds = [PaymentHistory::SEED, merchant.as_ref()],
        bump = history.bump,
    )]
    pub history: Box<Account<'info, PaymentHistory>>,

    pub oracle: Signer<'info>,
}

#[derive(Accounts)]
#[instruction(merchant: Pubkey)]
pub struct ReviewQuarantined<'info> {
    #[account(
        seeds = [RouterConfig::SEED],
        bump = config.bump,
        has_one = oracle @ RouterError::NotOracle,
    )]
    pub config: Box<Account<'info, RouterConfig>>,

    #[account(
        mut,
        seeds = [RevenueValidator::SEED, merchant.as_ref()],
        bump = validator.bump,
    )]
    pub validator: Box<Account<'info, RevenueValidator>>,

    #[account(
        mut,
        seeds = [PaymentHistory::SEED, merchant.as_ref()],
        bump = history.bump,
    )]
    pub history: Box<Account<'info, PaymentHistory>>,

    #[account(
        mut,
        seeds = [GlobalBlocklist::SEED],
        bump = blocklist.bump,
    )]
    pub blocklist: Box<Account<'info, GlobalBlocklist>>,

    pub oracle: Signer<'info>,
}

#[derive(Accounts)]
#[instruction(merchant: Pubkey)]
pub struct RetroactiveReject<'info> {
    #[account(
        seeds = [RouterConfig::SEED],
        bump = config.bump,
        has_one = oracle @ RouterError::NotOracle,
    )]
    pub config: Box<Account<'info, RouterConfig>>,

    #[account(
        mut,
        seeds = [RevenueValidator::SEED, merchant.as_ref()],
        bump = validator.bump,
    )]
    pub validator: Box<Account<'info, RevenueValidator>>,

    #[account(
        mut,
        seeds = [PaymentHistory::SEED, merchant.as_ref()],
        bump = history.bump,
    )]
    pub history: Box<Account<'info, PaymentHistory>>,

    pub oracle: Signer<'info>,
}
