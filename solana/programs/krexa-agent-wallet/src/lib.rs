//! # krexa-agent-wallet (THE CORE)
//!
//! PDA wallets for AI agents. 8 safety layers on every outbound payment.
//! Collateral earns yield in the credit vault. Full liquidation lifecycle.

use anchor_lang::prelude::*;
use anchor_spl::token::{Mint, Token, TokenAccount};
use krexa_agent_registry::{AgentProfile, RegistryConfig};
use krexa_credit_vault::{VaultConfig, DepositPosition, CreditLine};
use krexa_venue_whitelist::WhitelistedVenue;
use krexa_agent_registry::program::KrexaAgentRegistry;
use krexa_credit_vault::program::KrexaCreditVault;

pub mod state;
pub mod events;
pub mod errors;
pub mod instructions;
pub mod utils;

pub use state::*;
pub use events::*;
pub use errors::WalletError;
pub use state::{OwnershipTransfer};

declare_id!("FZoibjoRvbSTqR46XfKkkX6ZLRugZvGoV82NJBatt5fu");

// ═════════════════════════════════════════════════════════════════════════════
// ACCOUNTS STRUCTS — must be defined at crate root for #[program] macro
// ═════════════════════════════════════════════════════════════════════════════

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(
        init,
        payer = admin,
        space = WalletConfig::LEN,
        seeds = [WalletConfig::SEED],
        bump,
    )]
    pub config: Account<'info, WalletConfig>,

    /// SOL-009 fix: Validate usdc_mint is a real SPL Mint account
    pub usdc_mint: Account<'info, Mint>,

    /// Platform treasury token account for x402 fee capture.
    #[account(token::mint = usdc_mint)]
    pub platform_treasury: Account<'info, TokenAccount>,

    #[account(mut)]
    pub admin: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct CreateWallet<'info> {
    // Box<> prevents stack overflow — WalletConfig is 290 bytes
    #[account(
        mut,
        seeds = [WalletConfig::SEED],
        bump = config.bump,
    )]
    pub config: Box<Account<'info, WalletConfig>>,

    // Box<> prevents stack overflow — AgentWallet is 255 bytes
    #[account(
        init,
        payer = owner,
        space = AgentWallet::LEN,
        seeds = [AgentWallet::SEED, agent.key().as_ref()],
        bump,
    )]
    pub agent_wallet: Box<Account<'info, AgentWallet>>,

    #[account(
        init,
        payer = owner,
        token::mint = usdc_mint,
        token::authority = agent_wallet,
        seeds = [AgentWallet::USDC_SEED, agent.key().as_ref()],
        bump,
    )]
    pub wallet_usdc: Box<Account<'info, TokenAccount>>,

    /// CHECK: USDC mint address validated against config.usdc_mint
    #[account(address = config.usdc_mint)]
    pub usdc_mint: UncheckedAccount<'info>,

    /// CHECK: RegistryConfig PDA — validated by the krexa-agent-registry CPI
    pub registry_config: AccountInfo<'info>,

    // Box<> prevents stack overflow — AgentProfile is ~273 bytes
    #[account(
        mut,
        seeds = [b"agent_profile", agent.key().as_ref()],
        seeds::program = config.agent_registry_program,
        bump = agent_profile.bump,
    )]
    pub agent_profile: Box<Account<'info, AgentProfile>>,

    pub agent: Signer<'info>,

    #[account(mut)]
    pub owner: Signer<'info>,

    pub registry_program: Program<'info, KrexaAgentRegistry>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct Deposit<'info> {
    #[account(
        seeds = [WalletConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, WalletConfig>,

    #[account(
        mut,
        seeds = [AgentWallet::SEED, agent_wallet.agent.as_ref()],
        bump = agent_wallet.bump,
        has_one = owner @ WalletError::UnauthorizedOwner,
    )]
    pub agent_wallet: Account<'info, AgentWallet>,

    #[account(
        mut,
        seeds = [b"vault_config"],
        seeds::program = config.credit_vault_program,
        bump = vault_config.bump,
    )]
    pub vault_config: Account<'info, VaultConfig>,

    #[account(
        mut,
        address = vault_config.vault_token_account,
    )]
    pub vault_token: Account<'info, TokenAccount>,

    #[account(
        mut,
        seeds = [b"collateral", agent_wallet.agent.as_ref()],
        seeds::program = config.credit_vault_program,
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

    pub vault_program: Program<'info, KrexaCreditVault>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct RequestCredit<'info> {
    #[account(
        seeds = [WalletConfig::SEED],
        bump = config.bump,
    )]
    pub config: Box<Account<'info, WalletConfig>>,

    #[account(
        mut,
        seeds = [AgentWallet::SEED, agent_wallet.agent.as_ref()],
        bump = agent_wallet.bump,
    )]
    pub agent_wallet: Box<Account<'info, AgentWallet>>,

    #[account(
        mut,
        seeds = [AgentWallet::USDC_SEED, agent_wallet.agent.as_ref()],
        bump = agent_wallet.usdc_bump,
        address = agent_wallet.wallet_usdc,
    )]
    pub wallet_usdc: Box<Account<'info, TokenAccount>>,

    #[account(
        mut,
        seeds = [b"vault_config"],
        seeds::program = config.credit_vault_program,
        bump = vault_config.bump,
    )]
    pub vault_config: Box<Account<'info, VaultConfig>>,

    #[account(
        mut,
        address = vault_config.vault_token_account,
    )]
    pub vault_token: Box<Account<'info, TokenAccount>>,

    /// SOL-002 fix: Require collateral_position on-chain to compute collateral_value
    #[account(
        seeds = [b"collateral", agent_wallet.agent.as_ref()],
        seeds::program = config.credit_vault_program,
        bump,
    )]
    pub collateral_position: Box<Account<'info, DepositPosition>>,

    /// SOL-020 fix: Require agent_profile to validate credit_level on-chain
    #[account(
        seeds = [b"agent_profile", agent_wallet.agent.as_ref()],
        seeds::program = config.agent_registry_program,
        bump = agent_profile.bump,
        constraint = agent_profile.is_active @ WalletError::AgentNotEligible,
    )]
    pub agent_profile: Box<Account<'info, AgentProfile>>,

    /// CHECK: credit_line may not exist yet — created by vault.extend_credit CPI inside this ix.
    /// Seeds and discriminator are validated by the vault program during the CPI.
    #[account(mut)]
    pub credit_line: UncheckedAccount<'info>,

    #[account(mut, address = vault_config.oracle @ WalletError::NotOracle)]
    pub oracle: Signer<'info>,

    /// SOL-003 fix: Agent or owner must also sign credit requests (dual authorization)
    #[account(
        constraint = agent_or_owner.key() == agent_wallet.owner || agent_or_owner.key() == agent_wallet.agent @ WalletError::UnauthorizedOwner
    )]
    pub agent_or_owner: Signer<'info>,

    pub vault_program: Program<'info, KrexaCreditVault>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(venue_program_id: Pubkey)]
