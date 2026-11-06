// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "./SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

/// @notice An incoming order goes to whichever venue quotes it better. Before routing, a resting ask
///         priced worse than the pool still took the whole of an incoming buy within its limit.
contract BestPriceRoutingTest is SetupHook {
    address alice = makeAddr("alice"); // resting maker
    address bob = makeAddr("bob"); // incoming taker

    function setUp() public override {
        super.setUp();
        topUp(alice, 1_000 ether);
        topUp(bob, 1_000 ether);
        // Deep liquidity around the 1:1 pool price.
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);
        token0.approve(address(lp), type(uint256).max);
        token1.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(key, ModifyLiquidityParams(-60, 60, 1e24, 0), "");
    }

    function _submit(address maker, bool zeroForOne, uint256 amountIn, uint256 amountOutMin)
        internal
        returns (AsyncOrder memory order)
    {
        order = AsyncOrder(key, maker, zeroForOne, amountIn, amountOutMin, 100_000, 2 ** 96, bytes32(0));
        MockERC20 input = zeroForOne ? token0 : token1;
        vm.startPrank(maker);
        input.approve(address(router), amountIn + 100_000);
        router.swap(order, abi.encode(AsyncSwap.UserParams(maker, address(router), amountOutMin, 100_000)));
        vm.stopPrank();
        order.salt = _expectedSalt(maker, amountIn, amountOutMin);
    }

    function _asset(address who) internal view returns (uint256) {
        return token0.balanceOf(who) + manager.balanceOf(who, currency0.toId());
    }

    /// The pool quotes about 1 USDC per asset; a resting ask wants 1.05. A buy of 10.5 USDC with a
    /// limit of 9.9 asset gets about 10.5 asset from the pool, but only 10 from the ask.
    function test_buyFillsFromThePoolWhenItBeatsTheBestAsk() public {
        AsyncOrder memory ask = _submit(alice, true, 10 ether, 10.5 ether);
        bytes32 askId = _orderIdFor(alice, true, ask.salt);
        assertEq(hook.asyncOrder(poolId, askId), 10 ether, "the ask rests above the pool price");

        uint256 before = _asset(bob);
        _submit(bob, false, 10.5 ether, 9.9 ether);

        assertGt(_asset(bob) - before, 10 ether, "the buyer gets more than the ask's 10 asset");
        assertEq(hook.asyncOrder(poolId, askId), 10 ether, "the worse ask is left resting");
    }

    /// A sell mirrors it: a resting bid below the pool price does not take a sell the pool pays more for.
    function test_sellFillsFromThePoolWhenItBeatsTheBestBid() public {
        AsyncOrder memory bid = _submit(alice, false, 9.5 ether, 10 ether);
        bytes32 bidId = _orderIdFor(alice, false, bid.salt);
        assertEq(hook.asyncOrder(poolId, bidId), 9.5 ether, "the bid rests below the pool price");

        uint256 before = token1.balanceOf(bob) + manager.balanceOf(bob, currency1.toId());
        _submit(bob, true, 10 ether, 9.4 ether);

        uint256 received = token1.balanceOf(bob) + manager.balanceOf(bob, currency1.toId()) + 100_000 - before;
        assertGt(received, 9.5 ether, "the seller gets more than the bid's 9.5 USDC");
        assertEq(hook.asyncOrder(poolId, bidId), 9.5 ether, "the worse bid is left resting");
    }
}
