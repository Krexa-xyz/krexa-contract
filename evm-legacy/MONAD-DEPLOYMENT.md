# Krexa Protocol — Monad Deployment

**Chain:** Monad Testnet (Chain ID: 10143)
**RPC:** `https://testnet-rpc.monad.xyz/`
**Explorer:** `https://testnet.monadexplorer.com`
**Status:** Live — 551 tests passing, A2A payments verified on-chain
**Deployed by:** `0xA1090527ac5c019Abc3989F405a5a63bB008008D`

---

## Deployed Contracts

| # | Contract | Address | Purpose |
|---|----------|---------|---------|
| 0 | MockUSDC | `0x460b023a87f7Dbe0114357Ab45830F1A41e9C103` | ERC-20 stablecoin (testnet) |
| 1 | AgentRegistry | `0xd0CB44B07e922d3bc276061bCB9eF41e103Cc872` | On-chain AI agent identity & credit levels |
| 2 | PaymentRouter (v2) | `0xA32D44b831C7AD1B99eCBf97333876f8fb0DD786` | x402 payments, revenue validation, A2A payments |
| 3 | VaultFactory | `0x964d800A7Bf5353084fE6360D22390ABec46f11F` | CREATE2 deployer for MerchantVault credit lines |
| 4 | SeniorPool | `0x746D4E417C111eD557A8564b7bEB6C4c3EB9C7F3` | Senior tranche liquidity pool |
| 5 | GeneralPool | `0xdDb014C771236CD62e1F3eD6cC9459163960bBDA` | General tranche liquidity pool |
| 6 | MilestoneRegistry | `0x56d60DA8665f56626bC6E2f372214A942f85a258` | Milestone tracking for credit lines |
| 7 | KrexitScore | `0x79c061083Ee39F0ECE67D30f5172C86372CAdb18` | Credit scoring engine (200–850) |
| 8 | VenueWhitelist | `0x0b45fDB4Fd92e8d8F21EFB03436Ea22E0eBDD824` | Approved venues/merchants |
| 9 | AgentWalletFactory | `0x120E6fCDe2244ccE9CC02360e4f0Dc5e311a8c65` | Deterministic CREATE2 wallet deployment |
| 10 | ServicePlan | `0xaaE90e87184e6D8072B829Cd0305068272c189B2` | Type B agent service plans with milestones |

---

## Architecture Overview

Krexa is an **AI agent credit protocol** — it lets autonomous AI agents register an on-chain identity, build a credit score, access credit lines, and make payments via the x402 standard. The protocol enforces safety guardrails at the smart contract level.

```
┌─────────────────────────────────────────────────────────────────┐
│                        KREXA PROTOCOL                           │
│                                                                 │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │
│  │ AgentRegistry │◄──►│ KrexitScore  │    │ VenueWhitelist│     │
│  │ (Identity)    │    │ (200-850)    │    │ (Approved)    │     │
│  └──────┬───────┘    └──────────────┘    └──────────────┘      │
│         │                                                       │
│  ┌──────▼───────┐    ┌──────────────┐    ┌──────────────┐      │
│  │ WalletFactory │──►│ AgentWallet  │    │ ServicePlan  │      │
│  │ (CREATE2/PDA) │    │ (8-layer)    │    │ (Milestones) │     │
│  └──────────────┘    └──────┬───────┘    └──────────────┘      │
│                             │                                   │
│  ┌──────────────┐    ┌──────▼───────┐    ┌──────────────┐      │
│  │ VaultFactory  │──►│PaymentRouter │──►│ MerchantVault │      │
│  │ (Credit Lines)│    │(x402+A2A+Rev)│    │ (Tranches)   │     │
│  └──────────────┘    └──────┬───────┘    └──────────────┘      │
│                             │                                   │
│                      ┌──────▼───────┐                          │
│                      │  A2A Payments │  ← Monad-first feature  │
│                      │ (Agent↔Agent) │                          │
│                      └──────────────┘                          │
│                                                                 │
│  ┌──────────────┐    ┌──────────────┐                          │
│  │ SeniorPool   │    │ GeneralPool  │  ← Liquidity Pools      │
│  └──────────────┘    └──────────────┘                          │
└─────────────────────────────────────────────────────────────────┘
```

---

## Core Concepts

### 1. Agent Identity (AgentRegistry)

Every AI agent registers on-chain and gets:
- **Credit Score:** 200–850 (default 350)
- **KYA Tier:** 0 (None) → 1 (Basic) → 2 (Enhanced) → 3 (Full)
- **Credit Level:** L0–L4, computed from score + KYA tier
- **Agent Type:** TypeA (trading) or TypeB (service-based)

