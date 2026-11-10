// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {VenueWhitelist} from "../src/VenueWhitelist.sol";

/// @title DeployVenueWhitelist — deploy global venue registry
contract DeployVenueWhitelist is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        VenueWhitelist whitelist = new VenueWhitelist(deployer);
        console.log("VenueWhitelist:", address(whitelist));
        console.log("  Admin:", deployer);

        vm.stopBroadcast();
    }
}
