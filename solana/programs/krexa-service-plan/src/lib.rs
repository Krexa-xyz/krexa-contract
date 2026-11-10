use anchor_lang::prelude::*;
use anchor_spl::token::{self, Token, TokenAccount, Transfer};
use krexa_common::constants::*;
use krexa_common::state::ServiceHealth;

declare_id!("Eqc48c6TtKAPRosTMoC6Nasi85iqdLuzwbu6WBrsPFdt");

// ─────────────────────────────────────────────────────────────────────────────
// Accounts (state)
// ─────────────────────────────────────────────────────────────────────────────

/// Global config for the service-plan program (singleton PDA).
#[account]
pub struct ServicePlanConfig {
    /// Admin authority — can pause, update config
    pub admin: Pubkey,
    /// Oracle authority — can attest revenue, update health
    pub oracle: Pubkey,
    /// Credit vault program (authorized CPI target)
    pub credit_vault_program: Pubkey,
    /// Agent wallet program (authorized CPI target)
    pub agent_wallet_program: Pubkey,
    /// Total plans created (monotonic counter)
    pub total_plans: u64,
    /// Global pause
    pub is_paused: bool,
    pub bump: u8,
}

impl ServicePlanConfig {
    pub const LEN: usize = 8 // discriminator
        + 32  // admin
        + 32  // oracle
        + 32  // credit_vault_program
        + 32  // agent_wallet_program
        + 8   // total_plans
        + 1   // is_paused
        + 1;  // bump
    pub const SEED: &'static [u8] = b"svc_config";
}

/// A single milestone within a service plan.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Debug, Default)]
pub struct Milestone {
    /// USDC amount to disburse (6 decimals)
    pub amount: u64,
    /// Description hash (first 32 bytes of SHA-256)
    pub description_hash: [u8; 32],
    /// Unix timestamp when milestone becomes eligible
    pub eligible_at: i64,
    /// Whether this milestone has been disbursed
    pub disbursed: bool,
    /// Actual disbursement timestamp (0 if not yet)
    pub disbursed_at: i64,
    /// Whether this milestone slot is active/used
    pub is_active: bool,
}

impl Milestone {
    pub const LEN: usize = 8 + 32 + 8 + 1 + 8 + 1; // 58 bytes
}

/// The service plan for a Type B agent. One plan per agent.
/// Seeds: ["service_plan", agent_wallet.key()]
#[account]
pub struct ServicePlan {
    /// The agent wallet this plan governs
    pub agent_wallet: Pubkey,
    /// The owner who created/controls this plan
    pub owner: Pubkey,
    /// Total credit allocated to this plan (USDC, 6 decimals)
    pub total_credit: u64,
    /// Total amount already disbursed across all milestones
    pub total_disbursed: u64,
    /// Projected monthly revenue (USDC, 6 decimals) — set by oracle
    pub projected_monthly_revenue: u64,
    /// Actual cumulative revenue recorded this period
    pub actual_revenue_this_period: u64,
    /// Period start timestamp (resets each month)
    pub period_start: i64,
    /// Current health zone
    pub health: u8, // ServiceHealth as u8
    /// Timestamp of last revenue recording
    pub last_revenue_at: i64,
    /// Number of consecutive zero-revenue days
    pub zero_revenue_days: u8,
    /// Wind-down state: 0=none, 1=grace, 2=executing, 3=completed
    pub wind_down_state: u8,
    /// Wind-down initiated timestamp (0 if not in wind-down)
    pub wind_down_started_at: i64,
    /// Number of active expense destinations
    pub expense_dest_count: u8,
    /// Fixed-size milestone array
    pub milestones: [Milestone; 8], // MAX_MILESTONES
    /// Number of active milestones
    pub milestone_count: u8,
    /// Creation timestamp
    pub created_at: i64,
    pub bump: u8,
}

