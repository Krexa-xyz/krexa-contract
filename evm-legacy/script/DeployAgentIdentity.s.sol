// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";

/// @title DeployAgentIdentity — deploy Soulbound Agent Identity NFT
contract DeployAgentIdentity is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        AgentIdentity identity = new AgentIdentity(deployer);
        console.log("AgentIdentity:", address(identity));
        console.log("  Admin: ", deployer);

        vm.stopBroadcast();
    }
}
