// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalSlotsB} from "./FormalSlotsB.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapOrderBookOrder.lean`.
contract AsyncSwapOrderBookOrderFormalTest is FormalSlotsB {
    function _call(address sender, bytes32 pid, bytes32 oid) internal returns (bool ok, bytes memory ret) {
        vm.prank(sender);
        (ok, ret) = address(hook).call(abi.encodeCall(AsyncSwap.orderBookOrder, (PoolId.wrap(pid), oid)));
    }

    function _expected(AsyncFiller.OrderInfo memory o) internal pure returns (bytes memory) {
        return abi.encode(o.owner, o.amountIn, o.amountOutMin, o.price, o.isBuy, o.sequence, o.priorityFee);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapOrderBookOrder.lean:25 — returns (owner, amountIn, amountOutMin, price,
    ///         isBuy, previous, next) of the stored record, world unchanged.
    function testFuzz_orderBookOrder_run(address sender, bytes32 pid, bytes32 oid, AsyncFiller.OrderInfo memory o)
        public
    {
        _storeOrder(PoolId.wrap(pid), oid, o);
        vm.record();
        (bool ok, bytes memory ret) = _call(sender, pid, oid);
        assertTrue(ok);
        assertEq(ret, _expected(o));
        _assertNoHookWrites();
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapOrderBookOrder.lean:32 — never reverts.
    function testFuzz_orderBookOrder_never_reverts(
        address sender,
        bytes32 pid,
        bytes32 oid,
        AsyncFiller.OrderInfo memory o,
        bool set
    ) public {
        if (set) _storeOrder(PoolId.wrap(pid), oid, o);
        (bool ok,) = _call(sender, pid, oid);
        assertTrue(ok);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapOrderBookOrder.lean:37 — no storage is written (also on real orders).
    function testFuzz_orderBookOrder_readOnly(bytes32 pid, bytes32 oid, AsyncFiller.OrderInfo memory o) public {
        _storeOrder(PoolId.wrap(pid), oid, o);
        (, bytes32 id) = _placeOrder(alice, true, 1 ether, 0.9 ether);
        vm.record();
        hook.orderBookOrder(PoolId.wrap(pid), oid);
        hook.orderBookOrder(poolId, id);
        _assertNoHookWrites();
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapOrderBookOrder.lean:44 — the answer depends only on
    ///         asyncOrders[poolId].orders[orderId].
    function testFuzz_orderBookOrder_congr(
        bytes32 pid,
        bytes32 oid,
        bytes32 otherOid,
        AsyncFiller.OrderInfo memory o,
        AsyncFiller.OrderInfo memory other,
        uint256 seed,
        address s1,
        address s2
    ) public {
        vm.assume(otherOid != oid);
        _storeOrder(PoolId.wrap(pid), oid, o);
        (, bytes memory r1) = _call(s1, pid, oid);
        _perturbOtherStorage(seed);
        _storeOrder(PoolId.wrap(pid), otherOid, other);
        vm.store(address(hook), _stateSlot(PoolId.wrap(pid)), bytes32(seed)); // State.poolManager
        vm.chainId(uint64(seed));
        (, bytes memory r2) = _call(s2, pid, oid);
        assertEq(r1, r2);
    }
}
