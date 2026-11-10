use anchor_lang::prelude::*;

#[event]
pub struct WalletCreated {
    pub agent: Pubkey,
    pub owner: Pubkey,
    pub wallet_pda: Pubkey,
}

#[event]
pub struct CollateralDeposited {
    pub agent: Pubkey,
    pub amount: u64,
    pub new_collateral_shares: u64,
}

#[event]
pub struct CreditReceived {
    pub agent: Pubkey,
    pub amount: u64,
    pub rate_bps: u16,
    pub credit_limit: u64,
    pub health_factor_bps: u16,
}

#[event]
pub struct TradeExecuted {
    pub agent: Pubkey,
    pub venue: Pubkey,
    pub amount: u64,
    pub health_after: u16,
    pub daily_spent: u64,
}

#[event]
pub struct X402Payment {
    pub agent: Pubkey,
    pub facilitator: Pubkey,
    pub recipient: Pubkey,
    pub amount: u64,
    pub memo: [u8; 32],
}

#[event]
pub struct Withdrawal {
    pub agent: Pubkey,
    pub amount: u64,
    pub remaining_debt: u64,
    pub health_after: u16,
}

#[event]
pub struct Repaid {
    pub agent: Pubkey,
    pub amount: u64,
    pub remaining_debt: u64,
    pub credit_cleared: bool,
}

#[event]
pub struct HealthChecked {
    pub agent: Pubkey,
    pub health_factor_bps: u16,
    pub wallet_usdc: u64,
    pub collateral_value: u64,
    pub total_debt: u64,
}

#[event]
pub struct Deleveraged {
    pub agent: Pubkey,
    pub health_before: u16,
}

#[event]
pub struct Liquidated {
    pub agent: Pubkey,
    pub debt_repaid: u64,
    pub keeper_reward: u64,
    pub returned_to_owner: u64,
    pub shortfall: u64,
}

#[event]
pub struct WalletFrozen {
    pub agent: Pubkey,
}

#[event]
pub struct WalletUnfrozen {
    pub agent: Pubkey,
}

#[event]
pub struct OwnershipTransferProposed {
    pub agent: Pubkey,
    pub current_owner: Pubkey,
    pub proposed_owner: Pubkey,
    pub proposed_owner_type: u8,
}

#[event]
pub struct OwnershipTransferAccepted {
    pub agent: Pubkey,
    pub old_owner: Pubkey,
    pub new_owner: Pubkey,
    pub new_owner_type: u8,
}

#[event]
pub struct OwnershipTransferCancelled {
    pub agent: Pubkey,
    pub cancelled_by: Pubkey,
}
