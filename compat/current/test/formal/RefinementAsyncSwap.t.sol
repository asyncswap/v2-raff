// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalProbesA} from "./FormalProbesA.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice Bytecode checks of `formal/Refinement/AsyncSwap.lean` (`AsyncSwap.isExecutor` / `setExecutor`).
contract RefinementAsyncSwapFormalTest is FormalProbesA {
    /// @notice formal/Refinement/AsyncSwap.lean:49 — `isExecutor` never reverts, writes nothing, and returns
    ///         entry `(maker, executor)` of pool `poolId`'s executor table.
    function testFuzz_isExecutor_refines(bytes32 pid, address maker, address executor, bool stored, bool viaSetter)
        public
    {
        PoolId p = PoolId.wrap(pid);
        if (viaSetter) {
            vm.prank(maker);
            hook.setExecutor(p, executor, stored);
        } else {
            vm.store(address(hook), _execSlot(p, maker, executor), bytes32(uint256(stored ? 1 : 0)));
        }
        vm.record();
        bool got = hook.isExecutor(p, maker, executor);
        _assertNoWrites(address(hook));
        assertEq(got, stored, "isExecutor reads the table entry");
    }

    /// @notice formal/Refinement/AsyncSwap.lean:57 — `setExecutor` never reverts; its one effect is the
    ///         table write `isExecutor[msg.sender][executor] = allow` in pool `poolId`.
    function testFuzz_setExecutor_run(address sender, bytes32 pid, address executor, bool allow, bool prior) public {
        PoolId p = PoolId.wrap(pid);
        bytes32 slot = _execSlot(p, sender, executor);
        vm.store(address(hook), slot, bytes32(uint256(prior ? 1 : 0)));
        vm.record();
        vm.prank(sender);
        (bool ok,) = address(hook).call(abi.encodeCall(hook.setExecutor, (p, executor, allow)));
        assertTrue(ok, "setExecutor never reverts");
        (, bytes32[] memory writes) = vm.accesses(address(hook));
        for (uint256 i; i < writes.length; i++) {
            assertEq(writes[i], slot, "only the caller's table entry is written");
        }
        assertEq(uint256(vm.load(address(hook), slot)), allow ? 1 : 0, "entry := allow");
    }

    /// @notice formal/Refinement/AsyncSwap.lean:65 — after `setExecutor(poolId, executor, allow)` the pool's
    ///         table is the old one with `(msg.sender, executor)` set to `allow` (the spec's `setExecutor` step).
    function testFuzz_setExecutor_refines(
        address sender,
        address executor,
        bool allow,
        address m,
        address e,
        bool probeSender,
        bool probeExecutor
    ) public {
        if (probeSender) m = sender;
        if (probeExecutor) e = executor;
        bool before = hook.isExecutor(poolId, m, e);
        vm.prank(sender);
        hook.setExecutor(poolId, executor, allow);
        bool expected = (m == sender && e == executor) ? allow : before;
        assertEq(hook.isExecutor(poolId, m, e), expected, "table updated at (sender, executor) only");
    }

    /// @notice formal/Refinement/AsyncSwap.lean:81 — `setExecutor` leaves other pools, the pool's orders,
    ///         other makers' rows, price books, owner, pendingOwner and nonces unchanged.
    function testFuzz_setExecutor_frame(address sender, bytes32 pid, address executor, bool allow, bool samePool)
        public
    {
        (, bytes32 id) = _placeOrder(alice, true, 1 ether, 0.9 ether);
        PoolId p = samePool ? poolId : PoolId.wrap(pid);
        bool hitsAliceRow = sender == alice && PoolId.unwrap(p) == PoolId.unwrap(poolId) && executor == address(router);
        (uint256 inBefore, uint256 outBefore) = hook.asyncOrderInfo(poolId, id);
        bytes32[3] memory before = [_loadHook(bytes32(OWNER_SLOT)), _loadHook(bytes32(PENDING_OWNER_SLOT)), bytes32(0)];
        bool aliceRouter = hook.isExecutor(poolId, alice, address(router));

        vm.record();
        vm.prank(sender);
        hook.setExecutor(p, executor, allow);
        _assertOnlyWrite(_execSlot(p, sender, executor));

        (uint256 inAfter, uint256 outAfter) = hook.asyncOrderInfo(poolId, id);
        assertEq(inAfter, inBefore, "orders unchanged");
        assertEq(outAfter, outBefore, "orders unchanged");
        if (!hitsAliceRow) {
            assertEq(hook.isExecutor(poolId, alice, address(router)), aliceRouter, "other rows unchanged");
        }
        assertEq(_loadHook(bytes32(OWNER_SLOT)), before[0], "owner unchanged");
        assertEq(_loadHook(bytes32(PENDING_OWNER_SLOT)), before[1], "pendingOwner unchanged");
    }

    function _assertOnlyWrite(bytes32 slot) internal {
        (, bytes32[] memory writes) = vm.accesses(address(hook));
        for (uint256 i; i < writes.length; i++) {
            assertEq(writes[i], slot, "only the caller's entry of pool poolId is written");
        }
    }
}
