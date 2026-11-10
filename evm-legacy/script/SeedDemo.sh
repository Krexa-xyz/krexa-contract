#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# SeedDemo.sh — Populate Base Sepolia with Krexa demo data
#
# Usage:
#   chmod +x script/SeedDemo.sh
#   ./script/SeedDemo.sh
#
# Prerequisites:
#   1. Copy .env.example → .env and fill in:
#        DEPLOYER_PRIVATE_KEY=0x...   (oracle/admin key: 0xA1090527...)
#        BASE_SEPOLIA_RPC_URL=https://...
#   2. Ensure deployer has ~800,000 test USDC on Base Sepolia
#        → https://faucet.circle.com  (select "Base Sepolia")
#   3. Ensure deployer has Base Sepolia ETH for gas
#        → https://faucet.quicknode.com/base/sepolia
#
# What this does:
#   Step 1 — Registers 4 merchants with credit scores (Tier A/B/C/D)
#   Step 2 — Deposits 500k + 200k USDC into SeniorPool / GeneralPool
#   Step 3 — Creates + funds Vault A (100k, 12% APY, mid-repayment)
#   Step 3b — Creates Vault B (50k, 15% APY, left in Fundraising for live demo)
#   Step 4 — Generates 20 x402 payment events (~42k USDC routed to vault)
#
# Idempotent: already-completed steps are skipped on re-run.
# ─────────────────────────────────────────────────────────────────────────────

set -e
cd "$(dirname "$0")/.."   # run from base-contracts/

# ── Load environment ─────────────────────────────────────────────────────────
if [ -f .env ]; then
    source .env
else
    echo "ERROR: .env not found. Copy .env.example → .env and fill in your keys."
    exit 1
fi

# ── Validate required vars ───────────────────────────────────────────────────
if [ -z "$DEPLOYER_PRIVATE_KEY" ]; then
    echo "ERROR: DEPLOYER_PRIVATE_KEY is not set in .env"
    exit 1
fi

if [ -z "$BASE_SEPOLIA_RPC_URL" ]; then
    echo "ERROR: BASE_SEPOLIA_RPC_URL is not set in .env"
    exit 1
fi

echo "================================================"
echo " Krexa Demo Seed — Base Sepolia"
echo "================================================"
echo " RPC: $BASE_SEPOLIA_RPC_URL"
echo " Oracle/Admin: $(cast wallet address --private-key $DEPLOYER_PRIVATE_KEY 2>/dev/null || echo '(install cast to preview)')"
echo ""
echo " This will broadcast real transactions to Base Sepolia."
echo " Estimated gas cost: ~0.02 ETH"
echo ""
read -p "Continue? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi
echo ""

# ── Run the Forge script ─────────────────────────────────────────────────────
forge script script/SeedDemo.s.sol:SeedDemo \
    --rpc-url "$BASE_SEPOLIA_RPC_URL" \
    --private-key "$DEPLOYER_PRIVATE_KEY" \
    --broadcast \
    --slow \
    -vvvv

echo ""
echo "================================================"
echo " Done! View results:"
echo "   https://sepolia.basescan.org"
echo "   https://t-credit.vercel.app"
echo "================================================"