pub struct ExecuteTrade<'info> {
    #[account(
        seeds = [WalletConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, WalletConfig>,

    #[account(
        mut,
        seeds = [AgentWallet::SEED, agent_wallet.agent.as_ref()],
        bump = agent_wallet.bump,
        has_one = agent @ WalletError::UnauthorizedAgent,
    )]
    pub agent_wallet: Account<'info, AgentWallet>,

    #[account(
        mut,
        seeds = [AgentWallet::USDC_SEED, agent_wallet.agent.as_ref()],
        bump = agent_wallet.usdc_bump,
        address = agent_wallet.wallet_usdc,
    )]
    pub wallet_usdc: Account<'info, TokenAccount>,

    #[account(
        mut,
        token::mint = config.usdc_mint,
    )]
    pub venue_token: Account<'info, TokenAccount>,

    #[account(
        seeds = [b"venue", venue_program_id.as_ref()],
        seeds::program = config.venue_whitelist_program,
        bump = venue_entry.bump,
        constraint = venue_entry.is_active @ WalletError::VenueNotWhitelisted,
    )]
    pub venue_entry: Account<'info, WhitelistedVenue>,

    /// Per-venue exposure tracking — safety check 5 (50% per-venue limit)
    #[account(
        init_if_needed,
        payer = agent,
        space = VenueExposure::LEN,
        seeds = [VenueExposure::SEED, agent_wallet.agent.as_ref(), venue_program_id.as_ref()],
        bump,
    )]
    pub venue_exposure: Account<'info, VenueExposure>,

    #[account(
        seeds = [b"vault_config"],
        seeds::program = config.credit_vault_program,
        bump = vault_config.bump,
    )]
    pub vault_config: Account<'info, VaultConfig>,

    #[account(mut)]
    pub agent: Signer<'info>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(facilitator: Pubkey)]
