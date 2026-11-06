// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalSlotsB} from "./FormalSlotsB.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapAcceptOwnership.lean`.
contract AsyncSwapAcceptOwnershipFormalTest is FormalSlotsB {
    /// @dev Put the hook in an arbitrary ownership state `w` (owner, pendingOwner).
    function _setOwnership(address o, address p) internal {
        vm.store(address(hook), bytes32(OWNER_SLOT), bytes32(uint256(uint160(o))));
        vm.store(address(hook), bytes32(PENDING_OWNER_SLOT), bytes32(uint256(uint160(p))));
    }

    function _call(address sender) internal returns (bool ok, bytes memory ret) {
        vm.prank(sender);
        (ok, ret) = address(hook).call(abi.encodeCall(AsyncSwap.acceptOwnership, ()));
    }

    function _writeSet() internal pure returns (bytes32[] memory s) {
        s = new bytes32[](2);
        s[0] = bytes32(OWNER_SLOT);
        s[1] = bytes32(PENDING_OWNER_SLOT);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAcceptOwnership.lean:20 — sender ≠ pendingOwner ⇒ NotOwner,
    ///         else exactly `owner := sender` then `pendingOwner := 0`.
    function testFuzz_acceptOwnership_run(address o, address p, address sender, bool senderIsPending) public {
        if (senderIsPending) sender = p;
        _setOwnership(o, p);
        vm.record();
        (bool ok, bytes memory ret) = _call(sender);
        if (sender != p) {
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(AsyncSwap.NotOwner.selector));
            _assertNoHookWrites();
            assertEq(hook.owner(), o);
            assertEq(hook.pendingOwner(), p);
        } else {
            assertTrue(ok);
            _assertWritesWithin(_writeSet());
            assertEq(hook.owner(), sender);
            assertEq(hook.pendingOwner(), address(0));
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAcceptOwnership.lean:30 — callers other than pendingOwner revert NotOwner.
    function testFuzz_acceptOwnership_notPending(address o, address p, address sender) public {
        vm.assume(sender != p);
        _setOwnership(o, p);
        vm.prank(sender);
        vm.expectRevert(AsyncSwap.NotOwner.selector);
        hook.acceptOwnership();
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAcceptOwnership.lean:36 — reverts (any reason) iff sender ≠ pendingOwner.
    function testFuzz_acceptOwnership_reverts_iff(address o, address p, address sender, bool senderIsPending) public {
        if (senderIsPending) sender = p;
        _setOwnership(o, p);
        (bool ok,) = _call(sender);
        assertEq(!ok, sender != p);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAcceptOwnership.lean:45 — success iff sender = pendingOwner, and the
    ///         result is the single update `owner := sender, pendingOwner := 0`, all else unchanged.
    function testFuzz_acceptOwnership_ok_iff(address o, address p, address sender, bool senderIsPending) public {
        if (senderIsPending) sender = p;
        _setOwnership(o, p);
        vm.store(address(hook), _nonceSlot(sender, 7), bytes32(uint256(1)));
        bytes32 book = _loadHook(_bookSlot(poolId));
        vm.record();
        (bool ok,) = _call(sender);
        assertEq(ok, sender == p, "ok iff sender = pendingOwner");
        if (ok) {
            _assertWritesWithin(_writeSet());
            assertEq(hook.owner(), sender);
            assertEq(hook.pendingOwner(), address(0));
            assertTrue(hook.nonceUsed(sender, 7), "other fields unchanged");
            assertEq(_loadHook(_bookSlot(poolId)), book, "other fields unchanged");
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAcceptOwnership.lean:56 — on success sender was pendingOwner, and now
    ///         owner = sender, pendingOwner = 0.
    function testFuzz_acceptOwnership_ok_state(address o, address p, address sender, bool senderIsPending) public {
        if (senderIsPending) sender = p;
        _setOwnership(o, p);
        (bool ok,) = _call(sender);
        if (ok) {
            assertEq(sender, p);
            assertEq(hook.owner(), sender);
            assertEq(hook.pendingOwner(), address(0));
        }
    }
}
