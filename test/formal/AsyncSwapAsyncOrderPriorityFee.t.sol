// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {OrderInfo} from "./OrderInfo.sol";
import {FormalSlotsB} from "./FormalSlotsB.sol";
import {IAsyncSwap as AsyncSwap} from "src/interface/IAsyncSwap.sol";
import {IAsyncFiller as AsyncFiller} from "src/interface/IAsyncFiller.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapAsyncOrderPriorityFee.lean`.
contract AsyncSwapAsyncOrderPriorityFeeFormalTest is FormalSlotsB {
    function _call(address sender, bytes32 pid, bytes32 oid) internal returns (bool ok, bytes memory ret) {
        vm.prank(sender);
        (ok, ret) = address(hook).call(abi.encodeCall(AsyncSwap.asyncOrderPriorityFee, (PoolId.wrap(pid), oid)));
    }

    function _paid(OrderInfo memory o) internal pure returns (uint256) {
        return o.priorityFeeEscrowed ? o.priorityFee : 0;
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAsyncOrderPriorityFee.lean:21 — returns `escrowed ? priorityFee : 0`,
    ///         world untouched.
    function testFuzz_asyncOrderPriorityFee_run(
        address sender,
        bytes32 pid,
        bytes32 oid,
        OrderInfo memory o
    ) public {
        _storeOrder(PoolId.wrap(pid), oid, o);
        vm.record();
        (bool ok, bytes memory ret) = _call(sender, pid, oid);
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint256)), _paid(o));
        _assertNoHookWrites();
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAsyncOrderPriorityFee.lean:30 — never reverts.
    function testFuzz_asyncOrderPriorityFee_never_reverts(
        address sender,
        bytes32 pid,
        bytes32 oid,
        OrderInfo memory o,
        bool set
    ) public {
        if (set) _storeOrder(PoolId.wrap(pid), oid, o);
        (bool ok,) = _call(sender, pid, oid);
        assertTrue(ok);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAsyncOrderPriorityFee.lean:36 — ok (a, w') iff a = paid fee ∧ w' = w.
    function testFuzz_asyncOrderPriorityFee_ok_iff(bytes32 pid, bytes32 oid, OrderInfo memory o) public {
        _storeOrder(PoolId.wrap(pid), oid, o);
        vm.record();
        uint256 a = hook.asyncOrderPriorityFee(PoolId.wrap(pid), oid);
        _assertNoHookWrites();
        assertEq(a, _paid(o));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAsyncOrderPriorityFee.lean:46 — not escrowed ⇒ 0 (also a real FIFO order).
    function testFuzz_asyncOrderPriorityFee_not_escrowed(bytes32 pid, bytes32 oid, OrderInfo memory o)
        public
    {
        o.priorityFeeEscrowed = false;
        _storeOrder(PoolId.wrap(pid), oid, o);
        vm.record();
        assertEq(hook.asyncOrderPriorityFee(PoolId.wrap(pid), oid), 0);
        _assertNoHookWrites();
        (, bytes32 id) = _placeOrder(alice, true, 1 ether, 0.9 ether);
        assertEq(hook.asyncOrderPriorityFee(poolId, id), 0);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAsyncOrderPriorityFee.lean:52 — escrowed ⇒ the stored priorityFee (also a
    ///         real escrowed PriorityFee-mode order).
    function testFuzz_asyncOrderPriorityFee_escrowed(
        bytes32 pid,
        bytes32 oid,
        OrderInfo memory o,
        uint64 fee
    ) public {
        o.priorityFeeEscrowed = true;
        _storeOrder(PoolId.wrap(pid), oid, o);
        vm.record();
        assertEq(hook.asyncOrderPriorityFee(PoolId.wrap(pid), oid), o.priorityFee);
        _assertNoHookWrites();
        hook.setOrderingMode(key, AsyncFiller.OrderingMode.PriorityFee);
        uint256 f = bound(fee, 100_000, 10 ether);
        bytes32 id = _placePriorityOrder(alice, true, 1 ether, 0.9 ether, f);
        uint256 w7 = uint256(_orderWord(poolId, id, 7));
        uint256 w6 = uint256(_orderWord(poolId, id, 6));
        assertEq((w7 >> 128) & 0xff, 1, "real priority order is escrowed");
        assertEq(hook.asyncOrderPriorityFee(poolId, id), uint64(w6 >> 80));
        assertEq(hook.asyncOrderPriorityFee(poolId, id), f);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAsyncOrderPriorityFee.lean:59 — the result depends only on asyncOrders.
    function testFuzz_asyncOrderPriorityFee_reads_only_asyncOrders(
        bytes32 pid,
        bytes32 oid,
        OrderInfo memory o,
        uint256 seed,
        address s1,
        address s2
    ) public {
        _storeOrder(PoolId.wrap(pid), oid, o);
        (, bytes memory r1) = _call(s1, pid, oid);
        _perturbOtherStorage(seed);
        vm.store(address(hook), _bookSlot(PoolId.wrap(pid)), bytes32(seed));
        vm.chainId(uint64(seed));
        (, bytes memory r2) = _call(s2, pid, oid);
        assertEq(r1, r2);
    }
}