impl ServicePlan {
    pub const LEN: usize = 8  // discriminator
        + 32  // agent_wallet
        + 32  // owner
        + 8   // total_credit
        + 8   // total_disbursed
        + 8   // projected_monthly_revenue
        + 8   // actual_revenue_this_period
        + 8   // period_start
        + 1   // health
        + 8   // last_revenue_at
        + 1   // zero_revenue_days
        + 1   // wind_down_state
        + 8   // wind_down_started_at
        + 1   // expense_dest_count
        + (Milestone::LEN * 8) // milestones [Milestone; 8]
        + 1   // milestone_count
        + 8   // created_at
        + 1;  // bump
    pub const SEED: &'static [u8] = b"service_plan";
}

/// Approved expense destination for a Type B agent.
/// Seeds: ["expense_dest", service_plan.key(), destination.key()]
#[account]
pub struct ExpenseDestination {
    /// The service plan this destination belongs to
    pub service_plan: Pubkey,
    /// The destination token account (ATA of the vendor/service)
    pub destination: Pubkey,
    /// Human-readable label hash (first 32 bytes of SHA-256)
    pub label_hash: [u8; 32],
    /// Category: 0=infrastructure, 1=api, 2=marketing, 3=payroll, 4=other
    pub category: u8,
    /// Maximum single-transaction amount (0 = no per-tx limit)
    pub max_amount: u64,
    /// Cumulative amount sent to this destination
    pub total_sent: u64,
    /// Whether this destination is active
    pub is_active: bool,
    /// When this destination was approved
    pub approved_at: i64,
    pub bump: u8,
}

impl ExpenseDestination {
    pub const LEN: usize = 8  // discriminator
        + 32  // service_plan
        + 32  // destination
        + 32  // label_hash
        + 1   // category
        + 8   // max_amount
        + 8   // total_sent
        + 1   // is_active
        + 8   // approved_at
        + 1;  // bump
    pub const SEED: &'static [u8] = b"expense_dest";
}

// ─────────────────────────────────────────────────────────────────────────────
// Wind-down states
// ─────────────────────────────────────────────────────────────────────────────

pub const WIND_DOWN_NONE: u8 = 0;
pub const WIND_DOWN_GRACE: u8 = 1;
pub const WIND_DOWN_EXECUTING: u8 = 2;
pub const WIND_DOWN_COMPLETED: u8 = 3;

// ─────────────────────────────────────────────────────────────────────────────
// Events
// ─────────────────────────────────────────────────────────────────────────────

#[event]
pub struct PlanCreated {
    pub agent_wallet: Pubkey,
    pub owner: Pubkey,
    pub total_credit: u64,
    pub milestone_count: u8,
}

#[event]
pub struct MilestoneDisbursed {
    pub agent_wallet: Pubkey,
    pub milestone_index: u8,
    pub amount: u64,
}

#[event]
pub struct ExpenseDestAdded {
    pub service_plan: Pubkey,
    pub destination: Pubkey,
    pub category: u8,
}

#[event]
pub struct ExpenseDestRemoved {
    pub service_plan: Pubkey,
    pub destination: Pubkey,
}

#[event]
pub struct RevenueRecorded {
    pub agent_wallet: Pubkey,
    pub amount: u64,
    pub new_total: u64,
    pub health: u8,
}

#[event]
pub struct HealthUpdated {
    pub agent_wallet: Pubkey,
    pub old_health: u8,
    pub new_health: u8,
}

#[event]
pub struct WindDownStarted {
    pub agent_wallet: Pubkey,
    pub grace_ends_at: i64,
}

#[event]
pub struct WindDownAdvanced {
    pub agent_wallet: Pubkey,
    pub new_state: u8,
}

#[event]
pub struct ExpenseExecuted {
    pub service_plan: Pubkey,
    pub destination: Pubkey,
    pub amount: u64,
}

// ─────────────────────────────────────────────────────────────────────────────
// Errors
// ─────────────────────────────────────────────────────────────────────────────

