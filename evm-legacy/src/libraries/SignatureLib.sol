// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Errors} from "./Errors.sol";

/// @title SignatureLib — ECDSA x402 payment proof verification
/// @notice Replaces Ed25519 oracle verification from Solana with secp256k1 ECDSA
library SignatureLib {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    uint256 internal constant MAX_MESSAGE_AGE = 300; // 5 minutes

    /// @notice Construct the payment message hash for signing
    /// @dev The oracle signs: keccak256(abi.encode(from, to, amount, nonce, deadline, paymentId))
    function paymentHash(
        address from,
        address to,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes32 paymentId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(from, to, amount, nonce, deadline, paymentId));
    }

    /// @notice Verify an oracle-signed x402 payment proof (pre-computed hash)
    function verifyPaymentProof(
        bytes32 msgHash,
        bytes calldata signature,
        address oracle
    ) internal pure returns (bool) {
        bytes32 ethSignedHash = msgHash.toEthSignedMessageHash();
        address recovered = ethSignedHash.recover(signature);
        return recovered == oracle;
    }

    /// @notice Verify an oracle-signed x402 payment proof (full params)
    function verifyPaymentProofFull(
        address oracle,
        address from,
        address to,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes32 paymentId,
        bytes calldata signature
    ) internal view returns (bool) {
        if (block.timestamp > deadline) revert Errors.PaymentExpired();

        bytes32 msgHash = paymentHash(from, to, amount, nonce, deadline, paymentId);
        bytes32 ethSignedHash = msgHash.toEthSignedMessageHash();
        address recovered = ethSignedHash.recover(signature);

        return recovered == oracle;
    }
}
