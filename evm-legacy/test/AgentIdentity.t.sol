// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {Errors} from "../src/libraries/Errors.sol";

contract AgentIdentityTest is Test {
    AgentIdentity public identity;

    address admin = makeAddr("admin");
    address agent1 = makeAddr("agent1");
    address agent2 = makeAddr("agent2");

    function setUp() public {
        identity = new AgentIdentity(admin);
    }

    function test_mintIdentity() public {
        vm.prank(admin);
        identity.mintIdentity(agent1);

        assertTrue(identity.hasIdentity(agent1));
        assertEq(identity.tokenOfAgent(agent1), 1);
        assertEq(identity.balanceOf(agent1), 1);
    }

    function test_mintIdentity_onlyAdmin() public {
        vm.prank(agent1);
        vm.expectRevert(Errors.Unauthorized.selector);
        identity.mintIdentity(agent1);
    }

    function test_mintIdentity_revertDuplicate() public {
        vm.prank(admin);
        identity.mintIdentity(agent1);

        vm.prank(admin);
        vm.expectRevert(Errors.AgentAlreadyRegistered.selector);
        identity.mintIdentity(agent1);
    }

    function test_soulbound_transferBlocked() public {
        vm.prank(admin);
        identity.mintIdentity(agent1);

        vm.prank(agent1);
        vm.expectRevert(Errors.Unauthorized.selector);
        identity.transferFrom(agent1, agent2, 1);
    }

    function test_soulbound_approveBlocked() public {
        vm.prank(admin);
        identity.mintIdentity(agent1);

        vm.prank(agent1);
        vm.expectRevert(Errors.Unauthorized.selector);
        identity.approve(agent2, 1);
    }

    function test_updateReputation() public {
        vm.prank(admin);
        identity.mintIdentity(agent1);

        vm.prank(admin);
        identity.updateReputation(agent1, 100, 50_000e6, 20, 0);

        AgentIdentity.Reputation memory rep = identity.getReputation(agent1);
        assertEq(rep.totalTransactions, 100);
        assertEq(rep.totalVolumeUsdc, 50_000e6);
        assertEq(rep.successfulRepayments, 20);
        assertEq(rep.defaultCount, 0);
    }

    function test_updateReputation_notRegistered() public {
        vm.prank(admin);
        vm.expectRevert(Errors.AgentNotRegistered.selector);
        identity.updateReputation(agent1, 100, 50_000e6, 20, 0);
    }

    function test_computeReputationScore_zero() public view {
        uint16 score = identity.computeReputationScore(agent1);
        assertEq(score, 0);
    }

    function test_computeReputationScore_withStats() public {
        vm.prank(admin);
        identity.mintIdentity(agent1);

        // 50k volume → 200/400, 20 repayments → 120/300, 0 age → 0, 0 defaults
        vm.prank(admin);
        identity.updateReputation(agent1, 100, 50_000e6, 20, 0);

        uint16 score = identity.computeReputationScore(agent1);
        // Volume: 50k/100k * 400 = 200, Repayments: 20/50 * 300 = 120, Age: ~0
        assertGe(score, 300);
        assertLe(score, 350);
    }

    function test_computeReputationScore_withAge() public {
        vm.prank(admin);
        identity.mintIdentity(agent1);

        vm.prank(admin);
        identity.updateReputation(agent1, 100, 100_000e6, 50, 0);

        // Advance 1 year
        vm.warp(block.timestamp + 365 days);

        uint16 score = identity.computeReputationScore(agent1);
        // Max: 400 + 300 + 200 = 900
        assertEq(score, 900);
    }

    function test_computeReputationScore_withDefaults() public {
        vm.prank(admin);
        identity.mintIdentity(agent1);

        vm.prank(admin);
        identity.updateReputation(agent1, 100, 100_000e6, 50, 3);

        vm.warp(block.timestamp + 365 days);

        uint16 score = identity.computeReputationScore(agent1);
        // 900 - 60 (3 defaults * 20) = 840
        assertEq(score, 840);
    }

    function test_setMetadataURI() public {
        vm.prank(admin);
        identity.mintIdentity(agent1);

        vm.prank(admin);
        identity.setMetadataURI(agent1, "ipfs://QmTest");

        AgentIdentity.Reputation memory rep = identity.getReputation(agent1);
        assertEq(rep.metadataURI, "ipfs://QmTest");
    }
}
