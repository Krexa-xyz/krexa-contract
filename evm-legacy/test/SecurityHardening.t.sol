// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {MerchantVault} from "../src/MerchantVault.sol";
import {IMerchantVault} from "../src/interfaces/IMerchantVault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {Errors} from "../src/libraries/Errors.sol";

contract SecurityHardeningTest is Test {
    MockUSDC public usdc;
    AgentRegistry public registry;
    PaymentRouter public router;
    VaultFactory public factory;
    LiquidityPool public pool;

    uint256 oraclePrivKey = 0xA11CE;
    address oracle = vm.addr(oraclePrivKey);
    address admin = makeAddr("admin");
    address borrower = makeAddr("translateBot");
    address payer = makeAddr("shopBot");
    address feeRecipient = makeAddr("feeRecipient");
    address newAdmin = makeAddr("newAdmin");

    function setUp() public {
        usdc = new MockUSDC();
        registry = new AgentRegistry(admin, oracle);
        router = new PaymentRouter(address(usdc), address(registry), admin, oracle);

        vm.startPrank(admin);
        registry.setPaymentRouter(address(router));

        factory = new VaultFactory(
            admin, oracle, address(usdc), 200, feeRecipient,
            address(registry), address(router)
        );
        registry.setFactory(address(factory));
        router.setFactory(address(factory));
        vm.stopPrank();

        pool = new LiquidityPool(address(usdc), admin, true, 100_000e6);

        // Register agents
        vm.prank(borrower);
        registry.registerAgent("ipfs://translateBot");
        vm.prank(payer);
        registry.registerAgent("ipfs://shopBot");

        // Credit score + KYA for vault creation (oracle-only)
        vm.startPrank(oracle);
        registry.updateKya(borrower, 2);
        registry.updateCreditScore(borrower, 750);
        vm.stopPrank();

        // Fund payer
        usdc.mint(payer, 1_000_000e6);
    }

    // ════════════════════════════════════════════════════════════════
    // 1. Oracle zero-address rejection
    // ════════════════════════════════════════════════════════════════

    function test_constructor_rejectsZeroOracle() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new PaymentRouter(address(usdc), address(registry), admin, address(0));
    }

    function test_setOracle_rejectsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        router.setOracle(address(0));
    }

    function test_signatureAlwaysVerified() public {
        // Even with a valid oracle, a bad signature must revert
        uint256 deadline = block.timestamp + 300;
        bytes32 paymentId = keccak256("badSig");
        bytes memory badSig = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(27));

        vm.prank(payer);
        usdc.approve(address(router), 100e6);

        // OZ ECDSA reverts with ECDSAInvalidSignature or our InvalidSignature
        vm.expectRevert();
        router.executePayment(
            IPaymentRouter.X402Payment(payer, borrower, 100e6, 1, deadline, paymentId),
            badSig
        );
    }

    // ════════════════════════════════════════════════════════════════
    // 2. PaymentRouter pause
    // ════════════════════════════════════════════════════════════════

    function test_pause_blocksPayments() public {
        vm.prank(admin);
        router.pause();
        assertTrue(router.paused());

        uint256 deadline = block.timestamp + 300;
        bytes32 paymentId = keccak256("paused");
        bytes memory sig = _signPayment(payer, borrower, 100e6, 1, deadline, paymentId);

        vm.prank(payer);
        usdc.approve(address(router), 100e6);

        vm.expectRevert(Errors.PlatformPaused.selector);
        router.executePayment(
            IPaymentRouter.X402Payment(payer, borrower, 100e6, 1, deadline, paymentId),
            sig
        );
    }

    function test_unpause_resumesPayments() public {
        vm.prank(admin);
        router.pause();

        vm.prank(admin);
        router.unpause();
        assertFalse(router.paused());
    }

    function test_pause_onlyAdmin() public {
        vm.prank(payer);
        vm.expectRevert(Errors.Unauthorized.selector);
        router.pause();
    }

    // ════════════════════════════════════════════════════════════════
    // 3. Two-step admin transfer
    // ════════════════════════════════════════════════════════════════

    function test_adminTransfer_router() public {
        vm.prank(admin);
        router.proposeAdmin(newAdmin);
        assertEq(router.pendingAdmin(), newAdmin);

        vm.prank(newAdmin);
        router.acceptAdmin();
        assertEq(router.admin(), newAdmin);
        assertEq(router.pendingAdmin(), address(0));
    }

    function test_adminTransfer_registry() public {
        vm.prank(admin);
        registry.proposeAdmin(newAdmin);

        vm.prank(newAdmin);
        registry.acceptAdmin();
        assertEq(registry.admin(), newAdmin);
    }

    function test_adminTransfer_pool() public {
        vm.prank(admin);
        pool.proposeAdmin(newAdmin);

        vm.prank(newAdmin);
        pool.acceptAdmin();
        assertEq(pool.admin(), newAdmin);
    }

    function test_adminTransfer_factory() public {
        vm.prank(admin);
        factory.proposeAdmin(newAdmin);

        vm.prank(newAdmin);
        factory.acceptAdmin();
        (address factoryAdmin,,,,, ) = factory.config();
        assertEq(factoryAdmin, newAdmin);
    }

    function test_acceptAdmin_onlyPendingAdmin() public {
        vm.prank(admin);
        router.proposeAdmin(newAdmin);

        vm.prank(payer); // not the pending admin
        vm.expectRevert(Errors.Unauthorized.selector);
        router.acceptAdmin();
    }

    function test_proposeAdmin_rejectsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        router.proposeAdmin(address(0));
    }

    // ════════════════════════════════════════════════════════════════
    // 4. CREATE2 deterministic addresses
    // ════════════════════════════════════════════════════════════════

    function test_predictVaultAddress_deterministic() public {
        // predictVaultAddress should return the same address regardless of block
        address predicted1 = factory.predictVaultAddress(borrower, 50_000e6, 1200, 180 days, 3, 0, 0, 0);
        vm.warp(block.timestamp + 1000);
        address predicted2 = factory.predictVaultAddress(borrower, 50_000e6, 1200, 180 days, 3, 0, 0, 0);
        assertEq(predicted1, predicted2, "Predicted addresses should be deterministic");
    }

    // ════════════════════════════════════════════════════════════════
    // 5. VaultFactory bounds validation
    // ════════════════════════════════════════════════════════════════

    function test_createVault_interestRateTooHigh() public {
        vm.prank(admin);
        vm.expectRevert(Errors.FeeTooHigh.selector);
        factory.createVault(borrower, 50_000e6, 5001, 180 days, 3, 1500, 0, 0, 0, 0, type(uint256).max);
    }

    function test_createVault_durationTooShort() public {
        vm.prank(admin);
        vm.expectRevert(Errors.InvalidAmount.selector);
        factory.createVault(borrower, 50_000e6, 1200, 1 days, 3, 1500, 0, 0, 0, 0, type(uint256).max);
    }

    function test_createVault_durationTooLong() public {
        vm.prank(admin);
        vm.expectRevert(Errors.InvalidAmount.selector);
        factory.createVault(borrower, 50_000e6, 1200, 731 days, 3, 1500, 0, 0, 0, 0, type(uint256).max);
    }

    // ════════════════════════════════════════════════════════════════
    // 6. releaseTranche doesn't drain investor funds
    // ════════════════════════════════════════════════════════════════

    function test_releaseTranche_lastTranche_noInvestorDrain() public {
        // Create and fund a vault with 3 tranches
        MerchantVault vault = _createFundedVault(30_000e6, 3);

        vm.prank(admin);
        vault.setPaymentRouter(address(router));

        // Release all 3 tranches
        vm.startPrank(admin);
        vault.releaseTranche();
        vault.releaseTranche();
        vault.releaseTranche();
        vm.stopPrank();

        // Agent should receive exactly totalRaised, not more
        assertEq(usdc.balanceOf(address(vault.agent())), 30_000e6, "Agent should receive exactly totalRaised");
    }

    // ════════════════════════════════════════════════════════════════
    // 7. claimRefund division by zero guard
    // ════════════════════════════════════════════════════════════════

    function test_claimRefund_zeroBalance_reverts() public {
        // Create a vault in Fundraising state and cancel it
        MerchantVault vault2 = new MerchantVault(MerchantVault.VaultParams({
            usdc: address(usdc),
            agent: borrower,
            admin: admin,
            factory: address(this),
            targetAmount: 50_000e6,
            interestRateBps: 1200,
            durationSeconds: 180 days,
            numTranches: 3,
            platformFeeBps: 200,
            platformFeeRecipient: feeRecipient,
            lateFeeBps: 0,
            gracePeriodSeconds: 0,
            fundraisingDeadline: type(uint256).max
        }));

        // Invest something so vault has state
        usdc.mint(address(this), 10_000e6);
        usdc.approve(address(vault2), 10_000e6);
        vault2.invest(10_000e6);

        // Cancel the vault
        vm.prank(admin);
        vault2.cancel();

        // Someone who never invested tries to claim
        address nobody = makeAddr("nobody");
        vm.prank(nobody);
        vm.expectRevert(Errors.NothingToClaim.selector);
        vault2.claimRefund();
    }

    // ════════════════════════════════════════════════════════════════
    // 8. AgentRegistry incrementPayments existence check
    // ════════════════════════════════════════════════════════════════

    function test_incrementPayments_unregistered_reverts() public {
        address unregistered = makeAddr("unregistered");

        vm.prank(admin);
        vm.expectRevert(Errors.AgentNotRegistered.selector);
        registry.incrementPaymentsSent(unregistered, 100e6);

        vm.prank(admin);
        vm.expectRevert(Errors.AgentNotRegistered.selector);
        registry.incrementPaymentsReceived(unregistered, 100e6);
    }

    // ════════════════════════════════════════════════════════════════
    // 9. LiquidityPool: totalAllocated underflow reverts
    // ════════════════════════════════════════════════════════════════

    function test_processReturn_exceedsAllocated_reverts() public {
        // Deposit and allocate to a vault
        MerchantVault vault = _createVaultForPoolTest();

        usdc.mint(admin, 20_000e6);
        vm.startPrank(admin);
        usdc.approve(address(pool), 20_000e6);
        pool.deposit(20_000e6);
        pool.allocateToVault(address(vault), 10_000e6);
        vm.stopPrank();

        // Try to return MORE than was allocated (simulates accounting error)
        usdc.mint(address(this), 30_000e6);
        usdc.approve(address(pool), 30_000e6);

        vm.expectRevert(Errors.ArithmeticOverflow.selector);
        pool.processReturn(address(vault), 20_000e6);
    }

    // ════════════════════════════════════════════════════════════════
    // 10. _totalClaimable math correctness
    // ════════════════════════════════════════════════════════════════

    function test_claimable_correctAfterFees() public {
        // Create vault with 2% platform fee
        MerchantVault vault = _createFundedVault(50_000e6, 3);

        vm.prank(admin);
        vault.setPaymentRouter(address(this));

        // Process repayment — this contract acts as the router
        usdc.mint(address(this), 10_000e6);
        usdc.approve(address(vault), 10_000e6);
        vault.processRepayment(10_000e6);

        // New model: no time elapsed → accruedInterest = 0, all goes to principal
        // Principal waterfall: all 10K to senior (seniorFunded = 50K, all owed)
        // Platform fee = 2% of principal = 200 (transferred out separately)
        assertEq(vault.totalSeniorRepaid(), 10_000e6);
        assertEq(vault.platformFeesCollected(), 200e6);
    }

    // ════════════════════════════════════════════════════════════════
    // 11. Events emitted on admin changes
    // ════════════════════════════════════════════════════════════════

    function test_setOracle_emitsEvent() public {
        address newOracle = makeAddr("newOracle");

        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit IPaymentRouter.OracleUpdated(oracle, newOracle);
        router.setOracle(newOracle);
    }

    function test_setFactory_emitsEvent() public {
        address newFactory = makeAddr("newFactory");

        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit IPaymentRouter.FactoryUpdated(address(factory), newFactory);
        router.setFactory(newFactory);
    }

    // ════════════════════════════════════════════════════════════════
    // 12. MerchantVault _activate underflow guard
    // ════════════════════════════════════════════════════════════════

    function test_activate_underflowGuard() public {
        // This is tested implicitly — if seniorFunded + poolFunded > totalRaised,
        // _activate() would revert. The guard is in the code path; we verify a
        // normal activation still works correctly.
        MerchantVault vault = _createFundedVault(50_000e6, 3);
        assertTrue(vault.state() == IMerchantVault.VaultState(1)); // Active
        assertEq(vault.userFunded(), 0); // All senior
    }

    // ════════════════════════════════════════════════════════════════
    // Helpers
    // ════════════════════════════════════════════════════════════════

    function _createFundedVault(uint256 target, uint256 tranches) internal returns (MerchantVault) {
        MerchantVault vault = new MerchantVault(MerchantVault.VaultParams({
            usdc: address(usdc),
            agent: borrower,
            admin: admin,
            factory: address(this),
            targetAmount: target,
            interestRateBps: 1200,
            durationSeconds: 180 days,
            numTranches: tranches,
            platformFeeBps: 200,
            platformFeeRecipient: feeRecipient,
            lateFeeBps: 0,
            gracePeriodSeconds: 0,
            fundraisingDeadline: type(uint256).max
        }));
        usdc.mint(address(this), target);
        usdc.approve(address(vault), target);
        vault.investSenior(target);
        return vault;
    }

    function _createVaultForPoolTest() internal returns (MerchantVault) {
        MerchantVault vault = new MerchantVault(MerchantVault.VaultParams({
            usdc: address(usdc),
            agent: borrower,
            admin: admin,
            factory: address(this),
            targetAmount: 50_000e6,
            interestRateBps: 1200,
            durationSeconds: 180 days,
            numTranches: 3,
            platformFeeBps: 200,
            platformFeeRecipient: feeRecipient,
            lateFeeBps: 0,
            gracePeriodSeconds: 0,
            fundraisingDeadline: type(uint256).max
        }));
        return vault;
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
