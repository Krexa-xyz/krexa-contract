use krexa_common::constants::{BPS_DENOMINATOR, MAX_PER_TRADE_BPS, WITHDRAWAL_BUFFER_BPS};

/// Enforce the per-trade limit: amount <= balance * MAX_PER_TRADE_BPS / BPS_DENOMINATOR.
/// MAX_PER_TRADE_BPS = 2000 → max 20% of wallet per trade.
pub fn check_per_trade_limit(amount: u64, wallet_balance: u64) -> bool {
    if wallet_balance == 0 {
        return amount == 0;
    }
    let max = (wallet_balance as u128 * MAX_PER_TRADE_BPS as u128
        / BPS_DENOMINATOR as u128) as u64;
    amount <= max
}

/// Reset daily counter if we've crossed into a new calendar day (UTC).
/// Returns the updated (daily_spent, last_daily_reset).
pub fn maybe_reset_daily(
    daily_spent: u64,
    last_daily_reset: i64,
    now: i64,
) -> (u64, i64) {
    let last_day = last_daily_reset / 86_400;
    let current_day = now / 86_400;
    if current_day > last_day {
        (0, now) // new day — reset
    } else {
        (daily_spent, last_daily_reset)
    }
}

/// Compute the maximum USDC the owner can withdraw given current debt.
///
/// If total_debt == 0: can withdraw everything in wallet.
/// Otherwise must keep at least WITHDRAWAL_BUFFER_BPS (120%) of total_debt
/// covered by (wallet_usdc + collateral_value). Since collateral can't be
/// directly withdrawn here, collateral counts toward the buffer first.
pub fn max_withdrawable(
    wallet_usdc: u64,
    collateral_value: u64,
    total_debt: u64,
) -> u64 {
    if total_debt == 0 {
        return wallet_usdc;
    }

    // Minimum total value required = debt * 120%
    let min_total_required =
        (total_debt as u128 * WITHDRAWAL_BUFFER_BPS as u128 / BPS_DENOMINATOR as u128) as u64;

    // Collateral already covers part of the requirement
    let collateral_cover = collateral_value.min(min_total_required);
    let remaining_required = min_total_required.saturating_sub(collateral_cover);

    // Wallet must keep at least remaining_required
    wallet_usdc.saturating_sub(remaining_required)
}
