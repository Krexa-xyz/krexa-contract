use anchor_lang::prelude::*;
use anchor_spl::token::{self, Transfer};
use crate::{Withdraw, AgentWallet, WalletError};
use crate::events::Withdrawal;
use crate::utils::{max_withdrawable, collateral_value_usdc};
use crate::utils::health::compute_nav;

pub fn handle(ctx: Context<Withdraw>, amount: u64) -> Result<()> {
    require!(!ctx.accounts.config.is_paused, WalletError::Paused);
    require!(amount > 0, WalletError::ZeroAmount);

    {
        let wallet = &ctx.accounts.agent_wallet;
        require!(!wallet.is_frozen, WalletError::WalletFrozen);
        require!(!wallet.is_liquidating, WalletError::WalletLiquidating);

        let wallet_balance = ctx.accounts.wallet_usdc.amount;
        require!(wallet_balance >= amount, WalletError::InsufficientBalance);

        let vault_cfg = &ctx.accounts.vault_config;
        let coll_val = collateral_value_usdc(
            wallet.collateral_shares,
            vault_cfg.total_deposits,
            vault_cfg.total_shares,
        );
        let max_out = max_withdrawable(wallet_balance, coll_val, wallet.total_debt);
        require!(amount <= max_out, WalletError::WithdrawalGate);
    }

    let agent_key = ctx.accounts.agent_wallet.agent;
    let wallet_bump = ctx.accounts.agent_wallet.bump;
    let wallet_seeds: &[&[&[u8]]] = &[&[AgentWallet::SEED, agent_key.as_ref(), &[wallet_bump]]];

    token::transfer(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            Transfer {
                from: ctx.accounts.wallet_usdc.to_account_info(),
                to: ctx.accounts.owner_usdc.to_account_info(),
                authority: ctx.accounts.agent_wallet.to_account_info(),
            },
            wallet_seeds,
        ),
        amount,
    )?;

    // SOL-024 fix: Reload balance after transfer to get accurate post-transfer amount
    ctx.accounts.wallet_usdc.reload()?;
    let now = Clock::get()?.unix_timestamp;
    let new_balance = ctx.accounts.wallet_usdc.amount;
    let vault_cfg = &ctx.accounts.vault_config;
    let wallet = &mut ctx.accounts.agent_wallet;

    wallet.health_factor_bps = compute_nav(
        new_balance,
        wallet.collateral_shares,
        vault_cfg.total_deposits,
        vault_cfg.total_shares,
        wallet.credit_limit, // NAV = V(t) / C₀
    );
    wallet.last_health_check = now;

    emit!(Withdrawal {
        agent: wallet.agent,
        amount,
        remaining_debt: wallet.total_debt,
        health_after: wallet.health_factor_bps,
    });
    Ok(())
}
