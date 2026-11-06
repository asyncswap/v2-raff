// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalRefA} from "./formal/FormalHarnessesA.sol";
import {RadixPriceTree} from "@async-swap/libraries/RadixPriceTree.sol";
import {EligiblePrice} from "@async-swap/libraries/EligiblePrice.sol";

contract EligiblePriceTest is FormalRefA {
    using RadixPriceTree for RadixPriceTree.Tree;
    RadixPriceTree.Tree private tree;
    mapping(uint32 => EligiblePrice.Ratio) private bounds;
    mapping(uint128 => EligiblePrice.Ratio) private oracle;
    uint128[] private ranks;

    function _put(uint128 rank, uint256 n, uint256 d, bool buy) private {
        if (tree.leaves[rank] == 0) ranks.push(rank);
        tree.insert(rank);
        oracle[rank] = EligiblePrice.Ratio(n, d);
        EligiblePrice.refresh(tree, bounds, rank, oracle[rank], buy);
    }

    function _check(uint256 n, uint256 d, bool buy) private view {
        // All ratios in this test fit uint64, so independent cross products fit uint128.
        uint128 expected;
        bool exists;
        for (uint256 i; i < ranks.length; ++i) {
            uint128 k = ranks[i];
            if (tree.leaves[k] == 0) continue;
            EligiblePrice.Ratio memory r = oracle[k];
            bool ok = buy ? r.numerator * d >= n * r.denominator : r.numerator * d <= n * r.denominator;
            if (ok && (!exists || k > expected)) {
                expected = k;
                exists = true;
            }
        }
        (bool found, uint128 actual) = EligiblePrice.best(tree, bounds, EligiblePrice.Ratio(n, d), buy);
        assertEq(found, exists);
        if (found) assertEq(actual, expected);
        _invariant(tree.root, buy, 0);
    }

    function _invariant(uint32 node, bool buy, uint256 depth) private view returns (EligiblePrice.Ratio memory r) {
        if (node == 0) return r;
        assertLe(depth, 128);
        RadixPriceTree.Node storage t = tree.nodes[node];
        if (t.leaf) {
            r = oracle[t.price];
        } else {
            EligiblePrice.Ratio memory a = _invariant(t.left, buy, depth + 1);
            EligiblePrice.Ratio memory b = _invariant(t.right, buy, depth + 1);
            bool le = a.numerator * b.denominator <= b.numerator * a.denominator;
            r = le == buy ? b : a;
            assertEq(tree.nodes[t.left].parent, node);
            assertEq(tree.nodes[t.right].parent, node);
            if (!tree.nodes[t.left].leaf) assertLt(tree.nodes[t.left].bit, t.bit);
            if (!tree.nodes[t.right].leaf) assertLt(tree.nodes[t.right].bit, t.bit);
        }
        assertEq(bounds[node].numerator, r.numerator);
        assertEq(bounds[node].denominator, r.denominator);
    }

    function testFuzz_mutationsAndEligibility(uint256 seed, bool buy) public {
        for (uint256 i; i < 60; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint128 k = uint128(seed % 24);
            if (seed % 4 == 0 && tree.leaves[k] != 0) {
                EligiblePrice.remove(tree, bounds, k, buy);
                delete oracle[k];
            } else {
                _put(k, 1 + uint64(seed >> 64), 1 + uint256(uint64(seed >> 128)), buy);
            }
            _check(1 + uint64(seed >> 192), 1 + uint256(uint64(seed)), buy);
        }
    }

    function test_full128BranchPathAndIdReuse() public {
        _put(0, 1, 1, false);
        for (uint256 i; i < 128; ++i) {
            _put(uint128(uint256(1) << i), 2, 1, false);
        }
        _check(1, 1, false);
        uint32 node = tree.leaves[0];
        uint256 depth;
        while (tree.nodes[node].parent != 0) {
            node = tree.nodes[node].parent;
            ++depth;
        }
        assertEq(depth, 128);
        uint32 peak = tree.nextNodeId;
        for (uint256 i; i < ranks.length; ++i) {
            EligiblePrice.remove(tree, bounds, ranks[i], false);
        }
        assertEq(tree.root, 0);
        _put(0, 3, 1, false);
        _put(type(uint128).max, 1, 1, false);
        assertEq(tree.nextNodeId, peak);
        _check(1, 1, false);
    }

    function test_recycledSummaryMustPropagateToNewAncestors() public {
        _recycledSummary(false);
    }

    function test_recycledBuySummaryMustPropagateToNewAncestors() public {
        _recycledSummary(true);
    }

    function _recycledSummary(bool buy) private {
        _put(0, buy ? 1 : 10, 1, buy);
        _put(1, buy ? 10 : 1, 1, buy);
        _put(2, 5, 1, buy);
        uint32 recycled = tree.nodes[tree.leaves[1]].parent;
        EligiblePrice.remove(tree, bounds, 1, buy);
        _check(5, 1, buy);
        // Reinsert the same extremum into the same recycled branch. Its stale
        // summary equals the new one, but the root must still be updated.
        _put(1, buy ? 10 : 1, 1, buy);
        assertEq(tree.nodes[tree.leaves[1]].parent, recycled);
        _check(buy ? 10 : 1, 1, buy);
    }

    function test_fullWidthRatioComparison() public pure {
        uint256 m = type(uint256).max;
        assertTrue(EligiblePrice.le(EligiblePrice.Ratio(m - 1, m), EligiblePrice.Ratio(m, m)));
        assertFalse(EligiblePrice.le(EligiblePrice.Ratio(m, m - 1), EligiblePrice.Ratio(m, m)));
        assertTrue(EligiblePrice.le(EligiblePrice.Ratio(m, m), EligiblePrice.Ratio(1, 1)));
    }

    function testFuzz_fullWidthComparison(uint256 a, uint256 b, uint256 c, uint256 d) public pure {
        // Independent schoolbook multiplication in four 128-bit limbs, not mulmod.
        (uint256 ah, uint256 al) = _mul512(a, d);
        (uint256 bh, uint256 bl) = _mul512(c, b);
        assertEq(
            EligiblePrice.le(EligiblePrice.Ratio(a, b), EligiblePrice.Ratio(c, d)), ah < bh || (ah == bh && al <= bl)
        );
    }
}
