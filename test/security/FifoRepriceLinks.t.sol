// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";

/// @notice Regression: a FIFO reprice must leave both price levels well linked.
/// @dev `AsyncFiller._append` used to set `previous` but not `next`, so an order re-appended by
///      `updatePrice` (or by a partial fill that moved its price) kept the `next` of its old level.
///      Its next removal then rewired the wrong level: `bestOrder` named a cancelled order, a crossed
///      book could not be matched, and a new order at that price reverted. Found by the proof-derived
///      invariant suite in asyncswap/v2-proofs (`official/test/proofs`).
contract FifoRepriceLinksTest is SetupHook {
    address maker = makeAddr("maker");
    address maker2 = makeAddr("maker2");
    address maker3 = makeAddr("maker3");

    function setUp() public override {
        super.setUp();
        topUp(maker, 10 ether);
        topUp(maker2, 10 ether);
        topUp(maker3, 10 ether);
    }

    /// @dev Place an order through the Router; returns it with its hook-assigned salt, and its id.
    function _place(address owner_, bool zeroForOne, uint256 amountIn, uint256 amountOutMin)
        internal
        returns (AsyncOrder memory order, bytes32 id)
    {
        order = AsyncOrder({
            key: key,
            owner: owner_,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            priorityFee: 0,
            sqrtPrice: 2 ** 96,
            salt: bytes32(0)
        });
        vm.startPrank(owner_);
        (zeroForOne ? token0 : token1).approve(address(router), amountIn);
        router.swap(order, abi.encode(AsyncSwap.UserParams(owner_, address(router), amountOutMin, 0)));
        vm.stopPrank();
        order.salt = _expectedSalt(owner_, amountIn, amountOutMin);
        id = _orderIdFor(owner_, zeroForOne, order.salt);
        assertEq(hook.asyncOrder(poolId, id), amountIn, "order rests");
    }

    function test_repriceKeepsLevelListsWellFormed() public {
        // Asks (sell 1 token0 for N token1): level 3 = [C], level 2 = [A, B].
        (, bytes32 cId) = _place(maker, true, 1 ether, 3 ether);
        (AsyncOrder memory a, bytes32 aId) = _place(maker, true, 1 ether, 2 ether);
        (AsyncOrder memory b,) = _place(maker2, true, 1 ether, 2 ether);

        // Reprice A into level 3: it joins behind C as the tail, with no successor.
        vm.prank(maker);
        hook.updatePrice(a, 3 ether);
        (,,,,, bytes32 aPrev, bytes32 aNext) = hook.orderBookOrder(poolId, aId);
        assertEq(aPrev, cId, "A re-entered behind C");
        assertEq(aNext, bytes32(0), "the tail of a level has no successor");

        // Remove A, add D at 3, then remove C and B: level 3 must be exactly [D].
        vm.prank(maker);
        router.cancelOrder(a);
        (, bytes32 dId) = _place(maker3, true, 1 ether, 3 ether);
        AsyncOrder memory c = _orderAt(maker, 3 ether);
        vm.prank(maker);
        router.cancelOrder(c);
        vm.prank(maker2);
        router.cancelOrder(b);

        (bool found, uint128 askKey, bytes32 bestAsk, address bestMaker) = hook.bestOrder(poolId, false);
        assertTrue(found, "an ask is open");
        assertEq(askKey, 3 ether, "at the level price");
        assertEq(bestAsk, dId, "the best ask is the only live ask");
        assertEq(bestMaker, maker3);
        (bytes32 head, bytes32 tail, uint32 count) = hook.orderBookLevel(poolId, false, askKey);
        assertEq(head, dId);
        assertEq(tail, dId);
        assertEq(count, 1);

        // A crossing bid (4 token1 for 1 token0 beats the ask at 3) matches D on creation.
        (, bytes32 eId) = _placeCrossing();
        assertTrue(hook.asyncOrder(poolId, dId) == 0 || hook.asyncOrder(poolId, eId) == 0, "a crossed book is matched");
    }

    /// @dev C's order struct: maker's 1-for-3 ask, with its hook-assigned salt.
    function _orderAt(address owner_, uint256 amountOutMin) internal view returns (AsyncOrder memory) {
        return AsyncOrder({
            key: key,
            owner: owner_,
            zeroForOne: true,
            amountIn: 1 ether,
            amountOutMin: amountOutMin,
            priorityFee: 0,
            sqrtPrice: 2 ** 96,
            salt: _expectedSalt(owner_, 1 ether, amountOutMin)
        });
    }

    /// @dev Places a bid that crosses the ask without asserting it rests (it is expected to match).
    function _placeCrossing() internal returns (AsyncOrder memory order, bytes32 id) {
        order = AsyncOrder({
            key: key,
            owner: maker2,
            zeroForOne: false,
            amountIn: 4 ether,
            amountOutMin: 1 ether,
            priorityFee: 0,
            sqrtPrice: 2 ** 96,
            salt: bytes32(0)
        });
        vm.startPrank(maker2);
        token1.approve(address(router), 4 ether);
        router.swap(order, abi.encode(AsyncSwap.UserParams(maker2, address(router), 1 ether, 0)));
        vm.stopPrank();
        order.salt = _expectedSalt(maker2, 4 ether, 1 ether);
        id = _orderIdFor(maker2, false, order.salt);
    }
}
