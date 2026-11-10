use anchor_lang::prelude::*;

pub mod errors;
pub mod state;

use errors::*;
use state::*;

declare_id!("2GwtAXnjY5LehfZfT77ZH3XSshwbni8LP9zXeA84WUqh");

#[program]
pub mod krexa_score {
    use super::*;

    /// Initialize the score config singleton
    pub fn initialize(
        ctx: Context<Initialize>,
        oracle: Pubkey,
        registry_program: Pubkey,
        wallet_program: Pubkey,
        vault_program: Pubkey,
    ) -> Result<()> {
        let cfg = &mut ctx.accounts.config;
        cfg.admin = ctx.accounts.admin.key();
        cfg.oracle = oracle;
        cfg.registry_program = registry_program;
        cfg.wallet_program = wallet_program;
        cfg.vault_program = vault_program;
        cfg.is_paused = false;
        cfg.bump = ctx.bumps.config;
        Ok(())
    }

    /// Initialize a Krexit Score for a new agent
    pub fn initialize_score(ctx: Context<InitializeScore>, agent_type: u8) -> Result<()> {
        require!(agent_type <= 2, KrexaScoreError::InvalidAgentType);

        let score = &mut ctx.accounts.krexit_score;
        let clock = Clock::get()?;

        score.agent = ctx.accounts.agent_profile.key();
        score.owner = ctx.accounts.owner.key();
        score.score = 350;
        score.credit_level = 1;
        score.kya_tier = 0;

        score.c1_repayment = 7000;
        score.c2_profitability = 5000;
        score.c3_behavioral = 5000;
        score.c4_usage = 0;
        score.c5_maturity = 0;

        score.on_time_repayments = 0;
        score.late_repayments = 0;
        score.missed_repayments = 0;
        score.liquidations = 0;
        score.defaults = 0;
        score.credit_cycles_completed = 0;

        score.cumulative_borrowed = 0;
        score.cumulative_repaid = 0;
        score.current_debt = 0;
        score.pnl_ratio_bps = 0;
        score.max_drawdown_bps = 0;
        score.sharpe_ratio_bps = 0;

        score.green_time_bps = 0;
        score.yellow_time_bps = 0;
        score.orange_time_bps = 0;
        score.red_time_bps = 0;

        score.venue_entropy_bps = 0;
        score.unique_venues = 0;
        score.total_transactions = 0;
        score.avg_daily_volume = 0;

        score.registered_at = clock.unix_timestamp;
        score.last_score_update = clock.unix_timestamp;
        score.last_critical_event = 0;
        score.last_repayment = 0;

        score.history = [ScoreHistoryEntry::default(); 30];
        score.history_index = 0;

        score.agent_type = agent_type;
        score.revenue_health_bps = 0;
        score.milestone_completion_rate_bps = 0;

        score.is_active = false;
        score.is_blacklisted = false;
        score.bump = ctx.bumps.krexit_score;

        emit!(ScoreInitialized {
            agent: score.agent,
            owner: score.owner,
            starting_score: 350,
        });

        Ok(())
    }

