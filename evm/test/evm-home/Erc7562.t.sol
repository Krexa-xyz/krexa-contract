// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EvmHomeBase} from "./EvmHomeBase.sol";
import {SwapDecoder} from "../../src/evm-home/lib/SwapDecoder.sol";
import {ExecDecoder} from "../../src/evm-home/lib/ExecDecoder.sol";
import {PackedUserOperation} from "../../src/evm-home/interfaces/PackedUserOperation.sol";

/// @notice ERC-7562 audit surface of KrexaSwapPolicy.checkUserOpPolicy (the only code that runs in the ERC-4337
/// validation phase). Public bundlers (Pimlico, Coinbase CDP, ...) reject UserOps that touch banned opcodes or
/// storage that is not associated with the sender during validation. This file pins the policy to that rule.
///
/// FOOTPRINT (what the policy touches while validating a session UserOp):
///   opcodes : SLOAD, KECCAK256, CALLER, ADDRESS, CALLDATA*, MLOAD/MSTORE/MCOPY, arithmetic and control flow.
///             Nothing that reads the block (TIMESTAMP, NUMBER, BLOCKHASH, COINBASE, PREVRANDAO, GASLIMIT, BASEFEE,
///             BLOBHASH, BLOBBASEFEE), the transaction (ORIGIN, GASPRICE, GAS), other accounts (BALANCE, SELFBALANCE,
///             EXTCODE*, CALL*, CREATE*, SELFDESTRUCT). SSTORE and LOG exist in the runtime only for
///             onInstall / onUninstall / setConfig, which run in the execution phase and are never reached by
///             checkUserOpPolicy (proved below: zero writes recorded).
///   storage : only this contract's slots keccak256(pad32(wallet) . X) + n, with the wallet (the UserOp sender,
///             which is msg.sender) as the first word of the preimage:
///               _cfg[id][wallet]   2 words  (slot 0 mapping)
///               _gen[id][wallet]   1 word   (slot 1 mapping)
///               _allow[key][wallet] 1 word per checked (target, selector) / token / spender (slot 2 mapping)
///             No other contract (no Chainlink feed, no token) is read.
///   writes  : none.
contract Erc7562Test is EvmHomeBase {
    uint256 private constant SLOT_CFG = 0;
    uint256 private constant SLOT_GEN = 1;
    uint256 private constant SLOT_ALLOW = 2;

    // ---------------------------------------------------------------- bytecode scan
    /// @dev walks the opcodes of `code` once (skipping PUSH data and the CBOR metadata tail) and returns a bitmap
    /// with bit `op` set for every opcode that occurs
    function _opMask(bytes memory code) internal pure returns (uint256 mask) {
        uint256 end = code.length;
        if (end > 2) {
            uint256 metaLen = (uint256(uint8(code[end - 2])) << 8) | uint8(code[end - 1]);
            if (metaLen + 2 < end) end -= metaLen + 2;
        }
        for (uint256 i; i < end; ++i) {
            uint8 b = uint8(code[i]);
            mask |= uint256(1) << b;
            if (b >= 0x60 && b <= 0x7f) i += b - 0x5f; // PUSHn
        }
    }

    function _contains(bytes memory code, uint8 op) internal pure returns (bool) {
        return (_opMask(code) >> op) & 1 == 1;
    }

    function _bannedOpcodes() internal pure returns (uint8[17] memory ops) {
        ops = [
            uint8(0x31), // BALANCE
            0x32, // ORIGIN
            0x3a, // GASPRICE
            0x3b, // EXTCODESIZE
            0x3c, // EXTCODECOPY
            0x3f, // EXTCODEHASH
            0x40, // BLOCKHASH
            0x41, // COINBASE
            0x42, // TIMESTAMP
            0x43, // NUMBER
            0x44, // PREVRANDAO / DIFFICULTY
            0x45, // GASLIMIT
            0x47, // SELFBALANCE
            0x48, // BASEFEE
            0x49, // BLOBHASH
            0x4a, // BLOBBASEFEE
            0x5a // GAS
        ];
    }

    function _bannedCallLike() internal pure returns (uint8[7] memory ops) {
        ops = [uint8(0xf0), 0xf1, 0xf2, 0xf4, 0xf5, 0xfa, 0xff]; // CREATE CALL CALLCODE DELEGATECALL CREATE2 STATICCALL SELFDESTRUCT
    }

    function test_policyRuntimeHasNoBannedOpcodes() public view {
        bytes memory code = address(policy).code;
        assertGt(code.length, 1000);
        uint256 mask = _opMask(code);
        uint8[17] memory banned = _bannedOpcodes();
        for (uint256 i; i < banned.length; ++i) {
            assertEq((mask >> banned[i]) & 1, 0, "banned opcode in KrexaSwapPolicy");
        }
        uint8[7] memory calls = _bannedCallLike();
        for (uint256 i; i < calls.length; ++i) {
            assertEq((mask >> calls[i]) & 1, 0, "external call / create in KrexaSwapPolicy");
        }
    }

    /// @dev the scanner is only worth something if it finds the opcodes in code that does use them
    function test_scannerFindsOpcodesInTheHook() public view {
        uint256 mask = _opMask(address(hook).code);
        assertEq((mask >> 0x42) & 1, 1, "hook reads TIMESTAMP (execution phase, allowed)");
        assertEq((mask >> 0xfa) & 1, 1, "hook STATICCALLs feeds and tokens (execution phase, allowed)");
        assertEq((mask >> 0x55) & 1, 1, "hook writes counters");
        assertTrue(_contains(address(policy).code, 0x55), "the policy writes only on the install path");
    }

    // ---------------------------------------------------------------- storage footprint
    function _assoc(uint256 base, bytes32 outerKey) internal view returns (bytes32) {
        return keccak256(abi.encode(wallet, keccak256(abi.encode(outerKey, base))));
    }

    function _allowKey(uint8 kind, address a, bytes4 sel) internal pure returns (bytes32) {
        return keccak256(abi.encode(kind, PID, uint32(0), a, sel));
    }

    function _inSet(bytes32 slot, bytes32[] memory set) internal pure returns (bool) {
        for (uint256 i; i < set.length; ++i) {
            if (set[i] == slot) return true;
        }
        return false;
    }

    function test_validationReadsOnlySenderAssociatedStorageAndWritesNothing() public {
        // batch: approve USDC to the router, then a USDC -> WETH exactInputSingle through SwapRouter02
        address[] memory t = new address[](2);
        bytes[] memory d = new bytes[](2);
        t[0] = address(usdc);
        d[0] = _approve(sr02, 50 * U);
        t[1] = sr02;
        d[1] = _sr02Single(address(usdc), address(weth), wallet, 50 * U, 0);
        PackedUserOperation memory op = _userOp(wallet, _wrapHooked(_batch(t, d)));

        bytes32[] memory allowed = new bytes32[](9);
        uint256 n;
        bytes32 cfg = _assoc(SLOT_CFG, PID);
        allowed[n++] = cfg;
        allowed[n++] = bytes32(uint256(cfg) + 1);
        allowed[n++] = bytes32(uint256(cfg) + 2); // maxOpWei
        allowed[n++] = _assoc(SLOT_GEN, PID);
        allowed[n++] = _assoc(SLOT_ALLOW, _allowKey(3, address(usdc), bytes4(0))); // token USDC
        allowed[n++] = _assoc(SLOT_ALLOW, _allowKey(3, address(weth), bytes4(0))); // token WETH
        allowed[n++] = _assoc(SLOT_ALLOW, _allowKey(2, sr02, bytes4(0))); // spender
        allowed[n++] = _assoc(SLOT_ALLOW, _allowKey(1, sr02, SwapDecoder.SR02_EXACT_INPUT_SINGLE)); // target+selector
        assertEq(n, 8);

        vm.record();
        vm.prank(wallet);
        policy.checkUserOpPolicy(PID, op);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(policy));

        assertEq(writes.length, 0, "validation must not write storage");
        assertGt(reads.length, 0);
        for (uint256 i; i < reads.length; ++i) {
            assertTrue(_inSet(reads[i], allowed), "validation read a slot that is not keyed by the sender");
        }
    }

    function test_sponsoredValidationReadsOnlySenderAssociatedStorage() public {
        PackedUserOperation memory op = _userOp(wallet, _wrapHooked(_buy(10 * U)));
        op.paymasterAndData = abi.encodePacked(paymaster, uint128(100_000), uint128(50_000));
        bytes32[] memory allowed = new bytes32[](9);
        uint256 n;
        bytes32 cfg = _assoc(SLOT_CFG, PID);
        allowed[n++] = cfg;
        allowed[n++] = bytes32(uint256(cfg) + 1);
        allowed[n++] = bytes32(uint256(cfg) + 2);
        allowed[n++] = _assoc(SLOT_GEN, PID);
        allowed[n++] = _assoc(SLOT_ALLOW, _allowKey(4, paymaster, bytes4(0))); // paymaster
        allowed[n++] = _assoc(SLOT_ALLOW, _allowKey(3, address(usdc), bytes4(0)));
        allowed[n++] = _assoc(SLOT_ALLOW, _allowKey(3, address(weth), bytes4(0)));
        allowed[n++] = _assoc(SLOT_ALLOW, _allowKey(1, sr02, SwapDecoder.SR02_EXACT_INPUT_SINGLE));
        vm.record();
        vm.prank(wallet);
        policy.checkUserOpPolicy(PID, op);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(policy));
        assertEq(writes.length, 0);
        for (uint256 i; i < reads.length; ++i) {
            assertTrue(_inSet(reads[i], allowed), "sponsored validation read a non-associated slot");
        }
    }

    function test_associatedSlotShapeMatchesErc7562() public view {
        // ERC-7562: a slot is associated with address A when it is A, keccak256(A || x) + n for 0 <= n <= 128 (A
        // padded to 32 bytes as the first word of the preimage). Solidity's `mapping(K => mapping(address => V))`
        // lays out the innermost level as keccak256(pad32(address) . innerBase), which is exactly that shape.
        bytes32 inner = keccak256(abi.encode(PID, SLOT_CFG));
        assertEq(_assoc(SLOT_CFG, PID), keccak256(abi.encodePacked(bytes32(uint256(uint160(wallet))), inner)));
    }

    function test_denialPathsAreAlsoStatic() public {
        // a denied op reverts, so nothing it touched can matter; but it must not need anything non-associated
        vm.record();
        vm.expectRevert();
        this.callPolicy(_single(attacker, 0, _sr02Single(address(usdc), address(weth), wallet, U, 0)));
        (, bytes32[] memory writes) = vm.accesses(address(policy));
        assertEq(writes.length, 0);
    }

    function callPolicy(bytes memory cd) external {
        PackedUserOperation memory op = _userOp(wallet, cd);
        vm.prank(wallet);
        policy.checkUserOpPolicy(PID, op);
    }
}
