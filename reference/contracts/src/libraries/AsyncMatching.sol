// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ClaimTransfers} from "@async-swap/libraries/ClaimTransfers.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {CurrencySettler} from "@async-swap/libraries/CurrencySettler.sol";
import {IPoolManager, SwapParams} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RadixPriceTree} from "@async-swap/libraries/RadixPriceTree.sol";
import {TickBitmap} from "@async-swap/libraries/TickBitmap.sol";
import {EligiblePrice} from "@async-swap/libraries/EligiblePrice.sol";
import {DynamicFeeOrdering} from "@async-swap/libraries/DynamicFeeOrdering.sol";

/// @notice Linked matching module operating on the hook's order and radix-book storage.
/// @dev Public library calls use DELEGATECALL, so ERC-6909 escrow remains owned by Async Swap.
library AsyncMatching {
    using CurrencySettler for Currency;
    using AsyncFiller for AsyncFiller.Book;
    using AsyncFiller for AsyncFiller.State;
    using PoolIdLibrary for PoolKey;
    using RadixPriceTree for RadixPriceTree.Tree;
    using TickBitmap for TickBitmap.Tree;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeCast for *;
    using StateLibrary for IPoolManager;

    uint8 public constant MAX_MATCHES_PER_CALL = 8;

    struct ReductionParams {
        bytes32 id;
        uint256 inputUsed;
        uint256 outputReceived;
    }

    /// @dev Who receives each leg of a match, read before the matched orders are reduced.
    struct Payouts {
        address sellOwner;
        address buyOwner;
        Currency sellInput;
        Currency buyInput;
        uint256 sellRefund; // input returned to an order left below the pool minimum
        uint256 buyRefund;
    }

    struct FillParams {
        AsyncOrder order;
        bytes32 id;
        address hook;
        address executor;
        address filler;
        address feeVault;
        uint256 fee;
    }

    struct CancelParams {
        AsyncOrder order;
        bytes32 id;
        address hook;
        address executor;
    }

    struct UpdateParams {
        AsyncOrder order;
        bytes32 id;
        uint256 newAmountOutMin;
        address caller;
    }

    event AsyncOrdersMatched(
        PoolId indexed poolId,
        bytes32 indexed sellOrderId,
        bytes32 indexed buyOrderId,
        uint256 assetAmount,
        uint256 numeraireAmount
    );

    error InvalidMatchBound();
    error PartialLiquidityFill();
    error LimitPriceNotMet();
    error NoActiveLiquidity();

    /// @dev LP fee on a pool-liquidity fill, in v4 pips: 0.02%.
    uint24 private constant POOL_LIQUIDITY_FILL_FEE = 200;

    event AsyncOrderLiquidityFilled(
        PoolId indexed poolId, bytes32 indexed orderId, address indexed maker, uint256 amountIn, uint256 amountOut
    );

    function bestOrder(AsyncFiller.State storage self, AsyncFiller.Book storage book, bool isBuy)
        public
        view
        returns (bool found, uint128 price, bytes32 orderId, address owner)
    {
        return self.bestOrder(book, isBuy);
    }

    function fill(AsyncFiller.State storage self, AsyncFiller.Book storage book, FillParams memory params) public {
        self.fill(
            book, params.order, params.id, params.hook, params.executor, params.filler, params.feeVault, params.fee
        );
    }

    function cancel(AsyncFiller.State storage self, AsyncFiller.Book storage book, CancelParams memory params) public {
        self.cancel(book, params.order, params.id, params.hook, params.executor);
    }

    function updatePrice(AsyncFiller.State storage self, AsyncFiller.Book storage book, UpdateParams memory params)
        public
    {
        self.updatePrice(book, params.order, params.id, params.newAmountOutMin, params.caller);
    }

    function matchIncoming(
        AsyncFiller.State storage self,
        AsyncFiller.Book storage book,
        PoolKey calldata key,
        bytes32 incomingId
    ) public returns (uint8 matched) {
        if (self.orders[incomingId].amountIn == 0) revert AsyncFiller.OrderNotFound();
        // Admission has already inserted and funded the order. Use the same book-wide
        // priority rule for arrivals and backlog, sharing one bounded match budget.
        return matchBook(self, book, key, MAX_MATCHES_PER_CALL);
    }

    function matchBook(
        AsyncFiller.State storage self,
        AsyncFiller.Book storage book,
        PoolKey calldata key,
        uint8 maxMatches
    ) public returns (uint8 matched) {
        if (maxMatches == 0 || maxMatches > MAX_MATCHES_PER_CALL) revert InvalidMatchBound();
        ClaimTransfers.Batch memory batch;
        while (matched < maxMatches) {
            (bytes32 bidId, bytes32 askId) = _bookPair(self, book);
            if (bidId == bytes32(0)) break;
            if (!_matchPair(self, book, key, bidId, askId, batch)) break;
            unchecked {
                ++matched;
            }
        }
        ClaimTransfers.flush(batch, self.poolManager);
    }

    function _bookPair(AsyncFiller.State storage self, AsyncFiller.Book storage book)
        private
        view
        returns (bytes32 bidId, bytes32 askId)
    {
        (bool hasBid, uint128 bidPrice) = book.bids.best(true);
        (bool hasAsk, uint128 askPrice) = book.asks.best(false);
        if (!hasBid || !hasAsk || bidPrice < askPrice) return (bytes32(0), bytes32(0));
        bidId = book.bestAtPrice(true, bidPrice);
        askId = book.bestAtPrice(false, askPrice);
        if (_crosses(bidPrice, askPrice, self.orders[bidId], self.orders[askId])) return (bidId, askId);
        return (bytes32(0), bytes32(0));
    }

    /// @notice Execute an order against active v4 LP positions if they meet the signed minimum.
    /// @dev Reverts atomically on insufficient liquidity or output; the caller catches this across a self-call so
    ///      the resting order is preserved. Without a price limit the whole order must fill. With one (the best
    ///      book level, when the pool goes first) the swap may stop there: the filled part must meet the maker's
    ///      limit pro rata, and the rest stays on the book with the maker's own limit for the book to match.
    function fillFromPoolLiquidity(
        AsyncFiller.State storage self,
        AsyncFiller.Book storage book,
        PoolKey calldata key,
        bytes32 id,
        address hook,
        uint160 sqrtPriceLimitX96
    ) public {
        AsyncFiller.OrderInfo storage info = self.orders[id];
        if (info.amountIn == 0) revert AsyncFiller.OrderNotFound();
        (uint256 swapped, uint256 consumed, uint256 amountOut) = _poolFillNet(self, key, id, hook, sqrtPriceLimitX96);
        address maker = info.owner;
        Currency output = info.zeroForOne ? key.currency1 : key.currency0;
        if (consumed == info.amountIn) {
            uint256 priorityFee = info.priorityFee;
            // Close the order before the maker's payout, which can run recipient code.
            AsyncFiller._remove(self, book, id);
            delete self.orders[id];
            output.take(self.poolManager, maker, amountOut, output.isAddressZero());
            AsyncFiller.settlePriorityFee(self, key, id, maker, priorityFee, hook);
        } else {
            // The order stays live, so the output is credited as claims and no recipient code runs. The filled
            // share of the priority bid is spent; a remainder below the minimum is kept for the book to match
            // (`closeBelowMinimum` refunds what the book leaves).
            _reduceAfterPoolFill(self, book, key, id, consumed);
            output.take(self.poolManager, maker, amountOut, true);
        }
        emit AsyncOrderLiquidityFilled(key.toId(), id, maker, swapped, amountOut);
    }

    function _reduceAfterPoolFill(
        AsyncFiller.State storage self,
        AsyncFiller.Book storage book,
        PoolKey calldata key,
        bytes32 id,
        uint256 consumed
    ) private {
        ClaimTransfers.Batch memory batch;
        _reduceAfterMatch(self, book, key, ReductionParams(id, consumed, 0), batch, false);
        ClaimTransfers.flush(batch, self.poolManager);
    }

    /// @notice Close a live order left below the pool minimum and return its input as claims; its unfilled
    ///         priority bid is spent, as for a book match that leaves dust.
    function closeBelowMinimum(
        AsyncFiller.State storage self,
        AsyncFiller.Book storage book,
        PoolKey calldata key,
        bytes32 id
    ) public {
        AsyncFiller.OrderInfo storage info = self.orders[id];
        uint256 amountIn = info.amountIn;
        if (amountIn == 0 || (info.isBuy ? amountIn : info.amountOutMin) >= book.minOrder) return;
        address maker = info.owner;
        Currency input = info.zeroForOne ? key.currency0 : key.currency1;
        ClaimTransfers.Batch memory batch;
        _reduceAfterMatch(self, book, key, ReductionParams(id, 0, 0), batch, true);
        ClaimTransfers.credit(batch, self.poolManager, input, maker, amountIn);
        ClaimTransfers.flush(batch, self.poolManager);
    }

    /// @dev Swap the order's input less the protocol's 0.01% (rounded up, paid to the vault), then take the dynamic
    ///      fee (`DynamicFeeOrdering`) from the output. A swap stopped short at `sqrtPriceLimitX96` pays the 0.01% on
    ///      what it swapped. Returns the input swapped, the input used including the 0.01%, and the net output,
    ///      reverting unless the output meets the maker's limit on the input used.
    function _poolFillNet(
        AsyncFiller.State storage self,
        PoolKey calldata key,
        bytes32 id,
        address hook,
        uint160 sqrtPriceLimitX96
    ) private returns (uint256 swapped, uint256 consumed, uint256 amountOut) {
        AsyncFiller.OrderInfo storage info = self.orders[id];
        uint256 protocolFee = (info.amountIn + 9_999) / 10_000;
        uint256 swapIn = info.amountIn - protocolFee;
        int24 tickBefore;
        (swapped, amountOut, tickBefore) =
            _swapAgainstPool(self.poolManager, key, info.zeroForOne, swapIn, hook, sqrtPriceLimitX96);
        // A swap stopped at the best book level pays the 0.01% on what it swapped; the book takes the rest.
        if (swapped != swapIn) protocolFee = Math.mulDiv(protocolFee, swapped, swapIn, Math.Rounding.Ceil);
        consumed = swapped + protocolFee;
        amountOut -= _chargeFees(self, key, id, protocolFee, tickBefore, amountOut);
        if (amountOut < Math.mulDiv(info.amountOutMin, consumed, info.amountIn, Math.Rounding.Ceil)) {
            revert LimitPriceNotMet();
        }
    }

    /// @dev Pay the 0.01% from the input's escrow to the vault and charge the dynamic fee on the output; returns
    ///      the dynamic fee.
    function _chargeFees(
        AsyncFiller.State storage self,
        PoolKey calldata key,
        bytes32 id,
        uint256 protocolFee,
        int24 tickBefore,
        uint256 amountOut
    ) private returns (uint256) {
        bool zeroForOne = self.orders[id].zeroForOne;
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        self.poolManager.transfer(self.feeVault, input.toId(), protocolFee);
        emit AsyncFiller.OrderFeeAccrued(key.toId(), id, input, protocolFee);
        return
            DynamicFeeOrdering.charge(self, key, id, zeroForOne ? key.currency1 : key.currency0, tickBefore, amountOut);
    }

    function _swapAgainstPool(
        IPoolManager manager,
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        address hook,
        uint160 sqrtPriceLimitX96
    ) private returns (uint256 swapped, uint256 amountOut, int24 tickBefore) {
        if (manager.getLiquidity(key.toId()) == 0) revert NoActiveLiquidity();
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        input.settle(manager, hook, amountIn, true);
        uint24 previousFee;
        (, tickBefore,, previousFee) = manager.getSlot0(key.toId());
        manager.updateDynamicLPFee(key, POOL_LIQUIDITY_FILL_FEE);
        BalanceDelta delta = manager.swap(
            key,
            SwapParams(
                zeroForOne,
                -amountIn.toInt256(),
                // A limit (the best book level) stops the swap there.
                sqrtPriceLimitX96 != 0
                    ? sqrtPriceLimitX96
                    : zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        manager.updateDynamicLPFee(key, previousFee);
        // A fill that runs out of in-range liquidity leaves the pool where no liquidity is active, and the
        // check above would then refuse every later fill: refuse this one instead, so the order uses the book.
        if (manager.getLiquidity(key.toId()) == 0) revert NoActiveLiquidity();
        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        // Without a limit the whole input must be used; with one the swap may stop at it.
        if (sqrtPriceLimitX96 == 0 && inputDelta != -amountIn.toInt128()) revert PartialLiquidityFill();
        if (outputDelta <= 0) revert LimitPriceNotMet();
        swapped = uint256(uint128(-inputDelta));
        // Input the swap left unused goes back into escrow as claims.
        if (swapped < amountIn) manager.mint(hook, input.toId(), amountIn - swapped);
        amountOut = uint256(uint128(outputDelta));
    }

    /// @dev `buyId` comes from the bid tree and `sellId` from the ask tree (`_bookPair`), so their
    ///      sides are fixed by construction.
    function _matchPair(
        AsyncFiller.State storage self,
        AsyncFiller.Book storage book,
        PoolKey calldata key,
        bytes32 buyId,
        bytes32 sellId,
        ClaimTransfers.Batch memory batch
    ) internal returns (bool) {
        AsyncFiller.OrderInfo storage buy = self.orders[buyId];
        AsyncFiller.OrderInfo storage sell = self.orders[sellId];
        if (buy.amountIn == 0 || sell.amountIn == 0) return false;
        // The older order is the maker and sets the price.
        bool makerBuy = buy.createdSequence < sell.createdSequence;
        AsyncFiller.MatchAmounts memory amounts = _matchAmounts(sell, buy, makerBuy);
        if (amounts.assetAmount == 0 || amounts.quoteAmount == 0) return false;

        // Capture recipients before reducing the orders. Claim credits are combined and
        // transferred after the bounded match loop; no underlying token transfer occurs.
        Payouts memory payouts = _payouts(self, key, buyId, sellId);
        (payouts.sellRefund, payouts.buyRefund) = _reduceMatchedOrders(self, book, key, buyId, sellId, amounts, batch);
        _settleTransfers(self.poolManager, self.feeVault, payouts, amounts, batch);
        // Each side's 0.02% comes out of what it receives: the buyer's in the asset, the seller's in the quote.
        emit AsyncFiller.OrderFeeAccrued(
            key.toId(), buyId, payouts.sellInput, AsyncFiller.tradeFee(amounts.assetAmount)
        );
        emit AsyncFiller.OrderFeeAccrued(
            key.toId(), sellId, payouts.buyInput, AsyncFiller.tradeFee(amounts.quoteAmount)
        );
        emit AsyncOrdersMatched(key.toId(), sellId, buyId, amounts.assetAmount, amounts.quoteAmount);
        return true;
    }

    function _matchAmounts(AsyncFiller.OrderInfo memory sell, AsyncFiller.OrderInfo memory buy, bool restingBuy)
        internal
        pure
        returns (AsyncFiller.MatchAmounts memory amounts)
    {
        // Both directions use the same maker/taker sizing. Cap affordability before mulDiv:
        // its uncapped quotient could overflow even though the full maker amount fits.
        AsyncFiller.OrderInfo memory maker = restingBuy ? buy : sell;
        AsyncFiller.OrderInfo memory taker = restingBuy ? sell : buy;
        uint256 used = maker.amountOutMin != 0 && taker.amountIn >= maker.amountOutMin
            ? maker.amountIn
            : Math.mulDiv(taker.amountIn, maker.amountIn, maker.amountOutMin);
        if (used == 0) return amounts;
        uint256 paid = Math.mulDiv(used, maker.amountOutMin, maker.amountIn, Math.Rounding.Ceil);
        if (paid > taker.amountIn || used < Math.mulDiv(paid, taker.amountOutMin, taker.amountIn, Math.Rounding.Ceil)) {
            return AsyncFiller.MatchAmounts(0, 0);
        }
        return restingBuy ? AsyncFiller.MatchAmounts(paid, used) : AsyncFiller.MatchAmounts(used, paid);
    }

    function _payouts(AsyncFiller.State storage self, PoolKey calldata key, bytes32 buyId, bytes32 sellId)
        private
        view
        returns (Payouts memory payouts)
    {
        AsyncFiller.OrderInfo storage buy = self.orders[buyId];
        AsyncFiller.OrderInfo storage sell = self.orders[sellId];
        payouts.sellInput = sell.zeroForOne ? key.currency0 : key.currency1;
        payouts.buyInput = buy.zeroForOne ? key.currency0 : key.currency1;
        payouts.sellOwner = sell.owner;
        payouts.buyOwner = buy.owner;
    }

    /// @dev Each side receives its proceeds less the 0.02% trade fee, which goes to the vault.
    function _settleTransfers(
        IPoolManager manager,
        address feeVault,
        Payouts memory payouts,
        AsyncFiller.MatchAmounts memory amounts,
        ClaimTransfers.Batch memory batch
    ) internal {
        uint256 assetFee = AsyncFiller.tradeFee(amounts.assetAmount);
        uint256 quoteFee = AsyncFiller.tradeFee(amounts.quoteAmount);
        _transferEscrow(manager, payouts.sellInput, payouts.buyOwner, amounts.assetAmount - assetFee, batch);
        _transferEscrow(manager, payouts.buyInput, payouts.sellOwner, amounts.quoteAmount - quoteFee, batch);
        _transferEscrow(manager, payouts.sellInput, feeVault, assetFee, batch);
        _transferEscrow(manager, payouts.buyInput, feeVault, quoteFee, batch);
        if (payouts.sellRefund != 0) {
            _transferEscrow(manager, payouts.sellInput, payouts.sellOwner, payouts.sellRefund, batch);
        }
        if (payouts.buyRefund != 0) {
            _transferEscrow(manager, payouts.buyInput, payouts.buyOwner, payouts.buyRefund, batch);
        }
    }

    function _reduceMatchedOrders(
        AsyncFiller.State storage self,
        AsyncFiller.Book storage book,
        PoolKey calldata key,
        bytes32 buyId,
        bytes32 sellId,
        AsyncFiller.MatchAmounts memory amounts,
        ClaimTransfers.Batch memory batch
    ) private returns (uint256 sellRefund, uint256 buyRefund) {
        sellRefund = _reduceAfterMatch(
            self, book, key, ReductionParams(sellId, amounts.assetAmount, amounts.quoteAmount), batch, true
        );
        buyRefund = _reduceAfterMatch(
            self, book, key, ReductionParams(buyId, amounts.quoteAmount, amounts.assetAmount), batch, true
        );
    }

    function _transferEscrow(
        IPoolManager manager,
        Currency currency,
        address recipient,
        uint256 amount,
        ClaimTransfers.Batch memory batch
    ) private {
        ClaimTransfers.credit(batch, manager, currency, recipient, amount);
    }

    function _reduceAfterMatch(
        AsyncFiller.State storage self,
        AsyncFiller.Book storage book,
        PoolKey calldata key,
        ReductionParams memory params,
        ClaimTransfers.Batch memory batch,
        bool closeDust
    ) internal returns (uint256) {
        AsyncFiller.OrderInfo storage info = self.orders[params.id];
        uint256 oldInput = info.amountIn;
        uint256 remainingInput = oldInput - params.inputUsed;
        uint256 oldPriorityFee = info.priorityFee;
        uint256 unfilledPriorityFee = _settleMatchedPriorityFee(self, key, params.id, params.inputUsed, oldInput, batch);
        // The unfilled input keeps the maker's own limit: price improvement on the filled part is
        // not credited against it. Rounding up never asks less than that limit, and leaves a
        // nonzero minimum for any nonzero remainder.
        uint256 remainingMinimum = Math.mulDiv(info.amountOutMin, remainingInput, oldInput, Math.Rounding.Ceil);

        // The order closes when its input is used up, or when what is left is worth less than the
        // pool minimum by the order's own terms (no pool price involved); the caller then returns
        // the remaining input after both reductions. Settling the unfilled bid calls no maker code.
        if (remainingInput == 0 || (closeDust && (info.isBuy ? remainingInput : remainingMinimum) < book.minOrder)) {
            _creditPriorityFee(self, key, params.id, info.owner, unfilledPriorityFee, batch);
            AsyncFiller._remove(self, book, params.id);
            delete self.orders[params.id];
            return remainingInput;
        }

        info.amountIn = remainingInput;
        info.amountOutMin = remainingMinimum;
        info.priorityFee = uint64(unfilledPriorityFee);
        uint128 updatedPrice = AsyncFiller._priceKey(info.isBuy, info.zeroForOne, remainingInput, remainingMinimum);
        bool priceChanged = updatedPrice != info.price;
        if (priceChanged || unfilledPriorityFee != oldPriorityFee) {
            AsyncFiller._remove(self, book, params.id);
            info.price = updatedPrice;
            if (priceChanged) info.sequence = ++book.nextSequence;
            AsyncFiller._append(self, book, params.id);
        } else {
            AsyncFiller.refreshExactPrice(self, book, params.id);
        }
        return 0;
    }

    function _settleMatchedPriorityFee(
        AsyncFiller.State storage self,
        PoolKey calldata key,
        bytes32 id,
        uint256 inputUsed,
        uint256 oldInput,
        ClaimTransfers.Batch memory batch
    ) private returns (uint256 unfilledPriorityFee) {
        AsyncFiller.OrderInfo storage info = self.orders[id];
        // Every stored bid is escrowed; a zero remainder needs no settlement.
        uint256 oldPriorityFee = info.priorityFee;
        if (oldPriorityFee == 0) return 0;
        uint256 filledPriorityFee = Math.mulDiv(oldPriorityFee, inputUsed, oldInput);
        unfilledPriorityFee = oldPriorityFee - filledPriorityFee;
        // Credit only the share for input that filled. The final claim transfers are in
        // this unlock, so a failed settlement reverts all matching and credits.
        _creditPriorityFee(self, key, id, info.owner, filledPriorityFee, batch);
    }

    function _creditPriorityFee(
        AsyncFiller.State storage self,
        PoolKey calldata key,
        bytes32 id,
        address maker,
        uint256 amount,
        ClaimTransfers.Batch memory batch
    ) internal {
        if (amount == 0) return;
        ClaimTransfers.credit(batch, self.poolManager, self.numeraire, self.feeVault, amount);
        emit AsyncFiller.PriorityFeeForfeited(key.toId(), id, maker, amount);
    }

    /// @notice Decide whether a buy and a sell order cross, i.e. a price exists that satisfies both
    ///         makers' limits.
    /// @dev Keys are the floor ticks of the exact limits, ordered by numeraire per asset, so two
    ///      distinct prices can share a key. Strictly ordered keys decide the result directly,
    ///      since a monotone key cannot invert a strict inequality. Equal keys are decided by a
    ///      full-precision cross-multiply:
    ///
    ///      cross  <=>  buyIn/buyOut >= sellOut/sellIn  <=>  buyIn*sellIn >= sellOut*buyOut
    ///             <=>  floor(buyIn*sellIn / sellOut) >= buyOut   (sellOut, buyOut are nonzero).
    ///
    ///      An exact tie counts as a cross. With equal keys the quotient is on the order of
    ///      `buyOut`, so the `mulDiv` cannot overflow for escrowable amounts.
    function _crosses(
        uint128 buyKey,
        uint128 sellKey,
        AsyncFiller.OrderInfo storage buy,
        AsyncFiller.OrderInfo storage sell
    ) internal view returns (bool) {
        if (buyKey != sellKey) return buyKey > sellKey;
        return Math.mulDiv(buy.amountIn, sell.amountIn, sell.amountOutMin) >= buy.amountOutMin;
    }
}
