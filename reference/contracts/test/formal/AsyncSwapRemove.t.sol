// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalRefA, RadixPriceTreeHarness} from "./FormalHarnessesA.sol";
import {RadixPriceTree} from "@async-swap/libraries/RadixPriceTree.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapRemove.lean`: the real
///         `RadixPriceTree.remove` on a harness tree. The theorems hold for any tree, so besides valid trees
///         built with `insert`, the tests use arbitrary 8-node trees (ids 0..7, fuzzed links, aliasing
///         allowed) and compare the result field by field with the Lean `removeTree` written out below.
contract AsyncSwapRemoveFormalTest is FormalRefA {
    uint256 constant N = 8;

    RadixPriceTreeHarness h;

    struct Snap {
        uint32 root;
        uint32 next;
        RadixPriceTree.Node[N] nodes;
        uint32[] free;
    }

    function setUp() public {
        h = new RadixPriceTreeHarness();
    }

    function _node(uint256 seed) internal pure returns (RadixPriceTree.Node memory n) {
        n.parent = uint32(seed % N);
        n.left = uint32((seed >> 8) % N);
        n.right = uint32((seed >> 16) % N);
        n.price = uint128(seed >> 24);
        n.bit = uint8(seed >> 152);
        n.leaf = (seed >> 160) & 1 == 1;
    }

    /// @dev Writes an arbitrary 8-node tree; `leaves[price] = leafId`.
    function _craft(
        uint256[N] memory seeds,
        uint32 root,
        uint32 leafId,
        uint128 price,
        uint32[] memory free,
        uint32 next
    ) internal returns (Snap memory s) {
        s.root = root % uint32(N);
        s.next = next;
        s.free = free;
        for (uint256 i; i < N; ++i) {
            s.nodes[i] = _node(seeds[i]);
            h.setNode(uint32(i), s.nodes[i]);
        }
        h.setRoot(s.root);
        h.setNextNodeId(next);
        h.setFreeIds(free);
        h.setLeaf(price, leafId);
    }

    function _push(uint32[] memory a, uint32 x) internal pure returns (uint32[] memory b) {
        b = new uint32[](a.length + 1);
        for (uint256 i; i < a.length; ++i) {
            b[i] = a[i];
        }
        b[a.length] = x;
    }

    function _freeTree(Snap memory t, uint32 id) internal pure {
        t.free = _push(t.free, id);
    }

    /// @dev `removeTree t price` from AsyncSwapRemove.lean, with `leafId = t.leaves price` (nonzero, < N).
    function _removeTree(Snap memory t, uint32 leafId) internal pure {
        if (leafId == t.root) {
            t.root = 0;
            _freeTree(t, leafId);
            return;
        }
        uint32 branchId = t.nodes[leafId].parent;
        uint32 siblingId = t.nodes[branchId].left == leafId ? t.nodes[branchId].right : t.nodes[branchId].left;
        uint32 gp = t.nodes[branchId].parent;
        if (gp == 0) t.root = siblingId;
        else if (t.nodes[gp].left == branchId) t.nodes[gp].left = siblingId;
        else t.nodes[gp].right = siblingId;
        t.nodes[siblingId].parent = gp;
        _freeTree(t, branchId);
        _freeTree(t, leafId);
    }

    function _assertTree(Snap memory t) internal view {
        assertEq(h.root(), t.root, "root");
        assertEq(h.nextNodeId(), t.next, "nextNodeId");
        for (uint256 i; i < N; ++i) {
            assertEq(abi.encode(h.node(uint32(i))), abi.encode(t.nodes[i]), "node");
        }
        uint32[] memory got = h.freeIds();
        assertEq(got.length, t.free.length, "freeIds length");
        for (uint256 i; i < got.length; ++i) {
            assertEq(got[i], t.free[i], "freeIds entry");
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapRemove.lean:48 — reverts PriceLevelMissing iff leaves[price] = 0,
    ///         otherwise returns and writes back exactly removeTree(tree, price).
    function testFuzz_remove_run(
        uint256[N] memory seeds,
        uint32 root,
        uint32 leafId,
        uint128 price,
        uint32[] memory free,
        uint32 next,
        bool missing
    ) public {
        leafId = missing ? 0 : leafId % uint32(N);
        Snap memory s = _craft(seeds, root, leafId, price, free, next);
        if (leafId == 0) {
            vm.expectRevert(RadixPriceTree.PriceLevelMissing.selector);
            h.remove(price);
            return;
        }
        h.remove(price);
        _removeTree(s, leafId);
        _assertTree(s);
        assertEq(h.leaf(price), 0, "leaves[price] cleared");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapRemove.lean:104 — the only revert is PriceLevelMissing, exactly
    ///         when leaves[price] = 0.
    function testFuzz_remove_reverts_iff(
        uint256[N] memory seeds,
        uint32 root,
        uint32 leafId,
        uint128 price,
        bool missing
    ) public {
        if (missing) leafId = 0;
        else leafId = leafId % uint32(N);
        _craft(seeds, root, leafId, price, new uint32[](0), 0);
        (bool ok, bytes memory ret) = address(h).call(abi.encodeCall(h.remove, (price)));
        assertEq(!ok, leafId == 0, "reverts iff leaves[price] = 0");
        if (!ok) assertEq(ret, abi.encodeWithSelector(RadixPriceTree.PriceLevelMissing.selector));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapRemove.lean:115 — succeeds whenever the price is present
    ///         (any tree shape), writing removeTree.
    function testFuzz_remove_ok(uint256[N] memory seeds, uint32 root, uint32 leafId, uint128 price) public {
        leafId = 1 + leafId % uint32(N - 1);
        Snap memory s = _craft(seeds, root, leafId, price, new uint32[](0), 3);
        h.remove(price);
        _removeTree(s, leafId);
        _assertTree(s);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapRemove.lean:115 — remove_ok on valid trees built by insert:
    ///         removing every present price succeeds.
    function testFuzz_remove_ok_validTree(uint128[] memory prices, uint256 order) public {
        uint256 n = prices.length < 16 ? prices.length : 16;
        for (uint256 i; i < n; ++i) {
            h.insert(prices[i]);
        }
        for (uint256 i; i < n; ++i) {
            uint128 p = prices[(i + order % n) % n];
            if (h.leaf(p) != 0) h.remove(p);
            assertEq(h.leaf(p), 0);
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapRemove.lean:126 — on success only the tree is written:
    ///         leaves[price] cleared, other leaves and nextNodeId unchanged, freeIds gets [leaf] (leaf was the
    ///         root) or [branch, leaf] appended.
    function testFuzz_remove_footprint(
        uint256[N] memory seeds,
        uint32 root,
        uint32 leafId,
        uint128 price,
        uint128 otherPrice,
        uint32 otherLeaf,
        uint32[] memory free,
        uint32 next
    ) public {
        vm.assume(price != otherPrice);
        leafId = 1 + leafId % uint32(N - 1);
        Snap memory s = _craft(seeds, root, leafId, price, free, next);
        h.setLeaf(otherPrice, otherLeaf);
        uint32 branchId = s.nodes[leafId].parent;
        bool wasRoot = leafId == s.root;
        h.remove(price);
        assertEq(h.leaf(price), 0, "leaves[price] cleared");
        assertEq(h.leaf(otherPrice), otherLeaf, "other leaves unchanged");
        assertEq(h.nextNodeId(), next, "nextNodeId unchanged");
        uint32[] memory got = h.freeIds();
        uint32[] memory want = wasRoot ? _push(free, leafId) : _push(_push(free, branchId), leafId);
        assertEq(abi.encode(got), abi.encode(want), "freeIds");
        assertEq(h.sentinel(), 0x5e17, "nothing outside the tree");
    }
}
