// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {MerchantVault} from "../src/MerchantVault.sol";
import {IMerchantVault} from "../src/interfaces/IMerchantVault.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {Errors} from "../src/libraries/Errors.sol";

contract VaultFactoryTest is Test {
    MockUSDC public usdc;
    AgentRegistry public registry;
    PaymentRouter public router;
    VaultFactory public factory;

    address oracle = vm.addr(0xB0B);
    address admin = makeAddr("admin");
    address agent = makeAddr("translateBot");
    address agent2 = makeAddr("shopBot");
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

        vm.prank(agent);
        registry.registerAgent("ipfs://translateBot");

        vm.prank(agent2);
        registry.registerAgent("ipfs://shopBot");

        // Credit scores + KYA required for vault creation (oracle-only)
        vm.startPrank(oracle);
        registry.updateKya(agent, 2);
        registry.updateCreditScore(agent, 750);
        registry.updateKya(agent2, 2);
        registry.updateCreditScore(agent2, 750);
        vm.stopPrank();
    }

    // ════════════════════════════════════════════════════════════════
    // 1. createVault happy path
    // ════════════════════════════════════════════════════════════════

    function test_createVault_happy() public {
        vm.prank(admin);
        address vault = factory.createVault(agent, 50_000e6, 1200, 180 days, 4, 1500, 0, 0, 0, 0, type(uint256).max);

        assertTrue(vault != address(0));
        assertEq(factory.agentToVault(agent), vault);
        assertEq(factory.getVaultCount(), 1);
        assertEq(factory.getAllVaults()[0], vault);

        // Registry should link vault
        assertEq(registry.getVault(agent), vault);

        // Settlement should be created in router
        IPaymentRouter.Settlement memory s = router.getSettlement(agent);
        assertEq(s.vault, vault);
        assertEq(s.repaymentRateBps, 1500);
        assertTrue(s.active);
    }

    function test_createVault_deployedVault_isUsable() public {
        vm.prank(admin);
        address vaultAddr = factory.createVault(agent, 50_000e6, 1200, 180 days, 4, 1500, 0, 0, 0, 0, type(uint256).max);

        MerchantVault vault = MerchantVault(vaultAddr);
        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Fundraising));
        assertEq(vault.agent(), agent);
        assertEq(vault.targetAmount(), 50_000e6);

        // Can invest into it
        usdc.mint(address(this), 50_000e6);
        usdc.approve(vaultAddr, 50_000e6);
        vault.investSenior(50_000e6);
        assertEq(uint8(vault.state()), uint8(IMerchantVault.VaultState.Active));
    }

    function test_createVault_emitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit VaultFactory.VaultCreated(agent, address(0), 50_000e6, 1200, 180 days);
        factory.createVault(agent, 50_000e6, 1200, 180 days, 4, 1500, 0, 0, 0, 0, type(uint256).max);
    }

    // ════════════════════════════════════════════════════════════════
    // 2. Duplicate vault rejection
    // ════════════════════════════════════════════════════════════════

    function test_createVault_duplicate_reverts() public {
        vm.startPrank(admin);
        factory.createVault(agent, 50_000e6, 1200, 180 days, 4, 1500, 0, 0, 0, 0, type(uint256).max);
        vm.expectRevert(Errors.VaultAlreadyExists.selector);
        factory.createVault(agent, 50_000e6, 1200, 180 days, 4, 1500, 0, 0, 0, 0, type(uint256).max);
        vm.stopPrank();
    }

    function test_createVault_differentAgents_succeed() public {
        vm.startPrank(admin);
        address vault1 = factory.createVault(agent, 50_000e6, 1200, 180 days, 4, 1500, 0, 0, 0, 0, type(uint256).max);
        address vault2 = factory.createVault(agent2, 30_000e6, 1000, 90 days, 3, 1000, 0, 0, 0, 0, type(uint256).max);
        vm.stopPrank();

        assertTrue(vault1 != vault2);
        assertEq(factory.getVaultCount(), 2);
    }

    // ════════════════════════════════════════════════════════════════
    // 3. Unregistered agent rejection
    // ════════════════════════════════════════════════════════════════

    function test_createVault_unregisteredAgent_reverts() public {
        address stranger = makeAddr("stranger");
        vm.prank(admin);
        vm.expectRevert(Errors.AgentNotRegistered.selector);
        factory.createVault(stranger, 50_000e6, 1200, 180 days, 4, 1500, 0, 0, 0, 0, type(uint256).max);
    }

    // ════════════════════════════════════════════════════════════════
    // 4. Platform pause blocks vault creation
    // ════════════════════════════════════════════════════════════════

    function test_createVault_platformPaused_reverts() public {
        vm.prank(admin);
        factory.pausePlatform();

        vm.prank(admin);
        vm.expectRevert(Errors.PlatformPaused.selector);
        factory.createVault(agent, 50_000e6, 1200, 180 days, 4, 1500, 0, 0, 0, 0, type(uint256).max);
    }

    function test_unpausePlatform_resumesCreation() public {
        vm.startPrank(admin);
        factory.pausePlatform();
        factory.unpausePlatform();
        address vault = factory.createVault(agent, 50_000e6, 1200, 180 days, 4, 1500, 0, 0, 0, 0, type(uint256).max);
        vm.stopPrank();
        assertTrue(vault != address(0));
    }

    // ════════════════════════════════════════════════════════════════
    // 5. onlyAdmin guard
    // ════════════════════════════════════════════════════════════════

    function test_createVault_onlyAdmin_reverts() public {
        vm.prank(agent);
        vm.expectRevert(Errors.Unauthorized.selector);
        factory.createVault(agent, 50_000e6, 1200, 180 days, 4, 1500, 0, 0, 0, 0, type(uint256).max);
    }

    // ════════════════════════════════════════════════════════════════
    // 6. setPlatformFee
    // ════════════════════════════════════════════════════════════════

    function test_setPlatformFee() public {
        vm.prank(admin);
        factory.setPlatformFee(300);
        (,,, uint16 fee,,) = factory.config();
        assertEq(fee, 300);
    }

    function test_setPlatformFee_tooHigh_reverts() public {
        vm.prank(admin);
        vm.expectRevert(Errors.FeeTooHigh.selector);
        factory.setPlatformFee(1001);
    }

    function test_setPlatformFee_maxBoundary() public {
        vm.prank(admin);
        factory.setPlatformFee(1000); // exactly 10% — should pass
        (,,, uint16 fee,,) = factory.config();
        assertEq(fee, 1000);
    }

    function test_setPlatformFee_onlyAdmin_reverts() public {
        vm.prank(agent);
        vm.expectRevert(Errors.Unauthorized.selector);
        factory.setPlatformFee(300);
    }

    // ════════════════════════════════════════════════════════════════
    // 7. setFeeRecipient
    // ════════════════════════════════════════════════════════════════

    function test_setFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");
        vm.prank(admin);
        factory.setFeeRecipient(newRecipient);
        (,,,, address recipient,) = factory.config();
        assertEq(recipient, newRecipient);
    }

    function test_setFeeRecipient_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        factory.setFeeRecipient(address(0));
    }

    function test_setFeeRecipient_onlyAdmin_reverts() public {
        vm.prank(agent);
        vm.expectRevert(Errors.Unauthorized.selector);
        factory.setFeeRecipient(makeAddr("x"));
    }

    // ════════════════════════════════════════════════════════════════
    // 8. setOracle
    // ════════════════════════════════════════════════════════════════

    function test_setOracle() public {
        address newOracle = makeAddr("newOracle");
        vm.prank(admin);
        factory.setOracle(newOracle);
        assertEq(factory.getOracle(), newOracle);
    }

    function test_setOracle_onlyAdmin_reverts() public {
        vm.prank(agent);
        vm.expectRevert(Errors.Unauthorized.selector);
        factory.setOracle(makeAddr("x"));
    }

    // ════════════════════════════════════════════════════════════════
    // 9. getAllVaults / getVaultCount
    // ════════════════════════════════════════════════════════════════

    function test_getAllVaults_empty() public view {
        assertEq(factory.getVaultCount(), 0);
        assertEq(factory.getAllVaults().length, 0);
    }

    function test_getAllVaults_afterCreation() public {
        vm.startPrank(admin);
        factory.createVault(agent, 50_000e6, 1200, 180 days, 4, 1500, 0, 0, 0, 0, type(uint256).max);
        factory.createVault(agent2, 30_000e6, 1000, 90 days, 3, 1000, 0, 0, 0, 0, type(uint256).max);
        vm.stopPrank();

        assertEq(factory.getVaultCount(), 2);
        assertEq(factory.getAllVaults().length, 2);
    }

    // ════════════════════════════════════════════════════════════════
    // 10. Two-step admin transfer
    // ════════════════════════════════════════════════════════════════

    function test_adminTransfer_factory() public {
        vm.prank(admin);
        factory.proposeAdmin(newAdmin);
        assertEq(factory.pendingAdmin(), newAdmin);

        vm.prank(newAdmin);
        factory.acceptAdmin();
        (address factoryAdmin,,,,,) = factory.config();
        assertEq(factoryAdmin, newAdmin);
        assertEq(factory.pendingAdmin(), address(0));
    }

    function test_acceptAdmin_onlyPendingAdmin_reverts() public {
        vm.prank(admin);
        factory.proposeAdmin(newAdmin);

        vm.prank(agent); // not the pending admin
        vm.expectRevert(Errors.Unauthorized.selector);
        factory.acceptAdmin();
    }
}
