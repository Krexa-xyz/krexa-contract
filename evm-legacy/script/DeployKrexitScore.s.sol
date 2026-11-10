// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {KrexitScore} from "../src/KrexitScore.sol";

/// @title DeployKrexitScore — deploy KrexitScore scoring engine
contract DeployKrexitScore is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address oracle = vm.envAddress("ORACLE_ADDRESS");
        address registry = vm.envAddress("AGENT_REGISTRY_ADDRESS");

        vm.startBroadcast(deployerKey);

        KrexitScore scorer = new KrexitScore(deployer, oracle, registry);
        console.log("KrexitScore:", address(scorer));
        console.log("  Admin:   ", deployer);
        console.log("  Oracle:  ", oracle);
        console.log("  Registry:", registry);

        vm.stopBroadcast();
    }
}
