// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IServicePlan} from "./interfaces/IServicePlan.sol";
import {Errors} from "./libraries/Errors.sol";

/// @title ServicePlan — Type B agent service plan lifecycle
/// @notice Solana parity: milestones, expense destinations, health zones, wind-down
contract ServicePlan is IServicePlan, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Constants (from krexa-common/constants.rs) ──────────────────

    uint8 public constant MAX_MILESTONES = 8;
    uint8 public constant MAX_EXPENSE_DESTINATIONS = 20;

    // Health zone thresholds (revenue ratio in BPS)
    uint16 public constant REVENUE_GREEN_BPS = 8_000;    // >= 80% → Green
    uint16 public constant REVENUE_YELLOW_BPS = 5_000;   // >= 50% → Yellow
    uint16 public constant REVENUE_ORANGE_BPS = 2_500;   // >= 25% → Orange
    // Below 25% → Red

    // Zero-revenue day overrides
    uint8 public constant ZERO_REVENUE_ORANGE_DAYS = 7;
    uint8 public constant ZERO_REVENUE_RED_DAYS = 14;

    // Wind-down grace period: 48 hours
    uint256 public constant WIND_DOWN_GRACE_SECONDS = 172_800;

    // Yellow zone milestone delay: 7 days
    uint256 public constant YELLOW_MILESTONE_DELAY_SECONDS = 604_800;

    uint16 public constant BPS_DENOMINATOR = 10_000;

    // ── State ───────────────────────────────────────────────────────

    IERC20 public immutable usdc;
    address public admin;
    address public oracle;
    bool public paused;
    uint256 public totalPlans;

    // agentWallet => Plan
    mapping(address => Plan) private _plans;
    // agentWallet => milestoneIndex => MilestoneData
    mapping(address => MilestoneData[8]) private _milestones;
    // agentWallet => destination => ExpenseDestination
    mapping(address => mapping(address => ExpenseDestination)) private _expenseDests;
    // agentWallet => USDC balance allocated for disbursement
    mapping(address => uint256) private _planBalances;

    // ── Modifiers ───────────────────────────────────────────────────

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

    modifier notPaused() {
        if (paused) revert Errors.PlatformPaused();
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────

    constructor(address _usdc, address _admin, address _oracle) {
        if (_usdc == address(0) || _admin == address(0) || _oracle == address(0))
            revert Errors.ZeroAddress();
        usdc = IERC20(_usdc);
        admin = _admin;
        oracle = _oracle;
    }

    // ── Admin ───────────────────────────────────────────────────────

    function pause() external onlyAdmin {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyAdmin {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function setOracle(address _oracle) external onlyAdmin {
        if (_oracle == address(0)) revert Errors.ZeroAddress();
        oracle = _oracle;
    }

    // ── Plan Lifecycle ──────────────────────────────────────────────

    function createPlan(
        address agentWallet,
        uint256 totalCredit,
        MilestoneInput[] calldata milestones
    ) external onlyAdminOrOracle notPaused {
        if (agentWallet == address(0)) revert Errors.ZeroAddress();
        if (totalCredit == 0) revert Errors.ZeroCredit();
        if (_plans[agentWallet].totalCredit != 0) revert Errors.PlanAlreadyExists();
        if (milestones.length > MAX_MILESTONES) revert Errors.MaxMilestonesReached();

        // Validate milestone sum
        uint256 milestoneSum = 0;
        for (uint256 i = 0; i < milestones.length; i++) {
            milestoneSum += milestones[i].amount;
        }
        if (milestoneSum > totalCredit) revert Errors.MilestoneSumExceedsCredit();

        _plans[agentWallet] = Plan({
            agentWallet: agentWallet,
            owner: msg.sender,
            totalCredit: totalCredit,
            totalDisbursed: 0,
            projectedMonthlyRevenue: 0,
            actualRevenueThisPeriod: 0,
            periodStart: block.timestamp,
            health: ServiceHealth.Green,
            lastRevenueAt: block.timestamp,
            zeroRevenueDays: 0,
            windDownState: WindDownState.None,
            windDownStartedAt: 0,
            expenseDestCount: 0,
            milestoneCount: uint8(milestones.length),
            createdAt: block.timestamp
        });

        for (uint256 i = 0; i < milestones.length; i++) {
            _milestones[agentWallet][i] = MilestoneData({
                amount: milestones[i].amount,
                descriptionHash: milestones[i].descriptionHash,
                eligibleAt: milestones[i].eligibleAt,
                disbursed: false,
                disbursedAt: 0,
                isActive: true
            });
        }

        totalPlans++;

        emit PlanCreated(agentWallet, msg.sender, totalCredit, uint8(milestones.length));
    }

    /// @notice Fund a plan with USDC for milestone disbursements
    function fundPlan(address agentWallet, uint256 amount) external nonReentrant notPaused {
        if (_plans[agentWallet].totalCredit == 0) revert Errors.PlanNotFound();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        _planBalances[agentWallet] += amount;
    }

    // ── Milestone Disbursement ──────────────────────────────────────

    function disburseMilestone(
        address agentWallet,
        uint8 milestoneIndex
    ) external onlyOracle nonReentrant notPaused {
        Plan storage plan = _plans[agentWallet];
        if (plan.totalCredit == 0) revert Errors.PlanNotFound();

        // No disbursements during wind-down
        if (plan.windDownState != WindDownState.None) revert Errors.InWindDown();

        // Health gates
        if (plan.health == ServiceHealth.Orange || plan.health == ServiceHealth.Red) {
            revert Errors.DisbursementsPaused();
        }

        if (milestoneIndex >= MAX_MILESTONES) revert Errors.MilestoneOutOfBounds();

        MilestoneData storage ms = _milestones[agentWallet][milestoneIndex];
        if (!ms.isActive) revert Errors.MilestoneNotActive_();
        if (ms.disbursed) revert Errors.MilestoneAlreadyDisbursed();
        if (block.timestamp < ms.eligibleAt) revert Errors.MilestoneNotEligible();

        // Yellow zone: enforce 7-day delay
        if (plan.health == ServiceHealth.Yellow) {
            if (block.timestamp < ms.eligibleAt + YELLOW_MILESTONE_DELAY_SECONDS) {
                revert Errors.MilestoneDelayed();
            }
        }

        uint256 amount = ms.amount;

        // Effects
        ms.disbursed = true;
        ms.disbursedAt = block.timestamp;
        plan.totalDisbursed += amount;

        // Interaction: transfer from plan balance to agent wallet
        _planBalances[agentWallet] -= amount;
        usdc.safeTransfer(agentWallet, amount);

        emit MilestoneDisbursed(agentWallet, milestoneIndex, amount);
    }

    // ── Expense Destinations ────────────────────────────────────────

    function addExpenseDestination(
        address agentWallet,
        address destination,
        bytes32 labelHash,
        uint8 category,
        uint256 maxAmount
    ) external onlyAdminOrOracle notPaused {
        Plan storage plan = _plans[agentWallet];
        if (plan.totalCredit == 0) revert Errors.PlanNotFound();
        if (category > 4) revert Errors.InvalidCategory();
        if (plan.expenseDestCount >= MAX_EXPENSE_DESTINATIONS) revert Errors.MaxExpenseDestsReached();

        ExpenseDestination storage dest = _expenseDests[agentWallet][destination];
        if (dest.isActive) revert Errors.SettlementAlreadyExists();

        dest.destination = destination;
        dest.labelHash = labelHash;
        dest.category = category;
        dest.maxAmount = maxAmount;
        dest.totalSent = 0;
        dest.isActive = true;
        dest.approvedAt = block.timestamp;

        plan.expenseDestCount++;

        emit ExpenseDestAdded(agentWallet, destination, category);
    }

    function removeExpenseDestination(
        address agentWallet,
        address destination
    ) external onlyAdminOrOracle notPaused {
        Plan storage plan = _plans[agentWallet];
        if (plan.totalCredit == 0) revert Errors.PlanNotFound();

        ExpenseDestination storage dest = _expenseDests[agentWallet][destination];
        if (!dest.isActive) revert Errors.ExpenseDestNotActive();

        dest.isActive = false;
        plan.expenseDestCount--;

        emit ExpenseDestRemoved(agentWallet, destination);
    }

    function executeExpense(
        address agentWallet,
        address destination,
        uint256 amount
    ) external nonReentrant notPaused {
        Plan storage plan = _plans[agentWallet];
        if (plan.totalCredit == 0) revert Errors.PlanNotFound();

        // Only allow expenses in None or Grace wind-down states
        if (plan.windDownState == WindDownState.Executing ||
            plan.windDownState == WindDownState.Completed) {
            revert Errors.InWindDown();
        }

        // Caller must be plan owner or oracle
        if (msg.sender != plan.owner && msg.sender != oracle && msg.sender != admin) {
            revert Errors.Unauthorized();
        }

        ExpenseDestination storage dest = _expenseDests[agentWallet][destination];
        if (!dest.isActive) revert Errors.ExpenseDestNotActive();

        // Per-tx limit check
        if (dest.maxAmount > 0 && amount > dest.maxAmount) {
            revert Errors.ExceedsExpenseLimit();
        }

        dest.totalSent += amount;

        // Transfer from agent wallet (agent must have approved this contract)
        usdc.safeTransferFrom(agentWallet, destination, amount);

        emit ExpenseExecuted(agentWallet, destination, amount);
    }

    // ── Revenue Monitoring ──────────────────────────────────────────

    function recordRevenue(
        address agentWallet,
        uint256 amount
    ) external onlyOracle notPaused {
        Plan storage plan = _plans[agentWallet];
        if (plan.totalCredit == 0) revert Errors.PlanNotFound();

        plan.actualRevenueThisPeriod += amount;
        plan.lastRevenueAt = block.timestamp;
        plan.zeroRevenueDays = 0;

        ServiceHealth oldHealth = plan.health;
        ServiceHealth newHealth = computeHealth(
            plan.actualRevenueThisPeriod,
            plan.projectedMonthlyRevenue,
            plan.zeroRevenueDays
        );
        plan.health = newHealth;

        emit RevenueRecorded(agentWallet, amount, plan.actualRevenueThisPeriod, newHealth);

        if (oldHealth != newHealth) {
            emit HealthUpdated(agentWallet, oldHealth, newHealth);
        }
    }

    function updateZeroRevenueDays(
        address agentWallet,
        uint8 days_
    ) external onlyOracle notPaused {
        Plan storage plan = _plans[agentWallet];
        if (plan.totalCredit == 0) revert Errors.PlanNotFound();

        ServiceHealth oldHealth = plan.health;
        plan.zeroRevenueDays = days_;

        ServiceHealth newHealth = computeHealth(
            plan.actualRevenueThisPeriod,
            plan.projectedMonthlyRevenue,
            plan.zeroRevenueDays
        );
        plan.health = newHealth;

        if (oldHealth != newHealth) {
            emit HealthUpdated(agentWallet, oldHealth, newHealth);
        }
    }

    function setProjectedRevenue(
        address agentWallet,
        uint256 projected
    ) external onlyOracle notPaused {
        Plan storage plan = _plans[agentWallet];
        if (plan.totalCredit == 0) revert Errors.PlanNotFound();

        plan.projectedMonthlyRevenue = projected;
        plan.actualRevenueThisPeriod = 0;
        plan.periodStart = block.timestamp;

        emit ProjectedRevenueSet(agentWallet, projected);
    }

    // ── Wind-Down ───────────────────────────────────────────────────

    function startWindDown(address agentWallet) external onlyAdminOrOracle notPaused {
        Plan storage plan = _plans[agentWallet];
        if (plan.totalCredit == 0) revert Errors.PlanNotFound();
        if (plan.windDownState != WindDownState.None) revert Errors.WindDownAlreadyStarted();
        if (plan.health != ServiceHealth.Red) revert Errors.HealthNotRed();

        plan.windDownState = WindDownState.Grace;
        plan.windDownStartedAt = block.timestamp;

        emit WindDownStarted(agentWallet, block.timestamp + WIND_DOWN_GRACE_SECONDS);
    }

    /// @notice Advance wind-down: Grace → Executing → Completed. Permissionless after grace.
    function advanceWindDown(address agentWallet) external {
        Plan storage plan = _plans[agentWallet];
        if (plan.totalCredit == 0) revert Errors.PlanNotFound();

        if (plan.windDownState == WindDownState.Grace) {
            if (block.timestamp < plan.windDownStartedAt + WIND_DOWN_GRACE_SECONDS) {
                revert Errors.GracePeriodNotElapsed();
            }
            plan.windDownState = WindDownState.Executing;
            emit WindDownAdvanced(agentWallet, WindDownState.Executing);
        } else if (plan.windDownState == WindDownState.Executing) {
            plan.windDownState = WindDownState.Completed;
            emit WindDownAdvanced(agentWallet, WindDownState.Completed);
        } else {
            revert Errors.InvalidWindDownTransition();
        }
    }

    // ── Views ───────────────────────────────────────────────────────

    function getPlan(address agentWallet) external view returns (Plan memory) {
        return _plans[agentWallet];
    }

    function getMilestone(address agentWallet, uint8 index) external view returns (MilestoneData memory) {
        if (index >= MAX_MILESTONES) revert Errors.MilestoneOutOfBounds();
        return _milestones[agentWallet][index];
    }

    function getExpenseDestination(
        address agentWallet,
        address destination
    ) external view returns (ExpenseDestination memory) {
        return _expenseDests[agentWallet][destination];
    }

    function getPlanBalance(address agentWallet) external view returns (uint256) {
        return _planBalances[agentWallet];
    }

    // ── Pure: Health Computation ────────────────────────────────────

    function computeHealth(
        uint256 actual,
        uint256 projected,
        uint8 zeroDays
    ) public pure returns (ServiceHealth) {
        // Zero-revenue day overrides
        if (zeroDays >= ZERO_REVENUE_RED_DAYS) return ServiceHealth.Red;
        if (zeroDays >= ZERO_REVENUE_ORANGE_DAYS) return ServiceHealth.Orange;

        // No projection → stay Green
        if (projected == 0) return ServiceHealth.Green;

        // Revenue velocity ratio in BPS
        uint256 ratioBps = (actual * BPS_DENOMINATOR) / projected;

        if (ratioBps >= REVENUE_GREEN_BPS) return ServiceHealth.Green;
        if (ratioBps >= REVENUE_YELLOW_BPS) return ServiceHealth.Yellow;
        if (ratioBps >= REVENUE_ORANGE_BPS) return ServiceHealth.Orange;
        return ServiceHealth.Red;
    }
}
