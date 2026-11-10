// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MerchantVault} from "./MerchantVault.sol";
import {IAgentRegistry} from "./interfaces/IAgentRegistry.sol";
import {IPaymentRouter} from "./interfaces/IPaymentRouter.sol";
import {Errors} from "./libraries/Errors.sol";

/// @title VaultFactory — CREATE2 deployer + platform config
/// @notice Deploys MerchantVault per borrowing agent, links registry + router
contract VaultFactory {
    struct PlatformConfig {
        address admin;
        address oracle;
        address usdc;
        uint16 defaultFeeBps;
        address feeRecipient;
        bool paused;
    }

    PlatformConfig public config;
    IAgentRegistry public registry;
    IPaymentRouter public router;

    address[] public allVaults;
    mapping(address => address) public agentToVault;

    address public pendingAdmin;

    event VaultCreated(
        address indexed agent,
        address indexed vault,
        uint256 targetAmount,
        uint256 interestRateBps,
        uint256 durationSeconds
    );
    event PlatformConfigUpdated();
    event PlatformPausedEvent();
    event PlatformUnpausedEvent();
    event AdminTransferProposed(address indexed current, address indexed proposed);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    modifier onlyAdmin() {
        if (msg.sender != config.admin) revert Errors.Unauthorized();
        _;
    }

    modifier notPaused() {
        if (config.paused) revert Errors.PlatformPaused();
        _;
    }

    constructor(
        address _admin,
        address _oracle,
        address _usdc,
        uint16 _defaultFeeBps,
        address _feeRecipient,
        address _registry,
        address _router
    ) {
        if (_admin == address(0) || _usdc == address(0) || _registry == address(0) || _router == address(0))
            revert Errors.ZeroAddress();

        config = PlatformConfig({
            admin: _admin,
            oracle: _oracle,
            usdc: _usdc,
            defaultFeeBps: _defaultFeeBps,
            feeRecipient: _feeRecipient,
            paused: false
        });
        registry = IAgentRegistry(_registry);
        router = IPaymentRouter(_router);
    }

    // ─── Create Vault ────────────────────────────────────────────

    function createVault(
        address agent,
        uint256 targetAmount,
        uint256 interestRateBps,
        uint256 durationSeconds,
        uint256 numTranches,
        uint16 repaymentRateBps,
        uint64 minPaymentInterval,
        uint256 maxSinglePayment,
        uint16 lateFeeBps,
        uint256 gracePeriodSeconds,
        uint256 fundraisingDeadline
    ) external onlyAdmin notPaused returns (address vault) {
        if (!registry.isRegistered(agent)) revert Errors.AgentNotRegistered();
        if (agentToVault[agent] != address(0)) revert Errors.VaultAlreadyExists();
        if (targetAmount == 0) revert Errors.InvalidAmount();
        if (interestRateBps > 5000) revert Errors.FeeTooHigh(); // max 50%
        if (durationSeconds < 7 days || durationSeconds > 730 days) revert Errors.InvalidAmount();

        // Credit level gating: require valid score and level >= L1
        if (!registry.isCreditValid(agent)) revert Errors.CreditScoreExpired();
        IAgentRegistry.CreditLevel level = registry.getCreditLevel(agent);
        if (level == IAgentRegistry.CreditLevel.L0) revert Errors.CreditTierTooLow();

        // CREATE2 deploy with agent as sole salt (one vault per agent enforced above)
        bytes32 salt = keccak256(abi.encodePacked(agent));

        vault = address(
            new MerchantVault{salt: salt}(
                MerchantVault.VaultParams({
                    usdc: config.usdc,
                    agent: agent,
                    admin: config.admin,
                    factory: address(this),
                    targetAmount: targetAmount,
                    interestRateBps: interestRateBps,
                    durationSeconds: durationSeconds,
                    numTranches: numTranches,
                    platformFeeBps: config.defaultFeeBps,
                    platformFeeRecipient: config.feeRecipient,
                    lateFeeBps: lateFeeBps,
                    gracePeriodSeconds: gracePeriodSeconds,
                    fundraisingDeadline: fundraisingDeadline
                })
            )
        );

        allVaults.push(vault);
        agentToVault[agent] = vault;

        // Link vault in registry
        registry.linkVault(agent, vault);

        // Create settlement in router
        router.createSettlement(agent, vault, repaymentRateBps, minPaymentInterval, maxSinglePayment);

        emit VaultCreated(agent, vault, targetAmount, interestRateBps, durationSeconds);
    }

    // ─── Predicted Address ───────────────────────────────────────

    function predictVaultAddress(
        address agent,
        uint256 targetAmount,
        uint256 interestRateBps,
        uint256 durationSeconds,
        uint256 numTranches,
        uint16 lateFeeBps,
        uint256 gracePeriodSeconds,
        uint256 fundraisingDeadline
    ) external view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(agent));
        MerchantVault.VaultParams memory p = MerchantVault.VaultParams({
            usdc: config.usdc,
            agent: agent,
            admin: config.admin,
            factory: address(this),
            targetAmount: targetAmount,
            interestRateBps: interestRateBps,
            durationSeconds: durationSeconds,
            numTranches: numTranches,
            platformFeeBps: config.defaultFeeBps,
            platformFeeRecipient: config.feeRecipient,
            lateFeeBps: lateFeeBps,
            gracePeriodSeconds: gracePeriodSeconds,
            fundraisingDeadline: fundraisingDeadline
        });
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(
                    abi.encodePacked(
                        type(MerchantVault).creationCode,
                        abi.encode(p)
                    )
                )
            )
        );
        return address(uint160(uint256(hash)));
    }

    // ─── Admin ───────────────────────────────────────────────────

    function setOracle(address _oracle) external onlyAdmin {
        config.oracle = _oracle;
        emit PlatformConfigUpdated();
    }

    function setPlatformFee(uint16 _feeBps) external onlyAdmin {
        if (_feeBps > 1000) revert Errors.FeeTooHigh(); // max 10%
        config.defaultFeeBps = _feeBps;
        emit PlatformConfigUpdated();
    }

    function setFeeRecipient(address _recipient) external onlyAdmin {
        if (_recipient == address(0)) revert Errors.ZeroAddress();
        config.feeRecipient = _recipient;
        emit PlatformConfigUpdated();
    }

    function pausePlatform() external onlyAdmin {
        config.paused = true;
        emit PlatformPausedEvent();
    }

    function unpausePlatform() external onlyAdmin {
        config.paused = false;
        emit PlatformUnpausedEvent();
    }

    function proposeAdmin(address _newAdmin) external onlyAdmin {
        if (_newAdmin == address(0)) revert Errors.ZeroAddress();
        pendingAdmin = _newAdmin;
        emit AdminTransferProposed(config.admin, _newAdmin);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert Errors.Unauthorized();
        address old = config.admin;
        config.admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferred(old, config.admin);
    }

    // ─── View ────────────────────────────────────────────────────

    function getAllVaults() external view returns (address[] memory) {
        return allVaults;
    }

    function getVaultCount() external view returns (uint256) {
        return allVaults.length;
    }

    function getOracle() external view returns (address) {
        return config.oracle;
    }
}
