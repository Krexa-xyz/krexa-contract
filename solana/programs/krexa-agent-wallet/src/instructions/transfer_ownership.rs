use anchor_lang::prelude::*;
use crate::{
    ProposeOwnershipTransfer, AcceptOwnershipTransfer, CancelOwnershipTransfer,
    WalletError,
    events::{OwnershipTransferProposed, OwnershipTransferAccepted, OwnershipTransferCancelled},
};

/// Propose an ownership transfer to a new owner.
/// Current owner creates the OwnershipTransfer PDA.
pub fn handle_propose(
    ctx: Context<ProposeOwnershipTransfer>,
    new_owner: Pubkey,
    new_owner_type: u8,
) -> Result<()> {
    require!(new_owner_type <= 1, WalletError::InvalidOwnerType);
    require!(new_owner != Pubkey::default(), WalletError::InvalidOwnerType);

    let transfer = &mut ctx.accounts.transfer_request;
    transfer.agent = ctx.accounts.agent_wallet.agent;
    transfer.proposed_owner = new_owner;
    transfer.proposed_owner_type = new_owner_type;
    transfer.proposed_at = Clock::get()?.unix_timestamp;
    transfer.bump = ctx.bumps.transfer_request;

    emit!(OwnershipTransferProposed {
        agent: ctx.accounts.agent_wallet.agent,
        current_owner: ctx.accounts.owner.key(),
        proposed_owner: new_owner,
        proposed_owner_type: new_owner_type,
    });

    Ok(())
}

/// Accept an ownership transfer. The proposed new owner must sign.
/// Closes the OwnershipTransfer PDA and refunds rent to rent_receiver.
pub fn handle_accept(ctx: Context<AcceptOwnershipTransfer>) -> Result<()> {
    let transfer = &ctx.accounts.transfer_request;
    let old_owner = ctx.accounts.agent_wallet.owner;
    let new_owner = transfer.proposed_owner;
    let new_owner_type = transfer.proposed_owner_type;
    let agent = ctx.accounts.agent_wallet.agent;

    let wallet = &mut ctx.accounts.agent_wallet;
    wallet.owner = new_owner;
    wallet.owner_type = new_owner_type;

    emit!(OwnershipTransferAccepted {
        agent,
        old_owner,
        new_owner,
        new_owner_type,
    });

    Ok(())
}

/// Cancel a pending ownership transfer. Current owner must sign.
/// Closes the OwnershipTransfer PDA and refunds rent to owner.
pub fn handle_cancel(ctx: Context<CancelOwnershipTransfer>) -> Result<()> {
    emit!(OwnershipTransferCancelled {
        agent: ctx.accounts.agent_wallet.agent,
        cancelled_by: ctx.accounts.owner.key(),
    });

    Ok(())
}
