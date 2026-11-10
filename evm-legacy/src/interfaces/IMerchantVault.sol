// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMerchantVault — Per-agent credit vault with continuous interest accrual,
///        tranche yield waterfall, insurance fund, and credit freeze.
/// @notice Solana krexa-credit-vault parity: per-second accrual, protocol fee,
///         tranche APR yields (Senior 8% / Mezz 12% / Junior 20%),
///         surplus split (insurance/treasury), credit freeze.
interface IMerchantVault {
    enum VaultState {
        Fundraising,
        Active,
        Repaying,
        Completed,
        Defaulted,
        Cancelled
    }

    // ─── Events ──────────────────────────────────────────────────────

    event Invested(address indexed investor, uint256 amount, uint256 totalRaised);
    event TrancheReleased(uint256 indexed trancheNum, uint256 amount, address indexed agent);
    event RepaymentProcessed(uint256 amount, uint256 seniorPay, uint256 poolPay, uint256 communityPay);
    event WaterfallDistributed(uint256 seniorPayment, uint256 poolPayment, uint256 communityPayment);
    event ReturnsClaimed(address indexed investor, uint256 amount);
    event VaultStateChanged(VaultState oldState, VaultState newState);
    event VaultPaused();
    event VaultUnpaused();
    event VaultDefaulted(uint256 timestamp);
    event VaultCancelled(uint256 timestamp);
    event LateFeeApplied(uint256 feeAmount, uint256 totalLateFees);
    event PaymentRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event AdminTransferProposed(address indexed current, address indexed proposed);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    // Solana-parity events
    event InterestAccrued(uint256 newInterest, uint256 totalAccrued);
    event InsuranceFunded(uint256 protocolFee, uint256 surplusCut, uint256 newBalance);
    event TranchYieldDistributed(uint256 seniorYield, uint256 poolYield, uint256 communityYield, uint256 surplus);
    event CreditFrozen(bool frozen);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    // ─── Investor Functions ──────────────────────────────────────────

    function invest(uint256 amount) external;
    function investSenior(uint256 amount) external;
    function investFromPool(uint256 amount) external;
    function claimReturns() external;
    function claimRefund() external;

    // ─── Repayment ──────────────────────────────────────────────────

    function processRepayment(uint256 amount) external;
    function accrueInterest() external;

    // ─── Lifecycle ──────────────────────────────────────────────────

    function releaseTranche() external;
    function markDefault() external;
    function autoCancelExpired() external;
    function completeFundraisingManual() external;
    function cancel() external;

    // ─── Admin ──────────────────────────────────────────────────────

    function pause() external;
    function unpause() external;
    function freezeCredit() external;
    function unfreezeCredit() external;
    function setPaymentRouter(address _router) external;
    function setMilestoneRegistry(address _milestoneRegistry) external;
    function setTreasury(address _treasury) external;
    function proposeAdmin(address _newAdmin) external;
    function acceptAdmin() external;

    // ─── View Functions ─────────────────────────────────────────────

    function getAgent() external view returns (address);
    function getState() external view returns (VaultState);
    function getTotalRaised() external view returns (uint256);
    function getTotalRepaid() external view returns (uint256);
    function getTotalToRepay() external view returns (uint256);
    function getInvestorBalance(address investor) external view returns (uint256);
    function getClaimable(address investor) external view returns (uint256);
    function getInvestors() external view returns (address[] memory);
    function getWaterfallState() external view returns (
        uint256 seniorFunded,
        uint256 poolFunded,
        uint256 userFunded,
        uint256 seniorRepaid,
        uint256 poolRepaid,
        uint256 communityRepaid
    );
    function calculateLateFee() external view returns (uint256);
    function shouldDefault() external view returns (bool);

    // Solana-parity views
    function accruedInterest() external view returns (uint256);
    function creditDrawn() external view returns (uint256);
    function totalDebt() external view returns (uint256);
    function insuranceBalance() external view returns (uint256);
    function isFrozen() external view returns (bool);
    function treasury() external view returns (address);
    function seniorAprBps() external view returns (uint16);
    function poolAprBps() external view returns (uint16);
    function communityAprBps() external view returns (uint16);
}
