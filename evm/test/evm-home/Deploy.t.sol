// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployEvmHome} from "../../script/DeployEvmHome.s.sol";
import {KrexaSwapPolicy} from "../../src/evm-home/KrexaSwapPolicy.sol";
import {KrexaRiskHook} from "../../src/evm-home/KrexaRiskHook.sol";

/// @notice Runs the deploy script inside the test VM (no network): checks the CREATE2 addresses are the predicted
/// ones, the script is idempotent, and the JSON artifact is written. The key is derived in the test, never read
/// from a file.
contract DeployTest is Test {
    function test_deployIsDeterministicAndIdempotent() public {
        // writes deployments/31337-evm-home.json (git-ignored); foundry.toml grants fs_permissions on ./deployments
        vm.setEnv("PRIVATE_KEY", vm.toString(uint256(keccak256("krexa-evm-home-test-deployer"))));
        DeployEvmHome d = new DeployEvmHome();
        (address pPred, address hPred) = d.predict();
        assertEq(pPred.code.length, 0);

        (address p, address h) = d.run();
        assertEq(p, pPred);
        assertEq(h, hPred);
        assertGt(p.code.length, 0);
        assertGt(h.code.length, 0);
        assertTrue(KrexaSwapPolicy(p).isModuleType(5));
        assertTrue(KrexaRiskHook(h).isModuleType(4));

        (address p2, address h2) = d.run(); // second run reuses the deployed contracts
        assertEq(p2, p);
        assertEq(h2, h);

        string memory path = string.concat("deployments/", vm.toString(block.chainid), "-evm-home.json");
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonAddress(json, ".KrexaSwapPolicy"), p);
        assertEq(vm.parseJsonAddress(json, ".KrexaRiskHook"), h);
        assertEq(vm.parseJsonUint(json, ".chainId"), block.chainid);
        vm.removeFile(path);
    }
}
