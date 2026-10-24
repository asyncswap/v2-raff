// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalSlotsB} from "./FormalSlotsB.sol";
import {IAsyncSwap as AsyncSwap} from "src/interface/IAsyncSwap.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapOrderingMode.lean`. The stored mode ranges over the
///         enum's domain {0, 1} (see `test_note_orderingMode_outOfRangeStoredMode_panics` for other bytes).
contract AsyncSwapOrderingModeFormalTest is FormalSlotsB {
    function _setBook(PoolId pid, uint64 seq, uint64 open, bool mode) internal {
        vm.store(address(hook), _bookSlot(pid), _bookWord(seq, open, mode ? 1 : 0));
    }

    function _call(address sender, PoolId pid) internal returns (bool ok, bytes memory ret) {
        vm.prank(sender);
        (ok, ret) = address(hook).call(abi.encodeCall(AsyncSwap.orderingMode, (pid)));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapOrderingMode.lean:18 — returns priceBooks[poolId].orderingMode, world unchanged.
    function testFuzz_orderingMode_run(address sender, bytes32 pid, uint64 seq, uint64 open, bool mode) public {
        _setBook(PoolId.wrap(pid), seq, open, mode);
        vm.record();
        (bool ok, bytes memory ret) = _call(sender, PoolId.wrap(pid));
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint256)), mode ? 1 : 0);
        _assertNoHookWrites();
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapOrderingMode.lean:24 — never reverts.
    function testFuzz_orderingMode_never_reverts(
        address sender,
        bytes32 pid,
        uint64 seq,
        uint64 open,
        bool mode,
        bool setIt
    ) public {
        if (setIt) _setBook(PoolId.wrap(pid), seq, open, mode);
        (bool ok,) = _call(sender, PoolId.wrap(pid));
        assertTrue(ok);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapOrderingMode.lean:29 — writes nothing.
    function testFuzz_orderingMode_frame(bytes32 pid, uint64 seq, uint64 open, bool mode) public {
        _setBook(PoolId.wrap(pid), seq, open, mode);
        vm.record();
        hook.orderingMode(PoolId.wrap(pid));
        _assertNoHookWrites();
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapOrderingMode.lean:34 — the result is the stored ordering mode.
    function testFuzz_orderingMode_result(bytes32 pid, uint64 seq, uint64 open, bool mode) public {
        _setBook(PoolId.wrap(pid), seq, open, mode);
        assertEq(
            uint8(hook.orderingMode(PoolId.wrap(pid))), uint8(uint256(_loadHook(_bookSlot(PoolId.wrap(pid)))) >> 128)
        );
        assertEq(uint8(hook.orderingMode(PoolId.wrap(pid))), mode ? 1 : 0);
    }

    /// @notice Domain note (no theorem): the model's `orderingMode : Nat` admits any stored value, but the bytecode
    ///         ABI-encodes an enum and panics 0x21 on a stored byte ≥ 2. Unreachable: `setOrderingMode` decodes `mode`
    ///         as the enum, so storage only ever holds 0 or 1.
    function test_note_orderingMode_outOfRangeStoredMode_panics() public {
        vm.store(address(hook), _bookSlot(poolId), _bookWord(0, 0, 2));
        (bool ok, bytes memory ret) = address(hook).call(abi.encodeCall(AsyncSwap.orderingMode, (poolId)));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSignature("Panic(uint256)", 0x21));
    }
}
