// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {IAgentRegistry} from "../src/interfaces/IAgentRegistry.sol";
import {Errors} from "../src/libraries/Errors.sol";

contract AgentRegistryTest is Test {
    AgentRegistry public registry;
    address admin = makeAddr("admin");
    address oracle = makeAddr("oracle");
    address agent1 = makeAddr("agent1");
    address agent2 = makeAddr("agent2");

    function setUp() public {
        registry = new AgentRegistry(admin, oracle);
    }

    // ════════════════════════════════════════════════════════════════
    // Registration
    // ════════════════════════════════════════════════════════════════

    function test_registerAgent() public {
        vm.prank(agent1);
        registry.registerAgent("ipfs://QmAgent1");

        assertTrue(registry.isRegistered(agent1));
        IAgentRegistry.Agent memory a = registry.getAgent(agent1);
        assertEq(a.metadataURI, "ipfs://QmAgent1");
        assertEq(a.creditScore, 350); // DEFAULT_CREDIT_SCORE
        assertEq(uint8(a.creditLevel), uint8(IAgentRegistry.CreditLevel.L0));
        assertEq(a.kyaTier, 0);
        assertEq(a.owner, agent1);
        assertTrue(a.active);
        assertEq(registry.getAgentCount(), 1);
    }

    function test_registerAgent_duplicate_reverts() public {
        vm.prank(agent1);
        registry.registerAgent("ipfs://QmAgent1");

        vm.prank(agent1);
        vm.expectRevert(Errors.AgentAlreadyRegistered.selector);
        registry.registerAgent("ipfs://QmAgent1v2");
    }

    function test_registerAgent_emptyMetadata_reverts() public {
        vm.prank(agent1);
        vm.expectRevert(Errors.InvalidMetadata.selector);
        registry.registerAgent("");
    }

    // ════════════════════════════════════════════════════════════════
    // Metadata
    // ════════════════════════════════════════════════════════════════

    function test_updateMetadata() public {
        vm.prank(agent1);
        registry.registerAgent("ipfs://v1");

        vm.prank(agent1);
        registry.updateMetadata("ipfs://v2");

        assertEq(registry.getAgent(agent1).metadataURI, "ipfs://v2");
    }

    // ════════════════════════════════════════════════════════════════
    // KYA Updates
    // ════════════════════════════════════════════════════════════════

    function test_updateKya_oracleCanUpdate() public {
        vm.prank(agent1);
        registry.registerAgent("ipfs://a");

        vm.prank(oracle);
        registry.updateKya(agent1, 2);

        assertEq(registry.getKyaTier(agent1), 2);
    }

    function test_updateKya_adminCanUpdate() public {
        vm.prank(agent1);
        registry.registerAgent("ipfs://a");

        vm.prank(admin);
        registry.updateKya(agent1, 1);

        assertEq(registry.getKyaTier(agent1), 1);
    }

    function test_updateKya_recalculatesLevel() public {
        vm.prank(agent1);
        registry.registerAgent("ipfs://a");

        // Score 350 + KYA 1 → L1
        vm.prank(oracle);
        registry.updateKya(agent1, 1);
        assertEq(uint8(registry.getCreditLevel(agent1)), uint8(IAgentRegistry.CreditLevel.L1));
    }

    function test_updateKya_invalidTier_reverts() public {
        vm.prank(agent1);
        registry.registerAgent("ipfs://a");

        vm.prank(oracle);
        vm.expectRevert(Errors.InvalidKyaTier.selector);
        registry.updateKya(agent1, 4);
    }

    function test_updateKya_unauthorized_reverts() public {
        vm.prank(agent1);
        registry.registerAgent("ipfs://a");

        vm.prank(agent2);
        vm.expectRevert(Errors.OnlyAdminOrOracle.selector);
        registry.updateKya(agent1, 1);
    }

    // ════════════════════════════════════════════════════════════════
    // Credit Score Updates
    // ════════════════════════════════════════════════════════════════

    function test_updateCreditScore_updatesLevelAndTimestamp() public {
        vm.prank(agent1);
        registry.registerAgent("ipfs://a");

        vm.startPrank(oracle);
        registry.updateKya(agent1, 2);
        registry.updateCreditScore(agent1, 750);
        vm.stopPrank();

        IAgentRegistry.Agent memory a = registry.getAgent(agent1);
        assertEq(a.creditScore, 750);
        assertEq(uint8(a.creditLevel), uint8(IAgentRegistry.CreditLevel.L4));
        assertTrue(a.scoreUpdatedAt > 0);
    }

    function test_updateCreditScore_onlyOracle() public {
        vm.prank(agent1);
        registry.registerAgent("ipfs://a");

        vm.prank(admin);
        vm.expectRevert(Errors.OnlyOracle.selector);
        registry.updateCreditScore(agent1, 500);
    }

    function test_updateCreditScore_below200_reverts() public {
        vm.prank(agent1);
        registry.registerAgent("ipfs://a");

        vm.prank(oracle);
        vm.expectRevert(Errors.CreditScoreOutOfRange.selector);
        registry.updateCreditScore(agent1, 199);
    }

    function test_updateCreditScore_above850_reverts() public {
        vm.prank(agent1);
        registry.registerAgent("ipfs://a");

        vm.prank(oracle);
        vm.expectRevert(Errors.CreditScoreOutOfRange.selector);
        registry.updateCreditScore(agent1, 851);
    }

    // ════════════════════════════════════════════════════════════════
    // Liquidation
    // ════════════════════════════════════════════════════════════════

    function test_recordLiquidation() public {
        vm.prank(agent1);
        registry.registerAgent("ipfs://a");

        vm.prank(oracle);
        registry.updateCreditScore(agent1, 500);

        vm.prank(admin);
        registry.recordLiquidation(agent1);

        IAgentRegistry.Agent memory a = registry.getAgent(agent1);
        assertEq(a.creditScore, 460); // 500 - 40
        assertEq(a.liquidationCount, 1);
    }

    function test_recordLiquidation_floorsAt200() public {
        vm.prank(agent1);
        registry.registerAgent("ipfs://a");

        vm.prank(oracle);
        registry.updateCreditScore(agent1, 220);

        vm.prank(admin);
        registry.recordLiquidation(agent1);

        assertEq(registry.getAgent(agent1).creditScore, 200);
    }

    // ════════════════════════════════════════════════════════════════
    // Agent Types
    // ════════════════════════════════════════════════════════════════

    function test_setAgentType() public {
        vm.prank(agent1);
        registry.registerAgent("ipfs://a");

        vm.prank(oracle);
        registry.setAgentType(agent1, IAgentRegistry.AgentType.Service);

        assertEq(uint8(registry.getAgent(agent1).agentType), uint8(IAgentRegistry.AgentType.Service));
    }

    // ════════════════════════════════════════════════════════════════
    // Ownership Transfer
    // ════════════════════════════════════════════════════════════════

    function test_ownershipTransfer_fullCycle() public {
        vm.prank(agent1);
        registry.registerAgent("ipfs://a");

        // Propose
        vm.prank(agent1);
        registry.proposeOwnershipTransfer(agent1, agent2);

        IAgentRegistry.OwnershipTransfer memory t = registry.getOwnershipTransfer(agent1);
        assertEq(t.proposedOwner, agent2);

        // Accept
        vm.prank(agent2);
        registry.acceptOwnershipTransfer(agent1);

        assertEq(registry.getAgent(agent1).owner, agent2);
    }

    function test_ownershipTransfer_cancel() public {
        vm.prank(agent1);
        registry.registerAgent("ipfs://a");

        vm.prank(agent1);
        registry.proposeOwnershipTransfer(agent1, agent2);

        vm.prank(agent1);
        registry.cancelOwnershipTransfer(agent1);

        IAgentRegistry.OwnershipTransfer memory t = registry.getOwnershipTransfer(agent1);
        assertEq(t.proposedAt, 0);
    }

    function test_ownershipTransfer_wrongAcceptor_reverts() public {
        vm.prank(agent1);
        registry.registerAgent("ipfs://a");

        vm.prank(agent1);
        registry.proposeOwnershipTransfer(agent1, agent2);

        address random = makeAddr("random");
        vm.prank(random);
        vm.expectRevert(Errors.NotProposedOwner.selector);
        registry.acceptOwnershipTransfer(agent1);
    }

    // ════════════════════════════════════════════════════════════════
    // Deactivate / Reactivate
    // ════════════════════════════════════════════════════════════════

    function test_deactivateAgent_stripsLevel() public {
        vm.prank(agent1);
        registry.registerAgent("ipfs://a");

        vm.startPrank(oracle);
        registry.updateKya(agent1, 1);
        registry.updateCreditScore(agent1, 500);
        vm.stopPrank();
        assertEq(uint8(registry.getCreditLevel(agent1)), uint8(IAgentRegistry.CreditLevel.L2));

        vm.prank(admin);
        registry.deactivateAgent(agent1);

        IAgentRegistry.Agent memory a = registry.getAgent(agent1);
        assertFalse(a.active);
        assertEq(uint8(a.creditLevel), uint8(IAgentRegistry.CreditLevel.L0));
    }

    function test_reactivateAgent_recalculatesLevel() public {
        vm.prank(agent1);
        registry.registerAgent("ipfs://a");

        vm.startPrank(oracle);
        registry.updateKya(agent1, 1);
        registry.updateCreditScore(agent1, 500);
        vm.stopPrank();

        vm.prank(admin);
        registry.deactivateAgent(agent1);

        vm.prank(admin);
        registry.reactivateAgent(agent1);

        IAgentRegistry.Agent memory a = registry.getAgent(agent1);
        assertTrue(a.active);
        assertEq(uint8(a.creditLevel), uint8(IAgentRegistry.CreditLevel.L2));
    }

    // ════════════════════════════════════════════════════════════════
    // Wallet Link
    // ════════════════════════════════════════════════════════════════

    function test_linkWallet_onceOnly() public {
        vm.prank(agent1);
        registry.registerAgent("ipfs://a");

        address wallet = makeAddr("wallet");
        vm.prank(admin);
        registry.linkWallet(agent1, wallet);

        assertTrue(registry.getAgent(agent1).hasWallet);
        assertEq(registry.getAgent(agent1).walletContract, wallet);

        // Second link reverts
        vm.prank(admin);
        vm.expectRevert(Errors.WalletAlreadyLinked.selector);
        registry.linkWallet(agent1, wallet);
    }

    // ════════════════════════════════════════════════════════════════
    // Vault Link & Auth
    // ════════════════════════════════════════════════════════════════

    function test_linkVault_onlyAuthorized() public {
        vm.prank(agent1);
        registry.registerAgent("ipfs://QmAgent1");

        address vault = makeAddr("vault");

        vm.prank(agent2);
        vm.expectRevert(Errors.Unauthorized.selector);
        registry.linkVault(agent1, vault);

        vm.prank(admin);
        registry.linkVault(agent1, vault);
        assertTrue(registry.hasActiveCreditLine(agent1));
        assertEq(registry.getVault(agent1), vault);
    }

    // ════════════════════════════════════════════════════════════════
    // Pause
    // ════════════════════════════════════════════════════════════════

    function test_pause_blocksRegistration() public {
        vm.prank(admin);
        registry.pause();

        vm.prank(agent1);
        vm.expectRevert(Errors.PlatformPaused.selector);
        registry.registerAgent("ipfs://a");
    }

    function test_unpause_allowsRegistration() public {
        vm.prank(admin);
        registry.pause();

        vm.prank(admin);
        registry.unpause();

        vm.prank(agent1);
        registry.registerAgent("ipfs://a");
        assertTrue(registry.isRegistered(agent1));
    }

    // ════════════════════════════════════════════════════════════════
    // Admin Config
    // ════════════════════════════════════════════════════════════════

    function test_setFactory_onlyAdmin() public {
        address factoryAddr = makeAddr("factory");

        vm.prank(agent1);
        vm.expectRevert(Errors.Unauthorized.selector);
        registry.setFactory(factoryAddr);

        vm.prank(admin);
        registry.setFactory(factoryAddr);
        assertEq(registry.factory(), factoryAddr);
    }

    function test_setOracle() public {
        address newOracle = makeAddr("newOracle");
        vm.prank(admin);
        registry.setOracle(newOracle);
        assertEq(registry.oracle(), newOracle);
    }

    function test_adminTransfer() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        registry.proposeAdmin(newAdmin);

        vm.prank(newAdmin);
        registry.acceptAdmin();

        assertEq(registry.admin(), newAdmin);
    }

    // ════════════════════════════════════════════════════════════════
    // Legal Agreement
    // ════════════════════════════════════════════════════════════════

    function test_signLegalAgreement() public {
        vm.prank(agent1);
        registry.registerAgent("ipfs://a");

        bytes32 hash = keccak256("credit agreement v1");
        vm.prank(agent1);
        registry.signLegalAgreement(agent1, hash);
        // Just verifying it doesn't revert — event emission tested implicitly
    }

    function test_signLegalAgreement_unauthorized_reverts() public {
        vm.prank(agent1);
        registry.registerAgent("ipfs://a");

        vm.prank(agent2);
        vm.expectRevert(Errors.NotAgentOrOwner.selector);
        registry.signLegalAgreement(agent1, keccak256("x"));
    }
}
