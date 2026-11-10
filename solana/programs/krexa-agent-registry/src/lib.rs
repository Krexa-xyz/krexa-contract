use anchor_lang::prelude::*;
use krexa_common::constants::{
    DEFAULT_CREDIT_SCORE, MAX_CREDIT_SCORE, MIN_CREDIT_SCORE, SCORE_EXPIRY_SECONDS,
};

declare_id!("EnteGjokMnFqTDcZSBitXDQEctMCnqV33HbPKw2LnDCg");

// ─────────────────────────────────────────────────────────────────────────────
// Accounts
// ─────────────────────────────────────────────────────────────────────────────

#[account]
pub struct RegistryConfig {
    pub admin: Pubkey,
    pub oracle: Pubkey,
    pub wallet_program: Pubkey, // the krexa-agent-wallet program authorised to CPI here
    pub total_agents: u64,
    pub is_paused: bool,
    pub bump: u8,
}

impl RegistryConfig {
    pub const LEN: usize = 8 + 32 + 32 + 32 + 8 + 1 + 1;
    pub const SEED: &'static [u8] = b"registry_config";
}

#[account]
pub struct AgentProfile {
    pub agent: Pubkey,
    pub owner: Pubkey,
    pub name: [u8; 32],

    // Credit identity
    pub credit_score: u16,
    pub credit_level: u8,
    pub kya_tier: u8,
    pub kya_verified_at: i64,
    pub score_updated_at: i64,

    // Lifetime stats (updated via CPI from agent wallet)
    pub total_volume_usd: u64,
    pub total_trades: u64,
    pub total_repaid: u64,
    pub total_borrowed: u64,
    pub liquidation_count: u8,

    // Links
    pub wallet_pda: Pubkey,
    pub has_wallet: bool,

    // Status
    pub is_active: bool,
    pub registered_at: i64,
    pub bump: u8,

    // v3: Agent enforcement type (0=Trader/TypeA, 1=Service/TypeB, 2=Hybrid/TypeC)
    pub agent_type: u8,
}

impl AgentProfile {
    // 8 discriminator + 32+32+32 identity + 2+1+1+8+8 credit + 8+8+8+8+1 stats + 32+1 links + 1+8+1 status + 1 agent_type = 201
    pub const LEN: usize = 8 + 32 + 32 + 32 + 2 + 1 + 1 + 8 + 8
        + 8 + 8 + 8 + 8 + 1 + 32 + 1 + 1 + 8 + 1 + 1;
    pub const SEED: &'static [u8] = b"agent_profile";
}

// ─────────────────────────────────────────────────────────────────────────────
// ProfileOwnershipTransfer — temporary PDA for 2-step profile ownership transfer
// ─────────────────────────────────────────────────────────────────────────────

#[account]
pub struct ProfileOwnershipTransfer {
    pub agent: Pubkey,
    pub proposed_owner: Pubkey,
    pub proposed_owner_type: u8,
    pub proposed_at: i64,
    pub bump: u8,
}

impl ProfileOwnershipTransfer {
    pub const LEN: usize = 8 + 32 + 32 + 1 + 8 + 1; // 82
    pub const SEED: &'static [u8] = b"profile_transfer";
}

// ─────────────────────────────────────────────────────────────────────────────
// Level calculation (pure — no IO, usable everywhere)
// ─────────────────────────────────────────────────────────────────────────────

