use anchor_lang::prelude::*;
use crate::Initialize;

pub fn handle(
    ctx: Context<Initialize>,
    keeper: Pubkey,
    credit_vault_program: Pubkey,
    agent_registry_program: Pubkey,
    venue_whitelist_program: Pubkey,
    payment_router_program: Pubkey,
) -> Result<()> {
    let cfg = &mut ctx.accounts.config;
    cfg.admin = ctx.accounts.admin.key();
    cfg.credit_vault_program = credit_vault_program;
    cfg.agent_registry_program = agent_registry_program;
    cfg.venue_whitelist_program = venue_whitelist_program;
    cfg.payment_router_program = payment_router_program;
    cfg.usdc_mint = ctx.accounts.usdc_mint.key();
    cfg.keeper = keeper;
    cfg.platform_treasury = ctx.accounts.platform_treasury.key();
    cfg.total_wallets = 0;
    cfg.is_paused = false;
    cfg.bump = ctx.bumps.config;
    Ok(())
}
