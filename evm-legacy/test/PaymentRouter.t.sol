// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {MerchantVault} from "../src/MerchantVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {Errors} from "../src/libraries/Errors.sol";

contract PaymentRouterTest is Test {
    MockUSDC public usdc;
    AgentRegistry public registry;
    PaymentRouter public router;
    MerchantVault public vault;

    uint256 oraclePrivKey = 0xA11CE;
    address oracle = vm.addr(oraclePrivKey);
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

        // Create vault for borrower
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

        // Fund vault so it's active
        usdc.mint(address(this), 50_000e6);
        usdc.approve(address(vault), 50_000e6);
        vault.investSenior(50_000e6);

        // Register agents
        vm.prank(borrower);
        registry.registerAgent("ipfs://translateBot");
        vm.prank(payer);
        registry.registerAgent("ipfs://shopBot");

        // Create settlement: 15% repayment rate
        vm.prank(admin);
        router.setFactory(admin);
        vm.prank(admin);
        router.createSettlement(borrower, address(vault), 1500, 0, 0);

        // Fund payer
        usdc.mint(payer, 100_000e6);
    }

    function test_executePayment_withSettlement() public {
        uint256 amount = 1000e6;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 300;
        bytes32 paymentId = keccak256("payment1");

        bytes memory sig = _signPayment(payer, borrower, amount, nonce, deadline, paymentId);

        vm.prank(payer);
        usdc.approve(address(router), amount);

        router.executePayment(
            IPaymentRouter.X402Payment(payer, borrower, amount, nonce, deadline, paymentId),
            sig
        );

        // 15% = 150 USDC to vault, 850 to borrower
        assertEq(usdc.balanceOf(borrower), 850e6);
        assertTrue(vault.totalRepaid() > 0);
        assertTrue(router.isNonceUsed(payer, nonce));
    }

    function test_executePayment_directPayment() public {
        // Agent with no settlement
        address receiver = makeAddr("receiver");
        vm.prank(receiver);
        registry.registerAgent("ipfs://receiver");

        uint256 amount = 500e6;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 300;
        bytes32 paymentId = keccak256("direct1");

        bytes memory sig = _signPayment(payer, receiver, amount, nonce, deadline, paymentId);

        vm.prank(payer);
        usdc.approve(address(router), amount);

        router.executePayment(
            IPaymentRouter.X402Payment(payer, receiver, amount, nonce, deadline, paymentId),
            sig
        );

        assertEq(usdc.balanceOf(receiver), 500e6);
    }

    function test_executePayment_replayProtection() public {
        uint256 amount = 100e6;
        uint256 nonce = 42;
        uint256 deadline = block.timestamp + 300;
        bytes32 paymentId = keccak256("replay");

        bytes memory sig = _signPayment(payer, borrower, amount, nonce, deadline, paymentId);

        vm.startPrank(payer);
        usdc.approve(address(router), amount * 2);
        router.executePayment(
            IPaymentRouter.X402Payment(payer, borrower, amount, nonce, deadline, paymentId),
            sig
        );

        vm.expectRevert(Errors.NonceAlreadyUsed.selector);
        router.executePayment(
            IPaymentRouter.X402Payment(payer, borrower, amount, nonce, deadline, paymentId),
            sig
        );
        vm.stopPrank();
    }

    function test_executePayment_expiredDeadline() public {
        uint256 deadline = block.timestamp - 1;
        bytes32 paymentId = keccak256("expired");
        bytes memory sig = _signPayment(payer, borrower, 100e6, 1, deadline, paymentId);

        vm.prank(payer);
        vm.expectRevert(Errors.PaymentExpired.selector);
        router.executePayment(
            IPaymentRouter.X402Payment(payer, borrower, 100e6, 1, deadline, paymentId),
            sig
        );
    }

    function test_createSettlement_maxRate() public {
        vm.prank(admin);
        vm.expectRevert(Errors.FeeTooHigh.selector);
        router.createSettlement(payer, address(vault), 5001, 0, 0);
    }

    // ─── Helpers ─────────────────────────────────────────────────

    function _signPayment(
        address from, address to, uint256 amount, uint256 nonce, uint256 deadline, bytes32 paymentId
    ) internal view returns (bytes memory) {
        bytes32 msgHash = keccak256(abi.encode(from, to, amount, nonce, deadline, paymentId));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oraclePrivKey, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }
}