pub struct PayX402<'info> {
    #[account(
        seeds = [WalletConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, WalletConfig>,

    #[account(
        mut,
        seeds = [AgentWallet::SEED, agent_wallet.agent.as_ref()],
        bump = agent_wallet.bump,
        has_one = agent @ WalletError::UnauthorizedAgent,
    )]
    pub agent_wallet: Account<'info, AgentWallet>,

    #[account(
        mut,
        seeds = [AgentWallet::USDC_SEED, agent_wallet.agent.as_ref()],
        bump = agent_wallet.usdc_bump,
        address = agent_wallet.wallet_usdc,
    )]
    pub wallet_usdc: Account<'info, TokenAccount>,

    #[account(
        mut,
        token::mint = config.usdc_mint,
        constraint = facilitator_token.owner == facilitator @ WalletError::InvalidFacilitatorToken,
    )]
    pub facilitator_token: Account<'info, TokenAccount>,

    /// SOL-013 fix: Platform treasury receives platform fee on x402 payments.
    /// SOL-058 fix: Validate this is the exact treasury token account stored in config.
    #[account(
        mut,
        address = config.platform_treasury @ WalletError::InvalidTreasury,
    )]
    pub platform_treasury_token: Account<'info, TokenAccount>,

    #[account(
        seeds = [b"venue", facilitator.as_ref()],
        seeds::program = config.venue_whitelist_program,
        bump = venue_entry.bump,
        constraint = venue_entry.is_active @ WalletError::VenueNotWhitelisted,
    )]
    pub venue_entry: Account<'info, WhitelistedVenue>,

    #[account(
        seeds = [b"vault_config"],
        seeds::program = config.credit_vault_program,
        bump = vault_config.bump,
    )]
    pub vault_config: Account<'info, VaultConfig>,

    pub agent: Signer<'info>,
    pub token_program: Program<'info, Token>,
}

#[derive(Accounts)]
pub struct Withdraw<'info> {
    #[account(
        seeds = [WalletConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, WalletConfig>,

    #[account(
        mut,
        seeds = [AgentWallet::SEED, agent_wallet.agent.as_ref()],
        bump = agent_wallet.bump,
        has_one = owner @ WalletError::UnauthorizedOwner,
    )]
    pub agent_wallet: Account<'info, AgentWallet>,

    #[account(
        mut,
        seeds = [AgentWallet::USDC_SEED, agent_wallet.agent.as_ref()],
        bump = agent_wallet.usdc_bump,
        address = agent_wallet.wallet_usdc,
    )]
    pub wallet_usdc: Account<'info, TokenAccount>,

    #[account(
        mut,
        token::mint = config.usdc_mint,
        token::authority = owner,
    )]
    pub owner_usdc: Account<'info, TokenAccount>,

    #[account(
        seeds = [b"vault_config"],
        seeds::program = config.credit_vault_program,
        bump = vault_config.bump,
    )]
    pub vault_config: Account<'info, VaultConfig>,

    pub owner: Signer<'info>,
    pub token_program: Program<'info, Token>,
}

