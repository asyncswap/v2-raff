// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {HookUnlockBase} from "./HookUnlockBase.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapUpdatePrice.lean`. `updatePrice` needs
///         no unlock; storage words not exposed by getters (sequence, nextSequence, book word) are read
///         with `vm.load` (layout in `HookUnlockBase`).
contract AsyncSwapUpdatePriceFormalTest is HookUnlockBase {
    using PoolIdLibrary for PoolKey;

    /// @dev Orders here are placed so that `isBuy == !zeroForOne` (asks sell currency0).
    function _priceKey(bool isBuy, uint256 amountIn, uint256 amountOut) internal pure returns (uint128) {
        return AsyncFiller._priceKey(isBuy, !isBuy, amountIn, amountOut);
    }

    function _price(bytes32 id) internal view returns (uint128 p) {
        (,,, p,,,) = hook.orderBookOrder(poolId, id);
    }

    /// @dev Live order with an amountOutMin that keeps the sell-side price mulDiv in range for any n we use.
    function _live(bool zeroForOne, uint256 amountIn) internal returns (AsyncOrder memory o, bytes32 id) {
        (o, id) = _placeOrder(alice, zeroForOne, bound(amountIn, 1, 50 ether), 1 ether);
    }

    /// @dev Largest n for which the order's `_priceKey` mulDiv cannot overflow.
    function _maxN(bool isBuy, uint256 amountIn) internal pure returns (uint256) {
        return isBuy || amountIn >= 1e18 ? type(uint256).max : type(uint256).max / 1e18 * amountIn;
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapUpdatePrice.lean:72 — NotOrderOwner unless sender = owner; ZeroAmount if n = 0; OrderNotFound if stored amountIn = 0; else _remove, the mid writes, _append.
    function testFuzz_updatePrice_run(uint8 callerKind, uint256 n, bool exists, bool zeroForOne, uint256 amountIn)
        public
    {
        (AsyncOrder memory o, bytes32 id) = _live(zeroForOne, amountIn);
        if (!exists) o.salt = bytes32(uint256(o.salt) + 1);
        address caller = callerKind % 3 == 0 ? alice : callerKind % 3 == 1 ? address(router) : bob;
        if (callerKind % 4 == 3) n = 0;
        else n = bound(n, 0, _maxN(!zeroForOne, hook.asyncOrder(poolId, id)));
        vm.prank(caller);
        if (caller != alice) {
            vm.expectRevert(AsyncFiller.NotOrderOwner.selector);
            hook.updatePrice(o, n);
        } else if (n == 0) {
            vm.expectRevert(AsyncFiller.ZeroAmount.selector);
            hook.updatePrice(o, n);
        } else if (!exists) {
            vm.expectRevert(AsyncFiller.OrderNotFound.selector);
            hook.updatePrice(o, n);
        } else {
            hook.updatePrice(o, n);
            (, uint256 out) = hook.asyncOrderInfo(poolId, id);
            assertEq(out, n);
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapUpdatePrice.lean:92 — anyone but order.owner (executors included) reverts NotOrderOwner.
    function testFuzz_updatePrice_notOwner(address caller, AsyncOrder memory o, uint256 n) public {
        vm.assume(caller != o.owner);
        vm.prank(caller);
        vm.expectRevert(AsyncFiller.NotOrderOwner.selector);
        hook.updatePrice(o, n);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapUpdatePrice.lean:98 — the owner passing n = 0 reverts ZeroAmount (live order or not).
    function testFuzz_updatePrice_zero(AsyncOrder memory o, bool live) public {
        if (live) (o,) = _placeOrder(alice, true, 1 ether, 1 ether);
        vm.prank(o.owner);
        vm.expectRevert(AsyncFiller.ZeroAmount.selector);
        hook.updatePrice(o, 0);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapUpdatePrice.lean:104 — the owner with n != 0 on an order with no stored input reverts OrderNotFound.
    function testFuzz_updatePrice_notFound(AsyncOrder memory o, uint256 n) public {
        _placeOrder(alice, true, 1 ether, 1 ether);
        vm.assume(n != 0 && hook.asyncOrder(o.key.toId(), _idOf(o)) == 0);
        vm.prank(o.owner);
        vm.expectRevert(AsyncFiller.OrderNotFound.selector);
        hook.updatePrice(o, n);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapUpdatePrice.lean:127 (stale: was [1, 2^128)) — _priceKey returns the tick key in [1, 2 * MAX_TICK + 1] (observed as the stored price after a reprice to any n).
    function testFuzz_priceKey_ok(bool zeroForOne, uint256 amountIn, uint256 n) public {
        (AsyncOrder memory o, bytes32 id) = _live(zeroForOne, amountIn);
        uint256 stored = hook.asyncOrder(poolId, id);
        n = bound(n, 1, _maxN(!zeroForOne, stored));
        vm.prank(alice);
        hook.updatePrice(o, n);
        uint128 p = _price(id);
        assertGe(p, 1);
        assertLe(uint256(p), 2 * 887272 + 1);
        assertEq(p, _priceKey(!zeroForOne, stored, n), "the v4 tick key");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapUpdatePrice.lean:176 — the writes between _remove and _append: amountOutMin := n, price := _priceKey(isBuy, amountIn, n), nextSequence := nextSequence + 1 (no uint64 overflow), sequence := that.
    function testFuzz_mid_ok(bool zeroForOne, uint256 amountIn, uint256 n, uint8 others) public {
        for (uint256 i; i < bound(others, 0, 3); ++i) {
            _placeOrder(bob, !zeroForOne, 2 ether + i, 1e30); // non-crossing extra orders bump the sequence
        }
        (AsyncOrder memory o, bytes32 id) = _live(zeroForOne, amountIn);
        uint256 stored = hook.asyncOrder(poolId, id);
        n = bound(n, 1, _maxN(!zeroForOne, stored));
        uint64 seq = _nextSequence(poolId);
        vm.prank(alice);
        hook.updatePrice(o, n);
        (, uint256 out) = hook.asyncOrderInfo(poolId, id);
        assertEq(out, n, "amountOutMin := n");
        assertEq(_price(id), _priceKey(!zeroForOne, stored, n), "price := _priceKey");
        assertEq(_nextSequence(poolId), seq + 1, "nextSequence + 1");
        assertEq(_sequenceOf(poolId, id), seq + 1, "sequence := nextSequence");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapUpdatePrice.lean:203 — repricing never changes the order's escrowed amountIn, owner, side, zeroForOne, priorityFee or escrow flag.
    function testFuzz_midState_order(bool zeroForOne, uint256 amountIn, uint256 n) public {
        (AsyncOrder memory o, bytes32 id) = _live(zeroForOne, amountIn);
        n = bound(n, 1, _maxN(!zeroForOne, hook.asyncOrder(poolId, id)));
        bytes32[5] memory b = _orderWords(poolId, id);
        (address mk, uint256 inB,,, bool isBuyB,,) = hook.orderBookOrder(poolId, id);
        vm.prank(alice);
        hook.updatePrice(o, n);
        bytes32[5] memory a = _orderWords(poolId, id);
        (address mkA, uint256 inA,,, bool isBuyA,,) = hook.orderBookOrder(poolId, id);
        assertEq(mkA, mk);
        assertEq(inA, inB);
        assertEq(isBuyA, isBuyB);
        assertEq(a[0], b[0], "owner word");
        assertEq(a[1], b[1], "amountIn word");
        uint256 sideMask = uint256(0xffff) << 128;
        assertEq(uint256(a[3]) & sideMask, uint256(b[3]) & sideMask, "sides unchanged");
        assertEq(uint64(uint256(a[4])), uint64(uint256(b[4])), "bid unchanged");
        assertEq(hook.asyncOrderPriorityFee(poolId, id), 100_000);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapUpdatePrice.lean:213 — every other order is untouched (checked on an order in a price level the repriced order neither leaves nor joins, so _remove/_append cannot relink it).
    function testFuzz_midState_other_order(uint256 n) public {
        (, bytes32 otherId) = _placeOrder(bob, true, 3 ether, 9 ether); // ask at price 3
        (AsyncOrder memory o, bytes32 id) = _placeOrder(alice, true, 1 ether, 1 ether); // ask at price 1
        n = bound(n, 1, 2 ether); // new price <= 2: never level 3
        bytes32[5] memory b = _orderWords(poolId, otherId);
        vm.prank(alice);
        hook.updatePrice(o, n);
        bytes32[5] memory a = _orderWords(poolId, otherId);
        for (uint256 i; i < 5; ++i) {
            assertEq(a[i], b[i]);
        }
        assertTrue(id != otherId);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapUpdatePrice.lean:218 — every other pool (orders and book) is untouched.
    function testFuzz_midState_other_pool(uint256 n) public {
        PoolKey memory k2 = PoolKey({
            currency0: currency0, currency1: currency1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 2, hooks: hook
        });
        manager.initialize(k2, 2 ** 96);
        (, bytes32 id2) = _placeOrderOn(k2, alice, true, 1 ether, 1 ether);
        (AsyncOrder memory o,) = _placeOrderOn(key, alice, true, 2 ether, 1 ether);
        PoolId p2 = k2.toId();
        bytes32[5] memory b = _orderWords(p2, id2);
        bytes32 book = _bookWord0(p2);
        n = bound(n, 1, 1e30);
        vm.prank(alice);
        hook.updatePrice(o, n);
        bytes32[5] memory a = _orderWords(p2, id2);
        for (uint256 i; i < 5; ++i) {
            assertEq(a[i], b[i]);
        }
        assertEq(_bookWord0(p2), book);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapUpdatePrice.lean:223 — owner, pendingOwner, nonceUsed, the pool's manager, executors, openOrderCount and orderingMode are unchanged.
    function testFuzz_midState_frame(uint256 n, address someExec, uint256 nonce) public {
        hook.transferOwnership(bob);
        vm.prank(alice);
        hook.invalidateNonce(nonce);
        (AsyncOrder memory o, bytes32 id) = _placeOrder(alice, true, 1 ether, 1 ether);
        n = bound(n, 1, 1e30);
        bytes32 own = _loadHook(bytes32(OWNER_SLOT));
        bytes32 pend = _loadHook(bytes32(PENDING_OWNER_SLOT));
        bool exec = hook.isExecutor(poolId, alice, someExec);
        uint256 st = _stateSlot(poolId);
        bytes32 pm = _loadHook(bytes32(st));
        uint256 bw = uint256(_bookWord0(poolId)) >> 64; // openOrderCount | orderingMode
        vm.prank(alice);
        hook.updatePrice(o, n);
        assertEq(_loadHook(bytes32(OWNER_SLOT)), own);
        assertEq(_loadHook(bytes32(PENDING_OWNER_SLOT)), pend);
        assertTrue(hook.nonceUsed(alice, nonce));
        assertEq(hook.isExecutor(poolId, alice, someExec), exec);
        assertEq(_loadHook(bytes32(st)), pm, "poolManager");
        assertEq(uint256(_bookWord0(poolId)) >> 64, bw, "openOrderCount and orderingMode");
        assertGt(hook.asyncOrder(poolId, id), 0);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapUpdatePrice.lean:236 — a success was by order.owner, n != 0, on a live order, and leaves amountOutMin = n, price key in [1, 2^128), sequence = old nextSequence + 1, amountIn unchanged; no tokens move.
    function testFuzz_updatePrice_ok(
        address caller,
        bool asOwner,
        uint256 n,
        bool zeroForOne,
        uint256 amountIn,
        bool exists
    ) public {
        (AsyncOrder memory o, bytes32 id) = _live(zeroForOne, amountIn);
        if (!exists) o.salt = bytes32(uint256(o.salt) ^ 2);
        if (asOwner) caller = alice;
        uint256 stored = hook.asyncOrder(poolId, id);
        n = bound(n, 0, _maxN(!zeroForOne, stored));
        uint64 seq = _nextSequence(poolId);
        uint256 c0 = _claims(address(hook), currency0) + _claims(address(hook), currency1);
        vm.prank(caller);
        try hook.updatePrice(o, n) {
            assertEq(caller, alice, "sender = owner");
            assertTrue(n != 0);
            assertTrue(exists && stored != 0, "live order");
            (uint256 inA, uint256 out) = hook.asyncOrderInfo(poolId, id);
            assertEq(out, n);
            assertEq(inA, stored);
            assertGe(_price(id), 1);
            assertEq(_sequenceOf(poolId, id), seq + 1);
            assertEq(_claims(address(hook), currency0) + _claims(address(hook), currency1), c0, "no token moves");
        } catch {}
    }
}
