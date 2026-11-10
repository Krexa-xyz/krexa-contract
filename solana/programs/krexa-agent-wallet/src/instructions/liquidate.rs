use anchor_lang::prelude::*;
use anchor_spl::token::{self, Transfer};
use crate::{Liquidate, AgentWallet, WalletConfig, WalletError};
use crate::events::Liquidated;
use crate::utils::health::{compute_nav, nav_trigger_for_level};
use krexa_common::constants::{LIQUIDATION_REWARD_BPS, BPS_DENOMINATOR};

/// Liquidation is PERMISSIONLESS — any caller can trigger if health condition is met.
/// Canonical 6-step sequence:
///   1. FREEZE wallet (is_frozen + is_liquidating in same tx)
///   2. All non-USDC already sold (off-chain via Jupiter — wallet holds USDC only)
///   3. CALCULATE amounts (keeper_reward, repayable, shortfall, surplus)
///   4. DISTRIBUTE (keeper → vault → owner)
///   5. UPDATE agent record (score -40, credit_drawn=0, accrued_interest=0)
///   6. RETURN surplus to agent.owner
pub fn handle(ctx: Context<Liquidate>) -> Result<()> {
    let wallet_usdc_balance = ctx.accounts.wallet_usdc.amount;
    let vault_cfg = &ctx.accounts.vault_config;
    let wallet = &ctx.accounts.agent_wallet;

    // Step 1: Verify liquidation trigger — NAV(t) < τ_L(credit_level)
    let live_nav = compute_nav(
        wallet_usdc_balance,
        wallet.collateral_shares,
        vault_cfg.total_deposits,
        vault_cfg.total_shares,
        wallet.credit_limit, // C₀ — original credit amount
    );

    let nav_trigger = nav_trigger_for_level(wallet.credit_level);
    require!(live_nav < nav_trigger, WalletError::HealthAboveLiquidation);

    // Step 1: FREEZE — set both flags in same transaction as liquidation
    ctx.accounts.agent_wallet.is_frozen = true;
    ctx.accounts.agent_wallet.is_liquidating = true;

    // Step 3: CALCULATE amounts
    let total_debt = ctx.accounts.agent_wallet.total_debt;
    let keeper_reward = (wallet_usdc_balance as u128
        * LIQUIDATION_REWARD_BPS as u128
        / BPS_DENOMINATOR as u128) as u64;
    let available_for_repay = wallet_usdc_balance.saturating_sub(keeper_reward);
    let repay_amount = available_for_repay.min(total_debt);
    let shortfall = total_debt.saturating_sub(repay_amount);
    let returned_to_owner = wallet_usdc_balance.saturating_sub(keeper_reward).saturating_sub(repay_amount);

    let agent_key = ctx.accounts.agent_wallet.agent;
    let wallet_bump = ctx.accounts.agent_wallet.bump;
    let wallet_seeds: &[&[&[u8]]] = &[&[AgentWallet::SEED, agent_key.as_ref(), &[wallet_bump]]];

    // Step 4: DISTRIBUTE — repayment through waterfall
    if repay_amount > 0 {
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
            repay_amount,
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
            repay_amount,
        )?;
    }

    // Step 4: DISTRIBUTE — keeper reward (0.5% of total recovered)
    if keeper_reward > 0 {
        token::transfer(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                Transfer {
                    from: ctx.accounts.wallet_usdc.to_account_info(),
                    to: ctx.accounts.liquidator_usdc.to_account_info(),
                    authority: ctx.accounts.agent_wallet.to_account_info(),
                },
                wallet_seeds,
            ),
            keeper_reward,
        )?;
    }

    // Step 6: RETURN surplus to agent.owner
    if returned_to_owner > 0 {
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
            returned_to_owner,
        )?;
    }

    // Step 5: UPDATE agent record — CPI to registry (score -40, liquidation_count++)
    let config_bump = ctx.accounts.config.bump;
    let config_seeds: &[&[&[u8]]] = &[&[WalletConfig::SEED, &[config_bump]]];

    krexa_agent_registry::cpi::record_liquidation(
        CpiContext::new_with_signer(
            ctx.accounts.registry_program.to_account_info(),
            krexa_agent_registry::cpi::accounts::RecordLiquidation {
                config: ctx.accounts.registry_config.to_account_info(),
                profile: ctx.accounts.agent_profile.to_account_info(),
                wallet_program_authority: ctx.accounts.config.to_account_info(),
            },
            config_seeds,
        ),
    )?;

    // Step 5: UPDATE wallet state
    let now = Clock::get()?.unix_timestamp;
    let wallet = &mut ctx.accounts.agent_wallet;
    wallet.is_liquidating = false;
    wallet.is_frozen = true;
    wallet.credit_drawn = 0;
    wallet.credit_limit = 0;
    // Shortfall remains as residual debt — admin calls write_off_bad_debt to process
    // through the loss waterfall (insurance → junior → mezzanine → senior)
    wallet.total_debt = shortfall;
    wallet.health_factor_bps = u16::MAX;
    wallet.last_health_check = now;

    emit!(Liquidated {
        agent: wallet.agent,
        debt_repaid: repay_amount,
        keeper_reward,
        returned_to_owner,
        shortfall,
    });
    Ok(())
}
