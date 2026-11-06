// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {TickIndexHarness} from "./utils/TickIndexHarness.sol";
import {TickBitmap} from "@async-swap/libraries/TickBitmap.sol";

/// @dev Uniform-domain mutations supplement dense patterns and test every hierarchy boundary.
contract TickBitmapTest is Test {
    function test_boundariesDuplicatesAndMissingKeys() public {
        TickIndexHarness h = new TickIndexHarness(true);
        (bool found,) = h.best(false);
        assertFalse(found);
        vm.expectRevert(TickBitmap.InvalidKey.selector);
        h.insert(0);
        vm.expectRevert(TickBitmap.InvalidKey.selector);
        h.insert(1_774_546);
        vm.expectRevert(TickBitmap.InvalidKey.selector);
        h.remove(0);
        vm.expectRevert(TickBitmap.InvalidKey.selector);
        h.remove(1_774_546);
        vm.expectRevert(TickBitmap.PriceLevelMissing.selector);
        h.remove(1);
        uint128[6] memory keys = [uint128(1), 255, 256, 65_535, 65_536, 1_774_545];
        for (uint256 i; i < keys.length; ++i) {
            assertTrue(h.insert(keys[i]));
            assertFalse(h.insert(keys[i]));
        }
        for (uint256 i; i < keys.length; ++i) {
            (, uint128 lowest) = h.best(false);
            assertEq(lowest, keys[i]);
            h.remove(keys[i]);
        }
        (found,) = h.best(true);
        assertFalse(found);
    }

    function _check(TickIndexHarness radix, TickIndexHarness bitmap, uint128[64] memory keys, bool[64] memory live)
        internal
        view
    {
        uint128 low = type(uint128).max;
        uint128 high;
        for (uint256 i; i < 64; ++i) {
            if (live[i]) {
                if (keys[i] < low) low = keys[i];
                if (keys[i] > high) high = keys[i];
            }
        }
        for (uint256 i; i < 2; ++i) {
            TickIndexHarness h = i == 0 ? radix : bitmap;
            (bool found, uint128 key) = h.best(false);
            assertEq(found, high != 0);
            if (found) assertEq(key, low);
            (found, key) = h.best(true);
            assertEq(found, high != 0);
            if (found) assertEq(key, high);
        }
    }

    function testFuzz_sparseDomainChurn(uint256 seed) public {
        TickIndexHarness radix = new TickIndexHarness(false);
        TickIndexHarness bitmap = new TickIndexHarness(true);
        uint128[64] memory keys;
        bool[64] memory live;
        for (uint256 i; i < 64; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            // Disjoint intervals guarantee unique keys spread across the entire valid domain.
            keys[i] = uint128(1 + i * 27_726 + seed % 27_726);
        }
        for (uint256 step; step < 256; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 i = seed % 64;
            if (live[i]) {
                radix.remove(keys[i]);
                bitmap.remove(keys[i]);
            } else {
                assertTrue(radix.insert(keys[i]));
                assertTrue(bitmap.insert(keys[i]));
            }
            live[i] = !live[i];
            _check(radix, bitmap, keys, live);
        }
    }

    function test_everyGroupCanBeEmptiedAndReused() public {
        TickIndexHarness h = new TickIndexHarness(true);
        for (uint256 round; round < 3; ++round) {
            for (uint256 group; group < 28; ++group) {
                assertTrue(h.insert(uint128(group * 65536 + 1)));
            }
            assertTrue(h.insert(1_774_545));
            for (uint256 group; group < 28; ++group) {
                (bool found, uint128 lowest) = h.best(false);
                assertTrue(found);
                assertEq(lowest, group * 65536 + 1);
                h.remove(lowest);
            }
            (bool found, uint128 last) = h.best(true);
            assertTrue(found);
            assertEq(last, 1_774_545);
            h.remove(last);
            (found,) = h.best(false);
            assertFalse(found);
        }
    }
}
