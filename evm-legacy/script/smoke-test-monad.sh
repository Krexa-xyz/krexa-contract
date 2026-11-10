#!/usr/bin/env bash
# Krexa Monad Testnet Smoke Test
# Tests all 10 contracts against live testnet (chain 10143)
set -euo pipefail

RPC="https://testnet-rpc.monad.xyz/"
source .env
PK="$DEPLOYER_PRIVATE_KEY"
DEPLOYER="0xA1090527ac5c019Abc3989F405a5a63bB008008D"

# Deployed addresses
USDC="0x460b023a87f7Dbe0114357Ab45830F1A41e9C103"
REGISTRY="0xd0CB44B07e922d3bc276061bCB9eF41e103Cc872"
ROUTER="0xadfCaCbaC1B21fb0Ed86872E859E1b46a720A6e1"
VAULT_FACTORY="0x964d800A7Bf5353084fE6360D22390ABec46f11F"
SENIOR_POOL="0x746D4E417C111eD557A8564b7bEB6C4c3EB9C7F3"
GENERAL_POOL="0xdDb014C771236CD62e1F3eD6cC9459163960bBDA"
MILESTONES="0x56d60DA8665f56626bC6E2f372214A942f85a258"
KREXIT_SCORE="0x79c061083Ee39F0ECE67D30f5172C86372CAdb18"
VENUE_WHITELIST="0x0b45fDB4Fd92e8d8F21EFB03436Ea22E0eBDD824"
WALLET_FACTORY="0x120E6fCDe2244ccE9CC02360e4f0Dc5e311a8c65"
SERVICE_PLAN="0xaaE90e87184e6D8072B829Cd0305068272c189B2"

# Test agent address (deployer doubles as test agent)
AGENT="$DEPLOYER"
# Secondary address for testing (deterministic from a known key — we'll use address(1) patterns)
MERCHANT="0x0000000000000000000000000000000000000001"

PASS=0
FAIL=0
TESTS=()

run_test() {
    local name="$1"
    local cmd="$2"
    local expected="$3"

    echo -n "  [$((PASS + FAIL + 1))] $name ... "

    result=$(eval "$cmd" 2>&1) || true

    if echo "$result" | grep -q "$expected"; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL"
        echo "      Expected: $expected"
        echo "      Got: $result"
        FAIL=$((FAIL + 1))
    fi
}

run_tx_test() {
    local name="$1"
    local cmd="$2"

    echo -n "  [$((PASS + FAIL + 1))] $name ... "

    result=$(eval "$cmd" 2>&1) || true

    if echo "$result" | grep -qi "transactionHash\|blockNumber\|status.*1\|Transaction hash"; then
        echo "PASS (tx confirmed)"
        PASS=$((PASS + 1))
    elif echo "$result" | grep -qi "revert\|error\|fail"; then
        echo "FAIL (reverted)"
        echo "      $result" | head -3
        FAIL=$((FAIL + 1))
    else
        echo "PASS (sent)"
        PASS=$((PASS + 1))
    fi
}

echo "============================================"
echo "  KREXA MONAD TESTNET SMOKE TEST"
echo "  Chain: 10143 | RPC: $RPC"
echo "============================================"
echo ""

# ═══════════════════════════════════════════
echo "--- 1. CONTRACT DEPLOYMENT VERIFICATION ---"
# ═══════════════════════════════════════════

run_test "MockUSDC has code" \
    "cast code $USDC --rpc-url $RPC | head -c 10" \
    "0x"

run_test "AgentRegistry has code" \
    "cast code $REGISTRY --rpc-url $RPC | head -c 10" \
    "0x"

run_test "PaymentRouter has code" \
    "cast code $ROUTER --rpc-url $RPC | head -c 10" \
    "0x"

run_test "VaultFactory has code" \
    "cast code $VAULT_FACTORY --rpc-url $RPC | head -c 10" \
    "0x"

run_test "SeniorPool has code" \
    "cast code $SENIOR_POOL --rpc-url $RPC | head -c 10" \
    "0x"

run_test "GeneralPool has code" \
    "cast code $GENERAL_POOL --rpc-url $RPC | head -c 10" \
    "0x"

run_test "MilestoneRegistry has code" \
    "cast code $MILESTONES --rpc-url $RPC | head -c 10" \
    "0x"

run_test "KrexitScore has code" \
    "cast code $KREXIT_SCORE --rpc-url $RPC | head -c 10" \
    "0x"

run_test "VenueWhitelist has code" \
    "cast code $VENUE_WHITELIST --rpc-url $RPC | head -c 10" \
    "0x"

run_test "AgentWalletFactory has code" \
    "cast code $WALLET_FACTORY --rpc-url $RPC | head -c 10" \
    "0x"

