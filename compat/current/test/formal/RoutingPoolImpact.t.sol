// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

/// @notice FM-01 (audit/FM-01-routing-pool-impact.md): `_poolBeatsBook` compares only the pool's spot
///         tick to the best opposite level. Before the fix, a spot one tick better sent the whole order
///         through the pool, whose impact could drive its average far past a resting order it never
///         touched. Going first, the pool swap is now limited at the best book level.
contract RoutingPoolImpactTest is SetupHook {
    address alice = makeAddr("alice"); // resting ask
    address bob = makeAddr("bob"); // incoming buyer

    function setUp() public override {
        super.setUp();
        topUp(alice, 1_000 ether);
        topUp(bob, 1_000 ether);
        // Thin full-range liquidity at spot 1.0 (about 10 of each token).
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);
        token0.approve(address(lp), type(uint256).max);
        token1.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(key, ModifyLiquidityParams(-887272, 887272, 10 ether, 0), "");
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

    function test_poolSpotBetterNoLongerTakesWholeOrderPastTheBook() public {
        // Ask: 10 asset for 10.02 USDC (price ~1.002, ~19 ticks above the pool's spot).
        AsyncOrder memory ask = _submit(alice, true, 10 ether, 10.02 ether);
        bytes32 askId = _orderIdFor(alice, true, ask.salt);
        assertEq(hook.asyncOrder(poolId, askId), 10 ether, "ask rests");

        // Bob buys with 10 USDC. Through the pool alone he got ~5 asset; the ask gives him ~9.98.
        uint256 before = _asset(bob);
        _submit(bob, false, 10 ether, 4 ether);
        uint256 got = _asset(bob) - before;

        assertGt(got, 9.9 ether, "bob is filled at the ask's price");
        assertLt(hook.asyncOrder(poolId, askId), 0.1 ether, "the ask took the order");
    }

    function test_poolStillTakesAnOrderItFillsBeforeTheBookLevel() public {
        AsyncOrder memory ask = _submit(alice, true, 10 ether, 10.02 ether);
        bytes32 askId = _orderIdFor(alice, true, ask.salt);

        // A small buy moves the pool a few ticks, short of the 19 to the ask: the pool is still better.
        uint256 before = _asset(bob);
        _submit(bob, false, 0.001 ether, 0.0009 ether);

        assertGt(_asset(bob) - before, 0.000995 ether, "filled near the pool's spot");
        assertEq(hook.asyncOrder(poolId, askId), 10 ether, "the ask is left for a worse price");
    }
}
