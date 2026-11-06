// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalSlotsB} from "./FormalSlotsB.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapBestOrder.lean`. `bestAtPrice` is opaque in the model;
///         here it is the real linked (view) code. The expected outer index result is recomputed from raw storage by a bit-by-bit scan of each bitmap word;
///         the inner priority tree remains radix-based, and maker = orders[id].owner.
contract AsyncSwapBestOrderFormalTest is FormalSlotsB {
    struct Result {
        bool found;
        uint128 priceKey;
        bytes32 orderId;
        address maker;
    }

    function _call(address sender, PoolId pid, bool isBuy) internal returns (bool ok, Result memory r) {
        vm.prank(sender);
        bytes memory ret;
        (ok, ret) = address(hook).call(abi.encodeCall(AsyncSwap.bestOrder, (pid, isBuy)));
        if (ok) (r.found, r.priceKey, r.orderId, r.maker) = abi.decode(ret, (bool, uint128, bytes32, address));
    }

    /// @dev Independent bit-by-bit scan of the bitmap's three words; no production bit-scan helper.
    function _walk(PoolId pid, bool isBuy, uint256) internal view returns (bool empty, bool hit, uint128 price) {
        bytes32 t = _treeSlot(pid, isBuy);
        uint256 root = uint256(_loadHook(t));
        if (root == 0) return (true, false, 0);
        uint256 group = _scanWord(root, isBuy);
        uint256 mid = uint256(_loadHook(keccak256(abi.encode(group, uint256(t) + 1))));
        if (mid == 0) return (false, false, 0);
        uint256 word = group * 256 + _scanWord(mid, isBuy);
        uint256 leaf = uint256(_loadHook(keccak256(abi.encode(word, uint256(t) + 2))));
        if (leaf == 0) return (false, false, 0);
        return (false, true, uint128(word * 256 + _scanWord(leaf, isBuy)));
    }

    function _scanWord(uint256 word, bool highest) internal pure returns (uint256) {
        for (uint256 i; i < 256; ++i) {
            uint256 bit = highest ? 255 - i : i;
            if (word & (uint256(1) << bit) != 0) return bit;
        }
        revert("empty bitmap child");
    }

    /// @dev Expected bestOrder result for a valid occupied-bit path, given the returned id.
    function _checkRun(PoolId pid, bool isBuy, bool ok, Result memory r) internal view {
        (bool empty, bool hit, uint128 price) = _walk(pid, isBuy, 512);
        if (empty) {
            assertTrue(ok, "empty side never reverts");
            assertFalse(r.found);
            assertEq(r.priceKey, 0);
            assertEq(r.orderId, bytes32(0));
            assertEq(r.maker, address(0));
            return;
        }
        assertTrue(hit, "test setup: walk reaches a leaf");
        if (!ok) return; // a revert here can only come from the opaque bestAtPrice
        assertTrue(r.found);
        assertEq(r.priceKey, price, "price of the selected occupied tick");
        assertEq(r.maker, address(uint160(uint256(_loadHook(_orderSlot(pid, r.orderId))))), "maker = orders[id].owner");
    }

    /// @dev A synthetic occupied tick with a real priority leaf. The outer domain is bounded;
    ///      cyclic radix pointers no longer exist. Sparse tests cover multiple occupied groups.
    function _synthetic(PoolId pid, bool isBuy, uint8, uint128 price, bytes32 id, address maker, uint256) internal {
        price = 1 + price % 1_774_545;
        bytes32 t = _treeSlot(pid, isBuy);
        uint256 word = uint256(price) >> 8;
        uint256 group = word >> 8;
        vm.store(address(hook), t, bytes32(uint256(1) << group));
        vm.store(address(hook), keccak256(abi.encode(group, uint256(t) + 1)), bytes32(uint256(1) << (word & 255)));
        vm.store(address(hook), keccak256(abi.encode(word, uint256(t) + 2)), bytes32(uint256(1) << (price & 255)));
        bytes32 level = _levelSlot(pid, isBuy, price);
        bytes32 priorityTree = _add(level, 1);
        vm.store(address(hook), level, bytes32(uint256(1)));
        vm.store(address(hook), priorityTree, bytes32(uint256(1)));
        vm.store(address(hook), _nodeSlot(priorityTree, 1), _nodeWord(0, 0, 1, true));
        vm.store(address(hook), keccak256(abi.encode(uint256(1), uint256(level) + 5)), id);
        vm.store(address(hook), _orderSlot(pid, id), bytes32(uint256(uint160(maker))));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBestOrder.lean:155 — full characterization on real books (FIFO and
    ///         PriorityFee) and on fresh/empty pools.
    function testFuzz_bestOrder_run(uint256 seed, bool priority, bool populated, bool isBuy, address sender) public {
        if (populated) _populate(seed, priority);
        (bool ok, Result memory r) = _call(sender, poolId, isBuy);
        _checkRun(poolId, isBuy, ok, r);
        if (populated) assertTrue(ok && r.found, "populated side has a best order");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBestOrder.lean:155 — full characterization on synthetic occupied ticks
    ///         within the supported domain written into storage.
    function testFuzz_bestOrder_run_synthetic(
        bytes32 pid,
        bool isBuy,
        uint8 depth,
        uint128 price,
        bytes32 id,
        address maker,
        uint256 noise
    ) public {
        _synthetic(PoolId.wrap(pid), isBuy, depth, price, id, maker, noise);
        (bool ok, Result memory r) = _call(address(this), PoolId.wrap(pid), isBuy);
        assertTrue(ok);
        _checkRun(PoolId.wrap(pid), isBuy, ok, r);
        assertEq(r.orderId, id, "FIFO bestAtPrice = level head");
        assertEq(r.maker, maker);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBestOrder.lean:202 — empty side ⇒ (false, 0, 0, 0), nothing written, no
    ///         revert (fresh pool, the empty side of a one-sided book, and junk nodes under root = 0).
    function testFuzz_bestOrder_empty(bytes32 pid, bool isBuy, uint256 junk, bool oneSided) public {
        PoolId p = PoolId.wrap(pid);
        if (oneSided) {
            p = poolId;
            _placeOrder(alice, isBuy, 1 ether, 0.9 ether); // zeroForOne = isBuy fills the other side (side = !zeroForOne)
        }
        vm.store(address(hook), _nodeSlot(_treeSlot(p, isBuy), 0), bytes32(junk));
        vm.store(address(hook), _nodeSlot(_treeSlot(p, isBuy), 1), bytes32(junk));
        vm.record();
        (bool ok, Result memory r) = _call(address(this), p, isBuy);
        _assertNoHookWrites();
        assertTrue(ok);
        assertFalse(r.found);
        assertEq(r.priceKey, 0);
        assertEq(r.orderId, bytes32(0));
        assertEq(r.maker, address(0));
    }

    /// @notice Bitmap replacement for the old cyclic-pointer test: every valid synthetic path
    ///         terminates within the call budget; a parent with an empty child is rejected.
    function testFuzz_bestOrder_boundedBitmapDepth(bytes32 pid, bool isBuy, uint8, uint256 noise) public {
        PoolId p = PoolId.wrap(pid);
        _synthetic(p, isBuy, 0, uint128(noise), bytes32(noise), address(this), 0);
        (bool ok,) = address(hook).call{gas: 5_000_000}(abi.encodeCall(AsyncSwap.bestOrder, (p, isBuy)));
        assertTrue(ok, "three-level lookup terminates");
        bytes32 t = _treeSlot(p, isBuy);
        uint256 group = (1 + uint128(noise) % 1_774_545) >> 16;
        vm.store(address(hook), keccak256(abi.encode(group, uint256(t) + 1)), bytes32(0));
        (ok,) = address(hook).call{gas: 5_000_000}(abi.encodeCall(AsyncSwap.bestOrder, (p, isBuy)));
        assertFalse(ok, "missing occupied child rejected");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBestOrder.lean:218 — success shape: empty ⇒ (false,0,0,0) and w' = w;
    ///         else found, price at the first leaf of the walk, maker = orders[id].owner.
    function testFuzz_bestOrder_ok(
        uint256 seed,
        bool priority,
        bool populated,
        bool isBuy,
        bool synthetic,
        uint8 depth,
        uint128 price
    ) public {
        PoolId p = poolId;
        if (synthetic) {
            p = PoolId.wrap(keccak256(abi.encode(seed)));
            _synthetic(p, isBuy, depth, price, bytes32(seed), address(uint160(seed)), seed >> 8);
        } else if (populated) {
            _populate(seed, priority);
        }
        vm.record();
        (bool ok, Result memory r) = _call(address(this), p, isBuy);
        if (ok) {
            _assertNoHookWrites();
            _checkRun(p, isBuy, ok, r);
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBestOrder.lean:251 — the real bestAtPrice is a view, so a successful
    ///         bestOrder writes nothing.
    function testFuzz_bestOrder_readOnly(uint256 seed, bool priority, bool populated, bool isBuy, address sender)
        public
    {
        if (populated) _populate(seed, priority);
        vm.record();
        (bool ok,) = _call(sender, poolId, isBuy);
        assertTrue(ok);
        _assertNoHookWrites();
    }
}
