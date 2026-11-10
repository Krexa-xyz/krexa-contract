// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";

/// @title UpgradeRouterA2A — Deploy new PaymentRouter with A2A payments on Monad Testnet
/// @notice Deploys a new PaymentRouter and re-wires AgentRegistry + VaultFactory
contract UpgradeRouterA2A is Script {
    // Existing testnet deployments
    address constant USDC = 0x460b023a87f7Dbe0114357Ab45830F1A41e9C103;
    address constant REGISTRY = 0xd0CB44B07e922d3bc276061bCB9eF41e103Cc872;
    address constant VAULT_FACTORY = 0x964d800A7Bf5353084fE6360D22390ABec46f11F;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        uint16 routerFeeBps = uint16(vm.envOr("ROUTER_FEE_BPS", uint256(200)));
        address feeRecipient = vm.envOr("FEE_RECIPIENT", deployer);

        console.log("=== Upgrade PaymentRouter - A2A Payments ===");
        console.log("Chain: Monad Testnet (10143)");
        console.log("Deployer:", deployer);
        console.log("");

        vm.startBroadcast(deployerKey);

        // 1. Deploy new PaymentRouter with A2A support
        PaymentRouter newRouter = new PaymentRouter(USDC, REGISTRY, deployer, deployer);
        console.log("New PaymentRouter:", address(newRouter));

        // 2. Configure platform fee
        newRouter.setPlatformTreasury(feeRecipient);
        newRouter.setPlatformFeeBps(routerFeeBps);
        newRouter.setFactory(VAULT_FACTORY);

        // 3. Re-wire registry to point to new router
        AgentRegistry(REGISTRY).setPaymentRouter(address(newRouter));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Upgrade Complete ===");
        console.log("MONAD_TESTNET_PAYMENT_ROUTER=", address(newRouter));
        console.log("");
        console.log("New features: agentPay(), agentPayBatch(), getA2AStats()");
    }
}
