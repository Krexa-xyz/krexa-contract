use anchor_lang::prelude::*;
use crate::CheckHealth;
use crate::events::HealthChecked;
use crate::utils::health::{compute_nav, collateral_value_usdc, nav_trigger_for_level, nav_warning_for_level};

pub fn handle(ctx: Context<CheckHealth>) -> Result<()> {
    let wallet_usdc_balance = ctx.accounts.wallet_usdc.amount;
    let vault_cfg = &ctx.accounts.vault_config;

    let collateral_val = collateral_value_usdc(
        ctx.accounts.agent_wallet.collateral_shares,
        vault_cfg.total_deposits,
        vault_cfg.total_shares,
    );
    let credit_limit = ctx.accounts.agent_wallet.credit_limit;
    let nav = compute_nav(
        wallet_usdc_balance,
        ctx.accounts.agent_wallet.collateral_shares,
        vault_cfg.total_deposits,
        vault_cfg.total_shares,
        credit_limit, // NAV = V(t) / C₀
    );

    let now = Clock::get()?.unix_timestamp;
    let wallet = &mut ctx.accounts.agent_wallet;
    wallet.health_factor_bps = nav;
    wallet.last_health_check = now;

    // Auto-freeze when NAV drops below per-level warning threshold
    let warning = nav_warning_for_level(wallet.credit_level);
    if nav < warning && !wallet.is_frozen && wallet.credit_limit > 0 {
        wallet.is_frozen = true;
    }

    // Auto-unfreeze when NAV recovers well above warning (trigger + 10% buffer)
    let healthy = nav_trigger_for_level(wallet.credit_level).saturating_add(1_000);
    if nav >= healthy && wallet.is_frozen && !wallet.is_liquidating {
        wallet.is_frozen = false;
    }

    emit!(HealthChecked {
        agent: wallet.agent,
        health_factor_bps: nav,
        wallet_usdc: wallet_usdc_balance,
        collateral_value: collateral_val,
        total_debt: wallet.total_debt,
    });
    Ok(())
}
