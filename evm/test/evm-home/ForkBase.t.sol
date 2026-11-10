// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KrexaSwapPolicy} from "../../src/evm-home/KrexaSwapPolicy.sol";
import {KrexaRiskHook} from "../../src/evm-home/KrexaRiskHook.sol";
import {OracleLib} from "../../src/evm-home/lib/OracleLib.sol";
import {SwapDecoder} from "../../src/evm-home/lib/SwapDecoder.sol";
import {ExecDecoder} from "../../src/evm-home/lib/ExecDecoder.sol";
import {PackedUserOperation} from "../../src/evm-home/interfaces/PackedUserOperation.sol";

interface IERC20Like {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice OPTIONAL Base mainnet fork checks. Skipped unless BASE_MAINNET_RPC_URL is set in the environment
/// (the URL, which may contain a key, is never written to a file). They prove that the addresses, selectors and
/// calldata layouts the policy relies on match the deployed contracts. Addresses below are the published Base
/// deployments; the test fails loudly if any has no code, so a wrong address cannot pass silently.
contract ForkBaseTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant SWAP_ROUTER02 = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;
    address constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    bytes32 constant PID = bytes32(bytes4(0xabcd1234));
    KrexaSwapPolicy policy;
    KrexaRiskHook hook;
    address wallet = makeAddr("forkWallet");
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        policy = new KrexaSwapPolicy();
        KrexaSwapPolicy.PolicyConfig memory c;
        c.validUntil = uint48(block.timestamp + 1 days);
        c.usdc = USDC;
        c.spenders = new address[](3);
        c.spenders[0] = SWAP_ROUTER02;
        c.spenders[1] = UNIVERSAL_ROUTER;
        c.spenders[2] = PERMIT2;
        c.targets = new KrexaSwapPolicy.TargetCfg[](3);
        c.targets[0].target = SWAP_ROUTER02;
        c.targets[0].selectors = new bytes4[](1);
        c.targets[0].selectors[0] = SwapDecoder.SR02_EXACT_INPUT_SINGLE;
        c.targets[1].target = UNIVERSAL_ROUTER;
        c.targets[1].selectors = new bytes4[](1);
        c.targets[1].selectors[0] = SwapDecoder.UR_EXECUTE;
        c.targets[2].target = PERMIT2;
        c.targets[2].selectors = new bytes4[](1);
        c.targets[2].selectors[0] = SwapDecoder.PERMIT2_APPROVE;
        c.tokens = new address[](1);
        c.tokens[0] = WETH;
        c.maxOpWei = 0.002 ether;
        vm.prank(wallet);
        policy.onInstall(abi.encodePacked(PID, abi.encode(c)));