#[derive(Accounts)]
pub struct Repay<'info> {
    #[account(
        seeds = [WalletConfig::SEED],
        bump = config.bump,
    )]
    pub config: Box<Account<'info, WalletConfig>>,

    #[account(
        mut,
        seeds = [AgentWallet::SEED, agent_wallet.agent.as_ref()],
        bump = agent_wallet.bump,
    )]
    pub agent_wallet: Box<Account<'info, AgentWallet>>,

    #[account(
        mut,
        seeds = [AgentWallet::USDC_SEED, agent_wallet.agent.as_ref()],
        bump = agent_wallet.usdc_bump,
        address = agent_wallet.wallet_usdc,
    )]
    pub wallet_usdc: Account<'info, TokenAccount>,

    #[account(
        mut,
        seeds = [b"vault_config"],
        seeds::program = config.credit_vault_program,
        bump = vault_config.bump,
    )]
    pub vault_config: Box<Account<'info, VaultConfig>>,

    #[account(
        mut,
        address = vault_config.vault_token_account,
    )]
    pub vault_token: Account<'info, TokenAccount>,

    #[account(
        mut,
        address = vault_config.insurance_token_account,
    )]
    pub insurance_token: Account<'info, TokenAccount>,

    #[account(
        mut,
        seeds = [b"credit_line", agent_wallet.agent.as_ref()],
        seeds::program = config.credit_vault_program,
        bump = credit_line.bump,
    )]
    pub credit_line: Box<Account<'info, CreditLine>>,

    #[account(
        seeds = [b"registry_config"],
        seeds::program = config.agent_registry_program,
        bump = registry_config.bump,
    )]
    pub registry_config: Box<Account<'info, RegistryConfig>>,

    #[account(
        mut,
        seeds = [b"agent_profile", agent_wallet.agent.as_ref()],
        seeds::program = config.agent_registry_program,
        bump = agent_profile.bump,
    )]
    pub agent_profile: Box<Account<'info, AgentProfile>>,

    /// SOL-001 fix: Only agent or owner may repay — caller must match one of them
    #[account(
        constraint = caller.key() == agent_wallet.owner || caller.key() == agent_wallet.agent @ WalletError::UnauthorizedOwner
    )]
    pub caller: Signer<'info>,

    pub vault_program: Program<'info, KrexaCreditVault>,
    pub registry_program: Program<'info, KrexaAgentRegistry>,
    pub token_program: Program<'info, Token>,
}

#[derive(Accounts)]
pub struct CheckHealth<'info> {
    #[account(
        seeds = [WalletConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, WalletConfig>,

    #[account(
        mut,
        seeds = [AgentWallet::SEED, agent_wallet.agent.as_ref()],
        bump = agent_wallet.bump,
    )]
    pub agent_wallet: Account<'info, AgentWallet>,

    #[account(address = agent_wallet.wallet_usdc)]
    pub wallet_usdc: Account<'info, TokenAccount>,

    #[account(
        seeds = [b"vault_config"],
        seeds::program = config.credit_vault_program,
        bump = vault_config.bump,
    )]
    pub vault_config: Account<'info, VaultConfig>,

    pub caller: Signer<'info>,
}

#[derive(Accounts)]
pub struct Deleverage<'info> {
    #[account(
        seeds = [WalletConfig::SEED],
        bump = config.bump,
        has_one = keeper @ WalletError::NotKeeper,
    )]
    pub config: Account<'info, WalletConfig>,

    #[account(
        mut,
        seeds = [AgentWallet::SEED, agent_wallet.agent.as_ref()],
        bump = agent_wallet.bump,
    )]
    pub agent_wallet: Account<'info, AgentWallet>,

    #[account(address = agent_wallet.wallet_usdc)]
    pub wallet_usdc: Account<'info, TokenAccount>,

    #[account(
        seeds = [b"vault_config"],
        seeds::program = config.credit_vault_program,
        bump = vault_config.bump,
    )]
    pub vault_config: Account<'info, VaultConfig>,

    pub keeper: Signer<'info>,
}