/// Derive the correct credit level from score + KYA tier.
/// Level can go up OR down — called on every score/KYA change.
pub fn calculate_level(score: u16, kya_tier: u8) -> u8 {
    // Canonical thresholds (source: Investor Memo):
    //   L4: Score ≥ 750, KYA Tier 2+ (Enhanced), 6+ months history
    //   L3: Score ≥ 650, KYA Tier 2+ (Enhanced), 3+ months history
    //   L2: Score ≥ 500, KYA Tier 1+ (Basic)
    //   L1: Score < 500 (or new agent), KYA Tier 1+ (Basic)
    // Note: history requirements are checked elsewhere (off-chain oracle)
    match (score, kya_tier) {
        (s, k) if s >= 750 && k >= 2 => 4, // Elite    — KYA Tier 2+ (Enhanced)
        (s, k) if s >= 650 && k >= 2 => 3, // Trusted  — KYA Tier 2+ (Enhanced)
        (s, k) if s >= 500 && k >= 1 => 2, // Established — KYA Tier 1+ (Basic)
        (_, k) if k >= 1             => 1, // Starter  — any score, KYA Tier 1+ (Basic)
        _ => 0,                             // KyaOnly
    }
}

/// Returns true if the agent is eligible for the requested credit level.
/// Callers must pass the current unix timestamp for expiry checking.
pub fn is_agent_eligible(profile: &AgentProfile, required_level: u8, now: i64) -> bool {
    if !profile.is_active {
        return false;
    }
    if profile.credit_level < required_level {
        return false;
    }
    // SOL-019 fix: Check score expiry unconditionally when a score exists.
    // Previously skipped for kya_tier == 0, allowing agents with stale scores
    // to pass eligibility checks.
    if profile.score_updated_at > 0 && (now - profile.score_updated_at) > SCORE_EXPIRY_SECONDS {
        return false;
    }
    true
}

// ─────────────────────────────────────────────────────────────────────────────
// Events
// ─────────────────────────────────────────────────────────────────────────────

#[event]
pub struct AgentRegistered {
    pub agent: Pubkey,
    pub owner: Pubkey,
    pub name: [u8; 32],
}

#[event]
pub struct KyaUpdated {
    pub agent: Pubkey,
    pub old_tier: u8,
    pub new_tier: u8,
    pub new_level: u8,
}

#[event]
pub struct CreditScoreUpdated {
    pub agent: Pubkey,
    pub old_score: u16,
    pub new_score: u16,
    pub old_level: u8,
    pub new_level: u8,
}

#[event]
pub struct LiquidationRecorded {
    pub agent: Pubkey,
    pub new_score: u16,
    pub new_level: u8,
    pub liquidation_count: u8,
}

#[event]
pub struct AgentDeactivated {
    pub agent: Pubkey,
}

#[event]
pub struct LegalAgreementSigned {
    pub agent: Pubkey,
    pub agreement_hash: [u8; 32],
    pub signed_at: i64,
}

#[event]
pub struct ScoreAttested {
    pub agent: Pubkey,
    pub attestation_hash: [u8; 32],
    pub attested_at: i64,
}

#[event]
pub struct ProfileOwnershipTransferProposed {
    pub agent: Pubkey,
    pub current_owner: Pubkey,
    pub proposed_owner: Pubkey,
    pub proposed_owner_type: u8,
}

#[event]
pub struct ProfileOwnershipTransferAccepted {
    pub agent: Pubkey,
    pub old_owner: Pubkey,
    pub new_owner: Pubkey,
    pub new_owner_type: u8,
}

#[event]
pub struct ProfileOwnershipTransferCancelled {
    pub agent: Pubkey,
    pub cancelled_by: Pubkey,
}

// ─────────────────────────────────────────────────────────────────────────────
// Errors
// ─────────────────────────────────────────────────────────────────────────────

#[error_code]
pub enum RegistryError {
    #[msg("Signer is not the admin")]
    NotAdmin,
    #[msg("Signer is not the oracle")]
    NotOracle,
    #[msg("Signer is not admin or oracle")]
    NotAdminOrOracle,
    #[msg("Caller is not the authorised wallet program")]
    NotWalletProgram,
    #[msg("Registry is paused")]
    Paused,
    #[msg("Invalid KYA tier — must be 0–3")]
    InvalidKyaTier,
    #[msg("Invalid credit score — must be 200–850")]
    InvalidCreditScore,
    #[msg("Agent is not active")]
    AgentNotActive,
    #[msg("Invalid owner type — must be 0 (EOA) or 1 (Multisig)")]
    InvalidOwnerType,
    #[msg("Signer is not the proposed new owner")]
    NotPendingOwner,
    #[msg("Wallet is already linked to this agent profile")]
    WalletAlreadyLinked,
    #[msg("Address cannot be the zero/default pubkey")]
    InvalidAddress,
    #[msg("Invalid agent type")]
    InvalidAgentType,
}

