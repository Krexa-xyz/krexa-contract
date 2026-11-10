use anchor_lang::prelude::*;

// ─────────────────────────────────────────────────────────────────────────────
// Credit level
// ─────────────────────────────────────────────────────────────────────────────

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq, Debug)]
pub enum CreditLevel {
    /// Level 0: KYA verified identity only — no wallet, no credit
    KyaOnly,
    /// Level 1: Micro-credit $500, no collateral required
    Starter,
    /// Level 2: 1:1 leverage — deposit $X → borrow $X → $2X total
    /// Collateral earns LP yield simultaneously
    Established,
    /// Level 3: 1:2 leverage — deposit $X → borrow $2X → $3X total
    /// Collateral earns LP yield simultaneously
    Trusted,
    /// Level 4: 1:5+ leverage — deposit $X → borrow $5X → $6X total
    /// Or zero collateral for elite agents with proven track record
    Elite,
}

impl CreditLevel {
    pub fn as_u8(self) -> u8 {
        match self {
            CreditLevel::KyaOnly => 0,
            CreditLevel::Starter => 1,
            CreditLevel::Established => 2,
            CreditLevel::Trusted => 3,
            CreditLevel::Elite => 4,
        }
    }

    pub fn from_u8(v: u8) -> Option<Self> {
        match v {
            0 => Some(CreditLevel::KyaOnly),
            1 => Some(CreditLevel::Starter),
            2 => Some(CreditLevel::Established),
            3 => Some(CreditLevel::Trusted),
            4 => Some(CreditLevel::Elite),
            _ => None,
        }
    }

    /// Maximum credit line in USDC base units (6 decimals) for this level.
    pub fn max_credit_usdc(&self) -> u64 {
        use crate::constants::*;
        match self {
            CreditLevel::KyaOnly     => LEVEL_0_MAX_CREDIT,
            CreditLevel::Starter     => LEVEL_1_MAX_CREDIT,
            CreditLevel::Established => LEVEL_2_MAX_CREDIT,
            CreditLevel::Trusted     => LEVEL_3_MAX_CREDIT,
            CreditLevel::Elite       => LEVEL_4_MAX_CREDIT,
        }
    }

    /// Credit multiplier numerator (credit = collateral × num / den).
    pub fn leverage_numerator(&self) -> u64 {
        use crate::constants::*;
        match self {
            CreditLevel::KyaOnly     => 0,
            CreditLevel::Starter     => 0, // no collateral path
            CreditLevel::Established => LEVEL_2_LEVERAGE_NUM,
            CreditLevel::Trusted     => LEVEL_3_LEVERAGE_NUM,
            CreditLevel::Elite       => LEVEL_4_LEVERAGE_NUM,
        }
    }

    pub fn leverage_denominator(&self) -> u64 {
        use crate::constants::*;
        match self {
            CreditLevel::KyaOnly     => 1,
            CreditLevel::Starter     => 1,
            CreditLevel::Established => LEVEL_2_LEVERAGE_DEN,
            CreditLevel::Trusted     => LEVEL_3_LEVERAGE_DEN,
            CreditLevel::Elite       => LEVEL_4_LEVERAGE_DEN,
        }
    }
}

impl Default for CreditLevel {
    fn default() -> Self {
        CreditLevel::KyaOnly
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// KYA tier
// ─────────────────────────────────────────────────────────────────────────────

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq, Debug)]
pub enum KyaTier {
    /// Not yet verified
    None,
    /// Automated code scan + owner wallet signature
    Basic,
    /// + Human KYC review + 3-month on-chain behavioural analysis
    Enhanced,
    /// + Full business / legal entity verification + 12-month history
    Institutional,
}

impl KyaTier {
    pub fn as_u8(self) -> u8 {
        match self {
            KyaTier::None         => 0,
            KyaTier::Basic        => 1,
            KyaTier::Enhanced     => 2,
            KyaTier::Institutional => 3,
        }
    }

    pub fn from_u8(v: u8) -> Option<Self> {
        match v {
            0 => Some(KyaTier::None),
            1 => Some(KyaTier::Basic),
            2 => Some(KyaTier::Enhanced),
            3 => Some(KyaTier::Institutional),
            _ => None,
        }
    }

    /// Minimum KYA tier required to access a given credit level.
    /// Canonical: L1/L2 = Tier 1 (Basic), L3/L4 = Tier 2 (Enhanced)
    pub fn required_for(level: CreditLevel) -> KyaTier {
        match level {
            CreditLevel::KyaOnly     => KyaTier::None,
            CreditLevel::Starter     => KyaTier::Basic,     // Tier 1+
            CreditLevel::Established => KyaTier::Basic,     // Tier 1+
            CreditLevel::Trusted     => KyaTier::Enhanced,  // Tier 2+
            CreditLevel::Elite       => KyaTier::Enhanced,  // Tier 2+
        }
    }

    pub fn meets(&self, required: KyaTier) -> bool {
        self.as_u8() >= required.as_u8()
    }
}

impl Default for KyaTier {
    fn default() -> Self {
        KyaTier::None
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tranche
// ─────────────────────────────────────────────────────────────────────────────

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq, Debug)]
pub enum Tranche {
    /// Senior — 50% of pool, 10% APR, last to absorb losses
    Senior,
    /// Mezzanine — 30% of pool, 12% APR, middle risk
    Mezzanine,
    /// Junior — 20% of pool, 20% APR, first to absorb losses (protocol capital)
    Junior,
}

