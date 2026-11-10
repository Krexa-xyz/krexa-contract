// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Krexa402Facilitator} from "../src/Krexa402Facilitator.sol";
import {IKrexa402Facilitator} from "../src/interfaces/IKrexa402Facilitator.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {Errors} from "../src/libraries/Errors.sol";

contract Krexa402FacilitatorTest is Test {
    MockUSDC public usdc;
    AgentRegistry public registry;
    PaymentRouter public router;
    Krexa402Facilitator public facilitator;

    uint256 oraclePrivKey = 0xA11CE;
    address oracle = vm.addr(oraclePrivKey);
    address admin = makeAddr("admin");
    address merchant = makeAddr("merchant");
    address payer = makeAddr("payer");

    uint16 facilitatorFeeBps = 250; // 2.5%

    function setUp() public {
        usdc = new MockUSDC();
        registry = new AgentRegistry(admin, oracle);
        router = new PaymentRouter(address(usdc), address(registry), admin, oracle);
        facilitator = new Krexa402Facilitator(
            address(usdc), address(router), admin, facilitatorFeeBps
        );

        vm.startPrank(admin);
        registry.setPaymentRouter(address(router));
        // Approve facilitator in the router
        router.setFacilitator(address(facilitator), true);
        vm.stopPrank();

        // Register agents
        vm.prank(merchant);
        registry.registerAgent("ipfs://merchant");
        vm.prank(payer);
        registry.registerAgent("ipfs://payer");

        // Fund payer
        usdc.mint(payer, 100_000e6);
    }

    // ─── Helpers ──────────────────────────────────────────────────

    function _registerResource(address owner, uint256 price) internal returns (bytes32 key) {
        bytes32 rawHash = keccak256("https://api.example.com/translate");
        key = facilitator.resourceKey(rawHash, owner);
        vm.prank(owner);
        facilitator.registerResource(rawHash, price);
    }

    // ════════════════════════════════════════════════════════════════
    // 1. Resource registration
    // ════════════════════════════════════════════════════════════════

    function test_registerResource() public {
        bytes32 key = _registerResource(merchant, 5e6);

        IKrexa402Facilitator.Resource memory res = facilitator.getResource(key);
        assertEq(res.owner, merchant);
        assertEq(res.pricePerCall, 5e6);
        assertTrue(res.active);
    }

    function test_registerResource_revertDuplicate() public {
        bytes32 rawHash = keccak256("https://api.example.com/translate");
        vm.prank(merchant);
        facilitator.registerResource(rawHash, 5e6);

        // Same sender + same hash → same key → revert
        vm.prank(merchant);
        vm.expectRevert(Errors.VaultAlreadyExists.selector);
        facilitator.registerResource(rawHash, 10e6);
    }

    function test_registerResource_differentOwners_noConflict() public {
        bytes32 rawHash = keccak256("https://api.example.com/translate");

        // Merchant registers first
        vm.prank(merchant);
        facilitator.registerResource(rawHash, 5e6);

        // Payer registers same rawHash — different key, no conflict
        vm.prank(payer);
        facilitator.registerResource(rawHash, 3e6);

        bytes32 merchantKey = facilitator.resourceKey(rawHash, merchant);
        bytes32 payerKey = facilitator.resourceKey(rawHash, payer);

        assertTrue(merchantKey != payerKey);
        assertEq(facilitator.getResource(merchantKey).owner, merchant);
        assertEq(facilitator.getResource(payerKey).owner, payer);
    }

    function test_updateResourcePrice() public {
        bytes32 key = _registerResource(merchant, 5e6);

        vm.prank(merchant);
        facilitator.updateResourcePrice(key, 10e6);

        IKrexa402Facilitator.Resource memory res = facilitator.getResource(key);
        assertEq(res.pricePerCall, 10e6);
    }

    function test_updateResourcePrice_onlyOwner() public {
        bytes32 key = _registerResource(merchant, 5e6);

        vm.prank(payer);
        vm.expectRevert(Errors.Unauthorized.selector);
        facilitator.updateResourcePrice(key, 10e6);
    }

    function test_deactivateResource() public {
        bytes32 key = _registerResource(merchant, 5e6);

        vm.prank(merchant);
        facilitator.deactivateResource(key);

        IKrexa402Facilitator.Resource memory res = facilitator.getResource(key);
        assertFalse(res.active);
    }

    function test_reactivateResource() public {
        bytes32 key = _registerResource(merchant, 5e6);

        vm.prank(merchant);
        facilitator.deactivateResource(key);
        assertFalse(facilitator.getResource(key).active);

        vm.prank(merchant);
        facilitator.reactivateResource(key);
        assertTrue(facilitator.getResource(key).active);
    }

    // ════════════════════════════════════════════════════════════════
    // 2. Admin fee management
    // ════════════════════════════════════════════════════════════════

    function test_setFacilitatorFeeBps() public {
        vm.prank(admin);
        facilitator.setFacilitatorFeeBps(500);
        assertEq(facilitator.facilitatorFeeBps(), 500);
    }

    function test_setFacilitatorFeeBps_revertTooHigh() public {
        vm.prank(admin);
        vm.expectRevert(Errors.FeeTooHigh.selector);
        facilitator.setFacilitatorFeeBps(1001);
    }

    function test_setFacilitatorFeeBps_onlyAdmin() public {
        vm.prank(payer);
        vm.expectRevert(Errors.Unauthorized.selector);
        facilitator.setFacilitatorFeeBps(500);
    }

    // ════════════════════════════════════════════════════════════════
    // 3. executeX402Payment — full execution path (BUG-013)
    // ════════════════════════════════════════════════════════════════

    function test_executeX402Payment_success() public {
        bytes32 key = _registerResource(merchant, 100e6); // $100/call

        uint256 paymentAmount = 100e6;
        uint256 expectedFee = (paymentAmount * facilitatorFeeBps) / 10_000; // 2.5e6
        uint256 expectedNet = paymentAmount - expectedFee; // 97.5e6

        // Payer approves facilitator
        vm.prank(payer);
        usdc.approve(address(facilitator), paymentAmount);

        uint256 merchantBefore = usdc.balanceOf(merchant);
        uint256 adminBefore = usdc.balanceOf(admin);

        IPaymentRouter.X402Payment memory payment = IPaymentRouter.X402Payment({
            from: payer,
            to: merchant,
            amount: paymentAmount,
            nonce: 1,
            deadline: block.timestamp + 300,
            paymentId: keccak256("pay1")
        });

        vm.prank(payer);
        facilitator.executeX402Payment(key, payment, "");

        // Admin gets facilitator fee
        assertEq(usdc.balanceOf(admin) - adminBefore, expectedFee);
        // Merchant gets net amount (routed through PaymentRouter)
        assertEq(usdc.balanceOf(merchant) - merchantBefore, expectedNet);
    }

    function test_executeX402Payment_feeDistribution() public {
        // Test with 0% fee
        vm.prank(admin);
        facilitator.setFacilitatorFeeBps(0);

        bytes32 key = _registerResource(merchant, 50e6);

        vm.prank(payer);
        usdc.approve(address(facilitator), 50e6);

        uint256 merchantBefore = usdc.balanceOf(merchant);
        uint256 adminBefore = usdc.balanceOf(admin);

        IPaymentRouter.X402Payment memory payment = IPaymentRouter.X402Payment({
            from: payer,
            to: merchant,
            amount: 50e6,
            nonce: 1,
            deadline: block.timestamp + 300,
            paymentId: keccak256("pay2")
        });

        vm.prank(payer);
        facilitator.executeX402Payment(key, payment, "");

        // Zero fee → admin gets nothing, merchant gets all
        assertEq(usdc.balanceOf(admin) - adminBefore, 0);
        assertEq(usdc.balanceOf(merchant) - merchantBefore, 50e6);
    }

    function test_executeX402Payment_replayProtection() public {
        bytes32 key = _registerResource(merchant, 10e6);

        vm.startPrank(payer);
        usdc.approve(address(facilitator), 20e6);
        vm.stopPrank();

        IPaymentRouter.X402Payment memory payment = IPaymentRouter.X402Payment({
            from: payer,
            to: merchant,
            amount: 10e6,
            nonce: 42,
            deadline: block.timestamp + 300,
            paymentId: keccak256("pay3")
        });

        vm.prank(payer);
        facilitator.executeX402Payment(key, payment, "");

        // Same nonce again → replay blocked
        vm.prank(payer);
        usdc.approve(address(facilitator), 10e6);
        vm.prank(payer);
        vm.expectRevert(Errors.NonceAlreadyUsed.selector);
        facilitator.executeX402Payment(key, payment, "");
    }

    function test_executeX402Payment_inactiveResource_reverts() public {
        bytes32 key = _registerResource(merchant, 10e6);

        vm.prank(merchant);
        facilitator.deactivateResource(key);

        vm.prank(payer);
        usdc.approve(address(facilitator), 10e6);

        IPaymentRouter.X402Payment memory payment = IPaymentRouter.X402Payment({
            from: payer,
            to: merchant,
            amount: 10e6,
            nonce: 1,
            deadline: block.timestamp + 300,
            paymentId: keccak256("pay4")
        });

        vm.prank(payer);
        vm.expectRevert(Errors.SettlementNotActive.selector);
        facilitator.executeX402Payment(key, payment, "");
    }

    function test_executeX402Payment_amountBelowPrice_reverts() public {
        bytes32 key = _registerResource(merchant, 100e6);

        vm.prank(payer);
        usdc.approve(address(facilitator), 50e6);

        IPaymentRouter.X402Payment memory payment = IPaymentRouter.X402Payment({
            from: payer,
            to: merchant,
            amount: 50e6, // below 100e6 price
            nonce: 1,
            deadline: block.timestamp + 300,
            paymentId: keccak256("pay5")
        });

        vm.prank(payer);
        vm.expectRevert(Errors.InvalidAmount.selector);
        facilitator.executeX402Payment(key, payment, "");
    }

    function test_executeX402Payment_wrongRecipient_reverts() public {
        bytes32 key = _registerResource(merchant, 10e6);

        vm.prank(payer);
        usdc.approve(address(facilitator), 10e6);

        IPaymentRouter.X402Payment memory payment = IPaymentRouter.X402Payment({
            from: payer,
            to: payer, // not the resource owner (merchant)
            amount: 10e6,
            nonce: 1,
            deadline: block.timestamp + 300,
            paymentId: keccak256("pay6")
        });

        vm.prank(payer);
        vm.expectRevert(Errors.Unauthorized.selector);
        facilitator.executeX402Payment(key, payment, "");
    }

    function test_executeX402Payment_expiredDeadline_reverts() public {
        bytes32 key = _registerResource(merchant, 10e6);

        vm.prank(payer);
        usdc.approve(address(facilitator), 10e6);

        IPaymentRouter.X402Payment memory payment = IPaymentRouter.X402Payment({
            from: payer,
            to: merchant,
            amount: 10e6,
            nonce: 1,
            deadline: block.timestamp - 1, // already expired
            paymentId: keccak256("pay7")
        });

        vm.prank(payer);
        vm.expectRevert(Errors.PaymentExpired.selector);
        facilitator.executeX402Payment(key, payment, "");
    }

    function test_executeX402Payment_overpayment_succeeds() public {
        bytes32 key = _registerResource(merchant, 10e6);

        uint256 overpay = 50e6; // 5x the price — allowed
        vm.prank(payer);
        usdc.approve(address(facilitator), overpay);

        uint256 expectedFee = (overpay * facilitatorFeeBps) / 10_000;

        uint256 merchantBefore = usdc.balanceOf(merchant);
        uint256 adminBefore = usdc.balanceOf(admin);

        IPaymentRouter.X402Payment memory payment = IPaymentRouter.X402Payment({
            from: payer,
            to: merchant,
            amount: overpay,
            nonce: 1,
            deadline: block.timestamp + 300,
            paymentId: keccak256("pay8")
        });

        vm.prank(payer);
        facilitator.executeX402Payment(key, payment, "");

        assertEq(usdc.balanceOf(admin) - adminBefore, expectedFee);
        assertEq(usdc.balanceOf(merchant) - merchantBefore, overpay - expectedFee);
    }

    // ════════════════════════════════════════════════════════════════
    // 4. BUG-020: Unauthorized payer check
    // ════════════════════════════════════════════════════════════════

    function test_executeX402Payment_wrongCaller_reverts() public {
        bytes32 key = _registerResource(merchant, 10e6);

        // Fund and approve from payer
        vm.prank(payer);
        usdc.approve(address(facilitator), 10e6);

        IPaymentRouter.X402Payment memory payment = IPaymentRouter.X402Payment({
            from: payer,        // victim's address
            to: merchant,
            amount: 10e6,
            nonce: 1,
            deadline: block.timestamp + 300,
            paymentId: keccak256("pay9")
        });

        // Someone else (admin) tries to trigger payment on behalf of payer — must revert
        vm.prank(admin);
        vm.expectRevert(Errors.Unauthorized.selector);
        facilitator.executeX402Payment(key, payment, "");
    }
}
