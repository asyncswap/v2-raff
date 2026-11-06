// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BitMath} from "v4-core/libraries/BitMath.sol";

/// @notice Three-level occupancy bitmap for the bounded tick-key domain.
/// @dev Not a replacement for the 128-bit fee/sequence tree. Changes storage layout.
library TickBitmap {
    uint128 internal constant MAX_KEY = 1_774_545;

    struct Tree {
        // Each parent bit means its child word is nonempty: root -> middle -> leaf.
        uint256 root;
        mapping(uint256 group => uint256 bits) middle;
        mapping(uint256 word => uint256 bits) leaves;
    }

    error InvalidKey();
    error PriceLevelMissing();

    function insert(Tree storage self, uint128 key) internal returns (bool) {
        if (key == 0 || key > MAX_KEY) revert InvalidKey();
        // Split the tick into a 256-bit word index and a bit offset within that word.
        uint256 word = uint256(key) >> 8;
        uint256 bit = uint256(1) << (key & 255);
        uint256 old = self.leaves[word];
        if (old & bit != 0) return false;
        self.leaves[word] = old | bit;
        // Only an empty-to-nonempty transition needs to propagate to parent words.
        if (old == 0) {
            uint256 group = word >> 8;
            uint256 mid = self.middle[group];
            self.middle[group] = mid | (uint256(1) << (word & 255));
            if (mid == 0) self.root |= uint256(1) << group;
        }
        return true;
    }

    function remove(Tree storage self, uint128 key) internal {
        if (key == 0 || key > MAX_KEY) revert InvalidKey();
        uint256 word = uint256(key) >> 8;
        uint256 bit = uint256(1) << (key & 255);
        uint256 old = self.leaves[word];
        if (old & bit == 0) revert PriceLevelMissing();
        uint256 next = old & ~bit;
        self.leaves[word] = next;
        // Clear ancestor bits only when the last occupied child disappears.
        if (next == 0) {
            uint256 group = word >> 8;
            uint256 mid = self.middle[group] & ~(uint256(1) << (word & 255));
            self.middle[group] = mid;
            if (mid == 0) self.root &= ~(uint256(1) << group);
        }
    }

    // Link the scan once instead of embedding it in both the hook and matching library.
    function best(Tree storage self, bool highest) public view returns (bool, uint128) {
        uint256 root = self.root;
        if (root == 0) return (false, 0);
        // Follow the lowest/highest occupied bit at each level; never scan empty ticks.
        // Parent occupancy guarantees every child passed to BitMath is nonzero.
        uint256 group = _bit(root, highest);
        uint256 word = (group << 8) | _bit(self.middle[group], highest);
        return (true, uint128((word << 8) | _bit(self.leaves[word], highest)));
    }

    function _bit(uint256 bits, bool highest) private pure returns (uint8) {
        // Reuse assembly-backed bit scans (low-bit isolation/de Bruijn for LSB).
        return highest ? BitMath.mostSignificantBit(bits) : BitMath.leastSignificantBit(bits);
    }
}
