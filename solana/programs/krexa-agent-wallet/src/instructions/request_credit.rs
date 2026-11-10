use anchor_lang::prelude::*;
use crate::{RequestCredit, WalletError};
use crate::events::CreditReceived;
use crate::utils::health::{compute_health, collateral_value_usdc};
use krexa_common::constants::{
    LEVEL_1_MAX_CREDIT, LEVEL_2_MAX_CREDIT, LEVEL_2_LEVERAGE_NUM, LEVEL_2_LEVERAGE_DEN,
    LEVEL_3_MAX_CREDIT, LEVEL_3_LEVERAGE_NUM, LEVEL_3_LEVERAGE_DEN, LEVEL_4_MAX_CREDIT,
};

/// Mirror of vault's credit_limit_for_level — avoids reading post-CPI account data.
fn credit_limit_for_level(level: u8, collateral_value: u64) -> u64 {
    match level {
        1 => LEVEL_1_MAX_CREDIT,
        2 => (collateral_value as u128 * LEVEL_2_LEVERAGE_NUM as u128
            / LEVEL_2_LEVERAGE_DEN as u128).min(LEVEL_2_MAX_CREDIT as u128) as u64,
        3 => (collateral_value as u128 * LEVEL_3_LEVERAGE_NUM as u128
            / LEVEL_3_LEVERAGE_DEN as u128).min(LEVEL_3_MAX_CREDIT as u128) as u64,
        4 => LEVEL_4_MAX_CREDIT,
        _ => 0,
    }
}

pub fn handle(
    ctx: Context<RequestCredit>,
    amount: u64,
    rate_bps: u16,
    credit_level: u8,
    _collateral_value: u64, // SOL-002: ignored — computed on-chain from collateral_position
) -> Result<()> {
    require!(!ctx.accounts.config.is_paused, WalletError::Paused);
    require!(amount > 0, WalletError::ZeroAmount);
    require!(credit_level >= 1, WalletError::CreditLevelTooLow);

    // SOL-020 fix: Validate credit_level against agent's actual on-chain profile level
    let profile = &ctx.accounts.agent_profile;
    require!(
        credit_level <= profile.credit_level,
        WalletError::CreditLevelTooLow
    );

    {
        let wallet = &ctx.accounts.agent_wallet;
        require!(!wallet.is_frozen, WalletError::WalletFrozen);
        require!(!wallet.is_liquidating, WalletError::WalletLiquidating);
        require!(wallet.credit_drawn == 0, WalletError::CreditAlreadyDrawn);
    }

    // SOL-002 fix: Compute collateral_value on-chain from the vault's share accounting
    let vault_cfg = &ctx.accounts.vault_config;
    let collateral_value = collateral_value_usdc(
        ctx.accounts.collateral_position.shares,
        vault_cfg.total_deposits,
        vault_cfg.total_shares,
    );

    krexa_credit_vault::cpi::extend_credit(
        CpiContext::new(
            ctx.accounts.vault_program.to_account_info(),
            krexa_credit_vault::cpi::accounts::ExtendCredit {
                config: ctx.accounts.vault_config.to_account_info(),
                vault_token: ctx.accounts.vault_token.to_account_info(),
                credit_line: ctx.accounts.credit_line.to_account_info(),
                agent_wallet_usdc: ctx.accounts.wallet_usdc.to_account_info(),
                oracle: ctx.accounts.oracle.to_account_info(),
                token_program: ctx.accounts.token_program.to_account_info(),
                system_program: ctx.accounts.system_program.to_account_info(),
            },
        ),
        ctx.accounts.agent_wallet.agent,
        amount,
        rate_bps,
        credit_level,
        collateral_value, // now computed on-chain, not attacker-supplied
    )?;

    // credit_line is UncheckedAccount — compute limit locally using same formula as vault.
    ctx.accounts.wallet_usdc.reload()?;
    let credit_limit = credit_limit_for_level(credit_level, collateral_value);

    // NAV = V(t) / C₀ where C₀ = credit_limit (original credit amount)
    let hf = compute_health(
        ctx.accounts.wallet_usdc.amount,
        ctx.accounts.agent_wallet.collateral_shares,
        vault_cfg.total_deposits,
        vault_cfg.total_shares,
        credit_limit, // C₀ — original credit amount, not amount drawn
    );

    let wallet = &mut ctx.accounts.agent_wallet;
    wallet.credit_limit = credit_limit;
    wallet.credit_drawn = amount;
    wallet.total_debt = amount;
    wallet.health_factor_bps = hf;
    wallet.last_health_check = Clock::get()?.unix_timestamp;

    emit!(CreditReceived {
        agent: wallet.agent,
        amount,
        rate_bps,
        credit_limit,
        health_factor_bps: hf,
    });
    Ok(())
}