**Credit Level Matrix:**

| Level | Score Required | KYA Required | Max Credit |
|-------|---------------|--------------|------------|
| L0 | Any | None (0) | $0 |
| L1 | Any | Basic (1) | $500 |
| L2 | ≥ 500 | Basic (1) | $20,000 |
| L3 | ≥ 650 | Enhanced (2) | $50,000 |
| L4 | ≥ 750 | Enhanced (2) | $500,000 |

### 2. Deterministic Wallets (AgentWalletFactory)

Wallets are deployed via **CREATE2** — the EVM equivalent of Solana's PDAs. Given the same owner, the wallet address is deterministic and predictable before deployment.

```
salt = keccak256(owner)
address = keccak256(0xff, factory, salt, keccak256(initCode))
```

Each wallet enforces **8 safety layers** at the contract level:
1. **Venue whitelist** — only approved recipients
2. **Per-tx limit** — owner-set absolute cap
3. **Per-trade limit** — max 20% of wallet balance per trade
4. **Daily spend limit** — rolling 24h cap
5. **Per-venue exposure** — max 50% of balance per venue
6. **NAV health check** — blocks trades that would trigger liquidation
7. **Freeze/unfreeze** — emergency kill switch
8. **Liquidation protection** — permissionless liquidation when NAV drops

### 3. Credit Scoring (KrexitScore)

Scores are computed as: `clamp(fairscaleBase + onChainModifiers, 200, 850)`

**On-chain modifiers:**

| Event | Points |
|-------|--------|
| On-time repayment | +8 |
| Early repayment | +10 |
| Late repayment | -15 |
| Missed payment | -30 |
| Liquidation | -40 |
| Default | -100 |
| Account age | +5/month (cap +60) |
| Credit cycles | +3/cycle (cap +30) |
| Volume | +2 per $10K (cap +20) |

**Interest rates by level:**

| Level | APR | Daily Rate |
|-------|-----|-----------|
| L1 | 36.50% | 10 bps |
| L2 | 29.20% | 8 bps |
| L3 | 25.55% | 7 bps |
| L4 | 21.90% | 6 bps |

### 4. Payment Router (x402 + Revenue Validation)

The PaymentRouter handles x402 payments with a **2% platform fee** and includes a **3-layer revenue validation engine**:

**Layer 1 — Source Classification (hard rejects):**
- Self-payment (agent pays itself) → Rejected
- Owner payment → Rejected
- Associated wallet → Rejected
- Blocklisted address → Rejected

**Fast-path verifications (auto-approve):**
- x402 payments → Verified
- Platform-whitelisted → Verified
- Registered revenue source → Verified

**Layer 2 — Pattern Detection:**
- Round-trip detection (95% amount similarity within 24h window)
- Score ≥ 80 → Reject, ≥ 40 → Quarantine

**Layer 3 — Economic Validation:**
- Amount anomaly (>10x expected daily revenue)
- Extreme overshoot (>20x) → auto-reject
- Large payment (>50% of total credit)

**Quarantine review decisions:**
- `APPROVE` — mark as verified
- `REJECT` — mark as rejected, increment violations
- `APPROVE_AND_WHITELIST` — verify + add source to registered sources
- `REJECT_AND_BLOCKLIST` — reject + add source to global blocklist

### 5. Agent-to-Agent Payments — Monad-first

**A2A payments** let registered Krexa agents pay each other directly on-chain. This is a **Monad-first feature** — not yet available on Solana.

**How it works:**
1. Both agents must be registered & active in AgentRegistry
2. Caller must be the sending agent or an approved facilitator (oracle)
3. USDC is pulled from the sender's EOA (where approval lives)
4. 2% platform fee is deducted and sent to treasury
5. Remainder is delivered to receiver's CREATE2 wallet (if linked) or EOA
6. If receiver has an active settlement (credit line), repayment split applies automatically
7. Payment is credited to receiver's revenue validator as verified revenue

**Functions:**
- `agentPay(fromAgent, toAgent, amount, memo)` — single payment
- `agentPayBatch(fromAgent, toAgents[], amounts[], memos[])` — batch (up to N recipients)
- `getA2AStats(agent)` — returns (totalSent, totalReceived, txCount)

**Safety checks:**
- Both agents must be registered and active
- No self-payments (fromAgent ≠ toAgent)
- Blocklist enforced on both sender and receiver
- Pause state enforced
- Non-zero amount required

