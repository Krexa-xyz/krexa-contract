use anchor_lang::prelude::*;
use anchor_spl::token::{self, Mint, Token, TokenAccount, Transfer};
use krexa_common::constants::{
    BPS_DENOMINATOR, PROTOCOL_FEE_BPS, LEVEL_1_MAX_CREDIT, LEVEL_2_LEVERAGE_DEN,
    LEVEL_2_LEVERAGE_NUM, LEVEL_2_MAX_CREDIT, LEVEL_3_LEVERAGE_DEN, LEVEL_3_LEVERAGE_NUM,
    LEVEL_3_MAX_CREDIT, LEVEL_4_MAX_CREDIT, SECONDS_PER_YEAR,
    INSURANCE_TARGET_BPS, INSURANCE_SURPLUS_BPS, TREASURY_SURPLUS_BPS,
    INSURANCE_POST_TARGET_BPS, TREASURY_POST_TARGET_BPS,
    SENIOR_APR_BPS, MEZZANINE_APR_BPS, JUNIOR_APR_BPS,
};

declare_id!("LgrUXRquid228Azj2HrMNLhXHFw8FDRGVG1SqLbbcMS");

// ─────────────────────────────────────────────────────────────────────────────
// Accounts
// ─────────────────────────────────────────────────────────────────────────────

#[account]
pub struct VaultConfig {
    pub admin: Pubkey,
    pub oracle: Pubkey,
    pub wallet_program: Pubkey,          // authorised to call receive_repayment (wallet program ID)
    pub usdc_mint: Pubkey,
    pub vault_token_account: Pubkey,     // PDA token acct holding LP + collateral USDC
    pub insurance_token_account: Pubkey, // PDA token acct holding insurance fund

    // Pool accounting (aggregate — sum of all tranches)
    pub total_deposits: u64,           // sum of all USDC deposited (excl insurance)
    pub total_shares: u64,             // shares outstanding (aggregate)
    pub total_deployed: u64,           // credit currently live in agent wallets
    pub total_interest_earned: u64,    // cumulative net interest added to pool
    pub total_defaults: u64,           // cumulative bad debt written off
    pub insurance_balance: u64,        // USDC in insurance_token_account

    // Parameters
    pub utilization_cap_bps: u16,      // max pool % lent out (e.g. 8000 = 80%)
    pub base_interest_rate_bps: u16,   // annual rate used when no custom rate given
    pub lockup_seconds: i64,           // LP withdrawal lockup (0 = no lockup)

    pub is_paused: bool,
    pub bump: u8,
    pub vault_token_bump: u8,
    pub insurance_token_bump: u8,
    pub router_program: Pubkey,        // payment-router program ID

    // ── Tranche accounting (canonical: Senior 50%, Mezzanine 30%, Junior 20%) ──
    pub senior_deposits: u64,          // USDC deposited into senior tranche
    pub senior_shares: u64,
    pub mezz_deposits: u64,            // USDC deposited into mezzanine tranche
    pub mezz_shares: u64,
    pub junior_deposits: u64,          // USDC deposited into junior tranche
    pub junior_shares: u64,

    pub treasury_account: Pubkey,      // receives protocol fees + surplus
    pub last_yield_timestamp: i64,     // last time tranche yields were distributed

    // v2: service plan program — authorized to disburse milestone funds
    pub service_plan_program: Pubkey,
}

impl VaultConfig {
    // 8 disc + 7*32 keys + 6*8 pool + 3*2 params + 8 lockup + 1 pause + 3 bumps + 32 router
    // + 6*8 tranche + 32 treasury + 8 yield_ts + 32 service_plan_program
    pub const LEN: usize = 8 + 224 + 48 + 6 + 8 + 1 + 3 + 32 + 48 + 32 + 8 + 32;
    pub const SEED: &'static [u8] = b"vault_config";
    pub const VAULT_TOKEN_SEED: &'static [u8] = b"vault_usdc";
    pub const INSURANCE_TOKEN_SEED: &'static [u8] = b"insurance_usdc";

    /// Undeployed USDC sitting in vault_token_account, available to lend.
    pub fn available_liquidity(&self) -> u64 {
        self.total_deposits.saturating_sub(self.total_deployed)
    }

    /// Utilisation as bps (0–10000).
    pub fn utilization_bps(&self) -> u64 {
        if self.total_deposits == 0 {
            return 0;
        }
        (self.total_deployed as u128 * 10_000 / self.total_deposits as u128) as u64
    }

    /// Whether the insurance fund has reached target (20% of deployed capital).
    pub fn insurance_at_target(&self) -> bool {
        if self.total_deployed == 0 {
            return true;
        }
        let target = (self.total_deployed as u128
            * INSURANCE_TARGET_BPS as u128
            / BPS_DENOMINATOR as u128) as u64;
        self.insurance_balance >= target
    }

    /// Compute yield owed to a tranche for `days` elapsed.
    /// yield_owed = tranche_deposits × tranche_apr / 365 × days
    pub fn tranche_yield_owed(deposits: u64, apr_bps: u16, seconds_elapsed: i64) -> u64 {
        if deposits == 0 || seconds_elapsed <= 0 {
            return 0;
        }
        (deposits as u128
            * apr_bps as u128
            * seconds_elapsed as u128
            / (BPS_DENOMINATOR as u128 * SECONDS_PER_YEAR as u128)) as u64
    }
}

#[account]
pub struct DepositPosition {
    pub depositor: Pubkey,         // LP wallet or agent owner wallet
    pub shares: u64,
    pub deposited_amount: u64,     // original USDC deposited (not current value)
    pub deposit_timestamp: i64,
    pub is_collateral: bool,
    pub agent_pubkey: Pubkey,      // which agent (Pubkey::default() for pure LPs)
    pub tranche: u8,               // 0=Senior, 1=Mezzanine, 2=Junior (for LP deposits)
    pub bump: u8,
}

impl DepositPosition {
    // 8 + 32 + 8 + 8 + 8 + 1 + 32 + 1 + 1 + 15 pad
    pub const LEN: usize = 8 + 32 + 8 + 8 + 8 + 1 + 32 + 1 + 1 + 15;
    pub const DEPOSIT_SEED: &'static [u8] = b"deposit";
    pub const COLLATERAL_SEED: &'static [u8] = b"collateral";
}

#[account]
pub struct CreditLine {
    pub agent: Pubkey,
    pub agent_wallet_pda: Pubkey,
    pub credit_limit: u64,
    pub credit_drawn: u64,
    pub interest_rate_bps: u16,
    pub accrued_interest: u64,
    pub total_interest_paid: u64,
    pub last_accrual_timestamp: i64,
    pub originated_at: i64,
    pub is_active: bool,
    pub bump: u8,
    /// Admin-controlled per-credit-line freeze. When true, `extend_credit`
    /// rejects new draws for this agent. Repayments, accrual, and Router
    /// auto-repay continue to work so existing debt can still be paid down.
    /// Consumes 1 byte from the struct's reserved padding — existing accounts
    /// zero-deserialize to `false`, so no migration is required.
    pub is_frozen: bool,
}

