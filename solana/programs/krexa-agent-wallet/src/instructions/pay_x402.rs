use anchor_lang::prelude::*;
use anchor_spl::token::{self, Transfer};
use crate::{PayX402, AgentWallet, WalletError};
use crate::events::X402Payment;
use crate::utils::{check_per_trade_limit, maybe_reset_daily, projected_health};
use crate::utils::health::nav_warning_for_level;
use krexa_common::constants::{PLATFORM_FEE_BPS, BPS_DENOMINATOR};

pub fn handle(
    ctx: Context<PayX402>,
    facilitator: Pubkey,
    recipient: Pubkey,
    amount: u64,
    memo: [u8; 32],
) -> Result<()> {
    require!(!ctx.accounts.config.is_paused, WalletError::Paused);
    require!(amount > 0, WalletError::ZeroAmount);

    let wallet_balance = ctx.accounts.wallet_usdc.amount;

    {
        let wallet = &ctx.accounts.agent_wallet;
        require!(!wallet.is_frozen, WalletError::WalletFrozen);
        require!(!wallet.is_liquidating, WalletError::WalletLiquidating);
        require!(check_per_trade_limit(amount, wallet_balance), WalletError::ExceedsPerTradeLimit);

        let now = Clock::get()?.unix_timestamp;
        let (new_daily_spent, _) = maybe_reset_daily(wallet.daily_spent, wallet.last_daily_reset, now);
        require!(
            new_daily_spent.saturating_add(amount) <= wallet.daily_spend_limit,
            WalletError::DailyLimitExceeded
        );

        if wallet.credit_limit > 0 {
            let vault_cfg = &ctx.accounts.vault_config;
            let post_nav = projected_health(
                wallet_balance, amount,
                wallet.collateral_shares,
                vault_cfg.total_deposits, vault_cfg.total_shares,
                wallet.credit_limit, // NAV = V(t) / C₀
            );
            let warning_threshold = nav_warning_for_level(wallet.credit_level);
            require!(post_nav >= warning_threshold, WalletError::HealthTooLow);
        }
    }

    // SOL-013 fix: Deduct platform fee from payment (was missing — protocol earned zero).
    let platform_fee = (amount as u128 * PLATFORM_FEE_BPS as u128
        / BPS_DENOMINATOR as u128) as u64;
    let net_amount = amount.saturating_sub(platform_fee);

    let agent_key = ctx.accounts.agent_wallet.agent;
    let wallet_bump = ctx.accounts.agent_wallet.bump;
    let wallet_seeds: &[&[&[u8]]] = &[&[AgentWallet::SEED, agent_key.as_ref(), &[wallet_bump]]];

    // Transfer net amount to facilitator
    if net_amount > 0 {
        token::transfer(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                Transfer {
                    from: ctx.accounts.wallet_usdc.to_account_info(),
                    to: ctx.accounts.facilitator_token.to_account_info(),
                    authority: ctx.accounts.agent_wallet.to_account_info(),
                },
                wallet_seeds,
            ),
            net_amount,
        )?;
    }

    // Transfer platform fee to treasury
    if platform_fee > 0 {
        token::transfer(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                Transfer {
                    from: ctx.accounts.wallet_usdc.to_account_info(),
                    to: ctx.accounts.platform_treasury_token.to_account_info(),
                    authority: ctx.accounts.agent_wallet.to_account_info(),
                },
                wallet_seeds,
            ),
            platform_fee,
        )?;
    }

    let now = Clock::get()?.unix_timestamp;
    let wallet = &mut ctx.accounts.agent_wallet;
    let (new_daily_spent, new_reset) = maybe_reset_daily(wallet.daily_spent, wallet.last_daily_reset, now);
    wallet.daily_spent = new_daily_spent.saturating_add(amount);
    wallet.last_daily_reset = new_reset;
    wallet.total_trades = wallet.total_trades.saturating_add(1);
    wallet.total_volume = wallet.total_volume.saturating_add(amount);
    wallet.last_health_check = now;

    // SOL-012 fix: Update NAV after spending (was missing — unlike execute_trade)
    if wallet.credit_limit > 0 {
        let vault_cfg = &ctx.accounts.vault_config;
        ctx.accounts.wallet_usdc.reload()?;
        wallet.health_factor_bps = crate::utils::health::compute_nav(
            ctx.accounts.wallet_usdc.amount,
            wallet.collateral_shares,
            vault_cfg.total_deposits,
            vault_cfg.total_shares,
            wallet.credit_limit, // NAV = V(t) / C₀
        );
    }

    emit!(X402Payment { agent: wallet.agent, facilitator, recipient, amount, memo });
    Ok(())
}
