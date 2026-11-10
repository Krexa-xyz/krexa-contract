use anchor_lang::prelude::*;
use crate::{Deposit, WalletError};
use crate::events::CollateralDeposited;

pub fn handle(ctx: Context<Deposit>, amount: u64) -> Result<()> {
    require!(!ctx.accounts.config.is_paused, WalletError::Paused);
    require!(amount > 0, WalletError::ZeroAmount);
    require!(!ctx.accounts.agent_wallet.is_frozen, WalletError::WalletFrozen);

    krexa_credit_vault::cpi::deposit_collateral(
        CpiContext::new(
            ctx.accounts.vault_program.to_account_info(),
            krexa_credit_vault::cpi::accounts::DepositCollateral {
                config: ctx.accounts.vault_config.to_account_info(),
                vault_token: ctx.accounts.vault_token.to_account_info(),
                collateral_position: ctx.accounts.collateral_position.to_account_info(),
                owner_usdc: ctx.accounts.owner_usdc.to_account_info(),
                owner: ctx.accounts.owner.to_account_info(),
                token_program: ctx.accounts.token_program.to_account_info(),
                system_program: ctx.accounts.system_program.to_account_info(),
            },
        ),
        ctx.accounts.agent_wallet.agent,
        amount,
    )?;

    ctx.accounts.collateral_position.reload()?;
    let new_shares = ctx.accounts.collateral_position.shares;

    let wallet = &mut ctx.accounts.agent_wallet;
    wallet.collateral_shares = new_shares;

    emit!(CollateralDeposited {
        agent: wallet.agent,
        amount,
        new_collateral_shares: new_shares,
    });
    Ok(())
}