impl CreditLine {
    // 8 + 32 + 32 + 8 + 8 + 2 + 8 + 8 + 8 + 8 + 1 + 1 + 1 + 15 pad
    // is_frozen consumes 1 byte from the original 16-byte pad (now 15).
    pub const LEN: usize = 8 + 32 + 32 + 8 + 8 + 2 + 8 + 8 + 8 + 8 + 1 + 1 + 16;
    pub const SEED: &'static [u8] = b"credit_line";

    /// Simple-interest accrual for `elapsed` seconds.
    pub fn accrue(&mut self, elapsed: i64) {
        if elapsed <= 0 || self.credit_drawn == 0 {
            return;
        }
        let new_interest = (self.credit_drawn as u128
            * self.interest_rate_bps as u128
            * elapsed as u128)
            / (BPS_DENOMINATOR as u128 * SECONDS_PER_YEAR as u128);
        self.accrued_interest = self.accrued_interest.saturating_add(new_interest as u64);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Pure helpers
// ─────────────────────────────────────────────────────────────────────────────

/// SOL-004 fix: Prevent share inflation attack by requiring shares > 0
/// and enforcing minimum initial deposit of 1000 units (0.001 USDC).
const MINIMUM_INITIAL_DEPOSIT: u64 = 1_000; // 0.001 USDC (6 decimals)

fn calculate_shares(amount: u64, total_shares: u64, total_deposits: u64) -> Result<u64> {
    if total_shares == 0 || total_deposits == 0 {
        // First deposit: enforce minimum to prevent share manipulation
        require!(amount >= MINIMUM_INITIAL_DEPOSIT, VaultError::ZeroAmount);
        return Ok(amount); // 1:1 initial rate
    }
    let shares = (amount as u128 * total_shares as u128 / total_deposits as u128) as u64;
    // SOL-004: Never mint zero shares — prevents silent fund absorption
    require!(shares > 0, VaultError::ZeroAmount);
    Ok(shares)
}

fn shares_to_amount(shares: u64, total_shares: u64, total_deposits: u64) -> u64 {
    if total_shares == 0 {
        return 0;
    }
    (shares as u128 * total_deposits as u128 / total_shares as u128) as u64
}

fn credit_limit_for_level(level: u8, collateral_value: u64) -> u64 {
    match level {
        0 => 0,
        1 => LEVEL_1_MAX_CREDIT,
        2 => {
            let coll_credit = collateral_value * LEVEL_2_LEVERAGE_NUM / LEVEL_2_LEVERAGE_DEN;
            coll_credit.min(LEVEL_2_MAX_CREDIT)
        }
        3 => {
            let coll_credit = collateral_value * LEVEL_3_LEVERAGE_NUM / LEVEL_3_LEVERAGE_DEN;
            coll_credit.min(LEVEL_3_MAX_CREDIT)
        }
        4 => LEVEL_4_MAX_CREDIT,
        _ => 0,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Events
// ─────────────────────────────────────────────────────────────────────────────

#[event]
pub struct LiquidityDeposited {
    pub depositor: Pubkey,
    pub amount: u64,
    pub shares: u64,
    pub new_total_deposits: u64,
}

#[event]
pub struct CollateralDeposited {
    pub agent: Pubkey,
    pub owner: Pubkey,
    pub amount: u64,
    pub shares: u64,
}

#[event]
pub struct LiquidityWithdrawn {
    pub depositor: Pubkey,
    pub shares: u64,
    pub amount: u64,
}

#[event]
pub struct CollateralWithdrawn {
    pub agent: Pubkey,
    pub shares: u64,
    pub amount: u64,
}

#[event]
pub struct CreditExtended {
    pub agent: Pubkey,
    pub amount: u64,
    pub interest_rate_bps: u16,
    pub credit_limit: u64,
}

#[event]
pub struct RepaymentReceived {
    pub agent: Pubkey,
    pub total_amount: u64,
    pub principal_portion: u64,
    pub interest_portion: u64,
    pub insurance_cut: u64,
    pub credit_cleared: bool,
}

#[event]
pub struct InterestAccrued {
    pub agent: Pubkey,
    pub new_interest: u64,
    pub total_accrued: u64,
}

#[event]
pub struct BadDebtWrittenOff {
    pub agent: Pubkey,
    pub loss: u64,
    pub insurance_covered: u64,
    pub lp_absorbed: u64,
}

// ─────────────────────────────────────────────────────────────────────────────
// Errors
// ─────────────────────────────────────────────────────────────────────────────

#[error_code]
pub enum VaultError {
    #[msg("Not admin")]
    NotAdmin,
    #[msg("Not oracle")]
    NotOracle,
    #[msg("Not wallet program")]
    NotWalletProgram,
    #[msg("Vault is paused")]
    Paused,
    #[msg("Insufficient liquidity in vault")]
    InsufficientLiquidity,
    #[msg("Utilization cap would be exceeded")]
    UtilizationCap,
    #[msg("Agent has no eligible credit level")]
    NoCreditLevel,
    #[msg("Amount exceeds credit limit for this level")]
    ExceedsCreditLimit,
    #[msg("Agent already has an active credit line")]
    CreditLineAlreadyActive,
    #[msg("No active credit line for this agent")]
    NoCreditLine,
    #[msg("Repay amount exceeds total debt")]
    RepayExceedsDebt,
    #[msg("Lockup period has not elapsed")]
    LockupNotElapsed,
    #[msg("Cannot withdraw collateral while credit line is active")]
    CreditLineActive,
    #[msg("Only LP deposits may use withdraw_liquidity")]
    NotLpDeposit,
    #[msg("Only collateral deposits may use withdraw_collateral")]
    NotCollateral,
    #[msg("Insufficient shares")]
    InsufficientShares,
    #[msg("Amount must be > 0")]
    ZeroAmount,
    #[msg("Arithmetic overflow")]
    Overflow,
    #[msg("Address cannot be the zero/default pubkey")]
    InvalidAddress,
    #[msg("Parameter out of valid range")]
    InvalidParam,
    #[msg("Invalid tranche")]
    InvalidTranche,
    #[msg("Credit line is frozen by admin")]
    CreditLineFrozen,
}

// ─────────────────────────────────────────────────────────────────────────────
// Program
// ─────────────────────────────────────────────────────────────────────────────

#[program]
pub mod krexa_credit_vault {
    use super::*;

    // ── 1a. initialize_vault ───────────────────────────────────────────────
    // Creates only the VaultConfig PDA (no token accounts — avoids stack overflow).
    // Call create_vault_pools next to create the vault_usdc / insurance_usdc ATAs.

    pub fn initialize_vault(
        ctx: Context<InitializeVault>,
        oracle: Pubkey,
        wallet_program: Pubkey,
        utilization_cap_bps: u16,
        base_interest_rate_bps: u16,
        lockup_seconds: i64,
        treasury_account: Pubkey,
    ) -> Result<()> {
        let cfg = &mut ctx.accounts.config;
        cfg.admin = ctx.accounts.admin.key();
        cfg.oracle = oracle;
        cfg.wallet_program = wallet_program;
        cfg.usdc_mint = ctx.accounts.usdc_mint.key();
        cfg.vault_token_account = Pubkey::default();
        cfg.insurance_token_account = Pubkey::default();
        cfg.total_deposits = 0;
        cfg.total_shares = 0;
        cfg.total_deployed = 0;
        cfg.total_interest_earned = 0;
        cfg.total_defaults = 0;
        cfg.insurance_balance = 0;
        cfg.utilization_cap_bps = utilization_cap_bps;
        cfg.base_interest_rate_bps = base_interest_rate_bps;
        cfg.lockup_seconds = lockup_seconds;
        cfg.is_paused = false;
        cfg.bump = ctx.bumps.config;
        cfg.vault_token_bump = 0;
        cfg.insurance_token_bump = 0;
        cfg.router_program = Pubkey::default();
        // Tranche accounting
        cfg.senior_deposits = 0;
        cfg.senior_shares = 0;
        cfg.mezz_deposits = 0;
        cfg.mezz_shares = 0;
        cfg.junior_deposits = 0;
        cfg.junior_shares = 0;
        cfg.treasury_account = treasury_account;
        cfg.last_yield_timestamp = Clock::get()?.unix_timestamp;
        cfg.service_plan_program = Pubkey::default();
        Ok(())
    }

    // ── 1b. create_vault_token ─────────────────────────────────────────────
    // Creates the vault_usdc PDA token account. Call after initialize_vault.

    pub fn create_vault_token(ctx: Context<CreateVaultToken>) -> Result<()> {
        let cfg = &mut ctx.accounts.config;
        cfg.vault_token_account = ctx.accounts.vault_token.key();
        cfg.vault_token_bump = ctx.bumps.vault_token;
        Ok(())
    }

    // ── 1c. create_insurance_token ─────────────────────────────────────────
    // Creates the insurance_usdc PDA token account. Call after create_vault_token.

    pub fn create_insurance_token(ctx: Context<CreateInsuranceToken>) -> Result<()> {
        let cfg = &mut ctx.accounts.config;
        cfg.insurance_token_account = ctx.accounts.insurance_token.key();
        cfg.insurance_token_bump = ctx.bumps.insurance_token;
        Ok(())
    }

    // ── 2. deposit_liquidity ───────────────────────────────────────────────

    pub fn deposit_liquidity(ctx: Context<DepositLiquidity>, amount: u64, tranche: u8) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, VaultError::Paused);
        require!(amount > 0, VaultError::ZeroAmount);
        require!(tranche <= 2, VaultError::InvalidTranche);

        let cfg = &ctx.accounts.config;
        let shares = calculate_shares(amount, cfg.total_shares, cfg.total_deposits)?;

        // Transfer USDC from LP → vault
        token::transfer(
            CpiContext::new(
                ctx.accounts.token_program.to_account_info(),
                Transfer {
                    from: ctx.accounts.depositor_usdc.to_account_info(),
                    to: ctx.accounts.vault_token.to_account_info(),
                    authority: ctx.accounts.depositor.to_account_info(),
                },
            ),
            amount,
        )?;

        let pos = &mut ctx.accounts.deposit_position;
        let now = Clock::get()?.unix_timestamp;
        if pos.depositor == Pubkey::default() {
            pos.depositor = ctx.accounts.depositor.key();
            pos.deposited_amount = 0;
            pos.is_collateral = false;
            pos.agent_pubkey = Pubkey::default();
            pos.tranche = tranche;
            pos.bump = ctx.bumps.deposit_position;
        }
        pos.deposit_timestamp = now;
        pos.shares = pos.shares.saturating_add(shares);
        pos.deposited_amount = pos.deposited_amount.saturating_add(amount);

        let cfg = &mut ctx.accounts.config;
        cfg.total_deposits = cfg.total_deposits.saturating_add(amount);
        cfg.total_shares = cfg.total_shares.saturating_add(shares);

        // Update per-tranche accounting
        match tranche {
            0 => {
                cfg.senior_deposits = cfg.senior_deposits.saturating_add(amount);
                cfg.senior_shares = cfg.senior_shares.saturating_add(shares);
            }
            1 => {
                cfg.mezz_deposits = cfg.mezz_deposits.saturating_add(amount);
                cfg.mezz_shares = cfg.mezz_shares.saturating_add(shares);
            }
            2 => {
                cfg.junior_deposits = cfg.junior_deposits.saturating_add(amount);
                cfg.junior_shares = cfg.junior_shares.saturating_add(shares);
            }
            _ => unreachable!(),
        }

        emit!(LiquidityDeposited {
            depositor: ctx.accounts.depositor.key(),
            amount,
            shares,
            new_total_deposits: cfg.total_deposits,
        });
        Ok(())
    }

    // ── 3. deposit_collateral ──────────────────────────────────────────────
    // Same pool, same share math — the agent earns yield on their collateral.

    pub fn deposit_collateral(
        ctx: Context<DepositCollateral>,
        agent: Pubkey,
        amount: u64,
    ) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, VaultError::Paused);
        require!(amount > 0, VaultError::ZeroAmount);

        let cfg = &ctx.accounts.config;
        let shares = calculate_shares(amount, cfg.total_shares, cfg.total_deposits)?;

        token::transfer(
            CpiContext::new(
                ctx.accounts.token_program.to_account_info(),
                Transfer {
                    from: ctx.accounts.owner_usdc.to_account_info(),
                    to: ctx.accounts.vault_token.to_account_info(),
                    authority: ctx.accounts.owner.to_account_info(),
                },
            ),
            amount,
        )?;

        let pos = &mut ctx.accounts.collateral_position;
        let now = Clock::get()?.unix_timestamp;
        if pos.depositor == Pubkey::default() {
            pos.depositor = ctx.accounts.owner.key();
            pos.deposited_amount = 0;
            pos.deposit_timestamp = now;
            pos.is_collateral = true;
            pos.agent_pubkey = agent;
            pos.tranche = 0; // Collateral goes into Senior tranche (earns Senior APR × utilization)
            pos.bump = ctx.bumps.collateral_position;
        }
        pos.shares = pos.shares.saturating_add(shares);
        pos.deposited_amount = pos.deposited_amount.saturating_add(amount);

        let cfg = &mut ctx.accounts.config;
        cfg.total_deposits = cfg.total_deposits.saturating_add(amount);
        cfg.total_shares = cfg.total_shares.saturating_add(shares);
        // Collateral counts toward Senior tranche
        cfg.senior_deposits = cfg.senior_deposits.saturating_add(amount);
        cfg.senior_shares = cfg.senior_shares.saturating_add(shares);

        emit!(CollateralDeposited {
            agent,
            owner: ctx.accounts.owner.key(),
            amount,
            shares,
        });
        Ok(())
    }

