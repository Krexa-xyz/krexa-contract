// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title TraderVault — Revolving USDC credit line for Polymarket traders
/// @notice No tranches, no fundraising phase. Trader draws USDC and repays from winnings.
contract TraderVault {
    using SafeERC20 for IERC20;

    // ─── State ─────────────────────────────────────────────────────

    address public immutable trader;
    address public immutable usdc;
    address public immutable factory;
    address public admin;

    uint256 public creditLimit;       // max drawable (6 decimals, USDC)
    uint256 public drawn;             // currently outstanding
    uint256 public totalRepaid;
    uint256 public totalDrawn;
    uint256 public interestRateBps;   // annual rate, e.g. 1500 = 15%
    uint256 public activatedAt;
    bool    public frozen;

    // ─── Events ────────────────────────────────────────────────────

    event Drew(address indexed trader, uint256 amount, uint256 totalDrawn);
    event Repaid(address indexed trader, uint256 amount, uint256 remaining);
    event Frozen(address indexed byAdmin);
    event Unfrozen(address indexed byAdmin);
    event Funded(address indexed funder, uint256 amount);

    // ─── Errors ────────────────────────────────────────────────────

    error Unauthorized();
    error VaultFrozen();
    error ExceedsCreditLimit();
    error ZeroAmount();
    error InsufficientBalance();
    error ZeroAddress();

    // ─── Modifiers ─────────────────────────────────────────────────

    modifier onlyTrader() {
        if (msg.sender != trader) revert Unauthorized();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin && msg.sender != factory) revert Unauthorized();
        _;
    }

    modifier notFrozen() {
        if (frozen) revert VaultFrozen();
        _;
    }

    // ─── Constructor ───────────────────────────────────────────────

    constructor(
        address _trader,
        address _usdc,
        address _admin,
        uint256 _creditLimit,
        uint256 _interestRateBps
    ) {
        if (_trader == address(0) || _usdc == address(0) || _admin == address(0)) revert ZeroAddress();
        trader          = _trader;
        usdc            = _usdc;
        factory         = msg.sender;
        admin           = _admin;
        creditLimit     = _creditLimit;
        interestRateBps = _interestRateBps;
        activatedAt     = block.timestamp;
    }

    // ─── Core Functions ────────────────────────────────────────────

    /// @notice Fund the vault with USDC (called by factory/investors)
    function fund(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    /// @notice Trader draws USDC from their credit line
    function draw(uint256 amount) external onlyTrader notFrozen {
        if (amount == 0) revert ZeroAmount();
        if (drawn + amount > creditLimit) revert ExceedsCreditLimit();
        uint256 balance = IERC20(usdc).balanceOf(address(this));
        if (balance < amount) revert InsufficientBalance();

        drawn      += amount;
        totalDrawn += amount;

        IERC20(usdc).safeTransfer(trader, amount);
        emit Drew(trader, amount, totalDrawn);
    }

    /// @notice Trader repays USDC to the vault
    function repay(uint256 amount) external notFrozen {
        if (amount == 0) revert ZeroAmount();

        IERC20(usdc).safeTransferFrom(msg.sender, address(this), amount);

        uint256 repayPrincipal = amount > drawn ? drawn : amount;
        drawn        -= repayPrincipal;
        totalRepaid  += amount;

        emit Repaid(trader, amount, drawn);
    }

    /// @notice Admin freezes vault (risk control)
    function freeze() external onlyAdmin {
        frozen = true;
        emit Frozen(msg.sender);
    }

    /// @notice Admin unfreezes vault
    function unfreeze() external onlyAdmin {
        frozen = false;
        emit Unfrozen(msg.sender);
    }

    /// @notice Admin updates credit limit
    function setCreditLimit(uint256 newLimit) external onlyAdmin {
        creditLimit = newLimit;
    }

    // ─── View Functions ────────────────────────────────────────────

    /// @notice Utilization as a percentage (0-10000 bps)
    function getUtilization() external view returns (uint256) {
        if (creditLimit == 0) return 0;
        return (drawn * 10_000) / creditLimit;
    }

    /// @notice Available amount the trader can still draw
    function available() external view returns (uint256) {
        if (drawn >= creditLimit) return 0;
        uint256 remaining = creditLimit - drawn;
        uint256 balance   = IERC20(usdc).balanceOf(address(this));
        return remaining < balance ? remaining : balance;
    }

    /// @notice Accrued interest since activation (simple annual interest)
    function accruedInterest() external view returns (uint256) {
        if (totalDrawn == 0 || activatedAt == 0) return 0;
        uint256 elapsed = block.timestamp - activatedAt;
        // interest = drawn * rate * elapsed / (365 days * 10000)
        return (drawn * interestRateBps * elapsed) / (365 days * 10_000);
    }
}
