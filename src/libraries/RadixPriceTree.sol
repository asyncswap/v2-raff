// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Patricia radix index for uint128 price levels. Inserts and removals
///         traverse at most 128 branch bits; each distinct price creates one
///         leaf and at most one branch node. Node ids released by `remove` are
///         recycled by later inserts, so the id counter only grows with the peak
///         number of simultaneously stored prices and can never be exhausted in
///         practice (2^31 simultaneous levels).
library RadixPriceTree {
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
        /// @dev Ids released by `remove`; `_newNode` pops from here before growing `nextNodeId`.
        uint32[] freeIds;
        mapping(uint32 id => Node) nodes;
        mapping(uint128 price => uint32 id) leaves;
    }

    error PriceLevelMissing();
    error NodeIdOverflow();

    function insert(Tree storage self, uint128 price) internal returns (bool created) {
        if (self.leaves[price] != 0) return false;
        uint32 leafId = _newNode(self);
        self.nodes[leafId].price = price;
        self.nodes[leafId].leaf = true;
        self.leaves[price] = leafId;

        if (self.root == 0) {
            self.root = leafId;
            return true;
        }

        uint32 cursor = self.root;
        while (!self.nodes[cursor].leaf) {
            Node storage branch = self.nodes[cursor];
            cursor = _bitSet(price, branch.bit) ? branch.right : branch.left;
        }

        uint128 differing = price ^ self.nodes[cursor].price;
        uint8 splitBit = _mostSignificantBit(differing);
        uint32 parentId;
        cursor = self.root;
        while (!self.nodes[cursor].leaf && self.nodes[cursor].bit > splitBit) {
            parentId = cursor;
            Node storage branch = self.nodes[cursor];
            cursor = _bitSet(price, branch.bit) ? branch.right : branch.left;
        }

        uint32 branchId = _newNode(self);
        Node storage addedBranch = self.nodes[branchId];
        addedBranch.parent = parentId;
        addedBranch.bit = splitBit;
        if (_bitSet(price, splitBit)) {
            addedBranch.left = cursor;
            addedBranch.right = leafId;
        } else {
            addedBranch.left = leafId;
            addedBranch.right = cursor;
        }
        self.nodes[cursor].parent = branchId;
        self.nodes[leafId].parent = branchId;

        if (parentId == 0) {
            self.root = branchId;
        } else if (self.nodes[parentId].left == cursor) {
            self.nodes[parentId].left = branchId;
        } else {
            self.nodes[parentId].right = branchId;
        }
        return true;
    }

    function remove(Tree storage self, uint128 price) internal {
        uint32 leafId = self.leaves[price];
        if (leafId == 0) revert PriceLevelMissing();
        delete self.leaves[price];

        if (leafId == self.root) {
            self.root = 0;
            _freeNode(self, leafId);
            return;
        }

        uint32 branchId = self.nodes[leafId].parent;
        Node storage branch = self.nodes[branchId];
        uint32 siblingId = branch.left == leafId ? branch.right : branch.left;
        uint32 grandparentId = branch.parent;
        if (grandparentId == 0) {
            self.root = siblingId;
        } else if (self.nodes[grandparentId].left == branchId) {
            self.nodes[grandparentId].left = siblingId;
        } else {
            self.nodes[grandparentId].right = siblingId;
        }
        self.nodes[siblingId].parent = grandparentId;
        _freeNode(self, branchId);
        _freeNode(self, leafId);
    }

    function best(Tree storage self, bool highest) internal view returns (bool found, uint128 price) {
        uint32 cursor = self.root;
        if (cursor == 0) return (false, 0);
        while (!self.nodes[cursor].leaf) {
            Node storage branch = self.nodes[cursor];
            cursor = highest ? branch.right : branch.left;
        }
        return (true, self.nodes[cursor].price);
    }

    /// @dev Reuse a released id first; only grow the counter when none is free. A freed id
    ///      is referenced by nothing (its parent, sibling and `leaves` entries were rewired in
    ///      `remove`), so reusing it cannot alias a live node.
    function _newNode(Tree storage self) private returns (uint32 id) {
        uint256 free = self.freeIds.length;
        if (free != 0) {
            id = self.freeIds[free - 1];
            self.freeIds.pop();
            return id;
        }
        unchecked {
            id = ++self.nextNodeId;
        }
        if (id == 0) revert NodeIdOverflow();
    }

    function _freeNode(Tree storage self, uint32 id) private {
        delete self.nodes[id];
        self.freeIds.push(id);
    }

    function _bitSet(uint128 value, uint8 bit) private pure returns (bool) {
        return (value & (uint128(1) << bit)) != 0;
    }

    function _mostSignificantBit(uint128 value) private pure returns (uint8 bit) {
        // Callers pass the XOR of distinct prices, so value cannot be zero.
        if (value >> 64 != 0) {
            value >>= 64;
            bit = 64;
        }
        if (value >> 32 != 0) {
            value >>= 32;
            bit += 32;
        }
        if (value >> 16 != 0) {
            value >>= 16;
            bit += 16;
        }
        if (value >> 8 != 0) {
            value >>= 8;
            bit += 8;
        }
        if (value >> 4 != 0) {
            value >>= 4;
            bit += 4;
        }
        if (value >> 2 != 0) {
            value >>= 2;
            bit += 2;
        }
        if (value >> 1 != 0) bit += 1;
    }
}
