// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalSlotsB} from "./FormalSlotsB.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapReceive.lean`. Transient storage of the hook is read
///         and seeded by temporarily etching a TLOAD/TSTORE probe at the hook address (code restored afterwards;
///         transient storage is per account and survives the etch within the test transaction).
contract AsyncSwapReceiveFormalTest is FormalSlotsB {
    function _send(address sender, uint256 value) internal returns (bool ok, bytes memory ret) {
        vm.deal(sender, value);
        vm.prank(sender);
        (ok, ret) = address(hook).call{value: value}("");
    }

    function _yadd(uint256 a, uint256 b) internal pure returns (uint256 r) {
        unchecked {
            r = a + b;
        }
    }

    function test_probe_roundTrip() public oneTx {
        _tstore(address(hook), PENDING_NATIVE_DEPOSIT, 42);
        assertEq(_tload(address(hook), PENDING_NATIVE_DEPOSIT), 42);
        assertEq(hook.owner(), address(this), "code restored");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapReceive.lean:32 — always succeeds, returns (), ledger := pending + value
    ///         (mod 2^256).
    function testFuzz_receive_run(address sender, uint256 pending, uint256 value) public oneTx {
        _tstore(address(hook), PENDING_NATIVE_DEPOSIT, pending);
        (bool ok, bytes memory ret) = _send(sender, value);
        assertTrue(ok);
        assertEq(ret.length, 0);
        assertEq(_tload(address(hook), PENDING_NATIVE_DEPOSIT), _yadd(pending, value));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapReceive.lean:37 — never reverts.
    function testFuzz_receive_never_reverts(address sender, uint256 pending, uint256 value, bool seed) public {
        if (seed) _tstore(address(hook), PENDING_NATIVE_DEPOSIT, pending);
        (bool ok,) = _send(sender, value);
        assertTrue(ok);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapReceive.lean:42 — any success is exactly the ledger bump (two in a row
    ///         accumulate).
    function testFuzz_receive_ok(address sender, uint256 pending, uint256 v1, uint256 v2) public oneTx {
        _tstore(address(hook), PENDING_NATIVE_DEPOSIT, pending);
        (bool ok,) = _send(sender, v1);
        if (ok) assertEq(_tload(address(hook), PENDING_NATIVE_DEPOSIT), _yadd(pending, v1));
        (ok,) = _send(sender, v2);
        if (ok) assertEq(_tload(address(hook), PENDING_NATIVE_DEPOSIT), _yadd(_yadd(pending, v1), v2));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapReceive.lean:50 — ledger := (pending + value) mod 2^256; every storage
    ///         field and every other transient slot unchanged.
    function testFuzz_receive_frame(address sender, uint256 pending, uint256 value, bytes32 k, uint256 kv)
        public
        oneTx
    {
        vm.assume(k != PENDING_NATIVE_DEPOSIT);
        _placeOrder(alice, true, 1 ether, 0.9 ether); // non-trivial asyncOrders / priceBooks
        _tstore(address(hook), PENDING_NATIVE_DEPOSIT, pending);
        _tstore(address(hook), k, kv);
        uint256 matchId = _tload(address(hook), PENDING_MATCH_ID);
        address o = hook.owner();
        address p = hook.pendingOwner();
        bytes32 book = _loadHook(_bookSlot(poolId));
        vm.record();
        (bool ok,) = _send(sender, value);
        assertTrue(ok);
        _assertNoHookWrites();
        assertEq(_tload(address(hook), PENDING_NATIVE_DEPOSIT), _yadd(pending, value));
        assertEq(_tload(address(hook), k), kv, "other transient slot");
        if (k != PENDING_MATCH_ID) assertEq(_tload(address(hook), PENDING_MATCH_ID), matchId);
        assertEq(hook.owner(), o);
        assertEq(hook.pendingOwner(), p);
        assertEq(_loadHook(_bookSlot(poolId)), book);
    }
}
