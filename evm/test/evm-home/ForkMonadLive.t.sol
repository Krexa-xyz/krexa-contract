// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KrexaSwapPolicy} from "../../src/evm-home/KrexaSwapPolicy.sol";
import {KrexaRiskHook} from "../../src/evm-home/KrexaRiskHook.sol";
import {SwapDecoder} from "../../src/evm-home/lib/SwapDecoder.sol";
import {ExecDecoder} from "../../src/evm-home/lib/ExecDecoder.sol";
import {PackedUserOperation} from "../../src/evm-home/interfaces/PackedUserOperation.sol";

/// @notice Exercises the contracts ALREADY DEPLOYED on Monad testnet (10143) at their live addresses —
/// not fresh instances. This is the check that the bytecode on chain behaves like the reviewed source.
/// Run: MONAD_TESTNET_RPC_URL=https://testnet-rpc.monad.xyz FOUNDRY_PROFILE=evmhome forge test --match-contract ForkMonadLive -vv
contract MockFeed {
    int256 public answer;
    uint256 public updatedAt;

    constructor(int256 a) {
        answer = a;
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }

    function decimals() external pure returns (uint256) {
        return 8;
    }
}

contract MockToken {
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }
}

contract ForkMonadLiveTest is Test {
    // The live deployment recorded in deployments/10143-evm-home.json
    KrexaSwapPolicy constant POLICY = KrexaSwapPolicy(0x446b4ea7cd7CF874895c03b91478514Cbfd7E931);
    KrexaRiskHook constant HOOK = KrexaRiskHook(0xAcF4425F4E349cD4cE646898d2a5a6250945f5d9);
    // Circle USDC on Monad testnet (6 decimals), per the API's chain config
    address constant USDC = 0x534b2f3A21130d7a60830c2Df862319e593943A3;

    bytes32 constant PID = bytes32(bytes4(0xdeadbeef));
    address wallet = makeAddr("liveWallet");
    address router = makeAddr("router"); // stand-in: the policy only reads calldata, it never calls the router
    address token;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("MONAD_TESTNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        // The contracts must actually be there, with the code we recorded.
        assertGt(address(POLICY).code.length, 0, "policy has no code on 10143");
        assertGt(address(HOOK).code.length, 0, "hook has no code on 10143");
        assertEq(
            keccak256(address(POLICY).code),
            0x1c716e0bf998f5942de1d5daeb87b576546ec8e365273691672a9ed211f7fe44,
            "policy codehash drifted"
        );
        assertEq(
            keccak256(address(HOOK).code),
            0x84b28cc9fa76e796f646e397954ce169a3174432b3d60c630509860b50aa95a9,
            "hook codehash drifted"
        );

        token = address(new MockToken());

        // ---- install the policy as the wallet would ----
        KrexaSwapPolicy.PolicyConfig memory c;
        c.validUntil = uint48(block.timestamp + 1 days);
        c.usdc = USDC;
        c.hook = address(HOOK);
        c.maxOpWei = 0.01 ether;
        c.spenders = new address[](1);
        c.spenders[0] = router;
        c.tokens = new address[](1);
        c.tokens[0] = token;
        c.targets = new KrexaSwapPolicy.TargetCfg[](1);
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = SwapDecoder.SR02_EXACT_INPUT_SINGLE;
        c.targets[0] = KrexaSwapPolicy.TargetCfg({target: router, selectors: sels});
        vm.prank(wallet);
        POLICY.onInstall(abi.encodePacked(PID, abi.encode(c)));

        // ---- install the hook ----
        KrexaRiskHook.HookConfig memory h;
        h.maxDailyLossUsdc = 1_000e6;
        h.perTradeCapUsdc = 100e6;
        h.dailyCapUsdc = 500e6;
        h.maxOpsPerHour = 5;
        h.maxOracleAge = 3600;
        h.maxSlippageBps = 100; // 1%
        h.usdc = USDC;
        h.tokens = new KrexaRiskHook.TokenFeed[](1);
        // $2000, 8 decimals
        h.tokens[0] = KrexaRiskHook.TokenFeed({token: token, feed: address(new MockFeed(2000e8)), decimals: 18});
        vm.prank(wallet);
        HOOK.onInstall(abi.encode(h));
    }

    // ------------------------------------------------------------------ helpers
    function _swapCall(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        internal
        view
        returns (bytes memory)
    {
        SwapDecoder.SingleParams memory p = SwapDecoder.SingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: 3000,
            recipient: wallet,
            amountIn: amountIn,
            amountOutMinimum: minOut,
            sqrtPriceLimitX96: 0
        });
        return abi.encodePacked(SwapDecoder.SR02_EXACT_INPUT_SINGLE, abi.encode(p));
    }

    function _userOp(address target, bytes memory data) internal view returns (PackedUserOperation memory op) {
        bytes memory exec = abi.encodePacked(bytes20(target), uint256(0), data);
        op.sender = wallet;
        op.callData = abi.encodeWithSelector(ExecDecoder.EXECUTE, bytes32(0), exec);
        op.accountGasLimits = bytes32((uint256(200_000) << 128) | 200_000);
        op.gasFees = bytes32((uint256(1 gwei) << 128) | 1 gwei);
        op.preVerificationGas = 50_000;
    }

    /// what Kernel hands the hook: callData with the 4-byte selector stripped is NOT how it works —
    /// Kernel passes `userOp.callData[4:]` only for the executeUserOp wrapper. Here callData already
    /// starts with execute(), so the hook decodes the same bytes.
    function _hookData(address target, bytes memory data) internal pure returns (bytes memory) {
        bytes memory exec = abi.encodePacked(bytes20(target), uint256(0), data);
        return abi.encodeWithSelector(ExecDecoder.EXECUTE, bytes32(0), exec);
    }

    // ------------------------------------------------------------------ tests
    /// A well-formed buy (USDC -> token) passes both modules.
    function test_live_goodBuyPasses() public {
        if (!forked) return;
        // 100 USDC in, min 0.0495 token out (~$99 at $2000) = within 1% slippage
        bytes memory data = _swapCall(USDC, token, 100e6, 0.0495 ether);

        vm.prank(wallet);
        uint256 vd = POLICY.checkUserOpPolicy(PID, _userOp(router, data));
        assertEq(vd >> 160, uint256(uint48(block.timestamp + 1 days)), "validUntil not returned");

        vm.prank(wallet);
        HOOK.preCheck(address(0), 0, _hookData(router, data));
        assertEq(HOOK.spentInWindow(wallet), 100e6, "buy not counted");
        emit log_string("live: good buy allowed by policy AND hook");
    }

    /// The per-trade cap is enforced by the LIVE hook.
    function test_live_perTradeCapEnforced() public {
        if (!forked) return;
        bytes memory data = _swapCall(USDC, token, 101e6, 0.05 ether); // cap is 100
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.PerTradeCapExceeded.selector, 101e6, 100e6));
        HOOK.preCheck(address(0), 0, _hookData(router, data));
        emit log_string("live: per-trade cap enforced");
    }

    /// A minOut below the oracle's fair value minus slippage is refused by the LIVE hook.
    function test_live_badSlippageRefused() public {
        if (!forked) return;
        // 100 USDC should buy ~0.05 token; asking for 0.001 is a ~98% haircut
        bytes memory data = _swapCall(USDC, token, 100e6, 0.001 ether);
        vm.prank(wallet);
        vm.expectRevert();
        HOOK.preCheck(address(0), 0, _hookData(router, data));
        emit log_string("live: sandwich-grade minOut refused");
    }

    /// The session key cannot send the output anywhere but the account.
    function test_live_recipientMustBeWallet() public {
        if (!forked) return;
        address thief = makeAddr("thief");
        SwapDecoder.SingleParams memory p = SwapDecoder.SingleParams({
            tokenIn: USDC,
            tokenOut: token,
            fee: 3000,
            recipient: thief,
            amountIn: 10e6,
            amountOutMinimum: 0.00495 ether,
            sqrtPriceLimitX96: 0
        });
        bytes memory data = abi.encodePacked(SwapDecoder.SR02_EXACT_INPUT_SINGLE, abi.encode(p));
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(SwapDecoder.RecipientNotWallet.selector, thief));
        POLICY.checkUserOpPolicy(PID, _userOp(router, data));
        emit log_string("live: output to a third party denied");
    }

    /// ERC-20 transfer has no path to be allowed — the drain case.
    function test_live_transferDenied() public {
        if (!forked) return;
        bytes memory data = abi.encodeWithSelector(0xa9059cbb, makeAddr("thief"), uint256(1e6));
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.NotAllowed.selector, USDC, bytes4(0xa9059cbb)));
        POLICY.checkUserOpPolicy(PID, _userOp(USDC, data));
        emit log_string("live: USDC transfer denied");
    }

    /// A session op may not call the hook (that is what protects pause/unpause/setConfig).
    function test_live_cannotTouchHook() public {
        if (!forked) return;
        bytes memory data = abi.encodeWithSignature("unpause()");
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.TargetForbidden.selector, address(HOOK)));
        POLICY.checkUserOpPolicy(PID, _userOp(address(HOOK), data));
        emit log_string("live: session key cannot unpause the hook");
    }

    /// The owner can pause; every session op then reverts.
    function test_live_ownerPauseStopsEverything() public {
        if (!forked) return;
        vm.prank(wallet);
        HOOK.pause();
        bytes memory data = _swapCall(USDC, token, 10e6, 0.00495 ether);
        vm.prank(wallet);
        vm.expectRevert(KrexaRiskHook.HookPaused.selector);
        HOOK.preCheck(address(0), 0, _hookData(router, data));
        emit log_string("live: owner pause blocks session ops");
    }

    /// Ops per hour is enforced by the LIVE hook.
    function test_live_opsPerHourEnforced() public {
        if (!forked) return;
        bytes memory data = _swapCall(token, USDC, 0.001 ether, 1_980_000); // a sell: not spend-capped
        for (uint256 i; i < 5; ++i) {
            vm.prank(wallet);
            HOOK.preCheck(address(0), 0, _hookData(router, data));
        }
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(KrexaRiskHook.OpsPerHourExceeded.selector, uint32(5)));
        HOOK.preCheck(address(0), 0, _hookData(router, data));
        emit log_string("live: 5 ops/hour enforced, 6th refused");
    }
}
