// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalSlotsB} from "./FormalSlotsB.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapAsyncOrderInfo.lean`.
contract AsyncSwapAsyncOrderInfoFormalTest is FormalSlotsB {
    function _call(address sender, bytes32 pid, bytes32 oid) internal returns (bool ok, bytes memory ret) {
        vm.prank(sender);
        (ok, ret) = address(hook).call(abi.encodeCall(AsyncSwap.asyncOrderInfo, (PoolId.wrap(pid), oid)));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAsyncOrderInfo.lean:21 — returns (amountIn, amountOutMin), world untouched.
    function testFuzz_asyncOrderInfo_run(address sender, bytes32 pid, bytes32 oid, AsyncFiller.OrderInfo memory o)
        public
    {
        _storeOrder(PoolId.wrap(pid), oid, o);
        vm.record();
        (bool ok, bytes memory ret) = _call(sender, pid, oid);
        assertTrue(ok);
        assertEq(ret, abi.encode(o.amountIn, o.amountOutMin));
        _assertNoHookWrites();
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAsyncOrderInfo.lean:27 — never reverts.
    function testFuzz_asyncOrderInfo_never_reverts(
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

    /// @notice formal/Refinement/Swarm/AsyncSwapAsyncOrderInfo.lean:33 — ok ((a, b), w') iff a, b are the stored legs
    ///         ∧ w' = w; also on a real placed order.
    function testFuzz_asyncOrderInfo_ok_iff(bytes32 pid, bytes32 oid, AsyncFiller.OrderInfo memory o, uint96 amountIn)
        public
    {
        _storeOrder(PoolId.wrap(pid), oid, o);
        vm.record();
        (uint256 a, uint256 b) = hook.asyncOrderInfo(PoolId.wrap(pid), oid);
        _assertNoHookWrites();
        assertEq(a, o.amountIn);
        assertEq(b, o.amountOutMin);
        uint256 amt = bound(amountIn, 2, 50 ether);
        (, bytes32 id) = _placeOrder(alice, true, amt, amt / 2);
        (a, b) = hook.asyncOrderInfo(poolId, id);
        assertEq(a, amt);
        assertEq(b, amt / 2);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAsyncOrderInfo.lean:44 — the result depends only on asyncOrders.
    function testFuzz_asyncOrderInfo_reads_only_asyncOrders(
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
        (, bytes memory r2) = _call(s2, pid, oid);
        assertEq(r1, r2);
    }
}