// ─────────────────────────────────────────────────────────────────────────────
// Program
// ─────────────────────────────────────────────────────────────────────────────

#[program]
pub mod krexa_agent_registry {
    use super::*;

    /// One-time setup: store admin, oracle, and the authorised wallet program ID.
    pub fn initialize(
        ctx: Context<Initialize>,
        oracle: Pubkey,
        wallet_program: Pubkey,
    ) -> Result<()> {
        let cfg = &mut ctx.accounts.config;
        cfg.admin = ctx.accounts.admin.key();
        cfg.oracle = oracle;
        cfg.wallet_program = wallet_program;
        cfg.total_agents = 0;
        cfg.is_paused = false;
        cfg.bump = ctx.bumps.config;
        Ok(())
    }

    /// Register a new agent. Both the agent keypair and the human owner must sign.
    pub fn register_agent(ctx: Context<RegisterAgent>, name: [u8; 32]) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, RegistryError::Paused);

        let now = Clock::get()?.unix_timestamp;
        let profile = &mut ctx.accounts.profile;

        profile.agent = ctx.accounts.agent.key();
        profile.owner = ctx.accounts.owner.key();
        profile.name = name;
        profile.credit_score = DEFAULT_CREDIT_SCORE;
        profile.credit_level = 0;
        profile.kya_tier = 0;
        profile.kya_verified_at = 0;
        profile.score_updated_at = now;
        profile.total_volume_usd = 0;
        profile.total_trades = 0;
        profile.total_repaid = 0;
        profile.total_borrowed = 0;
        profile.liquidation_count = 0;
        profile.wallet_pda = Pubkey::default();
        profile.has_wallet = false;
        profile.is_active = true;
        profile.registered_at = now;
        profile.bump = ctx.bumps.profile;
        profile.agent_type = 0; // Default: Trader (Type A)

        ctx.accounts.config.total_agents =
            ctx.accounts.config.total_agents.saturating_add(1);

        emit!(AgentRegistered {
            agent: profile.agent,
            owner: profile.owner,
            name,
        });
        Ok(())
    }

    /// Admin or oracle updates an agent's KYA tier.
    /// Auto-grants Starter (level 1) if KYA Basic is reached and agent is still at level 0.
    pub fn update_kya(ctx: Context<UpdateKya>, new_tier: u8) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, RegistryError::Paused);
        require!(new_tier <= 3, RegistryError::InvalidKyaTier);

        let signer = ctx.accounts.authority.key();
        let cfg = &ctx.accounts.config;
        require!(
            signer == cfg.admin || signer == cfg.oracle,
            RegistryError::NotAdminOrOracle
        );

        let now = Clock::get()?.unix_timestamp;
        let profile = &mut ctx.accounts.profile;
        require!(profile.is_active, RegistryError::AgentNotActive);

        let old_tier = profile.kya_tier;
        profile.kya_tier = new_tier;
        profile.kya_verified_at = now;
        // SOL-048 fix: Update score_updated_at so expiry checks work correctly
        profile.score_updated_at = now;

        // SOL-006 fix: Always recalculate level from score + new KYA tier.
        // Previously auto-upgraded to Level 1 unconditionally when KYA >= 1,
        // bypassing score check. An agent with score < 400 (e.g. post-liquidation)
        // would incorrectly get Level 1 just from KYA upgrade.
        profile.credit_level = calculate_level(profile.credit_score, new_tier);

        emit!(KyaUpdated {
            agent: profile.agent,
            old_tier,
            new_tier,
            new_level: profile.credit_level,
        });
        Ok(())
    }

    /// Oracle updates an agent's credit score and recalculates credit level.
    /// Level can go up OR down — bad behaviour costs privileges.
    pub fn update_credit_score(ctx: Context<UpdateCreditScore>, new_score: u16) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, RegistryError::Paused);
        require!(
            ctx.accounts.authority.key() == ctx.accounts.config.oracle,
            RegistryError::NotOracle
        );
        require!(
            new_score >= MIN_CREDIT_SCORE && new_score <= MAX_CREDIT_SCORE,
            RegistryError::InvalidCreditScore
        );

        let now = Clock::get()?.unix_timestamp;
        let profile = &mut ctx.accounts.profile;
        require!(profile.is_active, RegistryError::AgentNotActive);

        let old_score = profile.credit_score;
        let old_level = profile.credit_level;

        profile.credit_score = new_score;
        profile.score_updated_at = now;
        profile.credit_level = calculate_level(new_score, profile.kya_tier);

        emit!(CreditScoreUpdated {
            agent: profile.agent,
            old_score,
            new_score,
            old_level,
            new_level: profile.credit_level,
        });
        Ok(())
    }

    /// Increment lifetime stats. Called via CPI from krexa-agent-wallet.
    pub fn update_agent_stats(
        ctx: Context<UpdateAgentStats>,
        volume: u64,
        trades: u64,
        repaid: u64,
        borrowed: u64,
    ) -> Result<()> {
        let profile = &mut ctx.accounts.profile;
        profile.total_volume_usd = profile.total_volume_usd.saturating_add(volume);
        profile.total_trades = profile.total_trades.saturating_add(trades);
        profile.total_repaid = profile.total_repaid.saturating_add(repaid);
        profile.total_borrowed = profile.total_borrowed.saturating_add(borrowed);
        Ok(())
    }

    /// Record a liquidation event. Drops score by 40 (immutable, floor 200) and recalculates level.
    pub fn record_liquidation(ctx: Context<RecordLiquidation>) -> Result<()> {
        let profile = &mut ctx.accounts.profile;
        profile.liquidation_count = profile.liquidation_count.saturating_add(1);
        // IMMUTABLE: -40 point penalty per liquidation (canonical, cannot be changed by governance)
        profile.credit_score = profile.credit_score.saturating_sub(40).max(MIN_CREDIT_SCORE);
        profile.credit_level = calculate_level(profile.credit_score, profile.kya_tier);

        emit!(LiquidationRecorded {
            agent: profile.agent,
            new_score: profile.credit_score,
            new_level: profile.credit_level,
            liquidation_count: profile.liquidation_count,
        });
        Ok(())
    }

    /// Link a newly-created agent wallet PDA to this profile. Called via CPI from agent-wallet.
    pub fn link_wallet(ctx: Context<LinkWallet>, wallet_pda: Pubkey) -> Result<()> {
        let profile = &mut ctx.accounts.profile;
        // SOL-035 fix: Prevent re-linking — wallet assignment is one-time
        // SOL-069 fix: use semantically correct error code
        require!(!profile.has_wallet, RegistryError::WalletAlreadyLinked);
        profile.wallet_pda = wallet_pda;
        profile.has_wallet = true;
        Ok(())
    }

    /// Admin permanently deactivates an agent and strips credit level.
    pub fn deactivate_agent(ctx: Context<DeactivateAgent>) -> Result<()> {
        let profile = &mut ctx.accounts.profile;
        profile.is_active = false;
        profile.credit_level = 0;
        emit!(AgentDeactivated { agent: profile.agent });
        Ok(())
    }

    /// SOL-034 fix: Admin can reactivate a previously deactivated agent.
    pub fn reactivate_agent(ctx: Context<DeactivateAgent>) -> Result<()> {
        let profile = &mut ctx.accounts.profile;
        require!(!profile.is_active, RegistryError::AgentNotActive);
        profile.is_active = true;
        // Recalculate level from current score and KYA
        profile.credit_level = calculate_level(profile.credit_score, profile.kya_tier);
        Ok(())
    }

    /// Agent or owner signs a legal credit agreement. Required for L3-L4 credit.
    /// Stores the hash of the signed agreement on-chain for verifiability.
    pub fn sign_legal_agreement(
        ctx: Context<SignLegalAgreement>,
        agreement_hash: [u8; 32],
    ) -> Result<()> {
        let profile = &mut ctx.accounts.profile;
        require!(profile.is_active, RegistryError::AgentNotActive);

        let now = Clock::get()?.unix_timestamp;

        emit!(LegalAgreementSigned {
            agent: profile.agent,
            agreement_hash,
            signed_at: now,
        });
        Ok(())
    }

    /// Oracle stores keccak256(agent, score, level, timestamp) on-chain.
    /// Third parties can verify a score was issued by the Krexa oracle.
    pub fn attest_score(
        ctx: Context<AttestScore>,
        score_hash: [u8; 32],
    ) -> Result<()> {
        require!(
            ctx.accounts.authority.key() == ctx.accounts.config.oracle,
            RegistryError::NotOracle
        );

        let profile = &mut ctx.accounts.profile;
        require!(profile.is_active, RegistryError::AgentNotActive);

        let now = Clock::get()?.unix_timestamp;

        emit!(ScoreAttested {
            agent: profile.agent,
            attestation_hash: score_hash,
            attested_at: now,
        });
        Ok(())
    }

    /// Admin can rotate oracle and wallet_program addresses.
    pub fn update_config(
        ctx: Context<UpdateRegistryConfig>,
        new_admin: Option<Pubkey>,
        new_oracle: Option<Pubkey>,
        new_wallet_program: Option<Pubkey>,
    ) -> Result<()> {
        let cfg = &mut ctx.accounts.config;
        // SOL-075 fix: prevent permanent lockout via zero-address
        if let Some(admin) = new_admin {
            require!(admin != Pubkey::default(), RegistryError::InvalidAddress);
            cfg.admin = admin;
        }
        if let Some(oracle) = new_oracle {
            require!(oracle != Pubkey::default(), RegistryError::InvalidAddress);
            cfg.oracle = oracle;
        }
        if let Some(wp) = new_wallet_program {
            cfg.wallet_program = wp;
        }
        Ok(())
    }

    /// Migrate a v1 AgentProfile (no owner_type field) to v2.
    /// Uses raw AccountInfo to avoid deserialization failure on the old 272-byte layout.
    /// The new byte at offset 272 is zeroed by realloc = EOA (owner_type = 0).
    pub fn migrate_profile_v2(ctx: Context<MigrateProfileV2>) -> Result<()> {
        let profile_info = ctx.accounts.profile.to_account_info();
        let current_len = profile_info.data_len();
        let new_len = AgentProfile::LEN;

        if current_len < new_len {
            // SOL-076 fix: use true to zero-init new bytes (owner_type defaults to 0 = EOA)
            profile_info.realloc(new_len, true)?;
            let rent = Rent::get()?;
            let new_min = rent.minimum_balance(new_len);
            let old_min = rent.minimum_balance(current_len);
            let diff = new_min.saturating_sub(old_min);
            if diff > 0 {
                anchor_lang::system_program::transfer(
                    CpiContext::new(
                        ctx.accounts.system_program.to_account_info(),
                        anchor_lang::system_program::Transfer {
                            from: ctx.accounts.payer.to_account_info(),
                            to: profile_info,
                        },
                    ),
                    diff,
                )?;
            }
            // New byte at offset (new_len - 1) is zeroed by realloc → owner_type = 0 (EOA)
        }
        Ok(())
    }

    /// Propose a profile ownership transfer.
    pub fn propose_profile_transfer(
        ctx: Context<ProposeProfileTransfer>,
        new_owner: Pubkey,
        new_owner_type: u8,
    ) -> Result<()> {
        require!(new_owner_type <= 1, RegistryError::InvalidOwnerType);
        require!(new_owner != Pubkey::default(), RegistryError::InvalidOwnerType);

        let transfer = &mut ctx.accounts.transfer_request;
        transfer.agent = ctx.accounts.profile.agent;
        transfer.proposed_owner = new_owner;
        transfer.proposed_owner_type = new_owner_type;
        transfer.proposed_at = Clock::get()?.unix_timestamp;
        transfer.bump = ctx.bumps.transfer_request;

        emit!(ProfileOwnershipTransferProposed {
            agent: ctx.accounts.profile.agent,
            current_owner: ctx.accounts.owner.key(),
            proposed_owner: new_owner,
            proposed_owner_type: new_owner_type,
        });
        Ok(())
    }

    /// Accept a pending profile ownership transfer.
    pub fn accept_profile_transfer(ctx: Context<AcceptProfileTransfer>) -> Result<()> {
        let transfer = &ctx.accounts.transfer_request;
        let old_owner = ctx.accounts.profile.owner;
        let new_owner = transfer.proposed_owner;
        let new_owner_type = transfer.proposed_owner_type;
        let agent = ctx.accounts.profile.agent;

        let profile = &mut ctx.accounts.profile;
        profile.owner = new_owner;

        emit!(ProfileOwnershipTransferAccepted {
            agent,
            old_owner,
            new_owner,
            new_owner_type,
        });
        Ok(())
    }

    /// Cancel a pending profile ownership transfer.
    pub fn cancel_profile_transfer(ctx: Context<CancelProfileTransfer>) -> Result<()> {
        emit!(ProfileOwnershipTransferCancelled {
            agent: ctx.accounts.profile.agent,
            cancelled_by: ctx.accounts.owner.key(),
        });
        Ok(())
    }

    /// Admin or oracle sets the agent enforcement type (Trader/Service/Hybrid).
    pub fn set_agent_type(ctx: Context<UpdateKya>, agent_type: u8) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, RegistryError::Paused);
        require!(agent_type <= 2, RegistryError::InvalidAgentType);

        let signer = ctx.accounts.authority.key();
        let cfg = &ctx.accounts.config;
        require!(
            signer == cfg.admin || signer == cfg.oracle,
            RegistryError::NotAdminOrOracle
        );

        let profile = &mut ctx.accounts.profile;
        require!(profile.is_active, RegistryError::AgentNotActive);
        profile.agent_type = agent_type;
        Ok(())
    }

    /// Migrate a v2 AgentProfile to v3 (adds agent_type field).
    /// Reallocs account to new size; new byte defaults to 0 (Trader).
    pub fn migrate_profile_v3(ctx: Context<MigrateProfileV2>) -> Result<()> {
        let profile_info = ctx.accounts.profile.to_account_info();
        let current_len = profile_info.data_len();
        let new_len = AgentProfile::LEN;

        if current_len < new_len {
            profile_info.realloc(new_len, false)?;
            let rent = Rent::get()?;
            let new_min = rent.minimum_balance(new_len);
            let old_min = rent.minimum_balance(current_len);
            let diff = new_min.saturating_sub(old_min);
            if diff > 0 {
                anchor_lang::system_program::transfer(
                    CpiContext::new(
                        ctx.accounts.system_program.to_account_info(),
                        anchor_lang::system_program::Transfer {
                            from: ctx.accounts.payer.to_account_info(),
                            to: profile_info,
                        },
                    ),
                    diff,
                )?;
            }
            // New byte at end is zeroed by realloc → agent_type = 0 (Trader)
        }
        Ok(())
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Contexts
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(
        init,
        payer = admin,
        space = RegistryConfig::LEN,
        seeds = [RegistryConfig::SEED],
        bump,
    )]
    pub config: Account<'info, RegistryConfig>,

    #[account(mut)]
    pub admin: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct RegisterAgent<'info> {
    #[account(
        seeds = [RegistryConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, RegistryConfig>,

    #[account(
        init,
        payer = owner,
        space = AgentProfile::LEN,
        seeds = [AgentProfile::SEED, agent.key().as_ref()],
        bump,
    )]
    pub profile: Account<'info, AgentProfile>,

    /// The AI agent's own signing keypair
    pub agent: Signer<'info>,

    /// The human owner pays rent and co-signs
    #[account(mut)]
    pub owner: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct UpdateKya<'info> {
    #[account(
        seeds = [RegistryConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, RegistryConfig>,

    #[account(
        mut,
        seeds = [AgentProfile::SEED, profile.agent.as_ref()],
        bump = profile.bump,
    )]
    pub profile: Account<'info, AgentProfile>,

    /// Must be admin or oracle — checked in handler
    pub authority: Signer<'info>,
}

