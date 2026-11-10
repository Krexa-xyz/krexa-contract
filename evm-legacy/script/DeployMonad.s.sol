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

/// @title DeployMonad — Full Krexa protocol deployment on Monad
/// @notice Deploys all 8 Solana-parity contracts + AgentWalletFactory, wires permissions
///
/// Usage:
///   forge script script/DeployMonad.s.sol:DeployMonad \
///     --rpc-url monad \
///     --private-key $DEPLOYER_PRIVATE_KEY \
///     --broadcast \
///     --verify --verifier sourcify \
///     --verifier-url https://sourcify-api-monad.blockvision.org/
///
/// Required env vars:
///   DEPLOYER_PRIVATE_KEY  — deployer wallet (becomes admin)
///   ORACLE_ADDRESS        — oracle signer for payments + scoring
///
/// Optional env vars:
///   USDC_ADDRESS          — override USDC (default: Monad mainnet Circle USDC)
///   PLATFORM_FEE_BPS      — vault platform fee (default: 200 = 2%)
///   ROUTER_FEE_BPS        — router platform fee (default: 200 = 2%)
///   FEE_RECIPIENT         — platform fee recipient (default: deployer)
///   SENIOR_POOL_CAP       — senior pool deposit cap (default: 500K USDC)
///   GENERAL_POOL_CAP      — general pool deposit cap (default: 200K USDC)
contract DeployMonad is Script {
    // Monad Mainnet Circle USDC
    address constant USDC_MONAD = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address oracle = vm.envAddress("ORACLE_ADDRESS");
        address usdc = vm.envOr("USDC_ADDRESS", USDC_MONAD);
        uint16 platformFeeBps = uint16(vm.envOr("PLATFORM_FEE_BPS", uint256(200)));
        uint16 routerFeeBps = uint16(vm.envOr("ROUTER_FEE_BPS", uint256(200)));
        address feeRecipient = vm.envOr("FEE_RECIPIENT", deployer);
        uint256 seniorPoolCap = vm.envOr("SENIOR_POOL_CAP", uint256(500_000e6));
        uint256 generalPoolCap = vm.envOr("GENERAL_POOL_CAP", uint256(200_000e6));

        console.log("=== Krexa Monad Deployment ===");
        console.log("Chain ID:  143 (Monad Mainnet)");
        console.log("Deployer: ", deployer);
        console.log("Oracle:   ", oracle);
        console.log("USDC:     ", usdc);
        console.log("");

        vm.startBroadcast(deployerKey);

        // ── 1. AgentRegistry ────────────────────────────────────────
        AgentRegistry registry = new AgentRegistry(deployer, oracle);
        console.log("[1] AgentRegistry:      ", address(registry));

        // ── 2. PaymentRouter ────────────────────────────────────────
        PaymentRouter router = new PaymentRouter(usdc, address(registry), deployer, oracle);
        console.log("[2] PaymentRouter:      ", address(router));

        // ── 3. VaultFactory ─────────────────────────────────────────
        VaultFactory factory = new VaultFactory(
            deployer, oracle, usdc, platformFeeBps, feeRecipient,
            address(registry), address(router)
        );
        console.log("[3] VaultFactory:       ", address(factory));

        // ── 4. Senior Liquidity Pool ────────────────────────────────
        LiquidityPool seniorPool = new LiquidityPool(usdc, deployer, true, seniorPoolCap);
        console.log("[4] SeniorPool:         ", address(seniorPool));

        // ── 5. General Liquidity Pool ───────────────────────────────
        LiquidityPool generalPool = new LiquidityPool(usdc, deployer, false, generalPoolCap);
        console.log("[5] GeneralPool:        ", address(generalPool));

        // ── 6. MilestoneRegistry ────────────────────────────────────
        MilestoneRegistry milestones = new MilestoneRegistry(deployer);
        console.log("[6] MilestoneRegistry:  ", address(milestones));

        // ── 7. KrexitScore ──────────────────────────────────────────
        KrexitScore scorer = new KrexitScore(deployer, oracle, address(registry));
        console.log("[7] KrexitScore:        ", address(scorer));

        // ── 8. VenueWhitelist ───────────────────────────────────────
        VenueWhitelist venueWhitelist = new VenueWhitelist(deployer);
        console.log("[8] VenueWhitelist:     ", address(venueWhitelist));

        // ── 9. AgentWalletFactory ───────────────────────────────────
        AgentWalletFactory walletFactory = new AgentWalletFactory(usdc, address(registry), deployer);
        console.log("[9] AgentWalletFactory: ", address(walletFactory));

        // ── 10. ServicePlan ─────────────────────────────────────────
        ServicePlan servicePlan = new ServicePlan(usdc, deployer, oracle);
        console.log("[10] ServicePlan:       ", address(servicePlan));

        // ── Wire permissions ────────────────────────────────────────
        console.log("");
        console.log("Wiring permissions...");

        registry.setFactory(address(factory));
        registry.setPaymentRouter(address(router));
        router.setFactory(address(factory));

        // Set router platform fee + treasury
        router.setPlatformTreasury(feeRecipient);
        router.setPlatformFeeBps(routerFeeBps);

        console.log("  registry.factory  =", address(factory));
        console.log("  registry.router   =", address(router));
        console.log("  router.factory    =", address(factory));
        console.log("  router.treasury   =", feeRecipient);
        console.log("  router.feeBps     =", routerFeeBps);

        vm.stopBroadcast();

        // ── Output deployment manifest ──────────────────────────────
        console.log("");
        console.log("=== Monad Deployment Complete ===");
        console.log("");
        console.log("MONAD_AGENT_REGISTRY=", address(registry));
        console.log("MONAD_PAYMENT_ROUTER=", address(router));
        console.log("MONAD_VAULT_FACTORY=", address(factory));
        console.log("MONAD_SENIOR_POOL=", address(seniorPool));
        console.log("MONAD_GENERAL_POOL=", address(generalPool));
        console.log("MONAD_MILESTONE_REGISTRY=", address(milestones));
        console.log("MONAD_KREXIT_SCORE=", address(scorer));
        console.log("MONAD_VENUE_WHITELIST=", address(venueWhitelist));
        console.log("MONAD_WALLET_FACTORY=", address(walletFactory));
        console.log("MONAD_SERVICE_PLAN=", address(servicePlan));
        console.log("");
        console.log("Verify with Sourcify:");
        console.log("  forge verify-contract <addr> <Contract> --chain 143 --verifier sourcify --verifier-url https://sourcify-api-monad.blockvision.org/");
        console.log("");
        console.log("Verify with Monadscan:");
        console.log("  forge verify-contract <addr> <Contract> --chain 143 --verifier etherscan --etherscan-api-key $MONADSCAN_API_KEY");
    }
}
