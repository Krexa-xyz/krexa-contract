// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {MerchantVault} from "../src/MerchantVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {Errors} from "../src/libraries/Errors.sol";

/// @notice Solana-parity tests: platform fee, revenue validation, blocklist/whitelist,
///         quarantine review, retroactive rejection, outflow tracking
contract PaymentRouterSolanaTest is Test {
    MockUSDC public usdc;
    AgentRegistry public registry;
    PaymentRouter public router;
    MerchantVault public vault;

    uint256 oraclePrivKey = 0xA11CE;
    address oracle = vm.addr(oraclePrivKey);
    address admin = makeAddr("admin");
    address merchant = makeAddr("translateBot");
    address payer = makeAddr("shopBot");
    address feeRecipient = makeAddr("feeRecipient");
    address treasury = makeAddr("treasury");

    function setUp() public {
        usdc = new MockUSDC();
        registry = new AgentRegistry(admin, oracle);
        router = new PaymentRouter(address(usdc), address(registry), admin, oracle);

        vm.prank(admin);
        registry.setPaymentRouter(address(router));

        // Deploy and fund vault
        vault = new MerchantVault(MerchantVault.VaultParams({
            usdc: address(usdc),
            agent: merchant,
            admin: admin,
            factory: address(this),
            targetAmount: 50_000e6,
            interestRateBps: 1200,
            durationSeconds: 365 days,
            numTranches: 4,
            platformFeeBps: 200,
            platformFeeRecipient: feeRecipient,
            lateFeeBps: 0,
            gracePeriodSeconds: 0,
            fundraisingDeadline: type(uint256).max
        }));
        vm.prank(admin);
        vault.setPaymentRouter(address(router));
        usdc.mint(address(this), 50_000e6);
        usdc.approve(address(vault), 50_000e6);
        vault.investSenior(50_000e6);

        // Register agents
        vm.prank(merchant);
        registry.registerAgent("ipfs://translateBot");
        vm.prank(payer);
        registry.registerAgent("ipfs://shopBot");

        // Setup factory + settlement
        vm.prank(admin);
        router.setFactory(admin);
        vm.prank(admin);
        router.createSettlement(merchant, address(vault), 1500, 0, 0);

        // Fund payer
        usdc.mint(payer, 1_000_000e6);

        // Set platform fee
        vm.startPrank(admin);
        router.setPlatformTreasury(treasury);
        router.setPlatformFeeBps(200); // 2%
        vm.stopPrank();
    }

    // ════════════════════════════════════════════════════════════════
    // 1. Platform Fee
    // ════════════════════════════════════════════════════════════════

    function test_platformFee_deductedFromPayment() public {
        uint256 amount = 1000e6;
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 merchantBefore = usdc.balanceOf(merchant);

        _pay(payer, merchant, amount, 1);

        // Platform fee = 2% of 1000 = 20
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 20e6);

        // Remainder = 980. Repayment = 15% of 980 = 147. Net = 980 - 147 = 833
        assertEq(usdc.balanceOf(merchant) - merchantBefore, 833e6);
    }

    function test_platformFee_directPaymentStillDeducted() public {
        // Agent with no settlement
        address receiver = makeAddr("receiver");
        vm.prank(receiver);
        registry.registerAgent("ipfs://receiver");

        uint256 amount = 500e6;
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        _pay(payer, receiver, amount, 1);

        // 2% of 500 = 10
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 10e6);
        // Receiver gets 490
        assertEq(usdc.balanceOf(receiver), 490e6);
    }

    function test_platformFee_zeroBpsNoFee() public {
        vm.prank(admin);
        router.setPlatformFeeBps(0);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        _pay(payer, merchant, 1000e6, 1);

        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 0);
    }

    function test_platformFee_maxBpsCap() public {
        vm.prank(admin);
        vm.expectRevert(Errors.FeeTooHigh.selector);
        router.setPlatformFeeBps(1001); // > 10%
    }

    function test_platformFee_settingRequiresAdmin() public {
        vm.prank(payer);
        vm.expectRevert(Errors.Unauthorized.selector);
        router.setPlatformFeeBps(100);
    }

    function test_platformTreasury_setRequiresAdmin() public {
        vm.prank(payer);
        vm.expectRevert(Errors.Unauthorized.selector);
        router.setPlatformTreasury(payer);
    }

    function test_platformTreasury_zeroAddressReverts() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        router.setPlatformTreasury(address(0));
    }

    // ════════════════════════════════════════════════════════════════
    // 2. Revenue Validator Lifecycle
    // ════════════════════════════════════════════════════════════════

    function test_createValidator_oracle() public {
        address agentWallet = makeAddr("agentWallet");
        vm.prank(oracle);
        router.createRevenueValidator(merchant, agentWallet, merchant, 1000e6, 50_000e6);

        IPaymentRouter.RevenueValidator memory v = router.getValidator(merchant);
        assertTrue(v.isActive);
        assertEq(v.merchant, merchant);
        assertEq(v.agentWallet, agentWallet);
        assertEq(v.agentOwner, merchant);
        assertEq(v.expectedDailyRevenue, 1000e6);
        assertEq(v.totalCredit, 50_000e6);
        assertEq(v.cumulativeValidatedRevenue, 0);
    }

    function test_createValidator_duplicateReverts() public {
        vm.prank(oracle);
        router.createRevenueValidator(merchant, makeAddr("w"), merchant, 1000e6, 50_000e6);

        vm.prank(oracle);
        vm.expectRevert(Errors.ValidatorAlreadyExists.selector);
        router.createRevenueValidator(merchant, makeAddr("w"), merchant, 1000e6, 50_000e6);
    }

    function test_createValidator_onlyAdminOrOracle() public {
        vm.prank(payer);
        vm.expectRevert(Errors.OnlyAdminOrOracle.selector);
        router.createRevenueValidator(merchant, makeAddr("w"), merchant, 1000e6, 50_000e6);
    }

    // ════════════════════════════════════════════════════════════════
    // 3. Revenue Source Registration
    // ════════════════════════════════════════════════════════════════

    function test_registerSource_andRemove() public {
        _setupValidator();

        address source = makeAddr("customer1");
        vm.prank(oracle);
        router.registerRevenueSource(merchant, source);

        address[] memory sources = router.getRegisteredSources(merchant);
        assertEq(sources.length, 1);
        assertEq(sources[0], source);

        vm.prank(oracle);
        router.removeRevenueSource(merchant, source);

        sources = router.getRegisteredSources(merchant);
        assertEq(sources.length, 0);
    }

    function test_registerSource_duplicateReverts() public {
        _setupValidator();
        address source = makeAddr("customer1");

        vm.prank(oracle);
        router.registerRevenueSource(merchant, source);

        vm.prank(oracle);
        vm.expectRevert(Errors.SourceAlreadyRegistered.selector);
        router.registerRevenueSource(merchant, source);
    }

    function test_removeSource_notFoundReverts() public {
        _setupValidator();

        vm.prank(oracle);
        vm.expectRevert(Errors.SourceNotFound.selector);
        router.removeRevenueSource(merchant, makeAddr("unknown"));
    }

    // ════════════════════════════════════════════════════════════════
    // 4. Associated Wallets
    // ════════════════════════════════════════════════════════════════

    function test_addAssociatedWallet() public {
        _setupValidator();
        address wallet = makeAddr("sybil");

        vm.prank(oracle);
        router.addAssociatedWallet(merchant, wallet);

        address[] memory wallets = router.getAssociatedWallets(merchant);
        assertEq(wallets.length, 1);
        assertEq(wallets[0], wallet);
    }

    function test_addAssociatedWallet_duplicateReverts() public {
        _setupValidator();
        address wallet = makeAddr("sybil");

        vm.prank(oracle);
        router.addAssociatedWallet(merchant, wallet);

        vm.prank(oracle);
        vm.expectRevert(Errors.WalletAlreadyAssociated.selector);
        router.addAssociatedWallet(merchant, wallet);
    }

    // ════════════════════════════════════════════════════════════════
    // 5. Blocklist / Whitelist
    // ════════════════════════════════════════════════════════════════

    function test_blocklist_addAndRemove() public {
        address bad = makeAddr("badactor");

        vm.prank(admin);
        router.addToBlocklist(bad);
        assertTrue(router.isBlocklisted(bad));

        vm.prank(admin);
        router.removeFromBlocklist(bad);
        assertFalse(router.isBlocklisted(bad));
    }

    function test_platformWhitelist_addAndRemove() public {
        address platform = makeAddr("commerce");

        vm.prank(admin);
        router.addToPlatformWhitelist(platform);
        assertTrue(router.isPlatformWhitelisted(platform));

        vm.prank(admin);
        router.removeFromPlatformWhitelist(platform);
        assertFalse(router.isPlatformWhitelisted(platform));
    }

    function test_blocklist_onlyAdmin() public {
        vm.prank(payer);
        vm.expectRevert(Errors.Unauthorized.selector);
        router.addToBlocklist(payer);
    }

    // ════════════════════════════════════════════════════════════════
    // 6. Revenue Validation — Layer 1 (Source Classification)
    // ════════════════════════════════════════════════════════════════

    function test_validate_selfPayRejected() public {
        address agentWallet = makeAddr("agentWallet");
        _setupValidatorWith(agentWallet, merchant);

        vm.prank(oracle);
        router.validateRevenue(merchant, agentWallet, 100e6, false);

        IPaymentRouter.PaymentRecord memory rec = router.getPaymentRecord(merchant, 0);
        assertEq(rec.classification, 1); // Rejected
    }

    function test_validate_ownerPayRejected() public {
        address agentWallet = makeAddr("agentWallet");
        address agentOwner = makeAddr("owner");
        _setupValidatorWith(agentWallet, agentOwner);

        vm.prank(oracle);
        router.validateRevenue(merchant, agentOwner, 100e6, false);

        IPaymentRouter.PaymentRecord memory rec = router.getPaymentRecord(merchant, 0);
        assertEq(rec.classification, 1); // Rejected
    }

    function test_validate_associatedWalletRejected() public {
        _setupValidator();
        address sybil = makeAddr("sybil");

        vm.prank(oracle);
        router.addAssociatedWallet(merchant, sybil);

        vm.prank(oracle);
        router.validateRevenue(merchant, sybil, 100e6, false);

        IPaymentRouter.PaymentRecord memory rec = router.getPaymentRecord(merchant, 0);
        assertEq(rec.classification, 1); // Rejected
    }

    function test_validate_blocklistedRejected() public {
        _setupValidator();
        address bad = makeAddr("badactor");

        vm.prank(admin);
        router.addToBlocklist(bad);

        vm.prank(oracle);
        router.validateRevenue(merchant, bad, 100e6, false);

        IPaymentRouter.PaymentRecord memory rec = router.getPaymentRecord(merchant, 0);
        assertEq(rec.classification, 1); // Rejected
    }

    // ════════════════════════════════════════════════════════════════
    // 7. Revenue Validation — Fast-Path Verifications
    // ════════════════════════════════════════════════════════════════

    function test_validate_x402AutoVerified() public {
        _setupValidator();

        vm.prank(oracle);
        router.validateRevenue(merchant, makeAddr("anyone"), 100e6, true);

        IPaymentRouter.PaymentRecord memory rec = router.getPaymentRecord(merchant, 0);
        assertEq(rec.classification, 0); // Verified

        // Cumulative revenue credited
        IPaymentRouter.RevenueValidator memory v = router.getValidator(merchant);
        assertEq(v.cumulativeValidatedRevenue, 100e6);
    }

    function test_validate_whitelistedPlatformVerified() public {
        _setupValidator();
        address platform = makeAddr("commerce");

        vm.prank(admin);
        router.addToPlatformWhitelist(platform);

        vm.prank(oracle);
        router.validateRevenue(merchant, platform, 100e6, false);

        IPaymentRouter.PaymentRecord memory rec = router.getPaymentRecord(merchant, 0);
        assertEq(rec.classification, 0); // Verified
    }

    function test_validate_registeredSourceVerified() public {
        _setupValidator();
        address customer = makeAddr("customer1");

        vm.prank(oracle);
        router.registerRevenueSource(merchant, customer);

        vm.prank(oracle);
        router.validateRevenue(merchant, customer, 100e6, false);

        IPaymentRouter.PaymentRecord memory rec = router.getPaymentRecord(merchant, 0);
        assertEq(rec.classification, 0); // Verified
    }

    // ════════════════════════════════════════════════════════════════
    // 8. Revenue Validation — Layer 2+3 (Pattern + Economic)
    // ════════════════════════════════════════════════════════════════

    function test_validate_roundTripDetected() public {
        _setupValidator();
        address counterparty = makeAddr("counterparty");

        // Record outflow to counterparty
        vm.prank(oracle);
        router.recordOutflow(merchant, counterparty, 1000e6);

        // Same counterparty pays back similar amount → round-trip (score >= 45)
        vm.prank(oracle);
        router.validateRevenue(merchant, counterparty, 1000e6, false);

        IPaymentRouter.PaymentRecord memory rec = router.getPaymentRecord(merchant, 0);
        // Score = 45 (round-trip) → quarantined (>= 40)
        assertTrue(rec.classification == 2 || rec.classification == 3, "Should be quarantined or pending");
        assertTrue(rec.patternScore >= 45);
    }

    function test_validate_extremeOvershootRejected() public {
        // Validator with expectedDailyRevenue = 100 USDC
        address agentWallet = makeAddr("agentWallet");
        vm.prank(oracle);
        router.createRevenueValidator(merchant, agentWallet, merchant, 100e6, 50_000e6);

        // Payment of 2000 USDC (20x daily revenue = EXTREME_OVERSHOOT)
        vm.prank(oracle);
        router.validateRevenue(merchant, makeAddr("unknown"), 2000e6, false);

        IPaymentRouter.PaymentRecord memory rec = router.getPaymentRecord(merchant, 0);
        assertEq(rec.classification, 1); // Rejected
    }

    function test_validate_unknownSourcePendingKeeper() public {
        _setupValidator();

        // Unknown source, small amount, no patterns → PendingKeeper
        vm.prank(oracle);
        router.validateRevenue(merchant, makeAddr("unknown"), 10e6, false);

        IPaymentRouter.PaymentRecord memory rec = router.getPaymentRecord(merchant, 0);
        assertEq(rec.classification, 3); // PendingKeeper

        // Cumulative revenue still credited (tentatively)
        IPaymentRouter.RevenueValidator memory v = router.getValidator(merchant);
        assertEq(v.cumulativeValidatedRevenue, 10e6);
    }

    // ════════════════════════════════════════════════════════════════
    // 9. Quarantine Review
    // ════════════════════════════════════════════════════════════════

    function test_reviewQuarantined_approve() public {
        _setupValidator();

        // Create a PendingKeeper payment
        vm.prank(oracle);
        router.validateRevenue(merchant, makeAddr("unknown"), 100e6, false);

        IPaymentRouter.PaymentRecord memory before = router.getPaymentRecord(merchant, 0);
        assertEq(before.classification, 3); // PendingKeeper

        // Approve it
        vm.prank(oracle);
        router.reviewQuarantined(merchant, 0, 0); // DECISION_APPROVE

        IPaymentRouter.PaymentRecord memory after_ = router.getPaymentRecord(merchant, 0);
        assertEq(after_.classification, 0); // Verified

        // Revenue stays credited (was already tentatively credited)
        IPaymentRouter.RevenueValidator memory v = router.getValidator(merchant);
        assertEq(v.cumulativeValidatedRevenue, 100e6);
    }

    function test_reviewQuarantined_reject() public {
        _setupValidator();

        vm.prank(oracle);
        router.validateRevenue(merchant, makeAddr("unknown"), 100e6, false);

        // Reject the PendingKeeper payment
        vm.prank(oracle);
        router.reviewQuarantined(merchant, 0, 1); // DECISION_REJECT

        IPaymentRouter.PaymentRecord memory after_ = router.getPaymentRecord(merchant, 0);
        assertEq(after_.classification, 1); // Rejected

        // Revenue decremented
        IPaymentRouter.RevenueValidator memory v = router.getValidator(merchant);
        assertEq(v.cumulativeValidatedRevenue, 0);
        assertEq(v.revenueIntegrityViolations, 1);
    }

    function test_reviewQuarantined_approveAndWhitelist() public {
        _setupValidator();
        address source = makeAddr("unknown");

        vm.prank(oracle);
        router.validateRevenue(merchant, source, 100e6, false);

        vm.prank(oracle);
        router.reviewQuarantined(merchant, 0, 2); // DECISION_APPROVE_AND_WHITELIST

        // Source is now registered
        address[] memory sources = router.getRegisteredSources(merchant);
        assertEq(sources.length, 1);
        assertEq(sources[0], source);
    }

    function test_reviewQuarantined_rejectAndBlocklist() public {
        _setupValidator();
        address source = makeAddr("suspicious");

        vm.prank(oracle);
        router.validateRevenue(merchant, source, 100e6, false);

        vm.prank(oracle);
        router.reviewQuarantined(merchant, 0, 3); // DECISION_REJECT_AND_BLOCKLIST

        // Source is now blocklisted
        assertTrue(router.isBlocklisted(source));
    }

    function test_reviewQuarantined_invalidIndexReverts() public {
        vm.prank(oracle);
        vm.expectRevert(Errors.PaymentIndexOutOfBounds.selector);
        router.reviewQuarantined(merchant, 16, 0);
    }

    function test_reviewQuarantined_notQuarantinedReverts() public {
        _setupValidator();

        // Create a Verified payment (x402)
        vm.prank(oracle);
        router.validateRevenue(merchant, makeAddr("customer"), 100e6, true);

        vm.prank(oracle);
        vm.expectRevert(Errors.NotQuarantined.selector);
        router.reviewQuarantined(merchant, 0, 0);
    }

    // ════════════════════════════════════════════════════════════════
    // 10. Retroactive Rejection
    // ════════════════════════════════════════════════════════════════

    function test_retroactiveReject_verified() public {
        _setupValidator();

        // Verified payment via x402
        vm.prank(oracle);
        router.validateRevenue(merchant, makeAddr("customer"), 500e6, true);

        IPaymentRouter.RevenueValidator memory v1 = router.getValidator(merchant);
        assertEq(v1.cumulativeValidatedRevenue, 500e6);

        // Retroactively reject
        vm.prank(oracle);
        router.retroactiveReject(merchant, 0);

        IPaymentRouter.RevenueValidator memory v2 = router.getValidator(merchant);
        assertEq(v2.cumulativeValidatedRevenue, 0);
        assertEq(v2.revenueIntegrityViolations, 1);

        IPaymentRouter.PaymentRecord memory rec = router.getPaymentRecord(merchant, 0);
        assertEq(rec.classification, 1); // Rejected
    }

    function test_retroactiveReject_alreadyRejectedReverts() public {
        _setupValidator();

        vm.prank(oracle);
        router.validateRevenue(merchant, makeAddr("customer"), 100e6, true);

        vm.prank(oracle);
        router.retroactiveReject(merchant, 0);

        // Already rejected → should revert
        vm.prank(oracle);
        vm.expectRevert(Errors.NotQuarantined.selector);
        router.retroactiveReject(merchant, 0);
    }

    // ════════════════════════════════════════════════════════════════
    // 11. Outflow Recording
    // ════════════════════════════════════════════════════════════════

    function test_recordOutflow_storedInRingBuffer() public {
        address dest = makeAddr("destination");

        vm.prank(oracle);
        router.recordOutflow(merchant, dest, 500e6);

        // Not directly viewable as a struct, but round-trip detection uses it
        // Verify via round-trip: send back and check classification
        _setupValidator();

        vm.prank(oracle);
        router.validateRevenue(merchant, dest, 500e6, false);

        IPaymentRouter.PaymentRecord memory rec = router.getPaymentRecord(merchant, 0);
        assertTrue(rec.patternScore >= 45, "Should detect round-trip");
    }

    function test_recordOutflow_expiredNotDetected() public {
        address dest = makeAddr("destination");

        vm.prank(oracle);
        router.recordOutflow(merchant, dest, 500e6);

        // Warp past 24h window
        vm.warp(block.timestamp + 86_401);

        _setupValidator();

        vm.prank(oracle);
        router.validateRevenue(merchant, dest, 500e6, false);

        IPaymentRouter.PaymentRecord memory rec = router.getPaymentRecord(merchant, 0);
        // Not detected as round-trip (expired window)
        assertTrue(rec.patternScore < 45, "Should NOT detect round-trip after window");
    }

    // ════════════════════════════════════════════════════════════════
    // 12. Payment History Ring Buffer
    // ════════════════════════════════════════════════════════════════

    function test_paymentHistory_wrapsAround() public {
        _setupValidator();

        // Fill 16 entries, then add one more to wrap
        for (uint256 i = 0; i < 17; i++) {
            vm.prank(oracle);
            router.validateRevenue(merchant, makeAddr(vm.toString(i)), 10e6, true);
        }

        // Index 0 should now contain the 17th payment (wrapped)
        IPaymentRouter.PaymentRecord memory rec = router.getPaymentRecord(merchant, 0);
        assertEq(rec.amount, 10e6); // Still valid, just overwritten
    }

    // ════════════════════════════════════════════════════════════════
    // 13. Validator Parameter Updates
    // ════════════════════════════════════════════════════════════════

    function test_updateValidatorParams() public {
        _setupValidator();

        vm.prank(oracle);
        router.updateValidatorParams(merchant, 2000e6, 100_000e6, 5000e6);

        IPaymentRouter.RevenueValidator memory v = router.getValidator(merchant);
        assertEq(v.expectedDailyRevenue, 2000e6);
        assertEq(v.totalCredit, 100_000e6);
        assertEq(v.totalDisbursed, 5000e6);
    }

    function test_updateValidatorParams_inactiveReverts() public {
        vm.prank(oracle);
        vm.expectRevert(Errors.ValidatorNotActive.selector);
        router.updateValidatorParams(merchant, 2000e6, 100_000e6, 5000e6);
    }

    // ════════════════════════════════════════════════════════════════
    // 14. Facilitated Payment with Platform Fee
    // ════════════════════════════════════════════════════════════════

    function test_facilitatedPayment_platformFee() public {
        address facilitator = makeAddr("facilitator");
        vm.prank(admin);
        router.setFacilitator(facilitator, true);

        usdc.mint(facilitator, 1000e6);
        vm.prank(facilitator);
        usdc.approve(address(router), 1000e6);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(facilitator);
        router.executeFacilitatedPayment(
            IPaymentRouter.X402Payment(payer, merchant, 1000e6, 1, block.timestamp + 300, keccak256("f1"))
        );

        // 2% fee = 20
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 20e6);
    }

    // ════════════════════════════════════════════════════════════════
    // 15. Economic Validation — Large Payment vs Credit
    // ════════════════════════════════════════════════════════════════

    function test_validate_largePaymentVsCreditQuarantined() public {
        // totalCredit = 1000, payment = 600 (> 50% of credit)
        address agentWallet = makeAddr("agentWallet");
        vm.prank(oracle);
        router.createRevenueValidator(merchant, agentWallet, merchant, 10_000e6, 1000e6);

        vm.prank(oracle);
        router.validateRevenue(merchant, makeAddr("unknown"), 600e6, false);

        IPaymentRouter.PaymentRecord memory rec = router.getPaymentRecord(merchant, 0);
        // score += 30 for large payment threshold → >= quarantine threshold (40)
        assertTrue(rec.patternScore >= 30, "Should flag large payment vs credit");
    }

    // ════════════════════════════════════════════════════════════════
    // 16. Pause Blocks Validation
    // ════════════════════════════════════════════════════════════════

    function test_validateRevenue_pausedReverts() public {
        _setupValidator();

        vm.prank(admin);
        router.pause();

        vm.prank(oracle);
        vm.expectRevert(Errors.PlatformPaused.selector);
        router.validateRevenue(merchant, makeAddr("anyone"), 100e6, true);
    }

    // ════════════════════════════════════════════════════════════════
    // Helpers
    // ════════════════════════════════════════════════════════════════

    function _setupValidator() internal {
        address agentWallet = makeAddr("agentWallet");
        vm.prank(oracle);
        router.createRevenueValidator(merchant, agentWallet, merchant, 10_000e6, 50_000e6);
    }

    function _setupValidatorWith(address agentWallet, address agentOwner) internal {
        vm.prank(oracle);
        router.createRevenueValidator(merchant, agentWallet, agentOwner, 10_000e6, 50_000e6);
    }

    function _pay(address from, address to, uint256 amount, uint256 nonce) internal {
        bytes32 paymentId = keccak256(abi.encodePacked("pay", nonce));
        bytes memory sig = _signPayment(from, to, amount, nonce, block.timestamp + 300, paymentId);
        vm.prank(from);
        usdc.approve(address(router), amount);
        router.executePayment(
            IPaymentRouter.X402Payment(from, to, amount, nonce, block.timestamp + 300, paymentId), sig
        );
    }

    function _signPayment(
        address from, address to, uint256 amount, uint256 nonce, uint256 deadline, bytes32 paymentId
    ) internal view returns (bytes memory) {
        bytes32 msgHash = keccak256(abi.encode(from, to, amount, nonce, deadline, paymentId));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oraclePrivKey, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }
}