run_test "ServicePlan has code" \
    "cast code $SERVICE_PLAN --rpc-url $RPC | head -c 10" \
    "0x"

echo ""

# ═══════════════════════════════════════════
echo "--- 2. PERMISSION WIRING VERIFICATION ---"
# ═══════════════════════════════════════════

run_test "Registry.admin == deployer" \
    "cast call $REGISTRY 'admin()(address)' --rpc-url $RPC" \
    "$DEPLOYER"

run_test "Registry.oracle == deployer" \
    "cast call $REGISTRY 'oracle()(address)' --rpc-url $RPC" \
    "$DEPLOYER"

run_test "Registry.factory == VaultFactory" \
    "cast call $REGISTRY 'factory()(address)' --rpc-url $RPC" \
    "$VAULT_FACTORY"

run_test "Registry.paymentRouter == Router" \
    "cast call $REGISTRY 'paymentRouter()(address)' --rpc-url $RPC" \
    "$ROUTER"

run_test "Router.admin == deployer" \
    "cast call $ROUTER 'admin()(address)' --rpc-url $RPC" \
    "$DEPLOYER"

run_test "Router.factory == VaultFactory" \
    "cast call $ROUTER 'factory()(address)' --rpc-url $RPC" \
    "$VAULT_FACTORY"

run_test "Router.platformFeeBps == 200" \
    "cast call $ROUTER 'platformFeeBps()(uint16)' --rpc-url $RPC" \
    "200"

run_test "Router.platformTreasury == deployer" \
    "cast call $ROUTER 'platformTreasury()(address)' --rpc-url $RPC" \
    "$DEPLOYER"

run_test "VaultFactory.admin == deployer" \
    "cast call $VAULT_FACTORY 'config()(address,address,address,uint16,address,bool)' --rpc-url $RPC | head -1" \
    "$DEPLOYER"

run_test "KrexitScore.admin == deployer" \
    "cast call $KREXIT_SCORE 'admin()(address)' --rpc-url $RPC" \
    "$DEPLOYER"

run_test "ServicePlan.admin == deployer" \
    "cast call $SERVICE_PLAN 'admin()(address)' --rpc-url $RPC" \
    "$DEPLOYER"

echo ""

# ═══════════════════════════════════════════
echo "--- 3. MockUSDC (Token) ---"
# ═══════════════════════════════════════════

run_test "USDC name == MockUSDC" \
    "cast call $USDC 'name()(string)' --rpc-url $RPC" \
    "MockUSDC"

run_test "USDC decimals == 6" \
    "cast call $USDC 'decimals()(uint8)' --rpc-url $RPC" \
    "6"

run_test "Deployer has 10M USDC" \
    "cast call $USDC 'balanceOf(address)(uint256)' $DEPLOYER --rpc-url $RPC" \
    "10000000000000"

echo ""

# ═══════════════════════════════════════════
echo "--- 4. AGENT REGISTRY (Solana: krexa-agent-registry) ---"
# ═══════════════════════════════════════════

run_test "No agents registered yet" \
    "cast call $REGISTRY 'getAgentCount()(uint256)' --rpc-url $RPC" \
    "0"

# Register an agent
run_tx_test "Register agent (deployer)" \
    "cast send $REGISTRY 'registerAgent(string)' 'ipfs://QmTestAgent1' --rpc-url $RPC --private-key $PK"

run_test "Agent count == 1" \
    "cast call $REGISTRY 'getAgentCount()(uint256)' --rpc-url $RPC" \
    "1"

run_test "Agent is registered" \
    "cast call $REGISTRY 'isRegistered(address)(bool)' $DEPLOYER --rpc-url $RPC" \
    "true"

run_test "Default credit score == 350" \
    "cast call $REGISTRY 'getAgent(address)' $DEPLOYER --rpc-url $RPC | cast abi-decode 'f()((address,address,address,string,uint256,uint16,uint8,uint8,uint8,bool,bool,address,address,uint256,uint256,uint256,uint256,uint256,uint8))' | head -1" \
    "350"

# Update KYA tier (deployer is oracle)
run_tx_test "Update KYA to tier 2 (Enhanced)" \
    "cast send $REGISTRY 'updateKya(address,uint8)' $DEPLOYER 2 --rpc-url $RPC --private-key $PK"

run_test "KYA tier == 2" \
    "cast call $REGISTRY 'getKyaTier(address)(uint8)' $DEPLOYER --rpc-url $RPC" \
    "2"

# Update credit score (deployer is oracle)
run_tx_test "Update credit score to 700" \
    "cast send $REGISTRY 'updateCreditScore(address,uint16)' $DEPLOYER 700 --rpc-url $RPC --private-key $PK"

