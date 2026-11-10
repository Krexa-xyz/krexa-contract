// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {Krexa402Facilitator} from "../src/Krexa402Facilitator.sol";

/// @title DeployFacilitator — deploy Krexa402Facilitator on top of existing protocol
contract DeployFacilitator is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address usdc = vm.envAddress("USDC_ADDRESS");
        address router = vm.envAddress("PAYMENT_ROUTER_ADDRESS");
        uint16 feeBps = uint16(vm.envOr("FACILITATOR_FEE_BPS", uint256(250)));

        vm.startBroadcast(deployerKey);

        Krexa402Facilitator facilitator = new Krexa402Facilitator(usdc, router, deployer, feeBps);
        console.log("Krexa402Facilitator:", address(facilitator));
        console.log("  USDC:        ", usdc);
        console.log("  Router:      ", router);
        console.log("  Admin:       ", deployer);
        console.log("  Fee BPS:     ", feeBps);

        vm.stopBroadcast();
    }
}