        hook = new KrexaRiskHook();
        KrexaRiskHook.HookConfig memory h;
        h.maxDailyLossUsdc = uint128(50e6);
        h.perTradeCapUsdc = uint128(100e6);
        h.dailyCapUsdc = uint128(300e6);
        h.maxOpsPerHour = 10;
        h.maxOracleAge = 7200; // Chainlink ETH/USD heartbeat on Base is 20 min
        h.maxSlippageBps = 300;
        h.usdc = USDC;
        h.tokens = new KrexaRiskHook.TokenFeed[](1);
        h.tokens[0] = KrexaRiskHook.TokenFeed(WETH, ETH_USD_FEED, 18);
        vm.prank(wallet);
        hook.onInstall(abi.encode(h));
    }

    modifier onlyFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function test_fork_contractsExist() public onlyFork {
        assertGt(USDC.code.length, 0, "USDC");
        assertGt(WETH.code.length, 0, "WETH");
        assertGt(SWAP_ROUTER02.code.length, 0, "SwapRouter02");
        assertGt(UNIVERSAL_ROUTER.code.length, 0, "UniversalRouter");
        assertGt(PERMIT2.code.length, 0, "Permit2");
        assertGt(ALLOWANCE_HOLDER.code.length, 0, "AllowanceHolder");
        assertGt(ETH_USD_FEED.code.length, 0, "ETH/USD feed");
    }

    function test_fork_realChainlinkFeed() public onlyFork {
        (bool ok, uint256 answer, uint8 fd) = OracleLib.read(ETH_USD_FEED, 7200);
        assertTrue(ok, "feed stale or unreadable");
        assertEq(fd, 8);
        assertGt(answer, 100e8); // ETH above $100
        assertLt(answer, 100_000e8); // and below $100k
        uint256 oneEth = OracleLib.toUsdc(1e18, 18, answer, fd);
        assertEq(oneEth, answer / 100); // 8-decimal USD price -> 6-decimal USDC
    }

    /// the policy accepts a real SwapRouter02 call and the router really executes the same bytes
    function test_fork_swapRouter02Roundtrip() public onlyFork {
        deal(USDC, wallet, 1000e6);
        // minOut 0 is rejected by the slippage proof (300 bps configured); set it from the oracle
        (, uint256 answer,) = OracleLib.read(ETH_USD_FEED, 7200);
        uint256 minOut = (50e6 * 1e18 / (answer / 100)) * 98 / 100;
        bytes memory swap = abi.encodeWithSelector(
            SwapDecoder.SR02_EXACT_INPUT_SINGLE,
            SwapDecoder.SingleParams(USDC, WETH, 500, wallet, 50e6, minOut, 0)
        );
        bytes memory callData = abi.encodeWithSelector(
            ExecDecoder.EXECUTE, bytes32(0), abi.encodePacked(SWAP_ROUTER02, uint256(0), swap)
        );
        PackedUserOperation memory op;
        op.sender = wallet;
        op.callData = callData;
        vm.prank(wallet);
        policy.checkUserOpPolicy(PID, op);
        vm.prank(wallet);
        hook.preCheck(address(0), 0, callData); // limits + slippage proof against the real Chainlink feed

        vm.startPrank(wallet);
        IERC20Like(USDC).approve(SWAP_ROUTER02, 50e6);
        (bool ok,) = SWAP_ROUTER02.call(swap);
        vm.stopPrank();
        assertTrue(ok, "real SwapRouter02 rejected the calldata the policy accepted");
        assertGt(IERC20Like(WETH).balanceOf(wallet), 0);
    }

    /// approve -> Permit2.approve -> Universal Router V3_SWAP_EXACT_IN, as one batch: the policy accepts it and
    /// the real router executes the same bytes (validates the UR input layout and the Permit2 approve selector)
    function test_fork_universalRouterRoundtrip() public onlyFork {
        deal(USDC, wallet, 1000e6);
        (, uint256 answer,) = OracleLib.read(ETH_USD_FEED, 7200);
        uint256 minOut = (50e6 * 1e18 / (answer / 100)) * 98 / 100;
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(wallet, uint256(50e6), minOut, abi.encodePacked(USDC, uint24(500), WETH), true);
        ExecDecoder.Call[] memory calls = new ExecDecoder.Call[](3);
        calls[0] = ExecDecoder.Call(USDC, 0, abi.encodeWithSelector(SwapDecoder.ERC20_APPROVE, PERMIT2, uint256(50e6)));
        calls[1] = ExecDecoder.Call(
            PERMIT2,
            0,
            abi.encodeWithSelector(
                SwapDecoder.PERMIT2_APPROVE, USDC, UNIVERSAL_ROUTER, uint160(50e6), uint48(block.timestamp + 1 hours)
            )
        );
        calls[2] = ExecDecoder.Call(
            UNIVERSAL_ROUTER,
            0,
            abi.encodeWithSelector(SwapDecoder.UR_EXECUTE, hex"00", inputs, block.timestamp + 600)
        );
        PackedUserOperation memory op;
        op.sender = wallet;
        op.callData = abi.encodeWithSelector(ExecDecoder.EXECUTE, bytes32(bytes1(0x01)), abi.encode(calls));
        vm.prank(wallet);
        policy.checkUserOpPolicy(PID, op);
        vm.prank(wallet);
        hook.preCheck(address(0), 0, op.callData);

        vm.startPrank(wallet);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = calls[i].target.call(calls[i].data);
            assertTrue(ok, "real contract rejected a call the policy accepted");
        }
        vm.stopPrank();
        assertGt(IERC20Like(WETH).balanceOf(wallet), 0);
    }
}
