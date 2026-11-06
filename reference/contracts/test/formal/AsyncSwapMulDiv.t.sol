// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalRefA, MathMulDivHarness} from "./FormalHarnessesA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapMulDiv.lean`: OpenZeppelin's `Math.mulDiv`
///         (v5.0, the copy AsyncSwap links), called through a harness. Expected values come from a
///         schoolbook 512-bit product, not from OpenZeppelin's algorithm.
contract AsyncSwapMulDivFormalTest is FormalRefA {
    MathMulDivHarness h;

    function setUp() public {
        h = new MathMulDivHarness();
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMulDiv.lean:258 — for d != 0 whose quotient fits 256 bits,
    ///         mulDiv returns exactly floor(x * y / d).
    function testFuzz_mulDiv_ok(uint256 x, uint256 y, uint256 d) public view {
        vm.assume(d != 0 && _quotientFits(x, y, d));
        uint256 r = h.mulDiv(x, y, d);
        assertTrue(_isFloorQuotient(r, x, y, d), "floor(x*y/d)");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMulDiv.lean:306 — for d != 0 whose quotient does not fit,
    ///         mulDiv reverts MathOverflowedMulDiv.
    function testFuzz_mulDiv_overflow(uint256 x, uint256 y, uint256 d) public {
        vm.assume(d != 0 && !_quotientFits(x, y, d));
        vm.expectRevert(Math.MathOverflowedMulDiv.selector);
        h.mulDiv(x, y, d);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMulDiv.lean:321 — d = 0 reverts: panic 0x12 when x * y < 2^256,
    ///         MathOverflowedMulDiv otherwise.
    function testFuzz_mulDiv_zero(uint256 x, uint256 y) public {
        (uint256 hi,) = _mul512(x, y);
        if (hi == 0) vm.expectRevert(_panic(0x12));
        else vm.expectRevert(Math.MathOverflowedMulDiv.selector);
        h.mulDiv(x, y, 0);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMulDiv.lean:338 — complete spec over all 256-bit inputs:
    ///         d = 0 reverts (0x12 / overflow), a fitting quotient is returned, otherwise MathOverflowedMulDiv.
    function testFuzz_mulDiv_spec(uint256 x, uint256 y, uint256 d, bool zeroD) public {
        if (zeroD) d = 0;
        (uint256 hi,) = _mul512(x, y);
        if (d == 0) {
            if (hi == 0) vm.expectRevert(_panic(0x12));
            else vm.expectRevert(Math.MathOverflowedMulDiv.selector);
            h.mulDiv(x, y, d);
        } else if (hi < d) {
            assertTrue(_isFloorQuotient(h.mulDiv(x, y, d), x, y, d), "floor(x*y/d)");
        } else {
            vm.expectRevert(Math.MathOverflowedMulDiv.selector);
            h.mulDiv(x, y, d);
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMulDiv.lean:381 — for d != 0, mulDiv behaves as the prelude's
    ///         mulDivFloor: the floor quotient when it fits, MathOverflowedMulDiv otherwise.
    function testFuzz_mulDiv_eq_mulDivFloor(uint256 x, uint256 y, uint256 d) public {
        vm.assume(d != 0);
        if (_quotientFits(x, y, d)) {
            assertTrue(_isFloorQuotient(h.mulDiv(x, y, d), x, y, d), "floor(x*y/d)");
        } else {
            vm.expectRevert(Math.MathOverflowedMulDiv.selector);
            h.mulDiv(x, y, d);
        }
    }
}
