// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";
import {MilestoneRegistry} from "../src/MilestoneRegistry.sol";
import {KrexitScore} from "../src/KrexitScore.sol";
import {VenueWhitelist} from "../src/VenueWhitelist.sol";
import {AgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {ServicePlan} from "../src/ServicePlan.sol";
import {PolymarketGuardrail} from "../src/PolymarketGuardrail.sol";

/// @title DeployPolygon — Full Krexa protocol deployment on Polygon PoS
/// @notice Deploys all Monad-parity contracts + PolymarketGuardrail, wires permissions,
///         and registers Polymarket venues in VenueWhitelist.
///
/// Usage:
///   forge script script/DeployPolygon.s.sol:DeployPolygon \
///     --rpc-url polygon \
///     --private-key $DEPLOYER_PRIVATE_KEY \
///     --broadcast \
///     --verify --verifier etherscan \
///     --etherscan-api-key $POLYGONSCAN_API_KEY
///
/// Required env vars:
///   DEPLOYER_PRIVATE_KEY  — deployer wallet (becomes admin)
///   ORACLE_ADDRESS        — oracle signer for payments + scoring
contract DeployPolygon is Script {
    // Polygon PoS Native USDC (Circle)
    address constant USDC_POLYGON = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;

    // Polymarket contracts on Polygon
    address constant POLYMARKET_CTF = 0x4D97DCd97eC945f40cF65F87097ACe5EA0476045;
    address constant POLYMARKET_CTF_EXCHANGE = 0x4bFb41d5B3570DeFd03C39a9A4D8dE6Bd8B8982E;
    address constant POLYMARKET_NEG_RISK = 0xC5d563A36AE78145C45a50134d48A1215220f80a;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address oracle = vm.envAddress("ORACLE_ADDRESS");
        address usdc = vm.envOr("USDC_ADDRESS", USDC_POLYGON);
        uint16 platformFeeBps = uint16(vm.envOr("PLATFORM_FEE_BPS", uint256(200)));
        uint16 routerFeeBps = uint16(vm.envOr("ROUTER_FEE_BPS", uint256(200)));
        address feeRecipient = vm.envOr("FEE_RECIPIENT", deployer);
        uint256 seniorPoolCap = vm.envOr("SENIOR_POOL_CAP", uint256(500_000e6));
        uint256 generalPoolCap = vm.envOr("GENERAL_POOL_CAP", uint256(200_000e6));

        console.log("=== Krexa Polygon Deployment ===");
        console.log("Chain ID:  137 (Polygon PoS)");
        console.log("Deployer: ", deployer);
        console.log("Oracle:   ", oracle);
        console.log("USDC:     ", usdc);
        console.log("");

        vm.startBroadcast(deployerKey);

        // ── 1. AgentRegistry ────────────────────────────────────────
        AgentRegistry registry = new AgentRegistry(deployer, oracle);
        console.log("[1]  AgentRegistry:        ", address(registry));

        // ── 2. PaymentRouter ────────────────────────────────────────
        PaymentRouter router = new PaymentRouter(usdc, address(registry), deployer, oracle);
        console.log("[2]  PaymentRouter:        ", address(router));

        // ── 3. VaultFactory ─────────────────────────────────────────
        VaultFactory factory = new VaultFactory(
            deployer, oracle, usdc, platformFeeBps, feeRecipient,
            address(registry), address(router)
        );
        console.log("[3]  VaultFactory:         ", address(factory));

        // ── 4. Senior Liquidity Pool ────────────────────────────────
        LiquidityPool seniorPool = new LiquidityPool(usdc, deployer, true, seniorPoolCap);
        console.log("[4]  SeniorPool:           ", address(seniorPool));

        // ── 5. General Liquidity Pool ───────────────────────────────
        LiquidityPool generalPool = new LiquidityPool(usdc, deployer, false, generalPoolCap);
        console.log("[5]  GeneralPool:          ", address(generalPool));

        // ── 6. MilestoneRegistry ────────────────────────────────────
        MilestoneRegistry milestones = new MilestoneRegistry(deployer);
        console.log("[6]  MilestoneRegistry:    ", address(milestones));

        // ── 7. KrexitScore ──────────────────────────────────────────
        KrexitScore scorer = new KrexitScore(deployer, oracle, address(registry));
        console.log("[7]  KrexitScore:          ", address(scorer));

        // ── 8. VenueWhitelist ───────────────────────────────────────
        VenueWhitelist venueWhitelist = new VenueWhitelist(deployer);
        console.log("[8]  VenueWhitelist:       ", address(venueWhitelist));

        // ── 9. AgentWalletFactory ───────────────────────────────────
        AgentWalletFactory walletFactory = new AgentWalletFactory(usdc, address(registry), deployer);
        console.log("[9]  AgentWalletFactory:   ", address(walletFactory));

        // ── 10. ServicePlan ─────────────────────────────────────────
        ServicePlan servicePlan = new ServicePlan(usdc, deployer, oracle);
        console.log("[10] ServicePlan:          ", address(servicePlan));

        // ── 11. PolymarketGuardrail (NEW — Polygon-specific) ────────
        PolymarketGuardrail guardrail = new PolymarketGuardrail(
            POLYMARKET_CTF,
            deployer,
            oracle
        );
        console.log("[11] PolymarketGuardrail:  ", address(guardrail));

        // ── Wire permissions ────────────────────────────────────────
        console.log("");
        console.log("Wiring permissions...");

        registry.setFactory(address(factory));
        registry.setPaymentRouter(address(router));
        router.setFactory(address(factory));
        router.setPlatformTreasury(feeRecipient);
        router.setPlatformFeeBps(routerFeeBps);

        console.log("  registry.factory  =", address(factory));
        console.log("  registry.router   =", address(router));
        console.log("  router.factory    =", address(factory));
        console.log("  router.treasury   =", feeRecipient);
        console.log("  router.feeBps     =", routerFeeBps);

        // ── Register Polymarket venues ──────────────────────────────
        console.log("");
        console.log("Registering Polymarket venues...");

        // Category 3 = DeFi
        venueWhitelist.addVenue(POLYMARKET_CTF_EXCHANGE, bytes32("Polymarket CTF Exchange"), 3);
        venueWhitelist.addVenue(POLYMARKET_NEG_RISK, bytes32("Polymarket NegRisk"), 3);
        venueWhitelist.addVenue(POLYMARKET_CTF, bytes32("Polymarket CondTokens"), 3);

        console.log("  CTF Exchange:  ", POLYMARKET_CTF_EXCHANGE);
        console.log("  Neg Risk:      ", POLYMARKET_NEG_RISK);
        console.log("  Cond Tokens:   ", POLYMARKET_CTF);

        vm.stopBroadcast();

        // ── Output deployment manifest ──────────────────────────────
        console.log("");
        console.log("=== Polygon Deployment Complete ===");
        console.log("");
        console.log("POLYGON_AGENT_REGISTRY=", address(registry));
        console.log("POLYGON_PAYMENT_ROUTER=", address(router));
        console.log("POLYGON_VAULT_FACTORY=", address(factory));
        console.log("POLYGON_SENIOR_POOL=", address(seniorPool));
        console.log("POLYGON_GENERAL_POOL=", address(generalPool));
        console.log("POLYGON_MILESTONE_REGISTRY=", address(milestones));
        console.log("POLYGON_KREXIT_SCORE=", address(scorer));
        console.log("POLYGON_VENUE_WHITELIST=", address(venueWhitelist));
        console.log("POLYGON_WALLET_FACTORY=", address(walletFactory));
        console.log("POLYGON_SERVICE_PLAN=", address(servicePlan));
        console.log("POLYGON_POLYMARKET_GUARDRAIL=", address(guardrail));
        console.log("");
        console.log("Verify:");
        console.log("  forge verify-contract <addr> <Contract> --chain 137 --etherscan-api-key $POLYGONSCAN_API_KEY");
    }
}
