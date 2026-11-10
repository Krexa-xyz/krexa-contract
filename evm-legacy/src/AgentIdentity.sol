// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IAgentIdentity} from "./interfaces/IAgentIdentity.sol";
import {Errors} from "./libraries/Errors.sol";

/// @title AgentIdentity — Soulbound NFT for AI agent reputation
/// @notice Non-transferable ERC721. One per agent. Tracks on-chain reputation metrics.
/// @dev Score: 40% volume + 30% repayments + 20% account age - 10% defaults
contract AgentIdentity is IAgentIdentity, ERC721 {
    address public admin;
    address public pendingAdmin;
    uint256 private _nextTokenId;

    mapping(address => Reputation) private _reputations;
    mapping(address => uint256) private _agentToToken;
    mapping(uint256 => address) private _tokenToAgent;

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Errors.Unauthorized();
        _;
    }

    constructor(address _admin) ERC721("Krexa Agent Identity", "KREXA-ID") {
        if (_admin == address(0)) revert Errors.ZeroAddress();
        admin = _admin;
        _nextTokenId = 1;
    }

    // ─── Soulbound: block all transfers ──────────────────────────

    function transferFrom(address, address, uint256) public pure override {
        revert Errors.Unauthorized();
    }

    function safeTransferFrom(address, address, uint256, bytes memory) public pure override {
        revert Errors.Unauthorized();
    }

    function approve(address, uint256) public pure override {
        revert Errors.Unauthorized();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert Errors.Unauthorized();
    }

    // ─── Mint ────────────────────────────────────────────────────

    /// @notice Mint identity NFT for an agent. One per agent.
    function mintIdentity(address agent) external onlyAdmin {
        if (agent == address(0)) revert Errors.ZeroAddress();
        if (_agentToToken[agent] != 0) revert Errors.AgentAlreadyRegistered();

        uint256 tokenId = _nextTokenId++;
        _mint(agent, tokenId);

        _agentToToken[agent] = tokenId;
        _tokenToAgent[tokenId] = agent;
        _reputations[agent].firstActiveAt = block.timestamp;

        emit IdentityMinted(agent, tokenId);
    }

    // ─── Reputation Management (Admin) ───────────────────────────

    function updateReputation(
        address agent,
        uint256 totalTransactions,
        uint256 totalVolumeUsdc,
        uint256 successfulRepayments,
        uint256 defaultCount
    ) external onlyAdmin {
        if (_agentToToken[agent] == 0) revert Errors.AgentNotRegistered();

        Reputation storage rep = _reputations[agent];
        rep.totalTransactions = totalTransactions;
        rep.totalVolumeUsdc = totalVolumeUsdc;
        rep.successfulRepayments = successfulRepayments;
        rep.defaultCount = defaultCount;

        emit ReputationUpdated(agent, totalTransactions, totalVolumeUsdc, successfulRepayments, defaultCount);
    }

    function setMetadataURI(address agent, string calldata metadataURI) external onlyAdmin {
        if (_agentToToken[agent] == 0) revert Errors.AgentNotRegistered();
        _reputations[agent].metadataURI = metadataURI;
        emit MetadataUpdated(agent, metadataURI);
    }

    // ─── Score Computation ───────────────────────────────────────

    /// @notice Compute reputation score (0-1000)
    /// @dev Score = 40% volume + 30% repayments + 20% age - 10% defaults
    function computeReputationScore(address agent) external view returns (uint16) {
        Reputation storage rep = _reputations[agent];
        if (_agentToToken[agent] == 0) return 0;

        // Volume score (0-400): caps at $100k
        uint256 volumeScore = rep.totalVolumeUsdc >= 100_000e6
            ? 400
            : (rep.totalVolumeUsdc * 400) / 100_000e6;

        // Repayment score (0-300): caps at 50 successful repayments
        uint256 repaymentScore = rep.successfulRepayments >= 50
            ? 300
            : (rep.successfulRepayments * 300) / 50;

        // Age score (0-200): caps at 365 days
        uint256 age = block.timestamp - rep.firstActiveAt;
        uint256 ageScore = age >= 365 days
            ? 200
            : (age * 200) / 365 days;

        // Default penalty (0-100): each default costs 20 points
        uint256 defaultPenalty = rep.defaultCount * 20;
        if (defaultPenalty > 100) defaultPenalty = 100;

        uint256 total = volumeScore + repaymentScore + ageScore;
        if (total <= defaultPenalty) return 0;
        total -= defaultPenalty;
        if (total > 1000) total = 1000;

        return uint16(total);
    }

    // ─── View ────────────────────────────────────────────────────

    function getReputation(address agent) external view returns (Reputation memory) {
        return _reputations[agent];
    }

    function hasIdentity(address agent) external view returns (bool) {
        return _agentToToken[agent] != 0;
    }

    function tokenOfAgent(address agent) external view returns (uint256) {
        return _agentToToken[agent];
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
        emit IdentityMinted(address(0), 0); // signal admin change (no dedicated event)
    }
}