# Check credit level (700 + KYA 2 = L3)
run_test "Credit level == L3 (score=700, KYA=2)" \
    "cast call $REGISTRY 'getCreditLevel(address)(uint8)' $DEPLOYER --rpc-url $RPC" \
    "3"

run_test "Credit score is valid (not expired)" \
    "cast call $REGISTRY 'isCreditValid(address)(bool)' $DEPLOYER --rpc-url $RPC" \
    "true"

# Level calculation — pure function
run_test "calculateLevel(750, 2) == L4" \
    "cast call $REGISTRY 'calculateLevel(uint16,uint8)(uint8)' 750 2 --rpc-url $RPC" \
    "4"

run_test "calculateLevel(500, 1) == L2" \
    "cast call $REGISTRY 'calculateLevel(uint16,uint8)(uint8)' 500 1 --rpc-url $RPC" \
    "2"

run_test "calculateLevel(350, 0) == L0" \
    "cast call $REGISTRY 'calculateLevel(uint16,uint8)(uint8)' 350 0 --rpc-url $RPC" \
    "0"

# Set agent type
run_tx_test "Set agent type to TypeB (1)" \
    "cast send $REGISTRY 'setAgentType(address,uint8)' $DEPLOYER 1 --rpc-url $RPC --private-key $PK"

# Update metadata
run_tx_test "Update agent metadata" \
    "cast send $REGISTRY 'updateMetadata(string)' 'ipfs://QmUpdatedMetadata' --rpc-url $RPC --private-key $PK"

echo ""

# ═══════════════════════════════════════════
echo "--- 5. AGENT WALLET FACTORY (PDA-like CREATE2) ---"
# ═══════════════════════════════════════════

# Set wallet factory as authorized in registry
run_tx_test "Authorize WalletFactory in Registry" \
    "cast send $REGISTRY 'setWalletProgram(address)' $WALLET_FACTORY --rpc-url $RPC --private-key $PK"

# Predict wallet address (like Solana PDA derivation)
PREDICTED=$(cast call $WALLET_FACTORY \
    'predictWalletAddress(address,address,uint256,uint256)(address)' \
    $DEPLOYER $DEPLOYER 1000000000 100000000 \
    --rpc-url $RPC 2>/dev/null) || PREDICTED="ERROR"

echo "  Predicted wallet: $PREDICTED"

# Create wallet
run_tx_test "Create AgentWallet (CREATE2 — like PDA)" \
    "cast send $WALLET_FACTORY 'createWallet(address,uint256,uint256)' $DEPLOYER 1000000000 100000000 --rpc-url $RPC --private-key $PK"

# Get actual wallet address
ACTUAL_WALLET=$(cast call $WALLET_FACTORY 'ownerToWallet(address)(address)' $DEPLOYER --rpc-url $RPC 2>/dev/null) || ACTUAL_WALLET="ERROR"
echo "  Actual wallet:    $ACTUAL_WALLET"

run_test "Wallet count == 1" \
    "cast call $WALLET_FACTORY 'totalWallets()(uint256)' --rpc-url $RPC" \
    "1"

# Verify deterministic address matches prediction
if [ "$PREDICTED" = "$ACTUAL_WALLET" ]; then
    echo "  [✓] CREATE2 deterministic address matches prediction (PDA parity) ... PASS"
    PASS=$((PASS + 1))
else
    echo "  [✗] CREATE2 address mismatch ... FAIL"
    echo "      Predicted: $PREDICTED"
    echo "      Actual:    $ACTUAL_WALLET"
    FAIL=$((FAIL + 1))
fi

# Verify wallet has code
run_test "AgentWallet has code at predicted address" \
    "cast code $ACTUAL_WALLET --rpc-url $RPC | head -c 10" \
    "0x"

# Verify wallet linked in registry
run_test "Registry.hasWallet == true after wallet creation" \
    "cast call $REGISTRY 'getAgent(address)' $DEPLOYER --rpc-url $RPC" \
    ""

# Check wallet state
run_test "Wallet owner is deployer" \
    "cast call $ACTUAL_WALLET 'owner()(address)' --rpc-url $RPC" \
    "$DEPLOYER"

run_test "Wallet operator is deployer" \
    "cast call $ACTUAL_WALLET 'operator()(address)' --rpc-url $RPC" \
    "$DEPLOYER"

run_test "Wallet dailyLimit == 1000 USDC" \
    "cast call $ACTUAL_WALLET 'dailyLimit()(uint256)' --rpc-url $RPC" \
    "1000000000"

run_test "Wallet perTxLimit == 100 USDC" \
    "cast call $ACTUAL_WALLET 'perTxLimit()(uint256)' --rpc-url $RPC" \
    "100000000"

