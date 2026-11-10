use anchor_lang::prelude::*;
use anchor_spl::token::{self, Transfer};
use crate::{Repay, AgentWallet, WalletConfig, WalletError};
use crate::events::Repaid;
use crate::utils::health::compute_nav;

pub fn handle(ctx: Context<Repay>, amount: u64) -> Result<()> {
    // SOL-066 fix: gate repay behind pause check
    require!(!ctx.accounts.config.is_paused, WalletError::Paused);
    require!(amount > 0, WalletError::ZeroAmount);

    {
        let wallet = &ctx.accounts.agent_wallet;
        require!(!wallet.is_liquidating, WalletError::WalletLiquidating);
        require!(wallet.credit_drawn > 0 || wallet.total_debt > 0, WalletError::NoCreditLine);
        require!(ctx.accounts.wallet_usdc.amount >= amount, WalletError::InsufficientBalance);
    }

    let agent_key = ctx.accounts.agent_wallet.agent;
    let wallet_bump = ctx.accounts.agent_wallet.bump;
    let wallet_seeds: &[&[&[u8]]] = &[&[AgentWallet::SEED, agent_key.as_ref(), &[wallet_bump]]];

    token::transfer(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            Transfer {
                from: ctx.accounts.wallet_usdc.to_account_info(),
                to: ctx.accounts.vault_token.to_account_info(),
                authority: ctx.accounts.agent_wallet.to_account_info(),
            },
            wallet_seeds,
        ),
        amount,
    )?;

    let config_bump = ctx.accounts.config.bump;
    let config_seeds: &[&[&[u8]]] = &[&[WalletConfig::SEED, &[config_bump]]];

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
        agent_key,
        amount,
    )?;

    krexa_agent_registry::cpi::update_agent_stats(
        CpiContext::new_with_signer(
            ctx.accounts.registry_program.to_account_info(),
            krexa_agent_registry::cpi::accounts::UpdateAgentStats {
                config: ctx.accounts.registry_config.to_account_info(),
                profile: ctx.accounts.agent_profile.to_account_info(),
                wallet_program_authority: ctx.accounts.config.to_account_info(),
            },
            config_seeds,
        ),
        0, 0, amount, 0,
    )?;

    ctx.accounts.credit_line.reload()?;
    let cl = &ctx.accounts.credit_line;
    let credit_cleared = !cl.is_active;
    let new_total_debt = cl.credit_drawn.saturating_add(cl.accrued_interest);

    let vault_cfg = &ctx.accounts.vault_config;
    let new_wallet_balance = ctx.accounts.wallet_usdc.amount.saturating_sub(amount);
    // NAV = V(t) / C₀ — use credit_limit (original credit) as denominator
    // After repayment, credit_limit may have been cleared — use the reloaded value
    let nav_denominator = if cl.is_active {
        ctx.accounts.agent_wallet.credit_limit
    } else {
        1 // credit cleared — NAV is infinite, will clamp to u16::MAX
    };
    let hf = compute_nav(
        new_wallet_balance,
        ctx.accounts.agent_wallet.collateral_shares,
        vault_cfg.total_deposits,
        vault_cfg.total_shares,
        nav_denominator,
    );

    let wallet = &mut ctx.accounts.agent_wallet;
    wallet.credit_drawn = cl.credit_drawn;
    wallet.total_debt = new_total_debt;
    wallet.total_repaid = wallet.total_repaid.saturating_add(amount);
    wallet.health_factor_bps = hf;
    wallet.last_health_check = Clock::get()?.unix_timestamp;
    if credit_cleared { wallet.credit_limit = 0; }

    emit!(Repaid { agent: wallet.agent, amount, remaining_debt: new_total_debt, credit_cleared });
    Ok(())
}
