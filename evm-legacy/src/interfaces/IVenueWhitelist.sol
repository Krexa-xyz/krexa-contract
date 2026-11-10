// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IVenueWhitelist — Global venue registry (Solana krexa-venue-whitelist parity)
/// @notice Protocol-level whitelist of approved venues (DEXes, launchpads, x402 facilitators,
///         DeFi protocols). AgentWallet checks this before sending funds.
///         Categories: 0=DEX, 1=Launchpad, 2=x402, 3=DeFi.
interface IVenueWhitelist {
    // ─── Structs ─────────────────────────────────────────────────────

    struct Venue {
        address venueAddress;     // contract address on this chain
        bytes32 name;             // 32-byte name (matches Solana [u8;32])
        uint8 category;           // 0=DEX, 1=Launchpad, 2=x402, 3=DeFi
        bool isActive;
        uint256 addedAt;
    }

    // ─── Events ──────────────────────────────────────────────────────

    event VenueAdded(address indexed venue, bytes32 name, uint8 category);
    event VenueDeactivated(address indexed venue);
    event VenueReactivated(address indexed venue);
    event VenueCategoryUpdated(address indexed venue, uint8 oldCategory, uint8 newCategory);

    event AdminTransferProposed(address indexed current, address indexed proposed);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    // ─── Admin Functions ─────────────────────────────────────────────

    function addVenue(address venue, bytes32 name, uint8 category) external;
    function deactivateVenue(address venue) external;
    function reactivateVenue(address venue) external;
    function updateCategory(address venue, uint8 newCategory) external;

    function proposeAdmin(address newAdmin) external;
    function acceptAdmin() external;
    function pause() external;
    function unpause() external;

    // ─── View Functions ──────────────────────────────────────────────

    function isWhitelisted(address venue) external view returns (bool);
    function getVenue(address venue) external view returns (Venue memory);
    function getVenuesByCategory(uint8 category) external view returns (address[] memory);
    function totalVenues() external view returns (uint256);
    function getAllVenues() external view returns (address[] memory);
}
