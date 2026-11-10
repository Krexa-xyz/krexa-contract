// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IKrexa402Facilitator} from "./interfaces/IKrexa402Facilitator.sol";
import {IPaymentRouter} from "./interfaces/IPaymentRouter.sol";
import {Errors} from "./libraries/Errors.sol";

/// @title Krexa402Facilitator — HTTP 402 payment facilitator for API monetisation
/// @notice Merchants register resources (URLs) with prices. Agents pay per-call
///         via the PaymentRouter. The facilitator takes a configurable fee.
contract Krexa402Facilitator is IKrexa402Facilitator, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    IPaymentRouter public immutable router;
    address public admin;
    address public pendingAdmin;
    uint16 public facilitatorFeeBps; // max 1000 (10%)

    mapping(bytes32 => Resource) private _resources;

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Errors.Unauthorized();
        _;
    }

    constructor(address _usdc, address _router, address _admin, uint16 _feeBps) {
        if (_usdc == address(0) || _router == address(0) || _admin == address(0))
            revert Errors.ZeroAddress();
        if (_feeBps > 1000) revert Errors.FeeTooHigh();

        usdc = IERC20(_usdc);
        router = IPaymentRouter(_router);
        admin = _admin;
        facilitatorFeeBps = _feeBps;
    }

    // ─── Resource Management ─────────────────────────────────────

    /// @notice Register a URL/API resource with a price. Hash is bound to msg.sender
    ///         to prevent front-running (different callers get different keys).
    function registerResource(bytes32 resourceHash, uint256 pricePerCall) external {
        if (pricePerCall == 0) revert Errors.InvalidAmount();
        bytes32 key = keccak256(abi.encode(resourceHash, msg.sender));
        Resource storage res = _resources[key];
        if (res.owner != address(0)) revert Errors.VaultAlreadyExists(); // resource exists
        res.owner = msg.sender;
        res.pricePerCall = pricePerCall;
        res.active = true;
        emit ResourceRegistered(key, msg.sender, pricePerCall);
    }

    /// @notice Compute the storage key for a resource (hash + owner).
    function resourceKey(bytes32 resourceHash, address owner) external pure returns (bytes32) {
        return keccak256(abi.encode(resourceHash, owner));
    }

    /// @notice Update price — only resource owner
    function updateResourcePrice(bytes32 resourceHash, uint256 newPrice) external {
        Resource storage res = _resources[resourceHash];
        if (res.owner != msg.sender) revert Errors.Unauthorized();
        if (newPrice == 0) revert Errors.InvalidAmount();
        res.pricePerCall = newPrice;
        emit ResourceUpdated(resourceHash, newPrice);
    }

    /// @notice Deactivate resource — owner or admin
    function deactivateResource(bytes32 resourceHash) external {
        Resource storage res = _resources[resourceHash];
        if (res.owner != msg.sender && msg.sender != admin) revert Errors.Unauthorized();
        res.active = false;
        emit ResourceDeactivated(resourceHash);
    }

    // ─── x402 Payment Execution ──────────────────────────────────

    /// @notice Execute an x402 payment for a registered resource.
    ///         The payment.amount must be >= resource price.
    ///         Facilitator fee is deducted, remainder forwarded via PaymentRouter.
    function executeX402Payment(
        bytes32 resourceHash,
        IPaymentRouter.X402Payment calldata payment,
        bytes calldata /* signature — kept for interface compat */
    ) external nonReentrant {
        if (msg.sender != payment.from) revert Errors.Unauthorized(); // payer must be caller
        Resource storage res = _resources[resourceHash];
        if (!res.active) revert Errors.SettlementNotActive();
        if (payment.amount < res.pricePerCall) revert Errors.InvalidAmount();
        if (payment.to != res.owner) revert Errors.Unauthorized(); // payment must go to resource owner

        // Calculate facilitator fee
        uint256 fee = (payment.amount * facilitatorFeeBps) / 10_000;

        // Pull full amount from payer
        usdc.safeTransferFrom(payment.from, address(this), payment.amount);

        // Send fee to admin (facilitator fee)
        if (fee > 0) {
            usdc.safeTransfer(admin, fee);
        }

        // Forward remainder through PaymentRouter via facilitated path (no sig check)
        uint256 routerAmount = payment.amount - fee;
        usdc.forceApprove(address(router), routerAmount);

        // Build payment preserving original payer for stats tracking
        IPaymentRouter.X402Payment memory routerPayment = IPaymentRouter.X402Payment({
            from: payment.from,     // original payer for stats
            to: payment.to,
            amount: routerAmount,
            nonce: payment.nonce,
            deadline: payment.deadline,
            paymentId: payment.paymentId
        });

        router.executeFacilitatedPayment(routerPayment);

        emit X402PaymentExecuted(
            resourceHash,
            payment.from,
            res.owner,
            payment.amount,
            fee,
            payment.paymentId
        );
    }

    // ─── Admin ───────────────────────────────────────────────────

    function setFacilitatorFeeBps(uint16 newFeeBps) external onlyAdmin {
        if (newFeeBps > 1000) revert Errors.FeeTooHigh();
        uint16 old = facilitatorFeeBps;
        facilitatorFeeBps = newFeeBps;
        emit FacilitatorFeeUpdated(old, newFeeBps);
    }

    // ─── Resource Reactivation ──────────────────────────────────

    function reactivateResource(bytes32 resourceHash) external {
        Resource storage res = _resources[resourceHash];
        if (res.owner != msg.sender) revert Errors.Unauthorized();
        res.active = true;
        emit ResourceRegistered(resourceHash, msg.sender, res.pricePerCall);
    }

    // ─── Admin Transfer ───────────────────────────────────────

    function proposeAdmin(address _newAdmin) external onlyAdmin {
        if (_newAdmin == address(0)) revert Errors.ZeroAddress();
        pendingAdmin = _newAdmin;
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert Errors.Unauthorized();
        address old = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit FacilitatorFeeUpdated(0, 0); // reuse event for admin change notification
    }

    // ─── View ────────────────────────────────────────────────────

    function getResource(bytes32 resourceHash) external view returns (Resource memory) {
        return _resources[resourceHash];
    }
}
