// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {MerchantVault} from "../src/MerchantVault.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";
import {IMerchantVault} from "../src/interfaces/IMerchantVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title E2E — Full agent-to-agent TranslateBot demo flow
/// @notice THE accelerator demo test. Shows: register → fund → release → pay → waterfall → claim
contract E2ETest is Test {
    MockUSDC public usdc;
    AgentRegistry public registry;
    PaymentRouter public router;
    VaultFactory public factory;
    LiquidityPool public seniorPool;

    uint256 oraclePrivKey = 0xA11CE;
    address oracle;
    address admin = makeAddr("admin");
    address feeRecipient = makeAddr("feeRecipient");

    // AI Agents
    address translateBot = makeAddr("translateBot");
    address shopBot = makeAddr("shopBot");
    address travelBot = makeAddr("travelBot");
    address yieldBot = makeAddr("yieldBot");

    function setUp() public {
        oracle = vm.addr(oraclePrivKey);
        usdc = new MockUSDC();

        // 1. Deploy core infra
        registry = new AgentRegistry(admin, oracle);
        router = new PaymentRouter(address(usdc), address(registry), admin, oracle);
        seniorPool = new LiquidityPool(address(usdc), admin, true, 100_000e6);

        // 2. Wire up permissions
        vm.startPrank(admin);
        registry.setPaymentRouter(address(router));
        vm.stopPrank();

        // 3. Deploy factory (needs registry + router deployed first)
        factory = new VaultFactory(
            admin, oracle, address(usdc), 200, feeRecipient,
            address(registry), address(router)
        );

        vm.startPrank(admin);
        registry.setFactory(address(factory));
        router.setFactory(address(factory));
        vm.stopPrank();

        // 4. Fund agents
        usdc.mint(shopBot, 500_000e6);
        usdc.mint(travelBot, 500_000e6);
        usdc.mint(yieldBot, 20_000e6);
        usdc.mint(address(seniorPool), 0); // pool gets funded by depositors

        // 5. Senior pool capital
        usdc.mint(admin, 100_000e6);
        vm.startPrank(admin);
        usdc.approve(address(seniorPool), 100_000e6);
        seniorPool.deposit(100_000e6);
        vm.stopPrank();
    }

    function test_fullAgentFlow() public {
        // ═══════════════════════════════════════════════════════════
        // Step 1: All agents self-register
        // ═══════════════════════════════════════════════════════════
        vm.prank(translateBot);
        registry.registerAgent("ipfs://QmTranslateBot");
        vm.prank(shopBot);
        registry.registerAgent("ipfs://QmShopBot");
        vm.prank(travelBot);
        registry.registerAgent("ipfs://QmTravelBot");
        vm.prank(yieldBot);
        registry.registerAgent("ipfs://QmYieldBot");

        // Credit score + KYA for vault creation (oracle-only)
        vm.startPrank(oracle);
        registry.updateKya(translateBot, 2);
        registry.updateCreditScore(translateBot, 750);
        vm.stopPrank();

        assertEq(registry.getAgentCount(), 4);

        // ═══════════════════════════════════════════════════════════
        // Step 2: Admin creates vault for TranslateBot ($50K credit line)
        // 15% repayment rate on each payment
        // ═══════════════════════════════════════════════════════════
        vm.prank(admin);
        address vaultAddr = factory.createVault(
            translateBot,
            50_000e6,    // target: $50K
            1200,        // 12% interest
            365 days,    // 1 year
            4,           // 4 tranches
            1500,        // 15% repayment on each payment
            0,           // no rate limit
            0,           // no max payment
            0,           // no late fees
            0,           // no grace period
            type(uint256).max // no fundraising deadline
        );

        MerchantVault vault = MerchantVault(vaultAddr);
        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Fundraising));
        assertTrue(registry.hasActiveCreditLine(translateBot));

        // ═══════════════════════════════════════════════════════════
        // Step 3: Fund the vault
        // Senior pool: $40K, Community (YieldBot): $10K
        // ═══════════════════════════════════════════════════════════

        // Senior pool allocates
        vm.prank(admin);
        seniorPool.allocateToVault(vaultAddr, 40_000e6);

        // YieldBot invests community tranche
        vm.startPrank(yieldBot);
        usdc.approve(vaultAddr, 10_000e6);
        vault.invest(10_000e6);
        vm.stopPrank();

        // Vault should be active now (fully funded)
        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Active));
        assertEq(vault.totalRaised(), 50_000e6);
        assertEq(vault.seniorFunded(), 40_000e6);
        assertTrue(vault.totalToRepay() > 50_000e6); // principal + interest

        // ═══════════════════════════════════════════════════════════
        // Step 4: Admin releases first tranche to TranslateBot
        // ═══════════════════════════════════════════════════════════
        vm.prank(admin);
        vault.setPaymentRouter(address(router));

        vm.prank(admin);
        vault.releaseTranche();
        assertEq(usdc.balanceOf(translateBot), 12_500e6); // 50K / 4

        // ═══════════════════════════════════════════════════════════
        // Step 5: ShopBot pays TranslateBot for API calls (x402 flow)
        // $1000 per call, 15% auto-routed to vault
        // ═══════════════════════════════════════════════════════════
        uint256 paymentAmount = 1000e6;
        uint256 translateBalBefore = usdc.balanceOf(translateBot);

        for (uint256 i = 1; i <= 5; i++) {
            bytes32 paymentId = keccak256(abi.encodePacked("shop-payment-", i));
            bytes memory sig = _signPayment(shopBot, translateBot, paymentAmount, i, block.timestamp + 300, paymentId);

            vm.prank(shopBot);
            usdc.approve(address(router), paymentAmount);

            router.executePayment(
                IPaymentRouter.X402Payment(shopBot, translateBot, paymentAmount, i, block.timestamp + 300, paymentId),
                sig
            );
        }

        // ShopBot paid 5 x $1000 = $5000
        // 15% = $750 to vault, $4250 to TranslateBot
        uint256 translateBalAfter = usdc.balanceOf(translateBot);
        assertEq(translateBalAfter - translateBalBefore, 4250e6);

        // ═══════════════════════════════════════════════════════════
        // Step 6: TravelBot also pays TranslateBot
        // ═══════════════════════════════════════════════════════════
        for (uint256 i = 100; i <= 103; i++) {
            bytes32 paymentId = keccak256(abi.encodePacked("travel-payment-", i));
            bytes memory sig = _signPayment(travelBot, translateBot, 2000e6, i, block.timestamp + 300, paymentId);

            vm.prank(travelBot);
            usdc.approve(address(router), 2000e6);

            router.executePayment(
                IPaymentRouter.X402Payment(travelBot, translateBot, 2000e6, i, block.timestamp + 300, paymentId),
                sig
            );
        }

        // ═══════════════════════════════════════════════════════════
        // Step 7: Verify waterfall accounting
        // ═══════════════════════════════════════════════════════════
        // Total payments: 5*1000 + 4*2000 = $13,000
        // Repayment: 15% of $13,000 = $1,950 to vault
        // Platform fee: 2% of $1,950 = $39
        // Net repayment: $1,911
        // Waterfall: all goes to senior first ($40K owed)
        assertTrue(vault.totalRepaid() > 0);
        assertTrue(vault.totalSeniorRepaid() > 0);

        (uint256 seniorF, uint256 poolF, uint256 userF, uint256 seniorR, uint256 poolR, uint256 commR) =
            vault.getWaterfallState();

        assertEq(seniorF, 40_000e6);
        assertEq(poolF, 0); // pool invested via investFromPool not used here
        assertTrue(seniorR > 0);
        // Pool and community shouldn't have received anything yet (senior not fully repaid)
        assertEq(poolR, 0);
        assertEq(commR, 0);

        // ═══════════════════════════════════════════════════════════
        // Step 8: Verify settlement stats
        // ═══════════════════════════════════════════════════════════
        IPaymentRouter.Settlement memory settlement = router.getSettlement(translateBot);
        assertEq(settlement.totalPayments, 9); // 5 + 4
        assertTrue(settlement.totalRouted > 0);

        // ═══════════════════════════════════════════════════════════
        // Step 9: Platform fees collected
        // ═══════════════════════════════════════════════════════════
        assertTrue(usdc.balanceOf(feeRecipient) > 0);
        assertTrue(vault.platformFeesCollected() > 0);

        // ═══════════════════════════════════════════════════════════
        // Verify agent stats in registry
        // ═══════════════════════════════════════════════════════════
        assertTrue(registry.getAgent(shopBot).totalVolumeUsd > 0);
        assertTrue(registry.getAgent(translateBot).totalVolumeUsd > 0);

        emit log_named_uint("Total vault repaid", vault.totalRepaid());
        emit log_named_uint("Senior repaid", vault.totalSeniorRepaid());
        emit log_named_uint("Platform fees", vault.platformFeesCollected());
        emit log_named_uint("TranslateBot balance", usdc.balanceOf(translateBot));
        emit log_named_uint("Settlement total routed", settlement.totalRouted);
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
