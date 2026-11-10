// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {MerchantVault} from "../src/MerchantVault.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";
import {IMerchantVault} from "../src/interfaces/IMerchantVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {Errors} from "../src/libraries/Errors.sol";

/// @notice Multi-investor E2E: verifies proportional claimReturns across investor types
/// Flow: 3 community investors + senior pool fund a vault → payments flow in → each investor claims proportionally
contract MultiInvestorE2ETest is Test {
    MockUSDC public usdc;
    AgentRegistry public registry;
    PaymentRouter public router;
    VaultFactory public factory;
    LiquidityPool public seniorPool;

    uint256 oraclePrivKey = 0xBEEF;
    address oracle = vm.addr(0xBEEF);
    address admin = makeAddr("admin");
    address feeRecipient = makeAddr("feeRecipient");

    // The borrowing agent
    address translateBot = makeAddr("translateBot");

    // Multiple community investors
    address investorA = makeAddr("investorA"); // 3K — 30% of community
    address investorB = makeAddr("investorB"); // 3K — 30% of community
    address investorC = makeAddr("investorC"); // 4K — 40% of community

    // The paying agent
    address shopBot = makeAddr("shopBot");

    MerchantVault vault;

    function setUp() public {
        usdc = new MockUSDC();

        // Deploy infrastructure
        registry = new AgentRegistry(admin, oracle);
        router = new PaymentRouter(address(usdc), address(registry), admin, oracle);
        seniorPool = new LiquidityPool(address(usdc), admin, true, 500_000e6);

        vm.startPrank(admin);
        registry.setPaymentRouter(address(router));
        factory = new VaultFactory(
            admin, oracle, address(usdc), 200, feeRecipient,
            address(registry), address(router)
        );
        registry.setFactory(address(factory));
        router.setFactory(address(factory));
        vm.stopPrank();

        // Fund senior pool
        usdc.mint(admin, 200_000e6);
        vm.startPrank(admin);
        usdc.approve(address(seniorPool), 200_000e6);
        seniorPool.deposit(200_000e6);
        vm.stopPrank();

        // Register agents
        vm.prank(translateBot); registry.registerAgent("ipfs://translateBot");
        vm.prank(shopBot);      registry.registerAgent("ipfs://shopBot");

        // Credit score + KYA for vault creation (oracle-only)
        vm.startPrank(oracle);
        registry.updateKya(translateBot, 2);
        registry.updateCreditScore(translateBot, 750);
        vm.stopPrank();

        // Mint community investor balances
        usdc.mint(investorA, 10_000e6);
        usdc.mint(investorB, 10_000e6);
        usdc.mint(investorC, 10_000e6);
        usdc.mint(shopBot, 1_000_000e6);

        // Admin creates vault: 20K target (10K senior + 10K community), 15% repayment
        vm.prank(admin);
        address vaultAddr = factory.createVault(translateBot, 20_000e6, 1200, 365 days, 2, 1500, 0, 0, 0, 0, type(uint256).max);
        vault = MerchantVault(vaultAddr);

        // Wire vault's payment router (factory doesn't set it automatically)
        vm.prank(admin);
        vault.setPaymentRouter(address(router));
    }

    // ════════════════════════════════════════════════════════════════
    // Full multi-investor flow
    // ════════════════════════════════════════════════════════════════

    function test_multiInvestor_proportionalClaims() public {
        // ── Fund vault: 10K senior (pool) + 10K community (A+B+C) ──
        vm.prank(admin);
        seniorPool.allocateToVault(address(vault), 10_000e6);

        vm.startPrank(investorA);
        usdc.approve(address(vault), 3_000e6);
        vault.invest(3_000e6);
        vm.stopPrank();

        vm.startPrank(investorB);
        usdc.approve(address(vault), 3_000e6);
        vault.invest(3_000e6);
        vm.stopPrank();

        vm.startPrank(investorC);
        usdc.approve(address(vault), 4_000e6);
        vault.invest(4_000e6);
        vm.stopPrank();

        // Vault should be active (10K + 10K = 20K)
        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Active));
        assertEq(vault.seniorFunded(), 10_000e6);
        assertEq(vault.userFunded(), 10_000e6);

        // Verify individual investor balances
        assertEq(vault.getInvestorBalance(investorA), 3_000e6);
        assertEq(vault.getInvestorBalance(investorB), 3_000e6);
        assertEq(vault.getInvestorBalance(investorC), 4_000e6);

        // ── ShopBot makes 15 payments of $1000 each (x402 flow) ──
        // Total: 15K; 15% repayment = 2.25K to vault; 85% = 12.75K to translateBot
        for (uint256 i = 1; i <= 15; i++) {
            bytes32 paymentId = keccak256(abi.encodePacked("p", i));
            bytes memory sig = _sign(shopBot, translateBot, 1000e6, i, block.timestamp + 300, paymentId);
            vm.prank(shopBot);
            usdc.approve(address(router), 1000e6);
            router.executePayment(
                IPaymentRouter.X402Payment(shopBot, translateBot, 1000e6, i, block.timestamp + 300, paymentId),
                sig
            );
        }

        // ── Verify waterfall: senior repaid first, community not yet ──
        // 15K * 15% = 2250 total routed. New model: no time elapsed →
        // accruedInterest = 0, all goes to principal. Waterfall gets full 2250.
        // senior owed 10K → all 2250 goes to senior
        assertEq(vault.totalSeniorRepaid(), 2_250e6);
        assertEq(vault.totalCommunityRepaid(), 0); // senior not cleared yet

        // Community investors have nothing claimable yet
        assertEq(vault.getClaimable(investorA), 0);
        assertEq(vault.getClaimable(investorB), 0);
        assertEq(vault.getClaimable(investorC), 0);

        // ── Now clear the senior tranche with more payments ──
        // Need ~10K net to senior → ~10204 gross → 10204 / 0.98 ≈ lots of payments
        // Pay 80 more payments of 1000 USDC
        for (uint256 i = 16; i <= 95; i++) {
            bytes32 paymentId = keccak256(abi.encodePacked("p2", i));
            bytes memory sig = _sign(shopBot, translateBot, 1000e6, i, block.timestamp + 300, paymentId);
            vm.prank(shopBot);
            usdc.approve(address(router), 1000e6);
            router.executePayment(
                IPaymentRouter.X402Payment(shopBot, translateBot, 1000e6, i, block.timestamp + 300, paymentId),
                sig
            );
        }

        // After 95 payments of 1K: 95K total, 15% = 14.25K routed, net = 13.965K
        // Senior gets first 10K → fully cleared at some point
        // Community gets excess (13.965K - 10K = 3.965K)
        assertTrue(vault.totalSeniorRepaid() >= 10_000e6, "Senior should be fully repaid");
        assertTrue(vault.totalCommunityRepaid() > 0, "Community should have received some repayment");

        // ── Verify proportional community claims ──
        uint256 communityRepaid = vault.totalCommunityRepaid();
        uint256 claimableA = vault.getClaimable(investorA);
        uint256 claimableB = vault.getClaimable(investorB);
        uint256 claimableC = vault.getClaimable(investorC);

        // A: 3K/10K = 30% of community repaid
        assertEq(claimableA, (3_000e6 * communityRepaid) / 10_000e6);
        // B: 3K/10K = 30%
        assertEq(claimableB, (3_000e6 * communityRepaid) / 10_000e6);
        // C: 4K/10K = 40%
        assertEq(claimableC, (4_000e6 * communityRepaid) / 10_000e6);

        // A + B + C claims should sum to totalCommunityRepaid (rounding may lose 1-2 wei)
        assertApproxEqAbs(claimableA + claimableB + claimableC, communityRepaid, 3);

        // ── All 3 investors claim ──
        uint256 beforeA = usdc.balanceOf(investorA);
        vm.prank(investorA); vault.claimReturns();
        assertEq(usdc.balanceOf(investorA) - beforeA, claimableA);

        uint256 beforeB = usdc.balanceOf(investorB);
        vm.prank(investorB); vault.claimReturns();
        assertEq(usdc.balanceOf(investorB) - beforeB, claimableB);

        uint256 beforeC = usdc.balanceOf(investorC);
        vm.prank(investorC); vault.claimReturns();
        assertEq(usdc.balanceOf(investorC) - beforeC, claimableC);

        // After claiming, claimable should be zero
        assertEq(vault.getClaimable(investorA), 0);
        assertEq(vault.getClaimable(investorB), 0);
        assertEq(vault.getClaimable(investorC), 0);
    }

    function test_multiInvestor_seniorClaimsProportionally() public {
        // Two senior investors directly (no pool), same vault
        // Override: create a fresh vault without pool, senior only
        MerchantVault directVault = new MerchantVault(MerchantVault.VaultParams({
            usdc: address(usdc),
            agent: translateBot,
            admin: admin,
            factory: address(this),
            targetAmount: 10_000e6,
            interestRateBps: 1200,
            durationSeconds: 365 days,
            numTranches: 2,
            platformFeeBps: 200,
            platformFeeRecipient: feeRecipient,
            lateFeeBps: 0,
            gracePeriodSeconds: 0,
            fundraisingDeadline: type(uint256).max
        }));
        vm.prank(admin);
        directVault.setPaymentRouter(address(this));

        address seniorA = makeAddr("seniorA");
        address seniorB = makeAddr("seniorB");
        usdc.mint(seniorA, 10_000e6);
        usdc.mint(seniorB, 10_000e6);

        vm.startPrank(seniorA);
        usdc.approve(address(directVault), 6_000e6);
        directVault.investSenior(6_000e6);
        vm.stopPrank();

        vm.startPrank(seniorB);
        usdc.approve(address(directVault), 4_000e6);
        directVault.investSenior(4_000e6);
        vm.stopPrank();

        assertEq(uint8(directVault.state()), uint8(IMerchantVault.VaultState.Active));

        // Repay 5K gross. New model: no time elapsed → all goes to principal.
        // Waterfall gets full 5K. Senior owed 10K → all 5K to senior.
        usdc.mint(address(this), 5_000e6);
        usdc.approve(address(directVault), 5_000e6);
        directVault.processRepayment(5_000e6);

        // SeniorA: 6K/10K = 60% of 5000 = 3000
        // SeniorB: 4K/10K = 40% of 5000 = 2000
        assertEq(directVault.getClaimable(seniorA), 3_000e6);
        assertEq(directVault.getClaimable(seniorB), 2_000e6);

        vm.prank(seniorA); directVault.claimReturns();
        vm.prank(seniorB); directVault.claimReturns();

        assertEq(directVault.getClaimable(seniorA), 0);
        assertEq(directVault.getClaimable(seniorB), 0);
    }

    // ─── Helper ──────────────────────────────────────────────────

    function _sign(
        address from, address to, uint256 amount, uint256 nonce, uint256 deadline, bytes32 paymentId
    ) internal view returns (bytes memory) {
        bytes32 msgHash = keccak256(abi.encode(from, to, amount, nonce, deadline, paymentId));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oraclePrivKey, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }
}
