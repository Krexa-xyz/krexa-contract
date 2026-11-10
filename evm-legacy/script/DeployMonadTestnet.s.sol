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
import {MockUSDC} from "../test/mocks/MockUSDC.sol";

/// @title DeployMonadTestnet — Full Krexa protocol on Monad Testnet
/// @notice Deploys MockUSDC + all 10 contracts, wires permissions
///
/// Usage:
///   source .env && forge script script/DeployMonadTestnet.s.sol:DeployMonadTestnet \
///     --rpc-url monad_testnet \
///     --private-key $DEPLOYER_PRIVATE_KEY \
///     --broadcast
contract DeployMonadTestnet is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address oracle = vm.envAddress("ORACLE_ADDRESS");
        uint16 platformFeeBps = uint16(vm.envOr("PLATFORM_FEE_BPS", uint256(200)));
        uint16 routerFeeBps = uint16(vm.envOr("ROUTER_FEE_BPS", uint256(200)));
        address feeRecipient = vm.envOr("FEE_RECIPIENT", deployer);

        console.log("=== Krexa Monad TESTNET Deployment ===");
        console.log("Chain ID:  10143 (Monad Testnet)");
        console.log("Deployer: ", deployer);
        console.log("Oracle:   ", oracle);
        console.log("");

        vm.startBroadcast(deployerKey);

        // ── 0. MockUSDC (testnet only) ──────────────────────────────
        MockUSDC usdc = new MockUSDC();
        console.log("[0]  MockUSDC:           ", address(usdc));

        // Mint 10M USDC to deployer for testing
        usdc.mint(deployer, 10_000_000e6);

        // ── 1. AgentRegistry ────────────────────────────────────────
        AgentRegistry registry = new AgentRegistry(deployer, oracle);
        console.log("[1]  AgentRegistry:      ", address(registry));

        // ── 2. PaymentRouter ────────────────────────────────────────
        PaymentRouter router = new PaymentRouter(address(usdc), address(registry), deployer, oracle);
        console.log("[2]  PaymentRouter:      ", address(router));

        // ── 3. VaultFactory ─────────────────────────────────────────
        VaultFactory factory = new VaultFactory(
            deployer, oracle, address(usdc), platformFeeBps, feeRecipient,
            address(registry), address(router)
        );
        console.log("[3]  VaultFactory:       ", address(factory));

        // ── 4. Senior Liquidity Pool ────────────────────────────────
        LiquidityPool seniorPool = new LiquidityPool(address(usdc), deployer, true, 500_000e6);
        console.log("[4]  SeniorPool:         ", address(seniorPool));

        // ── 5. General Liquidity Pool ───────────────────────────────
        LiquidityPool generalPool = new LiquidityPool(address(usdc), deployer, false, 200_000e6);
        console.log("[5]  GeneralPool:        ", address(generalPool));

        // ── 6. MilestoneRegistry ────────────────────────────────────
        MilestoneRegistry milestones = new MilestoneRegistry(deployer);
        console.log("[6]  MilestoneRegistry:  ", address(milestones));

        // ── 7. KrexitScore ──────────────────────────────────────────
        KrexitScore scorer = new KrexitScore(deployer, oracle, address(registry));
        console.log("[7]  KrexitScore:        ", address(scorer));

        // ── 8. VenueWhitelist ───────────────────────────────────────
        VenueWhitelist venueWhitelist = new VenueWhitelist(deployer);
        console.log("[8]  VenueWhitelist:     ", address(venueWhitelist));

        // ── 9. AgentWalletFactory ───────────────────────────────────
        AgentWalletFactory walletFactory = new AgentWalletFactory(address(usdc), address(registry), deployer);
        console.log("[9]  AgentWalletFactory: ", address(walletFactory));

        // ── 10. ServicePlan ─────────────────────────────────────────
        ServicePlan servicePlan = new ServicePlan(address(usdc), deployer, oracle);
        console.log("[10] ServicePlan:        ", address(servicePlan));

        // ── Wire permissions ────────────────────────────────────────
        console.log("");
        console.log("Wiring permissions...");

        registry.setFactory(address(factory));
        registry.setPaymentRouter(address(router));
        router.setFactory(address(factory));
        router.setPlatformTreasury(feeRecipient);
        router.setPlatformFeeBps(routerFeeBps);

        vm.stopBroadcast();

        // ── Output ──────────────────────────────────────────────────
        console.log("");
        console.log("=== Monad Testnet Deployment Complete ===");
        console.log("");
        console.log("MONAD_TESTNET_USDC=", address(usdc));
        console.log("MONAD_TESTNET_AGENT_REGISTRY=", address(registry));
        console.log("MONAD_TESTNET_PAYMENT_ROUTER=", address(router));
        console.log("MONAD_TESTNET_VAULT_FACTORY=", address(factory));
        console.log("MONAD_TESTNET_SENIOR_POOL=", address(seniorPool));
        console.log("MONAD_TESTNET_GENERAL_POOL=", address(generalPool));
        console.log("MONAD_TESTNET_MILESTONE_REGISTRY=", address(milestones));
        console.log("MONAD_TESTNET_KREXIT_SCORE=", address(scorer));
        console.log("MONAD_TESTNET_VENUE_WHITELIST=", address(venueWhitelist));
        console.log("MONAD_TESTNET_WALLET_FACTORY=", address(walletFactory));
        console.log("MONAD_TESTNET_SERVICE_PLAN=", address(servicePlan));
    }
}
