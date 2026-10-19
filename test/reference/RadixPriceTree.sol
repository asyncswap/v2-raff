// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title RadixPriceTree
/// @notice A Patricia (compressed binary) trie over `uint128` keys, used as the order book's price index and,
///         in `PriorityFee` mode, as the per-level priority index.
/// @dev Spec: `AsyncSwapSpec/RadixTree.lean` (functional trie: `best` is the exact max / min, `insert` /
///      `remove` have exact set semantics and keep the Patricia invariant, every traversal visits ≤ 128
///      branches) and `AsyncSwapSpec/RadixStorage.lean`, `RadixInsert.lean`, `RadixRemove.lean` (this storage
///      encoding refines the functional trie: `Tree.insert`, `Tree.remove`, `Tree.best`, `_newNode`,
///      `_freeNode`, `link`, `relink`). Node ids are `uint32`; `0` is the null id. Ids released by `remove`
///      are recycled by `_newNode`, so `nextNodeId` tracks the *peak* number of simultaneously stored keys
///      (`Bounds.lean` `IdAlloc.insert_no_overflow`): overflow needs `2^31` live keys.
library RadixPriceTree {
    /// @dev One storage slot: 4 + 4 + 4 + 16 + 1 + 1 = 30 bytes.
    struct Node {
        uint32 parent;
        uint32 left;
        uint32 right;
        uint128 price;
        uint8 bit;
        bool leaf;
    }

    struct Tree {
        uint32 root;
        uint32 nextNodeId;
        uint32[] freeIds;
        mapping(uint32 => Node) nodes;
        mapping(uint128 => uint32) leaves;
    }

    error NodeIdOverflow();
    error PriceLevelMissing(uint128 price);

    /// @notice `best(highest)`: the highest (rightmost) or lowest (leftmost) stored key.
    /// @return found `false` iff the tree is empty, in which case `price` is `0`.
    function best(Tree storage self, bool highest) internal view returns (bool found, uint128 price) {
        uint32 cursor = self.root;
        if (cursor == 0) return (false, 0);
        Node storage node = self.nodes[cursor];
        while (!node.leaf) {
            cursor = highest ? node.right : node.left;
            node = self.nodes[cursor];
        }
        return (true, node.price);
    }

    function contains(Tree storage self, uint128 price) internal view returns (bool) {
        return self.leaves[price] != 0;
    }

    function isEmpty(Tree storage self) internal view returns (bool) {
        return self.root == 0;
    }

    /// @notice Inserts `price`. Returns `created = false`, touching nothing, when it is already stored.
    function insert(Tree storage self, uint128 price) internal returns (bool created) {
        if (self.leaves[price] != 0) return false;

        uint32 leafId = _newNode(self);
        {
            Node storage leafNode = self.nodes[leafId];
            leafNode.price = price;
            leafNode.leaf = true;
        }
        self.leaves[price] = leafId;

        uint32 root = self.root;
        if (root == 0) {
            self.root = leafId;
            return true;
        }

        // First walk: descend by the new price's bits to the leaf it would share a prefix with.
        uint32 cursor = root;
        Node storage node = self.nodes[cursor];
        while (!node.leaf) {
            cursor = _testBit(price, node.bit) ? node.right : node.left;
            node = self.nodes[cursor];
        }
        uint8 split = _mostSignificantBit(price ^ node.price);

        // Second walk: descend again while the branch bit is above the split bit, remembering the parent.
        uint32 parentId = 0;
        cursor = root;
        node = self.nodes[cursor];
        while (!node.leaf && node.bit > split) {
            parentId = cursor;
            cursor = _testBit(price, node.bit) ? node.right : node.left;
            node = self.nodes[cursor];
        }

        // A fresh branch at `split` takes `cursor` and the new leaf as children and replaces `cursor` in its parent.
        uint32 branchId = _newNode(self);
        Node storage branch = self.nodes[branchId];
        branch.parent = parentId;
        branch.bit = split;
        if (_testBit(price, split)) {
            branch.left = cursor;
            branch.right = leafId;
        } else {
            branch.left = leafId;
            branch.right = cursor;
        }
        node.parent = branchId;
        self.nodes[leafId].parent = branchId;
        if (parentId == 0) {
            self.root = branchId;
        } else {
            Node storage parent = self.nodes[parentId];
            if (parent.left == cursor) parent.left = branchId;
            else parent.right = branchId;
        }
        return true;
    }

    /// @notice Removes `price`; reverts with `PriceLevelMissing` if it is not stored.
    function remove(Tree storage self, uint128 price) internal {
        uint32 leafId = self.leaves[price];
        if (leafId == 0) revert PriceLevelMissing(price);
        delete self.leaves[price];

        if (leafId == self.root) {
            _freeNode(self, leafId);
            self.root = 0;
            return;
        }

        // The leaf's parent branch is replaced by the leaf's sibling.
        uint32 branchId = self.nodes[leafId].parent;
        Node storage branch = self.nodes[branchId];
        uint32 siblingId = branch.left == leafId ? branch.right : branch.left;
        uint32 grandId = branch.parent;
        if (grandId == 0) {
            self.root = siblingId;
        } else {
            Node storage grand = self.nodes[grandId];
            if (grand.left == branchId) grand.left = siblingId;
            else grand.right = siblingId;
        }
        self.nodes[siblingId].parent = grandId;
        _freeNode(self, branchId);
        _freeNode(self, leafId);
    }

    /// @dev `_newNode`: pop a released id, else `++nextNodeId`.
    function _newNode(Tree storage self) private returns (uint32 id) {
        uint256 free = self.freeIds.length;
        if (free != 0) {
            id = self.freeIds[free - 1];
            self.freeIds.pop();
            return id;
        }
        uint32 next = self.nextNodeId;
        if (next == type(uint32).max) revert NodeIdOverflow();
        unchecked {
            next += 1;
        }
        self.nextNodeId = next;
        return next;
    }

    /// @dev `_freeNode`: reset the node and push its id onto the free list.
    function _freeNode(Tree storage self, uint32 id) private {
        delete self.nodes[id];
        self.freeIds.push(id);
    }

    function _testBit(uint128 value, uint8 bit) private pure returns (bool) {
        return (value >> bit) & 1 == 1;
    }

    /// @dev `⌊log₂ value⌋` for non-zero `value` (`RadixTree.lean` `solMsb_eq_log2`). Returns 0 for 0.
    function _mostSignificantBit(uint128 value) internal pure returns (uint8 bit) {
        uint256 v = value;
        if (v >> 64 != 0) {
            v >>= 64;
            bit += 64;
        }
        if (v >> 32 != 0) {
            v >>= 32;
            bit += 32;
        }
        if (v >> 16 != 0) {
            v >>= 16;
            bit += 16;
        }
        if (v >> 8 != 0) {
            v >>= 8;
            bit += 8;
        }
        if (v >> 4 != 0) {
            v >>= 4;
            bit += 4;
        }
        if (v >> 2 != 0) {
            v >>= 2;
            bit += 2;
        }
        if (v >> 1 != 0) bit += 1;
    }
}