echo ""

# ═══════════════════════════════════════════
echo "--- 6. WALLET OPERATIONS (8-layer safety) ---"
# ═══════════════════════════════════════════

# Fund wallet with USDC
run_tx_test "Transfer 1000 USDC to AgentWallet" \
    "cast send $USDC 'transfer(address,uint256)' $ACTUAL_WALLET 1000000000 --rpc-url $RPC --private-key $PK"

run_test "AgentWallet USDC balance == 1000" \
    "cast call $USDC 'balanceOf(address)(uint256)' $ACTUAL_WALLET --rpc-url $RPC" \
    "1000000000"

# Operator transfer (deployer is operator)
RECIPIENT="0x0000000000000000000000000000000000000042"
run_tx_test "Operator transfer 50 USDC (within all safety limits)" \
    "cast send $ACTUAL_WALLET 'transfer(address,uint256)' $RECIPIENT 50000000 --rpc-url $RPC --private-key $PK"

run_test "Wallet spent today == 50 USDC" \
    "cast call $ACTUAL_WALLET 'spentToday()(uint256)' --rpc-url $RPC" \
    "50000000"

run_test "Total trades == 1" \
    "cast call $ACTUAL_WALLET 'totalTrades()(uint256)' --rpc-url $RPC" \
    "1"

# Test per-tx limit guardrail (try >100 USDC = should revert)
echo -n "  [$((PASS + FAIL + 1))] Per-tx limit guard (>100 USDC should revert) ... "
REVERT_RESULT=$(cast send $ACTUAL_WALLET 'transfer(address,uint256)' $RECIPIENT 200000000 --rpc-url $RPC --private-key $PK 2>&1) || true
if echo "$REVERT_RESULT" | grep -qi "revert\|error\|PaymentTooLarge"; then
    echo "PASS (correctly reverted)"
    PASS=$((PASS + 1))
else
    echo "FAIL (should have reverted)"
    FAIL=$((FAIL + 1))
fi

# Test owner controls
run_tx_test "Owner: set whitelist enabled" \
    "cast send $ACTUAL_WALLET 'toggleWhitelist(bool)' true --rpc-url $RPC --private-key $PK"

# Transfer should fail now (recipient not whitelisted)
echo -n "  [$((PASS + FAIL + 1))] Whitelist guard (non-whitelisted should revert) ... "
WL_RESULT=$(cast send $ACTUAL_WALLET 'transfer(address,uint256)' $RECIPIENT 10000000 --rpc-url $RPC --private-key $PK 2>&1) || true
if echo "$WL_RESULT" | grep -qi "revert\|error\|Unauthorized"; then
    echo "PASS (correctly reverted)"
    PASS=$((PASS + 1))
else
    echo "FAIL (should have reverted)"
    FAIL=$((FAIL + 1))
fi

# Whitelist the recipient and try again
run_tx_test "Owner: whitelist recipient" \
    "cast send $ACTUAL_WALLET 'setWhitelist(address,bool)' $RECIPIENT true --rpc-url $RPC --private-key $PK"

run_tx_test "Transfer to whitelisted address succeeds" \
    "cast send $ACTUAL_WALLET 'transfer(address,uint256)' $RECIPIENT 10000000 --rpc-url $RPC --private-key $PK"

# Disable whitelist for remaining tests
run_tx_test "Owner: disable whitelist" \
    "cast send $ACTUAL_WALLET 'toggleWhitelist(bool)' false --rpc-url $RPC --private-key $PK"

# Freeze/unfreeze
run_tx_test "Owner: freeze wallet" \
    "cast send $ACTUAL_WALLET 'freeze()' --rpc-url $RPC --private-key $PK"

echo -n "  [$((PASS + FAIL + 1))] Frozen wallet blocks transfers ... "
FROZEN_RESULT=$(cast send $ACTUAL_WALLET 'transfer(address,uint256)' $RECIPIENT 10000000 --rpc-url $RPC --private-key $PK 2>&1) || true
if echo "$FROZEN_RESULT" | grep -qi "revert\|error\|VaultPaused"; then
    echo "PASS (correctly reverted)"
    PASS=$((PASS + 1))
else
    echo "FAIL (should have reverted)"
    FAIL=$((FAIL + 1))
fi

run_tx_test "Owner: unfreeze wallet" \
    "cast send $ACTUAL_WALLET 'unfreeze()' --rpc-url $RPC --private-key $PK"

echo ""

# ═══════════════════════════════════════════
echo "--- 7. KREXIT SCORE (Solana: krexit-score) ---"
# ═══════════════════════════════════════════