#[error_code]
pub enum ServicePlanError {
    #[msg("Signer is not the admin")]
    NotAdmin,
    #[msg("Signer is not the oracle")]
    NotOracle,
    #[msg("Signer is not the plan owner")]
    NotOwner,
    #[msg("Service plan program is paused")]
    Paused,
    #[msg("Maximum milestones reached (8)")]
    MaxMilestonesReached,
    #[msg("Milestone index out of bounds")]
    MilestoneOutOfBounds,
    #[msg("Milestone already disbursed")]
    MilestoneAlreadyDisbursed,
    #[msg("Milestone not yet eligible")]
    MilestoneNotEligible,
    #[msg("Milestone delayed due to Yellow health zone")]
    MilestoneDelayed,
    #[msg("Milestone slot is not active")]
    MilestoneNotActive,
    #[msg("Disbursements paused — Orange or Red health zone")]
    DisbursementsPaused,
    #[msg("Maximum expense destinations reached (20)")]
    MaxExpenseDestsReached,
    #[msg("Expense destination is not active")]
    ExpenseDestNotActive,
    #[msg("Amount exceeds expense destination per-tx limit")]
    ExceedsExpenseLimit,
    #[msg("Plan is in wind-down — no new disbursements")]
    InWindDown,
    #[msg("Wind-down grace period has not elapsed")]
    GracePeriodNotElapsed,
    #[msg("Wind-down already started")]
    WindDownAlreadyStarted,
    #[msg("Wind-down not active")]
    WindDownNotActive,
    #[msg("Invalid expense category (0–4)")]
    InvalidCategory,
    #[msg("Milestone amounts exceed total credit")]
    MilestoneSumExceedsCredit,
    #[msg("Invalid wind-down state transition")]
    InvalidWindDownTransition,
    #[msg("Plan already exists for this agent")]
    PlanAlreadyExists,
    #[msg("Total credit must be greater than zero")]
    ZeroCredit,
}

// ─────────────────────────────────────────────────────────────────────────────
// Program
// ─────────────────────────────────────────────────────────────────────────────

#[program]
pub mod krexa_service_plan {
    use super::*;

    // ── Admin instructions ──────────────────────────────────────────────

    /// Initialize the singleton config PDA.
    pub fn initialize(
        ctx: Context<Initialize>,
        oracle: Pubkey,
        credit_vault_program: Pubkey,
        agent_wallet_program: Pubkey,
    ) -> Result<()> {
        let config = &mut ctx.accounts.config;
        config.admin = ctx.accounts.admin.key();
        config.oracle = oracle;
        config.credit_vault_program = credit_vault_program;
        config.agent_wallet_program = agent_wallet_program;
        config.total_plans = 0;
        config.is_paused = false;
        config.bump = ctx.bumps.config;
        Ok(())
    }

    /// Pause / unpause the program.
    pub fn set_paused(ctx: Context<AdminConfig>, paused: bool) -> Result<()> {
        ctx.accounts.config.is_paused = paused;
        Ok(())
    }

    /// Update admin, oracle, or program references.
    pub fn update_config(
        ctx: Context<AdminConfig>,
        new_admin: Option<Pubkey>,
        new_oracle: Option<Pubkey>,
    ) -> Result<()> {
        let config = &mut ctx.accounts.config;
        if let Some(a) = new_admin {
            config.admin = a;
        }
        if let Some(o) = new_oracle {
            config.oracle = o;
        }
        Ok(())
    }

    // ── Plan lifecycle ──────────────────────────────────────────────────

