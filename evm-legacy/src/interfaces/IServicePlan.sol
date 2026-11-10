// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IServicePlan {
    // ── Enums ──

    enum ServiceHealth { Green, Yellow, Orange, Red }
    enum WindDownState { None, Grace, Executing, Completed }

    // ── Structs ──

    struct MilestoneData {
        uint256 amount;
        bytes32 descriptionHash;
        uint256 eligibleAt;
        bool disbursed;
        uint256 disbursedAt;
        bool isActive;
    }

    struct Plan {
        address agentWallet;
        address owner;
        uint256 totalCredit;
        uint256 totalDisbursed;
        uint256 projectedMonthlyRevenue;
        uint256 actualRevenueThisPeriod;
        uint256 periodStart;
        ServiceHealth health;
        uint256 lastRevenueAt;
        uint8 zeroRevenueDays;
        WindDownState windDownState;
        uint256 windDownStartedAt;
        uint8 expenseDestCount;
        uint8 milestoneCount;
        uint256 createdAt;
    }

    struct ExpenseDestination {
        address destination;
        bytes32 labelHash;
        uint8 category; // 0=infrastructure, 1=api, 2=marketing, 3=payroll, 4=other
        uint256 maxAmount;
        uint256 totalSent;
        bool isActive;
        uint256 approvedAt;
    }

    struct MilestoneInput {
        uint256 amount;
        bytes32 descriptionHash;
        uint256 eligibleAt;
    }

    // ── Events ──

    event PlanCreated(address indexed agentWallet, address indexed owner, uint256 totalCredit, uint8 milestoneCount);
    event MilestoneDisbursed(address indexed agentWallet, uint8 milestoneIndex, uint256 amount);
    event ExpenseDestAdded(address indexed agentWallet, address indexed destination, uint8 category);
    event ExpenseDestRemoved(address indexed agentWallet, address indexed destination);
    event ExpenseExecuted(address indexed agentWallet, address indexed destination, uint256 amount);
    event RevenueRecorded(address indexed agentWallet, uint256 amount, uint256 newTotal, ServiceHealth health);
    event HealthUpdated(address indexed agentWallet, ServiceHealth oldHealth, ServiceHealth newHealth);
    event WindDownStarted(address indexed agentWallet, uint256 graceEndsAt);
    event WindDownAdvanced(address indexed agentWallet, WindDownState newState);
    event ProjectedRevenueSet(address indexed agentWallet, uint256 projected);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    // ── Functions ──

    function createPlan(
        address agentWallet,
        uint256 totalCredit,
        MilestoneInput[] calldata milestones
    ) external;
    function disburseMilestone(address agentWallet, uint8 milestoneIndex) external;
    function addExpenseDestination(
        address agentWallet,
        address destination,
        bytes32 labelHash,
        uint8 category,
        uint256 maxAmount
    ) external;
    function removeExpenseDestination(address agentWallet, address destination) external;
    function executeExpense(address agentWallet, address destination, uint256 amount) external;
    function recordRevenue(address agentWallet, uint256 amount) external;
    function updateZeroRevenueDays(address agentWallet, uint8 days_) external;
    function setProjectedRevenue(address agentWallet, uint256 projected) external;
    function startWindDown(address agentWallet) external;
    function advanceWindDown(address agentWallet) external;
    function fundPlan(address agentWallet, uint256 amount) external;

    // ── Views ──

    function getPlan(address agentWallet) external view returns (Plan memory);
    function getMilestone(address agentWallet, uint8 index) external view returns (MilestoneData memory);
    function getExpenseDestination(address agentWallet, address destination) external view returns (ExpenseDestination memory);
    function computeHealth(uint256 actual, uint256 projected, uint8 zeroDays) external pure returns (ServiceHealth);
}
