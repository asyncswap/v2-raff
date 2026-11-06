// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalSlotsB} from "./FormalSlotsB.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapOnlyOwner.lean`. The modifier is exercised
///         through every `onlyOwner` entry point: `transferOwnership`, `sweep`.
contract AsyncSwapOnlyOwnerFormalTest is FormalSlotsB {
    function _setOwner(address o) internal {
        vm.store(address(hook), bytes32(OWNER_SLOT), bytes32(uint256(uint160(o))));
    }

    /// @dev Calldata for gated entry point `which % 2` with fuzzed body arguments.
    function _gated(uint8 which, address arg, bool) internal view returns (bytes memory) {
        if (which % 2 == 0) return abi.encodeCall(AsyncSwap.transferOwnership, (arg));
        return abi.encodeCall(AsyncSwap.sweep, (currency0, arg));
    }

    /// @dev The body's own outcome when run by the owner (what `k env w` evaluates to): `ZeroAddress` for
    ///      a zero target in transferOwnership/sweep, success otherwise.
    function _bodyReverts(uint8 which, address arg) internal pure returns (bool, bytes4) {
        if (arg == address(0)) return (true, AsyncSwap.ZeroAddress.selector);
        return (false, bytes4(0));
    }

    function _call(address sender, bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.prank(sender);
        (ok, ret) = address(hook).call(data);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapOnlyOwner.lean:20 — non-owner: reverts NotOwner whatever the body,
    ///         without writing storage.
    function testFuzz_onlyOwner_notOwner(address o, address sender, uint8 which, address arg, bool mode) public {
        vm.assume(sender != o);
        _setOwner(o);
        token0.mint(address(hook), 1 ether);
        vm.record();
        (bool ok, bytes memory ret) = _call(sender, _gated(which, arg, mode));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(AsyncSwap.NotOwner.selector));
        _assertNoHookWrites();
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapOnlyOwner.lean:25 — owner: the call is exactly the body.
    function testFuzz_onlyOwner_owner(address o, uint8 which, address arg, bool mode) public {
        vm.assume(o != address(0));
        _setOwner(o);
        (bool bodyReverts, bytes4 err) = _bodyReverts(which, arg);
        (bool ok, bytes memory ret) = _call(o, _gated(which, arg, mode));
        if (bodyReverts) {
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(err));
        } else {
            assertTrue(ok, "owner runs the body");
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapOnlyOwner.lean:32 — `if sender = owner then body else NotOwner`.
    function testFuzz_onlyOwner_run(address o, address sender, bool isOwner, uint8 which, address arg, bool mode)
        public
    {
        if (isOwner) sender = o;
        _setOwner(o);
        (bool ok, bytes memory ret) = _call(sender, _gated(which, arg, mode));
        if (sender != o) {
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(AsyncSwap.NotOwner.selector));
        } else {
            (bool bodyReverts, bytes4 err) = _bodyReverts(which, arg);
            assertEq(ok, !bodyReverts);
            if (bodyReverts) assertEq(ret, abi.encodeWithSelector(err));
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapOnlyOwner.lean:40 — for bodies that never revert NotOwner, the call
    ///         reverts with NotOwner iff sender ≠ owner.
    function testFuzz_onlyOwner_reverts_NotOwner_iff(
        address o,
        address sender,
        bool isOwner,
        uint8 which,
        address arg,
        bool mode
    ) public {
        if (isOwner) sender = o;
        _setOwner(o);
        (bool ok, bytes memory ret) = _call(sender, _gated(which, arg, mode));
        bool notOwner = !ok && keccak256(ret) == keccak256(abi.encodeWithSelector(AsyncSwap.NotOwner.selector));
        assertEq(notOwner, sender != o);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapOnlyOwner.lean:47 — on success the sender is the owner (and the
    ///         final state is the body's).
    function testFuzz_onlyOwner_ok(address o, address sender, bool isOwner, uint8 which, address arg, bool mode)
        public
    {
        if (isOwner) sender = o;
        _setOwner(o);
        (bool ok,) = _call(sender, _gated(which, arg, mode));
        if (ok) assertEq(sender, o);
    }
}
