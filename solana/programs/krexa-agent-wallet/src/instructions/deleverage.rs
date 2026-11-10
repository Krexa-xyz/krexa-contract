use anchor_lang::prelude::*;
use crate::{Deleverage, WalletError};
use crate::events::Deleveraged;
use crate::utils::health::{compute_nav, nav_warning_for_level};

pub fn handle(ctx: Context<Deleverage>) -> Result<()> {
    let wallet_usdc_balance = ctx.accounts.wallet_usdc.amount;
    let vault_cfg = &ctx.accounts.vault_config;
    let wallet = &ctx.accounts.agent_wallet;

    let live_nav = compute_nav(
        wallet_usdc_balance,
        wallet.collateral_shares,
        vault_cfg.total_deposits,
        vault_cfg.total_shares,
        wallet.credit_limit, // NAV = V(t) / C₀
    );

    // Deleverage triggers when NAV drops below per-level warning threshold
    let warning = nav_warning_for_level(wallet.credit_level);
    require!(live_nav < warning, WalletError::HealthFactorHealthy);
    require!(!wallet.is_liquidating, WalletError::WalletLiquidating);

    let health_before = ctx.accounts.agent_wallet.health_factor_bps;
    let now = Clock::get()?.unix_timestamp;
    let wallet = &mut ctx.accounts.agent_wallet;
    wallet.is_frozen = true;
    wallet.health_factor_bps = live_nav;
    wallet.last_health_check = now;

    emit!(Deleveraged { agent: wallet.agent, health_before });
    Ok(())
}
