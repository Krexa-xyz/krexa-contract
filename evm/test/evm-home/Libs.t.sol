// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OracleLib} from "../../src/evm-home/lib/OracleLib.sol";
import {ExecDecoder} from "../../src/evm-home/lib/ExecDecoder.sol";
import {SwapDecoder} from "../../src/evm-home/lib/SwapDecoder.sol";
import {MockFeed} from "./mocks/Mocks.sol";

contract OracleHarness {
    function read(address feed, uint32 maxAge) external view returns (bool, uint256, uint8) {
        return OracleLib.read(feed, maxAge);
    }

    function toUsdc(uint256 a, uint8 td, uint256 ans, uint8 fd) external pure returns (uint256) {
        return OracleLib.toUsdc(a, td, ans, fd);
    }
}

contract BadDecimalsFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e8, block.timestamp, block.timestamp, 1);
    }

    function decimals() external pure returns (uint8, uint8) {
        return (8, 8);
    }
}

contract LibsTest is Test {
    OracleHarness internal h = new OracleHarness();

    function test_toUsdcMath() public view {
        // 1 ETH (18 dec) at $2500 (8 dec feed) = 2500e6
        assertEq(h.toUsdc(1e18, 18, 2500e8, 8), 2500e6);
        // 1 WBTC (8 dec) at $60k (8 dec feed)
        assertEq(h.toUsdc(1e8, 8, 60_000e8, 8), 60_000e6);
        // exponent below 6 (2-decimal token, 2-decimal feed): scales up
        assertEq(h.toUsdc(100, 2, 250, 2), 2_500_000); // 1.00 token at $2.50 = 2.5 USDC
        // rounds down
        assertEq(h.toUsdc(1, 18, 2500e8, 8), 0);
    }

    function testFuzz_toUsdcMonotonic(uint128 a, uint128 b) public view {
        (uint128 lo, uint128 hi) = a < b ? (a, b) : (b, a);
        assertLe(h.toUsdc(lo, 18, 2500e8, 8), h.toUsdc(hi, 18, 2500e8, 8));
    }

    function test_readBranches() public {
        (bool ok,,) = h.read(address(0), 3600);
        assertFalse(ok);
        (ok,,) = h.read(address(0xdead), 3600); // EOA / no code: staticcall succeeds with empty return
        assertFalse(ok);
        (ok,,) = h.read(address(new BadDecimalsFeed()), 3600); // decimals() returns 64 bytes
        assertFalse(ok);
        MockFeed f = new MockFeed(8, 2500e8);
        uint256 ans;
        uint8 d;
        (ok, ans, d) = h.read(address(f), 3600);
        assertTrue(ok);
        assertEq(ans, 2500e8);
        assertEq(d, 8);
        vm.warp(block.timestamp + 3601);
        (ok,,) = h.read(address(f), 3600);
        assertFalse(ok);
        (ok,,) = h.read(address(f), 3601);
        assertTrue(ok);
    }

    function test_selectorConstantsMatchSignatures() public pure {
        assertEq(ExecDecoder.EXECUTE, bytes4(keccak256("execute(bytes32,bytes)")));
        assertEq(
            ExecDecoder.EXECUTE_USER_OP,
            bytes4(keccak256("executeUserOp((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes),bytes32)"))
        );
        assertEq(
            SwapDecoder.SR02_EXACT_INPUT_SINGLE,
            bytes4(keccak256("exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))"))
        );
        assertEq(SwapDecoder.SR02_EXACT_INPUT, bytes4(keccak256("exactInput((bytes,address,uint256,uint256))")));
        assertEq(SwapDecoder.UR_EXECUTE, bytes4(keccak256("execute(bytes,bytes[],uint256)")));
        assertEq(SwapDecoder.ZEROX_EXEC, bytes4(keccak256("exec(address,address,uint256,address,bytes)")));
        assertEq(
            SwapDecoder.ZEROX_SETTLER_EXECUTE, bytes4(keccak256("execute((address,address,uint256),bytes[],bytes32)"))
        );
        assertEq(SwapDecoder.ERC20_APPROVE, bytes4(keccak256("approve(address,uint256)")));
        assertEq(SwapDecoder.PERMIT2_APPROVE, bytes4(keccak256("approve(address,address,uint160,uint48)")));
        // literal values copied from the deployed routers' published ABIs
        assertEq(SwapDecoder.UR_EXECUTE, bytes4(0x3593564c));
        assertEq(SwapDecoder.SR02_EXACT_INPUT_SINGLE, bytes4(0x04e45aaf));
    }

    function test_swapDecoderUnknownSelector() public {
        vm.expectRevert(abi.encodeWithSelector(SwapDecoder.SelectorUnsupported.selector, bytes4(0xdeadbeef)));
        this.decodeExt(bytes4(0xdeadbeef), hex"deadbeef");
        vm.expectRevert(SwapDecoder.Malformed.selector);
        this.decodeExt(SwapDecoder.UR_EXECUTE, hex"12");
    }

    function decodeExt(bytes4 sel, bytes memory data) external pure returns (SwapDecoder.Swap[] memory) {
        return SwapDecoder.decodeSwaps(address(1), sel, data);
    }
}