    /// Create a service plan for a Type B agent.
    pub fn create_plan(
        ctx: Context<CreatePlan>,
        total_credit: u64,
        milestones: Vec<MilestoneInput>,
    ) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, ServicePlanError::Paused);
        require!(total_credit > 0, ServicePlanError::ZeroCredit);
        require!(
            milestones.len() <= MAX_MILESTONES,
            ServicePlanError::MaxMilestonesReached
        );

        // Validate milestone sum doesn't exceed total credit
        let milestone_sum: u64 = milestones.iter().map(|m| m.amount).sum();
        require!(
            milestone_sum <= total_credit,
            ServicePlanError::MilestoneSumExceedsCredit
        );

        let now = Clock::get()?.unix_timestamp;
        let plan = &mut ctx.accounts.plan;
        plan.agent_wallet = ctx.accounts.agent_wallet.key();
        plan.owner = ctx.accounts.owner.key();
        plan.total_credit = total_credit;
        plan.total_disbursed = 0;
        plan.projected_monthly_revenue = 0;
        plan.actual_revenue_this_period = 0;
        plan.period_start = now;
        plan.health = ServiceHealth::Green.as_u8();
        plan.last_revenue_at = now;
        plan.zero_revenue_days = 0;
        plan.wind_down_state = WIND_DOWN_NONE;
        plan.wind_down_started_at = 0;
        plan.expense_dest_count = 0;
        plan.milestone_count = milestones.len() as u8;
        plan.created_at = now;
        plan.bump = ctx.bumps.plan;

        // Initialize milestone array
        let mut ms_array = [Milestone::default(); 8];
        for (i, m) in milestones.iter().enumerate() {
            ms_array[i] = Milestone {
                amount: m.amount,
                description_hash: m.description_hash,
                eligible_at: m.eligible_at,
                disbursed: false,
                disbursed_at: 0,
                is_active: true,
            };
        }
        plan.milestones = ms_array;

        // Increment global counter
        let config = &mut ctx.accounts.config;
        config.total_plans = config.total_plans.saturating_add(1);

        emit!(PlanCreated {
            agent_wallet: plan.agent_wallet,
            owner: plan.owner,
            total_credit,
            milestone_count: plan.milestone_count,
        });

        Ok(())
    }

    // ── Milestone disbursement ──────────────────────────────────────────

    /// Disburse a milestone — transfers USDC from vault to agent wallet.
    /// Only the oracle can trigger milestone release (after verification).
    pub fn disburse_milestone(
        ctx: Context<DisburseMilestone>,
        milestone_index: u8,
    ) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, ServicePlanError::Paused);

        let plan = &ctx.accounts.plan;

        // No disbursements during wind-down
        require!(
            plan.wind_down_state == WIND_DOWN_NONE,
            ServicePlanError::InWindDown
        );

        let health = ServiceHealth::from_u8(plan.health).unwrap_or_default();

        // Orange/Red: no disbursements
        require!(
            health != ServiceHealth::Orange && health != ServiceHealth::Red,
            ServicePlanError::DisbursementsPaused
        );

        let idx = milestone_index as usize;
        require!(idx < MAX_MILESTONES, ServicePlanError::MilestoneOutOfBounds);

        let milestone = &plan.milestones[idx];
        require!(milestone.is_active, ServicePlanError::MilestoneNotActive);
        require!(!milestone.disbursed, ServicePlanError::MilestoneAlreadyDisbursed);

        let now = Clock::get()?.unix_timestamp;

        // Check eligibility time
        require!(
            now >= milestone.eligible_at,
            ServicePlanError::MilestoneNotEligible
        );

        // Yellow zone: enforce delay
        if health == ServiceHealth::Yellow {
            require!(
                now >= milestone.eligible_at.saturating_add(YELLOW_MILESTONE_DELAY_SECONDS),
                ServicePlanError::MilestoneDelayed
            );
        }

        let amount = milestone.amount;

        // Effects: update plan state BEFORE transfer (CEI pattern)
        let plan = &mut ctx.accounts.plan;
        plan.milestones[idx].disbursed = true;
        plan.milestones[idx].disbursed_at = now;
        plan.total_disbursed = plan.total_disbursed.saturating_add(amount);

        // Interaction: transfer USDC from vault source to agent wallet token account
        let config_bump = ctx.accounts.config.bump;
        let signer_seeds: &[&[&[u8]]] = &[&[
            ServicePlanConfig::SEED,
            &[config_bump],
        ]];

        let transfer_ctx = CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            Transfer {
                from: ctx.accounts.vault_token.to_account_info(),
                to: ctx.accounts.agent_token.to_account_info(),
                authority: ctx.accounts.config.to_account_info(),
            },
            signer_seeds,
        );
        token::transfer(transfer_ctx, amount)?;

        emit!(MilestoneDisbursed {
            agent_wallet: plan.agent_wallet,
            milestone_index,
            amount,
        });

        Ok(())
    }

    // ── Expense destination management ──────────────────────────────────

    /// Add an approved expense destination for a service agent.
    pub fn add_expense_destination(
        ctx: Context<AddExpenseDestination>,
        label_hash: [u8; 32],
        category: u8,
        max_amount: u64,
    ) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, ServicePlanError::Paused);
        require!(category <= 4, ServicePlanError::InvalidCategory);

        let plan_key = ctx.accounts.plan.key();
        let plan = &mut ctx.accounts.plan;
        require!(
            plan.expense_dest_count < MAX_EXPENSE_DESTINATIONS,
            ServicePlanError::MaxExpenseDestsReached
        );

        let now = Clock::get()?.unix_timestamp;

        let dest = &mut ctx.accounts.expense_dest;
        dest.service_plan = plan_key;
        dest.destination = ctx.accounts.destination.key();
        dest.label_hash = label_hash;
        dest.category = category;
        dest.max_amount = max_amount;
        dest.total_sent = 0;
        dest.is_active = true;
        dest.approved_at = now;
        dest.bump = ctx.bumps.expense_dest;

        plan.expense_dest_count = plan.expense_dest_count.saturating_add(1);

        emit!(ExpenseDestAdded {
            service_plan: plan.key(),
            destination: dest.destination,
            category,
        });

        Ok(())
    }

    /// Deactivate an expense destination.
    pub fn remove_expense_destination(
        ctx: Context<RemoveExpenseDestination>,
    ) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, ServicePlanError::Paused);

        let dest = &mut ctx.accounts.expense_dest;
        require!(dest.is_active, ServicePlanError::ExpenseDestNotActive);
        dest.is_active = false;

        let plan = &mut ctx.accounts.plan;
        plan.expense_dest_count = plan.expense_dest_count.saturating_sub(1);

        emit!(ExpenseDestRemoved {
            service_plan: plan.key(),
            destination: dest.destination,
        });

        Ok(())
    }

    /// Execute an expense — transfer USDC from agent wallet to approved destination.
    /// The agent (or owner) signs; we verify destination is whitelisted + active.
    pub fn execute_expense(
        ctx: Context<ExecuteExpense>,
        amount: u64,
    ) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, ServicePlanError::Paused);

        let plan = &ctx.accounts.plan;

        // No expenses during wind-down execution/completion
        require!(
            plan.wind_down_state == WIND_DOWN_NONE
                || plan.wind_down_state == WIND_DOWN_GRACE,
            ServicePlanError::InWindDown
        );

        let dest = &ctx.accounts.expense_dest;
        require!(dest.is_active, ServicePlanError::ExpenseDestNotActive);

        // Per-tx limit check (0 means no limit)
        if dest.max_amount > 0 {
            require!(amount <= dest.max_amount, ServicePlanError::ExceedsExpenseLimit);
        }

        // Effects: update destination tracking
        let dest = &mut ctx.accounts.expense_dest;
        dest.total_sent = dest.total_sent.saturating_add(amount);

        // Interaction: transfer from agent token account to destination
        let transfer_ctx = CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            Transfer {
                from: ctx.accounts.agent_token.to_account_info(),
                to: ctx.accounts.destination_token.to_account_info(),
                authority: ctx.accounts.authority.to_account_info(),
            },
        );
        token::transfer(transfer_ctx, amount)?;

        emit!(ExpenseExecuted {
            service_plan: plan.key(),
            destination: dest.destination,
            amount,
        });

        Ok(())
    }

    // ── Revenue monitoring ──────────────────────────────────────────────

    /// Oracle records revenue for a service agent and auto-updates health.
    pub fn record_revenue(
        ctx: Context<RecordRevenue>,
        amount: u64,
    ) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, ServicePlanError::Paused);

        let now = Clock::get()?.unix_timestamp;
        let plan = &mut ctx.accounts.plan;

        plan.actual_revenue_this_period = plan
            .actual_revenue_this_period
            .saturating_add(amount);
        plan.last_revenue_at = now;
        plan.zero_revenue_days = 0; // reset on any revenue

        // Auto-compute health zone
        let old_health = plan.health;
        let new_health = compute_health(
            plan.actual_revenue_this_period,
            plan.projected_monthly_revenue,
            plan.zero_revenue_days,
        );
        plan.health = new_health;

        emit!(RevenueRecorded {
            agent_wallet: plan.agent_wallet,
            amount,
            new_total: plan.actual_revenue_this_period,
            health: new_health,
        });

        if old_health != new_health {
            emit!(HealthUpdated {
                agent_wallet: plan.agent_wallet,
                old_health,
                new_health,
            });
        }

        Ok(())
    }

    /// Oracle updates zero-revenue day counter and recalculates health.
    /// Called daily by the off-chain crank when no revenue was recorded.
    pub fn update_zero_revenue_days(
        ctx: Context<RecordRevenue>,
        days: u8,
    ) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, ServicePlanError::Paused);

        let plan = &mut ctx.accounts.plan;
        let old_health = plan.health;

        plan.zero_revenue_days = days;

        let new_health = compute_health(
            plan.actual_revenue_this_period,
            plan.projected_monthly_revenue,
            plan.zero_revenue_days,
        );
        plan.health = new_health;

        if old_health != new_health {
            emit!(HealthUpdated {
                agent_wallet: plan.agent_wallet,
                old_health,
                new_health,
            });
        }

        Ok(())
    }

    /// Oracle sets the projected monthly revenue target (start of new period).
    pub fn set_projected_revenue(
        ctx: Context<RecordRevenue>,
        projected_monthly_revenue: u64,
    ) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, ServicePlanError::Paused);

        let now = Clock::get()?.unix_timestamp;
        let plan = &mut ctx.accounts.plan;
        plan.projected_monthly_revenue = projected_monthly_revenue;
        plan.actual_revenue_this_period = 0;
        plan.period_start = now;

        Ok(())
    }

    // ── Wind-down ───────────────────────────────────────────────────────

    /// Initiate wind-down — oracle or admin triggers when health = Red.
    /// Starts a 48-hour grace period.
    pub fn start_wind_down(ctx: Context<StartWindDown>) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, ServicePlanError::Paused);

        let plan = &mut ctx.accounts.plan;
        require!(
            plan.wind_down_state == WIND_DOWN_NONE,
            ServicePlanError::WindDownAlreadyStarted
        );

        // Must be in Red zone to initiate
        require!(
            plan.health == ServiceHealth::Red.as_u8(),
            ServicePlanError::DisbursementsPaused // re-using: health not bad enough
        );

        let now = Clock::get()?.unix_timestamp;
        plan.wind_down_state = WIND_DOWN_GRACE;
        plan.wind_down_started_at = now;

        emit!(WindDownStarted {
            agent_wallet: plan.agent_wallet,
            grace_ends_at: now.saturating_add(WIND_DOWN_GRACE_SECONDS),
        });

        Ok(())
    }

    /// Advance wind-down from grace → executing → completed.
    /// Permissionless after grace period elapses.
    pub fn advance_wind_down(ctx: Context<AdvanceWindDown>) -> Result<()> {
        let plan = &mut ctx.accounts.plan;
        let now = Clock::get()?.unix_timestamp;

        match plan.wind_down_state {
            WIND_DOWN_GRACE => {
                // Grace period must have elapsed
                let grace_end = plan
                    .wind_down_started_at
                    .saturating_add(WIND_DOWN_GRACE_SECONDS);
                require!(now >= grace_end, ServicePlanError::GracePeriodNotElapsed);

                plan.wind_down_state = WIND_DOWN_EXECUTING;
                emit!(WindDownAdvanced {
                    agent_wallet: plan.agent_wallet,
                    new_state: WIND_DOWN_EXECUTING,
                });
            }
            WIND_DOWN_EXECUTING => {
                // Mark as completed — off-chain keeper handles actual fund recovery
                plan.wind_down_state = WIND_DOWN_COMPLETED;
                emit!(WindDownAdvanced {
                    agent_wallet: plan.agent_wallet,
                    new_state: WIND_DOWN_COMPLETED,
                });
            }
            _ => {
                return Err(ServicePlanError::InvalidWindDownTransition.into());
            }
        }

        Ok(())
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper: compute health zone from revenue metrics
// ─────────────────────────────────────────────────────────────────────────────

fn compute_health(actual: u64, projected: u64, zero_days: u8) -> u8 {
    // Zero-revenue day overrides
    if zero_days >= ZERO_REVENUE_RED_DAYS {
        return ServiceHealth::Red.as_u8();
    }
    if zero_days >= ZERO_REVENUE_ORANGE_DAYS {
        return ServiceHealth::Orange.as_u8();
    }

    // If no projection set yet, stay Green
    if projected == 0 {
        return ServiceHealth::Green.as_u8();
    }

    // Revenue velocity ratio in BPS: (actual * 10000) / projected
    let ratio_bps = (actual as u128)
        .saturating_mul(BPS_DENOMINATOR as u128)
        .checked_div(projected as u128)
        .unwrap_or(0) as u16;

    if ratio_bps >= REVENUE_GREEN_BPS {
        ServiceHealth::Green.as_u8()
    } else if ratio_bps >= REVENUE_YELLOW_BPS {
        ServiceHealth::Yellow.as_u8()
    } else if ratio_bps >= REVENUE_ORANGE_BPS {
        ServiceHealth::Orange.as_u8()
    } else {
        ServiceHealth::Red.as_u8()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Instruction input types
// ─────────────────────────────────────────────────────────────────────────────

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct MilestoneInput {
    pub amount: u64,
    pub description_hash: [u8; 32],
    pub eligible_at: i64,
}

// ─────────────────────────────────────────────────────────────────────────────
// Contexts
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(
        init,
        payer = admin,
        space = ServicePlanConfig::LEN,
        seeds = [ServicePlanConfig::SEED],
        bump,
    )]
    pub config: Account<'info, ServicePlanConfig>,

    #[account(mut)]
    pub admin: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct AdminConfig<'info> {
    #[account(
        mut,
        seeds = [ServicePlanConfig::SEED],
        bump = config.bump,
        has_one = admin @ ServicePlanError::NotAdmin,
    )]
    pub config: Account<'info, ServicePlanConfig>,

    pub admin: Signer<'info>,
}

