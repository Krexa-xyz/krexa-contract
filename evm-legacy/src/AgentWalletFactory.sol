// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AgentWallet} from "./AgentWallet.sol";
import {IAgentRegistry} from "./interfaces/IAgentRegistry.sol";
import {Errors} from "./libraries/Errors.sol";

/// @title AgentWalletFactory — deploy deterministic AgentWallet instances
/// @notice One wallet per owner. Uses CREATE2 for predictable addresses.
///         Links wallet to AgentRegistry on creation.
contract AgentWalletFactory {
    address public immutable usdc;
    address public immutable registryAddr;
    address public admin;
    address public pendingAdmin;

    mapping(address => address) public ownerToWallet;
    address[] public allWallets;

    event WalletCreated(address indexed owner, address indexed operator, address wallet);
    event AdminTransferProposed(address indexed current, address indexed proposed);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Errors.Unauthorized();
        _;
    }

    constructor(address _usdc, address _registry, address _admin) {
        if (_usdc == address(0) || _admin == address(0) || _registry == address(0)) {
            revert Errors.ZeroAddress();
        }
        usdc = _usdc;
        registryAddr = _registry;
        admin = _admin;
    }

    /// @notice Create a new AgentWallet for the caller
    function createWallet(
        address operator,
        uint256 dailyLimit,
        uint256 perTxLimit
    ) external returns (address) {
        if (ownerToWallet[msg.sender] != address(0)) revert Errors.VaultAlreadyExists();

        bytes32 salt = keccak256(abi.encode(msg.sender));
        AgentWallet wallet = new AgentWallet{salt: salt}(
            usdc,
            registryAddr,
            msg.sender,
            operator,
            dailyLimit,
            perTxLimit
        );

        address walletAddr = address(wallet);
        ownerToWallet[msg.sender] = walletAddr;
        allWallets.push(walletAddr);

        // Link wallet in registry (if factory is authorized)
        try IAgentRegistry(registryAddr).linkWallet(msg.sender, walletAddr) {} catch {}

        emit WalletCreated(msg.sender, operator, walletAddr);
        return walletAddr;
    }

    /// @notice Predict wallet address for a given owner (must match createWallet args)
    function predictWalletAddress(
        address owner_,
        address operator,
        uint256 _dailyLimit,
        uint256 _perTxLimit
    ) external view returns (address) {
        bytes32 salt = keccak256(abi.encode(owner_));
        bytes memory bytecode = abi.encodePacked(
            type(AgentWallet).creationCode,
            abi.encode(usdc, registryAddr, owner_, operator, _dailyLimit, _perTxLimit)
        );
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode))
        );
        return address(uint160(uint256(hash)));
    }

    function getAllWallets() external view returns (address[] memory) {
        return allWallets;
    }

    function totalWallets() external view returns (uint256) {
        return allWallets.length;
    }

    // ─── Admin Transfer ───────────────────────────────────────

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

    // ─── Paginated View ───────────────────────────────────────

    function getWallets(uint256 offset, uint256 limit) external view returns (address[] memory) {
        uint256 end = offset + limit;
        if (end > allWallets.length) end = allWallets.length;
        if (offset >= allWallets.length) return new address[](0);
        address[] memory result = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = allWallets[i];
        }
        return result;
    }
}
