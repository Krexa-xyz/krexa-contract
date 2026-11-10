# Krexa Solana programs

Anchor 0.30.1 programs: agent registry, agent wallet (deposit, trade through whitelisted venues, x402 payments,
credit, health checks, liquidation), credit vault, payment router, venue whitelist, service plan and credit score.
Shared types live in `programs/krexa-common`.

> **Unaudited and retired.** The mainnet programs were closed on 2026-09-29: no program data, no accounts, no upgrade
> authority. Read [KNOWN-ISSUES.md](KNOWN-ISSUES.md) before you reuse this code.

## Program ids

| Program | Mainnet (closed) | Devnet / localnet |
|---|---|---|
| krexa_agent_registry | `EnteGjokMnFqTDcZSBitXDQEctMCnqV33HbPKw2LnDCg` | `ChJjAXy7sE4d4jst9VViG7ScanVKqH9Q1cFxtdcH78cG` |
| krexa_credit_vault | `LgrUXRquid228Azj2HrMNLhXHFw8FDRGVG1SqLbbcMS` | `26SQx3rAyujWCupxvPAMf9N3ok4cw1awyTWAVWDQfr9N` |
| krexa_agent_wallet | `FZoibjoRvbSTqR46XfKkkX6ZLRugZvGoV82NJBatt5fu` | `35t8yWLsUZNTLT71ej7DF59P81HrtZTx2uZeMhwuhhf6` |
| krexa_payment_router | `Hx1fkePyNggZDjL4mwVWYyd3K3vqg7iWAEtb5xuGBHVL` | `2Zy3d7C28Z9dfazdysKVBQUXnvvWNshxtDEFKftG83u8` |
| krexa_venue_whitelist | `BuutifX7Wj8ysKeLQt1pag3JYWQdZHjktCA6ePUfHFHs` | `HyWQrHG14Sw6KpKYSMiBDmVj5u7PXfLWvim6FHbBLmua` |
| krexa_service_plan | not deployed | `Eqc48c6TtKAPRosTMoC6Nasi85iqdLuzwbu6WBrsPFdt` |
| krexa_score | not deployed | `2GwtAXnjY5LehfZfT77ZH3XSshwbni8LP9zXeA84WUqh` |

## Build and test

```
cargo build            # compile check
anchor build           # SBF build
anchor test            # TypeScript tests in tests/ against a local validator
```
