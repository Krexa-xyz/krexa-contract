use anchor_lang::prelude::*;
use crate::{CreateWallet, WalletConfig, WalletError};
use crate::events::WalletCreated;

pub fn handle(ctx: Context<CreateWallet>, daily_spend_limit: u64, owner_type: u8) -> Result<()> {
    // SOL-022 fix: Respect pause status
    require!(!ctx.accounts.config.is_paused, WalletError::Paused);

    let profile = &ctx.accounts.agent_profile;

    require!(profile.credit_level >= 1, WalletError::AgentNotEligible);
    require!(!profile.has_wallet, WalletError::WalletAlreadyExists);
    require!(profile.is_active, WalletError::AgentNotEligible);

    let now = Clock::get()?.unix_timestamp;
    let wallet = &mut ctx.accounts.agent_wallet;
    wallet.agent = ctx.accounts.agent.key();
    wallet.owner = ctx.accounts.owner.key();
    wallet.config = ctx.accounts.config.key();
    wallet.wallet_usdc = ctx.accounts.wallet_usdc.key();
    wallet.collateral_shares = 0;
    wallet.credit_limit = 0;
    wallet.credit_drawn = 0;
    wallet.total_debt = 0;
    wallet.daily_spend_limit = daily_spend_limit;
    wallet.daily_spent = 0;
    wallet.last_daily_reset = now;
    wallet.health_factor_bps = u16::MAX;
    wallet.last_health_check = now;
    wallet.credit_level = profile.credit_level;
    wallet.is_frozen = false;
    wallet.is_liquidating = false;
    wallet.total_trades = 0;
    wallet.total_volume = 0;
    wallet.total_repaid = 0;
    wallet.created_at = now;
    wallet.bump = ctx.bumps.agent_wallet;
    wallet.usdc_bump = ctx.bumps.wallet_usdc;
    wallet.owner_type = owner_type;

    ctx.accounts.config.total_wallets =
        ctx.accounts.config.total_wallets.saturating_add(1);

    let config_bump = ctx.accounts.config.bump;
    let config_seeds: &[&[&[u8]]] = &[&[WalletConfig::SEED, &[config_bump]]];

    krexa_agent_registry::cpi::link_wallet(
        CpiContext::new_with_signer(
            ctx.accounts.registry_program.to_account_info(),
            krexa_agent_registry::cpi::accounts::LinkWallet {
                config: ctx.accounts.registry_config.to_account_info(),
                profile: ctx.accounts.agent_profile.to_account_info(),
                wallet_program_authority: ctx.accounts.config.to_account_info(),
            },
            config_seeds,
        ),
        ctx.accounts.agent_wallet.key(),
    )?;

    emit!(WalletCreated {
        agent: ctx.accounts.agent.key(),
        owner: ctx.accounts.owner.key(),
        wallet_pda: ctx.accounts.agent_wallet.key(),
    });

    Ok(())
}
