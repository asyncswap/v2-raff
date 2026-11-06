// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RadixPriceTree} from "./RadixPriceTree.sol";

/// @notice Exact-price summaries on a priority-key radix tree.
/// @dev A buy subtree stores its maximum limit; a sell subtree its minimum.
///      This is an existence certificate, not an approximation of an order's limit.
library EligiblePrice {
    using RadixPriceTree for RadixPriceTree.Tree;

    struct Ratio {
        uint256 numerator;
        uint256 denominator;
    }

    /// @dev Exact comparison of positive-denominator ratios using two 512-bit products.
    function le(Ratio memory a, Ratio memory b) internal pure returns (bool result) {
        assembly ("memory-safe") {
            let an := mload(a)
            let ad := mload(add(a, 32))
            let bn := mload(b)
            let bd := mload(add(b, 32))
            let al := mul(an, bd)
            let am := mulmod(an, bd, not(0))
            let ah := sub(sub(am, al), lt(am, al))
            let bl := mul(bn, ad)
            let bm := mulmod(bn, ad, not(0))
            let bh := sub(sub(bm, bl), lt(bm, bl))
            result := or(lt(ah, bh), and(eq(ah, bh), iszero(gt(al, bl))))
        }
    }

    // Linked updates keep matching bytecode below the size limit; storage stays in the caller.
    function refresh(
        RadixPriceTree.Tree storage tree,
        mapping(uint32 => Ratio) storage bounds,
        uint128 rank,
        Ratio memory price,
        bool isBuy
    ) public {
        uint32 leaf = tree.leaves[rank];
        // Callers have just inserted rank or are refreshing a live order.
        // The leaf exists and order admission guarantees a positive denominator.
        bounds[leaf] = price;
        _repair(tree, bounds, tree.nodes[leaf].parent, isBuy, true);
    }

    function remove(RadixPriceTree.Tree storage tree, mapping(uint32 => Ratio) storage bounds, uint128 rank, bool isBuy)
        public
    {
        uint32 leaf = tree.leaves[rank];
        uint32 parent = tree.nodes[leaf].parent;
        uint32 grandparent = tree.nodes[parent].parent;
        tree.remove(rank);
        // Freed summaries are unreachable. Reuse overwrites the leaf and repairs
        // its new parent unconditionally before allowing an early exit above it.
        // The promoted sibling's summary is unchanged, including when it becomes the root.
        _repair(tree, bounds, grandparent, isBuy, false);
    }

    function _repair(
        RadixPriceTree.Tree storage tree,
        mapping(uint32 => Ratio) storage bounds,
        uint32 cursor,
        bool isBuy,
        bool forceFirst
    ) private {
        while (cursor != 0) {
            RadixPriceTree.Node storage node = tree.nodes[cursor];
            Ratio memory left = bounds[node.left];
            Ratio memory right = bounds[node.right];
            Ratio memory next = le(left, right) == isBuy ? right : left;
            Ratio storage previous = bounds[cursor];
            // Only this subtree changed. Once its exact summary is unchanged,
            // every ancestor sees the same pair of child summaries as before.
            // On insertion the first branch may be recycled: equal old bytes do
            // not imply its new ancestors are current. Always propagate past it.
            if (!forceFirst && previous.numerator == next.numerator && previous.denominator == next.denominator) break;
            forceFirst = false;
            previous.numerator = next.numerator;
            previous.denominator = next.denominator;
            cursor = node.parent;
        }
    }

    function _eligible(Ratio memory bound, Ratio memory limit, bool isBuy) private pure returns (bool) {
        return isBuy ? le(limit, bound) : le(bound, limit);
    }

    /// @notice Highest priority key among orders crossing `limit`, in at most 128 branches.
    /// @dev Right children have greater priority keys. No backtracking or linear scan.
    function best(
        RadixPriceTree.Tree storage tree,
        mapping(uint32 => Ratio) storage bounds,
        Ratio memory limit,
        bool isBuy
    ) internal view returns (bool found, uint128 rank) {
        uint32 cursor = tree.root;
        if (cursor == 0 || !_eligible(bounds[cursor], limit, isBuy)) return (false, 0);
        while (!tree.nodes[cursor].leaf) {
            RadixPriceTree.Node storage node = tree.nodes[cursor];
            cursor = _eligible(bounds[node.right], limit, isBuy) ? node.right : node.left;
        }
        return (true, tree.nodes[cursor].price);
    }
}