#[derive(Accounts)]
pub struct UpdateCreditScore<'info> {
    #[account(
        seeds = [RegistryConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, RegistryConfig>,

    #[account(
        mut,
        seeds = [AgentProfile::SEED, profile.agent.as_ref()],
        bump = profile.bump,
    )]
    pub profile: Account<'info, AgentProfile>,

    /// Must be the oracle
    pub authority: Signer<'info>,
}

#[derive(Accounts)]
pub struct UpdateAgentStats<'info> {
    #[account(
        seeds = [RegistryConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, RegistryConfig>,

    #[account(
        mut,
        seeds = [AgentProfile::SEED, profile.agent.as_ref()],
        bump = profile.bump,
    )]
    pub profile: Account<'info, AgentProfile>,

    /// Must equal config.wallet_program — the only authorised caller
    /// WalletConfig PDA derived from ["wallet_config"] seed and the wallet program
    #[account(
        seeds = [b"wallet_config"],
        seeds::program = config.wallet_program,
        bump,
    )]
    pub wallet_program_authority: Signer<'info>,
}

#[derive(Accounts)]
pub struct RecordLiquidation<'info> {
    #[account(
        seeds = [RegistryConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, RegistryConfig>,

    #[account(
        mut,
        seeds = [AgentProfile::SEED, profile.agent.as_ref()],
        bump = profile.bump,
    )]
    pub profile: Account<'info, AgentProfile>,

    /// WalletConfig PDA derived from ["wallet_config"] seed and the wallet program
    #[account(
        seeds = [b"wallet_config"],
        seeds::program = config.wallet_program,
        bump,
    )]
    pub wallet_program_authority: Signer<'info>,
}

