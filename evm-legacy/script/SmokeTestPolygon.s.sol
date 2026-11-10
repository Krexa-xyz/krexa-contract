// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {KrexitScore} from "../src/KrexitScore.sol";
import {VenueWhitelist} from "../src/VenueWhitelist.sol";

/// @title SmokeTestPolygon — Verify Krexa contracts work on Polygon mainnet
/// @notice Registers an agent, sets score, creates a vault, reads state.
///         No USDC required — only POL for gas.
///
/// Usage:
///   source .env && forge script script/SmokeTestPolygon.s.sol:SmokeTestPolygon \
///     --rpc-url polygon --private-key $DEPLOYER_PRIVATE_KEY --broadcast
contract SmokeTestPolygon is Script {
    // Polygon deployment addresses
    address constant REGISTRY      = 0x176b21ba5C62B6D43702327E57544Bf6E8F70E39;
    address constant ROUTER        = 0xCa72E51C2911cf412Aa50A78eAc400eB1149De9f;
    address constant FACTORY       = 0x65529C5dbF29b9380a0cE80b1A1737b0CE06d903;
    address constant KREXIT_SCORE  = 0x4e2eCCE2007b13816E6E3b05eCB93c5862D3653d;
    address constant VENUE_WL      = 0x8dAbCd3bd4efaB3c30C4f1D52Fe54dD6f8bF4037;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("=== Krexa Polygon Smoke Test ===");
        console.log("Deployer:", deployer);
        console.log("");

        AgentRegistry registry = AgentRegistry(REGISTRY);
        KrexitScore scorer = KrexitScore(KREXIT_SCORE);
        VaultFactory factory = VaultFactory(FACTORY);

        // ── Test 0: Update oracle to deployer (one-time fix) ──────────
        console.log("[Test 0] Checking oracle...");
        vm.startBroadcast(deployerKey);
        if (registry.oracle() != deployer) {
            registry.setOracle(deployer);
            console.log("  PASS: Oracle updated to deployer");
        } else {
            console.log("  SKIP: Oracle already set to deployer");
        }
        vm.stopBroadcast();

        // ── Test 1: Register a test agent ─────────────────────────────
        console.log("[Test 1] Register agent...");
        vm.startBroadcast(deployerKey);

        if (!registry.isRegistered(deployer)) {
            registry.registerAgent("ipfs://krexa-polygon-smoke-test");
            console.log("  PASS: Agent registered");
        } else {
            console.log("  SKIP: Agent already registered");
        }

        vm.stopBroadcast();

        // ── Test 2: Set credit score ──────────────────────────────────
        console.log("[Test 2] Set credit score...");
        vm.startBroadcast(deployerKey);

        registry.updateCreditScore(deployer, 750);
        console.log("  PASS: Credit score set to 750 (Tier A)");

        // Set KYA tier (required for credit level calculation)
        registry.updateKya(deployer, 3); // tier 3 = full KYA
        console.log("  PASS: KYA tier set to 3");

        vm.stopBroadcast();

        // ── Test 3: Read score back ───────────────────────────────────
        console.log("[Test 3] Read credit score...");
        AgentRegistry.Agent memory agent = registry.getAgent(deployer);
        require(agent.creditScore == 750, "Score mismatch");
        console.log("  PASS: Score reads back as", agent.creditScore);

        // ── Test 4: Check registry state ──────────────────────────────
        console.log("[Test 4] Verify registry state...");
        bool isReg = registry.isRegistered(deployer);
        require(isReg, "Not registered");
        console.log("  PASS: isRegistered = true");

        // ── Test 5: Check VenueWhitelist (Polymarket) ─────────────────
        console.log("[Test 5] Check Polymarket venue whitelist...");
        VenueWhitelist venueWl = VenueWhitelist(VENUE_WL);
        bool ctfWhitelisted = venueWl.isWhitelisted(0x4bFb41d5B3570DeFd03C39a9A4D8dE6Bd8B8982E);
        require(ctfWhitelisted, "CTF Exchange not whitelisted");
        console.log("  PASS: Polymarket CTF Exchange is whitelisted");

        bool negRiskWhitelisted = venueWl.isWhitelisted(0xC5d563A36AE78145C45a50134d48A1215220f80a);
        require(negRiskWhitelisted, "NegRisk not whitelisted");
        console.log("  PASS: Polymarket NegRisk is whitelisted");

        // ── Test 6: Create a test vault ───────────────────────────────
        console.log("[Test 6] Create vault...");

        address existingVault = factory.agentToVault(deployer);
        if (existingVault == address(0)) {
            vm.startBroadcast(deployerKey);

            address vault = factory.createVault(
                deployer,
                1000e6,                      // 1,000 USDC target (small test)
                1200,                        // 12% APY
                180 days,                    // 6-month term
                2,                           // 2 tranches
                3000,                        // 30% repayment rate
                0,                           // no min payment interval
                0,                           // no max single payment
                100,                         // 1% late fee
                7 days,                      // grace period
                block.timestamp + 30 days    // fundraising deadline
            );

            vm.stopBroadcast();

            console.log("  PASS: Vault created at", vault);
        } else {
            console.log("  SKIP: Vault already exists at", existingVault);
        }

        // ── Test 7: Read vault state ──────────────────────────────────
        console.log("[Test 7] Read vault state...");
        address vaultAddr = factory.agentToVault(deployer);
        require(vaultAddr != address(0), "Vault not found");
        console.log("  PASS: Vault address:", vaultAddr);

        // ── Summary ───────────────────────────────────────────────────
        console.log("");
        console.log("=== ALL TESTS PASSED ===");
        console.log("Krexa is live on Polygon (chain 137)");
    }
}