/// Liquidation is PERMISSIONLESS — any caller can trigger if NAV condition is met.
/// If the keeper goes down, anyone can call this to protect LP funds.
#[derive(Accounts)]
pub struct Liquidate<'info> {
    #[account(
        seeds = [WalletConfig::SEED],
        bump = config.bump,
    )]
    pub config: Box<Account<'info, WalletConfig>>,

    #[account(
        mut,
        seeds = [AgentWallet::SEED, agent_wallet.agent.as_ref()],
        bump = agent_wallet.bump,
    )]
    pub agent_wallet: Box<Account<'info, AgentWallet>>,

    #[account(
        mut,
        seeds = [AgentWallet::USDC_SEED, agent_wallet.agent.as_ref()],
        bump = agent_wallet.usdc_bump,
        address = agent_wallet.wallet_usdc,
    )]
    pub wallet_usdc: Account<'info, TokenAccount>,

    #[account(
        mut,
        seeds = [b"vault_config"],
        seeds::program = config.credit_vault_program,
        bump = vault_config.bump,
    )]
    pub vault_config: Box<Account<'info, VaultConfig>>,

    #[account(mut, address = vault_config.vault_token_account)]
    pub vault_token: Account<'info, TokenAccount>,

    #[account(mut, address = vault_config.insurance_token_account)]
    pub insurance_token: Account<'info, TokenAccount>,

    #[account(
        mut,
        seeds = [b"credit_line", agent_wallet.agent.as_ref()],
        seeds::program = config.credit_vault_program,
        bump = credit_line.bump,
    )]
    pub credit_line: Box<Account<'info, CreditLine>>,

    #[account(
        seeds = [b"registry_config"],
        seeds::program = config.agent_registry_program,
        bump = registry_config.bump,
    )]
    pub registry_config: Box<Account<'info, RegistryConfig>>,

    #[account(
        mut,
        seeds = [b"agent_profile", agent_wallet.agent.as_ref()],
        seeds::program = config.agent_registry_program,
        bump = agent_profile.bump,
    )]
    pub agent_profile: Box<Account<'info, AgentProfile>>,

    /// Liquidator's USDC account — receives keeper reward (0.5%)
    #[account(
        mut,
        token::mint = config.usdc_mint,
        constraint = liquidator_usdc.owner == liquidator.key() @ WalletError::UnauthorizedOwner,
    )]
    pub liquidator_usdc: Account<'info, TokenAccount>,

    /// owner_usdc must belong to the wallet's actual owner (surplus returned here)
    #[account(
        mut,
        token::mint = config.usdc_mint,
        constraint = owner_usdc.owner == agent_wallet.owner @ WalletError::UnauthorizedOwner,
    )]
    pub owner_usdc: Account<'info, TokenAccount>,

    /// PERMISSIONLESS: any signer can trigger liquidation if health condition is met
    pub liquidator: Signer<'info>,

    pub vault_program: Program<'info, KrexaCreditVault>,
    pub registry_program: Program<'info, KrexaAgentRegistry>,
    pub token_program: Program<'info, Token>,
}

#[derive(Accounts)]
pub struct FreezeWallet<'info> {
    #[account(
        seeds = [WalletConfig::SEED],
        bump = config.bump,
        has_one = admin @ WalletError::NotAdmin,
    )]
    pub config: Account<'info, WalletConfig>,

    #[account(
        mut,
        seeds = [AgentWallet::SEED, agent_wallet.agent.as_ref()],
        bump = agent_wallet.bump,
    )]
    pub agent_wallet: Account<'info, AgentWallet>,

    pub admin: Signer<'info>,
}

