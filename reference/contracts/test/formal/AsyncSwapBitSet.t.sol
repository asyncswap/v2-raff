// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalRefA, RadixPriceTreeHarness} from "./FormalHarnessesA.sol";
import {RadixPriceTree} from "@async-swap/libraries/RadixPriceTree.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapBitSet.lean`. The private
///         `RadixPriceTree._bitSet(value, bit)` is observed through the real `insert`: the tree is a root
///         branch (id 1) with `bit = b`, left leaf `p ^ 1` (id 2) and right leaf `p ^ 2` (id 3). Inserting
///         `p` walks right iff `_bitSet(p, b)`, so the new branch's `bit` is `msb(p ^ leaf)`: 1 after a
///         right turn, 0 after a left turn. `b` ranges over all of `uint8`, including `b >= 128`.
contract AsyncSwapBitSetFormalTest is FormalRefA {
    RadixPriceTreeHarness h;

    function setUp() public {
        h = new RadixPriceTreeHarness();
    }

    /// @dev Runs `_bitSet(p, b)` in `insert`'s first walk and returns the direction it took.
    function _bitSetViaInsert(uint128 p, uint8 b) internal returns (bool) {
        h.setNode(1, RadixPriceTree.Node({parent: 0, left: 2, right: 3, price: 0, bit: b, leaf: false}));
        h.setNode(2, RadixPriceTree.Node({parent: 1, left: 0, right: 0, price: p ^ 1, bit: 0, leaf: true}));
        h.setNode(3, RadixPriceTree.Node({parent: 1, left: 0, right: 0, price: p ^ 2, bit: 0, leaf: true}));
        h.setLeaf(p ^ 1, 2);
        h.setLeaf(p ^ 2, 3);
        h.setRoot(1);
        h.setNextNodeId(3);
        assertTrue(h.insert(p), "insert succeeds");
        // Ids 4 (leaf) and 5 (branch) are the new nodes.
        assertTrue(h.node(4).leaf);
        RadixPriceTree.Node memory added = h.node(5);
        assertFalse(added.leaf);
        assertTrue(added.bit <= 1);
        return added.bit == 1;
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBitSet.lean:20 — never reverts and returns
    ///         (value & ((1 << bit) mod 2^128)) != 0.
    function testFuzz_bitSet_spec(uint128 p, uint8 b) public {
        uint128 mask;
        unchecked {
            mask = uint128((uint256(1) << b) % (uint256(1) << 128));
        }
        assertEq(_bitSetViaInsert(p, b), (p & mask) != 0);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBitSet.lean:25 — returns true iff bit < 128 and bit `bit` of
    ///         value is set.
    function testFuzz_bitSet_testBit(uint128 p, uint8 b) public {
        assertEq(_bitSetViaInsert(p, b), b < 128 && (uint256(p) >> b) & 1 == 1);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBitSet.lean:41 — it never reverts.
    function testFuzz_bitSet_noRevert(uint128 p, uint8 b) public {
        _bitSetViaInsert(p, b);
    }
}
