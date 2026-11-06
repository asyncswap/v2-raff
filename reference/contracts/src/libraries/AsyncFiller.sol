// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {CurrencySettler} from "@async-swap/libraries/CurrencySettler.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RadixPriceTree} from "@async-swap/libraries/RadixPriceTree.sol";
import {TickBitmap} from "@async-swap/libraries/TickBitmap.sol";
import {EligiblePrice} from "@async-swap/libraries/EligiblePrice.sol";
import {TickPrice} from "@async-swap/libraries/TickPrice.sol";

/// @title AsyncFiller
/// @author @msakiart
/// @notice Stores open async orders and settles fills against them.
///
/// @dev    Authorization model: the maker authorizes a Router/executor at order-creation time
///         (`setExecutor[owner][executor] = true`). All subsequent fill / cancel / updatePrice
///         calls on the hook must come from that registered executor. The hook forwards its
///         immediate caller (`msg.sender`) and the resolved end-actor address (filler / canceller)
///         into this library; the executor is checked here, and PM settlement targets the actor.
library AsyncFiller {
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using RadixPriceTree for RadixPriceTree.Tree;
    using TickBitmap for TickBitmap.Tree;

    uint64 internal constant MAX_PRIORITY_FEE = type(uint64).max;
    /// @dev Default $0.10 cap for six-decimal numeraires. A pool may override this for other decimals.
    uint64 internal constant MIN_PRIORITY_FEE = 100_000;
    /// @dev Below a $100 order the least bid is 10 bps of the order instead: min($0.10, 0.1% of it).
    uint256 internal constant PRIORITY_FEE_BPS = 10;
    /// @dev Protocol fee on what each side of a book match or filler fill receives: 0.02%.
    uint256 internal constant TRADE_FEE_BPS = 2;

    /// @notice Open-order record. Filler fills are full-order; direct matches can reduce it
    ///         partially while keeping the remaining input in escrow.
    struct OrderInfo {
        address owner;
        uint256 amountIn;
        uint256 amountOutMin;
        uint128 price;
        bool isBuy;
        bool zeroForOne;
        uint64 sequence;
        /// @dev Maker reprices so far; signed reprices commit to it (`OrderSignatures.hashUpdatePrice`).
        uint32 reprices;
        /// @dev The bid, escrowed as hook claims since the order was created.
        uint64 priorityFee;
        uint128 priorityKey;
        /// @dev Immutable settlement age; repricing only resets queue sequence.
        uint64 createdSequence;
    }

    /// @dev Orders at one price, highest bid first, then earliest.
    struct PriceLevel {
        uint32 orderCount;
        RadixPriceTree.Tree priorityOrders;
        mapping(uint128 priorityKey => bytes32 orderId) priorityOrderIds;
        mapping(uint32 nodeId => EligiblePrice.Ratio) exactBounds;
    }

    struct MatchAmounts {
        uint256 assetAmount;
        uint256 quoteAmount;
    }

    struct NewOrder {
        bytes32 id;
        address owner;
        uint256 amountIn;
        uint256 amountOutMin;
        bool isBuy;
        bool zeroForOne;
        uint256 priorityFee;
        PoolId poolId;
    }

    struct State {
        IPoolManager poolManager;
        Currency numeraire;
        address feeVault;
        mapping(bytes32 orderId => OrderInfo) orders;
        mapping(address owner => mapping(address executor => bool)) isExecutor;
        /// @dev Pool tick before the first pool fill of the current backrun window, and that fill's block.
        int24 refTick;
        uint64 refBlock;
    }

    struct Book {
        uint64 nextSequence;
        uint64 openOrderCount;
        /// @dev $0.10 in this pool's numeraire base units. Zero uses the six-decimal default.
        uint64 priorityFeeCap;
        TickBitmap.Tree bids;
        TickBitmap.Tree asks;
        mapping(uint128 price => PriceLevel) bidLevels;
        mapping(uint128 price => PriceLevel) askLevels;
        /// @dev Least order size in numeraire base units (0: none); see `checkMinimum`.
        uint256 minOrder;
        /// @dev Least asset amount an order may trade, from the asset's decimals and the hook's precision.
        uint256 minAssetAmount;
    }

    event AsyncOrderCreated(
        PoolId indexed poolId,
        bytes32 indexed orderId,
        address indexed owner,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMin,
        bytes32 salt
    );

    event AsyncOrderPriceUpdated(
        PoolId indexed poolId, bytes32 indexed orderId, uint256 oldAmountOutMin, uint256 newAmountOutMin
    );

    event AsyncOrderFilled(
        PoolId indexed poolId, bytes32 indexed orderId, address indexed filler, uint256 amountIn, uint256 amountOutMin
    );

    event AsyncOrderCancelled(PoolId indexed poolId, bytes32 indexed orderId, address indexed owner, uint256 amountIn);

    event OrderFeeAccrued(PoolId indexed poolId, bytes32 indexed orderId, Currency indexed currency, uint256 amount);
    event PriorityFeeDonated(PoolId indexed poolId, bytes32 indexed orderId, address indexed maker, uint256 amount);
    event PriorityFeeForfeited(PoolId indexed poolId, bytes32 indexed orderId, address indexed maker, uint256 amount);

    error OrderAlreadyExists();
    error OrderNotFound();
    error NotOrderOwner();
    error NotAuthorizedExecutor();
    error ZeroAmount();
    error PriorityFeeTooLarge();
    error PriorityFeeTooSmall();
    error BelowMinimumOrder();
    error BelowMinimumAssetAmount();

    function addOrder(
        State storage self,
        Book storage book,
        bytes32 id,
        address owner,
        uint256 amountIn,
        uint256 amountOutMin,
        bool isBuy,
        bool zeroForOne,
        uint256 priorityFee
    ) internal {
        // A priority bid is optional. Nonzero bids must meet the minimum to avoid dust bids;
        // zero bids remain in the time-priority queue behind any paid bids at the same price.
        if (priorityFee > MAX_PRIORITY_FEE) revert PriorityFeeTooLarge();
        // Escrow the bid now: minting the hook's claims leaves the hook owing the bid to the
        // PoolManager, so the unlock that creates the order cannot end until the bid is paid
        // (the Router does `settleFor(hook)`), exactly as the swap delta makes it pay the input.
        if (priorityFee != 0) {
            if (priorityFee < minPriorityFee(isBuy ? amountIn : amountOutMin, book.priorityFeeCap)) {
                revert PriorityFeeTooSmall();
            }
            self.numeraire.take(self.poolManager, address(this), priorityFee, true);
        }
        uint128 price = _priceKey(isBuy, zeroForOne, amountIn, amountOutMin);
        uint64 sequence = ++book.nextSequence;
        self.orders[id] = OrderInfo({
            owner: owner,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            price: price,
            isBuy: isBuy,
            zeroForOne: zeroForOne,
            sequence: sequence,
            reprices: 0,
            priorityFee: uint64(priorityFee),
            priorityKey: _priorityKey(uint64(priorityFee), sequence),
            createdSequence: sequence
        });
        _append(self, book, id);
    }

    /// @notice The protocol's 0.02% of a payment, rounded up. Each side of a trade receives its
    ///         proceeds less this fee, so a maker receives at least `amountOutMin` minus 0.02%.
    function tradeFee(uint256 amount) internal pure returns (uint256) {
        return Math.mulDiv(amount, TRADE_FEE_BPS, 10_000, Math.Rounding.Ceil);
    }

    /// @notice The least bid for an order worth `notional` numeraire units: $0.10, or 0.1% of the
    ///         order when that is less (orders under $100).
    function minPriorityFee(uint256 notional) internal pure returns (uint256) {
        return minPriorityFee(notional, MIN_PRIORITY_FEE);
    }

    function minPriorityFee(uint256 notional, uint64 cap) internal pure returns (uint256) {
        // 10 bps is exactly 1/1000; integer division preserves the existing rounding down.
        uint256 tiered = notional / (10_000 / PRIORITY_FEE_BPS);
        uint256 effectiveCap = cap == 0 ? MIN_PRIORITY_FEE : cap;
        return tiered < effectiveCap ? tiered : effectiveCap;
    }

    /// @notice Reverts unless the order's numeraire leg is at least the pool's minimum (a buy's input, a
    ///         sell's minimum output) and its asset leg at least the pool's asset floor (a sell's input, a buy's minimum
    ///         output). Neither reads the pool price, which whoever initializes the pool sets.
    function checkMinimum(Book storage book, bool isBuy, uint256 amountIn, uint256 amountOutMin) internal view {
        if ((isBuy ? amountIn : amountOutMin) < book.minOrder) revert BelowMinimumOrder();
        if ((isBuy ? amountOutMin : amountIn) < book.minAssetAmount) revert BelowMinimumAssetAmount();
    }

    function settlePriorityFee(
        State storage self,
        PoolKey memory key,
        bytes32 id,
        address maker,
        uint256 amount,
        address hook
    ) internal {
        if (amount == 0) return;
        // Priority bids fund the protocol independently of instantaneous LP liquidity.
        self.poolManager.transfer(self.feeVault, self.numeraire.toId(), amount);
        emit PriorityFeeForfeited(key.toId(), id, maker, amount);
    }

    function bestOrder(State storage self, Book storage book, bool isBuy)
        internal
        view
        returns (bool found, uint128 price, bytes32 orderId, address owner)
    {
        (found, price) = isBuy ? book.bids.best(true) : book.asks.best(false);
        if (found) {
            orderId = bestAtPrice(book, isBuy, price);
            owner = self.orders[orderId].owner;
        }
    }

    function level(Book storage book, bool isBuy, uint128 price)
        internal
        view
        returns (bytes32 head, bytes32 tail, uint32 orderCount)
    {
        PriceLevel storage priceLevel = isBuy ? book.bidLevels[price] : book.askLevels[price];
        (bool hasHead, uint128 highestKey) = priceLevel.priorityOrders.best(true);
        (bool hasTail, uint128 lowestKey) = priceLevel.priorityOrders.best(false);
        head = hasHead ? priceLevel.priorityOrderIds[highestKey] : bytes32(0);
        tail = hasTail ? priceLevel.priorityOrderIds[lowestKey] : bytes32(0);
        return (head, tail, priceLevel.orderCount);
    }

    function bestAtPrice(Book storage book, bool isBuy, uint128 price) internal view returns (bytes32 id) {
        // The exact extremum comes first; fee and age break exact-price ties.
        return eligibleAtPrice(book, isBuy, price, mostPermissiveAtPrice(book, isBuy, price));
    }

    /// @notice Maker-only price update: `caller` must equal `order.owner` (the maker directly, or the
    ///         owner whose signature `updatePriceWithSig` verified). No executor is involved.
    function updatePrice(
        State storage self,
        Book storage book,
        AsyncOrder memory order,
        bytes32 id,
        uint256 newAmountOutMin,
        address caller
    ) internal {
        if (caller != order.owner) revert NotOrderOwner();
        if (newAmountOutMin == 0) revert ZeroAmount();
        OrderInfo storage info = self.orders[id];
        if (info.amountIn == 0) revert OrderNotFound();
        checkMinimum(book, info.isBuy, info.amountIn, newAmountOutMin);
        uint256 old = info.amountOutMin;
        // A nonzero sell bid floor follows its minimum output. Zero remains a valid no-bid order.
        if (!info.isBuy && info.priorityFee != 0) {
            uint256 required = minPriorityFee(newAmountOutMin, book.priorityFeeCap);
            if (newAmountOutMin > old && info.priorityFee < required) revert PriorityFeeTooSmall();
        }
        _remove(self, book, id);
        info.amountOutMin = newAmountOutMin;
        info.price = _priceKey(info.isBuy, info.zeroForOne, info.amountIn, newAmountOutMin);
        // A maker price update re-enters the queue with fresh time priority.
        info.sequence = ++book.nextSequence;
        ++info.reprices;
        _append(self, book, id);
        emit AsyncOrderPriceUpdated(order.key.toId(), id, old, newAmountOutMin);
    }

    /// @notice Full-fill. The caller (the hook contract) must be an authorized executor of the
    ///         order owner; `filler` is the actual end-user paying the output and receiving the
    ///         input. Must be invoked from inside an `IPoolManager.unlock` context.
    ///
    /// @dev Settle gross output (native only; ERC20 is pre-settled), pay the signed minimum less the trade fee to the
    ///      maker, and mint fee claims to the vault. Burn input claims and pay the input less the trade fee to the
    ///      filler. Both currency deltas net to zero. A failed fill reverts all legs.
    function fill(
        State storage self,
        Book storage book,
        AsyncOrder memory order,
        bytes32 id,
        address hook,
        address executor,
        address filler,
        address feeVault,
        uint256 fee
    ) internal {
        if (!self.isExecutor[order.owner][executor]) revert NotAuthorizedExecutor();
        OrderInfo storage info = self.orders[id];
        uint256 amountIn = info.amountIn;
        uint256 amountOutMin = info.amountOutMin;
        if (amountIn == 0) revert OrderNotFound();

        Currency input = order.zeroForOne ? order.key.currency0 : order.key.currency1;
        Currency output = order.zeroForOne ? order.key.currency1 : order.key.currency0;

        // Close the order before any payout: an ERC20 transfer can run recipient code, which must
        // not find this order still live. Its bid settles to the vault, never to the maker.
        _closeOrder(self, book, order.key, id, hook);

        // Output side: ERC20 output must already be settled to the hook's credit by the executor
        // (`PoolManager.settleFor(hook)`), so the hook never spends its own token balance. Native
        // output is settled from the filler's same-tx deposit, guarded by the hook's ledger.
        // Then take real tokens straight to the maker — both legs net the hook's output delta to zero.
        if (output.isAddressZero()) output.settle(self.poolManager, hook, amountOutMin + fee, false);
        // Native proceeds are redeemable claims; settlement never invokes native recipients.
        uint256 tradeFeeOut = tradeFee(amountOutMin);
        output.take(self.poolManager, order.owner, amountOutMin - tradeFeeOut, output.isAddressZero());

        fee += tradeFeeOut;
        if (fee != 0) {
            output.take(self.poolManager, feeVault, fee, true);
            emit OrderFeeAccrued(order.key.toId(), id, output, fee);
        }

        // `fee` now holds the filler's trade fee on the input (reused to keep the stack shallow).
        fee = _payFiller(self, input, hook, filler, feeVault, amountIn);
        if (fee != 0) emit OrderFeeAccrued(order.key.toId(), id, input, fee);
        emit AsyncOrderFilled(order.key.toId(), id, filler, amountIn, amountOutMin);
    }

    /// @dev Burn the order's input claims and pay the filler all but the trade fee, which goes to the vault.
    function _payFiller(
        State storage self,
        Currency input,
        address hook,
        address filler,
        address feeVault,
        uint256 amountIn
    ) private returns (uint256 tradeFeeIn) {
        tradeFeeIn = tradeFee(amountIn);
        input.settle(self.poolManager, hook, amountIn, true);
        input.take(self.poolManager, filler, amountIn - tradeFeeIn, input.isAddressZero());
        if (tradeFeeIn != 0) input.take(self.poolManager, feeVault, tradeFeeIn, true);
    }

    /// @dev Remove and delete an order, then settle its bid.
    function _closeOrder(State storage self, Book storage book, PoolKey memory key, bytes32 id, address hook) private {
        OrderInfo storage info = self.orders[id];
        uint256 priorityFee = info.priorityFee;
        address maker = info.owner;
        _remove(self, book, id);
        delete self.orders[id];
        settlePriorityFee(self, key, id, maker, priorityFee, hook);
    }

    function settleOrderPriorityFee(State storage self, PoolKey memory key, bytes32 id, address hook) internal {
        OrderInfo storage info = self.orders[id];
        settlePriorityFee(self, key, id, info.owner, info.priorityFee, hook);
    }

    /// @notice Cancel an unfilled order. Must be called inside an unlock context. Auth: `executor`
    ///         must be either the order owner themselves (smart-contract makers calling the hook
    ///         directly from their own unlock) or an executor the maker authorised via
    ///         `setExecutor`. Funds always return to `order.owner`.
    function cancel(
        State storage self,
        Book storage book,
        AsyncOrder memory order,
        bytes32 id,
        address hook,
        address executor
    ) internal {
        if (executor != order.owner && !self.isExecutor[order.owner][executor]) {
            revert NotAuthorizedExecutor();
        }
        OrderInfo storage info = self.orders[id];
        uint256 amountIn = info.amountIn;
        if (amountIn == 0) revert OrderNotFound();
        uint256 priorityFee = info.priorityFee;

        Currency input = order.zeroForOne ? order.key.currency0 : order.key.currency1;
        _remove(self, book, id);
        delete self.orders[id];

        // Burn the hook's 6909 input claim, then return real input tokens to the maker
        // as native claims or real ERC20 tokens, depending on the input currency.
        input.settle(self.poolManager, hook, amountIn, true);
        input.take(self.poolManager, order.owner, amountIn, input.isAddressZero());
        settlePriorityFee(self, order.key, id, order.owner, priorityFee, hook);

        emit AsyncOrderCancelled(order.key.toId(), id, order.owner, amountIn);
    }

    function _append(State storage self, Book storage book, bytes32 id) internal {
        OrderInfo storage order = self.orders[id];
        PriceLevel storage priceLevel = order.isBuy ? book.bidLevels[order.price] : book.askLevels[order.price];
        if (priceLevel.orderCount == 0) {
            if (order.isBuy) book.bids.insert(order.price);
            else book.asks.insert(order.price);
        }
        order.priorityKey = _priorityKey(order.priorityFee, order.sequence);
        priceLevel.priorityOrders.insert(order.priorityKey);
        refreshExactPrice(self, book, id);
        priceLevel.priorityOrderIds[order.priorityKey] = id;
        ++priceLevel.orderCount;
        ++book.openOrderCount;
    }

    function _remove(State storage self, Book storage book, bytes32 id) internal {
        OrderInfo storage order = self.orders[id];
        PriceLevel storage priceLevel = order.isBuy ? book.bidLevels[order.price] : book.askLevels[order.price];
        EligiblePrice.remove(priceLevel.priorityOrders, priceLevel.exactBounds, order.priorityKey, order.isBuy);
        delete priceLevel.priorityOrderIds[order.priorityKey];
        --priceLevel.orderCount;
        --book.openOrderCount;
        if (priceLevel.orderCount == 0) {
            // The emptied level is left in place: its tree is empty (root 0). Deleting it would also
            // clear the tree's `freeIds`, a cost that grows with the level's historical peak; kept,
            // those ids are reused at this price.
            if (order.isBuy) book.bids.remove(order.price);
            else book.asks.remove(order.price);
        }
    }

    function _priorityKey(uint64 priorityFee, uint64 sequence) private pure returns (uint128) {
        return (uint128(priorityFee) << 64) | uint128(type(uint64).max - sequence);
    }

    /// @dev Refresh even when a partial fill changes neither the price key nor remaining bid.
    function refreshExactPrice(State storage self, Book storage book, bytes32 id) internal {
        OrderInfo storage order = self.orders[id];
        PriceLevel storage l = order.isBuy ? book.bidLevels[order.price] : book.askLevels[order.price];
        EligiblePrice.refresh(l.priorityOrders, l.exactBounds, order.priorityKey, exactPrice(order), order.isBuy);
    }

    function exactPrice(OrderInfo storage order) internal view returns (EligiblePrice.Ratio memory) {
        return order.isBuy
            ? EligiblePrice.Ratio(order.amountIn, order.amountOutMin)
            : EligiblePrice.Ratio(order.amountOutMin, order.amountIn);
    }

    function eligibleAtPrice(Book storage book, bool isBuy, uint128 price, EligiblePrice.Ratio memory limit)
        internal
        view
        returns (bytes32)
    {
        PriceLevel storage l = isBuy ? book.bidLevels[price] : book.askLevels[price];
        (bool found, uint128 rank) = EligiblePrice.best(l.priorityOrders, l.exactBounds, limit, isBuy);
        return found ? l.priorityOrderIds[rank] : bytes32(0);
    }

    function mostPermissiveAtPrice(Book storage book, bool isBuy, uint128 price)
        internal
        view
        returns (EligiblePrice.Ratio memory)
    {
        PriceLevel storage l = isBuy ? book.bidLevels[price] : book.askLevels[price];
        return l.exactBounds[l.priorityOrders.root];
    }

    /// @dev The order's book level: the v4 tick of its exact limit, ordered by numeraire per asset
    ///      (see `TickPrice.key`). The exact limit is kept on the order and decides crossing.
    function _priceKey(bool isBuy, bool zeroForOne, uint256 amountIn, uint256 amountOut)
        internal
        pure
        returns (uint128)
    {
        return TickPrice.key(isBuy, zeroForOne, amountIn, amountOut);
    }
}