/// SOL-039 fix: Pause/unpause the program (admin-only)
#[derive(Accounts)]
pub struct PauseProgram<'info> {
    #[account(
        mut,
        seeds = [WalletConfig::SEED],
        bump = config.bump,
        has_one = admin @ WalletError::NotAdmin,
    )]
    pub config: Account<'info, WalletConfig>,
    pub admin: Signer<'info>,
}

/// SOL-040 fix: Update config (admin, keeper) — admin-only
#[derive(Accounts)]
pub struct UpdateConfig<'info> {
    #[account(
        mut,
        seeds = [WalletConfig::SEED],
        bump = config.bump,
        has_one = admin @ WalletError::NotAdmin,
    )]
    pub config: Account<'info, WalletConfig>,
    pub admin: Signer<'info>,
}

/// Admin-only: clear debt on orphaned wallets
#[derive(Accounts)]
pub struct AdminClearDebt<'info> {
    #[account(
        seeds = [WalletConfig::SEED],
        bump = config.bump,
        has_one = admin @ WalletError::NotAdmin,
    )]
    pub config: Account<'info, WalletConfig>,

    #[account(
        mut,
        seeds = [AgentWallet::SEED, agent_wallet.agent.as_ref()],
        bump = agent_wallet.bump,
    )]
    pub agent_wallet: Account<'info, AgentWallet>,

    pub admin: Signer<'info>,
}

//// Admin-only: reset cumulative venue exposure for an agent.
/// Fixes agents stuck by ExceedsVenueLimit (error 6030) after heavy trading.
#[derive(Accounts)]
#[instruction(agent: Pubkey, venue_program_id: Pubkey)]
pub struct ResetVenueExposure<'info> {
    #[account(
        seeds = [WalletConfig::SEED],
        bump = config.bump,
        has_one = admin @ WalletError::NotAdmin,
    )]
    pub config: Account<'info, WalletConfig>,

    #[account(
        mut,
        seeds = [VenueExposure::SEED, agent.as_ref(), venue_program_id.as_ref()],
        bump = venue_exposure.bump,
    )]
    pub venue_exposure: Account<'info, VenueExposure>,

    pub admin: Signer<'info>,
}

// SOL-041 fix: Update daily spend limit — owner-only
#[derive(Accounts)]
pub struct UpdateDailyLimit<'info> {
    #[account(
        seeds = [WalletConfig::SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, WalletConfig>,

    #[account(
        mut,
        seeds = [AgentWallet::SEED, agent_wallet.agent.as_ref()],
        bump = agent_wallet.bump,
        has_one = owner @ WalletError::UnauthorizedOwner,
    )]
    pub agent_wallet: Account<'info, AgentWallet>,

    pub owner: Signer<'info>,
}

#[derive(Accounts)]
pub struct ProposeOwnershipTransfer<'info> {
    #[account(seeds = [WalletConfig::SEED], bump = config.bump)]
    pub config: Account<'info, WalletConfig>,

    #[account(
        mut,
        seeds = [AgentWallet::SEED, agent_wallet.agent.as_ref()],
        bump = agent_wallet.bump,
        has_one = owner @ WalletError::UnauthorizedOwner,
    )]
    pub agent_wallet: Account<'info, AgentWallet>,

    #[account(
        init,
        payer = owner,
        space = OwnershipTransfer::LEN,
        seeds = [OwnershipTransfer::SEED, agent_wallet.agent.as_ref()],
        bump,
    )]
    pub transfer_request: Account<'info, OwnershipTransfer>,

    #[account(mut)]
    pub owner: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct AcceptOwnershipTransfer<'info> {
    #[account(seeds = [WalletConfig::SEED], bump = config.bump)]
    pub config: Account<'info, WalletConfig>,

    #[account(
        mut,
        seeds = [AgentWallet::SEED, agent_wallet.agent.as_ref()],
        bump = agent_wallet.bump,
    )]
    pub agent_wallet: Account<'info, AgentWallet>,

    #[account(
        mut,
        seeds = [OwnershipTransfer::SEED, agent_wallet.agent.as_ref()],
        bump = transfer_request.bump,
        constraint = transfer_request.proposed_owner == new_owner.key() @ WalletError::NotPendingOwner,
        close = rent_receiver,
    )]
    pub transfer_request: Account<'info, OwnershipTransfer>,

    pub new_owner: Signer<'info>,

    /// CHECK: receives rent refund from closed OwnershipTransfer PDA
    #[account(mut)]
    pub rent_receiver: AccountInfo<'info>,
}

