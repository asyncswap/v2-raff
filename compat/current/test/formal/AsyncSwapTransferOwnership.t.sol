// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalSlotsB} from "./FormalSlotsB.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapTransferOwnership.lean`.
contract AsyncSwapTransferOwnershipFormalTest is FormalSlotsB {
    function _setOwnership(address o, address p) internal {
        vm.store(address(hook), bytes32(OWNER_SLOT), bytes32(uint256(uint160(o))));
        vm.store(address(hook), bytes32(PENDING_OWNER_SLOT), bytes32(uint256(uint160(p))));
    }

    function _call(address sender, address newOwner) internal returns (bool ok, bytes memory ret) {
        vm.prank(sender);
        (ok, ret) = address(hook).call(abi.encodeCall(AsyncSwap.transferOwnership, (newOwner)));
    }

    function _pendingOnly() internal pure returns (bytes32[] memory s) {
        s = new bytes32[](1);
        s[0] = bytes32(PENDING_OWNER_SLOT);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapTransferOwnership.lean:20 — NotOwner, then ZeroAddress, else exactly
    ///         `pendingOwner := newOwner`.
    function testFuzz_transferOwnership_run(
        address o,
        address p,
        address sender,
        address newOwner,
        bool isOwner,
        bool zero
    ) public {
        if (isOwner) sender = o;
        if (zero) newOwner = address(0);
        _setOwnership(o, p);
        vm.record();
        (bool ok, bytes memory ret) = _call(sender, newOwner);
        if (sender != o) {
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(AsyncSwap.NotOwner.selector));
            _assertNoHookWrites();
        } else if (newOwner == address(0)) {
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(AsyncSwap.ZeroAddress.selector));
            _assertNoHookWrites();
        } else {
            assertTrue(ok);
            _assertWritesWithin(_pendingOnly());
            assertEq(hook.pendingOwner(), newOwner);
            assertEq(hook.owner(), o);
            return;
        }
        assertEq(hook.owner(), o);
        assertEq(hook.pendingOwner(), p);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapTransferOwnership.lean:30 — non-owner callers revert NotOwner.
    function testFuzz_transferOwnership_notOwner(address o, address p, address sender, address newOwner) public {
        vm.assume(sender != o);
        _setOwnership(o, p);
        vm.prank(sender);
        vm.expectRevert(AsyncSwap.NotOwner.selector);
        hook.transferOwnership(newOwner);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapTransferOwnership.lean:36 — the owner passing address(0) reverts ZeroAddress.
    function testFuzz_transferOwnership_zero(address o, address p) public {
        _setOwnership(o, p);
        vm.prank(o);
        vm.expectRevert(AsyncSwap.ZeroAddress.selector);
        hook.transferOwnership(address(0));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapTransferOwnership.lean:43 — success iff sender = owner ∧ newOwner ≠ 0,
    ///         and then the only write is `pendingOwner := newOwner`.
    function testFuzz_transferOwnership_ok_iff(address o, address p, address sender, address newOwner, bool isOwner)
        public
    {
        if (isOwner) sender = o;
        _setOwnership(o, p);
        vm.record();
        (bool ok,) = _call(sender, newOwner);
        assertEq(ok, sender == o && newOwner != address(0));
        if (ok) {
            _assertWritesWithin(_pendingOnly());
            assertEq(hook.pendingOwner(), newOwner);
            assertEq(hook.owner(), o);
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapTransferOwnership.lean:52 — reverts iff sender ≠ owner ∨ newOwner = 0.
    function testFuzz_transferOwnership_reverts_iff(
        address o,
        address p,
        address sender,
        address newOwner,
        bool isOwner,
        bool zero
    ) public {
        if (isOwner) sender = o;
        if (zero) newOwner = address(0);
        _setOwnership(o, p);
        (bool ok,) = _call(sender, newOwner);
        assertEq(!ok, sender != o || newOwner == address(0));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapTransferOwnership.lean:61 — on success pendingOwner = newOwner and owner
    ///         (and every other field) is unchanged.
    function testFuzz_transferOwnership_ok_state(address o, address p, address sender, address newOwner, bool isOwner)
        public
    {
        if (isOwner) sender = o;
        _setOwnership(o, p);
        bytes32 book = _loadHook(_bookSlot(poolId));
        (bool ok,) = _call(sender, newOwner);
        if (ok) {
            assertEq(hook.pendingOwner(), newOwner);
            assertEq(hook.owner(), o);
            assertEq(_loadHook(_bookSlot(poolId)), book);
        }
    }
}
