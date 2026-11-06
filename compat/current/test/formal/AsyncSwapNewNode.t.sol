// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalRefA, RadixPriceTreeHarness} from "./FormalHarnessesA.sol";
import {RadixPriceTree} from "@async-swap/libraries/RadixPriceTree.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapNewNode.lean`. The private
///         `RadixPriceTree._newNode()` is observed through the real `insert` into an empty tree
///         (`root = 0`), which calls `_newNode` once and then writes only `root := id`,
///         `nodes[id].price`, `nodes[id].leaf` and `leaves[price] := id`. The free list and `nextNodeId`
///         are set to fuzzed values first.
contract AsyncSwapNewNodeFormalTest is FormalRefA {
    RadixPriceTreeHarness h;

    function setUp() public {
        h = new RadixPriceTreeHarness();
    }

    function _setState(uint32[] memory free, uint32 next) internal {
        h.setFreeIds(free);
        h.setNextNodeId(next);
    }

    function _assertFreeIds(uint32[] memory expected) internal view {
        uint32[] memory got = h.freeIds();
        assertEq(got.length, expected.length, "freeIds length");
        for (uint256 i; i < got.length; ++i) {
            assertEq(got[i], expected[i], "freeIds entry");
        }
    }

    function _dropLast(uint32[] memory a) internal pure returns (uint32[] memory b) {
        b = new uint32[](a.length - 1);
        for (uint256 i; i < b.length; ++i) {
            b[i] = a[i];
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapNewNode.lean:23 — with a non-empty free list it returns the
    ///         last free id and only drops it from the list.
    function testFuzz_newNode_run_free(uint32[] memory free, uint32 next, uint128 price) public {
        vm.assume(free.length != 0);
        _setState(free, next);
        assertTrue(h.insert(price));
        assertEq(h.root(), free[free.length - 1], "returned id = last free id");
        assertEq(h.leaf(price), free[free.length - 1]);
        _assertFreeIds(_dropLast(free));
        assertEq(h.nextNodeId(), next, "nextNodeId unchanged");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapNewNode.lean:36 — with an empty free list it sets and returns
    ///         nextNodeId := uint32(nextNodeId + 1), reverting NodeIdOverflow iff that wraps to 0.
    function testFuzz_newNode_run_fresh(uint32 next, uint128 price, bool atMax) public {
        if (atMax) next = type(uint32).max;
        _setState(new uint32[](0), next);
        uint32 id;
        unchecked {
            id = next + 1;
        }
        if (id == 0) {
            vm.expectRevert(RadixPriceTree.NodeIdOverflow.selector);
            h.insert(price);
            return;
        }
        assertTrue(h.insert(price));
        assertEq(h.root(), id, "returned id");
        assertEq(h.nextNodeId(), id, "nextNodeId := id");
        assertEq(h.freeIds().length, 0);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapNewNode.lean:46 — reverts iff the free list is empty and
    ///         uint32(nextNodeId + 1) = 0.
    function testFuzz_newNode_reverts_iff(uint32[] memory free, uint32 next, uint128 price, bool atMax, bool noFree)
        public
    {
        if (atMax) next = type(uint32).max;
        if (noFree) free = new uint32[](0);
        _setState(free, next);
        bool expectRevert = free.length == 0 && next == type(uint32).max;
        (bool ok, bytes memory ret) = address(h).call(abi.encodeCall(h.insert, (price)));
        assertEq(!ok, expectRevert, "reverts iff no free id and the counter wraps");
        if (!ok) assertEq(ret, abi.encodeWithSelector(RadixPriceTree.NodeIdOverflow.selector));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapNewNode.lean:60 — on success only freeIds / nextNodeId change
    ///         (pop the last free id, or bump the counter to a nonzero id); root, nodes and leaves are left
    ///         to the caller (here: insert's own writes are the only other changes).
    function testFuzz_newNode_footprint(
        uint32[] memory free,
        uint32 next,
        uint128 price,
        uint128 otherPrice,
        uint32 otherLeaf,
        RadixPriceTree.Node memory pre,
        bool noFree
    ) public {
        if (noFree) free = new uint32[](0);
        vm.assume(price != otherPrice);
        _setState(free, next);
        uint32 expectedId;
        unchecked {
            expectedId = free.length != 0 ? free[free.length - 1] : next + 1;
        }
        vm.assume(free.length != 0 || expectedId != 0);
        // Pre-existing contents at the id `_newNode` will hand out, and an unrelated node and leaf entry.
        h.setNode(expectedId, pre);
        RadixPriceTree.Node memory unrelated =
            RadixPriceTree.Node({parent: 7, left: 8, right: 9, price: 10, bit: 11, leaf: true});
        uint32 unrelatedId;
        unchecked {
            unrelatedId = expectedId + 1;
        }
        h.setNode(unrelatedId, unrelated);
        h.setLeaf(otherPrice, otherLeaf);

        assertTrue(h.insert(price));
        uint32 id = h.root();
        assertEq(id, expectedId, "id");
        if (free.length != 0) {
            _assertFreeIds(_dropLast(free));
            assertEq(h.nextNodeId(), next, "nextNodeId unchanged");
        } else {
            assertTrue(id != 0);
            assertEq(h.nextNodeId(), id, "nextNodeId := id");
            assertEq(h.freeIds().length, 0);
        }
        // `_newNode` allocates the id; insert overwrites the entire recycled record.
        RadixPriceTree.Node memory n = h.node(id);
        assertEq(n.parent, 0);
        assertEq(n.left, 0);
        assertEq(n.right, 0);
        assertEq(n.bit, 0);
        assertEq(n.price, price);
        assertTrue(n.leaf);
        RadixPriceTree.Node memory u = h.node(unrelatedId);
        assertEq(abi.encode(u), abi.encode(unrelated), "other node unchanged");
        assertEq(h.leaf(otherPrice), otherLeaf, "other leaf entry unchanged");
        assertEq(h.leaf(price), id);
        assertEq(h.sentinel(), 0x5e17, "nothing outside the tree");
    }
}