    // ── 4. withdraw_liquidity ──────────────────────────────────────────────

    pub fn withdraw_liquidity(ctx: Context<WithdrawLiquidity>, shares: u64) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, VaultError::Paused);
        require!(shares > 0, VaultError::ZeroAmount);

        let pos = &ctx.accounts.deposit_position;
        require!(!pos.is_collateral, VaultError::NotLpDeposit);
        require!(pos.shares >= shares, VaultError::InsufficientShares);

        // Lockup check
        let now = Clock::get()?.unix_timestamp;
        let lockup = ctx.accounts.config.lockup_seconds;
        require!(
            now >= pos.deposit_timestamp + lockup,
            VaultError::LockupNotElapsed
        );

        let cfg = &ctx.accounts.config;
        let amount = shares_to_amount(shares, cfg.total_shares, cfg.total_deposits);
        require!(amount <= cfg.available_liquidity(), VaultError::InsufficientLiquidity);

        // Transfer USDC from vault → LP (vault config PDA signs)
        let seeds: &[&[&[u8]]] = &[&[VaultConfig::SEED, &[cfg.bump]]];
        token::transfer(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                Transfer {
                    from: ctx.accounts.vault_token.to_account_info(),
                    to: ctx.accounts.depositor_usdc.to_account_info(),
                    authority: ctx.accounts.config.to_account_info(),
                },
                seeds,
            ),
            amount,
        )?;

        let tranche = ctx.accounts.deposit_position.tranche;
        let pos = &mut ctx.accounts.deposit_position;
        pos.shares = pos.shares.saturating_sub(shares);
        pos.deposited_amount = pos.deposited_amount.saturating_sub(amount);

        let cfg = &mut ctx.accounts.config;
        cfg.total_deposits = cfg.total_deposits.saturating_sub(amount);
        cfg.total_shares = cfg.total_shares.saturating_sub(shares);

        // Update per-tranche accounting
        match tranche {
            0 => {
                cfg.senior_deposits = cfg.senior_deposits.saturating_sub(amount);
                cfg.senior_shares = cfg.senior_shares.saturating_sub(shares);
            }
            1 => {
                cfg.mezz_deposits = cfg.mezz_deposits.saturating_sub(amount);
                cfg.mezz_shares = cfg.mezz_shares.saturating_sub(shares);
            }
            2 => {
                cfg.junior_deposits = cfg.junior_deposits.saturating_sub(amount);
                cfg.junior_shares = cfg.junior_shares.saturating_sub(shares);
            }
            _ => {}
        }

        emit!(LiquidityWithdrawn {
            depositor: ctx.accounts.depositor.key(),
            shares,
            amount,
        });
        Ok(())
    }

    // ── 5. withdraw_collateral ─────────────────────────────────────────────

    pub fn withdraw_collateral(
        ctx: Context<WithdrawCollateral>,
        _agent: Pubkey,
        shares: u64,
    ) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, VaultError::Paused);
        require!(shares > 0, VaultError::ZeroAmount);

        let pos = &ctx.accounts.collateral_position;
        require!(pos.is_collateral, VaultError::NotCollateral);
        require!(pos.shares >= shares, VaultError::InsufficientShares);

        // Block withdrawal if agent has an active credit line.
        // is_active offset: 8 disc + 32 agent + 32 wallet_pda + 8+8+2+8+8+8+8 fields = 122.
        {
            let data = ctx.accounts.credit_line.try_borrow_data()?;
            if data.len() >= 123 && data[122] != 0 {
                return err!(VaultError::CreditLineActive);
            }
        }

        let cfg = &ctx.accounts.config;
        let amount = shares_to_amount(shares, cfg.total_shares, cfg.total_deposits);
        require!(amount <= cfg.available_liquidity(), VaultError::InsufficientLiquidity);

        let seeds: &[&[&[u8]]] = &[&[VaultConfig::SEED, &[cfg.bump]]];
        token::transfer(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                Transfer {
                    from: ctx.accounts.vault_token.to_account_info(),
                    to: ctx.accounts.owner_usdc.to_account_info(),
                    authority: ctx.accounts.config.to_account_info(),
                },
                seeds,
            ),
            amount,
        )?;

        let pos = &mut ctx.accounts.collateral_position;
        pos.shares = pos.shares.saturating_sub(shares);
        pos.deposited_amount = pos.deposited_amount.saturating_sub(amount);

        let cfg = &mut ctx.accounts.config;
        cfg.total_deposits = cfg.total_deposits.saturating_sub(amount);
        cfg.total_shares = cfg.total_shares.saturating_sub(shares);
        // Collateral is in Senior tranche
        cfg.senior_deposits = cfg.senior_deposits.saturating_sub(amount);
        cfg.senior_shares = cfg.senior_shares.saturating_sub(shares);

        emit!(CollateralWithdrawn {
            agent: ctx.accounts.collateral_position.agent_pubkey,
            shares,
            amount,
        });
        Ok(())
    }

    // ── 6. extend_credit ──────────────────────────────────────────────────

    pub fn extend_credit(
        ctx: Context<ExtendCredit>,
        agent: Pubkey,
        amount: u64,
        rate_bps: u16,
        credit_level: u8,
        collateral_value: u64, // oracle computes: collateral_shares * total_deposits / total_shares
    ) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, VaultError::Paused);
        require!(amount > 0, VaultError::ZeroAmount);
        require!(credit_level >= 1, VaultError::NoCreditLevel);

        // SOL-014 fix: Prevent overwriting an active credit line — must be inactive or fresh
        let existing = &ctx.accounts.credit_line;
        require!(
            !existing.is_active || existing.agent == Pubkey::default(),
            VaultError::CreditLineAlreadyActive
        );

        // Per-credit-line freeze — admin can disable new draws for a specific
        // agent without pausing the whole vault. Repayments continue to work.
        // Applies when a prior credit line exists (freshly-initialized account
        // has is_frozen=false so this is a no-op for first-time borrowers).
        require!(!existing.is_frozen, VaultError::CreditLineFrozen);

        // Level-based cap
        let cap = credit_limit_for_level(credit_level, collateral_value);
        require!(amount <= cap, VaultError::ExceedsCreditLimit);

        // Liquidity & utilization
        let cfg = &ctx.accounts.config;
        require!(amount <= cfg.available_liquidity(), VaultError::InsufficientLiquidity);
        // SOL-028 fix: Guard against division by zero when pool has no deposits
        require!(cfg.total_deposits > 0, VaultError::InsufficientLiquidity);
        let new_deployed = cfg.total_deployed.saturating_add(amount);
        let new_util = (new_deployed as u128 * 10_000 / cfg.total_deposits as u128) as u64;
        require!(
            new_util <= cfg.utilization_cap_bps as u64,
            VaultError::UtilizationCap
        );

        // Transfer USDC vault → agent wallet
        let now = Clock::get()?.unix_timestamp;
        let seeds: &[&[&[u8]]] = &[&[VaultConfig::SEED, &[cfg.bump]]];
        token::transfer(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                Transfer {
                    from: ctx.accounts.vault_token.to_account_info(),
                    to: ctx.accounts.agent_wallet_usdc.to_account_info(),
                    authority: ctx.accounts.config.to_account_info(),
                },
                seeds,
            ),
            amount,
        )?;

        // Create credit line
        let cl = &mut ctx.accounts.credit_line;
        cl.agent = agent;
        cl.agent_wallet_pda = ctx.accounts.agent_wallet_usdc.owner;
        cl.credit_limit = cap;
        cl.credit_drawn = amount;
        cl.interest_rate_bps = rate_bps;
        cl.accrued_interest = 0;
        cl.total_interest_paid = 0;
        cl.last_accrual_timestamp = now;
        cl.originated_at = now;
        cl.is_active = true;
        cl.bump = ctx.bumps.credit_line;
        // Preserve frozen flag across re-opens: if an admin froze this agent's
        // credit line earlier and it was subsequently fully repaid (is_active=false),
        // the freeze should persist so they can't just re-open by repaying.
        // The require! above already enforces this — we just don't overwrite.

        let cfg = &mut ctx.accounts.config;
        cfg.total_deployed = cfg.total_deployed.saturating_add(amount);

        emit!(CreditExtended {
            agent,
            amount,
            interest_rate_bps: rate_bps,
            credit_limit: cap,
        });
        Ok(())
    }

    // ── 7. receive_repayment ───────────────────────────────────────────────
    // The krexa-agent-wallet program has already transferred USDC to vault_token.
    // This instruction: accrues interest, splits insurance, updates accounting.

    /// Canonical repayment waterfall:
    ///   1. Accrue all outstanding interest to current second
    ///   2. Protocol fee (10%) → treasury (via insurance_token for now)
    ///   3. Interest waterfall: Senior yield owed → Mezz owed → Junior owed → Surplus
    ///   4. Surplus → 40% insurance / 60% treasury (pre-target), 10%/90% (post-target)
    ///   5. Principal → reduces total_deployed (available for new lending)
    pub fn receive_repayment(
        ctx: Context<ReceiveRepayment>,
        agent: Pubkey,
        amount: u64,
    ) -> Result<()> {
        require!(amount > 0, VaultError::ZeroAmount);

        // Step 1: Accrue interest up to now
        let now = Clock::get()?.unix_timestamp;
        let cl = &mut ctx.accounts.credit_line;
        require!(cl.is_active, VaultError::NoCreditLine);

        let elapsed = now.saturating_sub(cl.last_accrual_timestamp);
        cl.accrue(elapsed);
        cl.last_accrual_timestamp = now;

        let total_debt = cl.credit_drawn.saturating_add(cl.accrued_interest);
        require!(amount <= total_debt, VaultError::RepayExceedsDebt);

        // Split payment: interest first, then principal
        let interest_portion = amount.min(cl.accrued_interest);
        let principal_portion = amount.saturating_sub(interest_portion);

        // Step 2: Protocol fee (10%) from interest portion
        let protocol_fee = (interest_portion as u128
            * PROTOCOL_FEE_BPS as u128
            / BPS_DENOMINATOR as u128) as u64;
        let distributable_interest = interest_portion.saturating_sub(protocol_fee);

        // Step 3: Tranche yield waterfall — each tranche gets what it's OWED at its APR
        let cfg = &ctx.accounts.config;
        let yield_elapsed = now.saturating_sub(cfg.last_yield_timestamp);

        let senior_owed = VaultConfig::tranche_yield_owed(
            cfg.senior_deposits, SENIOR_APR_BPS, yield_elapsed);
        let mezz_owed = VaultConfig::tranche_yield_owed(
            cfg.mezz_deposits, MEZZANINE_APR_BPS, yield_elapsed);
        let junior_owed = VaultConfig::tranche_yield_owed(
            cfg.junior_deposits, JUNIOR_APR_BPS, yield_elapsed);

        // Distribute interest through waterfall (Senior first)
        let senior_paid = distributable_interest.min(senior_owed);
        let after_senior = distributable_interest.saturating_sub(senior_paid);

        let mezz_paid = after_senior.min(mezz_owed);
        let after_mezz = after_senior.saturating_sub(mezz_paid);

        let junior_paid = after_mezz.min(junior_owed);
        let surplus = after_mezz.saturating_sub(junior_paid);

        // Step 4: Surplus split — insurance vs treasury
        let insurance_from_surplus;
        let _treasury_from_surplus;
        if cfg.insurance_at_target() {
            // Post-target: 10% insurance / 90% treasury
            insurance_from_surplus = (surplus as u128
                * INSURANCE_POST_TARGET_BPS as u128
                / BPS_DENOMINATOR as u128) as u64;
            _treasury_from_surplus = surplus.saturating_sub(insurance_from_surplus);
        } else {
            // Pre-target: 40% insurance / 60% treasury
            insurance_from_surplus = (surplus as u128
                * INSURANCE_SURPLUS_BPS as u128
                / BPS_DENOMINATOR as u128) as u64;
            _treasury_from_surplus = surplus.saturating_sub(insurance_from_surplus);
        }

        // Total to move to insurance: protocol_fee + insurance portion of surplus
        let total_insurance = protocol_fee.saturating_add(insurance_from_surplus);

        // ── Effects first (checks-effects-interactions) ──

        // Update credit line
        cl.accrued_interest = cl.accrued_interest.saturating_sub(interest_portion);
        cl.credit_drawn = cl.credit_drawn.saturating_sub(principal_portion);
        cl.total_interest_paid = cl.total_interest_paid.saturating_add(interest_portion);

        let credit_cleared = cl.credit_drawn == 0 && cl.accrued_interest == 0;
        if credit_cleared {
            cl.is_active = false;
        }

        // Update vault accounting
        // Net interest that stays in the pool (tranche yields + treasury surplus)
        let net_pool_interest = interest_portion.saturating_sub(total_insurance);
        let cfg = &mut ctx.accounts.config;
        cfg.total_deposits = cfg.total_deposits.saturating_add(net_pool_interest);
        cfg.total_interest_earned = cfg.total_interest_earned.saturating_add(net_pool_interest);
        cfg.insurance_balance = cfg.insurance_balance.saturating_add(total_insurance);
        cfg.total_deployed = cfg.total_deployed.saturating_sub(principal_portion);

        // Credit tranche deposits with their earned yield
        cfg.senior_deposits = cfg.senior_deposits.saturating_add(senior_paid);
        cfg.mezz_deposits = cfg.mezz_deposits.saturating_add(mezz_paid);
        cfg.junior_deposits = cfg.junior_deposits.saturating_add(junior_paid);

        cfg.last_yield_timestamp = now;

        // ── Interactions (token transfer after state updates) ──

        // Move total_insurance from vault_token → insurance_token
        if total_insurance > 0 {
            let bump = ctx.accounts.config.bump;
            let seeds: &[&[&[u8]]] = &[&[VaultConfig::SEED, &[bump]]];
            token::transfer(
                CpiContext::new_with_signer(
                    ctx.accounts.token_program.to_account_info(),
                    Transfer {
                        from: ctx.accounts.vault_token.to_account_info(),
                        to: ctx.accounts.insurance_token.to_account_info(),
                        authority: ctx.accounts.config.to_account_info(),
                    },
                    seeds,
                ),
                total_insurance,
            )?;
        }

        emit!(RepaymentReceived {
            agent,
            total_amount: amount,
            principal_portion,
            interest_portion,
            insurance_cut: total_insurance,
            credit_cleared,
        });
        Ok(())
    }

    // ── 8. accrue_interest ─────────────────────────────────────────────────
    // Permissionless — any keeper can call this.

    pub fn accrue_interest(ctx: Context<AccrueInterest>, _agent: Pubkey) -> Result<()> {
        let now = Clock::get()?.unix_timestamp;
        let cl = &mut ctx.accounts.credit_line;
        require!(cl.is_active, VaultError::NoCreditLine);

        let elapsed = now.saturating_sub(cl.last_accrual_timestamp);
        if elapsed <= 0 {
            return Ok(());
        }

        let prev_accrued = cl.accrued_interest;
        cl.accrue(elapsed);
        cl.last_accrual_timestamp = now;
        let new_interest = cl.accrued_interest.saturating_sub(prev_accrued);

        if new_interest > 0 {
            emit!(InterestAccrued {
                agent: cl.agent,
                new_interest,
                total_accrued: cl.accrued_interest,
            });
        }
        Ok(())
    }

    // ── 9. write_off_bad_debt ──────────────────────────────────────────────

    /// Canonical loss waterfall (opposite of repayment):
    ///   1. Insurance reserve absorbs first
    ///   2. Junior tranche absorbs (if insurance exhausted)
    ///   3. Mezzanine tranche absorbs (if Junior exhausted)
    ///   4. Senior tranche absorbs (LAST RESORT)
    pub fn write_off_bad_debt(ctx: Context<WriteBadDebt>, _agent: Pubkey) -> Result<()> {
        let cl = &mut ctx.accounts.credit_line;
        require!(cl.is_active, VaultError::NoCreditLine);

        // Accrue interest to current second before computing loss
        let now = Clock::get()?.unix_timestamp;
        let elapsed = now.saturating_sub(cl.last_accrual_timestamp);
        cl.accrue(elapsed);
        cl.last_accrual_timestamp = now;

        let principal_loss = cl.credit_drawn;
        let interest_loss = cl.accrued_interest;
        let total_loss = principal_loss.saturating_add(interest_loss);

        cl.is_active = false;
        cl.credit_drawn = 0;
        cl.accrued_interest = 0;

        let cfg = &mut ctx.accounts.config;
        cfg.total_deployed = cfg.total_deployed.saturating_sub(principal_loss);
        cfg.total_defaults = cfg.total_defaults.saturating_add(total_loss);

        // Loss waterfall: Insurance → Junior → Mezzanine → Senior
        let mut remaining_loss = total_loss;

        // 1. Insurance absorbs first
        let insurance_absorbed = remaining_loss.min(cfg.insurance_balance);
        cfg.insurance_balance = cfg.insurance_balance.saturating_sub(insurance_absorbed);
        remaining_loss = remaining_loss.saturating_sub(insurance_absorbed);

        // 2. Junior absorbs next (first LP tranche to lose)
        let junior_absorbed = remaining_loss.min(cfg.junior_deposits);
        cfg.junior_deposits = cfg.junior_deposits.saturating_sub(junior_absorbed);
        cfg.total_deposits = cfg.total_deposits.saturating_sub(junior_absorbed);
        remaining_loss = remaining_loss.saturating_sub(junior_absorbed);

        // 3. Mezzanine absorbs next
        let mezz_absorbed = remaining_loss.min(cfg.mezz_deposits);
        cfg.mezz_deposits = cfg.mezz_deposits.saturating_sub(mezz_absorbed);
        cfg.total_deposits = cfg.total_deposits.saturating_sub(mezz_absorbed);
        remaining_loss = remaining_loss.saturating_sub(mezz_absorbed);

        // 4. Senior absorbs last (LAST RESORT)
        let senior_absorbed = remaining_loss.min(cfg.senior_deposits);
        cfg.senior_deposits = cfg.senior_deposits.saturating_sub(senior_absorbed);
        cfg.total_deposits = cfg.total_deposits.saturating_sub(senior_absorbed);

        let lp_absorbed = junior_absorbed
            .saturating_add(mezz_absorbed)
            .saturating_add(senior_absorbed);

        emit!(BadDebtWrittenOff {
            agent: cl.agent,
            loss: total_loss,
            insurance_covered: insurance_absorbed,
            lp_absorbed,
        });
        Ok(())
    }

    // ── 10. set_paused ────────────────────────────────────────────────────

    pub fn set_paused(ctx: Context<SetPaused>, paused: bool) -> Result<()> {
        ctx.accounts.config.is_paused = paused;
        Ok(())
    }

    // ── 10b. set_credit_line_frozen ───────────────────────────────────────
    //
    // Per-agent kill switch. Flips `is_frozen` on one CreditLine account so
    // `extend_credit` rejects new draws for that agent only. All other agents
    // and all repayment paths continue to work. Admin-only.
    pub fn set_credit_line_frozen(
        ctx: Context<SetCreditLineFrozen>,
        _agent: Pubkey,
        frozen: bool,
    ) -> Result<()> {
        ctx.accounts.credit_line.is_frozen = frozen;
        Ok(())
    }

    // ── 11. update_config ───────────────────────────────────────────────
    // SOL-017 equivalent: Admin can rotate oracle, wallet_program, and utilization params.

    pub fn update_config(
        ctx: Context<UpdateVaultConfig>,
        new_admin: Option<Pubkey>,
        new_oracle: Option<Pubkey>,
        new_wallet_program: Option<Pubkey>,
        new_router_program: Option<Pubkey>,
        new_utilization_cap_bps: Option<u16>,
        new_base_interest_rate_bps: Option<u16>,
        new_lockup_seconds: Option<i64>,
        new_service_plan_program: Option<Pubkey>,
    ) -> Result<()> {
        let cfg = &mut ctx.accounts.config;
        // SOL-075 fix: prevent permanent lockout via zero-address
        if let Some(admin) = new_admin {
            require!(admin != Pubkey::default(), VaultError::InvalidAddress);
            cfg.admin = admin;
        }
        if let Some(oracle) = new_oracle {
            require!(oracle != Pubkey::default(), VaultError::InvalidAddress);
            cfg.oracle = oracle;
        }
        if let Some(wp) = new_wallet_program {
            cfg.wallet_program = wp;
        }
        if let Some(rp) = new_router_program {
            cfg.router_program = rp;
        }
        // SOL-079 fix: validate parameter bounds
        if let Some(cap) = new_utilization_cap_bps {
            require!(cap <= 10_000, VaultError::InvalidParam);
            cfg.utilization_cap_bps = cap;
        }
        if let Some(rate) = new_base_interest_rate_bps {
            require!(rate <= 5_000, VaultError::InvalidParam);
            cfg.base_interest_rate_bps = rate;
        }
        if let Some(lockup) = new_lockup_seconds {
            cfg.lockup_seconds = lockup;
        }
        if let Some(sp) = new_service_plan_program {
            cfg.service_plan_program = sp;
        }
        Ok(())
    }

    // ── 12. migrate_config_v2 ─────────────────────────────────────────────
    // Resize stale VaultConfig PDA from an older, smaller layout to the
    // current VaultConfig::LEN.  New bytes are zero-filled, which is safe
    // because all appended fields are u64 / Pubkey / i64 (default = 0).
    //
    // Only the admin can call this (validated via first 40 bytes of data).

    pub fn migrate_config_v2(ctx: Context<MigrateConfigV2>) -> Result<()> {
        let info = ctx.accounts.config.to_account_info();
        let current_len = info.data_len();
        let target_len = VaultConfig::LEN;
        if current_len >= target_len {
            msg!("Config already at target size ({} >= {})", current_len, target_len);
            return Ok(());
        }

        // Verify caller is the admin stored in the account (offset 8, 32 bytes)
        {
            let data = info.try_borrow_data()?;
            let stored_admin = Pubkey::try_from(&data[8..40])
                .map_err(|_| error!(VaultError::NotAdmin))?;
            require!(
                stored_admin == ctx.accounts.admin.key(),
                VaultError::NotAdmin
            );
        }

        // Resize — transfer extra rent from admin
        let rent = anchor_lang::prelude::Rent::get()?;
        let new_min = rent.minimum_balance(target_len);
        let current_lamports = info.lamports();
        if new_min > current_lamports {
            let diff = new_min - current_lamports;
            anchor_lang::system_program::transfer(
                CpiContext::new(
                    ctx.accounts.system_program.to_account_info(),
                    anchor_lang::system_program::Transfer {
                        from: ctx.accounts.admin.to_account_info(),
                        to: info.clone(),
                    },
                ),
                diff,
            )?;
        }

        info.realloc(target_len, false)?;

        // Zero-fill only the newly appended bytes
        {
            let mut data = info.try_borrow_mut_data()?;
            for byte in data[current_len..target_len].iter_mut() {
                *byte = 0;
            }
        }
        msg!("Migrated vault config: {} → {} bytes", current_len, target_len);
        Ok(())
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Contexts
// ─────────────────────────────────────────────────────────────────────────────

// InitializeVault: creates only the VaultConfig PDA (small, no token CPI overhead).
#[derive(Accounts)]
pub struct InitializeVault<'info> {
    #[account(
        init,
        payer = admin,
        space = VaultConfig::LEN,
        seeds = [VaultConfig::SEED],
        bump,
    )]
    pub config: Box<Account<'info, VaultConfig>>,

    /// SOL-031 fix: Validate usdc_mint is a real SPL Mint at initialization time.
    /// Previously UncheckedAccount — attacker could pass any account as the mint.
    pub usdc_mint: Account<'info, Mint>,

    #[account(mut)]
    pub admin: Signer<'info>,

    pub system_program: Program<'info, System>,
}

