// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalSlotsB} from "./FormalSlotsB.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapOrderBookLevel.lean`. The callee
///         `AsyncFiller.level` is opaque in the model; here it is the real linked code, which is a `view`
///         (satisfying the `Preserves` / `hlevel` hypotheses).
contract AsyncSwapOrderBookLevelFormalTest is FormalSlotsB {
    function _call(address sender, PoolId pid, bool isBuy, uint128 k) internal returns (bool ok, bytes memory ret) {
        vm.prank(sender);
        (ok, ret) = address(hook).call(abi.encodeCall(AsyncSwap.orderBookLevel, (pid, isBuy, k)));
    }

    /// @dev A price key to query: a live order's own price (when `pick`) or an arbitrary key.
    function _priceKey(bytes32[] memory ids, uint256 sel, bool pick, uint128 k) internal view returns (uint128, bool) {
        if (!pick || ids.length == 0) return (k, sel % 2 == 0);
        bytes32 s = _orderSlot(poolId, ids[sel % ids.length]);
        return (uint128(uint256(_loadHook(_add(s, 3)))), uint8(uint256(_loadHook(_add(s, 3))) >> 128) == 1);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapOrderBookLevel.lean:63 — the callee is read-only, so the call leaves the
    ///         world unchanged (FIFO and PriorityFee books, live and arbitrary price keys).
    function testFuzz_orderBookLevel_readOnly(
        uint256 seed,
        bool priority,
        bool populated,
        uint256 sel,
        bool pick,
        uint128 k
    ) public {
        bytes32[] memory ids;
        if (populated) ids = _populate(seed, priority);
        (uint128 price, bool isBuy) = _priceKey(ids, sel, pick, k);
        vm.record();
        (bool ok,) = _call(address(this), poolId, isBuy, price);
        assertTrue(ok);
        _assertNoHookWrites();
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapOrderBookLevel.lean:73 — returns F(priceBooks[poolId], isBuy, priceKey),
    ///         never reverting, state unchanged. In FIFO mode F reads the stored level (head, tail, orderCount).
    function testFuzz_orderBookLevel_view(
        uint256 seed,
        bool priority,
        bool populated,
        uint256 sel,
        bool pick,
        uint128 k,
        address sender
    ) public {
        bytes32[] memory ids;
        if (populated) ids = _populate(seed, priority);
        (uint128 price, bool isBuy) = _priceKey(ids, sel, pick, k);
        vm.record();
        (bool ok, bytes memory ret) = _call(sender, poolId, isBuy, price);
        assertTrue(ok, "never reverts");
        _assertNoHookWrites();
        (bytes32 head, bytes32 tail, uint32 count) = abi.decode(ret, (bytes32, bytes32, uint32));
        bytes32 lvl = _levelSlot(poolId, isBuy, price);
        assertEq(count, uint32(uint256(_loadHook(lvl))));
        if (count == 0) {
            assertEq(head, bytes32(0));
            assertEq(tail, bytes32(0));
        }
        if (populated && pick) assertGe(count, 1, "live level");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapOrderBookLevel.lean:86 — the answer depends only on priceBooks[poolId].
    function testFuzz_orderBookLevel_congr(
        uint256 seed,
        bool priority,
        uint256 sel,
        bool pick,
        uint128 k,
        address s1,
        address s2,
        uint256 junk
    ) public {
        bytes32[] memory ids = _populate(seed, priority);
        (uint128 price, bool isBuy) = _priceKey(ids, sel, pick, k);
        (, bytes memory r1) = _call(s1, poolId, isBuy, price);
        // Change everything except priceBooks[poolId]: asyncOrders (records of the live orders), ownership, nonces,
        // another pool's book, and the environment.
        for (uint256 i; i < ids.length; ++i) {
            vm.store(address(hook), _orderSlot(poolId, ids[i]), bytes32(junk));
            vm.store(address(hook), _add(_orderSlot(poolId, ids[i]), 1), bytes32(junk));
        }
        vm.store(address(hook), bytes32(OWNER_SLOT), bytes32(junk));
        vm.store(address(hook), _nonceSlot(alice, junk), bytes32(uint256(1)));
        vm.store(address(hook), _bookSlot(PoolId.wrap(bytes32(junk))), bytes32(junk));
        vm.chainId(uint64(junk));
        vm.warp(junk % 2 ** 40);
        (, bytes memory r2) = _call(s2, poolId, isBuy, price);
        assertEq(r1, r2);
    }
}
