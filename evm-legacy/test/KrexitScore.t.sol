// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {KrexitScore} from "../src/KrexitScore.sol";
import {IKrexitScore} from "../src/interfaces/IKrexitScore.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {IAgentRegistry} from "../src/interfaces/IAgentRegistry.sol";
import {Errors} from "../src/libraries/Errors.sol";

contract KrexitScoreTest is Test {
    KrexitScore public scorer;
    AgentRegistry public registry;

    address admin = makeAddr("admin");
    address oracle = makeAddr("oracle");
    address agent1 = makeAddr("agent1");
    address agent2 = makeAddr("agent2");
    address agent3 = makeAddr("agent3");

    function setUp() public {
        registry = new AgentRegistry(admin, oracle);
        scorer = new KrexitScore(admin, oracle, address(registry));

        // Set scorer as oracle on registry so updateCreditScore calls succeed
        vm.prank(admin);
        registry.setOracle(address(scorer));

        // Register agents
        vm.prank(agent1);
        registry.registerAgent("ipfs://agent1");
        vm.prank(agent2);
        registry.registerAgent("ipfs://agent2");
        vm.prank(agent3);
        registry.registerAgent("ipfs://agent3");
    }

    // ═══════════════════════════════════════════════════════════════
    // Constructor
    // ═══════════════════════════════════════════════════════════════

    function test_constructor() public view {
        assertEq(scorer.admin(), admin);
        assertEq(scorer.oracle(), oracle);
        assertEq(scorer.registryAddr(), address(registry));
        assertFalse(scorer.isPaused());
    }

    function test_constructor_zeroAddress() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new KrexitScore(address(0), oracle, address(registry));

        vm.expectRevert(Errors.ZeroAddress.selector);
        new KrexitScore(admin, address(0), address(registry));

        vm.expectRevert(Errors.ZeroAddress.selector);
        new KrexitScore(admin, oracle, address(0));
    }

    function test_defaultInterestRates() public view {
        IKrexitScore.InterestRate memory r1 = scorer.getInterestRate(1);
        assertEq(r1.aprBps, 3650);
        assertEq(r1.dailyBps, 10);

        IKrexitScore.InterestRate memory r2 = scorer.getInterestRate(2);
        assertEq(r2.aprBps, 2920);
        assertEq(r2.dailyBps, 8);

        IKrexitScore.InterestRate memory r3 = scorer.getInterestRate(3);
        assertEq(r3.aprBps, 2555);
        assertEq(r3.dailyBps, 7);

        IKrexitScore.InterestRate memory r4 = scorer.getInterestRate(4);
        assertEq(r4.aprBps, 2190);
        assertEq(r4.dailyBps, 6);
    }

    // ═══════════════════════════════════════════════════════════════
    // updateScore
    // ═══════════════════════════════════════════════════════════════

    function test_updateScore_basic() public {
        vm.prank(oracle);
        scorer.updateScore(agent1, 650, 3, 600, 50, bytes32(uint256(0xdead)), 0);

        IKrexitScore.ScoreData memory s = scorer.getScore(agent1);
        assertEq(s.score, 650);
        assertEq(s.level, 3);
        assertEq(s.fairscaleBase, 600);
        assertEq(s.modifierTotal, 50);
        assertEq(s.attestationHash, bytes32(uint256(0xdead)));
        assertEq(s.lastEventType, 0);
        assertTrue(s.lastUpdated > 0);
    }

    function test_updateScore_syncsToRegistry() public {
        vm.prank(oracle);
        scorer.updateScore(agent1, 750, 4, 700, 50, bytes32(0), 0);

        // Registry should have the updated score
        IAgentRegistry.Agent memory a = registry.getAgent(agent1);
        assertEq(a.creditScore, 750);
    }

    function test_updateScore_setsRegisteredAt() public {
        vm.prank(oracle);
        scorer.updateScore(agent1, 500, 2, 450, 50, bytes32(0), 0);

        IKrexitScore.ScoreData memory s = scorer.getScore(agent1);
        assertTrue(s.registeredAt > 0);
    }

    function test_updateScore_onlyOracle() public {
        vm.prank(admin);
        vm.expectRevert(Errors.OnlyOracle.selector);
        scorer.updateScore(agent1, 500, 2, 450, 50, bytes32(0), 0);
    }

    function test_updateScore_scoreTooLow() public {
        vm.prank(oracle);
        vm.expectRevert(Errors.CreditScoreOutOfRange.selector);
        scorer.updateScore(agent1, 199, 1, 199, 0, bytes32(0), 0);
    }

    function test_updateScore_scoreTooHigh() public {
        vm.prank(oracle);
        vm.expectRevert(Errors.CreditScoreOutOfRange.selector);
        scorer.updateScore(agent1, 851, 4, 851, 0, bytes32(0), 0);
    }

    function test_updateScore_levelTooHigh() public {
        vm.prank(oracle);
        vm.expectRevert(Errors.InvalidAmount.selector);
        scorer.updateScore(agent1, 500, 5, 450, 50, bytes32(0), 0);
    }

    function test_updateScore_zeroAgent() public {
        vm.prank(oracle);
        vm.expectRevert(Errors.ZeroAddress.selector);
        scorer.updateScore(address(0), 500, 2, 450, 50, bytes32(0), 0);
    }

    function test_updateScore_emitsEvent() public {
        vm.prank(oracle);
        vm.expectEmit(true, false, false, true);
        emit IKrexitScore.ScoreUpdated(agent1, 0, 650, 3, 0, 50);
        scorer.updateScore(agent1, 650, 3, 600, 50, bytes32(0), 0);
    }

    function test_updateScore_overwrite() public {
        vm.startPrank(oracle);
        scorer.updateScore(agent1, 500, 2, 450, 50, bytes32(0), 0);
        scorer.updateScore(agent1, 700, 3, 650, 50, bytes32(uint256(1)), 7);
        vm.stopPrank();

        IKrexitScore.ScoreData memory s = scorer.getScore(agent1);
        assertEq(s.score, 700);
        assertEq(s.level, 3);
        assertEq(s.lastEventType, 7);
    }

    // ═══════════════════════════════════════════════════════════════
    // batchUpdateScores
    // ═══════════════════════════════════════════════════════════════

    function test_batchUpdateScores() public {
        address[] memory agents = new address[](2);
        agents[0] = agent1;
        agents[1] = agent2;

        uint16[] memory scores = new uint16[](2);
        scores[0] = 600;
        scores[1] = 750;

        uint8[] memory levels = new uint8[](2);
        levels[0] = 2;
        levels[1] = 4;

        uint16[] memory bases = new uint16[](2);
        bases[0] = 550;
        bases[1] = 700;

        int16[] memory mods = new int16[](2);
        mods[0] = 50;
        mods[1] = 50;

        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = bytes32(uint256(0xaa));
        hashes[1] = bytes32(uint256(0xbb));

        vm.prank(oracle);
        scorer.batchUpdateScores(agents, scores, levels, bases, mods, hashes, 0);

        assertEq(scorer.getScoreValue(agent1), 600);
        assertEq(scorer.getScoreValue(agent2), 750);
        assertEq(scorer.getLevel(agent1), 2);
        assertEq(scorer.getLevel(agent2), 4);
    }

    function test_batchUpdateScores_mismatchedArrays() public {
        address[] memory agents = new address[](2);
        agents[0] = agent1;
        agents[1] = agent2;

        uint16[] memory scores = new uint16[](1); // wrong length
        scores[0] = 500;

        uint8[] memory levels = new uint8[](2);
        uint16[] memory bases = new uint16[](2);
        int16[] memory mods = new int16[](2);
        bytes32[] memory hashes = new bytes32[](2);

        vm.prank(oracle);
        vm.expectRevert(Errors.InvalidAmount.selector);
        scorer.batchUpdateScores(agents, scores, levels, bases, mods, hashes, 0);
    }

    function test_batchUpdateScores_skipsInvalid() public {
        address[] memory agents = new address[](2);
        agents[0] = address(0); // invalid — should skip
        agents[1] = agent2;

        uint16[] memory scores = new uint16[](2);
        scores[0] = 500;
        scores[1] = 600;

        uint8[] memory levels = new uint8[](2);
        levels[0] = 2;
        levels[1] = 2;

        uint16[] memory bases = new uint16[](2);
        int16[] memory mods = new int16[](2);
        bytes32[] memory hashes = new bytes32[](2);

        vm.prank(oracle);
        scorer.batchUpdateScores(agents, scores, levels, bases, mods, hashes, 0);

        // agent2 updated, agent(0) skipped
        assertEq(scorer.getScoreValue(agent2), 600);
    }

    // ═══════════════════════════════════════════════════════════════
    // recordRepayment
    // ═══════════════════════════════════════════════════════════════

    function test_recordRepayment_onTime() public {
        // First set a base score
        vm.prank(oracle);
        scorer.updateScore(agent1, 500, 2, 450, 50, bytes32(0), 0);

        vm.prank(oracle);
        scorer.recordRepayment(agent1, IKrexitScore.RepaymentType.OnTime, 1_000e6);

        IKrexitScore.ScoreData memory s = scorer.getScore(agent1);
        assertEq(s.onTimeCount, 1);
        // Score should reflect the modifier: base 450 + mod(1 on-time = +8) = 458
        // Plus any age/cycle/volume mods
        assertTrue(s.score >= 450);
    }

    function test_recordRepayment_early() public {
        vm.prank(oracle);
        scorer.updateScore(agent1, 500, 2, 500, 0, bytes32(0), 0);

        vm.prank(oracle);
        scorer.recordRepayment(agent1, IKrexitScore.RepaymentType.Early, 500e6);

        assertEq(scorer.getScore(agent1).earlyCount, 1);
    }

    function test_recordRepayment_late() public {
        vm.prank(oracle);
        scorer.updateScore(agent1, 500, 2, 500, 0, bytes32(0), 0);

        vm.prank(oracle);
        scorer.recordRepayment(agent1, IKrexitScore.RepaymentType.Late, 500e6);

        assertEq(scorer.getScore(agent1).lateCount, 1);
        // -15 modifier, score should drop
        assertTrue(scorer.getScoreValue(agent1) < 500);
    }

    function test_recordRepayment_liquidation() public {
        vm.prank(oracle);
        scorer.updateScore(agent1, 500, 2, 500, 0, bytes32(0), 0);

        vm.prank(oracle);
        scorer.recordRepayment(agent1, IKrexitScore.RepaymentType.Liquidation, 500e6);

        assertEq(scorer.getScore(agent1).liquidationCount, 1);
        // -40 modifier
        assertTrue(scorer.getScoreValue(agent1) < 500);
    }

    function test_recordRepayment_default() public {
        vm.prank(oracle);
        scorer.updateScore(agent1, 600, 2, 600, 0, bytes32(0), 0);

        vm.prank(oracle);
        scorer.recordRepayment(agent1, IKrexitScore.RepaymentType.Default, 500e6);

        assertEq(scorer.getScore(agent1).defaultCount, 1);
        // -100 modifier → score floors at 200 if base + mod < 200
        assertEq(scorer.getScoreValue(agent1), 500); // 600 - 100 = 500
    }

    function test_recordRepayment_onlyAdminOrOracle() public {
        vm.prank(agent1);
        vm.expectRevert(Errors.OnlyAdminOrOracle.selector);
        scorer.recordRepayment(agent1, IKrexitScore.RepaymentType.OnTime, 100e6);
    }

    function test_recordRepayment_multipleEvents() public {
        vm.prank(oracle);
        scorer.updateScore(agent1, 500, 2, 500, 0, bytes32(0), 0);

        vm.startPrank(oracle);
        scorer.recordRepayment(agent1, IKrexitScore.RepaymentType.OnTime, 100e6);
        scorer.recordRepayment(agent1, IKrexitScore.RepaymentType.OnTime, 100e6);
        scorer.recordRepayment(agent1, IKrexitScore.RepaymentType.Early, 100e6);
        scorer.recordRepayment(agent1, IKrexitScore.RepaymentType.Late, 100e6);
        vm.stopPrank();

        IKrexitScore.ScoreData memory s = scorer.getScore(agent1);
        assertEq(s.onTimeCount, 2);
        assertEq(s.earlyCount, 1);
        assertEq(s.lateCount, 1);
        // Net modifier: 2*8 + 1*10 + 1*(-15) = 11
        // Score = 500 + 11 = 511
        assertEq(s.score, 511);
    }

    // ═══════════════════════════════════════════════════════════════
    // computeModifiers
    // ═══════════════════════════════════════════════════════════════

    function test_computeModifiers_repaymentOnly() public {
        vm.prank(oracle);
        scorer.updateScore(agent1, 500, 2, 500, 0, bytes32(0), 0);

        vm.startPrank(oracle);
        scorer.recordRepayment(agent1, IKrexitScore.RepaymentType.OnTime, 100e6);
        scorer.recordRepayment(agent1, IKrexitScore.RepaymentType.OnTime, 100e6);
        vm.stopPrank();

        // 2 * 8 = 16 (no age/cycle/volume mods since registeredAt is current block)
        int16 mod = scorer.computeModifiers(agent1);
        assertEq(mod, 16);
    }

    function test_computeModifiers_ageBonus() public {
        vm.prank(oracle);
        scorer.updateScore(agent1, 500, 2, 500, 0, bytes32(0), 0);

        // Warp 3 months
        vm.warp(block.timestamp + 90 days);

        int16 mod = scorer.computeModifiers(agent1);
        // 3 months * 5 = 15
        assertEq(mod, 15);
    }

    function test_computeModifiers_ageCap() public {
        vm.prank(oracle);
        scorer.updateScore(agent1, 500, 2, 500, 0, bytes32(0), 0);

        // Warp 2 years (24 months)
        vm.warp(block.timestamp + 730 days);

        int16 mod = scorer.computeModifiers(agent1);
        // Cap at +60, not 24*5=120
        assertEq(mod, 60);
    }

    function test_computeModifiers_scoreFloors() public {
        vm.prank(oracle);
        scorer.updateScore(agent1, 300, 1, 300, 0, bytes32(0), 0);

        // Record 5 defaults = -500 modifier
        vm.startPrank(oracle);
        for (uint i = 0; i < 5; i++) {
            scorer.recordRepayment(agent1, IKrexitScore.RepaymentType.Default, 100e6);
        }
        vm.stopPrank();

        // Score should floor at 200
        assertEq(scorer.getScoreValue(agent1), 200);
    }

    // ═══════════════════════════════════════════════════════════════
    // Score Expiry
    // ═══════════════════════════════════════════════════════════════

    function test_isScoreExpired_noScore() public view {
        assertTrue(scorer.isScoreExpired(agent1));
    }

    function test_isScoreExpired_fresh() public {
        vm.prank(oracle);
        scorer.updateScore(agent1, 500, 2, 450, 50, bytes32(0), 0);

        assertFalse(scorer.isScoreExpired(agent1));
    }

    function test_isScoreExpired_after30Days() public {
        vm.prank(oracle);
        scorer.updateScore(agent1, 500, 2, 450, 50, bytes32(0), 0);

        vm.warp(block.timestamp + 30 days + 1);
        assertTrue(scorer.isScoreExpired(agent1));
    }

    // ═══════════════════════════════════════════════════════════════
    // Admin Functions
    // ═══════════════════════════════════════════════════════════════

    function test_setInterestRate() public {
        vm.prank(admin);
        scorer.setInterestRate(1, 4000, 11);

        IKrexitScore.InterestRate memory r = scorer.getInterestRate(1);
        assertEq(r.aprBps, 4000);
        assertEq(r.dailyBps, 11);
    }

    function test_setInterestRate_invalidLevel() public {
        vm.prank(admin);
        vm.expectRevert(Errors.InvalidAmount.selector);
        scorer.setInterestRate(0, 1000, 3);

        vm.prank(admin);
        vm.expectRevert(Errors.InvalidAmount.selector);
        scorer.setInterestRate(5, 1000, 3);
    }

    function test_setInterestRate_tooHigh() public {
        vm.prank(admin);
        vm.expectRevert(Errors.FeeTooHigh.selector);
        scorer.setInterestRate(1, 10_001, 28);
    }

    function test_setOracle() public {
        address newOracle = makeAddr("newOracle");
        vm.prank(admin);
        scorer.setOracle(newOracle);
        assertEq(scorer.oracle(), newOracle);
    }

    function test_setRegistry() public {
        address newRegistry = makeAddr("newRegistry");
        vm.prank(admin);
        scorer.setRegistry(newRegistry);
        assertEq(scorer.registryAddr(), newRegistry);
    }

    function test_adminTransfer() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        scorer.proposeAdmin(newAdmin);
        assertEq(scorer.pendingAdmin(), newAdmin);

        vm.prank(newAdmin);
        scorer.acceptAdmin();
        assertEq(scorer.admin(), newAdmin);
        assertEq(scorer.pendingAdmin(), address(0));
    }

    function test_adminTransfer_onlyPending() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        scorer.proposeAdmin(newAdmin);

        vm.prank(agent1);
        vm.expectRevert(Errors.Unauthorized.selector);
        scorer.acceptAdmin();
    }

    // ═══════════════════════════════════════════════════════════════
    // Pause
    // ═══════════════════════════════════════════════════════════════

    function test_pause_blocksUpdates() public {
        vm.prank(admin);
        scorer.pause();

        vm.prank(oracle);
        vm.expectRevert(Errors.PlatformPaused.selector);
        scorer.updateScore(agent1, 500, 2, 450, 50, bytes32(0), 0);
    }

    function test_unpause_resumesUpdates() public {
        vm.prank(admin);
        scorer.pause();

        vm.prank(admin);
        scorer.unpause();

        vm.prank(oracle);
        scorer.updateScore(agent1, 500, 2, 450, 50, bytes32(0), 0);
        assertEq(scorer.getScoreValue(agent1), 500);
    }

    function test_pause_onlyAdmin() public {
        vm.prank(oracle);
        vm.expectRevert(Errors.Unauthorized.selector);
        scorer.pause();
    }

    // ═══════════════════════════════════════════════════════════════
    // View Helpers
    // ═══════════════════════════════════════════════════════════════

    function test_getAprBps() public view {
        assertEq(scorer.getAprBps(1), 3650);
        assertEq(scorer.getAprBps(2), 2920);
        assertEq(scorer.getAprBps(3), 2555);
        assertEq(scorer.getAprBps(4), 2190);
        assertEq(scorer.getAprBps(0), 0); // L0 has no rate
    }

    // ═══════════════════════════════════════════════════════════════
    // Score Event Types
    // ═══════════════════════════════════════════════════════════════

    function test_scoreEventType_liquidation() public {
        vm.prank(oracle);
        scorer.updateScore(agent1, 500, 2, 500, 0, bytes32(0), 5); // 5 = Liquidation
        assertEq(scorer.getScore(agent1).lastEventType, 5);
    }

    function test_scoreEventType_dailyUpdate() public {
        vm.prank(oracle);
        scorer.updateScore(agent1, 500, 2, 500, 0, bytes32(0), 0); // 0 = DailyUpdate
        assertEq(scorer.getScore(agent1).lastEventType, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    // Attestation
    // ═══════════════════════════════════════════════════════════════

    function test_attestationHash_stored() public {
        bytes32 hash = keccak256("fairscale-payload-12345");
        vm.prank(oracle);
        scorer.updateScore(agent1, 700, 3, 650, 50, hash, 7);

        assertEq(scorer.getScore(agent1).attestationHash, hash);
    }

    function test_attestationHash_emitsEvent() public {
        bytes32 hash = keccak256("fairscale-payload");
        vm.prank(oracle);
        vm.expectEmit(true, false, false, true);
        emit IKrexitScore.AttestationStored(agent1, hash, block.timestamp);
        scorer.updateScore(agent1, 700, 3, 650, 50, hash, 7);
    }
}