// CreateVaultToken: creates only the vault_usdc PDA token account.
#[derive(Accounts)]
pub struct CreateVaultToken<'info> {
    #[account(
        mut,
        seeds = [VaultConfig::SEED],
        bump = config.bump,
        has_one = admin @ VaultError::NotAdmin,
        has_one = usdc_mint @ VaultError::NotAdmin,
    )]
    pub config: Box<Account<'info, VaultConfig>>,

    pub usdc_mint: Box<Account<'info, Mint>>,

    #[account(
        init,
        payer = admin,
        token::mint = usdc_mint,
        token::authority = config,
        seeds = [VaultConfig::VAULT_TOKEN_SEED],
        bump,
    )]
    pub vault_token: Box<Account<'info, TokenAccount>>,

    #[account(mut)]
    pub admin: Signer<'info>,

    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
    pub rent: Sysvar<'info, Rent>,
}

// CreateInsuranceToken: creates only the insurance_usdc PDA token account.
#[derive(Accounts)]
pub struct CreateInsuranceToken<'info> {
    #[account(
        mut,
        seeds = [VaultConfig::SEED],
        bump = config.bump,
        has_one = admin @ VaultError::NotAdmin,
        has_one = usdc_mint @ VaultError::NotAdmin,
    )]
    pub config: Box<Account<'info, VaultConfig>>,

    pub usdc_mint: Box<Account<'info, Mint>>,

    #[account(
        init,
        payer = admin,
        token::mint = usdc_mint,
        token::authority = config,
        seeds = [VaultConfig::INSURANCE_TOKEN_SEED],
        bump,
    )]
    pub insurance_token: Box<Account<'info, TokenAccount>>,

    #[account(mut)]
    pub admin: Signer<'info>,

    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
    pub rent: Sysvar<'info, Rent>,
}

