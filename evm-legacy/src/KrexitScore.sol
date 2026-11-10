// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IKrexitScore} from "./interfaces/IKrexitScore.sol";
import {IAgentRegistry} from "./interfaces/IAgentRegistry.sol";
import {Errors} from "./libraries/Errors.sol";

/// @title KrexitScore — On-chain scoring engine (Solana krexit-score parity)
/// @notice Stores credit scores (200-850) computed by the oracle from
///         FairScale base (0-100 → 200-850) + flat on-chain modifiers.
///         Matches oracle/scoring/engine.ts exactly.
contract KrexitScore is IKrexitScore {
    // ─── Constants (match oracle/scoring/engine.ts) ────────────────────

    uint16 public constant SCORE_MIN = 200;
    uint16 public constant SCORE_MAX = 850;
    uint16 public constant DEFAULT_BASE = 400;
    uint256 public constant SCORE_EXPIRY_SECONDS = 30 days;

    // On-chain modifier point values (flat, match engine.ts)
    int16 public constant MOD_ON_TIME = 8;
    int16 public constant MOD_EARLY = 10;
    int16 public constant MOD_LATE = -15;
    int16 public constant MOD_MISSED = -30;
    int16 public constant MOD_LIQUIDATION = -40;
    int16 public constant MOD_DEFAULT = -100;

    // Behavior modifiers
    int16 public constant MOD_AGE_PER_MONTH = 5;     // +5/month, cap +60
    int16 public constant MOD_AGE_CAP = 60;
    int16 public constant MOD_CYCLE_PER = 3;          // +3/cycle, cap +30
    int16 public constant MOD_CYCLE_CAP = 30;
    int16 public constant MOD_VOLUME_PER_10K = 2;     // +2 per $10K, cap +20
    int16 public constant MOD_VOLUME_CAP = 20;

    // ─── Storage ───────────────────────────────────────────────────────

    mapping(address => ScoreData) private _scores;
    mapping(uint8 => InterestRate) private _interestRates;

    address public admin;
    address public pendingAdmin;
    address public oracle;
    address public registryAddr;
    bool public isPaused;

    // ─── Modifiers ─────────────────────────────────────────────────────

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Errors.Unauthorized();
        _;
    }

    modifier onlyOracle() {
        if (msg.sender != oracle) revert Errors.OnlyOracle();
        _;
    }

    modifier onlyAdminOrOracle() {
        if (msg.sender != admin && msg.sender != oracle) revert Errors.OnlyAdminOrOracle();
        _;
    }

    modifier whenNotPaused() {
        if (isPaused) revert Errors.PlatformPaused();
        _;
    }

    // ─── Constructor ───────────────────────────────────────────────────

    constructor(address _admin, address _oracle, address _registry) {
        if (_admin == address(0) || _oracle == address(0) || _registry == address(0)) {
            revert Errors.ZeroAddress();
        }
        admin = _admin;
        oracle = _oracle;
        registryAddr = _registry;

        // Default interest rates (match docs/krexit-score-system.md)
        // L1: 36.50% APR → 10bps/day
        // L2: 29.20% APR → 8bps/day
        // L3: 25.55% APR → 7bps/day
        // L4: 21.90% APR → 6bps/day
        _interestRates[1] = InterestRate(3650, 10);
        _interestRates[2] = InterestRate(2920, 8);
        _interestRates[3] = InterestRate(2555, 7);
        _interestRates[4] = InterestRate(2190, 6);
    }

    // ═══════════════════════════════════════════════════════════════════
    // ORACLE: Score Updates
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Oracle writes a computed score for an agent.
    ///         Score = clamp(fairscaleBase + modifierTotal, 200, 850).
    function updateScore(
        address agent,
        uint16 score,
        uint8 level,
        uint16 fairscaleBase,
        int16 modifierTotal,
        bytes32 attestationHash,
        uint8 eventType
    ) external onlyOracle whenNotPaused {
        if (agent == address(0)) revert Errors.ZeroAddress();
        if (score < SCORE_MIN || score > SCORE_MAX) revert Errors.CreditScoreOutOfRange();
        if (level > 4) revert Errors.InvalidAmount();

        ScoreData storage s = _scores[agent];
        uint16 oldScore = s.score;

        s.score = score;
        s.level = level;
        s.fairscaleBase = fairscaleBase;
        s.modifierTotal = modifierTotal;
        s.lastUpdated = block.timestamp;
        s.lastEventType = eventType;

        if (attestationHash != bytes32(0)) {
            s.attestationHash = attestationHash;
            emit AttestationStored(agent, attestationHash, block.timestamp);
        }

        // Set registeredAt on first write (from registry)
        if (s.registeredAt == 0) {
            try IAgentRegistry(registryAddr).getAgent(agent) returns (IAgentRegistry.Agent memory a) {
                s.registeredAt = a.registeredAt;
            } catch {}
        }

        // Sync score to AgentRegistry
        try IAgentRegistry(registryAddr).updateCreditScore(agent, score) {} catch {}

        emit ScoreUpdated(agent, oldScore, score, level, eventType, modifierTotal);
    }

    /// @notice Batch update scores — gas-efficient daily oracle sweep.
    function batchUpdateScores(
        address[] calldata agents,
        uint16[] calldata scores,
        uint8[] calldata levels,
        uint16[] calldata fairscaleBases,
        int16[] calldata modifierTotals,
        bytes32[] calldata attestationHashes,
        uint8 eventType
    ) external onlyOracle whenNotPaused {
        uint256 len = agents.length;
        if (
            len != scores.length || len != levels.length ||
            len != fairscaleBases.length || len != modifierTotals.length ||
            len != attestationHashes.length
        ) revert Errors.InvalidAmount();

        for (uint256 i = 0; i < len; i++) {
            address agent = agents[i];
            if (agent == address(0)) continue;
            if (scores[i] < SCORE_MIN || scores[i] > SCORE_MAX) continue;

            ScoreData storage s = _scores[agent];
            uint16 oldScore = s.score;

            s.score = scores[i];
            s.level = levels[i];
            s.fairscaleBase = fairscaleBases[i];
            s.modifierTotal = modifierTotals[i];
            s.lastUpdated = block.timestamp;
            s.lastEventType = eventType;

            if (attestationHashes[i] != bytes32(0)) {
                s.attestationHash = attestationHashes[i];
            }

            if (s.registeredAt == 0) {
                try IAgentRegistry(registryAddr).getAgent(agent) returns (IAgentRegistry.Agent memory a) {
                    s.registeredAt = a.registeredAt;
                } catch {}
            }

            try IAgentRegistry(registryAddr).updateCreditScore(agent, scores[i]) {} catch {}

            emit ScoreUpdated(agent, oldScore, scores[i], levels[i], eventType, modifierTotals[i]);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // ORACLE/ADMIN: Repayment Events
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Record a repayment event — updates counters and recalculates modifiers.
    function recordRepayment(
        address agent,
        RepaymentType repaymentType,
        uint256 amount
    ) external onlyAdminOrOracle whenNotPaused {
        if (agent == address(0)) revert Errors.ZeroAddress();

        ScoreData storage s = _scores[agent];

        if (repaymentType == RepaymentType.OnTime) s.onTimeCount += 1;
        else if (repaymentType == RepaymentType.Early) s.earlyCount += 1;
        else if (repaymentType == RepaymentType.Late) s.lateCount += 1;
        else if (repaymentType == RepaymentType.Missed) s.missedCount += 1;
        else if (repaymentType == RepaymentType.Liquidation) s.liquidationCount += 1;
        else if (repaymentType == RepaymentType.Default) s.defaultCount += 1;

        // Recompute on-chain modifiers
        int16 newMod = _computeModifiers(s);

        // Apply to score: clamp(fairscaleBase + modifiers, 200, 850)
        int256 raw = int256(uint256(s.fairscaleBase == 0 ? DEFAULT_BASE : s.fairscaleBase)) + int256(newMod);
        uint16 newScore;
        if (raw < int256(uint256(SCORE_MIN))) newScore = SCORE_MIN;
        else if (raw > int256(uint256(SCORE_MAX))) newScore = SCORE_MAX;
        else newScore = uint16(uint256(raw));

        s.modifierTotal = newMod;
        s.score = newScore;
        s.lastUpdated = block.timestamp;

        // Sync to registry
        try IAgentRegistry(registryAddr).updateCreditScore(agent, newScore) {} catch {}

        emit RepaymentRecorded(agent, repaymentType, amount, newScore);
    }

    // ═══════════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════════

    function setInterestRate(uint8 level, uint16 aprBps, uint16 dailyBps) external onlyAdmin {
        if (level == 0 || level > 4) revert Errors.InvalidAmount();
        if (aprBps > 10_000) revert Errors.FeeTooHigh(); // cap at 100% APR
        _interestRates[level] = InterestRate(aprBps, dailyBps);
        emit InterestRateUpdated(level, aprBps, dailyBps);
    }

    function setOracle(address newOracle) external onlyAdmin {
        if (newOracle == address(0)) revert Errors.ZeroAddress();
        address old = oracle;
        oracle = newOracle;
        emit OracleUpdated(old, newOracle);
    }

    function setRegistry(address newRegistry) external onlyAdmin {
        if (newRegistry == address(0)) revert Errors.ZeroAddress();
        address old = registryAddr;
        registryAddr = newRegistry;
        emit RegistryUpdated(old, newRegistry);
    }

    function proposeAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert Errors.ZeroAddress();
        pendingAdmin = newAdmin;
        emit AdminTransferProposed(admin, newAdmin);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert Errors.Unauthorized();
        address old = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferred(old, admin);
    }

    function pause() external onlyAdmin {
        isPaused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyAdmin {
        isPaused = false;
        emit Unpaused(msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════

    function getScore(address agent) external view returns (ScoreData memory) {
        return _scores[agent];
    }

    function getScoreValue(address agent) external view returns (uint16) {
        return _scores[agent].score;
    }

    function getLevel(address agent) external view returns (uint8) {
        return _scores[agent].level;
    }

    function getInterestRate(uint8 level) external view returns (InterestRate memory) {
        return _interestRates[level];
    }

    function getAprBps(uint8 level) external view returns (uint16) {
        return _interestRates[level].aprBps;
    }

    function isScoreExpired(address agent) external view returns (bool) {
        uint256 updated = _scores[agent].lastUpdated;
        if (updated == 0) return true;
        return block.timestamp > updated + SCORE_EXPIRY_SECONDS;
    }

    /// @notice Compute on-chain modifiers from stored repayment counters + behavior.
    ///         Matches oracle/scoring/engine.ts computeModifiers (simplified — no recency weighting on-chain).
    function computeModifiers(address agent) external view returns (int16) {
        return _computeModifiers(_scores[agent]);
    }

    // ═══════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════

    /// @notice On-chain modifier computation (flat points, no recency weighting).
    ///         Recency weighting is applied off-chain by the oracle; on-chain is the fallback.
    function _computeModifiers(ScoreData storage s) internal view returns (int16) {
        int256 mod = 0;

        // Repayment history (flat — recency is off-chain only)
        mod += int256(uint256(s.onTimeCount)) * int256(MOD_ON_TIME);
        mod += int256(uint256(s.earlyCount)) * int256(MOD_EARLY);
        mod += int256(uint256(s.lateCount)) * int256(MOD_LATE);
        mod += int256(uint256(s.missedCount)) * int256(MOD_MISSED);
        mod += int256(uint256(s.liquidationCount)) * int256(MOD_LIQUIDATION);
        mod += int256(uint256(s.defaultCount)) * int256(MOD_DEFAULT);

        // Account age: +5/month, cap +60
        if (s.registeredAt > 0 && block.timestamp > s.registeredAt) {
            uint256 ageMonths = (block.timestamp - s.registeredAt) / 30 days;
            int256 ageMod = int256(ageMonths) * int256(MOD_AGE_PER_MONTH);
            if (ageMod > int256(MOD_AGE_CAP)) ageMod = int256(MOD_AGE_CAP);
            mod += ageMod;
        }

        // Credit cycles: +3/cycle, cap +30
        int256 cycleMod = int256(uint256(s.creditCyclesCompleted)) * int256(MOD_CYCLE_PER);
        if (cycleMod > int256(MOD_CYCLE_CAP)) cycleMod = int256(MOD_CYCLE_CAP);
        mod += cycleMod;

        // Volume: +2 per $10K, cap +20
        int256 volMod = int256(s.lifetimeVolumeUsd / 10_000e6) * int256(MOD_VOLUME_PER_10K);
        if (volMod > int256(MOD_VOLUME_CAP)) volMod = int256(MOD_VOLUME_CAP);
        mod += volMod;

        // Clamp to int16 range
        if (mod > type(int16).max) return type(int16).max;
        if (mod < type(int16).min) return type(int16).min;
        return int16(mod);
    }
}
