// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalSlotsB} from "./FormalSlotsB.sol";
import {IAsyncSwap as AsyncSwap} from "src/interface/IAsyncSwap.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapBestOrder.lean`. `bestAtPrice` is opaque in the model;
///         here it is the real linked (view) code. The expected walk is recomputed from raw storage:
///         `T = isBuy ? bids : asks`, step = right (isBuy) / left, first leaf, its price, maker = orders[id].owner.
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

    /// @dev `firstLeaf T isBuy fuel root` over raw storage; `fuel` stands in for `loopBound`.
    function _walk(PoolId pid, bool isBuy, uint256 fuel) internal view returns (bool empty, bool hit, uint128 price) {
        bytes32 t = _treeSlot(pid, isBuy);
        uint256 c = uint32(uint256(_loadHook(t)));
        if (c == 0) return (true, false, 0);
        for (uint256 i; i < fuel; ++i) {
            uint256 w = uint256(_loadHook(_nodeSlot(t, c)));
            if ((w >> 232) & 0xff != 0) return (false, true, uint128(w >> 96));
            c = isBuy ? uint32(w >> 64) : uint32(w >> 32);
        }
        return (false, false, 0);
    }

    /// @dev Expected outcome of `bestOrder_run` for an acyclic side (walk ends within `fuel`), given the returned id.
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
        assertEq(r.priceKey, price, "price of the first leaf on the walk");
        assertEq(r.maker, address(uint160(uint256(_orderWord(pid, r.orderId, 0)))), "maker = orders[id].owner");
    }

    /// @dev Synthetic side: `depth` branch nodes 1..depth chained along the walk direction (the other child random),
    ///      ending in leaf `depth + 1` with `price`; the level head at that price is `id` owned by `maker`.
    function _synthetic(PoolId pid, bool isBuy, uint8 depth, uint128 price, bytes32 id, address maker, uint256 noise)
        internal
    {
        bytes32 t = _treeSlot(pid, isBuy);
        uint256 n = uint256(depth) % 64;
        vm.store(address(hook), t, bytes32(uint256(1)));
        for (uint256 i = 1; i <= n; ++i) {
            uint32 next = uint32(i + 1);
            uint32 other = uint32(uint256(keccak256(abi.encode(noise, i))));
            vm.store(
                address(hook),
                _nodeSlot(t, i),
                isBuy ? _nodeWord(other, next, uint128(other), false) : _nodeWord(next, other, uint128(other), false)
            );
        }
        vm.store(address(hook), _nodeSlot(t, n + 1), _nodeWord(0, 0, price, true));
        vm.store(address(hook), _levelSlot(pid, isBuy, price), id); // FIFO head
        _storeOrderWord(pid, id, 0, bytes32(uint256(uint160(maker))));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBestOrder.lean:155 — full characterization on real books (FIFO and
    ///         PriorityFee) and on fresh/empty pools.
    function testFuzz_bestOrder_run(uint256 seed, bool priority, bool populated, bool isBuy, address sender) public {
        if (populated) _populate(seed, priority);
        (bool ok, Result memory r) = _call(sender, poolId, isBuy);
        _checkRun(poolId, isBuy, ok, r);
        if (populated) assertTrue(ok && r.found, "populated side has a best order");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBestOrder.lean:155 — full characterization on arbitrary (synthetic) tree
    ///         shapes written into storage.
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

    /// @notice formal/Refinement/Swarm/AsyncSwapBestOrder.lean:208 — a non-empty side whose walk never meets a leaf
    ///         reverts. Model: "loop bound" after 2^64 steps; EVM: out of gas (asserted with a 5M-gas call).
    function testFuzz_bestOrder_loopBound(bytes32 pid, bool isBuy, uint8 cycleLen, uint256 noise) public {
        bytes32 t = _treeSlot(PoolId.wrap(pid), isBuy);
        uint256 n = uint256(cycleLen) % 8 + 1;
        vm.store(address(hook), t, bytes32(uint256(1)));
        for (uint256 i = 1; i <= n; ++i) {
            uint32 next = uint32(i % n + 1); // i -> i+1 -> ... -> n -> 1
            uint32 other = uint32(uint256(keccak256(abi.encode(noise, i))));
            vm.store(
                address(hook),
                _nodeSlot(t, i),
                isBuy ? _nodeWord(other, next, uint128(noise), false) : _nodeWord(next, other, uint128(noise), false)
            );
        }
        (bool ok,) = address(hook).call{gas: 5_000_000}(abi.encodeCall(AsyncSwap.bestOrder, (PoolId.wrap(pid), isBuy)));
        assertFalse(ok);
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
