// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {AgentWallet} from "../src/AgentWallet.sol";
import {AgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {IAgentRegistry} from "../src/interfaces/IAgentRegistry.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract AgentWalletTest is Test {
    MockUSDC public usdc;
    AgentRegistry public registry;
    AgentWalletFactory public factory;

    address admin = makeAddr("admin");
    address oracle = makeAddr("oracle");
    address human = makeAddr("human");
    address agent = makeAddr("agent");
    address recipient = makeAddr("recipient");

    uint256 dailyLimit = 1000e6;  // $1000
    uint256 perTxLimit = 200e6;   // $200

    AgentWallet public wallet;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new AgentRegistry(admin, oracle);

        // Authorize factory in registry
        factory = new AgentWalletFactory(address(usdc), address(registry), admin);
        vm.prank(admin);
        registry.setFactory(address(factory));

        // Register agent (human is the agent address in registry)
        vm.prank(human);
        registry.registerAgent("ipfs://human-agent");

        // Create wallet as human
        vm.prank(human);
        address walletAddr = factory.createWallet(agent, dailyLimit, perTxLimit);
        wallet = AgentWallet(payable(walletAddr));

        // Fund wallet
        usdc.mint(walletAddr, 10_000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    // Factory Tests
    // ═══════════════════════════════════════════════════════════════

    function test_createWallet() public view {
        assertEq(wallet.owner(), human);
        assertEq(wallet.operator(), agent);
        assertEq(wallet.dailyLimit(), dailyLimit);
        assertEq(wallet.perTxLimit(), perTxLimit);
        assertEq(factory.ownerToWallet(human), address(wallet));
        assertEq(factory.totalWallets(), 1);
    }

    function test_createWallet_revertDuplicate() public {
        vm.prank(human);
        vm.expectRevert(Errors.VaultAlreadyExists.selector);
        factory.createWallet(agent, dailyLimit, perTxLimit);
    }

    function test_createWallet_linksInRegistry() public view {
        IAgentRegistry.Agent memory a = registry.getAgent(human);
        assertEq(a.walletContract, address(wallet));
        assertTrue(a.hasWallet);
    }

    function test_predictWalletAddress() public {
        address predicted = factory.predictWalletAddress(human, agent, dailyLimit, perTxLimit);
        assertEq(predicted, address(wallet));
    }

    // ═══════════════════════════════════════════════════════════════
    // Transfer — Basic
    // ═══════════════════════════════════════════════════════════════

    function test_transfer_success() public {
        vm.prank(agent);
        wallet.transfer(recipient, 100e6);
        assertEq(usdc.balanceOf(recipient), 100e6);
        assertEq(wallet.spentToday(), 100e6);
    }

    function test_transfer_onlyOperator() public {
        vm.prank(human);
        vm.expectRevert(Errors.Unauthorized.selector);
        wallet.transfer(recipient, 100e6);
    }

    function test_transfer_frozen() public {
        vm.prank(human);
        wallet.freeze();

        vm.prank(agent);
        vm.expectRevert(Errors.VaultPaused.selector);
        wallet.transfer(recipient, 100e6);
    }

    function test_transfer_zeroAmount() public {
        vm.prank(agent);
        vm.expectRevert(Errors.InvalidAmount.selector);
        wallet.transfer(recipient, 0);
    }

    function test_transfer_zeroRecipient() public {
        vm.prank(agent);
        vm.expectRevert(Errors.ZeroAddress.selector);
        wallet.transfer(address(0), 100e6);
    }

    // ═══════════════════════════════════════════════════════════════
    // Safety 1: Whitelist (venue authorization)
    // ═══════════════════════════════════════════════════════════════

    function test_whitelist_allowed() public {
        vm.startPrank(human);
        wallet.toggleWhitelist(true);
        wallet.setWhitelist(recipient, true);
        vm.stopPrank();

        vm.prank(agent);
        wallet.transfer(recipient, 100e6);
        assertEq(usdc.balanceOf(recipient), 100e6);
    }

    function test_whitelist_blocked() public {
        vm.prank(human);
        wallet.toggleWhitelist(true);

        vm.prank(agent);
        vm.expectRevert(Errors.Unauthorized.selector);
        wallet.transfer(recipient, 100e6);
    }

    // ═══════════════════════════════════════════════════════════════
    // Safety 2: Per-tx limit
    // ═══════════════════════════════════════════════════════════════

    function test_perTxLimit_exceeded() public {
        vm.prank(agent);
        vm.expectRevert(Errors.PaymentTooLarge.selector);
        wallet.transfer(recipient, 300e6); // exceeds $200 limit
    }

    // ═══════════════════════════════════════════════════════════════
    // Safety 3: Per-trade 20% of balance
    // ═══════════════════════════════════════════════════════════════

    function test_perTrade20pct_exceeded() public {
        // Balance = 10,000. 20% = 2,000. Set perTxLimit high.
        vm.prank(human);
        wallet.setLimits(50_000e6, 3_000e6);

        // 2,001 should fail (> 20% of 10,000)
        vm.prank(agent);
        vm.expectRevert(Errors.PaymentTooLarge.selector);
        wallet.transfer(recipient, 2_001e6);
    }

    function test_perTrade20pct_exactlyAtLimit() public {
        vm.prank(human);
        wallet.setLimits(50_000e6, 3_000e6);

        // 2,000 should succeed (exactly 20%)
        vm.prank(agent);
        wallet.transfer(recipient, 2_000e6);
        assertEq(usdc.balanceOf(recipient), 2_000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    // Safety 4: Daily spend limit
    // ═══════════════════════════════════════════════════════════════

    function test_dailyLimit_exceeded() public {
        vm.startPrank(agent);
        wallet.transfer(recipient, 200e6);
        wallet.transfer(recipient, 200e6);
        wallet.transfer(recipient, 200e6);
        wallet.transfer(recipient, 200e6);
        wallet.transfer(recipient, 200e6); // 1000 total

        vm.expectRevert(Errors.PaymentTooLarge.selector);
        wallet.transfer(recipient, 100e6);
        vm.stopPrank();
    }

    function test_dailyLimit_resetsAfter24h() public {
        vm.prank(agent);
        wallet.transfer(recipient, 200e6);
        assertEq(wallet.spentToday(), 200e6);

        vm.warp(block.timestamp + 1 days);

        vm.prank(agent);
        wallet.transfer(recipient, 200e6);
        assertEq(wallet.spentToday(), 200e6); // reset + new spend
    }

    // ═══════════════════════════════════════════════════════════════
    // Safety 5: Per-venue 50% exposure
    // ═══════════════════════════════════════════════════════════════

    function test_venueExposure_exceeded() public {
        // Fund wallet large enough so 20% per-trade limit is not a bottleneck.
        usdc.mint(address(wallet), 90_000e6); // total 100k
        vm.prank(human);
        wallet.setLimits(200_000e6, 20_000e6);

        // Send 10k chunks to same venue. Venue exposure check uses current balance.
        vm.startPrank(agent);
        wallet.transfer(recipient, 10_000e6); // venue=10k, bal=90k. Check: 10k <= 50%*100k=50k ✓
        wallet.transfer(recipient, 10_000e6); // venue=20k, bal=80k. Check: 20k <= 50%*90k=45k ✓
        wallet.transfer(recipient, 10_000e6); // venue=30k, bal=70k. Check: 30k <= 50%*80k=40k ✓
        // Next: venue would be 40k. maxVenue = 50%*70k = 35k. 40k > 35k → fail
        vm.expectRevert(Errors.ExceedsMaxAllocation.selector);
        wallet.transfer(recipient, 10_000e6);
        vm.stopPrank();
    }

    function test_venueExposure_trackedPerRecipient() public {
        address venue2 = makeAddr("venue2");
        // Use smaller amounts to stay within 20% per-trade limit
        vm.prank(agent);
        wallet.transfer(recipient, 100e6);
        vm.prank(agent);
        wallet.transfer(venue2, 100e6);

        assertEq(wallet.venueExposure(recipient), 100e6);
        assertEq(wallet.venueExposure(venue2), 100e6);
    }

    // ═══════════════════════════════════════════════════════════════
    // Safety 6: NAV health check on trade (tested with credit active)
    // ═══════════════════════════════════════════════════════════════

    function test_navHealthCheck_blocksTradeWhenLow() public {
        _setupCreditL1();

        // creditLimit = 500. L1 warning = 9500 bps (95%).
        // Need NAV after spend < 9500. NAV = (balance + collateral) * 10000 / creditLimit.
        // Simulate balance loss by transferring USDC out of the wallet directly.
        // Wallet has 10,000. Move 9,550 out so balance = 450.
        vm.prank(address(wallet));
        usdc.transfer(address(1), 9_550e6); // bal = 450
        // NAV = 450 * 10000 / 500 = 9000. Warning = 9500.
        // Any transfer would make NAV even lower → blocked.

        vm.prank(agent);
        vm.expectRevert(Errors.InsufficientBalance.selector);
        wallet.transfer(address(uint160(0x3000)), 10e6);
    }

    // ═══════════════════════════════════════════════════════════════
    // Collateral Deposit/Withdraw
    // ═══════════════════════════════════════════════════════════════

    function test_depositCollateral() public {
        usdc.mint(human, 1_000e6);
        vm.startPrank(human);
        usdc.approve(address(wallet), 1_000e6);
        wallet.depositCollateral(1_000e6);
        vm.stopPrank();
        assertEq(wallet.collateralAmount(), 1_000e6);
    }

    function test_depositCollateral_onlyOwner() public {
        usdc.mint(agent, 1_000e6);
        vm.startPrank(agent);
        usdc.approve(address(wallet), 1_000e6);
        vm.expectRevert(Errors.Unauthorized.selector);
        wallet.depositCollateral(1_000e6);
        vm.stopPrank();
    }

    function test_depositCollateral_zeroReverts() public {
        vm.prank(human);
        vm.expectRevert(Errors.ZeroAmount.selector);
        wallet.depositCollateral(0);
    }

    function test_withdrawCollateral_noCredit() public {
        usdc.mint(human, 1_000e6);
        vm.startPrank(human);
        usdc.approve(address(wallet), 1_000e6);
        wallet.depositCollateral(1_000e6);
        wallet.withdrawCollateral(500e6);
        vm.stopPrank();
        assertEq(wallet.collateralAmount(), 500e6);
        assertEq(usdc.balanceOf(human), 500e6);
    }

    function test_withdrawCollateral_exceedsBalance() public {
        usdc.mint(human, 1_000e6);
        vm.startPrank(human);
        usdc.approve(address(wallet), 1_000e6);
        wallet.depositCollateral(1_000e6);
        vm.expectRevert(Errors.InsufficientBalance.selector);
        wallet.withdrawCollateral(2_000e6);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    // Credit: requestCredit
    // ═══════════════════════════════════════════════════════════════

    function test_requestCredit_L1() public {
        _setupCreditL1();
        assertEq(wallet.creditDrawn(), 500e6);
        assertEq(wallet.totalDebt(), 500e6);
        assertEq(wallet.creditLevel(), 1);
        assertEq(wallet.creditLimit(), 500e6); // L1 = $500 fixed
    }

    function test_requestCredit_L2_leveraged() public {
        // L2 needs score >= 500 + KYA >= 1
        vm.startPrank(oracle);
        registry.updateKya(human, 1);
        registry.updateCreditScore(human, 550);
        vm.stopPrank();

        // Deposit collateral for L2 leverage (1x)
        usdc.mint(human, 5_000e6);
        vm.startPrank(human);
        usdc.approve(address(wallet), 5_000e6);
        wallet.depositCollateral(5_000e6);
        wallet.linkCreditVault(makeAddr("vault"));
        wallet.requestCredit(3_000e6, 1200, 2);
        vm.stopPrank();

        // L2 limit = min(collateral * 1, $20,000) = min(5000, 20000) = 5000
        assertEq(wallet.creditLimit(), 5_000e6);
        assertEq(wallet.creditDrawn(), 3_000e6);
    }

    function test_requestCredit_L3_leveraged() public {
        // L3: score >= 650 + KYA >= 2
        vm.startPrank(oracle);
        registry.updateKya(human, 2);
        registry.updateCreditScore(human, 700);
        vm.stopPrank();

        usdc.mint(human, 10_000e6);
        vm.startPrank(human);
        usdc.approve(address(wallet), 10_000e6);
        wallet.depositCollateral(10_000e6);
        wallet.linkCreditVault(makeAddr("vault"));
        wallet.requestCredit(15_000e6, 1000, 3);
        vm.stopPrank();

        // L3 limit = min(collateral * 2, $50,000) = min(20000, 50000) = 20000
        assertEq(wallet.creditLimit(), 20_000e6);
        assertEq(wallet.creditDrawn(), 15_000e6);
    }

    function test_requestCredit_reverts_L0() public {
        // Without KYA, agent is L0 → should fail
        vm.startPrank(human);
        wallet.linkCreditVault(makeAddr("vault"));
        vm.expectRevert(Errors.CreditTierTooLow.selector);
        wallet.requestCredit(100e6, 1200, 0);
        vm.stopPrank();
    }

    function test_requestCredit_reverts_ineligible() public {
        // Agent has no KYA → L0 but requests L1
        vm.startPrank(human);
        wallet.linkCreditVault(makeAddr("vault"));
        vm.expectRevert(Errors.CreditTierTooLow.selector);
        wallet.requestCredit(100e6, 1200, 1);
        vm.stopPrank();
    }

    function test_requestCredit_reverts_doubleCredit() public {
        _setupCreditL1();

        vm.prank(human);
        vm.expectRevert(Errors.InvalidAmount.selector);
        wallet.requestCredit(100e6, 1200, 1);
    }

    function test_requestCredit_reverts_exceedsLimit() public {
        vm.startPrank(oracle);
        registry.updateKya(human, 1);
        registry.updateCreditScore(human, 400);
        vm.stopPrank();

        vm.startPrank(human);
        wallet.linkCreditVault(makeAddr("vault"));
        vm.expectRevert(Errors.PaymentTooLarge.selector);
        wallet.requestCredit(600e6, 1200, 1); // L1 max = $500
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    // Credit: repay
    // ═══════════════════════════════════════════════════════════════

    function test_repay_full() public {
        address vault = makeAddr("vault");
        _setupCreditL1WithVault(vault);

        // Repay full debt
        vm.prank(human);
        wallet.repay(500e6);

        assertEq(wallet.creditDrawn(), 0);
        assertEq(wallet.totalDebt(), 0);
        assertEq(wallet.creditLimit(), 0);
        assertEq(wallet.totalRepaid(), 500e6);
        assertEq(usdc.balanceOf(vault), 500e6);
    }

    function test_repay_partial() public {
        address vault = makeAddr("vault");
        _setupCreditL1WithVault(vault);

        vm.prank(human);
        wallet.repay(200e6);

        assertEq(wallet.creditDrawn(), 300e6);
        assertEq(wallet.totalDebt(), 300e6);
        assertEq(wallet.totalRepaid(), 200e6);
        assertEq(usdc.balanceOf(vault), 200e6);
    }

    function test_repay_operatorCanRepay() public {
        address vault = makeAddr("vault");
        _setupCreditL1WithVault(vault);

        vm.prank(agent);
        wallet.repay(200e6);
        assertEq(wallet.totalRepaid(), 200e6);
    }

    function test_repay_reverts_noCredit() public {
        vm.prank(human);
        vm.expectRevert(Errors.InvalidAmount.selector);
        wallet.repay(100e6);
    }

    function test_repay_reverts_unauthorized() public {
        _setupCreditL1();
        vm.prank(recipient);
        vm.expectRevert(Errors.Unauthorized.selector);
        wallet.repay(100e6);
    }

    // ═══════════════════════════════════════════════════════════════
    // Health Check
    // ═══════════════════════════════════════════════════════════════

    function test_checkHealth_noCredit() public {
        wallet.checkHealth();
        assertEq(wallet.healthFactorBps(), type(uint16).max);
    }

    function test_checkHealth_autoFreezes() public {
        _setupCreditL1();
        // Wallet has 10,000 USDC. creditLimit = 500. NAV = 10000*10000/500 = 200000. Healthy.

        wallet.checkHealth();
        assertFalse(wallet.frozen());

        // Simulate a loss — transfer USDC out of wallet directly
        vm.prank(address(wallet));
        usdc.transfer(address(1), 9_600e6); // bal = 400
        // NAV = 400 * 10000 / 500 = 8000 < L1 warning (9500) → should auto-freeze

        wallet.checkHealth();
        assertTrue(wallet.frozen());
    }

    function test_checkHealth_autoUnfreezes() public {
        _setupCreditL1();

        // Drain to trigger freeze
        vm.prank(address(wallet));
        usdc.transfer(address(1), 9_700e6); // bal = 300
        wallet.checkHealth();
        assertTrue(wallet.frozen());

        // Inject USDC to recover. L1 healthy = trigger + 1000 = 9000 + 1000 = 10000.
        // Need NAV >= 10000. With creditLimit=500: balance >= 500.
        usdc.mint(address(wallet), 300e6); // bal = 600
        // NAV = 600 * 10000 / 500 = 12000 >= 10000 → should unfreeze
        wallet.checkHealth();
        assertFalse(wallet.frozen());
    }

    // ═══════════════════════════════════════════════════════════════
    // Liquidation
    // ═══════════════════════════════════════════════════════════════

    function test_liquidate_success() public {
        address vault = makeAddr("vault");
        _setupCreditL1WithVault(vault);

        // Drop NAV below L1 trigger (9000 = 90%)
        // creditLimit = 500. Need balance < 450.
        vm.prank(address(wallet));
        usdc.transfer(address(1), 9_700e6); // bal = 300

        // NAV = 300/500 = 6000 < 9000 → liquidatable
        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        wallet.liquidate();

        // keeper gets 0.5% of 300 = 1.5e6
        uint256 keeperReward = (300e6 * 50) / 10_000; // 1.5e6
        assertEq(usdc.balanceOf(keeper), keeperReward);

        // vault gets min(availableForRepay, totalDebt)
        // availableForRepay = 300 - 1.5 = 298.5. totalDebt = 500.
        // repayAmount = 298.5
        uint256 repayAmount = 300e6 - keeperReward;
        assertEq(usdc.balanceOf(vault), repayAmount);

        // Wallet state cleared
        assertEq(wallet.creditDrawn(), 0);
        assertEq(wallet.creditLimit(), 0);
        assertTrue(wallet.frozen()); // stays frozen post-liquidation
        assertFalse(wallet.isLiquidating()); // flag reset
    }

    function test_liquidate_reverts_healthAboveThreshold() public {
        _setupCreditL1();
        // NAV = 10500/500 = 21x → way above trigger
        vm.expectRevert(Errors.InvalidAmount.selector);
        wallet.liquidate();
    }

    function test_liquidate_reverts_noCredit() public {
        vm.expectRevert(Errors.InvalidAmount.selector);
        wallet.liquidate();
    }

    function test_liquidate_registryPenalty() public {
        address vault = makeAddr("vault");
        _setupCreditL1WithVault(vault);

        // Get initial score
        IAgentRegistry.Agent memory pre = registry.getAgent(human);
        uint16 preScore = pre.creditScore;

        // Trigger liquidation
        vm.prank(address(wallet));
        usdc.transfer(address(1), 9_700e6); // bal = 300
        wallet.liquidate();

        // Score should drop by 40 (or floor at 200)
        IAgentRegistry.Agent memory post = registry.getAgent(human);
        if (preScore > 240) {
            assertEq(post.creditScore, preScore - 40);
        } else {
            assertEq(post.creditScore, 200);
        }
        assertEq(post.liquidationCount, 1);
    }

    // ═══════════════════════════════════════════════════════════════
    // Owner Functions
    // ═══════════════════════════════════════════════════════════════

    function test_setOperator() public {
        address newAgent = makeAddr("newAgent");
        vm.prank(human);
        wallet.setOperator(newAgent);
        assertEq(wallet.operator(), newAgent);
    }

    function test_setOperator_zeroReverts() public {
        vm.prank(human);
        vm.expectRevert(Errors.ZeroAddress.selector);
        wallet.setOperator(address(0));
    }

    function test_setLimits() public {
        vm.prank(human);
        wallet.setLimits(5000e6, 500e6);
        assertEq(wallet.dailyLimit(), 5000e6);
        assertEq(wallet.perTxLimit(), 500e6);
    }

    function test_freeze_unfreeze() public {
        vm.prank(human);
        wallet.freeze();
        assertTrue(wallet.frozen());

        vm.prank(human);
        wallet.unfreeze();
        assertFalse(wallet.frozen());
    }

    function test_emergencyWithdraw() public {
        vm.prank(human);
        wallet.emergencyWithdraw(human);
        assertEq(usdc.balanceOf(human), 10_000e6);
        assertEq(usdc.balanceOf(address(wallet)), 0);
    }

    function test_emergencyWithdraw_onlyOwner() public {
        vm.prank(agent);
        vm.expectRevert(Errors.Unauthorized.selector);
        wallet.emergencyWithdraw(agent);
    }

    function test_emergencyWithdraw_blockedWithCredit() public {
        _setupCreditL1();
        vm.prank(human);
        vm.expectRevert(Errors.InvalidAmount.selector);
        wallet.emergencyWithdraw(human);
    }

    function test_linkCreditVault() public {
        address vault = makeAddr("vault");
        vm.prank(human);
        wallet.linkCreditVault(vault);
        assertEq(wallet.creditVault(), vault);
    }

    function test_getRemainingDaily() public {
        uint256 remaining = wallet.getRemainingDaily();
        assertEq(remaining, dailyLimit);

        vm.prank(agent);
        wallet.transfer(recipient, 100e6);

        remaining = wallet.getRemainingDaily();
        assertEq(remaining, dailyLimit - 100e6);
    }

    // ═══════════════════════════════════════════════════════════════
    // Ownership Transfer (2-step)
    // ═══════════════════════════════════════════════════════════════

    function test_ownershipTransfer() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(human);
        wallet.proposeOwnershipTransfer(newOwner, 0);
        assertEq(wallet.pendingOwner(), newOwner);

        vm.prank(newOwner);
        wallet.acceptOwnershipTransfer();
        assertEq(wallet.owner(), newOwner);
        assertEq(wallet.pendingOwner(), address(0));
    }

    function test_ownershipTransfer_onlyPending() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(human);
        wallet.proposeOwnershipTransfer(newOwner, 0);

        vm.prank(agent);
        vm.expectRevert(Errors.Unauthorized.selector);
        wallet.acceptOwnershipTransfer();
    }

    function test_cancelOwnershipTransfer() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(human);
        wallet.proposeOwnershipTransfer(newOwner, 0);

        vm.prank(human);
        wallet.cancelOwnershipTransfer();
        assertEq(wallet.pendingOwner(), address(0));
    }

    // ═══════════════════════════════════════════════════════════════
    // NAV Computation
    // ═══════════════════════════════════════════════════════════════

    function test_computeNav_noCredit() public view {
        assertEq(wallet.computeNav(), type(uint16).max);
    }

    function test_computeNav_withCredit() public {
        _setupCreditL1();
        // Balance = 10,500. creditLimit = 500. NAV = 10500 * 10000 / 500 = 210,000.
        // Capped at type(uint16).max = 65535.
        assertEq(wallet.computeNav(), type(uint16).max);
    }

    function test_navTriggerForLevel() public view {
        assertEq(wallet.navTriggerForLevel(1), 9_000);
        assertEq(wallet.navTriggerForLevel(2), 8_500);
        assertEq(wallet.navTriggerForLevel(3), 8_000);
        assertEq(wallet.navTriggerForLevel(4), 8_000);
        assertEq(wallet.navTriggerForLevel(0), 10_000); // L0 = immediate
    }

    // ═══════════════════════════════════════════════════════════════
    // Lifetime Stats
    // ═══════════════════════════════════════════════════════════════

    function test_lifetimeStats() public {
        vm.startPrank(agent);
        wallet.transfer(recipient, 100e6);
        wallet.transfer(recipient, 100e6);
        vm.stopPrank();

        assertEq(wallet.totalTrades(), 2);
        assertEq(wallet.totalVolume(), 200e6);
    }

    // ═══════════════════════════════════════════════════════════════
    // Credit Limit Calculations
    // ═══════════════════════════════════════════════════════════════

    function test_creditLimit_L4_fixed() public {
        // L4: score >= 750 + KYA >= 2 → $500K fixed
        vm.startPrank(oracle);
        registry.updateKya(human, 2);
        registry.updateCreditScore(human, 800);
        vm.stopPrank();

        usdc.mint(human, 100_000e6);
        vm.startPrank(human);
        usdc.approve(address(wallet), 100_000e6);
        wallet.depositCollateral(100_000e6);
        wallet.linkCreditVault(makeAddr("vault"));
        wallet.requestCredit(400_000e6, 800, 4);
        vm.stopPrank();

        assertEq(wallet.creditLimit(), 500_000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    // Factory: Admin & Pagination
    // ═══════════════════════════════════════════════════════════════

    function test_factory_adminTransfer() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        factory.proposeAdmin(newAdmin);

        vm.prank(newAdmin);
        factory.acceptAdmin();
        assertEq(factory.admin(), newAdmin);
    }

    function test_factory_getWallets_paginated() public {
        address[] memory wallets = factory.getWallets(0, 10);
        assertEq(wallets.length, 1);
        assertEq(wallets[0], address(wallet));
    }

    function test_factory_getWallets_outOfBounds() public view {
        address[] memory wallets = factory.getWallets(100, 10);
        assertEq(wallets.length, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    // Execute (generic calls for Polymarket etc.)
    // ═══════════════════════════════════════════════════════════════

    function test_execute_operatorCanCall() public {
        // Enable whitelist and whitelist USDC
        vm.startPrank(human);
        wallet.toggleWhitelist(true);
        wallet.setWhitelist(address(usdc), true);
        vm.stopPrank();

        // Operator calls usdc.approve via execute
        bytes memory data = abi.encodeCall(IERC20(address(usdc)).approve, (recipient, 1000e6));
        vm.prank(agent);
        wallet.execute(address(usdc), 0, data);

        assertEq(usdc.allowance(address(wallet), recipient), 1000e6);
        assertEq(wallet.totalTrades(), 1);
    }

    function test_execute_ownerCanCall() public {
        vm.startPrank(human);
        wallet.toggleWhitelist(true);
        wallet.setWhitelist(address(usdc), true);
        vm.stopPrank();

        bytes memory data = abi.encodeCall(IERC20(address(usdc)).approve, (recipient, 500e6));
        vm.prank(human);
        wallet.execute(address(usdc), 0, data);

        assertEq(usdc.allowance(address(wallet), recipient), 500e6);
    }

    function test_execute_rejectsNonWhitelisted() public {
        vm.prank(human);
        wallet.toggleWhitelist(true);
        // Don't whitelist usdc

        bytes memory data = abi.encodeCall(IERC20(address(usdc)).approve, (recipient, 100e6));
        vm.prank(agent);
        vm.expectRevert(Errors.TargetNotWhitelisted.selector);
        wallet.execute(address(usdc), 0, data);
    }

    function test_execute_requiresWhitelistEnabled() public {
        // Whitelist disabled by default
        bytes memory data = abi.encodeCall(IERC20(address(usdc)).approve, (recipient, 100e6));
        vm.prank(agent);
        vm.expectRevert(Errors.TargetNotWhitelisted.selector);
        wallet.execute(address(usdc), 0, data);
    }

    function test_execute_rejectsUnauthorized() public {
        vm.prank(human);
        wallet.toggleWhitelist(true);

        bytes memory data = abi.encodeCall(IERC20(address(usdc)).approve, (recipient, 100e6));
        vm.prank(recipient); // unauthorized
        vm.expectRevert(Errors.Unauthorized.selector);
        wallet.execute(address(usdc), 0, data);
    }

    function test_execute_frozen() public {
        vm.startPrank(human);
        wallet.toggleWhitelist(true);
        wallet.setWhitelist(address(usdc), true);
        wallet.freeze();
        vm.stopPrank();

        bytes memory data = abi.encodeCall(IERC20(address(usdc)).approve, (recipient, 100e6));
        vm.prank(agent);
        vm.expectRevert(Errors.VaultPaused.selector);
        wallet.execute(address(usdc), 0, data);
    }

    // ═══════════════════════════════════════════════════════════════
    // Batch Execute
    // ═══════════════════════════════════════════════════════════════

    function test_batchExecute_multipleApprovals() public {
        address venue1 = makeAddr("venue1");
        address venue2 = makeAddr("venue2");

        vm.startPrank(human);
        wallet.toggleWhitelist(true);
        wallet.setWhitelist(address(usdc), true);
        vm.stopPrank();

        address[] memory targets = new address[](2);
        targets[0] = address(usdc);
        targets[1] = address(usdc);

        uint256[] memory values = new uint256[](2);
        values[0] = 0;
        values[1] = 0;

        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = abi.encodeCall(IERC20(address(usdc)).approve, (venue1, 1000e6));
        calldatas[1] = abi.encodeCall(IERC20(address(usdc)).approve, (venue2, 2000e6));

        vm.prank(agent);
        wallet.batchExecute(targets, values, calldatas);

        assertEq(usdc.allowance(address(wallet), venue1), 1000e6);
        assertEq(usdc.allowance(address(wallet), venue2), 2000e6);
        assertEq(wallet.totalTrades(), 2);
    }

    function test_batchExecute_revertOnMismatchedArrays() public {
        vm.prank(human);
        wallet.toggleWhitelist(true);

        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](1); // wrong length
        bytes[] memory calldatas = new bytes[](2);

        vm.prank(agent);
        vm.expectRevert(Errors.InvalidAmount.selector);
        wallet.batchExecute(targets, values, calldatas);
    }

    // ═══════════════════════════════════════════════════════════════
    // ERC-1271 Signature Validation
    // ═══════════════════════════════════════════════════════════════

    function test_isValidSignature_ownerEOA() public {
        (address signer, uint256 signerKey) = makeAddrAndKey("signer");

        // Deploy a wallet with signer as owner
        vm.prank(signer);
        address w = factory.createWallet(agent, dailyLimit, perTxLimit);
        AgentWallet signerWallet = AgentWallet(payable(w));

        bytes32 hash = keccak256("test message");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, hash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes4 result = signerWallet.isValidSignature(hash, signature);
        assertEq(result, bytes4(0x1626ba7e));
    }

    function test_isValidSignature_operatorEOA() public {
        (address operatorSigner, uint256 operatorKey) = makeAddrAndKey("operatorSigner");

        // Set operator to the signer
        vm.prank(human);
        wallet.setOperator(operatorSigner);

        bytes32 hash = keccak256("polymarket order");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorKey, hash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes4 result = wallet.isValidSignature(hash, signature);
        assertEq(result, bytes4(0x1626ba7e));
    }

    function test_isValidSignature_rejectsRandom() public {
        (, uint256 randomKey) = makeAddrAndKey("random");

        bytes32 hash = keccak256("test message");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(randomKey, hash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes4 result = wallet.isValidSignature(hash, signature);
        assertEq(result, bytes4(0xffffffff));
    }

    // ═══════════════════════════════════════════════════════════════
    // ERC-1155 Receiver
    // ═══════════════════════════════════════════════════════════════

    function test_onERC721Received_returnsSelector() public view {
        bytes4 result = wallet.onERC721Received(address(0), address(0), 0, "");
        assertEq(result, bytes4(0x150b7a02));
    }

    function test_supportsInterface_ERC721Receiver() public view {
        // IERC721Receiver interfaceId = 0x150b7a02
        assertTrue(wallet.supportsInterface(0x150b7a02));
    }

    function test_supportsInterface_ERC1155Receiver() public view {
        // IERC1155Receiver interfaceId = 0x4e2312e0
        assertTrue(wallet.supportsInterface(0x4e2312e0));
    }

    function test_supportsInterface_ERC1271() public view {
        // IERC1271 interfaceId
        assertTrue(wallet.supportsInterface(type(IERC1271).interfaceId));
    }

    function test_supportsInterface_ERC165() public view {
        assertTrue(wallet.supportsInterface(0x01ffc9a7));
    }

    function test_onERC1155Received_returnsSelector() public view {
        bytes4 result = wallet.onERC1155Received(address(0), address(0), 0, 0, "");
        assertEq(result, bytes4(0xf23a6e61));
    }

    function test_onERC1155BatchReceived_returnsSelector() public view {
        uint256[] memory ids = new uint256[](0);
        uint256[] memory amounts = new uint256[](0);
        bytes4 result = wallet.onERC1155BatchReceived(address(0), address(0), ids, amounts, "");
        assertEq(result, bytes4(0xbc197c81));
    }

    // ═══════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════

    function _setupCreditL1() internal {
        vm.startPrank(oracle);
        registry.updateKya(human, 1);
        registry.updateCreditScore(human, 400);
        vm.stopPrank();

        // Authorize wallet as walletProgram so recordLiquidation works
        vm.prank(admin);
        registry.setWalletProgram(address(wallet));

        vm.startPrank(human);
        wallet.linkCreditVault(makeAddr("vault"));
        wallet.requestCredit(500e6, 1200, 1);
        vm.stopPrank();
    }

    function _setupCreditL1WithVault(address vault) internal {
        vm.startPrank(oracle);
        registry.updateKya(human, 1);
        registry.updateCreditScore(human, 400);
        vm.stopPrank();

        vm.prank(admin);
        registry.setWalletProgram(address(wallet));

        vm.startPrank(human);
        wallet.linkCreditVault(vault);
        wallet.requestCredit(500e6, 1200, 1);
        vm.stopPrank();
    }
}