#[derive(Accounts)]
pub struct DepositLiquidity<'info> {
    #[account(
        mut,
        seeds = [VaultConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, VaultConfig>,

    #[account(
        mut,
        address = config.vault_token_account,
    )]
    pub vault_token: Account<'info, TokenAccount>,

    #[account(
        init_if_needed,
        payer = depositor,
        space = DepositPosition::LEN,
        seeds = [DepositPosition::DEPOSIT_SEED, depositor.key().as_ref()],
        bump,
    )]
    pub deposit_position: Account<'info, DepositPosition>,

    #[account(
        mut,
        token::mint = config.usdc_mint,
        token::authority = depositor,
    )]
    pub depositor_usdc: Account<'info, TokenAccount>,

    #[account(mut)]
    pub depositor: Signer<'info>,

    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(agent: Pubkey)]
pub struct DepositCollateral<'info> {
    #[account(
        mut,
        seeds = [VaultConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, VaultConfig>,

    #[account(
        mut,
        address = config.vault_token_account,
    )]
    pub vault_token: Account<'info, TokenAccount>,

    #[account(
        init_if_needed,
        payer = owner,
        space = DepositPosition::LEN,
        seeds = [DepositPosition::COLLATERAL_SEED, agent.as_ref()],
        bump,
    )]
    pub collateral_position: Account<'info, DepositPosition>,

    #[account(
        mut,
        token::mint = config.usdc_mint,
        token::authority = owner,
    )]
    pub owner_usdc: Account<'info, TokenAccount>,

    #[account(mut)]
    pub owner: Signer<'info>,

    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct WithdrawLiquidity<'info> {
    #[account(
        mut,
        seeds = [VaultConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, VaultConfig>,

    #[account(
        mut,
        address = config.vault_token_account,
    )]
    pub vault_token: Account<'info, TokenAccount>,

    #[account(
        mut,
        seeds = [DepositPosition::DEPOSIT_SEED, depositor.key().as_ref()],
        bump = deposit_position.bump,
        has_one = depositor,
    )]
    pub deposit_position: Account<'info, DepositPosition>,

    #[account(
        mut,
        token::mint = config.usdc_mint,
        token::authority = depositor,
    )]
    pub depositor_usdc: Account<'info, TokenAccount>,

    pub depositor: Signer<'info>,
    pub token_program: Program<'info, Token>,
}