#[derive(Accounts)]
pub struct LinkWallet<'info> {
    #[account(
        seeds = [RegistryConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, RegistryConfig>,

    #[account(
        mut,
        seeds = [AgentProfile::SEED, profile.agent.as_ref()],
        bump = profile.bump,
    )]
    pub profile: Account<'info, AgentProfile>,

    /// WalletConfig PDA derived from ["wallet_config"] seed and the wallet program
    #[account(
        seeds = [b"wallet_config"],
        seeds::program = config.wallet_program,
        bump,
    )]
    pub wallet_program_authority: Signer<'info>,
}

#[derive(Accounts)]
pub struct DeactivateAgent<'info> {
    #[account(
        seeds = [RegistryConfig::SEED],
        bump = config.bump,
        has_one = admin @ RegistryError::NotAdmin,
    )]
    pub config: Account<'info, RegistryConfig>,

    #[account(
        mut,
        seeds = [AgentProfile::SEED, profile.agent.as_ref()],
        bump = profile.bump,
    )]
    pub profile: Account<'info, AgentProfile>,

    pub admin: Signer<'info>,
}

#[derive(Accounts)]
pub struct SignLegalAgreement<'info> {
    #[account(
        seeds = [RegistryConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, RegistryConfig>,

    #[account(
        mut,
        seeds = [AgentProfile::SEED, profile.agent.as_ref()],
        bump = profile.bump,
    )]
    pub profile: Account<'info, AgentProfile>,

    /// Must be the agent keypair or the owner — dual-auth pattern
    #[account(
        constraint = authority.key() == profile.agent || authority.key() == profile.owner
            @ RegistryError::NotAdminOrOracle
    )]
    pub authority: Signer<'info>,
}

