use anchor_lang::prelude::*;

// ─────────────────────────────────────────────────────────────────────────────
// WalletConfig — singleton program configuration
// ─────────────────────────────────────────────────────────────────────────────

#[account]
pub struct WalletConfig {
    pub admin: Pubkey,
    pub credit_vault_program: Pubkey,    // krexa-credit-vault
    pub agent_registry_program: Pubkey,  // krexa-agent-registry
    pub venue_whitelist_program: Pubkey, // krexa-venue-whitelist
    pub payment_router_program: Pubkey,  // krexa-payment-router (future)
    pub usdc_mint: Pubkey,
    pub keeper: Pubkey,                  // authorised keeper bot
    pub platform_treasury: Pubkey,       // SOL-058: treasury token account for x402 fees

    pub total_wallets: u64,
    pub is_paused: bool,
    pub bump: u8,
}

impl WalletConfig {
    // 8 + 8*32 + 8 + 1 + 1 + 16 pad = 290
    pub const LEN: usize = 8 + 8 * 32 + 8 + 2 + 16;
    pub const SEED: &'static [u8] = b"wallet_config";
}

// ─────────────────────────────────────────────────────────────────────────────
// AgentWallet — per-agent PDA wallet with full credit state
// ─────────────────────────────────────────────────────────────────────────────

#[account]
pub struct AgentWallet {
    // Identity
    pub agent: Pubkey,          // the agent's signing keypair
    pub owner: Pubkey,          // the human owner (controls withdrawals)
    pub config: Pubkey,         // WalletConfig PDA reference
    pub wallet_usdc: Pubkey,    // this wallet's PDA token account address

    // Financial state
    pub collateral_shares: u64, // shares in credit vault (collateral earning yield)
    pub credit_limit: u64,      // max credit approved on current line
    pub credit_drawn: u64,      // principal currently outstanding
    pub total_debt: u64,        // credit_drawn + accrued interest (synced on repay/health)

    // Spending limits — set by owner, enforced on every trade
    pub daily_spend_limit: u64, // USDC per 24h period
    pub daily_spent: u64,       // spent in current day
    pub last_daily_reset: i64,  // unix timestamp of last day boundary

    // Health monitoring
    pub health_factor_bps: u16, // HF * 10_000 (10000 = 1.0x, 15000 = 1.5x)
    pub last_health_check: i64,

    // Status flags
    pub credit_level: u8,       // copy from registry — gating for request_credit
    pub is_frozen: bool,        // admin or auto-frozen (no trades allowed)
    pub is_liquidating: bool,   // liquidation in progress

    // Lifetime stats
    pub total_trades: u64,
    pub total_volume: u64,
    pub total_repaid: u64,
    pub created_at: i64,

    pub bump: u8,
    pub usdc_bump: u8,
    pub owner_type: u8,  // 0 = EOA, 1 = Multisig (Squads v4)
}

impl AgentWallet {
    // 8 + 4*32 + 7*8 + 2 + 8 + 3 + 4*8 + 2 + 1 + 15 pad = 255 (same total, owner_type uses 1 pad byte)
    pub const LEN: usize = 8 + 4 * 32 + 7 * 8 + 2 + 8 + 3 + 4 * 8 + 2 + 1 + 15;
    pub const SEED: &'static [u8] = b"agent_wallet";
    pub const USDC_SEED: &'static [u8] = b"wallet_usdc";
}

// ─────────────────────────────────────────────────────────────────────────────
// VenueExposure — per-agent per-venue exposure tracking (safety check 5)
// ─────────────────────────────────────────────────────────────────────────────

#[account]
pub struct VenueExposure {
    pub agent: Pubkey,
    pub venue: Pubkey,
    pub total_sent: u64,     // cumulative USDC sent to this venue
    pub bump: u8,
}

impl VenueExposure {
    pub const LEN: usize = 8 + 32 + 32 + 8 + 1; // 81
    pub const SEED: &'static [u8] = b"venue_exposure";
}

// ─────────────────────────────────────────────────────────────────────────────
// OwnershipTransfer — temporary PDA created during a 2-step ownership transfer
// ─────────────────────────────────────────────────────────────────────────────

#[account]
pub struct OwnershipTransfer {
    pub agent: Pubkey,
    pub proposed_owner: Pubkey,
    pub proposed_owner_type: u8,
    pub proposed_at: i64,
    pub bump: u8,
}

impl OwnershipTransfer {
    pub const LEN: usize = 8 + 32 + 32 + 1 + 8 + 1; // 82
    pub const SEED: &'static [u8] = b"ownership_transfer";
}