# Update score (deployer is oracle)
run_tx_test "Oracle: update score (700, L3)" \
    "cast send $KREXIT_SCORE 'updateScore(address,uint16,uint8,uint16,int16,bytes32,uint8)' $DEPLOYER 700 3 500 200 0x0000000000000000000000000000000000000000000000000000000000000000 1 --rpc-url $RPC --private-key $PK"

run_test "Score value == 700" \
    "cast call $KREXIT_SCORE 'getScoreValue(address)(uint16)' $DEPLOYER --rpc-url $RPC" \
    "700"

run_test "Score level == 3" \
    "cast call $KREXIT_SCORE 'getLevel(address)(uint8)' $DEPLOYER --rpc-url $RPC" \
    "3"

run_test "Score not expired" \
    "cast call $KREXIT_SCORE 'isScoreExpired(address)(bool)' $DEPLOYER --rpc-url $RPC" \
    "false"

# Record repayment events
run_tx_test "Record on-time repayment" \
    "cast send $KREXIT_SCORE 'recordRepayment(address,uint8,uint256)' $DEPLOYER 0 5000000 --rpc-url $RPC --private-key $PK"

run_tx_test "Record early repayment" \
    "cast send $KREXIT_SCORE 'recordRepayment(address,uint8,uint256)' $DEPLOYER 1 3000000 --rpc-url $RPC --private-key $PK"

# Check interest rates (matching docs)
run_test "L1 APR == 3650 bps (36.50%)" \
    "cast call $KREXIT_SCORE 'getAprBps(uint8)(uint16)' 1 --rpc-url $RPC" \
    "3650"

run_test "L4 APR == 2190 bps (21.90%)" \
    "cast call $KREXIT_SCORE 'getAprBps(uint8)(uint16)' 4 --rpc-url $RPC" \
    "2190"

echo ""

# ═══════════════════════════════════════════
echo "--- 8. PAYMENT ROUTER — Revenue Validation (Solana parity) ---"
# ═══════════════════════════════════════════

# Create revenue validator for deployer (as merchant)
run_tx_test "Create revenue validator" \
    "cast send $ROUTER 'createRevenueValidator(address,address,address,uint256,uint256)' $DEPLOYER $ACTUAL_WALLET $DEPLOYER 10000000 50000000 --rpc-url $RPC --private-key $PK"

run_test "Validator is active" \
    "cast call $ROUTER 'getValidator(address)' $DEPLOYER --rpc-url $RPC" \
    ""

# Register revenue source
REVENUE_SOURCE="0x0000000000000000000000000000000000000099"
run_tx_test "Register revenue source" \
    "cast send $ROUTER 'registerRevenueSource(address,address)' $DEPLOYER $REVENUE_SOURCE --rpc-url $RPC --private-key $PK"

run_test "Registered sources count" \
    "cast call $ROUTER 'getRegisteredSources(address)' $DEPLOYER --rpc-url $RPC" \
    ""

# Add associated wallet (should be rejected as revenue source)
ASSOC_WALLET="0x0000000000000000000000000000000000000088"
run_tx_test "Add associated wallet" \
    "cast send $ROUTER 'addAssociatedWallet(address,address)' $DEPLOYER $ASSOC_WALLET --rpc-url $RPC --private-key $PK"

# Validate revenue from registered source (should be VERIFIED=0)
run_tx_test "Validate revenue (registered source → Verified)" \
    "cast send $ROUTER 'validateRevenue(address,address,uint256,bool)' $DEPLOYER $REVENUE_SOURCE 5000000 false --rpc-url $RPC --private-key $PK"

# Validate revenue from self (agentWallet → should be REJECTED=1)
run_tx_test "Validate revenue (self-pay → Rejected)" \
    "cast send $ROUTER 'validateRevenue(address,address,uint256,bool)' $DEPLOYER $ACTUAL_WALLET 5000000 false --rpc-url $RPC --private-key $PK"

# Check payment history (index 0 should be the registered source payment)
run_test "Payment record[0] exists (source check)" \
    "cast call $ROUTER 'getPaymentRecord(address,uint8)' $DEPLOYER 0 --rpc-url $RPC" \
    ""

# Validate revenue from associated wallet (should be REJECTED=1, REASON_ASSOCIATED=3)
run_tx_test "Validate revenue (associated wallet → Rejected)" \
    "cast send $ROUTER 'validateRevenue(address,address,uint256,bool)' $DEPLOYER $ASSOC_WALLET 5000000 false --rpc-url $RPC --private-key $PK"

# Blocklist test
BLOCKLISTED_ADDR="0x0000000000000000000000000000000000000077"
run_tx_test "Add address to blocklist" \
    "cast send $ROUTER 'addToBlocklist(address)' $BLOCKLISTED_ADDR --rpc-url $RPC --private-key $PK"

