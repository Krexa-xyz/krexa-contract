// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ILiquidityPool — LP capital management with share math, tranches, yield, insurance
/// @notice Solana krexa-credit-vault parity: share-based deposits, tranche accounting
///         (Senior/Mezzanine/Junior), time-based yield accrual, utilization cap,
///         insurance fund, LP lockup, collateral tracking, and bad debt write-off.
interface ILiquidityPool {
    // ─── Structs ─────────────────────────────────────────────────────

    struct PoolAllocation {
        uint256 amount;
        uint256 returnedAmount;
        uint256 allocatedAt;
        bool active;
    }

    struct DepositPosition {
        uint256 shares;
        uint256 depositedAmount;
        uint256 depositTimestamp;
        uint8 tranche;          // 0=Senior, 1=Mezzanine, 2=Junior
        bool isCollateral;
    }

    // ─── Events ──────────────────────────────────────────────────────

    event Deposited(address indexed depositor, uint256 amount, uint256 shares, uint8 tranche, uint256 totalDeposits);
    event Withdrawn(address indexed depositor, uint256 shares, uint256 amount);
    event CollateralDeposited(address indexed agent, uint256 amount, uint256 shares);
    event CollateralWithdrawn(address indexed agent, uint256 shares, uint256 amount);
    event AllocatedToVault(address indexed vault, uint256 amount);
    event ReturnProcessed(address indexed vault, uint256 amount);
    event YieldDistributed(uint256 seniorYield, uint256 mezzYield, uint256 juniorYield, uint256 insuranceCut);
    event BadDebtWrittenOff(uint256 loss, uint256 insuranceCovered, uint256 lpAbsorbed);
    event InsuranceFundUpdated(uint256 newBalance);

    event PoolPaused();
    event PoolUnpaused();
    event MaxAllocationUpdated(uint256 oldMax, uint256 newMax);
    event UtilizationCapUpdated(uint16 oldCap, uint16 newCap);
    event LockupUpdated(uint256 oldLockup, uint256 newLockup);
    event AdminTransferProposed(address indexed current, address indexed proposed);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    // ─── LP Functions ────────────────────────────────────────────────

    function deposit(uint256 amount) external;
    function depositTranche(uint256 amount, uint8 tranche) external;
    function withdraw(uint256 amount) external;
    function withdrawShares(uint256 shares) external;

    // ─── Collateral Functions ────────────────────────────────────────

    function depositCollateral(address agent, uint256 amount) external;
    function withdrawCollateral(address agent, uint256 shares) external;

    // ─── Admin Functions ─────────────────────────────────────────────

    function allocateToVault(address vault, uint256 amount) external;
    function processReturn(address vault, uint256 amount) external;
    function distributeYield() external;
    function writeOffBadDebt(uint256 loss) external;
    function pause() external;
    function unpause() external;
    function setMaxAllocation(uint256 _max) external;
    function setUtilizationCap(uint16 capBps) external;
    function setLockup(uint256 lockupSeconds) external;
    function proposeAdmin(address _newAdmin) external;
    function acceptAdmin() external;

    // ─── View Functions ──────────────────────────────────────────────

    function getDepositorBalance(address depositor) external view returns (uint256);
    function getDepositorShares(address depositor) external view returns (uint256);
    function getPosition(address depositor) external view returns (DepositPosition memory);
    function sharesToAmount(uint256 shares) external view returns (uint256);
    function amountToShares(uint256 amount) external view returns (uint256);
    function sharePrice() external view returns (uint256);
    function getAllocation(address vault) external view returns (PoolAllocation memory);
    function getTotalDeposits() external view returns (uint256);
    function getAvailableBalance() external view returns (uint256);
    function getAllocatedVaults() external view returns (address[] memory);
    function utilizationBps() external view returns (uint16);
    function insuranceBalance() external view returns (uint256);
}
