// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalSlotsB} from "./FormalSlotsB.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapAsyncOrder.lean`. The world is an arbitrary typed
///         `OrderInfo` record written into `asyncOrders[poolId].orders[orderId]`.
contract AsyncSwapAsyncOrderFormalTest is FormalSlotsB {
    function _call(address sender, bytes32 pid, bytes32 oid) internal returns (bool ok, bytes memory ret) {
        vm.prank(sender);
        (ok, ret) = address(hook).call(abi.encodeCall(AsyncSwap.asyncOrder, (PoolId.wrap(pid), oid)));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAsyncOrder.lean:20 — returns the stored amountIn, world untouched.
    function testFuzz_asyncOrder_run(address sender, bytes32 pid, bytes32 oid, AsyncFiller.OrderInfo memory o) public {
        _storeOrder(PoolId.wrap(pid), oid, o);
        vm.record();
        (bool ok, bytes memory ret) = _call(sender, pid, oid);
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint256)), o.amountIn);
        _assertNoHookWrites();
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAsyncOrder.lean:25 — never reverts.
    function testFuzz_asyncOrder_never_reverts(
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

    /// @notice formal/Refinement/Swarm/AsyncSwapAsyncOrder.lean:31 — ok (a, w') iff a = stored amountIn ∧ w' = w; also on
    ///         a real placed order.
    function testFuzz_asyncOrder_ok_iff(bytes32 pid, bytes32 oid, AsyncFiller.OrderInfo memory o, uint96 amountIn)
        public
    {
        _storeOrder(PoolId.wrap(pid), oid, o);
        vm.record();
        assertEq(hook.asyncOrder(PoolId.wrap(pid), oid), o.amountIn);
        _assertNoHookWrites();
        uint256 a = bound(amountIn, 2, 50 ether);
        (, bytes32 id) = _placeOrder(alice, true, a, a / 2);
        assertEq(hook.asyncOrder(poolId, id), uint256(_loadHook(_add(_orderSlot(poolId, id), 1))));
        assertEq(hook.asyncOrder(poolId, id), a);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAsyncOrder.lean:41 — the result depends only on asyncOrders (not other
    ///         storage, sender, chain or time).
    function testFuzz_asyncOrder_reads_only_asyncOrders(
        bytes32 pid,
        bytes32 oid,
        AsyncFiller.OrderInfo memory o,
        uint256 seed,
        address s1,
        address s2
    ) public {
        _storeOrder(PoolId.wrap(pid), oid, o);
        (, bytes memory r1) = _call(s1, pid, oid);
        _perturbOtherStorage(seed);
        vm.store(address(hook), _bookSlot(PoolId.wrap(pid)), bytes32(seed));
        vm.chainId(uint64(seed));
        vm.warp(seed % 2 ** 40);
        (, bytes memory r2) = _call(s2, pid, oid);
        assertEq(r1, r2);
    }
}
