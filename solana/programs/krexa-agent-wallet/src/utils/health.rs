use krexa_common::constants::{
    BPS_DENOMINATOR,
    LEVEL_1_NAV_TRIGGER_BPS, LEVEL_2_NAV_TRIGGER_BPS,
    LEVEL_3_NAV_TRIGGER_BPS, LEVEL_4_NAV_TRIGGER_BPS,
};

/// Compute the NAV ratio in BPS (10_000 = 1.0x = 100%).
///
/// NAV(t) = V(t) / C₀
///   V(t)  = wallet_usdc_balance + collateral_value
///   C₀    = original credit amount (credit_limit — never changes)
///
/// Returns u16::MAX when original_credit == 0 (no credit drawn = infinite NAV).
pub fn compute_nav(
    wallet_usdc_balance: u64,
    collateral_shares: u64,
    vault_total_deposits: u64,
    vault_total_shares: u64,
    original_credit: u64,
) -> u16 {
    if original_credit == 0 {
        return u16::MAX;
    }

    let collateral_value = collateral_value_usdc(
        collateral_shares, vault_total_deposits, vault_total_shares,
    );

    let total_value = wallet_usdc_balance.saturating_add(collateral_value);

    // NAV in BPS — clamp to u16::MAX
    let nav = (total_value as u128)
        .checked_mul(BPS_DENOMINATOR as u128)
        .unwrap_or(u128::MAX)
        .checked_div(original_credit as u128)
        .unwrap_or(0)
        .min(u16::MAX as u128);

    nav as u16
}

/// Backward-compatible alias: compute_health maps to compute_nav.
/// `total_debt` parameter is reinterpreted as `original_credit` (C₀).
/// Callers should migrate to `compute_nav` and pass credit_limit instead of total_debt.
pub fn compute_health(
    wallet_usdc_balance: u64,
    collateral_shares: u64,
    vault_total_deposits: u64,
    vault_total_shares: u64,
    original_credit: u64,
) -> u16 {
    compute_nav(
        wallet_usdc_balance,
        collateral_shares,
        vault_total_deposits,
        vault_total_shares,
        original_credit,
    )
}

/// Projected NAV AFTER spending `amount` from wallet_usdc.
/// Used as a pre-flight check in execute_trade and pay_x402.
pub fn projected_health(
    wallet_usdc_balance: u64,
    spend_amount: u64,
    collateral_shares: u64,
    vault_total_deposits: u64,
    vault_total_shares: u64,
    original_credit: u64,
) -> u16 {
    let projected_balance = wallet_usdc_balance.saturating_sub(spend_amount);
    compute_nav(
        projected_balance,
        collateral_shares,
        vault_total_deposits,
        vault_total_shares,
        original_credit,
    )
}

/// Collateral value in USDC from shares.
pub fn collateral_value_usdc(
    shares: u64,
    vault_total_deposits: u64,
    vault_total_shares: u64,
) -> u64 {
    if vault_total_shares == 0 {
        return shares;
    }
    (shares as u128 * vault_total_deposits as u128 / vault_total_shares as u128) as u64
}

/// NAV liquidation trigger for a given credit level (in BPS).
/// Canonical values: L1=90%, L2=85%, L3=80%, L4=80%.
pub fn nav_trigger_for_level(credit_level: u8) -> u16 {
    match credit_level {
        1 => LEVEL_1_NAV_TRIGGER_BPS, // 9000 = 90%
        2 => LEVEL_2_NAV_TRIGGER_BPS, // 8500 = 85%
        3 => LEVEL_3_NAV_TRIGGER_BPS, // 8000 = 80%
        4 => LEVEL_4_NAV_TRIGGER_BPS, // 8000 = 80%
        _ => BPS_DENOMINATOR,         // 100% — immediate trigger for unknown levels
    }
}

/// NAV warning threshold: slightly above liquidation trigger.
/// Used to restrict new positions when NAV is getting close to trigger.
pub fn nav_warning_for_level(credit_level: u8) -> u16 {
    // Warning = trigger + 5% buffer
    nav_trigger_for_level(credit_level).saturating_add(500)
}