#[derive(Accounts)]
#[instruction(_agent: Pubkey)]
pub struct WithdrawCollateral<'info> {
    #[account(
        mut,
        seeds = [VaultConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, VaultConfig>,

    #[account(
        mut,
        address = config.vault_token_account,
    )]
    pub vault_token: Account<'info, TokenAccount>,

    #[account(
        mut,
        seeds = [DepositPosition::COLLATERAL_SEED, _agent.as_ref()],
        bump = collateral_position.bump,
        has_one = depositor @ VaultError::NotAdmin,
    )]
    pub collateral_position: Account<'info, DepositPosition>,

    /// SOL-005 fix: credit_line MUST be the correct PDA for this agent.
    /// Previously was UncheckedAccount with no validation — attacker could pass any account.
    /// CHECK: We validate seeds derive correctly. Account may not be initialized (no credit line exists).
    #[account(
        seeds = [CreditLine::SEED, _agent.as_ref()],
        bump,
    )]
    pub credit_line: UncheckedAccount<'info>,

    #[account(
        mut,
        token::mint = config.usdc_mint,
        token::authority = owner,
    )]
    pub owner_usdc: Account<'info, TokenAccount>,

    /// depositor field in DepositPosition stores the owner's pubkey
    #[account(address = collateral_position.depositor)]
    pub depositor: SystemAccount<'info>,

    /// SOL-047 fix: owner must match depositor — only the original depositor can withdraw
    #[account(
        constraint = owner.key() == depositor.key() @ VaultError::NotAdmin
    )]
    pub owner: Signer<'info>,
    pub token_program: Program<'info, Token>,
}

