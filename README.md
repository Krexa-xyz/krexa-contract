# Krexa contracts

On-chain code for [Krexa](https://krexa.xyz), where AI trading agents trade from accounts their owners control.
Krexa's key can trade inside limits the chain enforces. It cannot move money out.

> **Unaudited.** None of this code has had an external audit. See [SECURITY.md](SECURITY.md).

| Folder | What | Chains | Tests |
|---|---|---|---|
| [`evm/`](evm) | **EVM home** (current). `KrexaSwapPolicy` and `KrexaRiskHook`: ERC-7579 modules that limit a session key on each user's own Kernel v3.3 smart account (ERC-4337). | Monad, Base, Arbitrum, Robinhood Chain | 169 Foundry tests: unit, fuzz, invariant |
| [`evm-legacy/`](evm-legacy) | Agent credit protocol (retired product): agent registry, agent wallets, x402 payment router, credit vaults, liquidity pools, credit score. | Base Sepolia, Monad | 569 Foundry tests |
| [`solana/`](solana) | Anchor programs for the same agent wallet and credit design on Solana (retired; mainnet programs closed 2026-09-29). | Solana | TypeScript tests (Anchor) |

Krexa vaults on other chains have their own repos: [krexa-stellar](https://github.com/Krexa-xyz/krexa-stellar) (Soroban).

## EVM home deployments

Same address on every chain (CREATE2, salt `keccak256("krexa.evm-home.v1")`, no constructor arguments, no owner).

| Contract | Address |
|---|---|
| `KrexaSwapPolicy` | `0x446b4ea7cd7CF874895c03b91478514Cbfd7E931` |
| `KrexaRiskHook` | `0xAcF4425F4E349cD4cE646898d2a5a6250945f5d9` |

| Chain | Chain id | Record |
|---|---|---|
| Monad | 143 | [`evm/deployments/143-evm-home.json`](evm/deployments/143-evm-home.json) |
| Monad testnet | 10143 | [`evm/deployments/10143-evm-home.json`](evm/deployments/10143-evm-home.json) |
| Arbitrum Sepolia | 421614 | [`evm/deployments/421614-evm-home.json`](evm/deployments/421614-evm-home.json) |
| Robinhood Chain testnet | 46630 | [`evm/deployments/46630-evm-home.json`](evm/deployments/46630-evm-home.json) |
| Base Sepolia | 84532 | [`evm/deployments/84532-evm-home.json`](evm/deployments/84532-evm-home.json) |

Anyone can check that the code on chain is the code in this repo:

```
git clone --recursive https://github.com/Krexa-xyz/krexa-contract
cd krexa-contract/evm && ./script/verify-deployments.sh
```

It rebuilds both contracts and compares three code hashes per chain: the build, the deployment record, and the code on chain.

## Build and test

Needs [Foundry](https://getfoundry.sh) and, for Solana, Rust (plus the Anchor CLI 0.30.1 for the TypeScript tests).

```
git submodule update --init --recursive
(cd evm && forge test)
(cd evm-legacy && forge test)
(cd solana && cargo build)
```

## License

[MIT](LICENSE)
