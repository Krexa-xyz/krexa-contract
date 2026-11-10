// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {AgentWalletFactory} from "../src/AgentWalletFactory.sol";

/// @title DeployAgentWallet — deploy AgentWalletFactory
contract DeployAgentWallet is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address usdc = vm.envAddress("USDC_ADDRESS");

        vm.startBroadcast(deployerKey);

        address registry = vm.envAddress("AGENT_REGISTRY_ADDRESS");
        AgentWalletFactory factory = new AgentWalletFactory(usdc, registry, deployer);
        console.log("AgentWalletFactory:", address(factory));
        console.log("  USDC:  ", usdc);
        console.log("  Admin: ", deployer);

        vm.stopBroadcast();
    }
}