    /// Update score — oracle only
    #[allow(clippy::too_many_arguments)]
    pub fn update_score(
        ctx: Context<UpdateScore>,
        new_score: u16,
        new_level: u8,
        c1: u16,
        c2: u16,
        c3: u16,
        c4: u16,
        c5: u16,
        event_type: u8,
        pnl_ratio_bps: i32,
        max_drawdown_bps: u16,
        sharpe_ratio_bps: i16,
        green_time_bps: u16,
        yellow_time_bps: u16,
        orange_time_bps: u16,
        red_time_bps: u16,
        venue_entropy_bps: u16,
        unique_venues: u8,
        avg_daily_volume: u64,
        revenue_health_bps: u16,
        milestone_completion_rate_bps: u16,
    ) -> Result<()> {
        let config = &ctx.accounts.config;
        require!(!config.is_paused, KrexaScoreError::Paused);
        require!(
            ctx.accounts.oracle.key() == config.oracle,
            KrexaScoreError::NotOracle
        );

        let score_account = &mut ctx.accounts.krexit_score;
        let clock = Clock::get()?;

        // Validate range
        require!(
            new_score >= 200 && new_score <= 850,
            KrexaScoreError::ScoreOutOfRange
        );
        require!(
            new_level >= 1 && new_level <= 4,
            KrexaScoreError::InvalidLevel
        );
        require!(
            c1 <= 10000 && c2 <= 10000 && c3 <= 10000 && c4 <= 10000 && c5 <= 10000,
            KrexaScoreError::ComponentOutOfRange
        );

        // Blacklist check
        require!(
            !score_account.is_blacklisted,
            KrexaScoreError::AgentBlacklisted
        );

        // Delta check
        let is_critical = event_type == score_event_type::LIQUIDATION
            || event_type == score_event_type::DEFAULT
            || event_type == score_event_type::MISSED_REPAYMENT
            || event_type == score_event_type::WINDDOWN;

        let max_delta: u16 = if is_critical { 200 } else { 100 };
        let delta = if new_score > score_account.score {
            new_score - score_account.score
        } else {
            score_account.score - new_score
        };
        require!(delta <= max_delta, KrexaScoreError::ScoreChangeTooLarge);

        // Cooldown check (60 seconds, bypassed for critical events)
        if !is_critical {
            require!(
                clock.unix_timestamp - score_account.last_score_update >= 60,
                KrexaScoreError::UpdateTooFrequent
            );
        }

        // Record history
        let old_score = score_account.score;
        let idx = score_account.history_index as usize % 30;
        score_account.history[idx] = ScoreHistoryEntry {
            timestamp: clock.unix_timestamp,
            old_score,
            new_score,
            event_type,
            delta_bps: new_score as i16 - old_score as i16,
        };
        score_account.history_index = ((idx + 1) % 30) as u8;

        // Apply update
        score_account.score = new_score;
        score_account.credit_level = new_level;
        score_account.c1_repayment = c1;
        score_account.c2_profitability = c2;
        score_account.c3_behavioral = c3;
        score_account.c4_usage = c4;
        score_account.c5_maturity = c5;

        score_account.pnl_ratio_bps = pnl_ratio_bps;
        score_account.max_drawdown_bps = max_drawdown_bps;
        score_account.sharpe_ratio_bps = sharpe_ratio_bps;
        score_account.green_time_bps = green_time_bps;
        score_account.yellow_time_bps = yellow_time_bps;
        score_account.orange_time_bps = orange_time_bps;
        score_account.red_time_bps = red_time_bps;
        score_account.venue_entropy_bps = venue_entropy_bps;
        score_account.unique_venues = unique_venues;
        score_account.avg_daily_volume = avg_daily_volume;
        score_account.revenue_health_bps = revenue_health_bps;
        score_account.milestone_completion_rate_bps = milestone_completion_rate_bps;

        score_account.last_score_update = clock.unix_timestamp;

        if is_critical {
            score_account.last_critical_event = clock.unix_timestamp;
        }

        // Handle special events
        match event_type {
            score_event_type::ON_TIME_REPAYMENT | score_event_type::EARLY_REPAYMENT => {
                score_account.on_time_repayments = score_account
                    .on_time_repayments
                    .checked_add(1)
                    .ok_or(KrexaScoreError::Overflow)?;
                score_account.last_repayment = clock.unix_timestamp;
            }
            score_event_type::LATE_REPAYMENT => {
                score_account.late_repayments = score_account
                    .late_repayments
                    .checked_add(1)
                    .ok_or(KrexaScoreError::Overflow)?;
                score_account.last_repayment = clock.unix_timestamp;
            }
            score_event_type::MISSED_REPAYMENT => {
                score_account.missed_repayments = score_account
                    .missed_repayments
                    .checked_add(1)
                    .ok_or(KrexaScoreError::Overflow)?;
            }
            score_event_type::LIQUIDATION | score_event_type::WINDDOWN => {
                score_account.liquidations = score_account
                    .liquidations
                    .checked_add(1)
                    .ok_or(KrexaScoreError::Overflow)?;
                // Enforce -40 penalty: new_score must be <= old_score - 40
                require!(
                    new_score <= old_score.saturating_sub(40),
                    KrexaScoreError::LiquidationPenaltyNotApplied
                );
            }
            score_event_type::DEFAULT => {
                score_account.defaults = score_account
                    .defaults
                    .checked_add(1)
                    .ok_or(KrexaScoreError::Overflow)?;
                score_account.c1_repayment = 0;
                score_account.is_blacklisted = true;
            }
            score_event_type::CREDIT_CYCLE_COMPLETE => {
                score_account.credit_cycles_completed = score_account
                    .credit_cycles_completed
                    .checked_add(1)
                    .ok_or(KrexaScoreError::Overflow)?;
            }
            _ => {}
        }

        emit!(ScoreUpdatedEvent {
            agent: score_account.agent,
            old_score,
            new_score,
            event_type,
            timestamp: clock.unix_timestamp,
        });

        Ok(())
    }

