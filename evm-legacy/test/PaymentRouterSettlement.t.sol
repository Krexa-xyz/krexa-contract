// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {MerchantVault} from "../src/MerchantVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {Errors} from "../src/libraries/Errors.sol";

/// @notice Tests for settlement lifecycle: update, deactivate, rate limiting, max payment cap
contract PaymentRouterSettlementTest is Test {
    MockUSDC public usdc;
    AgentRegistry public registry;
    PaymentRouter public router;
    MerchantVault public vault;

    uint256 oraclePrivKey = 0xA11CE;
    address oracle = vm.addr(0xA11CE);
    address admin = makeAddr("admin");
    address borrower = makeAddr("translateBot");
    address payer = makeAddr("shopBot");
    address feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        usdc = new MockUSDC();
        registry = new AgentRegistry(admin, oracle);
        router = new PaymentRouter(address(usdc), address(registry), admin, oracle);

        vm.prank(admin);
        registry.setPaymentRouter(address(router));
        vm.prank(admin);
        router.setFactory(admin); // admin acts as factory for test

        // Ensure block.timestamp is large enough to not trigger rate limits on first payment
        vm.warp(1000);

        // Deploy and fund vault
        vault = new MerchantVault(MerchantVault.VaultParams({
            usdc: address(usdc),
            agent: borrower,
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
        vm.prank(borrower);
        registry.registerAgent("ipfs://translateBot");
        vm.prank(payer);
        registry.registerAgent("ipfs://shopBot");

        usdc.mint(payer, 1_000_000e6);
    }

    // ════════════════════════════════════════════════════════════════
    // 1. Rate limiting
    // ════════════════════════════════════════════════════════════════

    function test_rateLimit_blocksImmediateSecondPayment() public {
        // Create settlement with 60-second minimum interval
        vm.prank(admin);
        router.createSettlement(borrower, address(vault), 1500, 60, 0);

        // First payment succeeds
        _pay(payer, borrower, 100e6, 1, block.timestamp + 300);

        // Second payment immediately → rate limited
        vm.prank(payer);
        usdc.approve(address(router), 100e6);
        bytes32 paymentId = keccak256("pay2");
        bytes memory sig = _signPayment(payer, borrower, 100e6, 2, block.timestamp + 300, paymentId);

        vm.expectRevert(Errors.RateLimitExceeded.selector);
        router.executePayment(
            IPaymentRouter.X402Payment(payer, borrower, 100e6, 2, block.timestamp + 300, paymentId),
            sig
        );
    }

    function test_rateLimit_afterIntervalSucceeds() public {
        vm.prank(admin);
        router.createSettlement(borrower, address(vault), 1500, 60, 0);

        _pay(payer, borrower, 100e6, 1, block.timestamp + 300);

        // Warp past interval
        vm.warp(block.timestamp + 61);

        // Second payment now succeeds
        _pay(payer, borrower, 100e6, 2, block.timestamp + 300);

        IPaymentRouter.Settlement memory s = router.getSettlement(borrower);
        assertEq(s.totalPayments, 2);
    }

    function test_rateLimit_zeroInterval_noRestriction() public {
        // minPaymentInterval = 0 means no restriction
        vm.prank(admin);
        router.createSettlement(borrower, address(vault), 1500, 0, 0);

        _pay(payer, borrower, 100e6, 1, block.timestamp + 300);
        _pay(payer, borrower, 100e6, 2, block.timestamp + 300);
        _pay(payer, borrower, 100e6, 3, block.timestamp + 300);

        IPaymentRouter.Settlement memory s = router.getSettlement(borrower);
        assertEq(s.totalPayments, 3);
    }

    // ════════════════════════════════════════════════════════════════
    // 2. Max single payment cap
    // ════════════════════════════════════════════════════════════════

    function test_maxSinglePayment_exceeded_reverts() public {
        vm.prank(admin);
        router.createSettlement(borrower, address(vault), 1500, 0, 500e6); // max 500 USDC

        uint256 deadline = block.timestamp + 300;
        bytes32 paymentId = keccak256("bigpay");
        bytes memory sig = _signPayment(payer, borrower, 501e6, 1, deadline, paymentId);

        vm.prank(payer);
        usdc.approve(address(router), 501e6);

        vm.expectRevert(Errors.PaymentTooLarge.selector);
        router.executePayment(
            IPaymentRouter.X402Payment(payer, borrower, 501e6, 1, deadline, paymentId),
            sig
        );
    }

    function test_maxSinglePayment_exactLimit_succeeds() public {
        vm.prank(admin);
        router.createSettlement(borrower, address(vault), 1500, 0, 500e6);

        _pay(payer, borrower, 500e6, 1, block.timestamp + 300);

        IPaymentRouter.Settlement memory s = router.getSettlement(borrower);
        assertEq(s.totalPayments, 1);
    }

    function test_maxSinglePayment_zeroMeansUnlimited() public {
        vm.prank(admin);
        router.createSettlement(borrower, address(vault), 1500, 0, 0); // 0 = unlimited

        _pay(payer, borrower, 100_000e6, 1, block.timestamp + 300); // huge payment

        IPaymentRouter.Settlement memory s = router.getSettlement(borrower);
        assertEq(s.totalPayments, 1);
    }

    // ════════════════════════════════════════════════════════════════
    // 3. deactivateSettlement
    // ════════════════════════════════════════════════════════════════

    function test_deactivateSettlement_directPaymentAfter() public {
        vm.prank(admin);
        router.createSettlement(borrower, address(vault), 1500, 0, 0);

        vm.prank(admin);
        router.deactivateSettlement(borrower);

        IPaymentRouter.Settlement memory s = router.getSettlement(borrower);
        assertFalse(s.active);

        // Payment should now go direct (no vault routing)
        uint256 vaultBalBefore = usdc.balanceOf(address(vault));
        uint256 borrowerBefore = usdc.balanceOf(borrower);

        _pay(payer, borrower, 1000e6, 1, block.timestamp + 300);

        // Borrower gets full 1000 (no repayment split)
        assertEq(usdc.balanceOf(borrower) - borrowerBefore, 1000e6);
        // Vault balance unchanged
        assertEq(usdc.balanceOf(address(vault)), vaultBalBefore);
    }

    function test_deactivateSettlement_onlyAdmin_reverts() public {
        vm.prank(admin);
        router.createSettlement(borrower, address(vault), 1500, 0, 0);

        vm.prank(payer);
        vm.expectRevert(Errors.Unauthorized.selector);
        router.deactivateSettlement(borrower);
    }

    // ════════════════════════════════════════════════════════════════
    // 4. updateSettlement
    // ════════════════════════════════════════════════════════════════

    function test_updateSettlement_changesRepaymentRate() public {
        vm.prank(admin);
        router.createSettlement(borrower, address(vault), 1500, 0, 0); // 15%

        vm.prank(admin);
        router.updateSettlement(borrower, 2000); // change to 20%

        IPaymentRouter.Settlement memory s = router.getSettlement(borrower);
        assertEq(s.repaymentRateBps, 2000);

        // Verify actual split at 20%
        uint256 borrowerBefore = usdc.balanceOf(borrower);
        _pay(payer, borrower, 1000e6, 1, block.timestamp + 300);

        assertEq(usdc.balanceOf(borrower) - borrowerBefore, 800e6); // 80% net
    }

    function test_updateSettlement_onlyAdmin_reverts() public {
        vm.prank(admin);
        router.createSettlement(borrower, address(vault), 1500, 0, 0);

        vm.prank(payer);
        vm.expectRevert(Errors.Unauthorized.selector);
        router.updateSettlement(borrower, 2000);
    }

    function test_updateSettlement_maxRate_reverts() public {
        vm.prank(admin);
        router.createSettlement(borrower, address(vault), 1500, 0, 0);

        vm.prank(admin);
        vm.expectRevert(Errors.FeeTooHigh.selector);
        router.updateSettlement(borrower, 5001);
    }

    // ════════════════════════════════════════════════════════════════
    // 5. Settlement stats tracking
    // ════════════════════════════════════════════════════════════════

    function test_settlement_statsAccumulate() public {
        vm.prank(admin);
        router.createSettlement(borrower, address(vault), 1500, 0, 0);

        _pay(payer, borrower, 1000e6, 1, block.timestamp + 300);
        _pay(payer, borrower, 2000e6, 2, block.timestamp + 300);
        _pay(payer, borrower, 500e6, 3, block.timestamp + 300);

        IPaymentRouter.Settlement memory s = router.getSettlement(borrower);
        assertEq(s.totalPayments, 3);
        // 15% of (1000 + 2000 + 500) = 15% of 3500 = 525
        assertEq(s.totalRouted, 525e6);
    }

    // ════════════════════════════════════════════════════════════════
    // Helpers
    // ════════════════════════════════════════════════════════════════

    function _pay(address from, address to, uint256 amount, uint256 nonce, uint256 deadline) internal {
        bytes32 paymentId = keccak256(abi.encodePacked("pay", nonce));
        bytes memory sig = _signPayment(from, to, amount, nonce, deadline, paymentId);
        vm.prank(from);
        usdc.approve(address(router), amount);
        router.executePayment(IPaymentRouter.X402Payment(from, to, amount, nonce, deadline, paymentId), sig);
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
