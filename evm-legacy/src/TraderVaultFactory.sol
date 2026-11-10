// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TraderVault} from "./TraderVault.sol";
import {IAgentRegistry} from "./interfaces/IAgentRegistry.sol";
import {Errors} from "./libraries/Errors.sol";

/// @title TraderVaultFactory — Deploys TraderVault per Polymarket trader
/// @notice One vault per trader. Credit limit set by credit tier from AgentRegistry.
contract TraderVaultFactory {

    // ─── Credit limits by tier (USDC, 6 decimals) ─────────────────
    // Tier D: blocked
    // Tier C (score 450-599): $5,000 USDC
    // Tier B (score 600-749): $25,000 USDC
    // Tier A (score 750+):    $100,000 USDC
    uint256 public constant CREDIT_LIMIT_C =    5_000e6;
    uint256 public constant CREDIT_LIMIT_B =   25_000e6;
    uint256 public constant CREDIT_LIMIT_A =  100_000e6;
    uint256 public constant DEFAULT_INTEREST_BPS = 1500; // 15% APY

    // ─── State ─────────────────────────────────────────────────────

    address public admin;
    address public pendingAdmin;
    address public immutable usdc;
    IAgentRegistry public immutable registry;

    address[] public allVaults;
    mapping(address => address) public traderToVault;

    bool public paused;

    // ─── Events ────────────────────────────────────────────────────

    event TraderVaultCreated(
        address indexed trader,
        address indexed vault,
        uint256 creditLimit,
        string  tier
    );
    event AdminTransferProposed(address indexed current, address indexed proposed);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event Paused();
    event Unpaused();

    // ─── Modifiers ─────────────────────────────────────────────────

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Errors.Unauthorized();
        _;
    }

    modifier notPaused() {
        if (paused) revert Errors.PlatformPaused();
        _;
    }

    // ─── Constructor ───────────────────────────────────────────────

    constructor(address _admin, address _usdc, address _registry) {
        if (_admin == address(0) || _usdc == address(0) || _registry == address(0))
            revert Errors.ZeroAddress();
        admin    = _admin;
        usdc     = _usdc;
        registry = IAgentRegistry(_registry);
    }

    // ─── Vault Creation ────────────────────────────────────────────

    /// @notice Deploy a TraderVault for msg.sender
    /// @dev Requires agent registered + credit tier >= C + no existing vault
    function createVault() external notPaused returns (address vault) {
        address trader = msg.sender;

        // Must be registered
        IAgentRegistry.Agent memory agent = registry.getAgent(trader);
        if (agent.registeredAt == 0) revert Errors.AgentNotRegistered();

        // Must have valid credit
        if (!registry.isCreditValid(trader)) revert Errors.CreditScoreExpired();

        // Determine credit limit from level
        IAgentRegistry.CreditLevel level = registry.getCreditLevel(trader);
        (uint256 creditLimit, string memory tierLabel) = _limitForLevel(level);
        if (creditLimit == 0) revert Errors.CreditTierTooLow();

        // One vault per trader
        if (traderToVault[trader] != address(0)) revert Errors.VaultAlreadyExists();

        // Deploy with CREATE2 (salt = trader address)
        bytes32 salt = bytes32(uint256(uint160(trader)));
        vault = address(new TraderVault{salt: salt}(
            trader,
            usdc,
            admin,
            creditLimit,
            DEFAULT_INTEREST_BPS
        ));

        traderToVault[trader] = vault;
        allVaults.push(vault);

        emit TraderVaultCreated(trader, vault, creditLimit, tierLabel);
    }

    /// @notice Predict vault address for a trader (before deployment)
    function predictVaultAddress(address trader) external view returns (address) {
        bytes32 salt      = bytes32(uint256(uint160(trader)));
        bytes32 bytesHash = keccak256(abi.encodePacked(
            type(TraderVault).creationCode,
            abi.encode(trader, usdc, admin, CREDIT_LIMIT_C, DEFAULT_INTEREST_BPS)
        ));
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            bytesHash
        )))));
    }

    // ─── View ───────────────────────────────────────────────────────

    function allVaultsLength() external view returns (uint256) {
        return allVaults.length;
    }

    function getVaults(uint256 start, uint256 count) external view returns (address[] memory) {
        uint256 total = allVaults.length;
        if (start >= total) return new address[](0);
        uint256 end = start + count > total ? total : start + count;
        address[] memory result = new address[](end - start);
        for (uint256 i = start; i < end; i++) {
            result[i - start] = allVaults[i];
        }
        return result;
    }

    // ─── Admin ─────────────────────────────────────────────────────

    function pause() external onlyAdmin { paused = true; emit Paused(); }
    function unpause() external onlyAdmin { paused = false; emit Unpaused(); }

    function proposeAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert Errors.ZeroAddress();
        pendingAdmin = newAdmin;
        emit AdminTransferProposed(admin, newAdmin);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert Errors.Unauthorized();
        address old = admin;
        admin        = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferred(old, admin);
    }

    // ─── Internal ──────────────────────────────────────────────────

    function _limitForLevel(IAgentRegistry.CreditLevel level)
        internal pure returns (uint256 limit, string memory label)
    {
        if (level == IAgentRegistry.CreditLevel.L4) return (CREDIT_LIMIT_A, "L4");
        if (level == IAgentRegistry.CreditLevel.L3) return (CREDIT_LIMIT_B, "L3");
        if (level == IAgentRegistry.CreditLevel.L2) return (CREDIT_LIMIT_C, "L2");
        if (level == IAgentRegistry.CreditLevel.L1) return (CREDIT_LIMIT_C, "L1");
        return (0, "L0");
    }
}
