// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;
import {PoolId} from "v4-core/types/PoolId.sol";

import {HookUnlockBase} from "./HookUnlockBase.sol";
import {LibHelpersCasesB, RadixTreeHarnessB} from "./LibHelpersB.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {RadixPriceTree} from "@async-swap/libraries/RadixPriceTree.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";

/// @notice Checks of the AsyncSwap-only helper theorems whose functions are private to their library:
///         `AsyncFiller._priorityKey` (read back from the stored `priorityKey`), `AsyncMatching._crosses`
///         (whether `matchBook` matches two resting orders), `AsyncFiller._priceKey` (the stored key of
///         an order a match left partly filled) and `RadixPriceTree._bitSet` / `_freeNode` (through the
///         library's `insert` / `remove` on a harness tree).
abstract contract HookHelpersCasesB is HookUnlockBase, LibHelpersCasesB {
    uint256 constant WAD = 1e18;
    /// @dev `TickPrice.key` runs from 1 to 2 * MAX_TICK + 1.
    uint256 constant MAX_PRICE_KEY = 2 * 887272 + 1;

    // ------------------------------------------------------------ _priorityKey

    /// @dev Set the pool's `nextSequence` so the next order gets sequence `seq`.
    function _setNextSequence(uint64 seq) internal {
        bytes32 slot = keccak256(abi.encode(poolId, PRICE_BOOKS_SLOT));
        uint256 word = uint256(_loadHook(slot));
        word = (word & ~uint256(type(uint64).max)) | uint256(seq - 1);
        vm.store(address(hook), slot, bytes32(word));
    }

    function _priorityKeyOf(bytes32 id) internal view returns (uint128) {
        return uint128(uint256(_loadHook(bytes32(_orderSlot(poolId, id) + 4))) >> 64);
    }

    /// @dev `_placeOrder` with a priority bid, through the Router (which pays the bid in the same unlock).
    function _placeWithFee(address maker, bool zeroForOne, uint256 amountIn, uint256 amountOutMin, uint256 fee)
        internal
        returns (bytes32 id)
    {
        AsyncOrder memory order = _orderFromMaker(maker, zeroForOne, amountIn, amountOutMin);
        order.priorityFee = fee;
        vm.prank(maker);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: maker, executor: address(router), amountOutMin: amountOutMin, priorityFee: fee
                })
            )
        );
        order.salt =
            keccak256(abi.encode(block.timestamp, block.number, address(manager), maker, amountIn, amountOutMin, fee));
        id = _orderIdFor(maker, zeroForOne, order.salt);
        (, uint256 amt,,,,,) = hook.orderBookOrder(poolId, id);
        assertEq(amt, amountIn, "order rests");
    }

    /// @dev `_priorityKey(fee, seq) = (uint128(fee) << 64) | (2^64 - 1 - seq)`; for a 64-bit fee that is
    ///      `fee * 2^64 + (2^64 - 1 - seq)`. FIFO pools store `_priorityKey(0, seq)`; PriorityFee pools
    ///      store `_priorityKey(paid fee, seq)`.
    function _checkPriorityKey(uint64 fee, uint64 seq, bool priorityMode, bool zeroForOne) internal {
        seq = uint64(bound(seq, 1, type(uint64).max)); // ++nextSequence: the first order is sequence 1
        uint256 f = 100_000;
        if (priorityMode) {
            f = bound(fee, 100_000, type(uint64).max); // the hook's MIN_PRIORITY_FEE .. MAX_PRIORITY_FEE
        }
        _setNextSequence(seq);
        bytes32 id = _placeWithFee(alice, zeroForOne, 1 ether, 1 ether, f);
        assertEq(_sequenceOf(poolId, id), seq, "sequence");
        assertEq(uint256(_priorityKeyOf(id)), f * 2 ** 64 + (2 ** 64 - 1 - uint256(seq)), "priorityKey");
    }

    // ------------------------------------------------------------ resting orders owned by this contract

    function _selfFund() internal {
        token0.mint(address(this), 1e33);
        token1.mint(address(this), 1e33);
        hook.setExecutor(poolId, address(this), true);
    }

    /// @dev Create an order owned by this contract without the Router's `matchNewOrder`, so it rests
    ///      even when it crosses the book.
    function _rest(bool zeroForOne, uint256 amountIn, uint256 amountOutMin) internal returns (bytes32 id) {
        (bytes32 liquiditySlot, bytes32 previousLiquidity) = _storedAdmissionFixture(PoolId.unwrap(poolId));
        _run(_createCalls(key, zeroForOne, amountIn, amountOutMin, 100_000));
        _restoreAdmissionFixture(liquiditySlot, previousLiquidity);
        id = _idOf(_selfOrder(key, zeroForOne, amountIn, amountOutMin, 100_000));
    }

    function _key(bytes32 id) internal view returns (uint128 k) {
        (,,, k,,,) = hook.orderBookOrder(poolId, id);
    }

    function _matchOne() internal returns (uint8) {
        bytes[] memory r = _runR(_one(_c(address(hook), abi.encodeCall(hook.matchBook, (key, uint8(1))))));
        return abi.decode(r[0], (uint8));
    }

    /// @dev The book's best bid / ask after resting `ask = (sIn asset -> sOut quote)` and
    ///      `bid = (bIn quote -> bOut asset)`.
    function _restPair(uint256 sIn, uint256 sOut, uint256 bIn, uint256 bOut)
        internal
        returns (bytes32 askId, bytes32 bidId, uint128 sk, uint128 bk)
    {
        _selfFund();
        askId = _rest(true, sIn, sOut); // zeroForOne: token0 in, isBuy = false
        bidId = _rest(false, bIn, bOut); // numeraire in, isBuy = true
        sk = _key(askId);
        bk = _key(bidId);
        (bool hasBid, uint128 bestBid,,) = hook.bestOrder(poolId, true);
        (bool hasAsk, uint128 bestAsk,,) = hook.bestOrder(poolId, false);
        assertTrue(hasBid && hasAsk, "both rest");
        assertEq(bestBid, bk);
        assertEq(bestAsk, sk);
    }

    // ------------------------------------------------------------ _priceKey

    /// @dev The v4 tick key of the exact limit (`TickPrice.key`). Asks here sell currency0 and bids
    ///      sell currency1, so `zeroForOne == !isBuy`.
    function _expectedPriceKey(bool isBuy, uint256 a, uint256 o) internal pure returns (uint256) {
        return AsyncFiller._priceKey(isBuy, !isBuy, a, o);
    }

    /// @dev After a match, a partly filled order's stored key is `_priceKey(isBuy, amountIn, amountOutMin)`
    ///      of its remaining amounts (when the key is unchanged the stored key already equals it).
    ///      Returns how many partly filled orders were checked.
    function _checkPartialKeys(bytes32 askId, bytes32 bidId) internal view returns (uint256 checked) {
        bytes32[2] memory ids = [askId, bidId];
        for (uint256 i; i < 2; ++i) {
            (, uint256 a, uint256 o, uint128 k, bool isBuy,,) = hook.orderBookOrder(poolId, ids[i]);
            if (a == 0) continue; // fully filled and deleted
            ++checked;
            assertEq(uint256(k), _expectedPriceKey(isBuy, a, o), "stored key = _priceKey(remaining)");
            assertGe(k, 1);
            assertLe(uint256(k), MAX_PRICE_KEY);
        }
    }

    function _checkPriceKeyAfterMatch(uint256 sIn, uint256 sOut, uint256 bIn, uint256 bOut, bool requireMatch)
        internal
        returns (uint256 checked)
    {
        (bytes32 askId, bytes32 bidId,,) = _restPair(sIn, sOut, bIn, bOut);
        uint8 matched = _matchOne();
        if (requireMatch) assertEq(matched, 1, "matched");
        if (matched == 0) return 0;
        checked = _checkPartialKeys(askId, bidId);
    }

    // ------------------------------------------------------------ RadixPriceTree

    function _assertNodeCleared(RadixTreeHarnessB t, uint32 id) internal view {
        RadixPriceTree.Node memory n = t.node(id);
        assertEq(n.parent, 0);
        assertEq(n.left, 0);
        assertEq(n.right, 0);
        assertEq(n.price, 0);
        assertEq(n.bit, 0);
        assertFalse(n.leaf);
    }
}
