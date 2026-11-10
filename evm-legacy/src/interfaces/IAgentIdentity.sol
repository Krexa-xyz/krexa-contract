// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentIdentity {
    struct Reputation {
        uint256 totalTransactions;
        uint256 totalVolumeUsdc;
        uint256 successfulRepayments;
        uint256 defaultCount;
        uint256 firstActiveAt;
        string metadataURI;
    }

    event IdentityMinted(address indexed agent, uint256 indexed tokenId);
    event ReputationUpdated(address indexed agent, uint256 totalTx, uint256 volume, uint256 repayments, uint256 defaults);
    event MetadataUpdated(address indexed agent, string metadataURI);

    function mintIdentity(address agent) external;
    function updateReputation(
        address agent,
        uint256 totalTransactions,
        uint256 totalVolumeUsdc,
        uint256 successfulRepayments,
        uint256 defaultCount
    ) external;
    function setMetadataURI(address agent, string calldata metadataURI) external;
    function computeReputationScore(address agent) external view returns (uint16);
    function getReputation(address agent) external view returns (Reputation memory);
    function hasIdentity(address agent) external view returns (bool);
    function tokenOfAgent(address agent) external view returns (uint256);
}
