// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EvmHomeBase} from "./EvmHomeBase.sol";
import {KrexaSwapPolicy} from "../../src/evm-home/KrexaSwapPolicy.sol";
import {KrexaRiskHook} from "../../src/evm-home/KrexaRiskHook.sol";
import {ExecDecoder} from "../../src/evm-home/lib/ExecDecoder.sol";
import {SwapDecoder} from "../../src/evm-home/lib/SwapDecoder.sol";
import {PackedUserOperation} from "../../src/evm-home/interfaces/PackedUserOperation.sol";
import {MockKernel, MockSwapRouter} from "./mocks/Mocks.sol";

/// @notice Policy + hook wired to a Kernel stand-in (`MockKernel`) the way Kernel v3.3 wires them:
/// session ops: policy.checkUserOpPolicy -> hook.preCheck -> execute -> hook.postCheck; owner ops: neither.
contract IntegrationTest is EvmHomeBase {
    MockKernel internal kernel;
    MockSwapRouter internal router;
    address internal owner = makeAddr("owner");

    function setUp() public override {
        super.setUp();
        router = new MockSwapRouter();
        kernel = new MockKernel(owner);
        kernel.wire(policy, PID, hook);
        // the account is the hook's and policy's `msg.sender`; the hook needs the token and feed for the account
        KrexaSwapPolicy.PolicyConfig memory c = defaultConfig();
        c.targets[0] = _target(address(router), SwapDecoder.SR02_EXACT_INPUT_SINGLE, SwapDecoder.SR02_EXACT_INPUT);
        c.spenders[0] = address(router);
        vm.startPrank(owner);
        kernel.callModule(address(policy), abi.encodeCall(policy.onInstall, (abi.encodePacked(PID, abi.encode(c)))));
        kernel.callModule(address(hook), abi.encodeCall(hook.onInstall, (abi.encode(hookConfig()))));
        vm.stopPrank();

        usdc.mint(address(kernel), 1000 * U);
        router.setRate(4e8, 1); // 1 USDC (1e6) -> 4e14 wei WETH = $2500/WETH
    }

    function _session(bytes memory executeCalldata) internal {
        PackedUserOperation memory op = _userOp(address(kernel), _wrapHooked(executeCalldata));
        kernel.sessionOp(op);
    }

    function _buyBatch(uint256 amount) internal view returns (bytes memory) {
        address[] memory t = new address[](2);
        bytes[] memory d = new bytes[](2);
        t[0] = address(usdc);
        d[0] = _approve(address(router), amount);
        t[1] = address(router);
        d[1] = _sr02Single(address(usdc), address(weth), address(kernel), amount, 0);
        return _batch(t, d);
    }

    function _sellBatch(uint256 amount) internal view returns (bytes memory) {
        address[] memory t = new address[](2);
        bytes[] memory d = new bytes[](2);
        t[0] = address(weth);
        d[0] = _approve(address(router), amount);
        t[1] = address(router);
        d[1] = _sr02Single(address(weth), address(usdc), address(kernel), amount, 0);
        return _batch(t, d);
    }

    function test_e2e_buyThenSell() public {
        _session(_buyBatch(40 * U));
        assertEq(usdc.balanceOf(address(kernel)), 960 * U);
        assertEq(weth.balanceOf(address(kernel)), 40 * U * 4e8);
    }

    function test_e2e_blockedStateBuysRevertSellsPass() public {
        _session(_buyBatch(100 * U));
        _session(_buyBatch(100 * U));
        uint256 got = weth.balanceOf(address(kernel));
        assertEq(got, 200 * U * 4e8);
        // price crashes 80%: NAV 800 + 0.08 * 500 = 840, loss 160 > 50
        ethFeed.set(500e8);
        vm.expectRevert(KrexaRiskHook.BuysBlocked.selector);
        this.runSession(_buyBatch(10 * U));

        router.setRate(500e6, 1e18);
        uint256 usdcBefore = usdc.balanceOf(address(kernel));
        _session(_sellBatch(got / 2));
        assertGt(usdc.balanceOf(address(kernel)), usdcBefore);
    }

    // external wrapper so vm.expectRevert sees the revert from a nested call frame
    function runSession(bytes memory cd) external {
        _session(cd);
    }

    function test_e2e_sessionCannotInstallModule() public {
        bytes memory install = abi.encodeWithSignature("installModule(uint256,address,bytes)", 1, attacker, "");
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.TargetForbidden.selector, address(kernel)));
        this.runSession(_single(address(kernel), 0, install));
        assertFalse(kernel.moduleInstalled());
        // while the same call from the owner path works
        vm.prank(owner);
        kernel.ownerOp(_single(address(kernel), 0, install));
        assertTrue(kernel.moduleInstalled());
    }

    function test_e2e_sessionCannotChangeConfigOrUnpause() public {
        vm.prank(owner);
        kernel.ownerOp(_single(address(hook), 0, abi.encodeWithSignature("pause()")));
        assertTrue(hook.getState(address(kernel)).paused);

        // a session op that tries to unpause is rejected by the policy (and would be by the paused hook)
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.TargetForbidden.selector, address(hook)));
        this.runSession(_single(address(hook), 0, abi.encodeWithSignature("unpause()")));
        assertTrue(hook.getState(address(kernel)).paused);

        // nor can it raise its own limits
        bytes memory cd = abi.encodeCall(KrexaSwapPolicy.setConfig, (PID, defaultConfig()));
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.TargetForbidden.selector, address(policy)));
        this.runSession(_single(address(policy), 0, cd));
    }

    function test_e2e_pausedBlocksSessionOwnerUnpauses() public {
        vm.prank(owner);
        kernel.ownerOp(_single(address(hook), 0, abi.encodeWithSignature("pause()")));
        vm.expectRevert(KrexaRiskHook.HookPaused.selector);
        this.runSession(_buyBatch(10 * U));
        vm.expectRevert(KrexaRiskHook.HookPaused.selector);
        this.runSession(_sellBatch(1));

        vm.prank(owner);
        kernel.ownerOp(_single(address(hook), 0, abi.encodeWithSignature("unpause()")));
        _session(_buyBatch(10 * U));
    }

    function test_e2e_ownerPathIsNeverBlocked() public {
        // pause + crash: the owner can still move everything out (no policy, no hook on the root validator)
        vm.startPrank(owner);
        kernel.ownerOp(_single(address(hook), 0, abi.encodeWithSignature("pause()")));
        kernel.ownerOp(
            _single(address(usdc), 0, abi.encodeWithSignature("transfer(address,uint256)", owner, 900 * U))
        );
        vm.stopPrank();
        assertEq(usdc.balanceOf(owner), 900 * U);
    }

    function test_e2e_nonOwnerCannotUseOwnerPath() public {
        vm.prank(attacker);
        vm.expectRevert(MockKernel.InvalidCaller.selector);
        kernel.ownerOp(_single(address(hook), 0, abi.encodeWithSignature("unpause()")));
        // and the account's execute() is not reachable from outside
        vm.prank(attacker);
        vm.expectRevert(MockKernel.InvalidCaller.selector);
        kernel.execute(bytes32(0), "");
    }

    function test_e2e_policyDenialStopsExecution() public {
        // buy above the per-trade cap: nothing executes, balances untouched
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.PerTradeCapExceeded.selector, 150 * U, 100 * U));
        this.runSession(_buyBatch(150 * U));
        assertEq(usdc.balanceOf(address(kernel)), 1000 * U);
    }

    function test_e2e_dailyCapAndOpsAreEnforcedByTheHook() public {
        _session(_buyBatch(100 * U));
        _session(_buyBatch(100 * U));
        _session(_buyBatch(50 * U));
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.DailyCapExceeded.selector, 1 * U, 0));
        this.runSession(_buyBatch(1 * U));
        assertEq(hook.opsThisHour(address(kernel)), 3);
        vm.warp(T0 + 25 hours);
        ethFeed.set(2500e8);
        _session(_buyBatch(1 * U));
    }

    function test_e2e_expiryIsEnforcedFromValidationData() public {
        // the policy returns validUntil in the validationData; the EntryPoint (here MockKernel) enforces it
        PackedUserOperation memory op = _userOp(address(kernel), _wrapHooked(_single(address(usdc), 0, _approve(address(router), 1))));
        vm.prank(address(kernel));
        uint256 vd = policy.checkUserOpPolicy(PID, op);
        assertEq(uint48(vd >> 160), uint48(T0 + 7 days));
        assertEq(uint48(vd >> 208), 0); // validAfter
        assertEq(address(uint160(vd)), address(0)); // authorizer: valid

        vm.warp(T0 + 7 days);
        ethFeed.set(2500e8);
        kernel.sessionOp(op);
        vm.warp(T0 + 7 days + 1);
        ethFeed.set(2500e8);
        vm.expectRevert(MockKernel.Expired.selector);
        this.runSession(_single(address(usdc), 0, _approve(address(router), 1)));
    }
}
