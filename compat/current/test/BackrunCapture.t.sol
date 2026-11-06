// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "./SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/// @notice A large pool fill moves the pool price; the order that moves it back earns the gap. The
///         protocol should keep a share of that gap, measured in USDC (`currency1` here), rather than
///         only the static 0.01% of the backrun's input.
contract BackrunCaptureTest is SetupHook {
    using StateLibrary for IPoolManager;

    address alice = makeAddr("alice"); // large seller
    address bob = makeAddr("bob"); // backrunner

    function setUp() public override {
        super.setUp();
        topUp(alice, 10_000 ether);
        topUp(bob, 10_000 ether);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);
        token0.approve(address(lp), type(uint256).max);
        token1.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(key, ModifyLiquidityParams(-60, 60, 1e24, 0), "");
    }

    function _submit(address maker, bool zeroForOne, uint256 amountIn, uint256 amountOutMin) internal {
        AsyncOrder memory order =
            AsyncOrder(key, maker, zeroForOne, amountIn, amountOutMin, 100_000, 2 ** 96, bytes32(0));
        MockERC20 input = zeroForOne ? token0 : token1;
        vm.startPrank(maker);
        input.approve(address(router), amountIn + 100_000);
        router.swap(order, abi.encode(AsyncSwap.UserParams(maker, address(router), amountOutMin, 100_000)));
        vm.stopPrank();
    }

    function _held(address who, bool asset) internal view returns (uint256) {
        return asset
            ? token0.balanceOf(who) + manager.balanceOf(who, currency0.toId())
            : token1.balanceOf(who) + manager.balanceOf(who, currency1.toId());
    }

    /// @dev What the FeeVault and the in-range LPs hold, valued at the 1:1 reference price.
    function _captured() internal view returns (uint256) {
        address vault = address(hook.feeVault());
        (uint256 g0, uint256 g1) = manager.getFeeGrowthGlobals(poolId);
        // All liquidity (1e24) is in range, so LP fees are fee growth times liquidity over 2^128.
        uint256 lps = ((g0 + g1) * 1e24) >> 128;
        return manager.balanceOf(vault, currency0.toId()) + manager.balanceOf(vault, currency1.toId()) + lps;
    }

    /// @dev Alice sells 2,000 asset into the pool, pushing the price down; returns the USDC she got.
    function _bigSell() internal returns (uint256 received) {
        uint256 before = _held(alice, false);
        _submit(alice, true, 2_000 ether, 1_900 ether);
        received = _held(alice, false) - before;
    }

    /// @dev Bob buys with `usdc` in `legs` equal orders; returns his profit at the 1:1 reference price
    ///      and what the vault and LPs captured meanwhile.
    function _backrun(uint256 usdc, uint256 legs) internal returns (int256 profit, uint256 captured) {
        uint256 c = _captured();
        uint256 a = _held(bob, true);
        uint256 u = _held(bob, false);
        for (uint256 i; i < legs; ++i) {
            _submit(bob, false, usdc / legs, 1);
        }
        profit = int256(_held(bob, true) - a) - int256(u - _held(bob, false));
        captured = _captured() - c;
    }

    /// Bob buys back with the USDC Alice received. Valued at the pre-sell price, the vault and LPs
    /// together should keep at least as much of the gap as Bob does.
    function test_backrunPaysAShareOfTheGap() public {
        (, int24 tickBefore,,) = manager.getSlot0(poolId);
        uint256 received = _bigSell();
        (, int24 tickAfterSell,,) = manager.getSlot0(poolId);
        assertLt(tickAfterSell, tickBefore - 10, "the sell moved the pool price down");

        (int256 profit, uint256 captured) = _backrun(received, 1);
        emit log_named_decimal_int("backrunner profit", profit, 18);
        emit log_named_decimal_uint("vault + LPs captured", captured, 18);
        assertGt(profit, 0, "the backrun stays profitable");
        assertGe(int256(captured), profit, "the vault and LPs keep at least half of the gap");
    }

    /// Splitting the backrun into five orders in the same block keeps about the same profit.
    function test_splittingTheBackrunDoesNotPayLess() public {
        uint256 snap = vm.snapshotState();
        uint256 received = _bigSell();
        (int256 single,) = _backrun(received, 1);
        vm.revertToState(snap);
        received = _bigSell();
        (int256 split,) = _backrun(received, 5);
        emit log_named_decimal_int("single-order profit", single, 18);
        emit log_named_decimal_int("five-order profit", split, 18);
        // Within 10% of the single order's profit (the tick average is linear, the price curve is not).
        assertLe(split, single + single / 10, "splitting doesn't earn meaningfully more");
    }

    /// Once the window has passed, the earlier price is no longer a reference: no premium.
    function test_noPremiumAfterTheWindow() public {
        uint256 received = _bigSell();
        vm.roll(block.number + 3);
        uint256 vault = manager.balanceOf(address(hook.feeVault()), currency0.toId());
        _backrun(received, 1);
        // Only the 0.01% protocol fee on the USDC input; no premium in the asset.
        assertEq(manager.balanceOf(address(hook.feeVault()), currency0.toId()), vault, "no asset premium");
    }
}
