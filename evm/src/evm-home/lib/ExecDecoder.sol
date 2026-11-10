// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ExecDecoder
/// @notice Decodes the calldata a Kernel v3.3 account will execute for a UserOp into a list of calls.
///
/// Kernel entry points (source: ZeroDev Kernel v3.3 `src/Kernel.sol`, `executeUserOp` and `execute`,
/// and `src/utils/ExecLib.sol`):
///  - A UserOp for a validation without a hook carries `execute(bytes32 mode, bytes executionCalldata)`.
///  - A UserOp for a validation WITH a hook must carry `executeUserOp.selector ++ execute(...)`;
///    Kernel strips the first 4 bytes, calls `hook.preCheck(..., callData[4:])`, then delegatecalls the rest
///    into itself. So `callData` here may start with either selector; the hook receives the stripped form.
///  - mode byte 0 = call type (0x00 single, 0x01 batch; 0xfe static and 0xff delegatecall are rejected),
///    byte 1 = exec type (0x00 revert on failure; 0x01 "try" is rejected so a failing leg cannot be skipped).
///  - single: `target(20) ++ value(32) ++ data`; batch: `abi.encode(Execution[])`.
///
/// Parser-differential defence: Kernel parses the batch with Solady `LibERC7579.decodeBatch`, which accepts
/// non-canonical pointer layouts. We re-encode what `abi.decode` produced and require it to equal the input
/// byte for byte, so every parser reads the same calls.
library ExecDecoder {
    /// @dev `execute(bytes32,bytes)`
    bytes4 internal constant EXECUTE = 0xe9ae5c53;
    /// @dev `executeUserOp(PackedUserOperation,bytes32)`
    bytes4 internal constant EXECUTE_USER_OP = 0x8dd7712f;

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    error NotExecute();
    error UnsupportedMode(bytes32 mode);
    error BadEncoding();

    function decode(bytes calldata callData) internal pure returns (Call[] memory calls) {
        if (callData.length >= 4 && bytes4(callData[:4]) == EXECUTE_USER_OP) callData = callData[4:];
        if (callData.length < 4 || bytes4(callData[:4]) != EXECUTE) revert NotExecute();
        (bytes32 mode, bytes memory ec) = abi.decode(callData[4:], (bytes32, bytes));
        if (mode[1] != 0x00) revert UnsupportedMode(mode);
        bytes1 callType = mode[0];
        if (callType == 0x00) {
            if (ec.length < 0x34) revert BadEncoding();
            calls = new Call[](1);
            address target;
            uint256 value;
            assembly ("memory-safe") {
                target := shr(96, mload(add(ec, 0x20)))
                value := mload(add(ec, 0x34))
            }
            calls[0] = Call(target, value, _slice(ec, 0x34));
        } else if (callType == 0x01) {
            calls = abi.decode(ec, (Call[]));
            if (keccak256(abi.encode(calls)) != keccak256(ec)) revert BadEncoding();
        } else {
            revert UnsupportedMode(mode);
        }
    }

    /// @dev copy of `b[start:]`
    function _slice(bytes memory b, uint256 start) private pure returns (bytes memory out) {
        uint256 len = b.length - start;
        out = new bytes(len);
        assembly ("memory-safe") {
            mcopy(add(out, 0x20), add(add(b, 0x20), start), len)
        }
    }
}
