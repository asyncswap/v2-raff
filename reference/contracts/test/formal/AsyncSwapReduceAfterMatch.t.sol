// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalMatchD} from "./FormalMatchD.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapReduceAfterMatch.lean`. `_reduceAfterMatch`
///         is private (`_priceKey` is now `AsyncFiller._priceKey`, the v4 tick key);
///         `_reduceMatchedOrders` runs `_reduceAfterMatch` once per side of a matched pair, reached through `matchBook(key, 1)` (`FormalMatchD`): sell (input asset, output
///         quote), then buy (input quote, output asset). Each side is checked from its storage before
///         and after, `book.nextSequence`, its level, and its events (fee settlements, refund).
contract AsyncSwapReduceAfterMatchFormalTest is FormalMatchD {
    /// @notice formal/Refinement/Swarm/AsyncSwapReduceAfterMatch.lean:95 (stale: the key is now `AsyncFiller._priceKey` = `TickPrice.key`, no longer a WAD ratio clamped to uint128) — `_priceKey` touches no storage and returns the tick key of (remIn, remainingMinimum), in [1, 2·MAX_TICK + 1] (observed as the re-keyed price of a partially matched order).
    function testFuzz_priceKey_ok(uint256[6] memory s, uint8 flags) public {
        Case memory c = _mkCase(s, flags);
        Run memory r = _exec(c);
        if (r.matched == 0) return;
        if (!_closes(r.sell0, r.asset)) _assertKey(c.pid, c.sellId, r.sell1);
        if (!_closes(r.buy0, r.quote)) _assertKey(c.pid, c.buyId, r.buy1);
    }

    function _assertKey(PoolId pid, bytes32 id, AsyncFiller.OrderInfo memory o1) internal view {
        uint256 raw = uint128(uint256(_loadHook(bytes32(_orderSlot(pid, id) + 3))));
        assertEq(raw, AsyncFiller._priceKey(o1.isBuy, o1.zeroForOne, o1.amountIn, o1.amountOutMin), "tick key");
        assertGe(raw, 1, "key >= 1");
        assertLe(raw, uint256(2 * uint256(int256(TickMath.MAX_TICK)) + 1), "key <= 2 * MAX_TICK + 1");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapReduceAfterMatch.lean:149 — closed order (no input or no minimum left): matched fee share settled, `_remove`, `orders[id]` deleted, the unfilled share settled for the owner, then (if input remains) exactly remIn refunded to the owner.
    function testFuzz_reduceAfterMatch_ok_close(uint256[6] memory s, uint8 flags) public {
        Case memory c = _mkCase(s, flags);
        Run memory r = _exec(c);
        if (r.matched == 0) return;
        _assertOps(r.ops, _expected(c, r));
        bool sellClosed = _closes(r.sell0, r.asset);
        bool buyClosed = _closes(r.buy0, r.quote);
        if (sellClosed) _assertClosed(c, c.sellId, r.sell0, r.sell1, r.asset, r.ops);
        if (buyClosed) _assertClosed(c, c.buyId, r.buy0, r.buy1, r.quote, r.ops);
        _assertReductions(c, r);
    }

    function _assertClosed(
        Case memory c,
        bytes32 id,
        AsyncFiller.OrderInfo memory o0,
        AsyncFiller.OrderInfo memory o1,
        uint256 used,
        Op[] memory ops
    ) internal view {
        assertLe(used, o0.amountIn, "inputUsed <= amountIn");
        assertTrue(_isEmpty(o1), "orders[id] deleted");
        (,, uint32 count) = hook.orderBookLevel(c.pid, o0.isBuy, o0.price);
        assertEq(count, 0, "removed from its level");
        Op[] memory fees = _feesOf(ops, id);
        uint256 filled = _filled(o0, used);
        uint256 k;
        if (filled != 0) assertEq(fees[k++].amount, filled, "matched share first");
        if (_paid(o0) - filled != 0) {
            assertEq(fees[k].amount, _paid(o0) - filled, "then the unfilled share");
            assertEq(fees[k++].who, o0.owner, "for the order's owner");
        }
        assertEq(fees.length, k, "no other fee settlement");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapReduceAfterMatch.lean:258 — partial (input and minimum left): amountIn := remIn, amountOutMin := remainingMinimum, priorityFee := unfilled; re-keyed (`_remove`, new price, fresh sequence iff the price moved, `_append`) exactly when the price moved or, in PriorityFee mode, the fee changed.
    function testFuzz_reduceAfterMatch_ok_partial(uint256[6] memory s, uint8 flags) public {
        Case memory c = _mkCase(s, flags);
        Run memory r = _exec(c);
        if (r.matched == 0) return;
        uint64 seq = r.nextSeq0;
        if (_closes(r.sell0, r.asset)) {
            assertTrue(_isEmpty(r.sell1));
        } else {
            assertLe(r.asset, r.sell0.amountIn, "inputUsed <= amountIn");
            seq = _assertPartial(c, c.sellId, r.sell0, r.sell1, r.asset, seq);
            assertLe(_feesOf(r.ops, c.sellId).length, 1, "partial: only the matched share is settled");
        }
        if (_closes(r.buy0, r.quote)) {
            assertTrue(_isEmpty(r.buy1));
        } else {
            assertLe(r.quote, r.buy0.amountIn, "inputUsed <= amountIn");
            seq = _assertPartial(c, c.buyId, r.buy0, r.buy1, r.quote, seq);
            assertLe(_feesOf(r.ops, c.buyId).length, 1, "partial: only the matched share is settled");
        }
        assertEq(r.nextSeq1, seq, "nextSequence + 1 per moved price, nothing else");
    }
}
