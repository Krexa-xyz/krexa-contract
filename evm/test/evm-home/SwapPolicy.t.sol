// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EvmHomeBase} from "./EvmHomeBase.sol";
import {KrexaSwapPolicy} from "../../src/evm-home/KrexaSwapPolicy.sol";
import {ExecDecoder} from "../../src/evm-home/lib/ExecDecoder.sol";
import {SwapDecoder} from "../../src/evm-home/lib/SwapDecoder.sol";
import {PackedUserOperation} from "../../src/evm-home/interfaces/PackedUserOperation.sol";
import {MockFeed} from "./mocks/Mocks.sol";

/// @notice Unit + fuzz tests for KrexaSwapPolicy. Cases ported in spirit from test/AgentWallet.t.sol
/// (whitelist allowed/blocked -> target allowlist; perTx/20%/daily limits -> per-trade/rolling budget;
/// daily reset after 24h -> test_dailyBudgetRolls; frozen -> pause (RiskHook.t.sol); execute/batchExecute
/// rejects unauthorized + mismatched arrays -> target/selector denial + canonical batch encoding) and from
/// test/SecurityHardening.t.sol (zero-address/zero-amount rejection, admin-only config, event emission).
contract SwapPolicyTest is EvmHomeBase {
    // ================================================================ install / lifecycle
    function test_installStoresConfig() public view {
        KrexaSwapPolicy.Cfg memory c = policy.getConfig(PID, wallet);
        assertTrue(c.installed);
        assertEq(c.validUntil, uint48(T0 + 7 days));
        assertEq(c.usdc, address(usdc));
        assertEq(c.hook, address(hook));
        assertTrue(policy.isInitialized(wallet));
        assertFalse(policy.isInitialized(attacker));
        assertTrue(policy.isModuleType(5));
        assertFalse(policy.isModuleType(4));
        assertTrue(policy.isTargetAllowed(PID, wallet, sr02, SwapDecoder.SR02_EXACT_INPUT_SINGLE));
        assertFalse(policy.isTargetAllowed(PID, wallet, sr02, SwapDecoder.UR_EXECUTE));
        assertTrue(policy.isSpenderAllowed(PID, wallet, ur));
        assertFalse(policy.isSpenderAllowed(PID, wallet, attacker));
        assertTrue(policy.isTokenAllowed(PID, wallet, address(weth)));
        assertTrue(policy.isTokenAllowed(PID, wallet, address(usdc)));
        assertFalse(policy.isTokenAllowed(PID, wallet, address(junk)));
    }

    function test_installTwiceReverts() public {
        bytes memory d = abi.encodePacked(PID, abi.encode(defaultConfig()));
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSignature("AlreadyInitialized(address)", wallet));
        policy.onInstall(d);
    }

    function test_uninstallThenCheckFailsAndReinstallStartsEmpty() public {
        vm.prank(wallet);
        policy.onUninstall(abi.encodePacked(PID));
        assertFalse(policy.isInitialized(wallet));
        PackedUserOperation memory op = _userOp(wallet, _buy(10 * U));
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSignature("NotInitialized(address)", wallet));
        policy.checkUserOpPolicy(PID, op);

        // reinstall with a config that lists no sr02: the old sr02 allowlist entry must not come back
        KrexaSwapPolicy.PolicyConfig memory c = defaultConfig();
        KrexaSwapPolicy.TargetCfg[] memory t = new KrexaSwapPolicy.TargetCfg[](1);
        t[0] = c.targets[1];
        c.targets = t;
        vm.prank(wallet);
        policy.onInstall(abi.encodePacked(PID, abi.encode(c)));
        assertFalse(policy.isTargetAllowed(PID, wallet, sr02, SwapDecoder.SR02_EXACT_INPUT_SINGLE));
        vm.expectRevert(
            abi.encodeWithSelector(KrexaSwapPolicy.NotAllowed.selector, sr02, SwapDecoder.SR02_EXACT_INPUT_SINGLE)
        );
        _check(_buy(10 * U));
    }

    function test_uninstallNotInstalledReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("NotInitialized(address)", attacker));
        policy.onUninstall(abi.encodePacked(PID));
    }

    function test_checkNotInstalledReverts() public {
        PackedUserOperation memory op = _userOp(attacker, _buy(U));
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("NotInitialized(address)", attacker));
        policy.checkUserOpPolicy(PID, op);
    }

    function test_senderMismatchReverts() public {
        PackedUserOperation memory op = _userOp(attacker, _buy(U));
        vm.prank(wallet);
        vm.expectRevert(KrexaSwapPolicy.BadSender.selector);
        policy.checkUserOpPolicy(PID, op);
    }

    function test_signaturePolicyAlwaysDenies() public view {
        assertEq(policy.checkSignaturePolicy(PID, wallet, keccak256("x"), hex"1234"), 1);
    }

    // ================================================================ happy paths
    function test_buyAllowedReturnsValidUntil() public {
        uint256 vd = _check(_buy(10 * U));
        assertEq(vd, uint256(uint48(T0 + 7 days)) << 160); // validUntil in the high bits, authorizer 0, validAfter 0
    }

    function test_hookedWrapperAccepted() public {
        _check(_wrapHooked(_buy(10 * U)));
    }

    function test_typicalBatchApproveThenSwap() public {
        address[] memory t = new address[](2);
        bytes[] memory d = new bytes[](2);
        t[0] = address(usdc);
        d[0] = _approve(sr02, type(uint256).max);
        t[1] = sr02;
        d[1] = _sr02Single(address(usdc), address(weth), wallet, 40 * U, 0);
        _check(_batch(t, d));
    }

    function test_sellAllowedAndNotCounted() public {
        _check(_sell(1000e18)); // the policy has no amount limits: those live in the hook
    }

    // ================================================================ target / selector allowlist
    function test_nonSessionTargetRejected() public {
        // a router that is not in the allowlist
        vm.expectRevert(
            abi.encodeWithSelector(KrexaSwapPolicy.NotAllowed.selector, attacker, SwapDecoder.SR02_EXACT_INPUT_SINGLE)
        );
        _check(_single(attacker, 0, _sr02Single(address(usdc), address(weth), wallet, U, 0)));
    }

    function test_selectorNotOnTargetRejected() public {
        // sr02 only has exactInputSingle/exactInput; the Universal Router selector is not allowed on it
        bytes memory d = abi.encodeWithSelector(SwapDecoder.UR_EXECUTE, hex"00", new bytes[](1), uint256(0));
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.NotAllowed.selector, sr02, SwapDecoder.UR_EXECUTE));
        _check(_single(sr02, 0, d));
    }

    function test_transferAndTransferFromRejected() public {
        vm.expectRevert(
            abi.encodeWithSelector(KrexaSwapPolicy.NotAllowed.selector, address(usdc), bytes4(0xa9059cbb))
        );
        _check(_single(address(usdc), 0, abi.encodeWithSignature("transfer(address,uint256)", attacker, U)));
        vm.expectRevert(
            abi.encodeWithSelector(KrexaSwapPolicy.NotAllowed.selector, address(usdc), bytes4(0x23b872dd))
        );
        _check(
            _single(address(usdc), 0, abi.encodeWithSignature("transferFrom(address,address,uint256)", wallet, attacker, U))
        );
    }

    function test_shortCalldataRejected() public {
        vm.expectRevert(KrexaSwapPolicy.BadCalldata.selector);
        _check(_single(sr02, 0, hex"0102"));
        vm.expectRevert(KrexaSwapPolicy.BadCalldata.selector);
        _check(_single(sr02, 0, ""));
    }

    function test_settlerCannotBeCalledDirectly() public {
        bytes memory d = abi.encodeWithSelector(
            SwapDecoder.ZEROX_SETTLER_EXECUTE,
            SwapDecoder.Slippage(wallet, address(weth), 1),
            new bytes[](0),
            bytes32(0)
        );
        vm.expectRevert(
            abi.encodeWithSelector(SwapDecoder.SelectorUnsupported.selector, SwapDecoder.ZEROX_SETTLER_EXECUTE)
        );
        _check(_single(settler, 0, d));
    }

    // ================================================================ value / self targets
    function test_valueRejected() public {
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.ValueNotAllowed.selector, 1));
        _check(_single(sr02, 1, _sr02Single(address(usdc), address(weth), wallet, U, 0)));

        ExecDecoder.Call[] memory calls = new ExecDecoder.Call[](2);
        calls[0] = ExecDecoder.Call(sr02, 0, _sr02Single(address(usdc), address(weth), wallet, U, 0));
        calls[1] = ExecDecoder.Call(sr02, 1 ether, _sr02Single(address(usdc), address(weth), wallet, U, 0));
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.ValueNotAllowed.selector, 1 ether));
        _check(_batchCalls(calls));
    }

    function test_sessionCannotInstallModule() public {
        // Kernel's installModule is onlyEntryPointOrSelfOrRoot: a call from the account to itself passes it.
        bytes memory install = abi.encodeWithSignature("installModule(uint256,address,bytes)", 1, attacker, "");
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.TargetForbidden.selector, wallet));
        _check(_single(wallet, 0, install));
        // also hidden in a batch behind a legit swap
        ExecDecoder.Call[] memory calls = new ExecDecoder.Call[](2);
        calls[0] = ExecDecoder.Call(sr02, 0, _sr02Single(address(usdc), address(weth), wallet, U, 0));
        calls[1] = ExecDecoder.Call(wallet, 0, install);
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.TargetForbidden.selector, wallet));
        _check(_batchCalls(calls));
    }

    function test_sessionCannotChangeConfig() public {
        // target = the policy itself (setConfig runs with msg.sender == account, so it would succeed if reached)
        bytes memory cd = abi.encodeCall(KrexaSwapPolicy.setConfig, (PID, defaultConfig()));
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.TargetForbidden.selector, address(policy)));
        _check(_single(address(policy), 0, cd));
        // target = the hook (unpause / setConfig)
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.TargetForbidden.selector, address(hook)));
        _check(_single(address(hook), 0, abi.encodeWithSignature("unpause()")));
    }

    function test_onlyInstalledWalletCanSetConfig() public {
        KrexaSwapPolicy.PolicyConfig memory c = defaultConfig();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.OnlyInstalledWallet.selector, attacker));
        policy.setConfig(PID, c);

        // the owner path (account itself) can: shorten the session
        c.validUntil = uint48(T0 + 1 days);
        vm.prank(wallet);
        policy.setConfig(PID, c);
        assertEq(policy.getConfig(PID, wallet).validUntil, uint48(T0 + 1 days));
        assertEq(_check(_buy(11 * U)), uint256(uint48(T0 + 1 days)) << 160);
    }

    function test_setConfigRebuildsAllowlist() public {
        KrexaSwapPolicy.PolicyConfig memory c = defaultConfig();
        KrexaSwapPolicy.TargetCfg[] memory t = new KrexaSwapPolicy.TargetCfg[](1);
        t[0] = c.targets[1]; // universal router only
        c.targets = t;
        vm.prank(wallet);
        policy.setConfig(PID, c);
        vm.expectRevert(
            abi.encodeWithSelector(KrexaSwapPolicy.NotAllowed.selector, sr02, SwapDecoder.SR02_EXACT_INPUT_SINGLE)
        );
        _check(_buy(U));
        _check(_single(ur, 0, _urBuy(wallet, U)));
    }

    // ================================================================ per-trade cap
    function test_zeroAmountRejected() public {
        vm.expectRevert(KrexaSwapPolicy.ZeroAmount.selector);
        _check(_buy(0));
    }

    // ================================================================ rolling daily budget
    // ================================================================ ops per hour
    // ================================================================ expiry
    // ================================================================ approvals
    function test_approveOnlyToRouters() public {
        _check(_single(address(usdc), 0, _approve(sr02, type(uint256).max)));
        _check(_single(address(weth), 0, _approve(permit2, 1e18)));
        _check(_single(address(usdc), 0, _approve(holder, 5 * U)));
        _check(_single(address(usdc), 0, _approve(sr02, 0))); // revoke

        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.SpenderNotAllowed.selector, attacker));
        _check(_single(address(usdc), 0, _approve(attacker, 1)));
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.SpenderNotAllowed.selector, address(0)));
        _check(_single(address(weth), 0, _approve(address(0), 1)));
        // a token that is not allowlisted is not approvable at all
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.NotAllowed.selector, address(junk), bytes4(0x095ea7b3)));
        _check(_single(address(junk), 0, _approve(sr02, 1)));
        // padded / truncated approve calldata
        vm.expectRevert(KrexaSwapPolicy.BadCalldata.selector);
        _check(_single(address(usdc), 0, bytes.concat(_approve(sr02, 1), hex"00")));
    }

    function test_permit2Approve() public {
        bytes memory ok = abi.encodeWithSelector(
            SwapDecoder.PERMIT2_APPROVE, address(weth), ur, uint160(1e18), uint48(block.timestamp + 1 days)
        );
        _check(_single(permit2, 0, ok));
        bytes memory badSpender = abi.encodeWithSelector(
            SwapDecoder.PERMIT2_APPROVE, address(weth), attacker, uint160(1e18), uint48(block.timestamp + 1 days)
        );
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.SpenderNotAllowed.selector, attacker));
        _check(_single(permit2, 0, badSpender));
        bytes memory badToken = abi.encodeWithSelector(
            SwapDecoder.PERMIT2_APPROVE, address(junk), ur, uint160(1e18), uint48(block.timestamp + 1 days)
        );
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.TokenNotAllowed.selector, address(junk)));
        _check(_single(permit2, 0, badToken));
        vm.expectRevert(KrexaSwapPolicy.BadCalldata.selector);
        _check(_single(permit2, 0, bytes.concat(ok, hex"00")));
    }

    // ================================================================ tokens / pairs
    function test_tokenNotAllowed() public {
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.TokenNotAllowed.selector, address(junk)));
        _check(_single(sr02, 0, _sr02Single(address(usdc), address(junk), wallet, U, 0)));
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.TokenNotAllowed.selector, address(junk)));
        _check(_single(sr02, 0, _sr02Single(address(junk), address(usdc), wallet, U, 0)));
    }

    function test_pairMustContainExactlyOneUsdc() public {
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.PairNotAllowed.selector, address(usdc), address(usdc)));
        _check(_single(sr02, 0, _sr02Single(address(usdc), address(usdc), wallet, U, 0)));
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.PairNotAllowed.selector, address(weth), address(weth)));
        _check(_single(sr02, 0, _sr02Single(address(weth), address(weth), wallet, U, 0)));
    }

    // ================================================================ oracle
    // ================================================================ recipient must be the account
    function test_recipientMustBeAccount_swapRouter02Single() public {
        vm.expectRevert(abi.encodeWithSelector(SwapDecoder.RecipientNotWallet.selector, attacker));
        _check(_single(sr02, 0, _sr02Single(address(usdc), address(weth), attacker, U, 0)));
        // the router-side shortcuts are not accepted either
        vm.expectRevert(abi.encodeWithSelector(SwapDecoder.RecipientNotWallet.selector, address(0)));
        _check(_single(sr02, 0, _sr02Single(address(usdc), address(weth), address(0), U, 0)));
        vm.expectRevert(abi.encodeWithSelector(SwapDecoder.RecipientNotWallet.selector, address(2)));
        _check(_single(sr02, 0, _sr02Single(address(usdc), address(weth), address(2), U, 0)));
        _check(_buy(U));
    }

    function testFuzz_recipientMustBeAccount_swapRouter02Single(address recipient) public {
        bool ok = _try(_single(sr02, 0, _sr02Single(address(usdc), address(weth), recipient, U, 0)));
        assertEq(ok, recipient == wallet);
    }

    function test_recipientMustBeAccount_swapRouter02Path() public {
        bytes memory path = _v3Path(address(usdc), address(weth));
        vm.expectRevert(abi.encodeWithSelector(SwapDecoder.RecipientNotWallet.selector, attacker));
        _check(_single(sr02, 0, _sr02Path(path, attacker, U, 0)));
        _check(_single(sr02, 0, _sr02Path(path, wallet, U, 0)));
        // multi-hop: first and last tokens are what count, the middle token is free
        bytes memory multi = abi.encodePacked(address(usdc), uint24(500), address(junk), uint24(3000), address(weth));
        _check(_single(sr02, 0, _sr02Path(multi, wallet, U, 0)));
        // path ending in a non-allowlisted token
        bytes memory bad = abi.encodePacked(address(usdc), uint24(500), address(weth), uint24(3000), address(junk));
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.TokenNotAllowed.selector, address(junk)));
        _check(_single(sr02, 0, _sr02Path(bad, wallet, U, 0)));
        // malformed path lengths
        vm.expectRevert(SwapDecoder.BadPath.selector);
        _check(_single(sr02, 0, _sr02Path(hex"aabbcc", wallet, U, 0)));
        vm.expectRevert(SwapDecoder.BadPath.selector);
        _check(_single(sr02, 0, _sr02Path(bytes.concat(path, hex"00"), wallet, U, 0)));
    }

    function test_recipientMustBeAccount_universalRouterV3() public {
        vm.expectRevert(abi.encodeWithSelector(SwapDecoder.RecipientNotWallet.selector, attacker));
        _check(_single(ur, 0, _urBuy(attacker, U)));
        // address(2) (ADDRESS_THIS) would leave the output in the router
        vm.expectRevert(abi.encodeWithSelector(SwapDecoder.RecipientNotWallet.selector, address(2)));
        _check(_single(ur, 0, _urBuy(address(2), U)));
        _check(_single(ur, 0, _urBuy(wallet, U)));
        _check(_single(ur, 0, _urBuy(address(1), U))); // MSG_SENDER constant
        // payer must be the account
        bytes[] memory in_ = _one(_urV3In(wallet, U, 0, _v3Path(address(usdc), address(weth)), false));
        vm.expectRevert(SwapDecoder.NotUserFunded.selector);
        _check(_single(ur, 0, _urExecute(hex"00", in_)));
    }

    function testFuzz_recipientMustBeAccount_universalRouterV3(address recipient) public {
        bool ok = _try(_single(ur, 0, _urBuy(recipient, U)));
        assertEq(ok, recipient == wallet || recipient == address(1));
    }

    function test_recipientMustBeAccount_universalRouterV2() public {
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);
        bytes[] memory in_ = _one(abi.encode(attacker, U, uint256(0), path, true));
        vm.expectRevert(abi.encodeWithSelector(SwapDecoder.RecipientNotWallet.selector, attacker));
        _check(_single(ur, 0, _urExecute(hex"08", in_)));

        in_ = _one(abi.encode(wallet, U, uint256(0), path, true));
        _check(_single(ur, 0, _urExecute(hex"08", in_)));

        in_ = _one(abi.encode(wallet, U, uint256(0), path, false));
        vm.expectRevert(SwapDecoder.NotUserFunded.selector);
        _check(_single(ur, 0, _urExecute(hex"08", in_)));

        address[] memory shortPath = new address[](1);
        shortPath[0] = address(usdc);
        in_ = _one(abi.encode(wallet, U, uint256(0), shortPath, true));
        vm.expectRevert(SwapDecoder.BadPath.selector);
        _check(_single(ur, 0, _urExecute(hex"08", in_)));
    }

    function test_recipientMustBeAccount_universalRouterV4() public {
        // SWAP_EXACT_IN_SINGLE(0x06) + SETTLE_ALL(0x0c) + TAKE_ALL(0x0f): output goes to msgSender
        bytes memory actions = hex"060c0f";
        bytes[] memory params = new bytes[](3);
        params[0] = _v4Single(address(usdc), address(weth), true, uint128(10 * U), 0, address(0));
        params[1] = abi.encode(address(usdc), uint256(10 * U));
        params[2] = abi.encode(address(weth), uint256(0));
        _check(_single(ur, 0, _urExecute(hex"10", _one(abi.encode(actions, params)))));

        // TAKE with an explicit recipient: attacker rejected, wallet / MSG_SENDER accepted
        actions = hex"060c0e";
        params[2] = abi.encode(address(weth), attacker, uint256(0));
        vm.expectRevert(abi.encodeWithSelector(SwapDecoder.RecipientNotWallet.selector, attacker));
        _check(_single(ur, 0, _urExecute(hex"10", _one(abi.encode(actions, params)))));
        params[2] = abi.encode(address(weth), wallet, uint256(0));
        _check(_single(ur, 0, _urExecute(hex"10", _one(abi.encode(actions, params)))));
        params[2] = abi.encode(address(weth), address(1), uint256(0));
        _check(_single(ur, 0, _urExecute(hex"10", _one(abi.encode(actions, params)))));
        params[2] = abi.encode(address(weth), address(2), uint256(0));
        vm.expectRevert(abi.encodeWithSelector(SwapDecoder.RecipientNotWallet.selector, address(2)));
        _check(_single(ur, 0, _urExecute(hex"10", _one(abi.encode(actions, params)))));
    }

    function test_universalRouterV4Variants() public {
        bytes[] memory params = new bytes[](3);
        params[1] = abi.encode(address(usdc), uint256(10 * U));
        params[2] = abi.encode(address(weth), uint256(0));

        // pool with a hook contract is rejected
        params[0] = _v4Single(address(usdc), address(weth), true, uint128(10 * U), 0, attacker);
        vm.expectRevert(abi.encodeWithSelector(SwapDecoder.PoolHookNotAllowed.selector, attacker));
        _check(_single(ur, 0, _urExecute(hex"10", _one(abi.encode(hex"060c0f", params)))));

        // oneForZero direction: sell WETH for USDC (currency0 = usdc)
        params[0] = _v4Single(address(usdc), address(weth), false, uint128(1e18), 0, address(0));
        _check(_single(ur, 0, _urExecute(hex"10", _one(abi.encode(hex"060c0f", params)))));

        // multi-hop SWAP_EXACT_IN (0x07)
        SwapDecoder.V4PathKey[] memory path = new SwapDecoder.V4PathKey[](2);
        path[0] = SwapDecoder.V4PathKey(address(junk), 500, 10, address(0), "");
        path[1] = SwapDecoder.V4PathKey(address(weth), 500, 10, address(0), "");
        params[0] = abi.encode(SwapDecoder.V4ExactInput(address(usdc), path, uint128(20 * U), 0));
        _check(_single(ur, 0, _urExecute(hex"10", _one(abi.encode(hex"070c0f", params)))));

        path[1].hooks = attacker;
        params[0] = abi.encode(SwapDecoder.V4ExactInput(address(usdc), path, uint128(20 * U), 0));
        vm.expectRevert(abi.encodeWithSelector(SwapDecoder.PoolHookNotAllowed.selector, attacker));
        _check(_single(ur, 0, _urExecute(hex"10", _one(abi.encode(hex"070c0f", params)))));

        params[0] = abi.encode(SwapDecoder.V4ExactInput(address(usdc), new SwapDecoder.V4PathKey[](0), uint128(20 * U), 0));
        vm.expectRevert(SwapDecoder.BadPath.selector);
        _check(_single(ur, 0, _urExecute(hex"10", _one(abi.encode(hex"070c0f", params)))));
    }

    function test_universalRouterV4Malformed() public {
        bytes[] memory params = new bytes[](3);
        params[0] = _v4Single(address(usdc), address(weth), true, uint128(U), 0, address(0));
        params[1] = abi.encode(address(usdc), uint256(U));
        params[2] = abi.encode(address(weth), uint256(0));

        // two swap actions
        bytes[] memory two = new bytes[](2);
        two[0] = params[0];
        two[1] = params[0];
        vm.expectRevert(SwapDecoder.Malformed.selector);
        _check(_single(ur, 0, _urExecute(hex"10", _one(abi.encode(hex"0606", two)))));
        // no swap at all
        bytes[] memory settleOnly = new bytes[](1);
        settleOnly[0] = params[1];
        vm.expectRevert(SwapDecoder.Malformed.selector);
        _check(_single(ur, 0, _urExecute(hex"10", _one(abi.encode(hex"0c", settleOnly)))));
        // actions/params length mismatch
        vm.expectRevert(SwapDecoder.Malformed.selector);
        _check(_single(ur, 0, _urExecute(hex"10", _one(abi.encode(hex"060c", params)))));
        // TAKE_PORTION (0x10) pays a fee to an arbitrary address
        bytes[] memory fee = new bytes[](2);
        fee[0] = params[0];
        fee[1] = abi.encode(address(weth), attacker, uint256(100));
        vm.expectRevert(abi.encodeWithSelector(SwapDecoder.ActionNotAllowed.selector, uint8(0x10)));
        _check(_single(ur, 0, _urExecute(hex"10", _one(abi.encode(hex"0610", fee)))));
    }

    function test_recipientMustBeAccount_universalRouterSweepAndUnwrap() public {
        // SWEEP(token, recipient, amountMin)
        bytes[] memory in_ = _one(abi.encode(address(weth), attacker, uint160(0)));
        vm.expectRevert(abi.encodeWithSelector(SwapDecoder.RecipientNotWallet.selector, attacker));
        _check(_single(ur, 0, _urExecute(hex"04", in_)));
        in_ = _one(abi.encode(address(weth), wallet, uint160(0)));
        _check(_single(ur, 0, _urExecute(hex"04", in_)));
        in_ = _one(abi.encode(address(weth), address(1), uint160(0)));
        _check(_single(ur, 0, _urExecute(hex"04", in_)));
        // UNWRAP_WETH(recipient, amountMin)
        in_ = _one(abi.encode(attacker, uint256(0)));
        vm.expectRevert(abi.encodeWithSelector(SwapDecoder.RecipientNotWallet.selector, attacker));
        _check(_single(ur, 0, _urExecute(hex"0c", in_)));
        in_ = _one(abi.encode(wallet, uint256(0)));
        _check(_single(ur, 0, _urExecute(hex"0c", in_)));
    }

    function test_universalRouterForbiddenCommands() public {
        bytes[] memory in_ = _one(abi.encode(address(usdc), attacker, uint256(U)));
        // TRANSFER 0x05, PAY_PORTION 0x06, PERMIT2_TRANSFER_FROM 0x02, WRAP_ETH 0x0b, PERMIT2_PERMIT 0x0a,
        // V3_SWAP_EXACT_OUT 0x01, V2_SWAP_EXACT_OUT 0x09, sub plan 0x21
        uint8[8] memory bad = [0x05, 0x06, 0x02, 0x0b, 0x0a, 0x01, 0x09, 0x21];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(SwapDecoder.CommandNotAllowed.selector, bad[i]));
            _check(_single(ur, 0, _urExecute(abi.encodePacked(bad[i]), in_)));
        }
        // allow-revert flag (0x80) and the 0x40 namespace are rejected even on an otherwise valid swap
        bytes[] memory swap = _one(_urV3In(wallet, U, 0, _v3Path(address(usdc), address(weth)), true));
        vm.expectRevert(abi.encodeWithSelector(SwapDecoder.CommandNotAllowed.selector, uint8(0x80)));
        _check(_single(ur, 0, _urExecute(hex"80", swap)));
        vm.expectRevert(abi.encodeWithSelector(SwapDecoder.CommandNotAllowed.selector, uint8(0x40)));
        _check(_single(ur, 0, _urExecute(hex"40", swap)));
        // commands/inputs mismatch and empty
        vm.expectRevert(SwapDecoder.Malformed.selector);
        _check(_single(ur, 0, _urExecute(hex"0000", swap)));
        vm.expectRevert(SwapDecoder.Malformed.selector);
        _check(_single(ur, 0, _urExecute(hex"", new bytes[](0))));
    }

    // ---- 0x AllowanceHolder
    function test_recipientMustBeAccount_zeroEx() public {
        bytes memory ok = _zeroEx(settler, address(usdc), 100 * U, settler, wallet, address(weth), 0.038e18);
        _check(_single(holder, 0, ok));

        vm.expectRevert(abi.encodeWithSelector(SwapDecoder.RecipientNotWallet.selector, attacker));
        _check(_single(holder, 0, _zeroEx(settler, address(usdc), U, settler, attacker, address(weth), 0.038e18)));
    }

    function test_zeroExStructureChecks() public {
        // the policy is static: it accepts a well formed 0x swap and leaves the minOut proof to the hook
        _check(_single(holder, 0, _zeroEx(settler, address(usdc), 10 * U, settler, wallet, address(weth), 1)));
        // operator != target
        vm.expectRevert(SwapDecoder.Malformed.selector);
        _check(_single(holder, 0, _zeroEx(attacker, address(usdc), U, settler, wallet, address(weth), 0.038e18)));
        // Settler not allowlisted
        vm.expectRevert(
            abi.encodeWithSelector(KrexaSwapPolicy.NotAllowed.selector, attacker, SwapDecoder.ZEROX_SETTLER_EXECUTE)
        );
        _check(_single(holder, 0, _zeroEx(attacker, address(usdc), U, attacker, wallet, address(weth), 0.038e18)));
        // inner selector is not Settler.execute
        bytes memory wrongInner = abi.encodeWithSelector(
            SwapDecoder.ZEROX_EXEC, settler, address(usdc), U, settler, abi.encodeWithSignature("foo()")
        );
        vm.expectRevert(abi.encodeWithSelector(SwapDecoder.SelectorUnsupported.selector, bytes4(keccak256("foo()"))));
        _check(_single(holder, 0, wrongInner));
    }

    function test_policyIgnoresTimeAndPrice() public {
        // no clock, no oracle, no counters: the same op is accepted far in the future and with a dead feed,
        // and any number of times. Expiry is the EntryPoint's job through the returned validationData.
        ethFeed.setBroken(true);
        vm.warp(T0 + 3650 days);
        for (uint256 i; i < 50; ++i) {
            assertEq(_check(_buy(100 * U)), uint256(uint48(T0 + 7 days)) << 160);
        }
    }

    function test_expiryIsReturnedInValidationData() public {
        uint256 vd = _check(_sell(1));
        assertEq(uint48(vd >> 160), uint48(T0 + 7 days)); // validUntil
        assertEq(uint48(vd >> 208), 0); // validAfter
        assertEq(address(uint160(vd)), address(0)); // authorizer 0 = signature valid
        KrexaSwapPolicy.PolicyConfig memory c = defaultConfig();
        c.validUntil = type(uint48).max;
        vm.prank(wallet);
        policy.setConfig(PID, c);
        assertEq(uint48(_check(_sell(1)) >> 160), type(uint48).max);
    }

    // ================================================================ ExecDecoder
    function test_execModes() public {
        bytes memory inner = abi.encodePacked(sr02, uint256(0), _sr02Single(address(usdc), address(weth), wallet, U, 0));
        // try exec type
        vm.expectRevert(abi.encodeWithSelector(ExecDecoder.UnsupportedMode.selector, bytes32(bytes2(0x0001))));
        _check(abi.encodeWithSelector(ExecDecoder.EXECUTE, bytes32(bytes2(0x0001)), inner));
        // delegatecall / static call types
        vm.expectRevert(abi.encodeWithSelector(ExecDecoder.UnsupportedMode.selector, bytes32(bytes1(0xff))));
        _check(abi.encodeWithSelector(ExecDecoder.EXECUTE, bytes32(bytes1(0xff)), inner));
        vm.expectRevert(abi.encodeWithSelector(ExecDecoder.UnsupportedMode.selector, bytes32(bytes1(0xfe))));
        _check(abi.encodeWithSelector(ExecDecoder.EXECUTE, bytes32(bytes1(0xfe)), inner));
    }

    function test_execRejectsOtherSelectors() public {
        vm.expectRevert(ExecDecoder.NotExecute.selector);
        _check(abi.encodeWithSignature("upgradeTo(address)", attacker));
        vm.expectRevert(ExecDecoder.NotExecute.selector);
        _check(hex"01");
        vm.expectRevert(ExecDecoder.NotExecute.selector);
        _check(bytes.concat(ExecDecoder.EXECUTE_USER_OP, hex"deadbeef")); // wrapper around a non-execute call
        vm.expectRevert(ExecDecoder.NotExecute.selector);
        _check(bytes.concat(ExecDecoder.EXECUTE_USER_OP));
    }

    function test_execRejectsMalformedSingleAndBatch() public {
        vm.expectRevert(ExecDecoder.BadEncoding.selector);
        _check(abi.encodeWithSelector(ExecDecoder.EXECUTE, bytes32(0), abi.encodePacked(sr02, bytes31(0)))); // 51 bytes < 0x34
    }

    function test_execEmptyBatchRejected() public {
        vm.expectRevert(KrexaSwapPolicy.EmptyExecution.selector);
        _check(_batchCalls(new ExecDecoder.Call[](0)));
    }

    function test_nonCanonicalBatchRejected() public {
        // Kernel's Solady parser follows raw pointers; abi.decode accepts an array whose element pointers are
        // reordered or padded. Re-encoding must not match, so the policy refuses to guess.
        ExecDecoder.Call[] memory calls = new ExecDecoder.Call[](1);
        calls[0] = ExecDecoder.Call(sr02, 0, _sr02Single(address(usdc), address(weth), wallet, U, 0));
        bytes memory canonical = abi.encode(calls);
        bytes memory padded = bytes.concat(canonical, hex"00");
        vm.expectRevert(ExecDecoder.BadEncoding.selector);
        _check(abi.encodeWithSelector(ExecDecoder.EXECUTE, bytes32(bytes1(0x01)), padded));
        // canonical passes
        _check(abi.encodeWithSelector(ExecDecoder.EXECUTE, bytes32(bytes1(0x01)), canonical));
    }

    // ================================================================ config validation
    function _expectInvalid(KrexaSwapPolicy.PolicyConfig memory c, string memory why) internal {
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(KrexaSwapPolicy.InvalidConfig.selector, why));
        policy.setConfig(PID, c);
    }

    function test_invalidConfigs() public {
        KrexaSwapPolicy.PolicyConfig memory c = defaultConfig();
        c.usdc = address(0);
        _expectInvalid(c, "usdc");
        c = defaultConfig();
        c.validUntil = 0;
        _expectInvalid(c, "validUntil");
        c = defaultConfig();
        c.targets = new KrexaSwapPolicy.TargetCfg[](0);
        _expectInvalid(c, "targets");
        c = defaultConfig();
        c.spenders = new address[](33);
        _expectInvalid(c, "list size");
        c = defaultConfig();
        c.tokens = new address[](33);
        _expectInvalid(c, "list size");
    }

    function test_invalidTokenTargetSpenderSelector() public {
        KrexaSwapPolicy.PolicyConfig memory c = defaultConfig();
        c.tokens[0] = address(0);
        _expectInvalid(c, "token");
        c = defaultConfig();
        c.tokens[0] = address(usdc);
        _expectInvalid(c, "token");

        c = defaultConfig();
        c.spenders[0] = wallet; // the account can never be a spender
        _expectInvalid(c, "spender");
        c = defaultConfig();
        c.spenders[0] = address(policy);
        _expectInvalid(c, "spender");
        c = defaultConfig();
        c.spenders[0] = address(hook);
        _expectInvalid(c, "spender");
        c = defaultConfig();
        c.spenders[0] = address(weth); // a token is not a router
        _expectInvalid(c, "spender");
        c = defaultConfig();
        c.spenders[0] = address(0);
        _expectInvalid(c, "spender");

        c = defaultConfig();
        c.targets[0].target = wallet;
        _expectInvalid(c, "target");
        c = defaultConfig();
        c.targets[0].target = address(usdc);
        _expectInvalid(c, "target");
        c = defaultConfig();
        c.targets[0].selectors = new bytes4[](0);
        _expectInvalid(c, "target");
        c = defaultConfig();
        c.targets[0].selectors[0] = bytes4(0xa9059cbb); // transfer is not a listable selector
        _expectInvalid(c, "selector");
    }

    // ================================================================ misc
    function test_installBadDataReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        policy.onInstall(hex"1234");
    }

    function testFuzz_randomCalldataNeverAllowed(bytes memory junkData) public {
        assertFalse(_try(junkData));
        assertFalse(_try(bytes.concat(ExecDecoder.EXECUTE, junkData)));
        assertFalse(_try(_single(sr02, 0, junkData)));
    }

    // ---------------------------------------------------------------- helper
    function _v4Single(address c0, address c1, bool zeroForOne, uint128 amountIn, uint128 minOut, address hooks)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            SwapDecoder.V4ExactInputSingle(SwapDecoder.PoolKey(c0, c1, 500, 10, hooks), zeroForOne, amountIn, minOut, "")
        );
    }
}
