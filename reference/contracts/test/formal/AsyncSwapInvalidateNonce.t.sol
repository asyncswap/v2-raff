// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalSlotsB} from "./FormalSlotsB.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapInvalidateNonce.lean`.
contract AsyncSwapInvalidateNonceFormalTest is FormalSlotsB {
    function _setUsed(address maker, uint256 nonce, bool used) internal {
        vm.store(address(hook), _nonceSlot(maker, nonce), bytes32(uint256(used ? 1 : 0)));
    }

    function _call(address sender, uint256 nonce) internal returns (bool ok, bytes memory ret) {
        vm.prank(sender);
        (ok, ret) = address(hook).call(abi.encodeCall(AsyncSwap.invalidateNonce, (nonce)));
    }

    function _one(bytes32 s) internal pure returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = s;
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapInvalidateNonce.lean:20 — NonceAlreadyUsed if set, else exactly
    ///         `nonceUsed[sender][nonce] := true`.
    function testFuzz_invalidateNonce_run(address sender, uint256 nonce, bool used) public {
        _setUsed(sender, nonce, used);
        vm.record();
        (bool ok, bytes memory ret) = _call(sender, nonce);
        if (used) {
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(AsyncSwap.NonceAlreadyUsed.selector));
            _assertNoHookWrites();
        } else {
            assertTrue(ok);
            _assertWritesWithin(_one(_nonceSlot(sender, nonce)));
        }
        assertTrue(hook.nonceUsed(sender, nonce));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapInvalidateNonce.lean:31 — reverts iff the nonce is already used.
    function testFuzz_invalidateNonce_reverts_iff(address sender, uint256 nonce, bool used) public {
        _setUsed(sender, nonce, used);
        (bool ok,) = _call(sender, nonce);
        assertEq(!ok, used);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapInvalidateNonce.lean:38 — a used nonce reverts NonceAlreadyUsed.
    function testFuzz_invalidateNonce_used(address sender, uint256 nonce) public {
        _setUsed(sender, nonce, true);
        vm.prank(sender);
        vm.expectRevert(AsyncSwap.NonceAlreadyUsed.selector);
        hook.invalidateNonce(nonce);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapInvalidateNonce.lean:44 — succeeds iff the nonce is unused.
    function testFuzz_invalidateNonce_ok_iff(address sender, uint256 nonce, bool used) public {
        _setUsed(sender, nonce, used);
        (bool ok,) = _call(sender, nonce);
        assertEq(ok, !used);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapInvalidateNonce.lean:52 — on success the entry was unused and is now
    ///         used; every other (maker, n) entry and every other field is unchanged.
    function testFuzz_invalidateNonce_ok_state(
        address sender,
        uint256 nonce,
        uint256 otherNonce,
        address otherMaker,
        bool otherUsed
    ) public {
        vm.assume(otherNonce != nonce);
        vm.assume(otherMaker != sender);
        _setUsed(sender, otherNonce, otherUsed);
        _setUsed(otherMaker, nonce, otherUsed);
        address o = hook.owner();
        bytes32 book = _loadHook(_bookSlot(poolId));
        bool before = hook.nonceUsed(sender, nonce);
        vm.record();
        (bool ok,) = _call(sender, nonce);
        if (ok) {
            assertFalse(before);
            assertTrue(hook.nonceUsed(sender, nonce));
            assertEq(hook.nonceUsed(sender, otherNonce), otherUsed, "same maker, other nonce");
            assertEq(hook.nonceUsed(otherMaker, nonce), otherUsed, "other maker, same nonce");
            assertEq(hook.owner(), o);
            assertEq(_loadHook(_bookSlot(poolId)), book);
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapInvalidateNonce.lean:75 — another maker's row is untouched on success.
    function testFuzz_invalidateNonce_other_maker(address sender, uint256 nonce, address maker, uint256 n, bool used)
        public
    {
        vm.assume(maker != sender);
        _setUsed(maker, nonce, !used);
        _setUsed(maker, n, used);
        (bool ok,) = _call(sender, nonce);
        assertTrue(ok);
        assertEq(hook.nonceUsed(maker, n), used);
        assertEq(hook.nonceUsed(maker, nonce), n == nonce ? used : !used);
    }
}
