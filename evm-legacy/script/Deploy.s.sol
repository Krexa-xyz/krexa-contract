// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";
import {MilestoneRegistry} from "../src/MilestoneRegistry.sol";

/// @title Deploy — Krexa credit protocol deployment (legacy)
/// @notice Deploy order: Registry → Router → Factory → Pools, then wire permissions
contract Deploy is Script {
    // Base Mainnet USDC
    address constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    // Base Sepolia USDC (Circle bridged)
    address constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address oracle = vm.envAddress("ORACLE_ADDRESS");
        address usdc = vm.envOr("USDC_ADDRESS", USDC_BASE_SEPOLIA);
        uint16 platformFeeBps = uint16(vm.envOr("PLATFORM_FEE_BPS", uint256(200)));
        address feeRecipient = vm.envOr("FEE_RECIPIENT", deployer);

        vm.startBroadcast(deployerKey);

        // 1. Agent Registry
        AgentRegistry registry = new AgentRegistry(deployer, oracle);
        console.log("AgentRegistry:", address(registry));

        // 2. Payment Router
        PaymentRouter router = new PaymentRouter(usdc, address(registry), deployer, oracle);
        console.log("PaymentRouter:", address(router));

        // 3. Vault Factory
        VaultFactory factory = new VaultFactory(
            deployer, oracle, usdc, platformFeeBps, feeRecipient,
            address(registry), address(router)
        );
        console.log("VaultFactory:", address(factory));

        // 4. Senior Liquidity Pool (alpha)
        LiquidityPool seniorPool = new LiquidityPool(usdc, deployer, true, 500_000e6);
        console.log("SeniorPool:", address(seniorPool));

        // 5. General Liquidity Pool
        LiquidityPool generalPool = new LiquidityPool(usdc, deployer, false, 200_000e6);
        console.log("GeneralPool:", address(generalPool));

        // 6. Milestone Registry
        MilestoneRegistry milestones = new MilestoneRegistry(deployer);
        console.log("MilestoneRegistry:", address(milestones));

        // 7. Wire permissions
        registry.setFactory(address(factory));
        registry.setPaymentRouter(address(router));
        router.setFactory(address(factory));

        // 7. Wire liquidity pools to factory and router (informational — pools use their own admin)
        // Both pools are deployed with deployer as admin; deployer can call allocateToVault
        // to fund vaults created by the factory. No additional permission wiring needed.
        // Registry does not track pool addresses; pools are operated by the deployer directly.

        // 8. Output deployment manifest
        console.log("--- Deployment complete ---");
        console.log("Admin:      ", deployer);
        console.log("Oracle:     ", oracle);
        console.log("USDC:       ", usdc);
        console.log("Registry:   ", address(registry));
        console.log("Router:     ", address(router));
        console.log("Factory:    ", address(factory));
        console.log("SeniorPool: ", address(seniorPool));
        console.log("GeneralPool:", address(generalPool));
        console.log("Milestones: ", address(milestones));
        console.log("");
        console.log("Verify on BaseScan:");
        console.log("  forge verify-contract <address> src/AgentRegistry.sol:AgentRegistry --chain base-sepolia");

        vm.stopBroadcast();
    }
}