#[derive(Accounts)]
pub struct CancelOwnershipTransfer<'info> {
    #[account(seeds = [WalletConfig::SEED], bump = config.bump)]
    pub config: Account<'info, WalletConfig>,

    #[account(
        seeds = [AgentWallet::SEED, agent_wallet.agent.as_ref()],
        bump = agent_wallet.bump,
        has_one = owner @ WalletError::UnauthorizedOwner,
    )]
    pub agent_wallet: Account<'info, AgentWallet>,

    #[account(
        mut,
        seeds = [OwnershipTransfer::SEED, agent_wallet.agent.as_ref()],
        bump = transfer_request.bump,
        close = owner,
    )]
    pub transfer_request: Account<'info, OwnershipTransfer>,

    #[account(mut)]
    pub owner: Signer<'info>,
}

// ═════════════════════════════════════════════════════════════════════════════
// PROGRAM MODULE
// ═════════════════════════════════════════════════════════════════════════════

#[program]
pub mod krexa_agent_wallet {
    use super::*;

    pub fn initialize(
        ctx: Context<Initialize>,
        keeper: Pubkey,
        credit_vault_program: Pubkey,
        agent_registry_program: Pubkey,
        venue_whitelist_program: Pubkey,
        payment_router_program: Pubkey,
    ) -> Result<()> {
        instructions::initialize::handle(
            ctx, keeper, credit_vault_program,
            agent_registry_program, venue_whitelist_program, payment_router_program,
        )
    }

    pub fn create_wallet(ctx: Context<CreateWallet>, daily_spend_limit: u64) -> Result<()> {
        instructions::create_wallet::handle(ctx, daily_spend_limit, 0)
    }

    /// Create a multisig-owned agent wallet (owner_type = 1).
    pub fn create_wallet_multisig(ctx: Context<CreateWallet>, daily_spend_limit: u64) -> Result<()> {
        instructions::create_wallet::handle(ctx, daily_spend_limit, 1)
    }

    pub fn deposit(ctx: Context<Deposit>, amount: u64) -> Result<()> {
        instructions::deposit::handle(ctx, amount)
    }

    pub fn request_credit(
        ctx: Context<RequestCredit>,
        amount: u64,
        rate_bps: u16,
        credit_level: u8,
        collateral_value: u64,
    ) -> Result<()> {
        instructions::request_credit::handle(ctx, amount, rate_bps, credit_level, collateral_value)
    }

    pub fn execute_trade(
        ctx: Context<ExecuteTrade>,
        venue_program_id: Pubkey,
        amount: u64,
        trade_data: Vec<u8>,
    ) -> Result<()> {
        instructions::execute_trade::handle(ctx, venue_program_id, amount, trade_data)
    }

    pub fn pay_x402(
        ctx: Context<PayX402>,
        facilitator: Pubkey,
        recipient: Pubkey,
        amount: u64,
        memo: [u8; 32],
    ) -> Result<()> {
        instructions::pay_x402::handle(ctx, facilitator, recipient, amount, memo)
    }

    pub fn withdraw(ctx: Context<Withdraw>, amount: u64) -> Result<()> {
        instructions::withdraw::handle(ctx, amount)
    }

    pub fn repay(ctx: Context<Repay>, amount: u64) -> Result<()> {
        instructions::repay::handle(ctx, amount)
    }

