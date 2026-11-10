// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {AgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";
import {IAgentRegistry} from "../src/interfaces/IAgentRegistry.sol";
import {Errors} from "../src/libraries/Errors.sol";

/// @title AgentPay (A2A) Tests — Agent-to-Agent payments on Monad
contract AgentPayTest is Test {
    MockUSDC usdc;
    AgentRegistry registry;
    PaymentRouter router;
    AgentWalletFactory walletFactory;

    address admin = address(this);
    address oracle = address(this);

    address agentA = address(0xA);
    address agentB = address(0xB);
    address agentC = address(0xC);
    address treasury = address(0xFEE);

    function setUp() public {
        usdc = new MockUSDC();
        registry = new AgentRegistry(admin, oracle);
        router = new PaymentRouter(address(usdc), address(registry), admin, oracle);
        walletFactory = new AgentWalletFactory(address(usdc), address(registry), admin);

        // Wire permissions
        registry.setPaymentRouter(address(router));
        registry.setWalletProgram(address(walletFactory));

        // Platform fee: 2%
        router.setPlatformTreasury(treasury);
        router.setPlatformFeeBps(200);

        // Register agents
        vm.prank(agentA);
        registry.registerAgent("ipfs://agentA");
        vm.prank(agentB);
        registry.registerAgent("ipfs://agentB");
        vm.prank(agentC);
        registry.registerAgent("ipfs://agentC");

        // Fund agents with USDC
        usdc.mint(agentA, 100_000e6);
        usdc.mint(agentB, 50_000e6);
        usdc.mint(agentC, 50_000e6);

        // Approve router to spend
        vm.prank(agentA);
        usdc.approve(address(router), type(uint256).max);
        vm.prank(agentB);
        usdc.approve(address(router), type(uint256).max);
        vm.prank(agentC);
        usdc.approve(address(router), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════
    // BASIC A2A PAYMENT
    // ═══════════════════════════════════════════════════════════════

    function test_agentPay_basic() public {
        vm.prank(agentA);
        router.agentPay(agentA, agentB, 1000e6, bytes32("invoice_001"));

        // Platform fee: 2% of 1000 = 20 USDC
        assertEq(usdc.balanceOf(treasury), 20e6, "treasury should get 2% fee");
        // agentB receives 980 USDC
        assertEq(usdc.balanceOf(agentB), 50_000e6 + 980e6, "agentB should receive net amount");
        // agentA spent 1000 USDC
        assertEq(usdc.balanceOf(agentA), 100_000e6 - 1000e6, "agentA should spend full amount");
    }

    function test_agentPay_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit IPaymentRouter.AgentPayment(agentA, agentB, agentA, agentB, 500e6, 10e6, bytes32("test"));

        vm.prank(agentA);
        router.agentPay(agentA, agentB, 500e6, bytes32("test"));
    }

    function test_agentPay_updatesA2AStats() public {
        vm.prank(agentA);
        router.agentPay(agentA, agentB, 1000e6, bytes32("pay1"));

        (uint256 sentA, uint256 recvA, uint256 txA) = router.getA2AStats(agentA);
        assertEq(sentA, 1000e6, "agentA sent");
        assertEq(recvA, 0, "agentA received");
        assertEq(txA, 1, "agentA tx count");

        (uint256 sentB, uint256 recvB, uint256 txB) = router.getA2AStats(agentB);
        assertEq(sentB, 0, "agentB sent");
        assertEq(recvB, 1000e6, "agentB received");
        assertEq(txB, 1, "agentB tx count");
    }

    function test_agentPay_multiplePayments() public {
        vm.startPrank(agentA);
        router.agentPay(agentA, agentB, 100e6, bytes32("p1"));
        router.agentPay(agentA, agentC, 200e6, bytes32("p2"));
        router.agentPay(agentA, agentB, 300e6, bytes32("p3"));
        vm.stopPrank();

        (uint256 sentA,, uint256 txA) = router.getA2AStats(agentA);
        assertEq(sentA, 600e6, "agentA total sent");
        assertEq(txA, 3, "agentA tx count");

        (, uint256 recvB, uint256 txB) = router.getA2AStats(agentB);
        assertEq(recvB, 400e6, "agentB total received");
        assertEq(txB, 2, "agentB tx count");
    }

    function test_agentPay_noFeeWhenZeroBps() public {
        router.setPlatformFeeBps(0);

        vm.prank(agentA);
        router.agentPay(agentA, agentB, 1000e6, bytes32("nofee"));

        assertEq(usdc.balanceOf(treasury), 0, "no fee collected");
        assertEq(usdc.balanceOf(agentB), 50_000e6 + 1000e6, "full amount to receiver");
    }

    function test_agentPay_emptyMemo() public {
        vm.prank(agentA);
        router.agentPay(agentA, agentB, 100e6, bytes32(0));
        // Should succeed with empty memo
        assertEq(usdc.balanceOf(agentB), 50_000e6 + 98e6);
    }

    // ═══════════════════════════════════════════════════════════════
    // BATCH A2A PAYMENTS
    // ═══════════════════════════════════════════════════════════════

    function test_agentPayBatch() public {
        address[] memory toAgents = new address[](2);
        toAgents[0] = agentB;
        toAgents[1] = agentC;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 500e6;
        amounts[1] = 300e6;

        bytes32[] memory memos = new bytes32[](2);
        memos[0] = bytes32("batch_1");
        memos[1] = bytes32("batch_2");

        vm.prank(agentA);
        router.agentPayBatch(agentA, toAgents, amounts, memos);

        // Platform fee: 2% of 800 = 16
        assertEq(usdc.balanceOf(treasury), 16e6, "batch platform fee");
        assertEq(usdc.balanceOf(agentB), 50_000e6 + 490e6, "agentB batch amount");
        assertEq(usdc.balanceOf(agentC), 50_000e6 + 294e6, "agentC batch amount");

        (uint256 sentA,,uint256 txA) = router.getA2AStats(agentA);
        assertEq(sentA, 800e6, "batch total sent");
        assertEq(txA, 2, "batch tx count");
    }

    function test_agentPayBatch_emitsBatchEvent() public {
        address[] memory toAgents = new address[](2);
        toAgents[0] = agentB;
        toAgents[1] = agentC;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e6;
        amounts[1] = 200e6;

        bytes32[] memory memos = new bytes32[](2);

        vm.expectEmit(true, false, false, true);
        emit IPaymentRouter.AgentPaymentBatch(agentA, 300e6, 2);

        vm.prank(agentA);
        router.agentPayBatch(agentA, toAgents, amounts, memos);
    }

    function test_agentPayBatch_revertsMismatchedArrays() public {
        address[] memory toAgents = new address[](2);
        toAgents[0] = agentB;
        toAgents[1] = agentC;

        uint256[] memory amounts = new uint256[](1); // wrong length
        amounts[0] = 100e6;

        bytes32[] memory memos = new bytes32[](2);

        vm.prank(agentA);
        vm.expectRevert(Errors.InvalidAmount.selector);
        router.agentPayBatch(agentA, toAgents, amounts, memos);
    }

    function test_agentPayBatch_revertsEmpty() public {
        address[] memory toAgents = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        bytes32[] memory memos = new bytes32[](0);

        vm.prank(agentA);
        vm.expectRevert(Errors.InvalidAmount.selector);
        router.agentPayBatch(agentA, toAgents, amounts, memos);
    }

    // ═══════════════════════════════════════════════════════════════
    // IDENTITY VERIFICATION
    // ═══════════════════════════════════════════════════════════════

    function test_agentPay_revertsUnregisteredSender() public {
        address unregistered = address(0xDEAD);
        usdc.mint(unregistered, 1000e6);
        vm.prank(unregistered);
        usdc.approve(address(router), type(uint256).max);

        vm.prank(unregistered);
        vm.expectRevert(Errors.AgentNotRegistered.selector);
        router.agentPay(unregistered, agentB, 100e6, bytes32("fail"));
    }

    function test_agentPay_revertsUnregisteredReceiver() public {
        address unregistered = address(0xDEAD);

        vm.prank(agentA);
        vm.expectRevert(Errors.AgentNotRegistered.selector);
        router.agentPay(agentA, unregistered, 100e6, bytes32("fail"));
    }

    function test_agentPay_revertsSelfPay() public {
        vm.prank(agentA);
        vm.expectRevert(Errors.InvalidAmount.selector);
        router.agentPay(agentA, agentA, 100e6, bytes32("self"));
    }

    function test_agentPay_revertsZeroAmount() public {
        vm.prank(agentA);
        vm.expectRevert(Errors.ZeroAmount.selector);
        router.agentPay(agentA, agentB, 0, bytes32("zero"));
    }

    function test_agentPay_revertsZeroAddresses() public {
        vm.prank(agentA);
        vm.expectRevert(Errors.ZeroAddress.selector);
        router.agentPay(address(0), agentB, 100e6, bytes32("zero"));

        vm.prank(agentA);
        vm.expectRevert(Errors.ZeroAddress.selector);
        router.agentPay(agentA, address(0), 100e6, bytes32("zero"));
    }

    // ═══════════════════════════════════════════════════════════════
    // AUTHORIZATION
    // ═══════════════════════════════════════════════════════════════

    function test_agentPay_revertsUnauthorizedCaller() public {
        // agentC tries to send FROM agentA's account
        vm.prank(agentC);
        vm.expectRevert(Errors.Unauthorized.selector);
        router.agentPay(agentA, agentB, 100e6, bytes32("steal"));
    }

    function test_agentPay_facilitatorCanSend() public {
        // Approve agentC as facilitator
        router.setFacilitator(agentC, true);

        // agentC sends on behalf of agentA
        vm.prank(agentC);
        router.agentPay(agentA, agentB, 100e6, bytes32("facilitated"));

        assertEq(usdc.balanceOf(agentB), 50_000e6 + 98e6);
    }

    // ═══════════════════════════════════════════════════════════════
    // BLOCKLIST
    // ═══════════════════════════════════════════════════════════════

    function test_agentPay_revertsBlocklistedSender() public {
        router.addToBlocklist(agentA);

        vm.prank(agentA);
        vm.expectRevert(Errors.Blocklisted.selector);
        router.agentPay(agentA, agentB, 100e6, bytes32("blocked"));
    }

    function test_agentPay_revertsBlocklistedReceiver() public {
        router.addToBlocklist(agentB);

        vm.prank(agentA);
        vm.expectRevert(Errors.Blocklisted.selector);
        router.agentPay(agentA, agentB, 100e6, bytes32("blocked"));
    }

    // ═══════════════════════════════════════════════════════════════
    // PAUSE
    // ═══════════════════════════════════════════════════════════════

    function test_agentPay_revertsWhenPaused() public {
        router.pause();

        vm.prank(agentA);
        vm.expectRevert(Errors.PlatformPaused.selector);
        router.agentPay(agentA, agentB, 100e6, bytes32("paused"));
    }

    // ═══════════════════════════════════════════════════════════════
    // SETTLEMENT ROUTING (credit line repayment)
    // ═══════════════════════════════════════════════════════════════

    function test_agentPay_withSettlement_noVault() public {
        // Without settlement, full net goes to receiver
        // (Settlement routing tested in PaymentRouterSettlement.t.sol)
        vm.prank(agentA);
        router.agentPay(agentA, agentB, 1000e6, bytes32("no_settlement"));

        assertEq(usdc.balanceOf(treasury), 20e6, "platform fee 2%");
        assertEq(usdc.balanceOf(agentB), 50_000e6 + 980e6, "full net to receiver");
    }

    // ═══════════════════════════════════════════════════════════════
    // REVENUE VALIDATOR INTEGRATION
    // ═══════════════════════════════════════════════════════════════

    function test_agentPay_creditsReceiverRevenue() public {
        // Create validator for agentB
        router.createRevenueValidator(agentB, agentB, agentB, 10_000e6, 50_000e6);

        vm.prank(agentA);
        router.agentPay(agentA, agentB, 1000e6, bytes32("revenue_credit"));

        // Check cumulative validated revenue (net after platform fee = 980)
        IPaymentRouter.RevenueValidator memory v = router.getValidator(agentB);
        assertEq(v.cumulativeValidatedRevenue, 980e6, "revenue credited to receiver");
    }

    // ═══════════════════════════════════════════════════════════════
    // WALLET RESOLUTION (CREATE2 wallets)
    // ═══════════════════════════════════════════════════════════════

    function test_agentPay_withCreate2Wallets() public {
        // Create wallets for both agents
        registry.setFactory(address(walletFactory));

        vm.prank(agentA);
        walletFactory.createWallet(agentA, 100_000e6, 50_000e6);

        vm.prank(agentB);
        address walletB = walletFactory.createWallet(agentB, 100_000e6, 50_000e6);

        // Verify wallet is linked
        IAgentRegistry.Agent memory a = registry.getAgent(agentA);
        assertTrue(a.hasWallet, "agentA has wallet");

        // A2A pulls from sender's EOA (not wallet contract)
        // and delivers to receiver's wallet contract
        vm.prank(agentA);
        router.agentPay(agentA, agentB, 500e6, bytes32("wallet_pay"));

        // Agent A EOA debited
        assertEq(usdc.balanceOf(agentA), 100_000e6 - 500e6, "agentA EOA debited");
        // Agent B wallet contract credited (receiver resolves to wallet)
        uint256 netToB = 500e6 - (500e6 * 200 / 10_000); // 490 USDC
        assertEq(usdc.balanceOf(walletB), netToB, "walletB credited net");
    }

    // ═══════════════════════════════════════════════════════════════
    // REGISTRY STATS UPDATE
    // ═══════════════════════════════════════════════════════════════

    function test_agentPay_updatesRegistryStats() public {
        vm.prank(agentA);
        router.agentPay(agentA, agentB, 1000e6, bytes32("stats"));

        // Check registry stats updated
        IAgentRegistry.Agent memory a = registry.getAgent(agentA);
        assertEq(a.totalVolumeUsd, 1000e6, "sender volume updated");

        IAgentRegistry.Agent memory b = registry.getAgent(agentB);
        assertEq(b.totalVolumeUsd, 1000e6, "receiver volume updated");
    }

    // ═══════════════════════════════════════════════════════════════
    // EDGE CASES
    // ═══════════════════════════════════════════════════════════════

    function test_agentPay_smallAmount() public {
        vm.prank(agentA);
        router.agentPay(agentA, agentB, 1, bytes32("dust")); // 0.000001 USDC

        // Platform fee on 1 = 0 (rounds down)
        assertEq(usdc.balanceOf(agentB), 50_000e6 + 1);
    }

    function test_agentPay_largeAmount() public {
        usdc.mint(agentA, 1_000_000e6); // extra 1M

        vm.prank(agentA);
        router.agentPay(agentA, agentB, 1_000_000e6, bytes32("large"));

        // Fee: 2% of 1M = 20K
        assertEq(usdc.balanceOf(treasury), 20_000e6);
        assertEq(usdc.balanceOf(agentB), 50_000e6 + 980_000e6);
    }

    function test_agentPay_insufficientBalance() public {
        vm.prank(agentA);
        vm.expectRevert(); // ERC20 insufficient balance
        router.agentPay(agentA, agentB, 200_000e6, bytes32("broke")); // only has 100K
    }

    function test_agentPay_bidirectional() public {
        // A pays B, then B pays A
        vm.prank(agentA);
        router.agentPay(agentA, agentB, 500e6, bytes32("a_to_b"));

        vm.prank(agentB);
        router.agentPay(agentB, agentA, 300e6, bytes32("b_to_a"));

        (uint256 sentA, uint256 recvA,) = router.getA2AStats(agentA);
        assertEq(sentA, 500e6);
        assertEq(recvA, 300e6);

        (uint256 sentB, uint256 recvB,) = router.getA2AStats(agentB);
        assertEq(sentB, 300e6);
        assertEq(recvB, 500e6);
    }

    function test_agentPay_threeWayCircular() public {
        // A→B, B→C, C→A
        vm.prank(agentA);
        router.agentPay(agentA, agentB, 100e6, bytes32("a_b"));

        vm.prank(agentB);
        router.agentPay(agentB, agentC, 100e6, bytes32("b_c"));

        vm.prank(agentC);
        router.agentPay(agentC, agentA, 100e6, bytes32("c_a"));

        // All agents should have 3 fee deductions total
        assertEq(usdc.balanceOf(treasury), 6e6, "3 x 2 USDC fees");
    }
}