#[derive(Accounts)]
#[instruction(agent: Pubkey)]
pub struct ExtendCredit<'info> {
    #[account(
        mut,
        seeds = [VaultConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, VaultConfig>,

    #[account(
        mut,
        address = config.vault_token_account,
    )]
    pub vault_token: Account<'info, TokenAccount>,

    #[account(
        init_if_needed,
        payer = oracle,
        space = CreditLine::LEN,
        seeds = [CreditLine::SEED, agent.as_ref()],
        bump,
    )]
    pub credit_line: Account<'info, CreditLine>,

    /// Destination: the agent wallet's USDC token account
    #[account(
        mut,
        token::mint = config.usdc_mint,
    )]
    pub agent_wallet_usdc: Account<'info, TokenAccount>,

    #[account(
        mut,
        address = config.oracle @ VaultError::NotOracle,
    )]
    pub oracle: Signer<'info>,

    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(agent: Pubkey)]
pub struct ReceiveRepayment<'info> {
    #[account(
        mut,
        seeds = [VaultConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, VaultConfig>,

    #[account(
        mut,
        address = config.vault_token_account,
    )]
    pub vault_token: Account<'info, TokenAccount>,

    #[account(
        mut,
        address = config.insurance_token_account,
    )]
    pub insurance_token: Account<'info, TokenAccount>,

    #[account(
        mut,
        seeds = [CreditLine::SEED, agent.as_ref()],
        bump = credit_line.bump,
    )]
    pub credit_line: Account<'info, CreditLine>,

    /// Caller program authority — either the wallet config PDA (from krexa-agent-wallet)
    /// or the router config PDA (from krexa-payment-router). Both sign their CPIs via
    /// their respective config PDAs, so we verify the address matches one of them.
    #[account(
        constraint = {
            let (wallet_config_pda, _) = Pubkey::find_program_address(&[b"wallet_config"], &config.wallet_program);
            let (router_config_pda, _) = Pubkey::find_program_address(&[b"router_config"], &config.router_program);
            wallet_program_authority.key() == wallet_config_pda
                || wallet_program_authority.key() == router_config_pda
        } @ VaultError::NotWalletProgram
    )]
    pub wallet_program_authority: Signer<'info>,

    pub token_program: Program<'info, Token>,
}