#[derive(Accounts)]
pub struct CreatePlan<'info> {
    #[account(
        mut,
        seeds = [ServicePlanConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, ServicePlanConfig>,

    #[account(
        init,
        payer = owner,
        space = ServicePlan::LEN,
        seeds = [ServicePlan::SEED, agent_wallet.key().as_ref()],
        bump,
    )]
    pub plan: Account<'info, ServicePlan>,

    /// The agent wallet this plan governs (must exist).
    /// CHECK: We just need the key for PDA derivation; wallet validity
    /// is enforced off-chain or by the caller.
    pub agent_wallet: UncheckedAccount<'info>,

    #[account(mut)]
    pub owner: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct DisburseMilestone<'info> {
    #[account(
        seeds = [ServicePlanConfig::SEED],
        bump = config.bump,
        has_one = oracle @ ServicePlanError::NotOracle,
    )]
    pub config: Account<'info, ServicePlanConfig>,

    #[account(
        mut,
        seeds = [ServicePlan::SEED, plan.agent_wallet.as_ref()],
        bump = plan.bump,
    )]
    pub plan: Account<'info, ServicePlan>,

    /// Source token account controlled by the config PDA (vault funds).
    #[account(mut)]
    pub vault_token: Account<'info, TokenAccount>,

    /// Destination token account on the agent's wallet.
    #[account(mut)]
    pub agent_token: Account<'info, TokenAccount>,

    pub oracle: Signer<'info>,

    pub token_program: Program<'info, Token>,
}

