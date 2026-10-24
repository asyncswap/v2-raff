// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {OrderInfo} from "./OrderInfo.sol";
import {FormalBase} from "./FormalBase.sol";
import {IAsyncSwap as AsyncSwap} from "src/interface/IAsyncSwap.sol";
import {IAsyncFiller as AsyncFiller} from "src/interface/IAsyncFiller.sol";
import {AsyncOrder} from "src/interface/types/AsyncOrder.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice Storage-slot, transient-storage and write-footprint helpers shared by the group-B
///         bytecode checks of the Lean theorems (getters, ownership, `receive`, order-book views).
abstract contract FormalSlotsB is FormalBase {
    /// @dev `keccak256("asyncswap.hook.pendingNativeDeposit") - 1`, `AsyncSwap.PENDING_NATIVE_DEPOSIT_SLOT`.
    bytes32 constant PENDING_NATIVE_DEPOSIT = 0x9c2a7e4f3b1d8a5c6e0f2d4b7a9c1e3d5f8b6a0c2e4d7b9f1a3c5e7d9b1f3a50;
    bytes32 constant PENDING_MATCH_ID = 0x247d5e35be7fbfd4d95fd66ea940bfb4ee942bef70db6afae46dc83ce0f89eb2;

    // ---------------------------------------------------------------- slots

    function _bookSlot(PoolId pid) internal pure returns (bytes32) {
        return keccak256(abi.encode(pid, PRICE_BOOKS_SLOT));
    }

    function _stateSlot(PoolId pid) internal pure returns (bytes32) {
        return keccak256(abi.encode(pid, ASYNC_ORDERS_SLOT));
    }

    /// @dev `asyncOrders[pid].orders[id]` (State member 3).
    function _orderSlot(PoolId pid, bytes32 id) internal pure returns (bytes32) {
        return keccak256(abi.encode(id, uint256(_stateSlot(pid)) + 3));
    }

    function _nonceSlot(address maker, uint256 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encode(nonce, keccak256(abi.encode(maker, NONCE_USED_SLOT))));
    }

    function _add(bytes32 s, uint256 k) internal pure returns (bytes32) {
        return bytes32(uint256(s) + k);
    }

    /// @dev Book slot 0: `nextSequence` (bytes 0-7) | `openOrderCount` (8-15) | `orderingMode` (16).
    function _bookWord(uint64 nextSequence, uint64 openOrderCount, uint8 mode) internal pure returns (bytes32) {
        return bytes32(uint256(nextSequence) | (uint256(openOrderCount) << 64) | (uint256(mode) << 128));
    }

    /// @dev Write a typed `OrderInfo` record into the order of `id` (Solidity field names, Huff slots).
    function _storeOrder(PoolId pid, bytes32 id, OrderInfo memory o) internal {
        bytes32[8] memory w;
        w[0] = bytes32(uint256(uint160(o.owner)));
        w[1] = bytes32(o.amountIn);
        w[2] = bytes32(o.amountOutMin);
        w[3] = bytes32(uint256(o.price));
        w[4] = o.previous;
        w[5] = o.next;
        w[6] = bytes32(
            (o.isBuy ? uint256(1) : 0) | ((o.zeroForOne ? uint256(1) : 0) << 8) | (uint256(o.sequence) << 16)
                | (uint256(o.priorityFee) << 80)
        );
        w[7] = bytes32(uint256(o.priorityKey) | ((o.priorityFeeEscrowed ? uint256(1) : 0) << 128));
        _storeOrderWordsAt(uint256(_orderSlot(pid, id)), w);
    }

    /// @dev Perturb storage the order getters must not read: owner, pendingOwner, a nonce entry and
    ///      the pool's book header.
    function _perturbOtherStorage(uint256 seed) internal {
        vm.store(address(hook), bytes32(OWNER_SLOT), bytes32(uint256(uint160(uint256(keccak256(abi.encode(seed, 1)))))));
        vm.store(
            address(hook),
            bytes32(PENDING_OWNER_SLOT),
            bytes32(uint256(uint160(uint256(keccak256(abi.encode(seed, 2))))))
        );
        vm.store(address(hook), _nonceSlot(address(uint160(seed)), seed), bytes32(uint256(1)));
        vm.store(address(hook), _bookSlot(poolId), _bookWord(uint64(seed), uint64(seed >> 64), uint8(seed % 2)));
    }

    // ---------------------------------------------------------------- write footprint

    /// @dev Slots written in `address(hook)`'s storage since the last `vm.record()`.
    function _hookWrites() internal view returns (bytes32[] memory writes) {
        (, writes) = vm.accesses(address(hook));
    }

    function _assertNoHookWrites() internal view {
        assertEq(_hookWrites().length, 0, "no SSTORE to the hook");
    }

    /// @dev Every SSTORE to the hook since `vm.record()` hit one of `allowed`.
    function _assertWritesWithin(bytes32[] memory allowed) internal view {
        bytes32[] memory writes = _hookWrites();
        for (uint256 i; i < writes.length; ++i) {
            bool ok;
            for (uint256 j; j < allowed.length; ++j) {
                if (writes[i] == allowed[j]) ok = true;
            }
            assertTrue(ok, "SSTORE outside the theorem's write set");
        }
    }

    // ---------------------------------------------------------------- transient storage probes

    /// @dev runtime: `tload(calldataload(0))` -> return 32 bytes.
    bytes constant TLOAD_PROBE = hex"6000355c60005260206000f3";
    /// @dev runtime: `tstore(calldataload(0), calldataload(32))`.
    bytes constant TSTORE_PROBE = hex"6020356000355d00";

    /// @dev Read `account`'s transient slot by swapping in a probe and restoring the code.
    function _tload(address account, bytes32 slot) internal returns (uint256 v) {
        bytes memory code = account.code;
        vm.etch(account, TLOAD_PROBE);
        (bool ok, bytes memory ret) = account.call(abi.encode(slot));
        require(ok, "tload probe");
        v = abi.decode(ret, (uint256));
        vm.etch(account, code);
    }

    function _tstore(address account, bytes32 slot, uint256 v) internal {
        bytes memory code = account.code;
        vm.etch(account, TSTORE_PROBE);
        (bool ok,) = account.call(abi.encode(slot, v));
        require(ok, "tstore probe");
        vm.etch(account, code);
    }

    // ---------------------------------------------------------------- orders

    function _withPriorityFee(AsyncOrder memory order, uint256 priorityFee) internal view returns (AsyncOrder memory) {
        order.priorityFee = priorityFee;
        order.salt = keccak256(
            abi.encode(
                block.timestamp,
                block.number,
                address(manager),
                order.owner,
                order.amountIn,
                order.amountOutMin,
                priorityFee
            )
        );
        return order;
    }

    /// @dev Place a priority-fee order (pool must be in PriorityFee mode); returns its id.
    function _placePriorityOrder(address maker, bool zeroForOne, uint256 amountIn, uint256 amountOutMin, uint256 fee)
        internal
        returns (bytes32 id)
    {
        AsyncOrder memory order = _withPriorityFee(_orderFromMaker(maker, zeroForOne, amountIn, amountOutMin), fee);
        vm.prank(maker);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: maker, executor: address(router), amountOutMin: amountOutMin, priorityFee: fee
                })
            )
        );
        id = _orderIdFor(maker, zeroForOne, order.salt);
    }

    // ---------------------------------------------------------------- populated books

    /// @dev Non-crossing book on the fixture pool: asks (zeroForOne, isBuy = false) at price ≥ 1.5 and bids
    ///      (!zeroForOne, isBuy = true) at price ≤ 1/1.5, two makers per price so FIFO levels hold > 1 order.
    ///      In PriorityFee mode every order carries a distinct priority fee.
    function _populate(uint256 seed, bool priority) internal returns (bytes32[] memory ids) {
        if (priority) hook.setOrderingMode(key, AsyncFiller.OrderingMode.PriorityFee);
        ids = new bytes32[](8);
        for (uint256 i; i < 4; ++i) {
            uint256 minOut = 1.5 ether + (uint256(keccak256(abi.encode(seed, i))) % 1.5 ether);
            bool zeroForOne = i % 2 == 0;
            for (uint256 j; j < 2; ++j) {
                address maker = j == 0 ? alice : bob;
                if (priority) {
                    ids[2 * i + j] =
                        _placePriorityOrder(maker, zeroForOne, 1 ether, minOut, 100_000 + 1000 * (2 * i + j));
                } else {
                    (, ids[2 * i + j]) = _placeOrder(maker, zeroForOne, 1 ether, minOut);
                }
            }
        }
    }

    /// @dev The bid (isBuy) or ask price tree: `P + 1` / `P + 2` (`src/lib/Book.huff`).
    function _treeSlot(PoolId pid, bool isBuy) internal pure returns (bytes32) {
        return _add(_bookSlot(pid), isBuy ? 1 : 2);
    }

    /// @dev Node `id` of the tree at `tree`: `keccak(tree) + 2^32 + id` (`src/lib/RadixPriceTree.huff`).
    function _nodeSlot(bytes32 tree, uint256 id) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(tree))) + 2 ** 32 + id);
    }

    /// @dev Node word: parent (0-3) | left (4-7) | right (8-11) | price (12-27) | bit (28) | leaf (29).
    function _nodeWord(uint32 left, uint32 right, uint128 price, bool leaf) internal pure returns (bytes32) {
        return bytes32(
            (uint256(left) << 32) | (uint256(right) << 64) | (uint256(price) << 96) | ((leaf ? uint256(1) : 0) << 232)
        );
    }

    /// @dev The bid / ask level at `price`: `keccak(price, P + 5)` / `keccak(price, P + 6)`.
    function _levelSlot(PoolId pid, bool isBuy, uint128 price) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(price), uint256(_bookSlot(pid)) + (isBuy ? 5 : 6)));
    }
}
