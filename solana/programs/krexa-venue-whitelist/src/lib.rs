use anchor_lang::prelude::*;

declare_id!("BuutifX7Wj8ysKeLQt1pag3JYWQdZHjktCA6ePUfHFHs");

// ─────────────────────────────────────────────────────────────────────────────
// Accounts
// ─────────────────────────────────────────────────────────────────────────────

#[account]
pub struct WhitelistConfig {
    pub admin: Pubkey,
    pub total_venues: u32,
    pub is_paused: bool,
    pub bump: u8,
}

impl WhitelistConfig {
    pub const LEN: usize = 8 + 32 + 4 + 1 + 1;
    pub const SEED: &'static [u8] = b"whitelist_config";
}

#[account]
pub struct WhitelistedVenue {
    pub program_id: Pubkey,
    pub name: [u8; 32],
    pub category: u8,  // 0=dex, 1=launchpad, 2=x402, 3=defi
    pub is_active: bool,
    pub added_at: i64,
    pub bump: u8,
}

impl WhitelistedVenue {
    pub const LEN: usize = 8 + 32 + 32 + 1 + 1 + 8 + 1;
    pub const SEED: &'static [u8] = b"venue";
}

// ─────────────────────────────────────────────────────────────────────────────
// Events
// ─────────────────────────────────────────────────────────────────────────────

#[event]
pub struct VenueAdded {
    pub program_id: Pubkey,
    pub name: [u8; 32],
    pub category: u8,
}

#[event]
pub struct VenueDeactivated {
    pub program_id: Pubkey,
}

#[event]
pub struct VenueReactivated {
    pub program_id: Pubkey,
}

// ─────────────────────────────────────────────────────────────────────────────
// Errors
// ─────────────────────────────────────────────────────────────────────────────

#[error_code]
pub enum VenueError {
    #[msg("Signer is not the admin")]
    NotAdmin,
    #[msg("Whitelist is paused")]
    Paused,
    #[msg("Venue is already active")]
    AlreadyActive,
    #[msg("Venue is already inactive")]
    AlreadyInactive,
    #[msg("Invalid venue category — must be 0–3")]
    InvalidCategory,
    #[msg("Admin cannot be set to the zero address")]
    InvalidAdmin,
}

// ─────────────────────────────────────────────────────────────────────────────
// Program
// ─────────────────────────────────────────────────────────────────────────────

#[program]
pub mod krexa_venue_whitelist {
    use super::*;

    pub fn initialize(ctx: Context<Initialize>) -> Result<()> {
        let config = &mut ctx.accounts.config;
        config.admin = ctx.accounts.admin.key();
        config.total_venues = 0;
        config.is_paused = false;
        config.bump = ctx.bumps.config;
        Ok(())
    }

    pub fn add_venue(
        ctx: Context<AddVenue>,
        program_id: Pubkey,
        name: [u8; 32],
        category: u8,
    ) -> Result<()> {
        let config = &mut ctx.accounts.config;
        require!(!config.is_paused, VenueError::Paused);
        // SOL-036 fix: Validate category range (0=dex, 1=launchpad, 2=x402, 3=defi)
        require!(category <= 3, VenueError::InvalidCategory);

        let venue = &mut ctx.accounts.venue;
        venue.program_id = program_id;
        venue.name = name;
        venue.category = category;
        venue.is_active = true;
        venue.added_at = Clock::get()?.unix_timestamp;
        venue.bump = ctx.bumps.venue;

        config.total_venues = config.total_venues.saturating_add(1);

        emit!(VenueAdded { program_id, name, category });
        Ok(())
    }

    pub fn deactivate_venue(ctx: Context<DeactivateVenue>) -> Result<()> {
        require!(!ctx.accounts.config.is_paused, VenueError::Paused);
        let venue = &mut ctx.accounts.venue;
        require!(venue.is_active, VenueError::AlreadyInactive);
        venue.is_active = false;
        emit!(VenueDeactivated { program_id: venue.program_id });
        Ok(())
    }

    pub fn reactivate_venue(ctx: Context<ReactivateVenue>) -> Result<()> {
        let config = &ctx.accounts.config;
        require!(!config.is_paused, VenueError::Paused);
        let venue = &mut ctx.accounts.venue;
        require!(!venue.is_active, VenueError::AlreadyActive);
        venue.is_active = true;
        emit!(VenueReactivated { program_id: venue.program_id });
        Ok(())
    }

    pub fn set_paused(ctx: Context<AdminWhitelistConfig>, paused: bool) -> Result<()> {
        ctx.accounts.config.is_paused = paused;
        Ok(())
    }

    pub fn update_config(ctx: Context<AdminWhitelistConfig>, new_admin: Option<Pubkey>) -> Result<()> {
        if let Some(admin) = new_admin {
            // SOL-068 fix: prevent setting admin to zero address (permanently locks program)
            require!(admin != Pubkey::default(), VenueError::InvalidAdmin);
            ctx.accounts.config.admin = admin;
        }
        Ok(())
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Contexts
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(
        init,
        payer = admin,
        space = WhitelistConfig::LEN,
        seeds = [WhitelistConfig::SEED],
        bump,
    )]
    pub config: Account<'info, WhitelistConfig>,

    #[account(mut)]
    pub admin: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(program_id: Pubkey)]
pub struct AddVenue<'info> {
    #[account(
        mut,
        seeds = [WhitelistConfig::SEED],
        bump = config.bump,
        has_one = admin @ VenueError::NotAdmin,
    )]
    pub config: Account<'info, WhitelistConfig>,

    #[account(
        init,
        payer = admin,
        space = WhitelistedVenue::LEN,
        seeds = [WhitelistedVenue::SEED, program_id.as_ref()],
        bump,
    )]
    pub venue: Account<'info, WhitelistedVenue>,

    #[account(mut)]
    pub admin: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct DeactivateVenue<'info> {
    #[account(
        seeds = [WhitelistConfig::SEED],
        bump = config.bump,
        has_one = admin @ VenueError::NotAdmin,
    )]
    pub config: Account<'info, WhitelistConfig>,

    #[account(
        mut,
        seeds = [WhitelistedVenue::SEED, venue.program_id.as_ref()],
        bump = venue.bump,
    )]
    pub venue: Account<'info, WhitelistedVenue>,

    pub admin: Signer<'info>,
}

#[derive(Accounts)]
pub struct ReactivateVenue<'info> {
    #[account(
        seeds = [WhitelistConfig::SEED],
        bump = config.bump,
        has_one = admin @ VenueError::NotAdmin,
    )]
    pub config: Account<'info, WhitelistConfig>,

    #[account(
        mut,
        seeds = [WhitelistedVenue::SEED, venue.program_id.as_ref()],
        bump = venue.bump,
    )]
    pub venue: Account<'info, WhitelistedVenue>,

    pub admin: Signer<'info>,
}

#[derive(Accounts)]
pub struct AdminWhitelistConfig<'info> {
    #[account(
        mut,
        seeds = [WhitelistConfig::SEED],
        bump = config.bump,
        has_one = admin @ VenueError::NotAdmin,
    )]
    pub config: Account<'info, WhitelistConfig>,

    pub admin: Signer<'info>,
}
