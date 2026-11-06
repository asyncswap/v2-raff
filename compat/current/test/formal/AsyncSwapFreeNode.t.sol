// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalRefA, RadixPriceTreeHarness} from "./FormalHarnessesA.sol";
import {RadixPriceTree} from "@async-swap/libraries/RadixPriceTree.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapFreeNode.lean`. The private
///         `RadixPriceTree._freeNode(id)` is observed through the real `remove` of the root leaf: with
///         `leaves[price] = root = id`, `remove(price)` clears `leaves[price]`, sets `root := 0` and calls
///         `_freeNode(id)` once (the same accessor wrappers `freeNode_run_wrapped` describes). Free list,
///         counter and the node's fields are fuzzed.
contract AsyncSwapFreeNodeFormalTest is FormalRefA {
    RadixPriceTreeHarness h;

    RadixPriceTree.Node unrelated = RadixPriceTree.Node({parent: 7, left: 8, right: 9, price: 10, bit: 11, leaf: true});

    function setUp() public {
        h = new RadixPriceTreeHarness();
    }

    /// @dev Root leaf `id` (fuzzed contents, `id != 0`), plus node `id + 1` and leaf `otherPrice` untouched by it.
    function _setUp(
        uint32 id,
        RadixPriceTree.Node memory n,
        uint128 price,
        uint32[] memory free,
        uint32 next,
        uint128 otherPrice
    ) internal returns (uint32 other) {
        h.setNode(id, n);
        h.setRoot(id);
        h.setLeaf(price, id);
        h.setFreeIds(free);
        h.setNextNodeId(next);
        unchecked {
            other = id + 1;
        }
        h.setNode(other, unrelated);
        h.setLeaf(otherPrice, 5);
    }

    function _assertFreed(uint32 id, uint32[] memory free, RadixPriceTree.Node memory n) internal view {
        assertEq(abi.encode(h.node(id)), abi.encode(n), "unreachable node retained");
        uint32[] memory got = h.freeIds();
        assertEq(got.length, free.length + 1, "one id pushed");
        for (uint256 i; i < free.length; ++i) {
            assertEq(got[i], free[i]);
        }
        assertEq(got[free.length], id, "id appended last");
    }

    function _run(
        uint32 id,
        RadixPriceTree.Node memory n,
        uint128 price,
        uint32[] memory free,
        uint32 next,
        uint128 otherPrice
    ) internal {
        vm.assume(id != 0 && price != otherPrice);
        _setUp(id, n, price, free, next, otherPrice);
        h.remove(price);
        _assertFreed(id, free, n);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapFreeNode.lean:33 — succeeds and writes back the tree with
    ///         nodes[id] retained and id appended to freeIds.
    function testFuzz_freeNode_run(
        uint32 id,
        RadixPriceTree.Node memory n,
        uint128 price,
        uint32[] memory free,
        uint32 next,
        uint128 otherPrice
    ) public {
        _run(id, n, price, free, next, otherPrice);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapFreeNode.lean:44 — the same result with the accessor wrappers
    ///         `remove` passes (the only call path on the bytecode).
    function testFuzz_freeNode_run_wrapped(
        uint32 id,
        RadixPriceTree.Node memory n,
        uint128 price,
        uint32[] memory free,
        uint32 next,
        uint128 otherPrice
    ) public {
        _run(id, n, price, free, next, otherPrice);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapFreeNode.lean:55 — never reverts.
    function testFuzz_freeNode_no_revert(uint32 id, RadixPriceTree.Node memory n, uint128 price, uint32[] memory free)
        public
    {
        vm.assume(id != 0);
        _setUp(id, n, price, free, 0, ~price);
        (bool ok,) = address(h).call(abi.encodeCall(h.remove, (price)));
        assertTrue(ok);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapFreeNode.lean:64 — after _freeNode(id): nodes[id] unchanged,
    ///         other nodes, nextNodeId and leaves unchanged, freeIds extended by id (root := 0 is remove's
    ///         own write).
    function testFuzz_freeNode_footprint(
        uint32 id,
        RadixPriceTree.Node memory n,
        uint128 price,
        uint32[] memory free,
        uint32 next,
        uint128 otherPrice
    ) public {
        vm.assume(id != 0 && price != otherPrice);
        uint32 other = _setUp(id, n, price, free, next, otherPrice);
        h.remove(price);
        _assertFreed(id, free, n);
        assertEq(abi.encode(h.node(other)), abi.encode(unrelated), "other node unchanged");
        assertEq(h.nextNodeId(), next, "nextNodeId unchanged");
        assertEq(h.leaf(otherPrice), 5, "other leaves unchanged");
        assertEq(h.leaf(price), 0, "remove's own write");
        assertEq(h.root(), 0, "remove's own write");
        assertEq(h.sentinel(), 0x5e17, "nothing outside the tree");
    }
}
