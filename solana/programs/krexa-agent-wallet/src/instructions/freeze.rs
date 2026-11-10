use anchor_lang::prelude::*;
use crate::{FreezeWallet, WalletError};
use crate::events::{WalletFrozen, WalletUnfrozen};

pub fn handle_freeze(ctx: Context<FreezeWallet>) -> Result<()> {
    let wallet = &mut ctx.accounts.agent_wallet;
    wallet.is_frozen = true;
    emit!(WalletFrozen { agent: wallet.agent });
    Ok(())
}

pub fn handle_unfreeze(ctx: Context<FreezeWallet>) -> Result<()> {
    let wallet = &mut ctx.accounts.agent_wallet;
    require!(!wallet.is_liquidating, WalletError::WalletLiquidating);
    wallet.is_frozen = false;
    emit!(WalletUnfrozen { agent: wallet.agent });
    Ok(())
}
