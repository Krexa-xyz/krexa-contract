// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {WaterfallLib} from "../src/libraries/WaterfallLib.sol";

contract WaterfallTest is Test {
    function test_distribute_allToSenior() public pure {
        WaterfallLib.Distribution memory d = WaterfallLib.distribute(100e6, 50e6, 80e6);
        assertEq(d.seniorPayment, 80e6);
        assertEq(d.poolPayment, 0);
        assertEq(d.communityPayment, 0);
    }

    function test_distribute_seniorAndPool() public pure {
        WaterfallLib.Distribution memory d = WaterfallLib.distribute(100e6, 50e6, 120e6);
        assertEq(d.seniorPayment, 100e6);
        assertEq(d.poolPayment, 20e6);
        assertEq(d.communityPayment, 0);
    }

    function test_distribute_allTiers() public pure {
        WaterfallLib.Distribution memory d = WaterfallLib.distribute(100e6, 50e6, 200e6);
        assertEq(d.seniorPayment, 100e6);
        assertEq(d.poolPayment, 50e6);
        assertEq(d.communityPayment, 50e6);
    }

    function test_distribute_zeroAmount() public pure {
        WaterfallLib.Distribution memory d = WaterfallLib.distribute(100e6, 50e6, 0);
        assertEq(d.seniorPayment, 0);
        assertEq(d.poolPayment, 0);
        assertEq(d.communityPayment, 0);
    }

    function test_distribute_zeroOwed() public pure {
        WaterfallLib.Distribution memory d = WaterfallLib.distribute(0, 0, 500e6);
        assertEq(d.seniorPayment, 0);
        assertEq(d.poolPayment, 0);
        assertEq(d.communityPayment, 500e6);
    }

    function test_distribute_exactSenior() public pure {
        WaterfallLib.Distribution memory d = WaterfallLib.distribute(100e6, 50e6, 100e6);
        assertEq(d.seniorPayment, 100e6);
        assertEq(d.poolPayment, 0);
        assertEq(d.communityPayment, 0);
    }

    function test_distribute_exactSeniorAndPool() public pure {
        WaterfallLib.Distribution memory d = WaterfallLib.distribute(100e6, 50e6, 150e6);
        assertEq(d.seniorPayment, 100e6);
        assertEq(d.poolPayment, 50e6);
        assertEq(d.communityPayment, 0);
    }

    function testFuzz_distribute_totalEqualsInput(uint128 senior, uint128 pool, uint128 amount) public pure {
        WaterfallLib.Distribution memory d = WaterfallLib.distribute(
            uint256(senior), uint256(pool), uint256(amount)
        );
        assertEq(d.seniorPayment + d.poolPayment + d.communityPayment, uint256(amount));
    }
}