#[derive(Accounts)]
#[instruction(_agent: Pubkey)]
pub struct AccrueInterest<'info> {
    #[account(
        seeds = [VaultConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, VaultConfig>,

    #[account(
        mut,
        seeds = [CreditLine::SEED, _agent.as_ref()],
        bump = credit_line.bump,
    )]
    pub credit_line: Account<'info, CreditLine>,

    /// Permissionless — any payer can trigger accrual
    pub caller: Signer<'info>,
}

#[derive(Accounts)]
#[instruction(_agent: Pubkey)]
pub struct WriteBadDebt<'info> {
    #[account(
        mut,
        seeds = [VaultConfig::SEED],
        bump = config.bump,
        has_one = admin @ VaultError::NotAdmin,
    )]
    pub config: Account<'info, VaultConfig>,

    #[account(
        mut,
        seeds = [CreditLine::SEED, _agent.as_ref()],
        bump = credit_line.bump,
    )]
    pub credit_line: Account<'info, CreditLine>,

    pub admin: Signer<'info>,
}

#[derive(Accounts)]
pub struct SetPaused<'info> {
    #[account(
        mut,
        seeds = [VaultConfig::SEED],
        bump = config.bump,
        has_one = admin @ VaultError::NotAdmin,
    )]
    pub config: Account<'info, VaultConfig>,

    pub admin: Signer<'info>,
}

/// Per-credit-line freeze. Admin signs; config proves admin authority via
/// has_one; credit_line PDA is the target.
#[derive(Accounts)]
#[instruction(agent: Pubkey)]
pub struct SetCreditLineFrozen<'info> {
    #[account(
        seeds = [VaultConfig::SEED],
        bump = config.bump,
        has_one = admin @ VaultError::NotAdmin,
    )]
    pub config: Account<'info, VaultConfig>,

    #[account(
        mut,
        seeds = [CreditLine::SEED, agent.as_ref()],
        bump = credit_line.bump,
    )]
    pub credit_line: Account<'info, CreditLine>,

    pub admin: Signer<'info>,
}

#[derive(Accounts)]
pub struct UpdateVaultConfig<'info> {
    #[account(
        mut,
        seeds = [VaultConfig::SEED],
        bump = config.bump,
        has_one = admin @ VaultError::NotAdmin,
    )]
    pub config: Account<'info, VaultConfig>,

    pub admin: Signer<'info>,
}

#[derive(Accounts)]
pub struct MigrateConfigV2<'info> {
    /// CHECK: Cannot deserialize old layout — validated manually via stored admin pubkey.
    #[account(
        mut,
        seeds = [VaultConfig::SEED],
        bump,
    )]
    pub config: UncheckedAccount<'info>,

    #[account(mut)]
    pub admin: Signer<'info>,

    pub system_program: Program<'info, System>,
}
