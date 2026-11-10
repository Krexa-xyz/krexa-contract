// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {IAgentRegistry} from "../src/interfaces/IAgentRegistry.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {Errors} from "../src/libraries/Errors.sol";

contract CreditScoringTest is Test {
    MockUSDC public usdc;
    AgentRegistry public registry;
    PaymentRouter public router;
    VaultFactory public factory;

    address oracle = vm.addr(0xB0B);
    address admin = makeAddr("admin");
    address agent = makeAddr("translateBot");
    address agent2 = makeAddr("shopBot");
    address feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        usdc = new MockUSDC();
        registry = new AgentRegistry(admin, oracle);
        router = new PaymentRouter(address(usdc), address(registry), admin, oracle);

        vm.startPrank(admin);
        registry.setPaymentRouter(address(router));
        factory = new VaultFactory(
            admin, oracle, address(usdc), 200, feeRecipient,
            address(registry), address(router)
        );
        registry.setFactory(address(factory));
        router.setFactory(address(factory));
        vm.stopPrank();

        vm.prank(agent);
        registry.registerAgent("ipfs://translateBot");

        vm.prank(agent2);
        registry.registerAgent("ipfs://shopBot");
    }

    // ════════════════════════════════════════════════════════════════
    // Credit Level Derivation (score + KYA)
    // ════════════════════════════════════════════════════════════════

    function test_calculateLevel_L4() public view {
        // L4: score >= 750 && KYA >= 2
        assertEq(uint8(registry.calculateLevel(750, 2)), uint8(IAgentRegistry.CreditLevel.L4));
        assertEq(uint8(registry.calculateLevel(850, 3)), uint8(IAgentRegistry.CreditLevel.L4));
    }

    function test_calculateLevel_L3() public view {
        // L3: score >= 650 && KYA >= 2
        assertEq(uint8(registry.calculateLevel(650, 2)), uint8(IAgentRegistry.CreditLevel.L3));
        assertEq(uint8(registry.calculateLevel(749, 2)), uint8(IAgentRegistry.CreditLevel.L3));
    }

    function test_calculateLevel_L2() public view {
        // L2: score >= 500 && KYA >= 1
        assertEq(uint8(registry.calculateLevel(500, 1)), uint8(IAgentRegistry.CreditLevel.L2));
        assertEq(uint8(registry.calculateLevel(649, 1)), uint8(IAgentRegistry.CreditLevel.L2));
    }

    function test_calculateLevel_L1() public view {
        // L1: any score && KYA >= 1
        assertEq(uint8(registry.calculateLevel(200, 1)), uint8(IAgentRegistry.CreditLevel.L1));
        assertEq(uint8(registry.calculateLevel(499, 1)), uint8(IAgentRegistry.CreditLevel.L1));
    }

    function test_calculateLevel_L0() public view {
        // L0: KYA == 0 (regardless of score)
        assertEq(uint8(registry.calculateLevel(850, 0)), uint8(IAgentRegistry.CreditLevel.L0));
        assertEq(uint8(registry.calculateLevel(200, 0)), uint8(IAgentRegistry.CreditLevel.L0));
    }

    // ════════════════════════════════════════════════════════════════
    // KYA + Score Updates
    // ════════════════════════════════════════════════════════════════

    function test_updateKya_recalculatesLevel() public {
        // Agent starts at score 350, KYA 0 → L0
        assertEq(uint8(registry.getCreditLevel(agent)), uint8(IAgentRegistry.CreditLevel.L0));

        // Oracle sets score to 750
        vm.prank(oracle);
        registry.updateCreditScore(agent, 750);
        // Still L0 because KYA = 0
        assertEq(uint8(registry.getCreditLevel(agent)), uint8(IAgentRegistry.CreditLevel.L0));

        // Oracle upgrades KYA to Enhanced (2)
        vm.prank(oracle);
        registry.updateKya(agent, 2);
        // Now L4: score 750 + KYA 2
        assertEq(uint8(registry.getCreditLevel(agent)), uint8(IAgentRegistry.CreditLevel.L4));
    }

    function test_updateCreditScore_levelCanGoDown() public {
        // Set up L4 agent
        vm.startPrank(oracle);
        registry.updateCreditScore(agent, 750);
        registry.updateKya(agent, 2);
        vm.stopPrank();
        assertEq(uint8(registry.getCreditLevel(agent)), uint8(IAgentRegistry.CreditLevel.L4));

        // Drop score below L4 threshold
        vm.prank(oracle);
        registry.updateCreditScore(agent, 600);
        // L3: score 600 < 650 → drops to... actually 600 < 650 so not L3, it's L2 with KYA 2? No:
        // L3 requires >= 650. 600 >= 500 and KYA >= 1 → L2
        assertEq(uint8(registry.getCreditLevel(agent)), uint8(IAgentRegistry.CreditLevel.L2));
    }

    function test_updateCreditScore_onlyOracle() public {
        vm.prank(agent);
        vm.expectRevert(Errors.OnlyOracle.selector);
        registry.updateCreditScore(agent, 750);
    }

    function test_updateCreditScore_rangeValidation() public {
        // Below minimum (200)
        vm.prank(oracle);
        vm.expectRevert(Errors.CreditScoreOutOfRange.selector);
        registry.updateCreditScore(agent, 199);

        // Above maximum (850)
        vm.prank(oracle);
        vm.expectRevert(Errors.CreditScoreOutOfRange.selector);
        registry.updateCreditScore(agent, 851);
    }

    function test_updateKya_onlyAdminOrOracle() public {
        vm.prank(agent);
        vm.expectRevert(Errors.OnlyAdminOrOracle.selector);
        registry.updateKya(agent, 1);
    }

    function test_updateKya_invalidTier() public {
        vm.prank(oracle);
        vm.expectRevert(Errors.InvalidKyaTier.selector);
        registry.updateKya(agent, 4);
    }

    // ════════════════════════════════════════════════════════════════
    // Liquidation
    // ════════════════════════════════════════════════════════════════

    function test_recordLiquidation_penaltyAndLevelDrop() public {
        // Set up L4 agent: score 750, KYA 2
        vm.startPrank(oracle);
        registry.updateCreditScore(agent, 750);
        registry.updateKya(agent, 2);
        vm.stopPrank();

        // Admin records liquidation (simulating wallet program callback)
        vm.prank(admin);
        registry.recordLiquidation(agent);

        IAgentRegistry.Agent memory a = registry.getAgent(agent);
        assertEq(a.creditScore, 710); // 750 - 40
        assertEq(a.liquidationCount, 1);
        // 710 >= 650 && KYA 2 → L3
        assertEq(uint8(a.creditLevel), uint8(IAgentRegistry.CreditLevel.L3));
    }

    function test_recordLiquidation_floorAt200() public {
        // Set score to 220 (near floor)
        vm.prank(oracle);
        registry.updateCreditScore(agent, 220);

        // Liquidation penalty (-40) should floor at 200
        vm.prank(admin);
        registry.recordLiquidation(agent);

        assertEq(registry.getAgent(agent).creditScore, 200);
    }

    // ════════════════════════════════════════════════════════════════
    // Score Validity & Agent Eligibility
    // ════════════════════════════════════════════════════════════════

    function test_isCreditValid_expiresAfter30Days() public {
        vm.prank(oracle);
        registry.updateCreditScore(agent, 500);
        assertTrue(registry.isCreditValid(agent));

        // Warp past 30-day expiry
        vm.warp(block.timestamp + 30 days + 1);
        assertFalse(registry.isCreditValid(agent));
    }

    function test_isAgentEligible() public {
        // Set up L2 agent
        vm.startPrank(oracle);
        registry.updateCreditScore(agent, 500);
        registry.updateKya(agent, 1);
        vm.stopPrank();

        // Eligible for L1 and L2
        assertTrue(registry.isAgentEligible(agent, IAgentRegistry.CreditLevel.L1));
        assertTrue(registry.isAgentEligible(agent, IAgentRegistry.CreditLevel.L2));
        // Not eligible for L3
        assertFalse(registry.isAgentEligible(agent, IAgentRegistry.CreditLevel.L3));
    }

    function test_isAgentEligible_expiredScore() public {
        vm.startPrank(oracle);
        registry.updateCreditScore(agent, 750);
        registry.updateKya(agent, 2);
        vm.stopPrank();

        assertTrue(registry.isAgentEligible(agent, IAgentRegistry.CreditLevel.L4));

        // Warp past expiry
        vm.warp(block.timestamp + 30 days + 1);
        assertFalse(registry.isAgentEligible(agent, IAgentRegistry.CreditLevel.L1));
    }

    // ════════════════════════════════════════════════════════════════
    // Vault Creation Gating (L0 blocked)
    // ════════════════════════════════════════════════════════════════

    function test_L0_blockedFromVaultCreation() public {
        // Agent has default score 350, KYA 0 → L0
        // First need a valid credit score update so isCreditValid passes
        vm.prank(oracle);
        registry.updateCreditScore(agent, 350);

        vm.prank(admin);
        vm.expectRevert(Errors.CreditTierTooLow.selector);
        factory.createVault(agent, 50_000e6, 1200, 180 days, 4, 1500, 0, 0, 0, 0, type(uint256).max);
    }

    function test_expiredScore_blockedFromVaultCreation() public {
        vm.startPrank(oracle);
        registry.updateCreditScore(agent, 750);
        registry.updateKya(agent, 2);
        vm.stopPrank();

        // Warp past 30-day expiry
        vm.warp(block.timestamp + 30 days + 1);

        vm.prank(admin);
        vm.expectRevert(Errors.CreditScoreExpired.selector);
        factory.createVault(agent, 50_000e6, 1200, 180 days, 4, 1500, 0, 0, 0, 0, type(uint256).max);
    }
}
