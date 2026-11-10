use anchor_lang::prelude::*;
use anchor_spl::token::{self, Transfer};
use krexa_common::constants::{MAX_PER_VENUE_BPS, BPS_DENOMINATOR};
use crate::{ExecuteTrade, AgentWallet, VenueExposure, WalletError};
use crate::events::TradeExecuted;
use crate::utils::{check_per_trade_limit, maybe_reset_daily, projected_health};
use crate::utils::health::nav_warning_for_level;

pub fn handle(
    ctx: Context<ExecuteTrade>,
    venue_program_id: Pubkey,
    amount: u64,
    _trade_data: Vec<u8>,
) -> Result<()> {
    require!(!ctx.accounts.config.is_paused, WalletError::Paused);
    require!(amount > 0, WalletError::ZeroAmount);

    let wallet_balance = ctx.accounts.wallet_usdc.amount;

    {
        let wallet = &ctx.accounts.agent_wallet;
        require!(!wallet.is_frozen, WalletError::WalletFrozen);
        require!(!wallet.is_liquidating, WalletError::WalletLiquidating);

        // Safety check 3: per-trade limit (20% of balance)
        require!(check_per_trade_limit(amount, wallet_balance), WalletError::ExceedsPerTradeLimit);

        // Safety check 4: daily spend limit
        let now = Clock::get()?.unix_timestamp;
        let (new_daily_spent, _) = maybe_reset_daily(wallet.daily_spent, wallet.last_daily_reset, now);
        require!(
            new_daily_spent.saturating_add(amount) <= wallet.daily_spend_limit,
            WalletError::DailyLimitExceeded
        );

        // Safety check 5: per-venue exposure limit (50% of wallet value)
        let venue_exp = &ctx.accounts.venue_exposure;
        let new_venue_total = venue_exp.total_sent.saturating_add(amount);
        let max_venue = (wallet_balance as u128 * MAX_PER_VENUE_BPS as u128
            / BPS_DENOMINATOR as u128) as u64;
        require!(new_venue_total <= max_venue, WalletError::ExceedsVenueLimit);

        // Safety check 6: NAV check — ensure NAV stays above per-level warning threshold
        if wallet.credit_limit > 0 {
            let vault_cfg = &ctx.accounts.vault_config;
            let post_nav = projected_health(
                wallet_balance,
                amount,
                wallet.collateral_shares,
                vault_cfg.total_deposits,
                vault_cfg.total_shares,
                wallet.credit_limit, // C₀ — original credit, not total_debt
            );
            let warning_threshold = nav_warning_for_level(wallet.credit_level);
            require!(post_nav >= warning_threshold, WalletError::HealthTooLow);
        }
    }

    let agent_key = ctx.accounts.agent_wallet.agent;
    let wallet_bump = ctx.accounts.agent_wallet.bump;
    let wallet_seeds: &[&[&[u8]]] = &[&[AgentWallet::SEED, agent_key.as_ref(), &[wallet_bump]]];

    token::transfer(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            Transfer {
                from: ctx.accounts.wallet_usdc.to_account_info(),
                to: ctx.accounts.venue_token.to_account_info(),
                authority: ctx.accounts.agent_wallet.to_account_info(),
            },
            wallet_seeds,
        ),
        amount,
    )?;

    // Initialize VenueExposure fields if this is a new account (total_sent == 0 and agent is default)
    let venue_exp = &mut ctx.accounts.venue_exposure;
    if venue_exp.agent == Pubkey::default() {
        venue_exp.agent = agent_key;
        venue_exp.venue = venue_program_id;
        venue_exp.bump = ctx.bumps.venue_exposure;
    }
    venue_exp.total_sent = venue_exp.total_sent.saturating_add(amount);

    let now = Clock::get()?.unix_timestamp;
    let wallet = &mut ctx.accounts.agent_wallet;
    let (new_daily_spent, new_reset) = maybe_reset_daily(wallet.daily_spent, wallet.last_daily_reset, now);
    wallet.daily_spent = new_daily_spent.saturating_add(amount);
    wallet.last_daily_reset = new_reset;
    wallet.total_trades = wallet.total_trades.saturating_add(1);
    wallet.total_volume = wallet.total_volume.saturating_add(amount);

    if wallet.credit_limit > 0 {
        let vault_cfg = &ctx.accounts.vault_config;
        wallet.health_factor_bps = projected_health(
            wallet_balance, amount,
            wallet.collateral_shares,
            vault_cfg.total_deposits, vault_cfg.total_shares,
            wallet.credit_limit, // NAV = V(t) / C₀
        );
    }
    wallet.last_health_check = now;

    emit!(TradeExecuted {
        agent: wallet.agent,
        venue: venue_program_id,
        amount,
        health_after: wallet.health_factor_bps,
        daily_spent: wallet.daily_spent,
    });
    Ok(())
}
