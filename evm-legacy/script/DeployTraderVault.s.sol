// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {TraderVaultFactory} from "../src/TraderVaultFactory.sol";

/// @title DeployTraderVault — deploy TraderVaultFactory to Base Sepolia
contract DeployTraderVault is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        address agentRegistry = vm.envAddress("AGENT_REGISTRY_ADDRESS");
        address usdc          = vm.envAddress("USDC_ADDRESS");

        vm.startBroadcast(deployerKey);

        TraderVaultFactory factory = new TraderVaultFactory(
            deployer,
            usdc,
            agentRegistry
        );

        console.log("TraderVaultFactory:", address(factory));
        console.log("  Admin:          ", deployer);
        console.log("  USDC:           ", usdc);
        console.log("  AgentRegistry:  ", agentRegistry);

        vm.stopBroadcast();
    }
}
