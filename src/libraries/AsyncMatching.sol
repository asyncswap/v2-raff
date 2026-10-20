// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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

/// @notice Linked matching module operating on the hook's order and radix-book storage.
/// @dev Public library calls use DELEGATECALL, so ERC-6909 escrow remains owned by Async Swap.
library AsyncMatching {
    using CurrencySettler for Currency;
    using AsyncFiller for AsyncFiller.Book;
    using AsyncFiller for AsyncFiller.State;
    using PoolIdLibrary for PoolKey;
    using RadixPriceTree for RadixPriceTree.Tree;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeCast for *;
    using StateLibrary for IPoolManager;

    uint256 private constant PRICE_SCALE = 1e18;
    uint8 public constant MAX_MATCHES_PER_CALL = 8;

    struct ReductionParams {
        bytes32 id;
        uint256 inputUsed;
        uint256 outputReceived;
        Currency inputCurrency;
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

    uint24 private constant POOL_LIQUIDITY_FILL_FEE = 3_000;

    event AsyncOrderLiquidityFilled(
        PoolId indexed poolId, bytes32 indexed orderId, address indexed maker, uint256 amountIn, uint256 amountOut
    );

    function addOrder(AsyncFiller.State storage self, AsyncFiller.Book storage book, AsyncFiller.NewOrder memory order)
        public
    {
        self.addOrder(
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

    function setOrderingMode(AsyncFiller.Book storage book, PoolId poolId, AsyncFiller.OrderingMode mode) public {
        book.setOrderingMode(poolId, mode);
    }

    function recordPriorityFee(
        AsyncFiller.State storage self,
        AsyncFiller.Book storage book,
        bytes32 id,
        uint256 amount,
        Currency numeraire
    ) public {
        self.recordPriorityFee(book, id, amount, numeraire);
    }

    function bestOrder(AsyncFiller.State storage self, AsyncFiller.Book storage book, bool isBuy)
        public
        view
        returns (bool found, uint128 price, bytes32 orderId, address owner)
    {
        return self.bestOrder(book, isBuy);
    }

    function level(AsyncFiller.Book storage book, bool isBuy, uint128 price)
        public
        view
        returns (bytes32 head, bytes32 tail, uint32 orderCount)
    {
        return book.level(isBuy, price);
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
        bytes32 incomingId,
        address hook
    ) public returns (uint8 matched) {
        AsyncFiller.OrderInfo storage incoming = self.orders[incomingId];
        if (incoming.amountIn == 0) revert AsyncFiller.OrderNotFound();

        while (matched < MAX_MATCHES_PER_CALL && incoming.amountIn != 0) {
            bool incomingBuy = incoming.isBuy;
            (bool found, uint128 opposingPrice) = incomingBuy ? book.asks.best(false) : book.bids.best(true);
            if (!found) break;

            bytes32 makerId = book.bestAtPrice(!incomingBuy, opposingPrice);
            if (makerId == bytes32(0)) break;
            // Order the pair as (buy, sell) for the exact cross test regardless of incoming side.
            bool crosses = incomingBuy
                ? _crosses(incoming.price, opposingPrice, self.orders[incomingId], self.orders[makerId])
                : _crosses(opposingPrice, incoming.price, self.orders[makerId], self.orders[incomingId]);
            if (!crosses) break;
            if (!_matchPair(self, book, key, incomingId, makerId, hook)) break;
            unchecked {
                ++matched;
            }
        }
    }

    function matchBook(
        AsyncFiller.State storage self,
        AsyncFiller.Book storage book,
        PoolKey calldata key,
        uint8 maxMatches,
        address hook
    ) public returns (uint8 matched) {
        if (maxMatches == 0 || maxMatches > MAX_MATCHES_PER_CALL) revert InvalidMatchBound();
        while (matched < maxMatches) {
            (bool hasBid, uint128 bidPrice) = book.bids.best(true);
            (bool hasAsk, uint128 askPrice) = book.asks.best(false);
            if (!hasBid || !hasAsk) break;
            bytes32 bidId = book.bestAtPrice(true, bidPrice);
            bytes32 askId = book.bestAtPrice(false, askPrice);
            if (!_crosses(bidPrice, askPrice, self.orders[bidId], self.orders[askId])) break;
            if (!_matchPair(self, book, key, bidId, askId, hook)) break;
            unchecked {
                ++matched;
            }
        }
    }

    /// @notice Execute an order against active v4 LP positions if they meet the signed minimum.
    /// @dev Reverts atomically on insufficient liquidity/output or partial execution. The caller
    ///      catches this across a self-call so the resting order is preserved.
    function fillFromPoolLiquidity(
        AsyncFiller.State storage self,
        AsyncFiller.Book storage book,
        PoolKey calldata key,
        bytes32 id,
        address maker,
        address hook
    ) public {
        AsyncFiller.OrderInfo storage info = self.orders[id];
        uint256 amountIn = info.amountIn;
        uint256 amountOutMin = info.amountOutMin;
        if (amountIn == 0) revert AsyncFiller.OrderNotFound();
        uint256 amountOut = _swapAgainstPool(self.poolManager, key, info.zeroForOne, amountIn, amountOutMin, hook);
        uint256 priorityFee = AsyncFiller.paidPriorityFee(info);
        Currency output = info.zeroForOne ? key.currency1 : key.currency0;
        output.take(self.poolManager, maker, amountOut, output.isAddressZero());
        AsyncFiller._remove(self, book, id);
        delete self.orders[id];
        AsyncFiller.settlePriorityFee(self, key, id, maker, priorityFee, hook);
        emit AsyncOrderLiquidityFilled(key.toId(), id, maker, amountIn, amountOut);
    }

    function _swapAgainstPool(
        IPoolManager manager,
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMin,
        address hook
    ) private returns (uint256 amountOut) {
        if (manager.getLiquidity(key.toId()) == 0) revert NoActiveLiquidity();
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        input.settle(manager, hook, amountIn, true);
        (,,, uint24 previousFee) = manager.getSlot0(key.toId());
        manager.updateDynamicLPFee(key, POOL_LIQUIDITY_FILL_FEE);
        BalanceDelta delta = manager.swap(
            key,
            SwapParams(
                zeroForOne, -amountIn.toInt256(), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        manager.updateDynamicLPFee(key, previousFee);
        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta != -amountIn.toInt128()) revert PartialLiquidityFill();
        if (outputDelta <= 0 || uint256(uint128(outputDelta)) < amountOutMin) revert LimitPriceNotMet();
        return uint256(uint128(outputDelta));
    }

    function _matchPair(
        AsyncFiller.State storage self,
        AsyncFiller.Book storage book,
        PoolKey calldata key,
        bytes32 firstId,
        bytes32 secondId,
        address hook
    ) private returns (bool) {
        AsyncFiller.OrderInfo storage first = self.orders[firstId];
        AsyncFiller.OrderInfo storage second = self.orders[secondId];
        if (first.amountIn == 0 || second.amountIn == 0 || first.isBuy == second.isBuy) return false;
        bytes32 sellId = first.isBuy ? secondId : firstId;
        bytes32 buyId = first.isBuy ? firstId : secondId;
        bool makerBuy = first.sequence < second.sequence ? first.isBuy : second.isBuy;
        AsyncFiller.MatchAmounts memory amounts = _matchAmounts(self.orders[sellId], self.orders[buyId], makerBuy);
        if (amounts.assetAmount == 0 || amounts.quoteAmount == 0) return false;

        _settleTransfers(self, key, firstId, secondId, amounts, hook);
        _reduceMatchedOrders(self, book, key, firstId, secondId, amounts, hook);
        emit AsyncOrdersMatched(key.toId(), sellId, buyId, amounts.assetAmount, amounts.quoteAmount);
        return true;
    }

    function _matchAmounts(AsyncFiller.OrderInfo storage sell, AsyncFiller.OrderInfo storage buy, bool restingBuy)
        private
        view
        returns (AsyncFiller.MatchAmounts memory amounts)
    {
        if (restingBuy) {
            amounts.quoteAmount = Math.mulDiv(sell.amountIn, buy.amountIn, buy.amountOutMin);
            if (amounts.quoteAmount > buy.amountIn) amounts.quoteAmount = buy.amountIn;
            if (amounts.quoteAmount == 0) return amounts;
            amounts.assetAmount = Math.mulDiv(amounts.quoteAmount, buy.amountOutMin, buy.amountIn, Math.Rounding.Ceil);
            if (amounts.assetAmount > sell.amountIn) return AsyncFiller.MatchAmounts(0, 0);
            uint256 sellerMinimum =
                Math.mulDiv(amounts.assetAmount, sell.amountOutMin, sell.amountIn, Math.Rounding.Ceil);
            if (amounts.quoteAmount < sellerMinimum) return AsyncFiller.MatchAmounts(0, 0);
        } else {
            amounts.assetAmount = Math.mulDiv(buy.amountIn, sell.amountIn, sell.amountOutMin);
            if (amounts.assetAmount > sell.amountIn) amounts.assetAmount = sell.amountIn;
            if (amounts.assetAmount == 0) return amounts;
            amounts.quoteAmount = Math.mulDiv(amounts.assetAmount, sell.amountOutMin, sell.amountIn, Math.Rounding.Ceil);
            if (amounts.quoteAmount > buy.amountIn) return AsyncFiller.MatchAmounts(0, 0);
            uint256 buyerMinimum = Math.mulDiv(amounts.quoteAmount, buy.amountOutMin, buy.amountIn, Math.Rounding.Ceil);
            if (amounts.assetAmount < buyerMinimum) return AsyncFiller.MatchAmounts(0, 0);
        }
    }

    function _settleTransfers(
        AsyncFiller.State storage self,
        PoolKey calldata key,
        bytes32 firstId,
        bytes32 secondId,
        AsyncFiller.MatchAmounts memory amounts,
        address hook
    ) private {
        AsyncFiller.OrderInfo storage first = self.orders[firstId];
        AsyncFiller.OrderInfo storage second = self.orders[secondId];
        Currency firstInput = first.zeroForOne ? key.currency0 : key.currency1;
        Currency secondInput = second.zeroForOne ? key.currency0 : key.currency1;
        Currency sellInput = first.isBuy ? secondInput : firstInput;
        Currency buyInput = first.isBuy ? firstInput : secondInput;
        address sellOwner = first.isBuy ? second.owner : first.owner;
        address buyOwner = first.isBuy ? first.owner : second.owner;

        _transferEscrow(self.poolManager, sellInput, buyOwner, amounts.assetAmount, hook);
        _transferEscrow(self.poolManager, buyInput, sellOwner, amounts.quoteAmount, hook);
    }

    function _reduceMatchedOrders(
        AsyncFiller.State storage self,
        AsyncFiller.Book storage book,
        PoolKey calldata key,
        bytes32 firstId,
        bytes32 secondId,
        AsyncFiller.MatchAmounts memory amounts,
        address hook
    ) private {
        bool firstBuy = self.orders[firstId].isBuy;
        bytes32 sellId = firstBuy ? secondId : firstId;
        bytes32 buyId = firstBuy ? firstId : secondId;
        Currency sellInput = self.orders[sellId].zeroForOne ? key.currency0 : key.currency1;
        Currency buyInput = self.orders[buyId].zeroForOne ? key.currency0 : key.currency1;
        _reduceAfterMatch(
            self, book, key, ReductionParams(sellId, amounts.assetAmount, amounts.quoteAmount, sellInput), hook
        );
        _reduceAfterMatch(
            self, book, key, ReductionParams(buyId, amounts.quoteAmount, amounts.assetAmount, buyInput), hook
        );
    }

    function _transferEscrow(IPoolManager manager, Currency currency, address recipient, uint256 amount, address hook)
        private
    {
        currency.settle(manager, hook, amount, true);
        // Native output is minted as claims, so settlement makes no call to the recipient.
        currency.take(manager, recipient, amount, currency.isAddressZero());
    }

    function _reduceAfterMatch(
        AsyncFiller.State storage self,
        AsyncFiller.Book storage book,
        PoolKey calldata key,
        ReductionParams memory params,
        address hook
    ) private {
        AsyncFiller.OrderInfo storage info = self.orders[params.id];
        uint256 oldInput = info.amountIn;
        uint256 oldMinimum = info.amountOutMin;
        address orderOwner = info.owner;
        uint256 remainingInput = oldInput - params.inputUsed;
        uint256 remainingMinimum = params.outputReceived >= oldMinimum ? 0 : oldMinimum - params.outputReceived;
        uint256 oldPriorityFee = info.priorityFee;
        uint256 unfilledPriorityFee = _settleMatchedPriorityFee(self, key, params.id, params.inputUsed, oldInput, hook);

        if (remainingInput == 0 || remainingMinimum == 0) {
            AsyncFiller._remove(self, book, params.id);
            delete self.orders[params.id];
            AsyncFiller.settlePriorityFee(self, key, params.id, orderOwner, unfilledPriorityFee, hook);
            if (remainingInput != 0) {
                params.inputCurrency.settle(self.poolManager, hook, remainingInput, true);
                params.inputCurrency
                    .take(self.poolManager, orderOwner, remainingInput, params.inputCurrency.isAddressZero());
            }
            return;
        }

        info.amountIn = remainingInput;
        info.amountOutMin = remainingMinimum;
        info.priorityFee = uint64(unfilledPriorityFee);
        uint128 updatedPrice = _priceKey(info.isBuy, remainingInput, remainingMinimum);
        bool priceChanged = updatedPrice != info.price;
        if (
            priceChanged
                || (book.orderingMode == AsyncFiller.OrderingMode.PriorityFee && unfilledPriorityFee != oldPriorityFee)
        ) {
            AsyncFiller._remove(self, book, params.id);
            info.price = updatedPrice;
            if (priceChanged) info.sequence = ++book.nextSequence;
            AsyncFiller._append(self, book, params.id);
        }
    }

    function _settleMatchedPriorityFee(
        AsyncFiller.State storage self,
        PoolKey calldata key,
        bytes32 id,
        uint256 inputUsed,
        uint256 oldInput,
        address hook
    ) private returns (uint256 unfilledPriorityFee) {
        AsyncFiller.OrderInfo storage info = self.orders[id];
        // A bid that was never paid counts as 0, so it neither blocks the match nor gets paid out.
        uint256 oldPriorityFee = AsyncFiller.paidPriorityFee(info);
        if (oldPriorityFee == 0) return 0;
        uint256 filledPriorityFee = Math.mulDiv(oldPriorityFee, inputUsed, oldInput);
        unfilledPriorityFee = oldPriorityFee - filledPriorityFee;
        // A proportional share is earned only for the input that actually filled. The
        // donation is in this unlock, so a failed fill reverts the bid settlement too.
        AsyncFiller.settlePriorityFee(self, key, id, info.owner, filledPriorityFee, hook);
    }

    function _priceKey(bool isBuy, uint256 amountIn, uint256 amountOut) private pure returns (uint128) {
        uint256 price =
            isBuy ? Math.mulDiv(amountIn, PRICE_SCALE, amountOut) : Math.mulDiv(amountOut, PRICE_SCALE, amountIn);
        if (price == 0) return 1;
        if (price > type(uint128).max) return type(uint128).max;
        return uint128(price);
    }

    /// @notice Decide whether a buy and a sell order cross, i.e. a price exists that satisfies both
    ///         makers' limits.
    /// @dev The `uint128` price keys on the book are truncated WAD ratios, so two distinct prices
    ///      can share a key. Strictly ordered keys decide the result directly, since truncation
    ///      cannot invert a strict inequality. Equal keys are decided by a full-precision
    ///      cross-multiply:
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
    ) private view returns (bool) {
        if (buyKey != sellKey) return buyKey > sellKey;
        return Math.mulDiv(buy.amountIn, sell.amountIn, sell.amountOutMin) >= buy.amountOutMin;
    }
}