    /// Record a credit event — updates counters without recomputing score
    pub fn record_credit_event(
        ctx: Context<RecordCreditEvent>,
        event: CreditEventInput,
    ) -> Result<()> {
        let config = &ctx.accounts.config;
        require!(!config.is_paused, KrexaScoreError::Paused);

        // Verify caller is wallet or vault program
        let caller = ctx.accounts.caller_authority.key();
        require!(
            caller == config.wallet_program || caller == config.vault_program,
            KrexaScoreError::NotAuthorizedCaller
        );

        let score = &mut ctx.accounts.krexit_score;
        let clock = Clock::get()?;

        let (label, amount) = match event {
            CreditEventInput::Borrowed { amount } => {
                score.cumulative_borrowed = score
                    .cumulative_borrowed
                    .checked_add(amount)
                    .ok_or(KrexaScoreError::Overflow)?;
                score.current_debt = score
                    .current_debt
                    .checked_add(amount)
                    .ok_or(KrexaScoreError::Overflow)?;
                score.is_active = true;
                ("borrowed", amount)
            }
            CreditEventInput::Repaid { amount } => {
                score.cumulative_repaid = score
                    .cumulative_repaid
                    .checked_add(amount)
                    .ok_or(KrexaScoreError::Overflow)?;
                score.current_debt = score.current_debt.saturating_sub(amount);
                score.last_repayment = clock.unix_timestamp;
                if score.current_debt == 0 {
                    score.is_active = false;
                }
                ("repaid", amount)
            }
            CreditEventInput::DebtUpdated { new_debt } => {
                score.current_debt = new_debt;
                ("debt_updated", new_debt)
            }
        };

        score.total_transactions = score
            .total_transactions
            .checked_add(1)
            .ok_or(KrexaScoreError::Overflow)?;

        emit!(CreditEventRecorded {
            agent: score.agent,
            event_type_label: label.to_string(),
            amount,
        });

        Ok(())
    }

    /// Update KYA tier — can only go up
    pub fn update_kya_tier(ctx: Context<UpdateKYA>, new_tier: u8) -> Result<()> {
        let config = &ctx.accounts.config;
        require!(!config.is_paused, KrexaScoreError::Paused);
        require!(
            ctx.accounts.authority.key() == config.oracle
                || ctx.accounts.authority.key() == config.admin,
            KrexaScoreError::NotAdminOrOracle
        );
        require!(new_tier <= 3, KrexaScoreError::InvalidKYATier);

        let score = &mut ctx.accounts.krexit_score;
        let old_tier = score.kya_tier;
        require!(new_tier > old_tier, KrexaScoreError::KYACannotDegrade);

        score.kya_tier = new_tier;

        emit!(KYAUpgradedEvent {
            agent: score.agent,
            old_tier,
            new_tier,
        });

        Ok(())
    }

