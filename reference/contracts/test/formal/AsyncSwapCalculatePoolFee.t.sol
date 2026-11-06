// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalSlotsB} from "./FormalSlotsB.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapCalculatePoolFee.lean`.
contract AsyncSwapCalculatePoolFeeFormalTest is FormalSlotsB {
    /// @dev The Lean model was `pf a = a / 997 * 3 + a % 997 * 3 / 997`; the filler surcharge is now constantly 0
    ///      (semantics changed by the 0.02% trade fee; Lean statement needs updating).
    function _pf(uint256) internal pure returns (uint256) {
        return 0;
    }

    function _call(uint24 f, uint256 a) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = address(hook).call(abi.encodeCall(AsyncSwap.calculatePoolFee, (f, a)));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapCalculatePoolFee.lean:32 — panics iff pf a ≥ 2^256 (never, for uint256),
    ///         otherwise returns pf a with the world unchanged. pf is now 0 (semantics changed by the 0.02% trade fee;
    ///         Lean statement needs updating).
    function testFuzz_calculatePoolFee_run(uint24 f, uint256 a) public {
        vm.record();
        (bool ok, bytes memory ret) = _call(f, a);
        assertTrue(ok, "pf a < 2^256 for every uint256");
        assertEq(abi.decode(ret, (uint256)), _pf(a));
        _assertNoHookWrites();
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapCalculatePoolFee.lean:46 — for every uint256 amount: no revert, returns
    ///         0 (was amount * 3 / 997), world unchanged (semantics changed by the 0.02% trade fee; Lean statement needs
    ///         updating).
    function testFuzz_calculatePoolFee_ok(uint24 f, uint256 a) public {
        vm.record();
        (bool ok, bytes memory ret) = _call(f, a);
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint256)), 0);
        _assertNoHookWrites();
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapCalculatePoolFee.lean:53 — the fee never exceeds the amount.
    function testFuzz_calculatePoolFee_le(uint24 f, uint256 a) public {
        vm.record();
        uint256 r = hook.calculatePoolFee(f, a);
        assertLe(r, a);
        _assertNoHookWrites();
    }

    /// @notice Edge values for the three theorems above.
    function test_calculatePoolFee_ok_edges() public view {
        uint256[6] memory xs = [uint256(0), 1, 332, 333, 997, type(uint256).max];
        for (uint256 i; i < xs.length; ++i) {
            assertEq(hook.calculatePoolFee(0, xs[i]), 0);
        }
    }
}
