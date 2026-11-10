// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMerchantVault} from "./interfaces/IMerchantVault.sol";
import {IMilestoneRegistry} from "./interfaces/IMilestoneRegistry.sol";
import {WaterfallLib} from "./libraries/WaterfallLib.sol";
import {Errors} from "./libraries/Errors.sol";

/// @title MerchantVault — Credit line + waterfall repayment for an AI agent
/// @notice Solana krexa-credit-vault parity: continuous interest accrual,
///         per-tranche APR yields, protocol fee, insurance fund, surplus split,
///         credit freeze, treasury routing.
contract MerchantVault is IMerchantVault, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Constants (matching Solana krexa-common) ────────────────────

    uint16 public constant SENIOR_APR = 800;      // 8%
    uint16 public constant MEZZ_APR = 1200;        // 12%
    uint16 public constant JUNIOR_APR = 2000;      // 20%
    uint16 public constant PROTOCOL_FEE_BPS = 1000; // 10%
    uint16 public constant BPS = 10_000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    // Insurance target: 20% of deployed capital
    uint16 public constant INSURANCE_TARGET_BPS = 2000;
    // Pre-target surplus split: 40% insurance / 60% treasury
    uint16 public constant INSURANCE_SURPLUS_BPS = 4000;
    // Post-target surplus split: 10% insurance / 90% treasury
    uint16 public constant INSURANCE_POST_TARGET_BPS = 1000;

    // ─── State ───────────────────────────────────────────────────

    IERC20 public immutable usdc;
    address public immutable agent;
    address public immutable factory;
    address public paymentRouter;
    address public admin;

    VaultState public state;

    // Fundraising
    uint256 public targetAmount;
    uint256 public totalRaised;
    uint256 public interestRateBps;
    uint256 public durationSeconds;
    uint256 public numTranches;
    uint256 public tranchesReleased;

    // Continuous interest accrual (Solana parity)
    uint256 public creditDrawn;         // principal outstanding (= totalRaised once activated)
    uint256 public accruedInterest;     // interest accrued but not yet paid
    uint256 public totalInterestPaid;   // cumulative interest paid
    uint256 public lastAccrualTimestamp;

    // Repayment
    uint256 public totalRepaid;
    uint256 public totalToRepay;        // kept for backward compat (recomputed dynamically)
    uint256 public activatedAt;

    // Waterfall accounting
    uint256 public seniorFunded;
    uint256 public poolFunded;
    uint256 public userFunded;
    uint256 public totalSeniorRepaid;
    uint256 public totalPoolRepaid;
    uint256 public totalCommunityRepaid;

    // Per-tranche yield tracking (Solana parity)
    uint256 public seniorYieldPaid;
    uint256 public poolYieldPaid;
    uint256 public communityYieldPaid;
    uint256 public lastYieldTimestamp;

    // Insurance fund (Solana parity)
    uint256 public insuranceBalance;

    // Treasury (Solana parity)
    address public treasury;

    // Platform fees
    uint16 public platformFeeBps;
    address public platformFeeRecipient;
    uint256 public platformFeesCollected;

    // Late fees
    uint16 public lateFeeBps;
    uint256 public totalLateFees;
    uint256 public gracePeriodSeconds;

    // x402-aware repayment tracking
    uint256 public nextPaymentDue;
    uint256 public expectedRepaymentPerPeriod;
    uint256 public constant REPAYMENT_INTERVAL = 30 days;

    // Fundraising deadline
    uint256 public fundraisingDeadline;

    // Milestone registry
    IMilestoneRegistry public milestoneRegistry;

    // Investor tracking
    mapping(address => uint256) public investorBalances;
    mapping(address => uint256) public claimedReturns;
    mapping(address => bool) public isSeniorInvestor;
    mapping(address => bool) public isPoolInvestor;
    address[] public investors;

    address public pendingAdmin;
    bool public paused;
    bool public frozen; // Credit freeze (Solana parity)

    // Default snapshot
    uint256 public defaultSnapshotBalance;

    // ─── Modifiers ───────────────────────────────────────────────

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Errors.Unauthorized();
        _;
    }

    modifier onlyPaymentRouter() {
        if (msg.sender != paymentRouter) revert Errors.Unauthorized();
        _;
    }

    modifier notPaused() {
        if (paused) revert Errors.VaultPaused();
        _;
    }

    modifier inState(VaultState expected) {
        if (state != expected) revert Errors.InvalidVaultState();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────

    struct VaultParams {
        address usdc;
        address agent;
        address admin;
        address factory;
        uint256 targetAmount;
        uint256 interestRateBps;
        uint256 durationSeconds;
        uint256 numTranches;
        uint16 platformFeeBps;
        address platformFeeRecipient;
        uint16 lateFeeBps;
        uint256 gracePeriodSeconds;
        uint256 fundraisingDeadline;
    }

    constructor(VaultParams memory p) {
        if (p.usdc == address(0) || p.agent == address(0) || p.admin == address(0))
            revert Errors.ZeroAddress();
        if (p.targetAmount == 0) revert Errors.InvalidAmount();
        if (p.numTranches == 0) revert Errors.InvalidTrancheCount();

        usdc = IERC20(p.usdc);
        agent = p.agent;
        admin = p.admin;
        factory = p.factory;
        targetAmount = p.targetAmount;
        interestRateBps = p.interestRateBps;
        durationSeconds = p.durationSeconds;
        numTranches = p.numTranches;
        platformFeeBps = p.platformFeeBps;
        platformFeeRecipient = p.platformFeeRecipient;
        lateFeeBps = p.lateFeeBps;
        gracePeriodSeconds = p.gracePeriodSeconds;
        fundraisingDeadline = p.fundraisingDeadline;
        state = VaultState.Fundraising;
    }

    // ─── Admin Setup ─────────────────────────────────────────────

    function setPaymentRouter(address _router) external onlyAdmin {
        if (_router == address(0)) revert Errors.ZeroAddress();
        address old = paymentRouter;
        paymentRouter = _router;
        emit PaymentRouterUpdated(old, _router);
    }

    function setMilestoneRegistry(address _milestoneRegistry) external onlyAdmin {
        milestoneRegistry = IMilestoneRegistry(_milestoneRegistry);
    }

    function setTreasury(address _treasury) external onlyAdmin {
        if (_treasury == address(0)) revert Errors.ZeroAddress();
        address old = treasury;
        treasury = _treasury;
        emit TreasuryUpdated(old, _treasury);
    }

    function proposeAdmin(address _newAdmin) external onlyAdmin {
        if (_newAdmin == address(0)) revert Errors.ZeroAddress();
        pendingAdmin = _newAdmin;
        emit AdminTransferProposed(admin, _newAdmin);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert Errors.Unauthorized();
        address old = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferred(old, admin);
    }

    function freezeCredit() external onlyAdmin {
        frozen = true;
        emit CreditFrozen(true);
    }

    function unfreezeCredit() external onlyAdmin {
        frozen = false;
        emit CreditFrozen(false);
    }

    // ─── Invest ──────────────────────────────────────────────────

    function invest(uint256 amount) external nonReentrant notPaused inState(VaultState.Fundraising) {
        if (amount == 0) revert Errors.InvalidAmount();
        if (totalRaised + amount > targetAmount) revert Errors.ExceedsTarget();

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        if (investorBalances[msg.sender] == 0) {
            investors.push(msg.sender);
        }
        investorBalances[msg.sender] += amount;
        totalRaised += amount;

        emit Invested(msg.sender, amount, totalRaised);

        if (totalRaised == targetAmount) {
            _activate();
        }
    }

    function investSenior(uint256 amount) external nonReentrant notPaused inState(VaultState.Fundraising) {
        if (amount == 0) revert Errors.InvalidAmount();
        if (totalRaised + amount > targetAmount) revert Errors.ExceedsTarget();
        if (isPoolInvestor[msg.sender]) revert Errors.Unauthorized();

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        if (investorBalances[msg.sender] == 0) {
            investors.push(msg.sender);
        }
        investorBalances[msg.sender] += amount;
        isSeniorInvestor[msg.sender] = true;
        seniorFunded += amount;
        totalRaised += amount;

        emit Invested(msg.sender, amount, totalRaised);

        if (totalRaised == targetAmount) {
            _activate();
        }
    }

    function investFromPool(uint256 amount) external nonReentrant notPaused inState(VaultState.Fundraising) {
        if (amount == 0) revert Errors.InvalidAmount();
        if (totalRaised + amount > targetAmount) revert Errors.ExceedsTarget();
        if (isSeniorInvestor[msg.sender]) revert Errors.Unauthorized();

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        if (investorBalances[msg.sender] == 0) {
            investors.push(msg.sender);
        }
        investorBalances[msg.sender] += amount;
        isPoolInvestor[msg.sender] = true;

        poolFunded += amount;
        totalRaised += amount;

        emit Invested(msg.sender, amount, totalRaised);

        if (totalRaised == targetAmount) {
            _activate();
        }
    }

    // ─── Tranche Release ─────────────────────────────────────────

    function releaseTranche() external onlyAdmin notPaused {
        if (state != VaultState.Active && state != VaultState.Repaying)
            revert Errors.InvalidVaultState();
        if (frozen) revert Errors.VaultPaused(); // frozen blocks new releases
        if (tranchesReleased >= numTranches) revert Errors.AllTranchesReleased();

        if (address(milestoneRegistry) != address(0)) {
            if (!milestoneRegistry.isMilestoneApproved(address(this), tranchesReleased + 1))
                revert Errors.MilestoneNotApproved();
        }

        tranchesReleased++;
        uint256 trancheSize = totalRaised / numTranches;
        uint256 trancheAmount;

        if (tranchesReleased == numTranches) {
            trancheAmount = totalRaised - (numTranches - 1) * trancheSize;
        } else {
            trancheAmount = trancheSize;
        }

        usdc.safeTransfer(agent, trancheAmount);

        emit TrancheReleased(tranchesReleased, trancheAmount, agent);
    }

    // ─── Interest Accrual (Solana parity) ────────────────────────

    /// @notice Permissionless interest accrual — anyone can trigger
    function accrueInterest() public {
        if (state != VaultState.Active && state != VaultState.Repaying) return;
        if (creditDrawn == 0) return;

        uint256 elapsed = block.timestamp - lastAccrualTimestamp;
        if (elapsed == 0) return;

        // Simple interest: creditDrawn * rate * elapsed / (BPS * SECONDS_PER_YEAR)
        uint256 newInterest = (creditDrawn * interestRateBps * elapsed) / (uint256(BPS) * SECONDS_PER_YEAR);

        if (newInterest > 0) {
            accruedInterest += newInterest;
            lastAccrualTimestamp = block.timestamp;
            emit InterestAccrued(newInterest, accruedInterest);
        } else {
            lastAccrualTimestamp = block.timestamp;
        }
    }

    // ─── Repayment (called by PaymentRouter) ─────────────────────

    struct RepaymentSplit {
        uint256 interestPortion;
        uint256 principalPortion;
        uint256 protocolFee;
        uint256 distributableInterest;
    }

    struct YieldSplit {
        uint256 seniorPaid;
        uint256 poolPaid;
        uint256 communityPaid;
        uint256 surplus;
        uint256 insuranceFromSurplus;
        uint256 treasuryAmount;
    }

    function processRepayment(uint256 amount) external nonReentrant onlyPaymentRouter notPaused {
        if (state != VaultState.Active && state != VaultState.Repaying)
            revert Errors.InvalidVaultState();
        if (amount == 0) revert Errors.InvalidAmount();

        // Move to repaying state on first repayment
        if (state == VaultState.Active) {
            VaultState oldState = state;
            state = VaultState.Repaying;
            emit VaultStateChanged(oldState, VaultState.Repaying);
        }

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Step 0: Accrue interest to current second
        accrueInterest();
        _applyLateFees();

        // Steps 1-2: Split interest/principal + protocol fee
        RepaymentSplit memory rs = _splitRepayment(amount);

        // Steps 3-4: Tranche yield waterfall + surplus split
        YieldSplit memory ys = _distributeYield(rs.distributableInterest);

        // Step 5: Update state
        _applyRepaymentState(rs, ys, amount);
    }

    function _applyLateFees() internal {
        if (lateFeeBps > 0 && nextPaymentDue > 0 && block.timestamp > nextPaymentDue) {
            uint256 lateFee = calculateLateFee();
            if (lateFee > 0) {
                accruedInterest += lateFee;
                totalLateFees += lateFee;
                emit LateFeeApplied(lateFee, totalLateFees);
            }
            while (nextPaymentDue > 0 && nextPaymentDue <= block.timestamp) {
                nextPaymentDue += REPAYMENT_INTERVAL;
            }
        }
    }

    function _splitRepayment(uint256 amount) internal view returns (RepaymentSplit memory rs) {
        rs.interestPortion = amount > accruedInterest ? accruedInterest : amount;
        rs.principalPortion = amount - rs.interestPortion;
        rs.protocolFee = (rs.interestPortion * PROTOCOL_FEE_BPS) / BPS;
        rs.distributableInterest = rs.interestPortion - rs.protocolFee;
    }

    function _distributeYield(uint256 distributable) internal view returns (YieldSplit memory ys) {
        uint256 yieldElapsed = block.timestamp - lastYieldTimestamp;

        uint256 seniorOwed = _trancheYieldOwed(seniorFunded, SENIOR_APR, yieldElapsed);
        uint256 poolOwed = _trancheYieldOwed(poolFunded, MEZZ_APR, yieldElapsed);
        uint256 communityOwed = _trancheYieldOwed(userFunded, JUNIOR_APR, yieldElapsed);

        // Senior first
        ys.seniorPaid = distributable > seniorOwed ? seniorOwed : distributable;
        uint256 afterSenior = distributable - ys.seniorPaid;

        ys.poolPaid = afterSenior > poolOwed ? poolOwed : afterSenior;
        uint256 afterPool = afterSenior - ys.poolPaid;

        ys.communityPaid = afterPool > communityOwed ? communityOwed : afterPool;
        ys.surplus = afterPool - ys.communityPaid;

        // Surplus split
        if (_insuranceAtTarget()) {
            ys.insuranceFromSurplus = (ys.surplus * INSURANCE_POST_TARGET_BPS) / BPS;
        } else {
            ys.insuranceFromSurplus = (ys.surplus * INSURANCE_SURPLUS_BPS) / BPS;
        }
        ys.treasuryAmount = ys.surplus - ys.insuranceFromSurplus;
    }

    function _applyRepaymentState(RepaymentSplit memory rs, YieldSplit memory ys, uint256 amount) internal {
        accruedInterest -= rs.interestPortion;
        creditDrawn -= rs.principalPortion;
        totalInterestPaid += rs.interestPortion;
        totalRepaid += amount;

        // Principal waterfall (backward compat)
        {
            uint256 seniorOwed = seniorFunded > totalSeniorRepaid ? seniorFunded - totalSeniorRepaid : 0;
            uint256 poolOwed = poolFunded > totalPoolRepaid ? poolFunded - totalPoolRepaid : 0;
            WaterfallLib.Distribution memory dist = WaterfallLib.distribute(seniorOwed, poolOwed, rs.principalPortion);
            totalSeniorRepaid += dist.seniorPayment;
            totalPoolRepaid += dist.poolPayment;
            totalCommunityRepaid += dist.communityPayment;

            emit RepaymentProcessed(amount, dist.seniorPayment, dist.poolPayment, dist.communityPayment);
            emit WaterfallDistributed(dist.seniorPayment, dist.poolPayment, dist.communityPayment);
        }

        // Tranche yields
        seniorYieldPaid += ys.seniorPaid;
        poolYieldPaid += ys.poolPaid;
        communityYieldPaid += ys.communityPaid;
        lastYieldTimestamp = block.timestamp;

        // Insurance
        uint256 totalInsurance = rs.protocolFee + ys.insuranceFromSurplus;
        insuranceBalance += totalInsurance;

        // Treasury transfer
        if (ys.treasuryAmount > 0 && treasury != address(0)) {
            usdc.safeTransfer(treasury, ys.treasuryAmount);
        }

        // Legacy platform fee on principal
        if (platformFeeBps > 0 && platformFeeRecipient != address(0) && rs.principalPortion > 0) {
            uint256 legacyFee = (rs.principalPortion * platformFeeBps) / BPS;
            if (legacyFee > 0) {
                platformFeesCollected += legacyFee;
                usdc.safeTransfer(platformFeeRecipient, legacyFee);
            }
        }

        emit TranchYieldDistributed(ys.seniorPaid, ys.poolPaid, ys.communityPaid, ys.surplus);
        if (totalInsurance > 0) {
            emit InsuranceFunded(rs.protocolFee, ys.insuranceFromSurplus, insuranceBalance);
        }

        // Check completion
        if (creditDrawn == 0 && accruedInterest == 0) {
            VaultState oldState = state;
            state = VaultState.Completed;
            emit VaultStateChanged(oldState, VaultState.Completed);
        }
    }

    // ─── Claim Returns ───────────────────────────────────────────

    function claimReturns() external nonReentrant {
        if (state != VaultState.Repaying && state != VaultState.Completed)
            revert Errors.InvalidVaultState();

        uint256 claimable = _claimableFor(msg.sender);
        if (claimable == 0) revert Errors.NothingToClaim();

        claimedReturns[msg.sender] += claimable;
        usdc.safeTransfer(msg.sender, claimable);

        emit ReturnsClaimed(msg.sender, claimable);
    }

    // ─── Lifecycle ───────────────────────────────────────────────

    function markDefault() external {
        if (state != VaultState.Active && state != VaultState.Repaying)
            revert Errors.InvalidVaultState();
        if (!shouldDefault() && msg.sender != admin) revert Errors.DefaultConditionsNotMet();

        // Accrue final interest before default
        accrueInterest();

        VaultState oldState = state;
        state = VaultState.Defaulted;
        defaultSnapshotBalance = usdc.balanceOf(address(this));
        emit VaultStateChanged(oldState, VaultState.Defaulted);
        emit VaultDefaulted(block.timestamp);
    }

    function autoCancelExpired() external {
        if (state != VaultState.Fundraising) revert Errors.InvalidVaultState();
        if (fundraisingDeadline == 0 || block.timestamp <= fundraisingDeadline)
            revert Errors.FundraisingNotExpired();
        if (totalRaised >= (targetAmount * 80) / 100)
            revert Errors.FundraisingAboveThreshold();

        VaultState oldState = state;
        state = VaultState.Cancelled;
        emit VaultStateChanged(oldState, VaultState.Cancelled);
        emit VaultCancelled(block.timestamp);
    }

    function completeFundraisingManual() external onlyAdmin inState(VaultState.Fundraising) {
        if (totalRaised < (targetAmount * 80) / 100)
            revert Errors.FundraisingThresholdNotMet();

        _activate();
    }

    function cancel() external onlyAdmin inState(VaultState.Fundraising) {
        VaultState oldState = state;
        state = VaultState.Cancelled;
        emit VaultStateChanged(oldState, VaultState.Cancelled);
        emit VaultCancelled(block.timestamp);
    }

    function claimRefund() external nonReentrant {
        if (state != VaultState.Cancelled && state != VaultState.Defaulted)
            revert Errors.InvalidVaultState();

        uint256 balance = investorBalances[msg.sender];
        if (balance == 0) revert Errors.NothingToClaim();

        uint256 refund;
        if (state == VaultState.Cancelled) {
            refund = balance;
        } else {
            if (totalRaised == 0) revert Errors.NothingToClaim();
            refund = (balance * defaultSnapshotBalance) / totalRaised;
        }

        investorBalances[msg.sender] = 0;
        if (refund > 0) {
            usdc.safeTransfer(msg.sender, refund);
        }
    }

    function pause() external onlyAdmin {
        paused = true;
        emit VaultPaused();
    }

    function unpause() external onlyAdmin {
        paused = false;
        emit VaultUnpaused();
    }

    // ─── View Functions ──────────────────────────────────────────

    function getAgent() external view returns (address) {
        return agent;
    }

    function getState() external view returns (VaultState) {
        return state;
    }

    function getTotalRaised() external view returns (uint256) {
        return totalRaised;
    }

    function getTotalRepaid() external view returns (uint256) {
        return totalRepaid;
    }

    function getTotalToRepay() external view returns (uint256) {
        return totalToRepay;
    }

    function totalDebt() external view returns (uint256) {
        return creditDrawn + accruedInterest;
    }

    function isFrozen() external view returns (bool) {
        return frozen;
    }

    function seniorAprBps() external pure returns (uint16) {
        return SENIOR_APR;
    }

    function poolAprBps() external pure returns (uint16) {
        return MEZZ_APR;
    }

    function communityAprBps() external pure returns (uint16) {
        return JUNIOR_APR;
    }

    function getInvestorBalance(address investor) external view returns (uint256) {
        return investorBalances[investor];
    }

    function getClaimable(address investor) external view returns (uint256) {
        return _claimableFor(investor);
    }

    function getInvestors() external view returns (address[] memory) {
        return investors;
    }

    function getWaterfallState()
        external
        view
        returns (
            uint256 _seniorFunded,
            uint256 _poolFunded,
            uint256 _userFunded,
            uint256 _seniorRepaid,
            uint256 _poolRepaid,
            uint256 _communityRepaid
        )
    {
        return (seniorFunded, poolFunded, userFunded, totalSeniorRepaid, totalPoolRepaid, totalCommunityRepaid);
    }

    function calculateLateFee() public view returns (uint256) {
        if (lateFeeBps == 0 || nextPaymentDue == 0) return 0;
        if (block.timestamp <= nextPaymentDue) return 0;

        uint256 daysLate = (block.timestamp - nextPaymentDue) / 1 days;
        if (daysLate == 0) return 0;
        if (daysLate > REPAYMENT_INTERVAL / 1 days) {
            daysLate = REPAYMENT_INTERVAL / 1 days;
        }

        uint256 periodsElapsed = 0;
        if (activatedAt > 0 && REPAYMENT_INTERVAL > 0) {
            periodsElapsed = (block.timestamp - activatedAt) / REPAYMENT_INTERVAL;
        }
        uint256 expectedCumulative = periodsElapsed * expectedRepaymentPerPeriod;
        if (expectedCumulative > totalToRepay) expectedCumulative = totalToRepay;

        uint256 shortfall = totalRepaid >= expectedCumulative ? 0 : expectedCumulative - totalRepaid;
        if (shortfall == 0) return 0;

        return (shortfall * lateFeeBps * daysLate) / BPS;
    }

    function shouldDefault() public view returns (bool) {
        if (state != VaultState.Active && state != VaultState.Repaying) return false;
        if (nextPaymentDue == 0 || gracePeriodSeconds == 0) return false;
        return block.timestamp > nextPaymentDue + gracePeriodSeconds;
    }

    // ─── Internal ────────────────────────────────────────────────

    function _activate() internal {
        if (seniorFunded + poolFunded > totalRaised) revert Errors.ArithmeticOverflow();
        userFunded = totalRaised - seniorFunded - poolFunded;

        // Set up continuous accrual instead of flat interest
        creditDrawn = totalRaised;
        accruedInterest = 0;
        lastAccrualTimestamp = block.timestamp;
        lastYieldTimestamp = block.timestamp;

        // totalToRepay kept for backward compat (estimated total with simple interest)
        uint256 interest = (totalRaised * interestRateBps * durationSeconds) / (SECONDS_PER_YEAR * BPS);
        totalToRepay = totalRaised + interest;

        VaultState oldState = state;
        state = VaultState.Active;
        activatedAt = block.timestamp;

        // Set up repayment schedule for late fee tracking
        if (lateFeeBps > 0 && durationSeconds >= REPAYMENT_INTERVAL) {
            nextPaymentDue = block.timestamp + REPAYMENT_INTERVAL;
            uint256 numberOfPeriods = durationSeconds / REPAYMENT_INTERVAL;
            expectedRepaymentPerPeriod = numberOfPeriods > 0 ? totalToRepay / numberOfPeriods : totalToRepay;
        }

        emit VaultStateChanged(oldState, VaultState.Active);
    }

    function _trancheYieldOwed(uint256 trancheCapital, uint16 aprBps, uint256 secondsElapsed) internal pure returns (uint256) {
        if (trancheCapital == 0 || secondsElapsed == 0) return 0;
        return (trancheCapital * aprBps * secondsElapsed) / (uint256(BPS) * SECONDS_PER_YEAR);
    }

    function _insuranceAtTarget() internal view returns (bool) {
        if (creditDrawn == 0) return true;
        uint256 target = (creditDrawn * INSURANCE_TARGET_BPS) / BPS;
        return insuranceBalance >= target;
    }

    function _claimableFor(address investor) internal view returns (uint256) {
        uint256 balance = investorBalances[investor];
        if (balance == 0) return 0;

        // Pool investors: pro-rata from pool principal repaid + pool yield
        if (isPoolInvestor[investor] && poolFunded > 0) {
            uint256 totalPoolReturns = totalPoolRepaid + poolYieldPaid;
            uint256 share = (balance * totalPoolReturns) / poolFunded;
            return share > claimedReturns[investor] ? share - claimedReturns[investor] : 0;
        }

        // Senior investors: pro-rata from senior principal repaid + senior yield
        if (isSeniorInvestor[investor] && seniorFunded > 0) {
            uint256 totalSeniorReturns = totalSeniorRepaid + seniorYieldPaid;
            uint256 share = (balance * totalSeniorReturns) / seniorFunded;
            return share > claimedReturns[investor] ? share - claimedReturns[investor] : 0;
        }

        // Community investors: pro-rata from community principal repaid + community yield
        if (userFunded > 0) {
            uint256 totalCommunityReturns = totalCommunityRepaid + communityYieldPaid;
            uint256 share = (balance * totalCommunityReturns) / userFunded;
            return share > claimedReturns[investor] ? share - claimedReturns[investor] : 0;
        }

        return 0;
    }
}
