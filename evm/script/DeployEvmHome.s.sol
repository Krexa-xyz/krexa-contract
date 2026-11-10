// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {KrexaSwapPolicy} from "../src/evm-home/KrexaSwapPolicy.sol";
import {KrexaRiskHook} from "../src/evm-home/KrexaRiskHook.sol";

/// @notice Deterministic CREATE2 deploy of KrexaSwapPolicy and KrexaRiskHook.
///
/// UNAUDITED - do not deploy to mainnet with user funds before an external audit.
///
/// The contracts have no constructor arguments, so the address depends only on (CREATE2 factory, salt, creation
/// code): identical on every EVM chain for the same compiler settings, no matter which key deploys. The factory is
/// the canonical Arachnid deterministic deployer 0x4e59b448...956C, which Foundry uses for `new C{salt: s}()`
/// inside a broadcast. It exists on Base and Monad (verify with `cast code` before running).
///
///   cd infra/base-contracts
///   export PRIVATE_KEY=...        # from your shell / secret manager only, never committed
///   FOUNDRY_PROFILE=evmhome forge script script/DeployEvmHome.s.sol --rpc-url <RPC> [--broadcast]
///
/// Writes deployments/<chainid>-evm-home.json (also on a dry run). Re-running is safe: contracts already at the
/// predicted address are reused, not redeployed.
contract DeployEvmHome is Script {
    bytes32 internal constant SALT = keccak256("krexa.evm-home.v1");

    function predict() public pure returns (address policy, address hook) {
        policy = vm.computeCreate2Address(SALT, keccak256(type(KrexaSwapPolicy).creationCode), CREATE2_FACTORY);
        hook = vm.computeCreate2Address(SALT, keccak256(type(KrexaRiskHook).creationCode), CREATE2_FACTORY);
    }

    function run() external returns (address policy, address hook) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        (policy, hook) = predict();

        vm.startBroadcast(pk);
        if (policy.code.length == 0) {
            address p = address(new KrexaSwapPolicy{salt: SALT}());
            require(p == policy, "policy address mismatch");
        }
        if (hook.code.length == 0) {
            address h = address(new KrexaRiskHook{salt: SALT}());
            require(h == hook, "hook address mismatch");
        }
        vm.stopBroadcast();

        string memory k = "evmhome";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "create2Factory", CREATE2_FACTORY);
        vm.serializeBytes32(k, "salt", SALT);
        vm.serializeAddress(k, "deployer", vm.addr(pk));
        vm.serializeAddress(k, "KrexaSwapPolicy", policy);
        vm.serializeBytes32(k, "KrexaSwapPolicyCodehash", keccak256(type(KrexaSwapPolicy).runtimeCode));
        vm.serializeAddress(k, "KrexaRiskHook", hook);
        vm.serializeBytes32(k, "KrexaRiskHookCodehash", keccak256(type(KrexaRiskHook).runtimeCode));
        string memory json = vm.serializeString(k, "status", "UNAUDITED - testnet only until external audit");
        vm.writeJson(json, string.concat("deployments/", vm.toString(block.chainid), "-evm-home.json"));
    }
}