    /// Pause/unpause the program
    pub fn set_paused(ctx: Context<AdminOnly>, paused: bool) -> Result<()> {
        let config = &mut ctx.accounts.config;
        require!(
            ctx.accounts.admin.key() == config.admin,
            KrexaScoreError::NotAdmin
        );
        config.is_paused = paused;
        Ok(())
    }

    /// Update config — admin only
    pub fn update_config(
        ctx: Context<AdminOnly>,
        new_admin: Option<Pubkey>,
        new_oracle: Option<Pubkey>,
    ) -> Result<()> {
        let config = &mut ctx.accounts.config;
        require!(
            ctx.accounts.admin.key() == config.admin,
            KrexaScoreError::NotAdmin
        );
        if let Some(a) = new_admin {
            config.admin = a;
        }
        if let Some(o) = new_oracle {
            config.oracle = o;
        }
        Ok(())
    }
}

// ─── Account Contexts ────────────────────────────────────────────────────────

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(
        init,
        payer = admin,
        space = ScoreConfig::LEN,
        seeds = [ScoreConfig::SEED],
        bump,
    )]
    pub config: Account<'info, ScoreConfig>,
    #[account(mut)]
    pub admin: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct InitializeScore<'info> {
    pub config: Account<'info, ScoreConfig>,
    /// CHECK: Agent profile PDA from the registry program — validated by caller
    pub agent_profile: UncheckedAccount<'info>,
    #[account(
        init,
        payer = owner,
        space = KrexitScore::LEN,
        seeds = [KrexitScore::SEED, agent_profile.key().as_ref()],
        bump,
    )]
    pub krexit_score: Account<'info, KrexitScore>,
    #[account(mut)]
    pub owner: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct UpdateScore<'info> {
    #[account(
        seeds = [ScoreConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, ScoreConfig>,
    pub oracle: Signer<'info>,
    #[account(
        mut,
        seeds = [KrexitScore::SEED, krexit_score.agent.as_ref()],
        bump = krexit_score.bump,
    )]
    pub krexit_score: Account<'info, KrexitScore>,
}

#[derive(Accounts)]
pub struct RecordCreditEvent<'info> {
    #[account(
        seeds = [ScoreConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, ScoreConfig>,
    pub caller_authority: Signer<'info>,
    #[account(
        mut,
        seeds = [KrexitScore::SEED, krexit_score.agent.as_ref()],
        bump = krexit_score.bump,
    )]
    pub krexit_score: Account<'info, KrexitScore>,
}

#[derive(Accounts)]
pub struct UpdateKYA<'info> {
    #[account(
        seeds = [ScoreConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, ScoreConfig>,
    pub authority: Signer<'info>,
    #[account(
        mut,
        seeds = [KrexitScore::SEED, krexit_score.agent.as_ref()],
        bump = krexit_score.bump,
    )]
    pub krexit_score: Account<'info, KrexitScore>,
}

#[derive(Accounts)]
pub struct AdminOnly<'info> {
    #[account(
        mut,
        seeds = [ScoreConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, ScoreConfig>,
    pub admin: Signer<'info>,
}

// ─── Events ──────────────────────────────────────────────────────────────────

#[event]
pub struct ScoreInitialized {
    pub agent: Pubkey,
    pub owner: Pubkey,
    pub starting_score: u16,
}

#[event]
pub struct ScoreUpdatedEvent {
    pub agent: Pubkey,
    pub old_score: u16,
    pub new_score: u16,
    pub event_type: u8,
    pub timestamp: i64,
}

#[event]
pub struct KYAUpgradedEvent {
    pub agent: Pubkey,
    pub old_tier: u8,
    pub new_tier: u8,
}

#[event]
pub struct CreditEventRecorded {
    pub agent: Pubkey,
    pub event_type_label: String,
    pub amount: u64,
}
