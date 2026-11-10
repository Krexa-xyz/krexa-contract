# Known issues

Found in a review on 2026-11-11. The mainnet programs were already closed (2026-09-29), so no funds or accounts are
exposed. Fix these before any redeploy, under new program ids.

| # | Severity | Where | Issue | Fix |
|---|---|---|---|---|
| 1 | High | `krexa-credit-vault` `deposit_collateral` / `withdraw_collateral` | The collateral position PDA is seeded `[b"collateral", agent]` with `agent` as an argument. Anyone can open the position first and become its `depositor`; the owner's later deposits land in it and only the attacker can withdraw. | Seed with the wallet owner (`[b"collateral", owner, agent]`) or require `pos.depositor == owner` on every deposit. |
| 2 | High | `krexa-agent-wallet` `utils/health.rs`, `liquidate` | NAV divides by `credit_limit`, not the debt drawn or left after a partial repay, so a healthy borrower can fall under the trigger and be liquidated by anyone. | Divide by the live debt. |
| 3 | High | `krexa-agent-wallet` `execute_trade` | `venue_token` is checked for the USDC mint only, so the agent key can send a trade to any USDC account (bounded by the per-trade, daily and per-venue limits). | Pin `venue_token.owner` to an authority stored in the venue's whitelist entry, or CPI into the venue. |
| 4 | Medium | `krexa-credit-vault` `deposit_liquidity` | The `tranche` argument on an existing position updates another tranche's totals. Share price is unaffected; the tranche counters drift. | Ignore the argument after the position exists, or require it to match. |
| 5 | Medium | `krexa-payment-router` `execute_payment` | A repayment through the router updates the vault's credit line but not the agent wallet's own debt fields. | Read debt from the credit line, or CPI into the wallet program to sync it. |
