// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HuffDeploy} from "./utils/HuffDeploy.sol";

import {Test} from "forge-std/Test.sol";

/// @dev The Huff `RadixPriceTree` behind `test/harness/RadixHarness.huff`.
interface RadixHarness {
    function insert(uint128 price) external returns (bool);
    function remove(uint128 price) external;
    function best(bool highest) external view returns (bool, uint128);
    function nextNodeId() external view returns (uint32);
    function freeCount() external view returns (uint256);
}

/// @notice Node ids released by `remove` are recycled: the counter only tracks the peak
///         number of simultaneously stored prices, so churn cannot exhaust it.
contract RadixPriceTreeTest is Test {
    RadixHarness internal h;

    function setUp() public {
        h = RadixHarness(HuffDeploy.radixHarness());
    }

    function test_counterTracksPeakNotHistory() public {
        for (uint128 p = 1; p <= 8; ++p) {
            h.insert(p);
        }
        uint32 peak = h.nextNodeId();
        assertEq(peak, 15, "8 levels = 1 + 2*7 ids");
        for (uint128 p = 1; p <= 8; ++p) {
            h.remove(p);
        }
        assertEq(h.freeCount(), 15, "all ids released");
        for (uint256 round; round < 50; ++round) {
            for (uint128 p = 1; p <= 8; ++p) {
                h.insert(p + uint128(round) * 100);
            }
            for (uint128 p = 1; p <= 8; ++p) {
                h.remove(p + uint128(round) * 100);
            }
        }
        assertEq(h.nextNodeId(), peak, "churn never grows the counter");
        assertEq(h.freeCount(), 15);
    }

    function test_packedFreeListCrossesWordBoundaries() public {
        for (uint128 round; round < 5; ++round) {
            uint128 base = round * 1000;
            for (uint128 i = 1; i <= 65; ++i) {
                assertTrue(h.insert(base + i));
                assertFalse(h.insert(base + i), "duplicate must not allocate");
                (bool found, uint128 high) = h.best(true);
                assertTrue(found);
                assertEq(high, base + i);
            }
            assertEq(h.nextNodeId(), 129, "reuse bounds the allocator across 17 packed words");
            for (uint128 i = 1; i <= 65; ++i) {
                h.remove(base + i);
                (bool found, uint128 low) = h.best(false);
                assertEq(found, i != 65);
                if (found) assertEq(low, base + i + 1);
            }
            assertEq(h.freeCount(), 129);
        }
    }

    function test_recycledIdsKeepBestCorrect(uint128[12] memory prices, uint8 removeMask) public {
        bool[12] memory present;
        uint256 count;
        for (uint256 i; i < 12; ++i) {
            if (prices[i] == 0) continue;
            if (h.insert(prices[i])) {
                present[i] = true;
                ++count;
            }
        }
        for (uint256 i; i < 8; ++i) {
            if (present[i] && (removeMask >> i) & 1 == 1) {
                h.remove(prices[i]);
                present[i] = false;
                --count;
            }
        }
        // re-insert a couple of fresh prices through recycled ids
        for (uint256 i = 8; i < 12; ++i) {
            if (!present[i] && prices[i] != 0 && h.insert(prices[i])) {
                present[i] = true;
                ++count;
            }
        }
        uint128 lo = type(uint128).max;
        uint128 hi;
        for (uint256 i; i < 12; ++i) {
            if (!present[i]) continue;
            if (prices[i] < lo) lo = prices[i];
            if (prices[i] > hi) hi = prices[i];
        }
        (bool fhi, uint128 bhi) = h.best(true);
        (bool flo, uint128 blo) = h.best(false);
        assertEq(fhi, count != 0);
        assertEq(flo, count != 0);
        if (count != 0) {
            assertEq(bhi, hi, "best(true) is the max after recycling");
            assertEq(blo, lo, "best(false) is the min after recycling");
        }
    }
}
