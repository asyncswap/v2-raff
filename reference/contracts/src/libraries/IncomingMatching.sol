// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AsyncFiller} from "./AsyncFiller.sol";
import {AsyncOrder} from "../types/AsyncOrder.sol";
import {TickPrice} from "./TickPrice.sol";
import {AsyncMatching} from "./AsyncMatching.sol";
import {ClaimTransfers} from "./ClaimTransfers.sol";
import {CurrencySettler} from "./CurrencySettler.sol";
import {TickBitmap} from "./TickBitmap.sol";
import {EligiblePrice} from "./EligiblePrice.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey, PoolIdLibrary} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev The hook's existing self-call boundary rolls back a failed LP attempt atomically.
interface IIncomingLiquidity {
    function fillOrderFromPoolLiquidity(AsyncOrder calldata order, bytes32 id, uint160 sqrtPriceLimitX96) external;
}

/// @notice Fund a crossing arrival, match it in memory, then index only its remainder.
/// @dev Active LP pools retain the existing storage path. Pending orders cannot match before funding.
library IncomingMatching {
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    bytes32 private constant STAGE = keccak256("asyncswap.incoming.record");
    bytes32 private constant POOL = keccak256("asyncswap.incoming.pool");
    bytes32 private constant ID = keccak256("asyncswap.incoming.id");

    function pending(PoolId poolId) public view returns (bool result) {
        bytes32 slot = POOL;
        bytes32 idSlot = ID;
        assembly ("memory-safe") {
            result := and(iszero(iszero(tload(idSlot))), eq(tload(slot), poolId))
        }
    }

    /// @dev Shared stored-admission wrapper. Keeping it here avoids duplicating admission
    /// bytecode in AsyncMatching, which only needs reductions and settlement for existing orders.
    function addOrder(AsyncFiller.State storage self, AsyncFiller.Book storage book, AsyncFiller.NewOrder memory order)
        public
    {
        AsyncFiller.checkMinimum(book, order.isBuy, order.amountIn, order.amountOutMin);
        AsyncFiller.addOrder(
            self,
            book,
            order.id,
            order.owner,
            order.amountIn,
            order.amountOutMin,
            order.isBuy,
            order.zeroForOne,
            order.priorityFee
        );
    }

    function stage(AsyncFiller.State storage self, AsyncFiller.Book storage book, AsyncFiller.NewOrder memory order)
        public
    {
        // Keep LP routing and its atomic rollback on the established path for liquidity-backed and noncrossing arrivals.
        if (self.poolManager.getLiquidity(order.poolId) != 0 || !_canCross(book, order)) {
            addOrder(self, book, order);
            return;
        }
        AsyncFiller.checkMinimum(book, order.isBuy, order.amountIn, order.amountOutMin);
        if (order.priorityFee > type(uint64).max) revert AsyncFiller.PriorityFeeTooLarge();
        if (order.priorityFee != 0) {
            if (
                order.priorityFee
                    < AsyncFiller.minPriorityFee(order.isBuy ? order.amountIn : order.amountOutMin, book.priorityFeeCap)
            ) revert AsyncFiller.PriorityFeeTooSmall();
            self.numeraire.take(self.poolManager, address(this), order.priorityFee, true);
        }
        uint64 sequence = ++book.nextSequence;
        AsyncFiller.OrderInfo memory info = AsyncFiller.OrderInfo({
            owner: order.owner,
            amountIn: order.amountIn,
            amountOutMin: order.amountOutMin,
            price: AsyncFiller._priceKey(order.isBuy, order.zeroForOne, order.amountIn, order.amountOutMin),
            isBuy: order.isBuy,
            zeroForOne: order.zeroForOne,
            sequence: sequence,
            reprices: 0,
            priorityFee: uint64(order.priorityFee),
            priorityKey: 0,
            createdSequence: sequence
        });
        bytes32 slot = STAGE;
        bytes32 poolSlot = POOL;
        bytes32 idSlot = ID;
        bytes32 id = order.id;
        PoolId poolId = order.poolId;
        // Memory structs use one word per member. Eleven transient words bridge the funding
        // callback without writing persistent order records or price/priority indexes.
        assembly ("memory-safe") {
            tstore(poolSlot, poolId)
            tstore(idSlot, id)
            for { let i := 0 } lt(i, 11) { i := add(i, 1) } {
                tstore(add(slot, i), mload(add(info, mul(i, 32))))
            }
        }
    }

    /// @dev Resting-only arrivals keep ordinary admission. The memory bridge pays off when
    /// an opposite order crosses; repeat full selection after funding because callbacks can reprice.
    function _canCross(AsyncFiller.Book storage book, AsyncFiller.NewOrder memory order) private view returns (bool) {
        (bool found, uint128 price) = TickBitmap.best(order.isBuy ? book.asks : book.bids, !order.isBuy);
        if (!found) return false;
        // The root summary is an exact extremum: no need to traverse the fee/FIFO tree
        // just to ask whether any opposite order crosses. Full selection happens after funding.
        EligiblePrice.Ratio memory other = AsyncFiller.mostPermissiveAtPrice(book, !order.isBuy, price);
        EligiblePrice.Ratio memory limit = EligiblePrice.Ratio(
            order.isBuy ? order.amountIn : order.amountOutMin, order.isBuy ? order.amountOutMin : order.amountIn
        );
        return order.isBuy ? EligiblePrice.le(other, limit) : EligiblePrice.le(limit, other);
    }

    /// @dev Delegatecall keeps escrow and the LP self-call in the hook context, while moving
    /// venue orchestration out of the hook's size-constrained runtime. Funding/auth stay in the Router/hook.
    function matchNewOrder(
        AsyncFiller.State storage self,
        AsyncFiller.Book storage book,
        AsyncOrder calldata order,
        bytes32 id
    ) public returns (uint8 matched) {
        (bool handled, uint8 count) = _matchPending(self, book, order.key, id, order.owner);
        if (handled) return count;
        if (self.orders[id].owner != order.owner || self.orders[id].amountIn == 0) revert AsyncFiller.OrderNotFound();
        (bool poolFirst, uint160 bookLimit) = _poolBeatsBook(self, book, order.key, self.orders[id].isBuy);
        for (uint256 step; step < 2 && self.orders[id].amountIn != 0; ++step) {
            if ((step == 0) == poolFirst) {
                try IIncomingLiquidity(address(this)).fillOrderFromPoolLiquidity(order, id, bookLimit) {} catch {}
            } else {
                matched = AsyncMatching.matchIncoming(self, book, order.key, id);
            }
        }
        if (poolFirst) AsyncMatching.closeBelowMinimum(self, book, order.key, id);
    }

    /// @dev The pool goes first only while its adjusted price beats the best opposite level.
    /// An equal level or empty opposite side leaves the book first; the existing LP limit is unchanged.
    function _poolBeatsBook(
        AsyncFiller.State storage self,
        AsyncFiller.Book storage book,
        PoolKey calldata key,
        bool isBuy
    ) private view returns (bool, uint160) {
        (bool found, uint128 bookKey) = TickBitmap.best(isBuy ? book.asks : book.bids, !isBuy);
        if (!found) return (false, 0);
        return TickPrice.poolBeatsLevel(
            self.poolManager, key.toId(), key.currency1 == self.numeraire, isBuy, bookKey, self.refTick, self.refBlock
        );
    }

    function _matchPending(
        AsyncFiller.State storage self,
        AsyncFiller.Book storage book,
        PoolKey calldata key,
        bytes32 id,
        address owner
    ) private returns (bool handled, uint8 matched) {
        if (!pending(key.toId())) return (false, 0);
        AsyncFiller.OrderInfo memory incoming = _load(id, owner);
        // Funding can call a token contract that adds liquidity. Recheck before choosing the path.
        if (self.poolManager.getLiquidity(key.toId()) != 0) {
            _persist(self, book, id, incoming);
            return (false, 0);
        }
        ClaimTransfers.Batch memory batch;
        while (matched < AsyncMatching.MAX_MATCHES_PER_CALL) {
            bytes32 bid = _best(self, book, incoming, id, true);
            bytes32 ask = _best(self, book, incoming, id, false);
            if (bid == bytes32(0) || ask == bytes32(0)) break;
            if (!_crosses(self, incoming, id, bid, ask)) break;
            if (bid != id && ask != id) {
                if (!AsyncMatching._matchPair(self, book, key, bid, ask, batch)) break;
            } else if (!_match(self, book, key, id, incoming, bid, ask, batch)) {
                break;
            }
            ++matched;
        }
        if (incoming.amountIn != 0) _persist(self, book, id, incoming);
        ClaimTransfers.flush(batch, self.poolManager);
        return (true, matched);
    }

    function _load(bytes32 id, address owner) private returns (AsyncFiller.OrderInfo memory incoming) {
        bytes32 stagedId;
        bytes32 idSlot = ID;
        bytes32 slot = STAGE;
        assembly ("memory-safe") {
            stagedId := tload(idSlot)
            tstore(idSlot, 0)
            for { let i := 0 } lt(i, 11) { i := add(i, 1) } {
                mstore(add(incoming, mul(i, 32)), tload(add(slot, i)))
                tstore(add(slot, i), 0)
            }
        }
        if (stagedId != id || incoming.owner != owner || incoming.amountIn == 0) revert AsyncFiller.OrderNotFound();
    }

    function _crosses(
        AsyncFiller.State storage self,
        AsyncFiller.OrderInfo memory incoming,
        bytes32 id,
        bytes32 bid,
        bytes32 ask
    ) private view returns (bool) {
        AsyncFiller.OrderInfo memory buy = bid == id ? incoming : self.orders[bid];
        AsyncFiller.OrderInfo memory sell = ask == id ? incoming : self.orders[ask];
        if (buy.price != sell.price) return buy.price > sell.price;
        return EligiblePrice.le(
            EligiblePrice.Ratio(sell.amountOutMin, sell.amountIn), EligiblePrice.Ratio(buy.amountIn, buy.amountOutMin)
        );
    }

    function _persist(
        AsyncFiller.State storage self,
        AsyncFiller.Book storage book,
        bytes32 id,
        AsyncFiller.OrderInfo memory info
    ) private {
        self.orders[id] = info;
        AsyncFiller._append(self, book, id);
    }

    function _best(
        AsyncFiller.State storage self,
        AsyncFiller.Book storage book,
        AsyncFiller.OrderInfo memory incoming,
        bytes32 id,
        bool buy
    ) private view returns (bytes32) {
        (bool found,, bytes32 storedId,) = AsyncFiller.bestOrder(self, book, buy);
        if (incoming.amountIn == 0 || incoming.isBuy != buy) return storedId;
        if (!found) return id;
        AsyncFiller.OrderInfo storage other = self.orders[storedId];
        if (incoming.price != other.price) {
            return (buy ? incoming.price > other.price : incoming.price < other.price) ? id : storedId;
        }
        EligiblePrice.Ratio memory a = EligiblePrice.Ratio(
            buy ? incoming.amountIn : incoming.amountOutMin, buy ? incoming.amountOutMin : incoming.amountIn
        );
        EligiblePrice.Ratio memory b =
            EligiblePrice.Ratio(buy ? other.amountIn : other.amountOutMin, buy ? other.amountOutMin : other.amountIn);
        bool ab = EligiblePrice.le(a, b);
        bool ba = EligiblePrice.le(b, a);
        if (ab != ba) return (buy ? ba : ab) ? id : storedId;
        // Re-evaluate the union after each fill: a shrinking bid can yield to a resting order.
        return (incoming.priorityFee != other.priorityFee
                ? incoming.priorityFee > other.priorityFee
                : incoming.sequence < other.sequence)
            ? id
            : storedId;
    }

    function _match(
        AsyncFiller.State storage self,
        AsyncFiller.Book storage book,
        PoolKey calldata key,
        bytes32 id,
        AsyncFiller.OrderInfo memory incoming,
        bytes32 bid,
        bytes32 ask,
        ClaimTransfers.Batch memory batch
    ) private returns (bool) {
        AsyncFiller.OrderInfo memory buy = bid == id ? incoming : self.orders[bid];
        AsyncFiller.OrderInfo memory sell = ask == id ? incoming : self.orders[ask];
        AsyncFiller.MatchAmounts memory amounts =
            AsyncMatching._matchAmounts(sell, buy, buy.createdSequence < sell.createdSequence);
        if (amounts.assetAmount == 0 || amounts.quoteAmount == 0) return false;
        AsyncMatching.Payouts memory payouts;
        payouts.sellOwner = sell.owner;
        payouts.buyOwner = buy.owner;
        payouts.sellInput = sell.zeroForOne ? key.currency0 : key.currency1;
        payouts.buyInput = buy.zeroForOne ? key.currency0 : key.currency1;
        // Sell is reduced first because a rounded price change consumes a new queue sequence.
        payouts.sellRefund = ask == id
            ? _reduce(self, book, key, id, incoming, amounts.assetAmount, batch)
            : AsyncMatching._reduceAfterMatch(
                self,
                book,
                key,
                AsyncMatching.ReductionParams(ask, amounts.assetAmount, amounts.quoteAmount),
                batch,
                true
            );
        payouts.buyRefund = bid == id
            ? _reduce(self, book, key, id, incoming, amounts.quoteAmount, batch)
            : AsyncMatching._reduceAfterMatch(
                self,
                book,
                key,
                AsyncMatching.ReductionParams(bid, amounts.quoteAmount, amounts.assetAmount),
                batch,
                true
            );
        AsyncMatching._settleTransfers(self.poolManager, self.feeVault, payouts, amounts, batch);
        emit AsyncFiller.OrderFeeAccrued(key.toId(), bid, payouts.sellInput, AsyncFiller.tradeFee(amounts.assetAmount));
        emit AsyncFiller.OrderFeeAccrued(key.toId(), ask, payouts.buyInput, AsyncFiller.tradeFee(amounts.quoteAmount));
        emit AsyncMatching.AsyncOrdersMatched(key.toId(), ask, bid, amounts.assetAmount, amounts.quoteAmount);
        return true;
    }

    function _reduce(
        AsyncFiller.State storage self,
        AsyncFiller.Book storage book,
        PoolKey calldata key,
        bytes32 id,
        AsyncFiller.OrderInfo memory info,
        uint256 consumed,
        ClaimTransfers.Batch memory batch
    ) private returns (uint256 refund) {
        uint256 oldInput = info.amountIn;
        uint256 spent = Math.mulDiv(info.priorityFee, consumed, oldInput);
        AsyncMatching._creditPriorityFee(self, key, id, info.owner, spent, batch);
        info.priorityFee -= uint64(spent);
        info.amountIn = oldInput - consumed;
        info.amountOutMin = Math.mulDiv(info.amountOutMin, info.amountIn, oldInput, Math.Rounding.Ceil);
        if (info.amountIn == 0 || (info.isBuy ? info.amountIn : info.amountOutMin) < book.minOrder) {
            AsyncMatching._creditPriorityFee(self, key, id, info.owner, info.priorityFee, batch);
            refund = info.amountIn;
            info.amountIn = 0;
        } else {
            uint128 price = AsyncFiller._priceKey(info.isBuy, info.zeroForOne, info.amountIn, info.amountOutMin);
            if (price != info.price) info.sequence = ++book.nextSequence;
            info.price = price;
        }
    }
}