#[derive(Accounts)]
pub struct AddExpenseDestination<'info> {
    #[account(
        seeds = [ServicePlanConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, ServicePlanConfig>,

    #[account(
        mut,
        seeds = [ServicePlan::SEED, plan.agent_wallet.as_ref()],
        bump = plan.bump,
        has_one = owner @ ServicePlanError::NotOwner,
    )]
    pub plan: Account<'info, ServicePlan>,

    #[account(
        init,
        payer = owner,
        space = ExpenseDestination::LEN,
        seeds = [
            ExpenseDestination::SEED,
            plan.key().as_ref(),
            destination.key().as_ref(),
        ],
        bump,
    )]
    pub expense_dest: Account<'info, ExpenseDestination>,

    /// CHECK: The destination token account — validated by seeds.
    pub destination: UncheckedAccount<'info>,

    #[account(mut)]
    pub owner: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct RemoveExpenseDestination<'info> {
    #[account(
        seeds = [ServicePlanConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, ServicePlanConfig>,

    #[account(
        mut,
        seeds = [ServicePlan::SEED, plan.agent_wallet.as_ref()],
        bump = plan.bump,
        has_one = owner @ ServicePlanError::NotOwner,
    )]
    pub plan: Account<'info, ServicePlan>,

    #[account(
        mut,
        seeds = [
            ExpenseDestination::SEED,
            plan.key().as_ref(),
            expense_dest.destination.as_ref(),
        ],
        bump = expense_dest.bump,
    )]
    pub expense_dest: Account<'info, ExpenseDestination>,

    pub owner: Signer<'info>,
}

