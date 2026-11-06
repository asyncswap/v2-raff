// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalRefA, RadixPriceTreeHarness} from "./FormalHarnessesA.sol";
import {RadixPriceTree} from "@async-swap/libraries/RadixPriceTree.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapInsert.lean`: the real `RadixPriceTree.insert`
///         on a harness tree. The theorems hold for any tree; the tests use valid trees built with
///         `insert`/`remove`, plus crafted states (free list, counter at its limit, a cyclic tree). The
///         model's `"loop bound"` (a walk exceeding 2^64 steps) is out-of-gas on the EVM, a revert with no data.
contract AsyncSwapInsertFormalTest is FormalRefA {
    RadixPriceTreeHarness h;

    function setUp() public {
        h = new RadixPriceTreeHarness();
    }

    /// @dev A valid tree holding up to 8 of `prices`, then up to `removals` of them removed (so the free
    ///      list is non-empty).
    function _build(uint128[] memory prices, uint8 removals) internal returns (uint256 n) {
        n = prices.length < 8 ? prices.length : 8;
        for (uint256 i; i < n; ++i) {
            h.insert(prices[i]);
        }
        for (uint256 i; i < n && i < removals % 4; ++i) {
            if (h.leaf(prices[i]) != 0) h.remove(prices[i]);
        }
    }

    function _wouldOverflow() internal view returns (bool) {
        return h.freeIds().length == 0 && h.nextNodeId() == type(uint32).max;
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapInsert.lean:67 — a successful _newNode (the first one, into an
    ///         empty tree) writes only the tree and leaves `leaves` and `root` as they were; root and
    ///         leaves[price] change only by insert's own writes afterwards.
    function testFuzz_newNode_ok(uint32[] memory free, uint32 next, uint128 price, uint128 otherPrice, uint32 otherLeaf)
        public
    {
        vm.assume(price != otherPrice);
        h.setFreeIds(free);
        h.setNextNodeId(next);
        h.setLeaf(otherPrice, otherLeaf);
        vm.assume(!_wouldOverflow());
        assertTrue(h.insert(price));
        assertEq(h.leaf(otherPrice), otherLeaf, "leaves unchanged except insert's leaves[price]");
        assertEq(h.leaf(price), h.root(), "root and leaves[price] are insert's writes of the new id");
        assertEq(h.sentinel(), 0x5e17, "only the tree is written");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapInsert.lean:76 — every _newNode revert is NodeIdOverflow (both
    ///         call sites: the leaf, and the branch of a non-empty tree).
    function testFuzz_newNode_err(uint128 a, uint128 price, bool oneFree, bool nonEmpty, bool atMax) public {
        vm.assume(a != price);
        if (nonEmpty) h.insert(a);
        h.setNextNodeId(atMax ? type(uint32).max : type(uint32).max - 1);
        uint32[] memory free = new uint32[](oneFree ? 1 : 0);
        if (oneFree) free[0] = 1000;
        h.setFreeIds(free);
        (bool ok, bytes memory ret) = address(h).call(abi.encodeCall(h.insert, (price)));
        if (!ok) assertEq(ret, abi.encodeWithSelector(RadixPriceTree.NodeIdOverflow.selector));
        // The second _newNode overflows too: one free id for the leaf, none left for the branch.
        if (nonEmpty && oneFree && atMax) assertFalse(ok, "branch id overflows");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapInsert.lean:92 — a present price (leaves[price] != 0) returns
    ///         false and writes nothing, whatever the rest of the tree holds.
    function testFuzz_insert_present(uint128 price, uint32 leafId, uint32 root, uint32 next, uint32[] memory free)
        public
    {
        vm.assume(leafId != 0);
        h.setLeaf(price, leafId);
        h.setRoot(root);
        h.setNextNodeId(next);
        h.setFreeIds(free);
        vm.record();
        assertFalse(h.insert(price));
        (, bytes32[] memory writes) = vm.accesses(address(h));
        assertEq(writes.length, 0, "no SSTORE");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapInsert.lean:100 — an absent price with no free id and
    ///         uint32(nextNodeId + 1) = 0 reverts NodeIdOverflow (any root).
    function testFuzz_insert_overflow(uint128 price, uint32 root) public {
        h.setRoot(root);
        h.setNextNodeId(type(uint32).max);
        vm.expectRevert(RadixPriceTree.NodeIdOverflow.selector);
        h.insert(price);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapInsert.lean:114 — into an empty tree, with _newNode returning a:
    ///         returns true, root := a, nodes[a] gets price and leaf = true (other fields kept), leaves[price] := a.
    function testFuzz_insert_empty(uint32[] memory free, uint32 next, uint128 price, RadixPriceTree.Node memory pre)
        public
    {
        h.setFreeIds(free);
        h.setNextNodeId(next);
        vm.assume(!_wouldOverflow());
        uint32 a;
        unchecked {
            a = free.length != 0 ? free[free.length - 1] : next + 1;
        }
        h.setNode(a, pre);
        assertTrue(h.insert(price));
        assertEq(h.root(), a, "root := a");
        assertEq(h.leaf(price), a, "leaves[price] := a");
        RadixPriceTree.Node memory n = h.node(a);
        assertEq(n.price, price);
        assertTrue(n.leaf);
        assertEq(n.parent, 0);
        assertEq(n.left, 0);
        assertEq(n.right, 0);
        assertEq(n.bit, 0);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapInsert.lean:139 — a revert happens only for an absent price and
    ///         is NodeIdOverflow or a non-terminating walk (out of gas on the EVM).
    function testFuzz_insert_reverts(uint128[] memory prices, uint8 removals, uint128 price, bool atMax, bool cyclic)
        public
    {
        if (cyclic) {
            // Root branch whose children are itself: the first walk never reaches a leaf.
            h.setNode(1, RadixPriceTree.Node({parent: 0, left: 1, right: 1, price: 0, bit: 0, leaf: false}));
            h.setRoot(1);
            h.setNextNodeId(1);
        } else {
            _build(prices, removals);
        }
        if (atMax) {
            h.setFreeIds(new uint32[](0));
            h.setNextNodeId(type(uint32).max);
        }
        bool absent = h.leaf(price) == 0;
        (bool ok, bytes memory ret) = address(h).call{gas: 5_000_000}(abi.encodeCall(h.insert, (price)));
        if (!ok) {
            assertTrue(absent, "reverts only for an absent price");
            bool nodeIdOverflow =
                keccak256(ret) == keccak256(abi.encodeWithSelector(RadixPriceTree.NodeIdOverflow.selector));
            assertTrue(nodeIdOverflow || ret.length == 0, "NodeIdOverflow or out of gas");
            if (ret.length == 0) assertTrue(cyclic, "out of gas only on the cyclic tree");
        }
        if (cyclic && !atMax) assertFalse(ok, "a non-terminating walk reverts");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapInsert.lean:204 — on success: either the price was present
    ///         (false, nothing written) or it was absent, the result is true, only the tree is written and
    ///         `leaves` changes exactly at price.
    function testFuzz_insert_footprint(uint128[] memory prices, uint8 removals, uint128 price, bool pickPresent)
        public
    {
        uint256 n = _build(prices, removals);
        if (pickPresent && n != 0) price = prices[n - 1];
        bool present = h.leaf(price) != 0;
        uint32[] memory before = new uint32[](n);
        for (uint256 i; i < n; ++i) {
            before[i] = h.leaf(prices[i]);
        }
        vm.record();
        bool created = h.insert(price);
        (, bytes32[] memory writes) = vm.accesses(address(h));
        if (present) {
            assertFalse(created);
            assertEq(writes.length, 0, "nothing written");
        } else {
            assertTrue(created);
            assertTrue(h.leaf(price) != 0, "leaves[price] := new leaf");
            for (uint256 i; i < n; ++i) {
                if (prices[i] != price) assertEq(h.leaf(prices[i]), before[i], "other leaves unchanged");
            }
            for (uint256 i; i < writes.length; ++i) {
                assertTrue(writes[i] != bytes32(0), "sentinel slot never written");
            }
            assertEq(h.sentinel(), 0x5e17);
        }
    }
}