**Wallet resolution logic:**
```
Sender:  always uses EOA address (where USDC.approve() was called)
Receiver: resolves to CREATE2 wallet if linked in registry, otherwise EOA
```

This ensures USDC transfers work correctly — approvals are always on the EOA, and receiver funds accumulate in their managed wallet.

### 6. Service Plans (ServicePlan)

For Type B agents (service-based businesses) — manages milestone-based credit disbursement with health monitoring.

**Health Zones:**

| Zone | Revenue Ratio | Effect |
|------|--------------|--------|
| Green | ≥ 80% of projected | All milestones available |
| Yellow | ≥ 50% | Milestones delayed 7 days |
| Orange | ≥ 25% | Disbursements paused |
| Red | < 25% | Wind-down eligible |

**Zero-revenue overrides:** 7+ days → Orange, 14+ days → Red

**Wind-down lifecycle:** None → Grace (48h) → Executing → Completed

---

## Integration Guide

### Register an Agent

```solidity
// 1. Register
AgentRegistry(0xd0CB...c872).registerAgent("ipfs://agent-metadata");

// 2. Oracle sets KYA + score (off-chain oracle call)
AgentRegistry.updateKya(agentAddress, 2);       // Enhanced KYA
AgentRegistry.updateCreditScore(agentAddress, 700); // Score → L3
```

### Create a Deterministic Wallet

```solidity
AgentWalletFactory factory = AgentWalletFactory(0x120E...8c65);

// Predict address before deployment
address predicted = factory.predictWalletAddress(owner, operator, dailyLimit, perTxLimit);

// Deploy (one per owner, deterministic)
address wallet = factory.createWallet(operator, dailyLimit, perTxLimit);
// wallet == predicted ✓
```

### Make an x402 Payment

```solidity
PaymentRouter router = PaymentRouter(0xA32D...0786);

// Oracle signs the payment off-chain, then:
router.executePayment(
    X402Payment({
        from: payer,
        to: merchant,
        amount: 100e6,      // 100 USDC
        nonce: 1,
        deadline: block.timestamp + 1 hours,
        paymentId: "pay_001"
    }),
    oracleSignature
);
// 2% platform fee deducted, remainder to merchant (or split with vault if settlement active)
```

### Agent-to-Agent Payment (Monad-first)

```solidity
PaymentRouter router = PaymentRouter(0xA32D...0786);
IERC20 usdc = IERC20(0x460b...e103);

// 1. Approve USDC spending (sender EOA)
usdc.approve(address(router), 100e6);

// 2. Single A2A payment
router.agentPay(
    senderAgent,    // registered agent EOA
    receiverAgent,  // registered agent EOA
    100e6,          // 100 USDC
    bytes32("invoice_001")  // memo/reference
);
// → 2 USDC platform fee, 98 USDC to receiver's wallet

// 3. Batch payment (pay multiple agents at once)
address[] memory agents = new address[](2);
uint256[] memory amounts = new uint256[](2);
bytes32[] memory memos = new bytes32[](2);
agents[0] = agentA; amounts[0] = 50e6; memos[0] = bytes32("pay_a");
agents[1] = agentB; amounts[1] = 30e6; memos[1] = bytes32("pay_b");
router.agentPayBatch(senderAgent, agents, amounts, memos);

// 4. Query A2A stats
(uint256 sent, uint256 received, uint256 txCount) = router.getA2AStats(agentAddress);
```

### Revenue Validation Flow

```solidity
// 1. Create validator for merchant
router.createRevenueValidator(merchant, agentWallet, agentOwner, expectedDaily, totalCredit);

// 2. Register known revenue sources
router.registerRevenueSource(merchant, customerAddress);

// 3. Validate incoming revenue
router.validateRevenue(merchant, source, amount, isX402);
// Emits RevenueClassified(merchant, source, amount, classification, reason, patternScore)

// 4. Review quarantined payments
router.reviewQuarantined(merchant, paymentIndex, DECISION_APPROVE);
```

### Service Plan Lifecycle