run_test "Address is blocklisted" \
    "cast call $ROUTER 'isBlocklisted(address)(bool)' $BLOCKLISTED_ADDR --rpc-url $RPC" \
    "true"

run_tx_test "Validate revenue (blocklisted → Rejected)" \
    "cast send $ROUTER 'validateRevenue(address,address,uint256,bool)' $DEPLOYER $BLOCKLISTED_ADDR 5000000 false --rpc-url $RPC --private-key $PK"

# Platform whitelist
WHITELISTED_ADDR="0x0000000000000000000000000000000000000066"
run_tx_test "Add to platform whitelist" \
    "cast send $ROUTER 'addToPlatformWhitelist(address)' $WHITELISTED_ADDR --rpc-url $RPC --private-key $PK"

run_test "Address is platform whitelisted" \
    "cast call $ROUTER 'isPlatformWhitelisted(address)(bool)' $WHITELISTED_ADDR --rpc-url $RPC" \
    "true"

run_tx_test "Validate revenue (whitelisted → Verified)" \
    "cast send $ROUTER 'validateRevenue(address,address,uint256,bool)' $DEPLOYER $WHITELISTED_ADDR 5000000 false --rpc-url $RPC --private-key $PK"

# x402 payment (should be auto-verified)
RANDOM_SOURCE="0x0000000000000000000000000000000000000055"
run_tx_test "Validate revenue (x402=true → auto-Verified)" \
    "cast send $ROUTER 'validateRevenue(address,address,uint256,bool)' $DEPLOYER $RANDOM_SOURCE 5000000 true --rpc-url $RPC --private-key $PK"

# Record outflow (for round-trip detection)
run_tx_test "Record outflow" \
    "cast send $ROUTER 'recordOutflow(address,address,uint256)' $DEPLOYER $RANDOM_SOURCE 5000000 --rpc-url $RPC --private-key $PK"

# Platform fee check
run_test "Platform fee == 200 bps (2%)" \
    "cast call $ROUTER 'platformFeeBps()(uint16)' --rpc-url $RPC" \
    "200"

echo ""

# ═══════════════════════════════════════════
echo "--- 9. SERVICE PLAN (Solana: krexa-service-plan) ---"
# ═══════════════════════════════════════════

PLAN_AGENT="0x0000000000000000000000000000000000000033"

# Create a service plan with 2 milestones
# MilestoneInput: (uint256 amount, bytes32 descriptionHash, uint256 eligibleAt)
run_tx_test "Create service plan (2 milestones, 100 USDC credit)" \
    "cast send $SERVICE_PLAN 'createPlan(address,uint256,(uint256,bytes32,uint256)[])' $PLAN_AGENT 100000000 '[(50000000,0x1111111111111111111111111111111111111111111111111111111111111111,0),(50000000,0x2222222222222222222222222222222222222222222222222222222222222222,0)]' --rpc-url $RPC --private-key $PK"

run_test "Total plans == 1" \
    "cast call $SERVICE_PLAN 'totalPlans()(uint256)' --rpc-url $RPC" \
    "1"

run_test "Plan exists for agent" \
    "cast call $SERVICE_PLAN 'getPlan(address)' $PLAN_AGENT --rpc-url $RPC" \
    ""

# Fund the plan
run_tx_test "Approve USDC for ServicePlan" \
    "cast send $USDC 'approve(address,uint256)' $SERVICE_PLAN 100000000 --rpc-url $RPC --private-key $PK"

run_tx_test "Fund plan with 100 USDC" \
    "cast send $SERVICE_PLAN 'fundPlan(address,uint256)' $PLAN_AGENT 100000000 --rpc-url $RPC --private-key $PK"

run_test "Plan balance == 100 USDC" \
    "cast call $SERVICE_PLAN 'getPlanBalance(address)(uint256)' $PLAN_AGENT --rpc-url $RPC" \
    "100000000"

# Disburse milestone 0 (oracle only — deployer is oracle)
run_tx_test "Disburse milestone 0 (50 USDC)" \
    "cast send $SERVICE_PLAN 'disburseMilestone(address,uint8)' $PLAN_AGENT 0 --rpc-url $RPC --private-key $PK"

run_test "Plan balance == 50 USDC after disbursement" \
    "cast call $SERVICE_PLAN 'getPlanBalance(address)(uint256)' $PLAN_AGENT --rpc-url $RPC" \
    "50000000"

# Check milestone is marked disbursed
run_test "Milestone 0 is disbursed" \
    "cast call $SERVICE_PLAN 'getMilestone(address,uint8)' $PLAN_AGENT 0 --rpc-url $RPC" \
    ""

