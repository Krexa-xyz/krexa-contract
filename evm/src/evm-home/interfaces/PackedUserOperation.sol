// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice ERC-4337 v0.7 packed user operation. Layout reproduced from the EIP-4337 spec
/// (https://eips.ethereum.org/EIPS/eip-4337) and eth-infinitism `PackedUserOperation.sol`
/// (https://github.com/eth-infinitism/account-abstraction/blob/v0.7.0/contracts/interfaces/PackedUserOperation.sol).
/// Only the field order matters for ABI compatibility with Kernel and the EntryPoint.
struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    bytes32 accountGasLimits;
    uint256 preVerificationGas;
    bytes32 gasFees;
    bytes paymasterAndData;
    bytes signature;
}
