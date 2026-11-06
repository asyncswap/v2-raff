// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalRefA, RadixPriceTreeHarness} from "./FormalHarnessesA.sol";
import {RadixPriceTree} from "@async-swap/libraries/RadixPriceTree.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapMostSignificantBit.lean`. The private
///         `RadixPriceTree._mostSignificantBit(value)` is observed through the real `insert`: inserting a
///         second price into a one-leaf tree creates a branch whose `bit` is
///         `_mostSignificantBit(price ^ leafPrice)`. For `value = 0` the tree is a root leaf whose price has
///         no `leaves` entry (inserting that price again gives `differing = 0`).
contract AsyncSwapMostSignificantBitFormalTest is FormalRefA {
    RadixPriceTreeHarness h;

    function setUp() public {
        h = new RadixPriceTreeHarness();
    }

    /// @dev Runs `_mostSignificantBit(v)` inside `insert` and returns the bit it produced.
    function _msbViaInsert(uint128 a, uint128 v) internal returns (uint8) {
        if (v == 0) {
            // Root leaf holding `a`, with no `leaves[a]` entry.
            h.setNode(1, RadixPriceTree.Node({parent: 0, left: 0, right: 0, price: a, bit: 0, leaf: true}));
            h.setRoot(1);
            h.setNextNodeId(1);
        } else {
            assertTrue(h.insert(a));
        }
        assertTrue(h.insert(a ^ v), "insert succeeds");
        RadixPriceTree.Node memory branch = h.node(h.root());
        assertFalse(branch.leaf, "new root is the branch");
        return branch.bit;
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMostSignificantBit.lean:32 — never reverts and returns
    ///         msbSpec(value), which equals Nat.log2(value) for every uint128 (msbSpec_eq_log2).
    function testFuzz_mostSignificantBit_spec(uint128 a, uint128 v) public {
        assertEq(_msbViaInsert(a, v), _log2(v));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMostSignificantBit.lean:111 — never reverts and returns a value
    ///         below 128.
    function testFuzz_mostSignificantBit_noRevert(uint128 a, uint128 v) public {
        assertLt(_msbViaInsert(a, v), 128);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMostSignificantBit.lean:117 — for every uint128 value it
    ///         returns Nat.log2(value) (0 for 0).
    function testFuzz_mostSignificantBit_eq_log2(uint128 a, uint128 v) public {
        assertEq(_msbViaInsert(a, v), _log2(v));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMostSignificantBit.lean:123 — for a nonzero uint128 value the
    ///         result r satisfies 2^r <= value < 2^(r+1).
    function testFuzz_mostSignificantBit_bounds(uint128 a, uint128 v) public {
        vm.assume(v != 0);
        uint8 r = _msbViaInsert(a, v);
        assertLe(uint256(1) << r, v);
        assertLt(v, uint256(1) << (uint256(r) + 1));
    }
}