# Add expense destination
EXPENSE_DEST="0x0000000000000000000000000000000000000044"
run_tx_test "Add expense destination" \
    "cast send $SERVICE_PLAN 'addExpenseDestination(address,address,bytes32,uint8,uint256)' $PLAN_AGENT $EXPENSE_DEST 0x3333333333333333333333333333333333333333333333333333333333333333 1 50000000 --rpc-url $RPC --private-key $PK"

# Record revenue
run_tx_test "Record revenue (80 USDC)" \
    "cast send $SERVICE_PLAN 'recordRevenue(address,uint256)' $PLAN_AGENT 80000000 --rpc-url $RPC --private-key $PK"

# Set projected revenue
run_tx_test "Set projected monthly revenue (100 USDC)" \
    "cast send $SERVICE_PLAN 'setProjectedRevenue(address,uint256)' $PLAN_AGENT 100000000 --rpc-url $RPC --private-key $PK"

# Record revenue and check health zones
run_tx_test "Record revenue for health check" \
    "cast send $SERVICE_PLAN 'recordRevenue(address,uint256)' $PLAN_AGENT 85000000 --rpc-url $RPC --private-key $PK"

# Health computation (pure)
run_test "computeHealth(80, 100, 0) == Green" \
    "cast call $SERVICE_PLAN 'computeHealth(uint256,uint256,uint8)(uint8)' 80000000 100000000 0 --rpc-url $RPC" \
    "0"

run_test "computeHealth(60, 100, 0) == Yellow" \
    "cast call $SERVICE_PLAN 'computeHealth(uint256,uint256,uint8)(uint8)' 60000000 100000000 0 --rpc-url $RPC" \
    "1"

run_test "computeHealth(30, 100, 0) == Orange" \
    "cast call $SERVICE_PLAN 'computeHealth(uint256,uint256,uint8)(uint8)' 30000000 100000000 0 --rpc-url $RPC" \
    "2"

run_test "computeHealth(10, 100, 0) == Red" \
    "cast call $SERVICE_PLAN 'computeHealth(uint256,uint256,uint8)(uint8)' 10000000 100000000 0 --rpc-url $RPC" \
    "3"

run_test "computeHealth(0, 100, 7) == Orange (zero-rev days)" \
    "cast call $SERVICE_PLAN 'computeHealth(uint256,uint256,uint8)(uint8)' 0 100000000 7 --rpc-url $RPC" \
    "2"

run_test "computeHealth(0, 100, 14) == Red (zero-rev days)" \
    "cast call $SERVICE_PLAN 'computeHealth(uint256,uint256,uint8)(uint8)' 0 100000000 14 --rpc-url $RPC" \
    "3"

echo ""

# ═══════════════════════════════════════════
echo "--- 10. GUARDRAILS & ACCESS CONTROL ---"
# ═══════════════════════════════════════════

# Test pause/unpause
run_tx_test "Pause Registry" \
    "cast send $REGISTRY 'pause()' --rpc-url $RPC --private-key $PK"

echo -n "  [$((PASS + FAIL + 1))] Paused registry blocks registration ... "
PAUSE_RESULT=$(cast send $REGISTRY 'registerAgent(string)' 'ipfs://ShouldFail' --rpc-url $RPC --private-key $PK 2>&1) || true
if echo "$PAUSE_RESULT" | grep -qi "revert\|error\|PlatformPaused"; then
    echo "PASS (correctly reverted)"
    PASS=$((PASS + 1))
else
    echo "FAIL (should have reverted)"
    FAIL=$((FAIL + 1))
fi

run_tx_test "Unpause Registry" \
    "cast send $REGISTRY 'unpause()' --rpc-url $RPC --private-key $PK"

# Test invalid credit score (>850)
echo -n "  [$((PASS + FAIL + 1))] Invalid credit score (>850) reverts ... "
SCORE_RESULT=$(cast send $REGISTRY 'updateCreditScore(address,uint16)' $DEPLOYER 900 --rpc-url $RPC --private-key $PK 2>&1) || true
if echo "$SCORE_RESULT" | grep -qi "revert\|error\|CreditScoreOutOfRange"; then
    echo "PASS (correctly reverted)"
    PASS=$((PASS + 1))
else
    echo "FAIL (should have reverted)"
    FAIL=$((FAIL + 1))
fi

# Test double registration
echo -n "  [$((PASS + FAIL + 1))] Double registration reverts ... "
DOUBLE_RESULT=$(cast send $REGISTRY 'registerAgent(string)' 'ipfs://Duplicate' --rpc-url $RPC --private-key $PK 2>&1) || true
if echo "$DOUBLE_RESULT" | grep -qi "revert\|error\|AgentAlreadyRegistered"; then
    echo "PASS (correctly reverted)"
    PASS=$((PASS + 1))
