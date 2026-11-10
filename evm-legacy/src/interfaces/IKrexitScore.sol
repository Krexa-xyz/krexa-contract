// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IKrexitScore — On-chain scoring engine (Solana krexit-score parity)
/// @notice Stores agent credit scores (200-850), FairScale base + on-chain modifiers,
///         repayment event tracking, attestation hashes, and interest rates per level.
interface IKrexitScore {
    // ─── Enums ───────────────────────────────────────────────────────

    /// Repayment event types (match oracle/scoring/types.ts)
    enum RepaymentType { OnTime, Early, Late, Missed, Liquidation, Default }

    /// Score update trigger type
    enum ScoreEventType {
        DailyUpdate,      // 0 — routine daily oracle sweep
        CreditOrigination,// 1 — new credit line opened
        RepaymentOnTime,  // 2
        RepaymentEarly,   // 3
        RepaymentLate,    // 4
        Liquidation,      // 5
        ManualOverride,   // 6 — admin correction
        FairScaleRefresh, // 7 — explicit FairScale re-pull
        CreditClosed,     // 8
        VolumeThreshold,  // 9 — lifetime volume milestone
        KyaUpgrade,       // 10
        KyaDowngrade,     // 11
        Winddown          // 12
    }

    // ─── Structs ─────────────────────────────────────────────────────

    struct ScoreData {
        uint16 score;             // 200-850 final Krexit Score
        uint8 level;              // 1-4 credit level
        uint16 fairscaleBase;     // FairScale-derived base (200-850)
        int16 modifierTotal;      // sum of on-chain modifiers (can be negative)
        bytes32 attestationHash;  // FairScale payload_hash for audit trail
        uint256 lastUpdated;      // timestamp of last oracle update
        uint8 lastEventType;      // ScoreEventType of last update
        // Repayment tracking
        uint16 onTimeCount;
        uint16 earlyCount;
        uint16 lateCount;
        uint16 missedCount;
        uint8 liquidationCount;
        uint8 defaultCount;
        // Behavior tracking
        uint16 creditCyclesCompleted;
        uint256 lifetimeVolumeUsd;  // 6 decimals
        uint256 registeredAt;       // copied from registry on first score write
    }

    struct InterestRate {
        uint16 aprBps;    // annual percentage rate in BPS
        uint16 dailyBps;  // daily rate in BPS (aprBps / 365, pre-computed)
    }

    // ─── Events ──────────────────────────────────────────────────────

    event ScoreUpdated(
        address indexed agent,
        uint16 oldScore,
        uint16 newScore,
        uint8 level,
        uint8 eventType,
        int16 modifierTotal
    );

    event RepaymentRecorded(
        address indexed agent,
        RepaymentType repaymentType,
        uint256 amount,
        uint16 newScore
    );

    event AttestationStored(
        address indexed agent,
        bytes32 attestationHash,
        uint256 timestamp
    );

    event InterestRateUpdated(uint8 level, uint16 aprBps, uint16 dailyBps);
    event RegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event AdminTransferProposed(address indexed current, address indexed proposed);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    // ─── Oracle Functions ────────────────────────────────────────────

    function updateScore(
        address agent,
        uint16 score,
        uint8 level,
        uint16 fairscaleBase,
        int16 modifierTotal,
        bytes32 attestationHash,
        uint8 eventType
    ) external;

    function recordRepayment(
        address agent,
        RepaymentType repaymentType,
        uint256 amount
    ) external;

    function batchUpdateScores(
        address[] calldata agents,
        uint16[] calldata scores,
        uint8[] calldata levels,
        uint16[] calldata fairscaleBases,
        int16[] calldata modifierTotals,
        bytes32[] calldata attestationHashes,
        uint8 eventType
    ) external;

    // ─── Admin Functions ─────────────────────────────────────────────

    function setInterestRate(uint8 level, uint16 aprBps, uint16 dailyBps) external;
    function setOracle(address newOracle) external;
    function setRegistry(address newRegistry) external;
    function proposeAdmin(address newAdmin) external;
    function acceptAdmin() external;
    function pause() external;
    function unpause() external;

    // ─── View Functions ──────────────────────────────────────────────

    function getScore(address agent) external view returns (ScoreData memory);
    function getScoreValue(address agent) external view returns (uint16);
    function getLevel(address agent) external view returns (uint8);
    function getInterestRate(uint8 level) external view returns (InterestRate memory);
    function getAprBps(uint8 level) external view returns (uint16);
    function isScoreExpired(address agent) external view returns (bool);
    function computeModifiers(address agent) external view returns (int16);
}