    pub fn check_health(ctx: Context<CheckHealth>) -> Result<()> {
        instructions::check_health::handle(ctx)
    }

    pub fn deleverage(ctx: Context<Deleverage>) -> Result<()> {
        instructions::deleverage::handle(ctx)
    }

    pub fn liquidate(ctx: Context<Liquidate>) -> Result<()> {
        instructions::liquidate::handle(ctx)
    }

    pub fn freeze_wallet(ctx: Context<FreezeWallet>) -> Result<()> {
        instructions::freeze::handle_freeze(ctx)
    }

    pub fn unfreeze_wallet(ctx: Context<FreezeWallet>) -> Result<()> {
        instructions::freeze::handle_unfreeze(ctx)
    }

    /// SOL-039: Pause the program — freezes all non-admin operations
    pub fn pause(ctx: Context<PauseProgram>) -> Result<()> {
        ctx.accounts.config.is_paused = true;
        Ok(())
    }

    /// SOL-039: Unpause the program
    pub fn unpause(ctx: Context<PauseProgram>) -> Result<()> {
        ctx.accounts.config.is_paused = false;
        Ok(())
    }

    /// SOL-040: Update config (admin rotation, keeper rotation)
    pub fn update_config(
        ctx: Context<UpdateConfig>,
        new_admin: Option<Pubkey>,
        new_keeper: Option<Pubkey>,
    ) -> Result<()> {
        let cfg = &mut ctx.accounts.config;
        // SOL-075 fix: prevent permanent lockout via zero-address admin/keeper
        if let Some(admin) = new_admin {
            require!(admin != Pubkey::default(), WalletError::InvalidAddress);
            cfg.admin = admin;
        }
        if let Some(keeper) = new_keeper {
            require!(keeper != Pubkey::default(), WalletError::InvalidAddress);
            cfg.keeper = keeper;
        }
        Ok(())
    }

    /// SOL-041: Update daily spend limit — owner-only
    pub fn update_daily_limit(ctx: Context<UpdateDailyLimit>, new_limit: u64) -> Result<()> {
        ctx.accounts.agent_wallet.daily_spend_limit = new_limit;
        Ok(())
    }

    /// Propose an ownership transfer to a new address.
    /// Creates a temporary OwnershipTransfer PDA for the proposed owner to accept.
    pub fn propose_ownership_transfer(
        ctx: Context<ProposeOwnershipTransfer>,
        new_owner: Pubkey,
        new_owner_type: u8,
    ) -> Result<()> {
        instructions::transfer_ownership::handle_propose(ctx, new_owner, new_owner_type)
    }

    /// Accept a pending ownership transfer. Must be signed by the proposed owner.
    pub fn accept_ownership_transfer(ctx: Context<AcceptOwnershipTransfer>) -> Result<()> {
        instructions::transfer_ownership::handle_accept(ctx)
    }

    /// Cancel a pending ownership transfer. Must be signed by the current owner.
    pub fn cancel_ownership_transfer(ctx: Context<CancelOwnershipTransfer>) -> Result<()> {
        instructions::transfer_ownership::handle_cancel(ctx)
    }

    /// Admin-only: clear debt on an agent wallet (for orphaned wallets missing credit_line PDAs)
    pub fn admin_clear_debt(ctx: Context<AdminClearDebt>) -> Result<()> {
        let wallet = &mut ctx.accounts.agent_wallet;
        wallet.credit_drawn = 0;
        wallet.total_debt = 0;
        Ok(())
    }

    /// Admin-only: reset cumulative venue exposure for an agent.
    /// Fixes agents blocked by ExceedsVenueLimit after heavy trading volume.
    pub fn reset_venue_exposure(
        ctx: Context<ResetVenueExposure>,
        _agent: Pubkey,
        _venue_program_id: Pubkey,
    ) -> Result<()> {
        ctx.accounts.venue_exposure.total_sent = 0;
        Ok(())
    }
}