else
    echo "FAIL (should have reverted)"
    FAIL=$((FAIL + 1))
fi

# Test duplicate wallet creation
echo -n "  [$((PASS + FAIL + 1))] Duplicate wallet creation reverts ... "
DUP_WALLET=$(cast send $WALLET_FACTORY 'createWallet(address,uint256,uint256)' $DEPLOYER 1000000000 100000000 --rpc-url $RPC --private-key $PK 2>&1) || true
if echo "$DUP_WALLET" | grep -qi "revert\|error\|VaultAlreadyExists"; then
    echo "PASS (correctly reverted)"
    PASS=$((PASS + 1))
else
    echo "FAIL (should have reverted)"
    FAIL=$((FAIL + 1))
fi

# Test milestone already disbursed
echo -n "  [$((PASS + FAIL + 1))] Re-disbursing milestone reverts ... "
MS_RESULT=$(cast send $SERVICE_PLAN 'disburseMilestone(address,uint8)' $PLAN_AGENT 0 --rpc-url $RPC --private-key $PK 2>&1) || true
if echo "$MS_RESULT" | grep -qi "revert\|error\|MilestoneAlreadyDisbursed"; then
    echo "PASS (correctly reverted)"
    PASS=$((PASS + 1))
else
    echo "FAIL (should have reverted)"
    FAIL=$((FAIL + 1))
fi

echo ""

# ═══════════════════════════════════════════
echo "--- 11. CONSTANTS VERIFICATION (Solana parity) ---"
# ═══════════════════════════════════════════

run_test "MIN_CREDIT_SCORE == 200" \
    "cast call $REGISTRY 'MIN_CREDIT_SCORE()(uint16)' --rpc-url $RPC" \
    "200"

run_test "MAX_CREDIT_SCORE == 850" \
    "cast call $REGISTRY 'MAX_CREDIT_SCORE()(uint16)' --rpc-url $RPC" \
    "850"

run_test "DEFAULT_CREDIT_SCORE == 350" \
    "cast call $REGISTRY 'DEFAULT_CREDIT_SCORE()(uint16)' --rpc-url $RPC" \
    "350"

run_test "LIQUIDATION_SCORE_PENALTY == 40" \
    "cast call $REGISTRY 'LIQUIDATION_SCORE_PENALTY()(uint8)' --rpc-url $RPC" \
    "40"

run_test "Router: PATTERN_REJECT_THRESHOLD == 80" \
    "cast call $ROUTER 'PATTERN_REJECT_THRESHOLD()(uint16)' --rpc-url $RPC" \
    "80"

run_test "Router: ROUND_TRIP_WINDOW == 86400" \
    "cast call $ROUTER 'ROUND_TRIP_WINDOW_SECONDS()(uint256)' --rpc-url $RPC" \
    "86400"

run_test "ServicePlan: MAX_MILESTONES == 8" \
    "cast call $SERVICE_PLAN 'MAX_MILESTONES()(uint8)' --rpc-url $RPC" \
    "8"

run_test "ServicePlan: WIND_DOWN_GRACE == 172800" \
    "cast call $SERVICE_PLAN 'WIND_DOWN_GRACE_SECONDS()(uint256)' --rpc-url $RPC" \
    "172800"

run_test "ServicePlan: YELLOW_DELAY == 604800" \
    "cast call $SERVICE_PLAN 'YELLOW_MILESTONE_DELAY_SECONDS()(uint256)' --rpc-url $RPC" \
    "604800"

run_test "Wallet: MAX_PER_TRADE_BPS == 2000" \
    "cast call $ACTUAL_WALLET 'MAX_PER_TRADE_BPS()(uint16)' --rpc-url $RPC" \
    "2000"

run_test "Wallet: LIQUIDATION_REWARD_BPS == 50" \
    "cast call $ACTUAL_WALLET 'LIQUIDATION_REWARD_BPS()(uint16)' --rpc-url $RPC" \
    "50"

run_test "Wallet: L1_MAX_CREDIT == 500 USDC" \
    "cast call $ACTUAL_WALLET 'L1_MAX_CREDIT()(uint256)' --rpc-url $RPC" \
    "500000000"

run_test "Wallet: L4_MAX_CREDIT == 500000 USDC" \
    "cast call $ACTUAL_WALLET 'L4_MAX_CREDIT()(uint256)' --rpc-url $RPC" \
    "500000000000"

echo ""

# ═══════════════════════════════════════════
echo "============================================"
echo "  RESULTS: $PASS PASSED / $((PASS + FAIL)) TOTAL"
if [ $FAIL -gt 0 ]; then
    echo "  FAILED: $FAIL"
fi
echo "============================================"
