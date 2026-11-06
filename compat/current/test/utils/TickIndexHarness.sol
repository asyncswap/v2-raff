// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {RadixPriceTree} from "@async-swap/libraries/RadixPriceTree.sol";
import {TickBitmap} from "@async-swap/libraries/TickBitmap.sol";

contract TickIndexHarness {
    using RadixPriceTree for RadixPriceTree.Tree;
    using TickBitmap for TickBitmap.Tree;
    RadixPriceTree.Tree private radix;
    TickBitmap.Tree private bitmap;
    bool immutable useBitmap;

    constructor(bool use_) {
        useBitmap = use_;
    }

    function insert(uint128 key) external returns (bool) {
        return useBitmap ? bitmap.insert(key) : radix.insert(key);
    }

    function remove(uint128 key) external {
        if (useBitmap) bitmap.remove(key);
        else radix.remove(key);
    }

    function best(bool highest) external view returns (bool, uint128) {
        return useBitmap ? bitmap.best(highest) : radix.best(highest);
    }
}
