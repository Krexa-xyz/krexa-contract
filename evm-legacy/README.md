# Krexa credit protocol (EVM, legacy)

The first Krexa protocol: credit lines for AI agents that earn money. Krexa has retired this product; the code stays here
for reference and for the deployments below.

> **Unaudited.**

| Contract | What it does |
|---|---|
| `AgentRegistry`, `AgentIdentity` | Agent identity and stats |
| `AgentWallet`, `AgentWalletFactory` | Deterministic per-agent wallets |
| `PaymentRouter`, `Krexa402Facilitator` | x402 machine-to-machine payments, signature checks, replay protection, revenue split |
| `MerchantVault`, `VaultFactory`, `LiquidityPool` | Per-agent credit vaults funded by senior and general pools, repaid by a waterfall |
| `TraderVault`, `TraderVaultFactory` | Vaults for trading agents |
| `KrexitScore`, `MilestoneRegistry`, `ServicePlan` | Credit score, milestones, service plans |
| `VenueWhitelist`, `PolymarketGuardrail` | Venue and market limits |

Libraries: `WaterfallLib` (Senior → Pool → Community), `SignatureLib`, `Errors`.

## Deployments

- Monad mainnet: [`deployments/monad-mainnet.json`](deployments/monad-mainnet.json), details in [MONAD-DEPLOYMENT.md](MONAD-DEPLOYMENT.md)
- Base Sepolia: [`deployments/base-sepolia.json`](deployments/base-sepolia.json)

## Build and test

```
forge build
forge test
```

Deploy scripts are in `script/`. Copy `.env.example` to `.env` and fill it; never commit it.