#[derive(Accounts)]
pub struct AttestScore<'info> {
    #[account(
        seeds = [RegistryConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, RegistryConfig>,

    #[account(
        mut,
        seeds = [AgentProfile::SEED, profile.agent.as_ref()],
        bump = profile.bump,
    )]
    pub profile: Account<'info, AgentProfile>,

    /// Must be the oracle — checked in handler
    pub authority: Signer<'info>,
}

#[derive(Accounts)]
pub struct UpdateRegistryConfig<'info> {
    #[account(
        mut,
        seeds = [RegistryConfig::SEED],
        bump = config.bump,
        has_one = admin @ RegistryError::NotAdmin,
    )]
    pub config: Account<'info, RegistryConfig>,

    pub admin: Signer<'info>,
}

#[derive(Accounts)]
pub struct MigrateProfileV2<'info> {
    /// CHECK: Raw account — realloc'd manually to avoid deserialization failure on v1 layout
    #[account(
        mut,
        seeds = [AgentProfile::SEED, agent.key().as_ref()],
        bump,
    )]
    pub profile: AccountInfo<'info>,

    pub agent: Signer<'info>,

    #[account(mut)]
    pub payer: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct ProposeProfileTransfer<'info> {
    #[account(seeds = [RegistryConfig::SEED], bump = config.bump)]
    pub config: Account<'info, RegistryConfig>,

    #[account(
        mut,
        seeds = [AgentProfile::SEED, profile.agent.as_ref()],
        bump = profile.bump,
        has_one = owner @ RegistryError::NotAdminOrOracle,
    )]
    pub profile: Account<'info, AgentProfile>,

    #[account(
        init,
        payer = owner,
        space = ProfileOwnershipTransfer::LEN,
        seeds = [ProfileOwnershipTransfer::SEED, profile.agent.as_ref()],
        bump,
    )]
    pub transfer_request: Account<'info, ProfileOwnershipTransfer>,

    #[account(mut)]
    pub owner: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct AcceptProfileTransfer<'info> {
    #[account(seeds = [RegistryConfig::SEED], bump = config.bump)]
    pub config: Account<'info, RegistryConfig>,

    #[account(
        mut,
        seeds = [AgentProfile::SEED, profile.agent.as_ref()],
        bump = profile.bump,
    )]
    pub profile: Account<'info, AgentProfile>,

    #[account(
        mut,
        seeds = [ProfileOwnershipTransfer::SEED, profile.agent.as_ref()],
        bump = transfer_request.bump,
        constraint = transfer_request.proposed_owner == new_owner.key() @ RegistryError::NotPendingOwner,
        close = rent_receiver,
    )]
    pub transfer_request: Account<'info, ProfileOwnershipTransfer>,

    pub new_owner: Signer<'info>,

    /// CHECK: receives rent refund from closed ProfileOwnershipTransfer PDA
    #[account(mut)]
    pub rent_receiver: AccountInfo<'info>,
}

#[derive(Accounts)]
pub struct CancelProfileTransfer<'info> {
    #[account(seeds = [RegistryConfig::SEED], bump = config.bump)]
    pub config: Account<'info, RegistryConfig>,

    #[account(
        seeds = [AgentProfile::SEED, profile.agent.as_ref()],
        bump = profile.bump,
        has_one = owner @ RegistryError::NotAdminOrOracle,
    )]
    pub profile: Account<'info, AgentProfile>,

    #[account(
        mut,
        seeds = [ProfileOwnershipTransfer::SEED, profile.agent.as_ref()],
        bump = transfer_request.bump,
        close = owner,
    )]
    pub transfer_request: Account<'info, ProfileOwnershipTransfer>,

    #[account(mut)]
    pub owner: Signer<'info>,
}