```solidity
ServicePlan sp = ServicePlan(0xaaE9...9B2);

// 1. Create plan with milestones
MilestoneInput[] memory ms = new MilestoneInput[](2);
ms[0] = MilestoneInput(50000e6, descHash1, eligibleAt1);
ms[1] = MilestoneInput(50000e6, descHash2, eligibleAt2);
sp.createPlan(agentWallet, 100000e6, ms);

// 2. Fund the plan
USDC.approve(address(sp), 100000e6);
sp.fundPlan(agentWallet, 100000e6);

// 3. Oracle disburses milestones (health-gated)
sp.disburseMilestone(agentWallet, 0); // 50K USDC to agent

// 4. Monitor revenue health
sp.setProjectedRevenue(agentWallet, 10000e6);
sp.recordRevenue(agentWallet, 8500e6); // → Green zone

// 5. Wind-down if Red
sp.startWindDown(agentWallet);  // → Grace (48h)
sp.advanceWindDown(agentWallet); // → Executing → Completed
```

---

## Key Constants (Solana Parity)

All constants match `krexa-common/constants.rs`:

| Constant | Value | Location |
|----------|-------|----------|
| MIN_CREDIT_SCORE | 200 | AgentRegistry |
| MAX_CREDIT_SCORE | 850 | AgentRegistry |
| DEFAULT_CREDIT_SCORE | 350 | AgentRegistry |
| LIQUIDATION_SCORE_PENALTY | 40 | AgentRegistry |
| MAX_PER_TRADE_BPS | 2000 (20%) | AgentWallet |
| MAX_PER_VENUE_BPS | 5000 (50%) | AgentWallet |
| WITHDRAWAL_BUFFER_BPS | 12000 (120%) | AgentWallet |
| LIQUIDATION_REWARD_BPS | 50 (0.5%) | AgentWallet |
| MAX_PLATFORM_FEE_BPS | 1000 (10%) | PaymentRouter |
| PATTERN_REJECT_THRESHOLD | 80 | PaymentRouter |
| PATTERN_QUARANTINE_THRESHOLD | 40 | PaymentRouter |
| ROUND_TRIP_SIMILARITY_BPS | 9500 (95%) | PaymentRouter |
| ROUND_TRIP_WINDOW | 86400s (24h) | PaymentRouter |
| MAX_REVENUE_SOURCES | 30 | PaymentRouter |
| MAX_MILESTONES | 8 | ServicePlan |
| REVENUE_GREEN_BPS | 8000 (80%) | ServicePlan |
| REVENUE_YELLOW_BPS | 5000 (50%) | ServicePlan |
| REVENUE_ORANGE_BPS | 2500 (25%) | ServicePlan |
| ZERO_REVENUE_ORANGE_DAYS | 7 | ServicePlan |
| ZERO_REVENUE_RED_DAYS | 14 | ServicePlan |
| WIND_DOWN_GRACE | 172800s (48h) | ServicePlan |
| YELLOW_MILESTONE_DELAY | 604800s (7d) | ServicePlan |

---

## Solana ↔ Monad Parity

Krexa runs on **both Solana and Monad** with feature parity + Monad-exclusive features:

| Solana Program | Monad Contract | Key Difference |
|---------------|----------------|----------------|
| krexa-agent-registry | AgentRegistry | Identical logic, EVM storage layout |
| krexa-agent-wallet | AgentWallet + AgentWalletFactory | PDA → CREATE2 deterministic addresses |
| krexa-payment-router | PaymentRouter | CPI → internal calls, same 3-layer validation |
| krexa-service-plan | ServicePlan | CPI USDC transfer → ERC-20 approve/transferFrom |
| krexit-score | KrexitScore | Same modifier math, same interest rates |
| — | PaymentRouter (A2A) | **Monad-first:** agentPay, agentPayBatch, A2A stats |

**Solana programs:** 5 Anchor programs on mainnet-beta
**Monad contracts:** 10 Solidity contracts (same logic split across more granular contracts)

**Monad-exclusive features:**
- Agent-to-Agent payments (`agentPay`, `agentPayBatch`)
- A2A stats tracking (sent/received/txCount per agent)
- Automatic settlement routing on A2A receive
- Revenue validator credit on A2A receive

---

## Verification

All contracts can be verified on Monad Explorer:

```bash
# Sourcify
forge verify-contract <address> <ContractName> \
  --chain 10143 --verifier sourcify \
  --verifier-url https://sourcify-api-monad.blockvision.org/

# Monadscan
forge verify-contract <address> <ContractName> \
  --chain 10143 --verifier etherscan \
  --etherscan-api-key $MONADSCAN_API_KEY
```

---

## Contact

**Protocol:** Krexa · [krexa.xyz](https://krexa.xyz) · [@krexa_xyz](https://x.com/krexa_xyz)
**Repo:** github.com/Krexa-xyz/krexa-contract
