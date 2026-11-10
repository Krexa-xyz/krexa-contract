// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {VenueWhitelist} from "../src/VenueWhitelist.sol";
import {IVenueWhitelist} from "../src/interfaces/IVenueWhitelist.sol";
import {Errors} from "../src/libraries/Errors.sol";

contract VenueWhitelistTest is Test {
    VenueWhitelist public whitelist;

    address admin = makeAddr("admin");
    address dex = makeAddr("jupiter");
    address launchpad = makeAddr("pumpfun");
    address facilitator = makeAddr("x402facilitator");
    address defi = makeAddr("marginfi");

    bytes32 dexName = bytes32("Jupiter V6");
    bytes32 launchName = bytes32("PumpFun");
    bytes32 facName = bytes32("Krexa x402");
    bytes32 defiName = bytes32("MarginFi");

    function setUp() public {
        whitelist = new VenueWhitelist(admin);
    }

    // ═══════════════════════════════════════════════════════════════
    // Constructor
    // ═══════════════════════════════════════════════════════════════

    function test_constructor() public view {
        assertEq(whitelist.admin(), admin);
        assertFalse(whitelist.isPaused());
        assertEq(whitelist.totalVenues(), 0);
    }

    function test_constructor_zeroAdmin() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new VenueWhitelist(address(0));
    }

    // ═══════════════════════════════════════════════════════════════
    // addVenue
    // ═══════════════════════════════════════════════════════════════

    function test_addVenue_dex() public {
        vm.prank(admin);
        whitelist.addVenue(dex, dexName, 0);

        assertTrue(whitelist.isWhitelisted(dex));
        assertEq(whitelist.totalVenues(), 1);

        IVenueWhitelist.Venue memory v = whitelist.getVenue(dex);
        assertEq(v.venueAddress, dex);
        assertEq(v.name, dexName);
        assertEq(v.category, 0);
        assertTrue(v.isActive);
        assertTrue(v.addedAt > 0);
    }

    function test_addVenue_allCategories() public {
        vm.startPrank(admin);
        whitelist.addVenue(dex, dexName, 0);           // DEX
        whitelist.addVenue(launchpad, launchName, 1);   // Launchpad
        whitelist.addVenue(facilitator, facName, 2);    // x402
        whitelist.addVenue(defi, defiName, 3);          // DeFi
        vm.stopPrank();

        assertEq(whitelist.totalVenues(), 4);

        address[] memory dexes = whitelist.getVenuesByCategory(0);
        assertEq(dexes.length, 1);
        assertEq(dexes[0], dex);

        address[] memory launchpads = whitelist.getVenuesByCategory(1);
        assertEq(launchpads.length, 1);
        assertEq(launchpads[0], launchpad);

        address[] memory x402s = whitelist.getVenuesByCategory(2);
        assertEq(x402s.length, 1);
        assertEq(x402s[0], facilitator);

        address[] memory defis = whitelist.getVenuesByCategory(3);
        assertEq(defis.length, 1);
        assertEq(defis[0], defi);
    }

    function test_addVenue_onlyAdmin() public {
        vm.prank(dex);
        vm.expectRevert(Errors.Unauthorized.selector);
        whitelist.addVenue(dex, dexName, 0);
    }

    function test_addVenue_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        whitelist.addVenue(address(0), dexName, 0);
    }

    function test_addVenue_invalidCategory() public {
        vm.prank(admin);
        vm.expectRevert(Errors.InvalidAmount.selector);
        whitelist.addVenue(dex, dexName, 4);
    }

    function test_addVenue_duplicate() public {
        vm.startPrank(admin);
        whitelist.addVenue(dex, dexName, 0);
        vm.expectRevert(Errors.VaultAlreadyExists.selector);
        whitelist.addVenue(dex, dexName, 0);
        vm.stopPrank();
    }

    function test_addVenue_emitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit IVenueWhitelist.VenueAdded(dex, dexName, 0);
        whitelist.addVenue(dex, dexName, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    // deactivateVenue
    // ═══════════════════════════════════════════════════════════════

    function test_deactivateVenue() public {
        vm.startPrank(admin);
        whitelist.addVenue(dex, dexName, 0);
        whitelist.deactivateVenue(dex);
        vm.stopPrank();

        assertFalse(whitelist.isWhitelisted(dex));
        // Venue still exists in storage
        IVenueWhitelist.Venue memory v = whitelist.getVenue(dex);
        assertFalse(v.isActive);
        assertTrue(v.addedAt > 0);
    }

    function test_deactivateVenue_notFound() public {
        vm.prank(admin);
        vm.expectRevert(Errors.InvalidAmount.selector);
        whitelist.deactivateVenue(dex);
    }

    function test_deactivateVenue_alreadyInactive() public {
        vm.startPrank(admin);
        whitelist.addVenue(dex, dexName, 0);
        whitelist.deactivateVenue(dex);
        vm.expectRevert(Errors.VaultAlreadyPaused.selector);
        whitelist.deactivateVenue(dex);
        vm.stopPrank();
    }

    function test_deactivateVenue_emitsEvent() public {
        vm.startPrank(admin);
        whitelist.addVenue(dex, dexName, 0);

        vm.expectEmit(true, false, false, false);
        emit IVenueWhitelist.VenueDeactivated(dex);
        whitelist.deactivateVenue(dex);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    // reactivateVenue
    // ═══════════════════════════════════════════════════════════════

    function test_reactivateVenue() public {
        vm.startPrank(admin);
        whitelist.addVenue(dex, dexName, 0);
        whitelist.deactivateVenue(dex);
        whitelist.reactivateVenue(dex);
        vm.stopPrank();

        assertTrue(whitelist.isWhitelisted(dex));
    }

    function test_reactivateVenue_notFound() public {
        vm.prank(admin);
        vm.expectRevert(Errors.InvalidAmount.selector);
        whitelist.reactivateVenue(dex);
    }

    function test_reactivateVenue_alreadyActive() public {
        vm.startPrank(admin);
        whitelist.addVenue(dex, dexName, 0);
        vm.expectRevert(Errors.AgentAlreadyActive.selector);
        whitelist.reactivateVenue(dex);
        vm.stopPrank();
    }

    function test_reactivateVenue_emitsEvent() public {
        vm.startPrank(admin);
        whitelist.addVenue(dex, dexName, 0);
        whitelist.deactivateVenue(dex);

        vm.expectEmit(true, false, false, false);
        emit IVenueWhitelist.VenueReactivated(dex);
        whitelist.reactivateVenue(dex);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    // updateCategory
    // ═══════════════════════════════════════════════════════════════

    function test_updateCategory() public {
        vm.startPrank(admin);
        whitelist.addVenue(dex, dexName, 0); // DEX
        whitelist.updateCategory(dex, 3);     // → DeFi
        vm.stopPrank();

        assertEq(whitelist.getVenue(dex).category, 3);

        // Old category list should be empty
        address[] memory dexes = whitelist.getVenuesByCategory(0);
        assertEq(dexes.length, 0);

        // New category list should have the venue
        address[] memory defis = whitelist.getVenuesByCategory(3);
        assertEq(defis.length, 1);
        assertEq(defis[0], dex);
    }

    function test_updateCategory_sameCategory_noop() public {
        vm.startPrank(admin);
        whitelist.addVenue(dex, dexName, 0);
        whitelist.updateCategory(dex, 0); // no change
        vm.stopPrank();

        // Category list should still have 1 entry
        address[] memory dexes = whitelist.getVenuesByCategory(0);
        assertEq(dexes.length, 1);
    }

    function test_updateCategory_invalidCategory() public {
        vm.startPrank(admin);
        whitelist.addVenue(dex, dexName, 0);
        vm.expectRevert(Errors.InvalidAmount.selector);
        whitelist.updateCategory(dex, 5);
        vm.stopPrank();
    }

    function test_updateCategory_notFound() public {
        vm.prank(admin);
        vm.expectRevert(Errors.InvalidAmount.selector);
        whitelist.updateCategory(dex, 1);
    }

    function test_updateCategory_swapAndPop() public {
        // Add 3 DEXes, then move the first to DeFi — tests swap-and-pop logic.
        address dex2 = makeAddr("raydium");
        address dex3 = makeAddr("orca");

        vm.startPrank(admin);
        whitelist.addVenue(dex, dexName, 0);
        whitelist.addVenue(dex2, bytes32("Raydium"), 0);
        whitelist.addVenue(dex3, bytes32("Orca"), 0);

        // Move jupiter (index 0) to DeFi
        whitelist.updateCategory(dex, 3);
        vm.stopPrank();

        // DEX list should have [orca, raydium] (orca swapped into index 0)
        address[] memory dexes = whitelist.getVenuesByCategory(0);
        assertEq(dexes.length, 2);
        // Order after swap: last element (orca) took jupiter's spot
        assertEq(dexes[0], dex3);
        assertEq(dexes[1], dex2);
    }

    function test_updateCategory_emitsEvent() public {
        vm.startPrank(admin);
        whitelist.addVenue(dex, dexName, 0);

        vm.expectEmit(true, false, false, true);
        emit IVenueWhitelist.VenueCategoryUpdated(dex, 0, 2);
        whitelist.updateCategory(dex, 2);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    // isWhitelisted
    // ═══════════════════════════════════════════════════════════════

    function test_isWhitelisted_false_notAdded() public view {
        assertFalse(whitelist.isWhitelisted(dex));
    }

    function test_isWhitelisted_false_deactivated() public {
        vm.startPrank(admin);
        whitelist.addVenue(dex, dexName, 0);
        whitelist.deactivateVenue(dex);
        vm.stopPrank();

        assertFalse(whitelist.isWhitelisted(dex));
    }

    // ═══════════════════════════════════════════════════════════════
    // Admin Transfer (2-step)
    // ═══════════════════════════════════════════════════════════════

    function test_adminTransfer() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        whitelist.proposeAdmin(newAdmin);
        assertEq(whitelist.pendingAdmin(), newAdmin);

        vm.prank(newAdmin);
        whitelist.acceptAdmin();
        assertEq(whitelist.admin(), newAdmin);
        assertEq(whitelist.pendingAdmin(), address(0));
    }

    function test_adminTransfer_onlyPending() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        whitelist.proposeAdmin(newAdmin);

        vm.prank(dex);
        vm.expectRevert(Errors.Unauthorized.selector);
        whitelist.acceptAdmin();
    }

    function test_proposeAdmin_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        whitelist.proposeAdmin(address(0));
    }

    // ═══════════════════════════════════════════════════════════════
    // Pause
    // ═══════════════════════════════════════════════════════════════

    function test_pause_blocksAddVenue() public {
        vm.prank(admin);
        whitelist.pause();

        vm.prank(admin);
        vm.expectRevert(Errors.PlatformPaused.selector);
        whitelist.addVenue(dex, dexName, 0);
    }

    function test_pause_blocksDeactivate() public {
        vm.startPrank(admin);
        whitelist.addVenue(dex, dexName, 0);
        whitelist.pause();

        vm.expectRevert(Errors.PlatformPaused.selector);
        whitelist.deactivateVenue(dex);
        vm.stopPrank();
    }

    function test_pause_blocksReactivate() public {
        vm.startPrank(admin);
        whitelist.addVenue(dex, dexName, 0);
        whitelist.deactivateVenue(dex);
        whitelist.pause();

        vm.expectRevert(Errors.PlatformPaused.selector);
        whitelist.reactivateVenue(dex);
        vm.stopPrank();
    }

    function test_unpause_resumes() public {
        vm.startPrank(admin);
        whitelist.pause();
        whitelist.unpause();
        whitelist.addVenue(dex, dexName, 0);
        vm.stopPrank();

        assertTrue(whitelist.isWhitelisted(dex));
    }

    function test_pause_onlyAdmin() public {
        vm.prank(dex);
        vm.expectRevert(Errors.Unauthorized.selector);
        whitelist.pause();
    }

    // ═══════════════════════════════════════════════════════════════
    // View: getAllVenues
    // ═══════════════════════════════════════════════════════════════

    function test_getAllVenues() public {
        vm.startPrank(admin);
        whitelist.addVenue(dex, dexName, 0);
        whitelist.addVenue(launchpad, launchName, 1);
        whitelist.addVenue(facilitator, facName, 2);
        vm.stopPrank();

        address[] memory all = whitelist.getAllVenues();
        assertEq(all.length, 3);
        assertEq(all[0], dex);
        assertEq(all[1], launchpad);
        assertEq(all[2], facilitator);
    }
}
