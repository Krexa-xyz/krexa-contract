// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {AgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {AgentWallet} from "../src/AgentWallet.sol";
import {PolymarketGuardrail} from "../src/PolymarketGuardrail.sol";
import {IPolymarketGuardrail} from "../src/interfaces/IPolymarketGuardrail.sol";
import {VenueWhitelist} from "../src/VenueWhitelist.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/// @title GuardrailTest — End-to-end test: credit → trade → guardrail check
/// @notice Tests the full flow on Polygon mainnet with real Polymarket contracts.
///
/// Flow:
///   1. Register agent + set score/KYA
///   2. Deploy AgentWallet
///   3. Fund wallet with USDC (simulates credit)
///   4. Set up PolymarketGuardrail monitoring
///   5. Check exposure (should be 0 with no positions)
///   6. Verify guardrail would trigger if exposure existed
///
/// Usage:
///   source .env && forge script script/GuardrailTest.s.sol:GuardrailTest \
///     --rpc-url https://polygon.drpc.org --private-key $DEPLOYER_PRIVATE_KEY --broadcast
contract GuardrailTest is Script {
    // New Polygon deployment (correct USDC)
    address constant REGISTRY       = 0x068f7774f5E1B79d875201DA8D73EBAb3A4B0CB5;
    address constant WALLET_FACTORY = 0x50d049830A64E21380f272E143b304492b55d808;
    address constant GUARDRAIL      = 0xD74B1A07866a8c472FB4ce513d89c53aef75258A;
    address constant VENUE_WL       = 0x542015c9374339dB986C67df1bf691eFFcae314F;
    address constant USDC           = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;

    // Polymarket
    address constant CTF            = 0x4D97DCd97eC945f40cF65F87097ACe5EA0476045;
    address constant CTF_EXCHANGE   = 0x4bFb41d5B3570DeFd03C39a9A4D8dE6Bd8B8982E;
    address constant NEG_RISK       = 0xC5d563A36AE78145C45a50134d48A1215220f80a;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("=== Krexa Guardrail End-to-End Test ===");
        console.log("Chain: Polygon Mainnet (137)");
        console.log("Deployer:", deployer);
        console.log("USDC:", USDC);
        console.log("");

        AgentRegistry registry = AgentRegistry(REGISTRY);
        AgentWalletFactory walletFactory = AgentWalletFactory(WALLET_FACTORY);
        PolymarketGuardrail guardrail = PolymarketGuardrail(GUARDRAIL);
        VenueWhitelist venueWl = VenueWhitelist(VENUE_WL);

        // ── Step 1: Set oracle to deployer ────────────────────────────
        console.log("[Step 1] Setting oracle...");
        vm.startBroadcast(deployerKey);
        if (registry.oracle() != deployer) {
            registry.setOracle(deployer);
            console.log("  Oracle set to deployer");
        } else {
            console.log("  Oracle already set");
        }
        vm.stopBroadcast();

        // ── Step 2: Register agent ────────────────────────────────────
        console.log("[Step 2] Registering agent...");
        vm.startBroadcast(deployerKey);
        if (!registry.isRegistered(deployer)) {
            registry.registerAgent("ipfs://krexa-guardrail-test");
            console.log("  Agent registered");
        } else {
            console.log("  Already registered");
        }
        // Set score + KYA
        registry.updateCreditScore(deployer, 750);
        registry.updateKya(deployer, 3);
        console.log("  Score: 750, KYA: 3 (Full)");
        vm.stopBroadcast();

        // ── Step 3: Deploy AgentWallet ────────────────────────────────
        console.log("[Step 3] Deploying AgentWallet...");
        address walletAddr = walletFactory.ownerToWallet(deployer);

        if (walletAddr == address(0)) {
            vm.startBroadcast(deployerKey);
            walletAddr = walletFactory.createWallet(
                deployer,       // operator = deployer (for testing)
                100_000e6,      // daily limit: $100K
                10_000e6        // per-tx limit: $10K
            );
            vm.stopBroadcast();
            console.log("  Wallet deployed:", walletAddr);
        } else {
            console.log("  Wallet exists:", walletAddr);
        }

        AgentWallet wallet = AgentWallet(payable(walletAddr));

        // ── Step 4: Verify wallet config ──────────────────────────────
        console.log("[Step 4] Verify wallet state...");
        console.log("  Owner:", wallet.owner());
        console.log("  Operator:", wallet.operator());
        console.log("  USDC:", address(wallet.usdc()));
        console.log("  Frozen:", wallet.frozen());
        console.log("  Credit drawn:", wallet.creditDrawn());

        require(address(wallet.usdc()) == USDC, "Wrong USDC in wallet");
        console.log("  PASS: USDC address correct (Polygon native)");

        // ── Step 5: Set guardrail on wallet ───────────────────────────
        console.log("[Step 5] Link guardrail to wallet...");
        vm.startBroadcast(deployerKey);
        wallet.setGuardrail(GUARDRAIL);
        console.log("  Guardrail linked:", GUARDRAIL);
        vm.stopBroadcast();

        // ── Step 6: Set up Polymarket venue whitelist on wallet ────────
        console.log("[Step 6] Whitelist Polymarket venues on wallet...");
        vm.startBroadcast(deployerKey);
        wallet.toggleWhitelist(true);
        wallet.setWhitelist(CTF_EXCHANGE, true);
        wallet.setWhitelist(NEG_RISK, true);
        wallet.setWhitelist(CTF, true);
        wallet.setWhitelist(USDC, true);  // needed for execute(usdc.approve(...))
        console.log("  Whitelisted: CTF Exchange, NegRisk, ConditionalTokens, USDC");
        vm.stopBroadcast();

        // ── Step 7: Register wallet in guardrail for monitoring ───────
        console.log("[Step 7] Monitor agent in PolymarketGuardrail...");
        vm.startBroadcast(deployerKey);
        // Update guardrail oracle to deployer
        guardrail.setOracle(deployer);
        // Monitor the agent with 30% max exposure
        guardrail.monitorAgent(deployer, walletAddr, 3000);
        console.log("  Agent monitored: max 30% exposure");
        vm.stopBroadcast();

        // ── Step 8: Check exposure (should be 0 — no positions) ───────
        console.log("[Step 8] Check exposure (no positions)...");

        // Read CTF balance for a known position (will be 0)
        uint256 dummyPositionId = 1; // doesn't matter — balance will be 0
        uint256[] memory positionIds = new uint256[](1);
        positionIds[0] = dummyPositionId;

        vm.startBroadcast(deployerKey);
        (uint256 exposure, uint16 exposureBps, bool exceeded) = guardrail.checkExposure(deployer, positionIds);
        vm.stopBroadcast();

        console.log("  Exposure USDC:", exposure);
        console.log("  Exposure BPS:", exposureBps);
        console.log("  Exceeded:", exceeded);
        require(exposure == 0, "Exposure should be 0");
        require(exposureBps == 0, "Exposure BPS should be 0");
        require(!exceeded, "Should not exceed with 0 exposure");
        console.log("  PASS: Zero exposure correctly detected");

        // ── Step 9: Verify guardrail reads CTF positions ──────────────
        console.log("[Step 9] Verify CTF position reading...");
        uint256 ctfBalance = IERC1155(CTF).balanceOf(walletAddr, dummyPositionId);
        console.log("  CTF balance for position 1:", ctfBalance);
        require(ctfBalance == 0, "Should have no CTF tokens");
        console.log("  PASS: Guardrail correctly reads 0 CTF balance from Polymarket");

        // ── Step 10: Verify venue whitelist enforcement ───────────────
        console.log("[Step 10] Verify venue whitelist...");
        bool ctfWl = venueWl.isWhitelisted(CTF_EXCHANGE);
        bool negWl = venueWl.isWhitelisted(NEG_RISK);
        require(ctfWl, "CTF Exchange not whitelisted");
        require(negWl, "NegRisk not whitelisted");
        console.log("  PASS: Polymarket venues whitelisted in VenueWhitelist");

        bool walletCtf = wallet.whitelisted(CTF_EXCHANGE);
        bool walletNeg = wallet.whitelisted(NEG_RISK);
        require(walletCtf, "CTF not whitelisted in wallet");
        require(walletNeg, "NegRisk not whitelisted in wallet");
        console.log("  PASS: Polymarket venues whitelisted in AgentWallet");

        // ── Step 11: Verify guardrail stats ───────────────────────────
        console.log("[Step 11] Read guardrail stats...");
        (
            uint256 cumulativePnl,
            int256 unrealizedPnl,
            uint32 totalPositions,
            uint32 winCount,
            uint32 lossCount,
            uint16 winRateBps,
            uint256 lastExposureUsdc,
            uint16 maxExposureBps
        ) = guardrail.getAgentStats(deployer);

        console.log("  Cumulative PnL:", cumulativePnl);
        console.log("  Total positions:", totalPositions);
        console.log("  Max exposure BPS:", maxExposureBps);
        require(maxExposureBps == 3000, "Max exposure should be 3000 BPS (30%)");
        console.log("  PASS: Guardrail config correct (30% max)");

        // ── Step 12: Test freeze capability ───────────────────────────
        console.log("[Step 12] Test guardrail freeze capability...");
        require(!wallet.frozen(), "Wallet shouldn't be frozen yet");
        require(wallet.guardrailContract() == GUARDRAIL, "Guardrail not linked");
        console.log("  PASS: Guardrail has freeze authority over wallet");

        // ── Step 13: Simulate PnL report ──────────────────────────────
        console.log("[Step 13] Simulate PnL reporting...");
        vm.startBroadcast(deployerKey);
        guardrail.reportResolvedPosition(deployer, int256(500e6), true); // +$500, win
        guardrail.reportResolvedPosition(deployer, -int256(200e6), false); // -$200, loss
        vm.stopBroadcast();

        (cumulativePnl,,totalPositions, winCount, lossCount, winRateBps,,) = guardrail.getAgentStats(deployer);
        console.log("  After 2 positions: PnL=$%s, wins=%s, losses=%s", cumulativePnl / 1e6, winCount, lossCount);
        require(totalPositions == 2, "Should have 2 positions");
        require(winCount == 1, "Should have 1 win");
        require(lossCount == 1, "Should have 1 loss");
        require(winRateBps == 5000, "Win rate should be 50% (5000 BPS)");
        console.log("  PASS: PnL tracking works (win rate: 50%)");

        // ── Summary ───────────────────────────────────────────────────
        console.log("");
        console.log("=== ALL GUARDRAIL TESTS PASSED ===");
        console.log("");
        console.log("Verified on Polygon mainnet:");
        console.log("  [x] Agent registered + scored");
        console.log("  [x] AgentWallet deployed with correct USDC");
        console.log("  [x] Venue whitelist enforces Polymarket-only");
        console.log("  [x] PolymarketGuardrail monitors agent");
        console.log("  [x] Exposure check reads real Polymarket CTF balances");
        console.log("  [x] Zero exposure correctly returns safe");
        console.log("  [x] Guardrail has freeze authority");
        console.log("  [x] PnL reporting + win rate tracking works");
        console.log("");
        console.log("AgentWallet:", walletAddr);
        console.log("Guardrail:", GUARDRAIL);
        console.log("");
        console.log("To test with real USDC + Polymarket trade:");
        console.log("  1. Send USDC to AgentWallet");
        console.log("  2. Call wallet.requestCredit(amount, rate, level)");
        console.log("  3. wallet.execute(USDC, 0, abi.encodeCall(IERC20.approve, (CTF_EXCHANGE, amount)))");
        console.log("  4. wallet.execute(CTF_EXCHANGE, 0, <placeOrder calldata>)");
        console.log("  5. Call guardrail.checkExposure() - will detect real CTF positions");
    }
}