impl Tranche {
    pub fn as_u8(self) -> u8 {
        match self {
            Tranche::Senior => 0,
            Tranche::Mezzanine => 1,
            Tranche::Junior => 2,
        }
    }

    pub fn from_u8(v: u8) -> Option<Self> {
        match v {
            0 => Some(Tranche::Senior),
            1 => Some(Tranche::Mezzanine),
            2 => Some(Tranche::Junior),
            _ => None,
        }
    }

    /// Annual yield rate in BPS for this tranche.
    pub fn apr_bps(&self) -> u16 {
        use crate::constants::*;
        match self {
            Tranche::Senior => SENIOR_APR_BPS,       // 1000 = 10%
            Tranche::Mezzanine => MEZZANINE_APR_BPS, // 1200 = 12%
            Tranche::Junior => JUNIOR_APR_BPS,       // 2000 = 20%
        }
    }

    /// Target share of total pool in BPS.
    pub fn share_bps(&self) -> u16 {
        use crate::constants::*;
        match self {
            Tranche::Senior => SENIOR_SHARE_BPS,       // 5000 = 50%
            Tranche::Mezzanine => MEZZANINE_SHARE_BPS, // 3000 = 30%
            Tranche::Junior => JUNIOR_SHARE_BPS,       // 2000 = 20%
        }
    }
}

impl Default for Tranche {
    fn default() -> Self {
        Tranche::Senior
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Agent type — determines enforcement model
// ─────────────────────────────────────────────────────────────────────────────

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq, Debug)]
pub enum AgentType {
    /// Type A: NAV-based enforcement — trading agents, collateral-backed
    Trader,
    /// Type B: Revenue velocity enforcement — service/merchant agents,
    /// milestone disbursement, expense whitelisting
    Service,
    /// Type C: Weighted blend of NAV + revenue velocity
    Hybrid,
}

impl AgentType {
    pub fn as_u8(self) -> u8 {
        match self {
            AgentType::Trader => 0,
            AgentType::Service => 1,
            AgentType::Hybrid => 2,
        }
    }

    pub fn from_u8(v: u8) -> Option<Self> {
        match v {
            0 => Some(AgentType::Trader),
            1 => Some(AgentType::Service),
            2 => Some(AgentType::Hybrid),
            _ => None,
        }
    }
}

impl Default for AgentType {
    fn default() -> Self {
        AgentType::Trader
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Service health — revenue velocity monitoring zones for Type B agents
// ─────────────────────────────────────────────────────────────────────────────

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq, Debug)]
pub enum ServiceHealth {
    /// On track — revenue ≥ 80% of projected
    Green,
    /// Slow but viable — revenue 50-80% of projected
    Yellow,
    /// Concerning — revenue 25-50% of projected, disbursements paused
    Orange,
    /// Critical — revenue < 25%, wind-down initiated
    Red,
}

impl ServiceHealth {
    pub fn as_u8(self) -> u8 {
        match self {
            ServiceHealth::Green => 0,
            ServiceHealth::Yellow => 1,
            ServiceHealth::Orange => 2,
            ServiceHealth::Red => 3,
        }
    }

    pub fn from_u8(v: u8) -> Option<Self> {
        match v {
            0 => Some(ServiceHealth::Green),
            1 => Some(ServiceHealth::Yellow),
            2 => Some(ServiceHealth::Orange),
            3 => Some(ServiceHealth::Red),
            _ => None,
        }
    }
}

impl Default for ServiceHealth {
    fn default() -> Self {
        ServiceHealth::Green
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Revenue source classification (Type B validation)
// ─────────────────────────────────────────────────────────────────────────────

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq, Debug)]
pub enum RevenueSourceClass {
    /// Passed all checks — counts as revenue
    Verified,
    /// Failed classification — does NOT count as revenue
    Rejected,
    /// Suspicious — held for oracle review
    Quarantined,
    /// Tentatively credited, awaiting keeper analysis
    PendingKeeper,
}

impl RevenueSourceClass {
    pub fn as_u8(self) -> u8 {
        match self {
            RevenueSourceClass::Verified => 0,
            RevenueSourceClass::Rejected => 1,
            RevenueSourceClass::Quarantined => 2,
            RevenueSourceClass::PendingKeeper => 3,
        }
    }

    pub fn from_u8(v: u8) -> Option<Self> {
        match v {
            0 => Some(RevenueSourceClass::Verified),
            1 => Some(RevenueSourceClass::Rejected),
            2 => Some(RevenueSourceClass::Quarantined),
            3 => Some(RevenueSourceClass::PendingKeeper),
            _ => None,
        }
    }
}

impl Default for RevenueSourceClass {
    fn default() -> Self {
        RevenueSourceClass::PendingKeeper
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Wallet / credit line status
// ─────────────────────────────────────────────────────────────────────────────

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq, Debug)]
pub enum WalletStatus {
    /// Normal operations — draw, pay, repay all permitted
    Active,
    /// Health 1.3–1.2x — no new borrows; repay and close positions only
    Warning,
    /// Health 1.2–1.05x — auto-deleverage in progress
    Deleveraging,
    /// Health < 1.05x — full liquidation triggered
    Liquidating,
    /// Fully closed / liquidated
    Closed,
}

impl Default for WalletStatus {
    fn default() -> Self {
        WalletStatus::Active
    }
}
