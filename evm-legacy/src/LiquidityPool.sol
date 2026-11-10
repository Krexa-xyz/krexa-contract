// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMerchantVault} from "./interfaces/IMerchantVault.sol";
import {ILiquidityPool} from "./interfaces/ILiquidityPool.sol";
import {Errors} from "./libraries/Errors.sol";

/// @title LiquidityPool — LP capital management with share math, tranches, yield, insurance
/// @notice Solana krexa-credit-vault parity: share-based accounting prevents donation attacks,
///         tranche APRs (Senior/Mezzanine/Junior), utilization cap, insurance fund, LP lockup.
contract LiquidityPool is ILiquidityPool, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Constants (match krexa-common/constants.rs) ────────────────────

    uint256 public constant BPS = 10_000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant MINIMUM_INITIAL_DEPOSIT = 1_000; // 0.001 USDC (SOL-004 fix)
    uint256 public constant SHARE_PRECISION = 1e18; // share price precision

    // Default tranche APRs (bps) — match Solana SENIOR_APR_BPS etc.
    uint16 public constant SENIOR_APR_BPS = 800;      // 8% APR
    uint16 public constant MEZZANINE_APR_BPS = 1200;   // 12% APR
    uint16 public constant JUNIOR_APR_BPS = 2000;      // 20% APR

    // Insurance fund parameters
    uint16 public constant INSURANCE_TARGET_BPS = 2000;  // 20% of deployed capital
    uint16 public constant INSURANCE_CUT_BPS = 500;      // 5% of repayment interest → insurance

    // ─── Immutables ────────────────────────────────────────────────────

    IERC20 public immutable usdc;

    // ─── Pool State ────────────────────────────────────────────────────

    address public admin;
    address public pendingAdmin;
    bool public paused;
    bool public isAlpha;              // senior pool flag (investSenior vs investFromPool)
    uint256 public maxAllocationPerVault;

    // Aggregate accounting (share-based)
    uint256 public totalDeposits;     // total USDC value in pool (deposits + yield - losses)
    uint256 public totalShares;       // total shares outstanding
    uint256 public totalAllocated;    // USDC currently lent to vaults

    // Tranche accounting
    uint256 public seniorDeposits;
    uint256 public seniorShares;
    uint256 public mezzDeposits;
    uint256 public mezzShares;
    uint256 public juniorDeposits;
    uint256 public juniorShares;

    // Insurance fund
    uint256 public insuranceBalance;

    // Parameters
    uint16 public utilizationCapBps;  // max % of pool lent out (e.g. 8000 = 80%)
    uint256 public lockupSeconds;     // LP withdrawal lockup (0 = no lockup)
    uint256 public lastYieldTimestamp; // last time yield was distributed

    // Per-depositor positions
    mapping(address => DepositPosition) private _positions;
    // Legacy: keep depositorBalances for backward compatibility with existing tests
    mapping(address => uint256) public depositorBalances;

    // Vault allocations
    mapping(address => PoolAllocation) private _allocations;
    address[] public allocatedVaults;

    // ─── Modifiers ─────────────────────────────────────────────────────

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Errors.Unauthorized();
        _;
    }

    modifier notPaused() {
        if (paused) revert Errors.PoolPaused();
        _;
    }

    // ─── Constructor ───────────────────────────────────────────────────

    constructor(address _usdc, address _admin, bool _isAlpha, uint256 _maxAllocPerVault) {
        if (_usdc == address(0) || _admin == address(0)) revert Errors.ZeroAddress();

        usdc = IERC20(_usdc);
        admin = _admin;
        isAlpha = _isAlpha;
        maxAllocationPerVault = _maxAllocPerVault;
        utilizationCapBps = 8000; // default 80%
        lastYieldTimestamp = block.timestamp;
    }

    // ═══════════════════════════════════════════════════════════════════
    // LP: Deposit / Withdraw
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Deposit USDC into Senior tranche (backward-compatible).
    function deposit(uint256 amount) external nonReentrant notPaused {
        _depositInternal(msg.sender, amount, 0, false); // default = Senior
    }

    /// @notice Deposit USDC into a specific tranche.
    function depositTranche(uint256 amount, uint8 tranche) external nonReentrant notPaused {
        if (tranche > 2) revert Errors.InvalidAmount();
        _depositInternal(msg.sender, amount, tranche, false);
    }

    /// @notice Withdraw USDC by amount (backward-compatible). Burns proportional shares.
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert Errors.InvalidAmount();
        if (depositorBalances[msg.sender] < amount) revert Errors.InsufficientBalance();

        // Convert amount to shares
        uint256 shares = _amountToShares(amount);
        if (shares == 0) revert Errors.InvalidAmount();

        _withdrawInternal(msg.sender, shares, amount);
    }

    /// @notice Withdraw by shares (Solana-parity). Amount determined by share price.
    function withdrawShares(uint256 shares) external nonReentrant {
        if (shares == 0) revert Errors.InvalidAmount();
        uint256 amount = _sharesToAmount(shares);
        if (amount == 0) revert Errors.InvalidAmount();

        _withdrawInternal(msg.sender, shares, amount);
    }

    // ═══════════════════════════════════════════════════════════════════
    // COLLATERAL: Agent deposits (earn yield on collateral)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Agent deposits collateral into pool (earns yield alongside LPs).
    function depositCollateral(address agent, uint256 amount) external nonReentrant notPaused {
        if (agent == address(0)) revert Errors.ZeroAddress();
        _depositInternal(agent, amount, 0, true);
        emit CollateralDeposited(agent, amount, _positions[agent].shares);
    }

    /// @notice Agent withdraws collateral shares.
    function withdrawCollateral(address agent, uint256 shares) external nonReentrant {
        if (agent == address(0)) revert Errors.ZeroAddress();
        DepositPosition storage pos = _positions[agent];
        if (!pos.isCollateral) revert Errors.InvalidAmount();
        if (pos.shares < shares) revert Errors.InsufficientBalance();

        uint256 amount = _sharesToAmount(shares);
        _withdrawInternal(agent, shares, amount);
        emit CollateralWithdrawn(agent, shares, amount);
    }

    // ═══════════════════════════════════════════════════════════════════
    // ADMIN: Vault Allocation
    // ═══════════════════════════════════════════════════════════════════

    function allocateToVault(address vault, uint256 amount) external onlyAdmin notPaused nonReentrant {
        if (vault == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.InvalidAmount();

        uint256 available = totalDeposits - totalAllocated;
        if (amount > available) revert Errors.InsufficientPoolBalance();

        // Utilization cap check
        if (utilizationCapBps > 0 && totalDeposits > 0) {
            uint256 newAllocated = totalAllocated + amount;
            uint256 newUtil = (newAllocated * BPS) / totalDeposits;
            if (newUtil > utilizationCapBps) revert Errors.AllocationExceedsCap();
        }

        if (maxAllocationPerVault > 0 && amount > maxAllocationPerVault)
            revert Errors.ExceedsMaxAllocation();

        if (!_allocations[vault].active) {
            allocatedVaults.push(vault);
        }

        _allocations[vault] = PoolAllocation({
            amount: _allocations[vault].amount + amount,
            returnedAmount: _allocations[vault].returnedAmount,
            allocatedAt: block.timestamp,
            active: true
        });
        totalAllocated += amount;

        // Invest into vault
        usdc.forceApprove(vault, amount);
        if (isAlpha) {
            IMerchantVault(vault).investSenior(amount);
        } else {
            IMerchantVault(vault).investFromPool(amount);
        }

        emit AllocatedToVault(vault, amount);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Return Processing
    // ═══════════════════════════════════════════════════════════════════

    function processReturn(address vault, uint256 amount) external nonReentrant {
        if (!_allocations[vault].active) revert Errors.AllocationNotFound();
        if (amount == 0) revert Errors.InvalidAmount();

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        _allocations[vault].returnedAmount += amount;
        if (totalAllocated < amount) revert Errors.ArithmeticOverflow();
        totalAllocated -= amount;

        // Deactivate if fully returned
        if (_allocations[vault].returnedAmount >= _allocations[vault].amount) {
            _allocations[vault].active = false;
        }

        emit ReturnProcessed(vault, amount);
    }

    // ═══════════════════════════════════════════════════════════════════
    // YIELD DISTRIBUTION
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Distribute time-based yield to tranches. Called periodically by admin/keeper.
    ///         yield = trancheDeposits × trancheAPR × elapsed / (BPS × SECONDS_PER_YEAR)
    function distributeYield() external onlyAdmin {
        uint256 elapsed = block.timestamp - lastYieldTimestamp;
        if (elapsed == 0) return;

        uint256 seniorYield = _trancheYield(seniorDeposits, SENIOR_APR_BPS, elapsed);
        uint256 mezzYield = _trancheYield(mezzDeposits, MEZZANINE_APR_BPS, elapsed);
        uint256 juniorYield = _trancheYield(juniorDeposits, JUNIOR_APR_BPS, elapsed);

        uint256 totalYield = seniorYield + mezzYield + juniorYield;

        // Insurance cut from yield
        uint256 insuranceCut = (totalYield * INSURANCE_CUT_BPS) / BPS;
        uint256 netYield = totalYield - insuranceCut;

        // Add net yield to pool deposits (increases share price)
        totalDeposits += netYield;
        seniorDeposits += (seniorYield * (BPS - INSURANCE_CUT_BPS)) / BPS;
        mezzDeposits += (mezzYield * (BPS - INSURANCE_CUT_BPS)) / BPS;
        juniorDeposits += (juniorYield * (BPS - INSURANCE_CUT_BPS)) / BPS;

        insuranceBalance += insuranceCut;
        lastYieldTimestamp = block.timestamp;

        emit YieldDistributed(seniorYield, mezzYield, juniorYield, insuranceCut);
    }

    // ═══════════════════════════════════════════════════════════════════
    // BAD DEBT WRITE-OFF
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Write off bad debt. Insurance covers first, remainder absorbed by LP pool.
    function writeOffBadDebt(uint256 loss) external onlyAdmin {
        if (loss == 0) revert Errors.InvalidAmount();

        uint256 insuranceCovered = 0;
        uint256 lpAbsorbed = 0;

        if (insuranceBalance >= loss) {
            insuranceCovered = loss;
            insuranceBalance -= loss;
        } else {
            insuranceCovered = insuranceBalance;
            lpAbsorbed = loss - insuranceBalance;
            insuranceBalance = 0;

            // LP absorbs remainder — reduces totalDeposits (share price drops)
            if (lpAbsorbed > totalDeposits) lpAbsorbed = totalDeposits;
            totalDeposits -= lpAbsorbed;

            // Junior absorbs first, then mezz, then senior (waterfall)
            uint256 remaining = lpAbsorbed;
            if (remaining > 0 && juniorDeposits > 0) {
                uint256 fromJunior = remaining < juniorDeposits ? remaining : juniorDeposits;
                juniorDeposits -= fromJunior;
                remaining -= fromJunior;
            }
            if (remaining > 0 && mezzDeposits > 0) {
                uint256 fromMezz = remaining < mezzDeposits ? remaining : mezzDeposits;
                mezzDeposits -= fromMezz;
                remaining -= fromMezz;
            }
            if (remaining > 0 && seniorDeposits > 0) {
                uint256 fromSenior = remaining < seniorDeposits ? remaining : seniorDeposits;
                seniorDeposits -= fromSenior;
            }
        }

        if (totalAllocated >= loss) {
            totalAllocated -= loss;
        } else {
            totalAllocated = 0;
        }

        emit BadDebtWrittenOff(loss, insuranceCovered, lpAbsorbed);
        emit InsuranceFundUpdated(insuranceBalance);
    }

    // ═══════════════════════════════════════════════════════════════════
    // ADMIN CONFIG
    // ═══════════════════════════════════════════════════════════════════

    function pause() external onlyAdmin {
        paused = true;
        emit PoolPaused();
    }

    function unpause() external onlyAdmin {
        paused = false;
        emit PoolUnpaused();
    }

    function setMaxAllocation(uint256 _max) external onlyAdmin {
        uint256 old = maxAllocationPerVault;
        maxAllocationPerVault = _max;
        emit MaxAllocationUpdated(old, _max);
    }

    function setUtilizationCap(uint16 capBps) external onlyAdmin {
        if (capBps > 10_000) revert Errors.InvalidAmount();
        uint16 old = utilizationCapBps;
        utilizationCapBps = capBps;
        emit UtilizationCapUpdated(old, capBps);
    }

    function setLockup(uint256 _lockupSeconds) external onlyAdmin {
        uint256 old = lockupSeconds;
        lockupSeconds = _lockupSeconds;
        emit LockupUpdated(old, _lockupSeconds);
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

    // ═══════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════

    function getDepositorBalance(address depositor) external view returns (uint256) {
        return depositorBalances[depositor];
    }

    function getDepositorShares(address depositor) external view returns (uint256) {
        return _positions[depositor].shares;
    }

    function getPosition(address depositor) external view returns (DepositPosition memory) {
        return _positions[depositor];
    }

    /// @notice Convert shares to USDC amount at current share price.
    function sharesToAmount(uint256 shares) external view returns (uint256) {
        return _sharesToAmount(shares);
    }

    /// @notice Convert USDC amount to shares at current share price.
    function amountToShares(uint256 amount) external view returns (uint256) {
        return _amountToShares(amount);
    }

    /// @notice Current share price in SHARE_PRECISION units (1e18 = 1:1).
    function sharePrice() external view returns (uint256) {
        if (totalShares == 0) return SHARE_PRECISION;
        return (totalDeposits * SHARE_PRECISION) / totalShares;
    }

    function getAllocation(address vault) external view returns (PoolAllocation memory) {
        return _allocations[vault];
    }

    function getTotalDeposits() external view returns (uint256) {
        return totalDeposits;
    }

    function getAvailableBalance() external view returns (uint256) {
        return totalDeposits - totalAllocated;
    }

    function getAllocatedVaults() external view returns (address[] memory) {
        return allocatedVaults;
    }

    function utilizationBps() external view returns (uint16) {
        if (totalDeposits == 0) return 0;
        return uint16((totalAllocated * BPS) / totalDeposits);
    }

    // ═══════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════

    function _depositInternal(address depositor, uint256 amount, uint8 tranche, bool isCollateral_) internal {
        if (amount == 0) revert Errors.InvalidAmount();

        // SOL-004: Minimum initial deposit to prevent share inflation attack
        if (totalShares == 0 && amount < MINIMUM_INITIAL_DEPOSIT) revert Errors.InvalidAmount();

        uint256 shares = _calculateShares(amount);
        if (shares == 0) revert Errors.InvalidAmount(); // SOL-004: never mint zero shares

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Update position
        DepositPosition storage pos = _positions[depositor];
        pos.shares += shares;
        pos.depositedAmount += amount;
        pos.depositTimestamp = block.timestamp;
        pos.tranche = tranche;
        pos.isCollateral = isCollateral_;

        // Update aggregate
        totalDeposits += amount;
        totalShares += shares;
        depositorBalances[depositor] += amount;

        // Update tranche
        if (tranche == 0) { seniorDeposits += amount; seniorShares += shares; }
        else if (tranche == 1) { mezzDeposits += amount; mezzShares += shares; }
        else if (tranche == 2) { juniorDeposits += amount; juniorShares += shares; }

        emit Deposited(depositor, amount, shares, tranche, totalDeposits);
    }

    function _withdrawInternal(address depositor, uint256 shares, uint256 amount) internal {
        DepositPosition storage pos = _positions[depositor];
        if (pos.shares < shares) revert Errors.InsufficientBalance();

        // Lockup check
        if (lockupSeconds > 0 && !pos.isCollateral) {
            if (block.timestamp < pos.depositTimestamp + lockupSeconds) {
                revert Errors.InvalidAmount(); // lockup not elapsed
            }
        }

        // Available check
        uint256 available = totalDeposits - totalAllocated;
        if (amount > available) revert Errors.InsufficientPoolBalance();

        // Update position
        pos.shares -= shares;
        if (pos.depositedAmount >= amount) {
            pos.depositedAmount -= amount;
        } else {
            pos.depositedAmount = 0;
        }

        // Update aggregate
        totalShares -= shares;
        totalDeposits -= amount;
        if (depositorBalances[depositor] >= amount) {
            depositorBalances[depositor] -= amount;
        } else {
            depositorBalances[depositor] = 0;
        }

        // Update tranche
        uint8 tranche = pos.tranche;
        if (tranche == 0 && seniorDeposits >= amount) { seniorDeposits -= amount; seniorShares -= shares; }
        else if (tranche == 1 && mezzDeposits >= amount) { mezzDeposits -= amount; mezzShares -= shares; }
        else if (tranche == 2 && juniorDeposits >= amount) { juniorDeposits -= amount; juniorShares -= shares; }

        usdc.safeTransfer(depositor, amount);
        emit Withdrawn(depositor, shares, amount);
    }

    /// @notice Calculate shares for a deposit. First deposit = 1:1, subsequent = proportional.
    function _calculateShares(uint256 amount) internal view returns (uint256) {
        if (totalShares == 0 || totalDeposits == 0) {
            return amount; // 1:1 initial rate
        }
        return (amount * totalShares) / totalDeposits;
    }

    function _sharesToAmount(uint256 shares) internal view returns (uint256) {
        if (totalShares == 0) return 0;
        return (shares * totalDeposits) / totalShares;
    }

    function _amountToShares(uint256 amount) internal view returns (uint256) {
        if (totalDeposits == 0) return amount;
        return (amount * totalShares) / totalDeposits;
    }

    /// @notice Compute yield owed to a tranche for `elapsed` seconds.
    function _trancheYield(uint256 deposits, uint16 aprBps, uint256 elapsed) internal pure returns (uint256) {
        if (deposits == 0 || elapsed == 0) return 0;
        return (deposits * aprBps * elapsed) / (BPS * SECONDS_PER_YEAR);
    }
}
