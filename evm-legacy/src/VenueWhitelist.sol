// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVenueWhitelist} from "./interfaces/IVenueWhitelist.sol";
import {Errors} from "./libraries/Errors.sol";

/// @title VenueWhitelist — Global venue registry (Solana krexa-venue-whitelist parity)
/// @notice Protocol-level whitelist of approved trading venues. AgentWallet's transfer()
///         can check this contract before sending funds. Categories match Solana:
///         0=DEX, 1=Launchpad, 2=x402, 3=DeFi.
contract VenueWhitelist is IVenueWhitelist {
    // ─── Constants ─────────────────────────────────────────────────────

    uint8 public constant MAX_CATEGORY = 3;

    // ─── Storage ───────────────────────────────────────────────────────

    mapping(address => Venue) private _venues;
    address[] private _allVenues;

    // Category → list of venue addresses (for enumeration)
    mapping(uint8 => address[]) private _venuesByCategory;
    // Track index in _venuesByCategory for removal
    mapping(address => uint256) private _categoryIndex;

    address public admin;
    address public pendingAdmin;
    bool public isPaused;

    // ─── Modifiers ─────────────────────────────────────────────────────

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Errors.Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (isPaused) revert Errors.PlatformPaused();
        _;
    }

    // ─── Constructor ───────────────────────────────────────────────────

    constructor(address _admin) {
        if (_admin == address(0)) revert Errors.ZeroAddress();
        admin = _admin;
    }

    // ═══════════════════════════════════════════════════════════════════
    // ADMIN: Venue Management
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Add a venue to the global whitelist.
    function addVenue(address venue, bytes32 name, uint8 category)
        external
        onlyAdmin
        whenNotPaused
    {
        if (venue == address(0)) revert Errors.ZeroAddress();
        if (category > MAX_CATEGORY) revert Errors.InvalidAmount();
        if (_venues[venue].addedAt != 0) revert Errors.VaultAlreadyExists();

        _venues[venue] = Venue({
            venueAddress: venue,
            name: name,
            category: category,
            isActive: true,
            addedAt: block.timestamp
        });

        _allVenues.push(venue);

        // Track in category list
        _categoryIndex[venue] = _venuesByCategory[category].length;
        _venuesByCategory[category].push(venue);

        emit VenueAdded(venue, name, category);
    }

    /// @notice Deactivate a venue (remains in storage, just inactive).
    function deactivateVenue(address venue)
        external
        onlyAdmin
        whenNotPaused
    {
        Venue storage v = _venues[venue];
        if (v.addedAt == 0) revert Errors.InvalidAmount();
        if (!v.isActive) revert Errors.VaultAlreadyPaused();

        v.isActive = false;
        emit VenueDeactivated(venue);
    }

    /// @notice Reactivate a previously deactivated venue.
    function reactivateVenue(address venue)
        external
        onlyAdmin
        whenNotPaused
    {
        Venue storage v = _venues[venue];
        if (v.addedAt == 0) revert Errors.InvalidAmount();
        if (v.isActive) revert Errors.AgentAlreadyActive();

        v.isActive = true;
        emit VenueReactivated(venue);
    }

    /// @notice Update a venue's category.
    function updateCategory(address venue, uint8 newCategory)
        external
        onlyAdmin
    {
        if (newCategory > MAX_CATEGORY) revert Errors.InvalidAmount();
        Venue storage v = _venues[venue];
        if (v.addedAt == 0) revert Errors.InvalidAmount();

        uint8 oldCategory = v.category;
        if (oldCategory == newCategory) return;

        // Remove from old category list (swap-and-pop)
        address[] storage oldList = _venuesByCategory[oldCategory];
        uint256 idx = _categoryIndex[venue];
        uint256 lastIdx = oldList.length - 1;
        if (idx != lastIdx) {
            address lastVenue = oldList[lastIdx];
            oldList[idx] = lastVenue;
            _categoryIndex[lastVenue] = idx;
        }
        oldList.pop();

        // Add to new category list
        _categoryIndex[venue] = _venuesByCategory[newCategory].length;
        _venuesByCategory[newCategory].push(venue);

        v.category = newCategory;
        emit VenueCategoryUpdated(venue, oldCategory, newCategory);
    }

    // ═══════════════════════════════════════════════════════════════════
    // ADMIN: Config
    // ═══════════════════════════════════════════════════════════════════

    function proposeAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert Errors.ZeroAddress();
        pendingAdmin = newAdmin;
        emit AdminTransferProposed(admin, newAdmin);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert Errors.Unauthorized();
        address old = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferred(old, admin);
    }

    function pause() external onlyAdmin {
        isPaused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyAdmin {
        isPaused = false;
        emit Unpaused(msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Returns true if venue is whitelisted AND active.
    function isWhitelisted(address venue) external view returns (bool) {
        Venue storage v = _venues[venue];
        return v.addedAt != 0 && v.isActive;
    }

    function getVenue(address venue) external view returns (Venue memory) {
        return _venues[venue];
    }

    function getVenuesByCategory(uint8 category) external view returns (address[] memory) {
        return _venuesByCategory[category];
    }

    function totalVenues() external view returns (uint256) {
        return _allVenues.length;
    }

    function getAllVenues() external view returns (address[] memory) {
        return _allVenues;
    }
}
