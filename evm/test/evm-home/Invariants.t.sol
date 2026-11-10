// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EvmHomeBase} from "./EvmHomeBase.sol";
import {KrexaSwapPolicy} from "../../src/evm-home/KrexaSwapPolicy.sol";
import {KrexaRiskHook} from "../../src/evm-home/KrexaRiskHook.sol";

/// @dev The test contract is its own handler: only the `handle*` functions are fuzzed (targetSelector).
contract HookWindowInvariantTest is EvmHomeBase {
    uint256[] internal hrs;
    uint256[] internal amts;

    function setUp() public override {
        super.setUp();
        KrexaRiskHook.HookConfig memory h = hookConfig();
        h.maxOracleAge = uint32(3650 days);
        h.maxOpsPerHour = 10_000;
        vm.prank(wallet);
        hook.onInstall(abi.encode(h));

        bytes4[] memory sel = new bytes4[](1);
        sel[0] = this.handleBuy.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: sel}));
        targetContract(address(this));
    }

    /// @dev random time step then a random buy; the model tracks accepted buys by hour
    function handleBuy(uint96 amount, uint32 dt) external {
        vm.warp(block.timestamp + (dt % 7 hours));
        uint256 a = bound(amount, 1, 150 * U);
        ethFeed.set(2500e8);
        vm.prank(wallet);
        try hook.preCheck(entryPoint, 0, _buy(a)) returns (bytes memory) {
            hrs.push(block.timestamp / 1 hours);
            amts.push(a);
        } catch {}
    }

    function _modelWindow() internal view returns (uint256 sum) {
        uint256 h = block.timestamp / 1 hours;
        for (uint256 i; i < hrs.length; ++i) {
            if (hrs[i] + 25 > h) sum += amts[i];
        }
    }

    /// no sequence of ops can ever exceed the rolling daily cap
    function invariant_windowNeverExceedsCap() public view {
        assertLe(hook.spentInWindow(wallet), 250 * U);
    }

    /// the contract's ring buffer agrees with an independent per-hour model
    function invariant_windowMatchesModel() public view {
        assertEq(hook.spentInWindow(wallet), _modelWindow());
    }

    /// remaining + spent is always the cap
    function invariant_remainingConsistent() public view {
        assertEq(hook.remainingDaily(wallet) + hook.spentInWindow(wallet), 250 * U);
    }
}

contract HookInvariantTest is EvmHomeBase {
    bool internal buyPassedWhileBlocked;
    bool internal sellRejected;
    uint256 internal buysPassed;

    function setUp() public override {
        super.setUp();
        KrexaRiskHook.HookConfig memory h = hookConfig();
        h.maxOpsPerHour = type(uint32).max; // the invariants below are about the loss gate, not the rate limit
        h.perTradeCapUsdc = type(uint128).max;
        h.dailyCapUsdc = type(uint128).max;
        h.maxOracleAge = uint32(3650 days);
        vm.prank(wallet);
        hook.onInstall(abi.encode(h));
        usdc.mint(wallet, 500 * U);
        weth.mint(wallet, 0.2e18);

        bytes4[] memory sel = new bytes4[](1);
        sel[0] = this.handleAct.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: sel}));
        targetContract(address(this));
    }

    function _runOp(bool isBuy, uint256 amount) internal {
        (bool blocked,,,,) = hook.riskState(wallet);
        vm.prank(wallet);
        bytes memory d;
        try hook.preCheck(entryPoint, 0, isBuy ? _buy(1) : _sell(1)) returns (bytes memory r) {
            d = r;
        } catch {
            return; // e.g. a buy through a stale feed is refused before it can run
        }
        if (isBuy) {
            uint256 spend = bound(amount, 1, usdc.balanceOf(wallet) + 1);
            if (spend > usdc.balanceOf(wallet)) return;
            usdc.burn(wallet, spend);
            weth.mint(wallet, spend * 4e8);
        } else {
            uint256 sold = bound(amount, 1, weth.balanceOf(wallet) + 1);
            if (sold > weth.balanceOf(wallet)) return;
            weth.burn(wallet, sold);
            usdc.mint(wallet, sold / 4e8);
        }
        vm.prank(wallet);
        try hook.postCheck(d) {
            if (isBuy) {
                buysPassed++;
                if (blocked) buyPassedWhileBlocked = true;
            }
        } catch {
            if (!isBuy) sellRejected = true;
        }
    }

    /// kind: 0 move time + refresh price, 1 buy, 2 sell, 3 owner withdraws, 4 owner deposits, 5 price tick (stale allowed)
    function handleAct(uint8 kind, uint96 amount, uint32 dt, uint16 price) external {
        kind = kind % 6;
        if (kind == 0) {
            vm.warp(block.timestamp + (dt % 30 hours));
            ethFeed.set(int256(500e8 + uint256(price % 4000) * 1e8));
        } else if (kind == 1) {
            _runOp(true, amount);
        } else if (kind == 2) {
            _runOp(false, amount);
        } else if (kind == 3) {
            uint256 w = bound(amount, 0, usdc.balanceOf(wallet));
            usdc.burn(wallet, w);
        } else if (kind == 4) {
            usdc.mint(wallet, bound(amount, 0, 200 * U));
        } else {
            vm.warp(block.timestamp + (dt % 3 hours)); // may leave the feed stale
        }
    }

    /// a buy that reduces USDC / increases a token never passes while the hook says buys are blocked
    function invariant_noBuyWhileBlocked() public view {
        assertFalse(buyPassedWhileBlocked);
    }

    /// sells are never rejected by the hook (they only decrease token balances and increase USDC)
    function invariant_sellsNeverRejected() public view {
        assertFalse(sellRejected);
    }
}