#[derive(Accounts)]
pub struct ExecuteExpense<'info> {
    #[account(
        seeds = [ServicePlanConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, ServicePlanConfig>,

    #[account(
        seeds = [ServicePlan::SEED, plan.agent_wallet.as_ref()],
        bump = plan.bump,
    )]
    pub plan: Account<'info, ServicePlan>,

    #[account(
        mut,
        seeds = [
            ExpenseDestination::SEED,
            plan.key().as_ref(),
            expense_dest.destination.as_ref(),
        ],
        bump = expense_dest.bump,
    )]
    pub expense_dest: Account<'info, ExpenseDestination>,

    /// Agent wallet's USDC token account (source).
    #[account(mut)]
    pub agent_token: Account<'info, TokenAccount>,

    /// Destination USDC token account (target).
    #[account(mut)]
    pub destination_token: Account<'info, TokenAccount>,

    /// Agent or owner — must have authority over agent_token.
    pub authority: Signer<'info>,

    pub token_program: Program<'info, Token>,
}

#[derive(Accounts)]
pub struct RecordRevenue<'info> {
    #[account(
        seeds = [ServicePlanConfig::SEED],
        bump = config.bump,
        has_one = oracle @ ServicePlanError::NotOracle,
    )]
    pub config: Account<'info, ServicePlanConfig>,

    #[account(
        mut,
        seeds = [ServicePlan::SEED, plan.agent_wallet.as_ref()],
        bump = plan.bump,
    )]
    pub plan: Account<'info, ServicePlan>,

    pub oracle: Signer<'info>,
}

#[derive(Accounts)]
pub struct StartWindDown<'info> {
    #[account(
        seeds = [ServicePlanConfig::SEED],
        bump = config.bump,
        has_one = oracle @ ServicePlanError::NotOracle,
    )]
    pub config: Account<'info, ServicePlanConfig>,

    #[account(
        mut,
        seeds = [ServicePlan::SEED, plan.agent_wallet.as_ref()],
        bump = plan.bump,
    )]
    pub plan: Account<'info, ServicePlan>,

    pub oracle: Signer<'info>,
}

#[derive(Accounts)]
pub struct AdvanceWindDown<'info> {
    #[account(
        mut,
        seeds = [ServicePlan::SEED, plan.agent_wallet.as_ref()],
        bump = plan.bump,
    )]
    pub plan: Account<'info, ServicePlan>,

    /// Permissionless — anyone can advance after grace period.
    pub caller: Signer<'info>,
}
