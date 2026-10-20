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
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

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
    using StateLibrary for IPoolManager;

    uint256 private constant PRICE_SCALE = 1e18;
    uint64 internal constant MAX_PRIORITY_FEE = type(uint64).max;
    /// @dev $0.10 in six-decimal USDC base units. Async Swap pools are configured with USDC as numeraire.
    uint64 internal constant MIN_PRIORITY_FEE = 100_000;

    enum OrderingMode {
        FIFO,
        PriorityFee
    }

    /// @notice Open-order record. Filler fills are full-order; direct matches can reduce it
    ///         partially while keeping the remaining input in escrow.
    struct OrderInfo {
        address owner;
        uint256 amountIn;
        uint256 amountOutMin;
        uint128 price;
        bytes32 previous;
        bytes32 next;
        bool isBuy;
        bool zeroForOne;
        uint64 sequence;
        uint64 priorityFee;
        uint128 priorityKey;
        bool priorityFeeEscrowed;
    }

    struct PriceLevel {
        bytes32 head;
        bytes32 tail;
        uint32 orderCount;
        RadixPriceTree.Tree priorityOrders;
        mapping(uint128 priorityKey => bytes32 orderId) priorityOrderIds;
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
    }

    struct State {
        IPoolManager poolManager;
        Currency numeraire;
        address feeVault;
        mapping(bytes32 orderId => OrderInfo) orders;
        mapping(address owner => mapping(address executor => bool)) isExecutor;
    }

    struct Book {
        uint64 nextSequence;
        uint64 openOrderCount;
        OrderingMode orderingMode;
        RadixPriceTree.Tree bids;
        RadixPriceTree.Tree asks;
        mapping(uint128 price => PriceLevel) bidLevels;
        mapping(uint128 price => PriceLevel) askLevels;
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

    event OrderFeeAccrued(bytes32 indexed orderId, Currency indexed currency, uint256 amount);
    event PriorityFeeDonated(PoolId indexed poolId, bytes32 indexed orderId, address indexed maker, uint256 amount);
    event PriorityFeeForfeited(PoolId indexed poolId, bytes32 indexed orderId, address indexed maker, uint256 amount);
    event OrderingModeChanged(PoolId indexed poolId, OrderingMode mode);

    error OrderAlreadyExists();
    error OrderNotFound();
    error NotOrderOwner();
    error NotAuthorizedExecutor();
    error ZeroAmount();
    error PriorityFeeTooLarge();
    error PriorityFeeTooSmall();
    error PriorityFeeNotEscrowed();
    error InvalidOrderingModeChange();

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
        if (book.orderingMode == OrderingMode.FIFO && priorityFee != 0) {
            revert InvalidOrderingModeChange();
        }
        if (book.orderingMode == OrderingMode.PriorityFee && priorityFee < MIN_PRIORITY_FEE) {
            revert PriorityFeeTooSmall();
        }
        if (priorityFee > MAX_PRIORITY_FEE) revert PriorityFeeTooLarge();
        uint128 price = _priceKey(isBuy, amountIn, amountOutMin);
        uint64 sequence = ++book.nextSequence;
        self.orders[id] = OrderInfo({
            owner: owner,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            price: price,
            previous: bytes32(0),
            next: bytes32(0),
            isBuy: isBuy,
            zeroForOne: zeroForOne,
            sequence: sequence,
            priorityFee: uint64(priorityFee),
            // An unpaid bid buys no priority: the order queues as if its bid were 0 until the bid is escrowed.
            priorityKey: _priorityKey(0, sequence),
            priorityFeeEscrowed: priorityFee == 0
        });
        _append(self, book, id);
    }

    function setOrderingMode(Book storage book, PoolId poolId, OrderingMode mode) internal {
        if (book.openOrderCount != 0) revert InvalidOrderingModeChange();
        book.orderingMode = mode;
        emit OrderingModeChanged(poolId, mode);
    }

    function recordPriorityFee(State storage self, Book storage book, bytes32 id, uint256 amount, Currency numeraire)
        internal
    {
        OrderInfo storage info = self.orders[id];
        if (info.amountIn == 0 || info.priorityFeeEscrowed || info.priorityFee != amount || amount == 0) {
            revert PriorityFeeNotEscrowed();
        }
        numeraire.take(self.poolManager, address(this), amount, true);
        info.priorityFeeEscrowed = true;
        // Now that the bid is paid, the order takes the place in its level that the bid earns.
        if (book.orderingMode == OrderingMode.PriorityFee) {
            _remove(self, book, id);
            _append(self, book, id);
        }
    }

    /// @notice The bid an order has actually escrowed. A bid that was never paid counts as 0
    ///         everywhere (priority, settlement, refunds), so an unpaid bid can never block the book.
    function paidPriorityFee(OrderInfo storage info) internal view returns (uint256) {
        return info.priorityFeeEscrowed ? info.priorityFee : 0;
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
        Currency numeraire = self.numeraire;
        if (self.poolManager.getLiquidity(key.toId()) == 0) {
            // No active LP can receive a PoolManager donation, so the non-refundable
            // bid is forfeited to the protocol FeeVault.
            self.numeraire.settle(self.poolManager, hook, amount, true);
            self.numeraire.take(self.poolManager, self.feeVault, amount, true);
            emit PriorityFeeForfeited(key.toId(), id, maker, amount);
            return;
        }
        uint256 amount0 = numeraire == key.currency0 ? amount : 0;
        uint256 amount1 = numeraire == key.currency1 ? amount : 0;
        self.poolManager.donate(key, amount0, amount1, "");
        numeraire.settle(self.poolManager, hook, amount, true);
        emit PriorityFeeDonated(key.toId(), id, maker, amount);
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
        if (book.orderingMode == OrderingMode.FIFO) return (priceLevel.head, priceLevel.tail, priceLevel.orderCount);
        (bool hasHead, uint128 highestKey) = priceLevel.priorityOrders.best(true);
        (bool hasTail, uint128 lowestKey) = priceLevel.priorityOrders.best(false);
        head = hasHead ? priceLevel.priorityOrderIds[highestKey] : bytes32(0);
        tail = hasTail ? priceLevel.priorityOrderIds[lowestKey] : bytes32(0);
        return (head, tail, priceLevel.orderCount);
    }

    function bestAtPrice(Book storage book, bool isBuy, uint128 price) internal view returns (bytes32 id) {
        PriceLevel storage priceLevel = isBuy ? book.bidLevels[price] : book.askLevels[price];
        if (book.orderingMode == OrderingMode.FIFO) return priceLevel.head;
        (, uint128 priorityKey) = priceLevel.priorityOrders.best(true);
        return priceLevel.priorityOrderIds[priorityKey];
    }

    /// @notice Remove an order after a successful full fill against PoolManager liquidity.
    function clearLiquidityFilledOrder(State storage self, Book storage book, bytes32 id) internal {
        OrderInfo storage info = self.orders[id];
        if (info.amountIn == 0) revert OrderNotFound();
        _remove(self, book, id);
        delete self.orders[id];
    }

    function isExecutor(AsyncOrder calldata order, State storage self, address executor) internal view returns (bool) {
        return self.isExecutor[order.owner][executor];
    }

    /// @notice Maker-only price update. The executor (router) is required to be authorized by
    ///         the maker, AND `caller` must equal `order.owner` — both checked here.
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
        uint256 old = info.amountOutMin;
        _remove(self, book, id);
        info.amountOutMin = newAmountOutMin;
        info.price = _priceKey(info.isBuy, info.amountIn, newAmountOutMin);
        // A maker price update re-enters the queue with fresh time priority.
        info.sequence = ++book.nextSequence;
        _append(self, book, id);
        emit AsyncOrderPriceUpdated(order.key.toId(), id, old, newAmountOutMin);
    }

    /// @notice Full-fill. The caller (the hook contract) must be an authorized executor of the
    ///         order owner; `filler` is the actual end-user paying the output and receiving the
    ///         input. Must be invoked from inside an `IPoolManager.unlock` context.
    ///
    /// @dev Settle gross output (native only; ERC20 is pre-settled), pay the signed net minimum to the maker, and mint fee
    ///      claims to the vault. Burn input claims and pay the full input to the filler.
    ///      Both currency deltas net to zero. A failed fill reverts all legs.
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

        _remove(self, book, id);

        // Output side: ERC20 output must already be settled to the hook's credit by the executor
        // (`PoolManager.settleFor(hook)`), so the hook never spends its own token balance. Native
        // output is settled from the filler's same-tx deposit, guarded by the hook's ledger.
        // Then take real tokens straight to the maker — both legs net the hook's output delta to zero.
        if (output.isAddressZero()) output.settle(self.poolManager, hook, amountOutMin + fee, false);
        // Native proceeds are redeemable claims; settlement never invokes native recipients.
        output.take(self.poolManager, order.owner, amountOutMin, output.isAddressZero());

        if (fee != 0) {
            output.take(self.poolManager, feeVault, fee, true);
            emit OrderFeeAccrued(id, output, fee);
        }

        input.settle(self.poolManager, hook, amountIn, true);
        input.take(self.poolManager, filler, amountIn, input.isAddressZero());
        settleOrderPriorityFee(self, order.key, id, hook);
        delete self.orders[id];
        emit AsyncOrderFilled(order.key.toId(), id, filler, amountIn, amountOutMin);
    }

    function settleOrderPriorityFee(State storage self, PoolKey memory key, bytes32 id, address hook) internal {
        OrderInfo storage info = self.orders[id];
        settlePriorityFee(self, key, id, info.owner, paidPriorityFee(info), hook);
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
        // Only a paid bid is settled; an order whose bid was never paid can still always be cancelled.
        uint256 priorityFee = paidPriorityFee(info);

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
        if (book.orderingMode == OrderingMode.PriorityFee) {
            order.priorityKey = _priorityKey(uint64(paidPriorityFee(order)), order.sequence);
            priceLevel.priorityOrders.insert(order.priorityKey);
            priceLevel.priorityOrderIds[order.priorityKey] = id;
        } else {
            // A re-appended order (reprice, or a partial fill that moved its price) still carries the
            // `next` of its old level; it joins as the tail, so it has no successor. Leaving the stale
            // pointer corrupted both levels' lists on the order's next `_remove`.
            order.previous = priceLevel.tail;
            order.next = bytes32(0);
            if (priceLevel.tail == bytes32(0)) priceLevel.head = id;
            else self.orders[priceLevel.tail].next = id;
            priceLevel.tail = id;
        }
        ++priceLevel.orderCount;
        ++book.openOrderCount;
    }

    function _remove(State storage self, Book storage book, bytes32 id) internal {
        OrderInfo storage order = self.orders[id];
        PriceLevel storage priceLevel = order.isBuy ? book.bidLevels[order.price] : book.askLevels[order.price];
        if (book.orderingMode == OrderingMode.PriorityFee) {
            priceLevel.priorityOrders.remove(order.priorityKey);
            delete priceLevel.priorityOrderIds[order.priorityKey];
        } else {
            if (order.previous == bytes32(0)) priceLevel.head = order.next;
            else self.orders[order.previous].next = order.next;
            if (order.next == bytes32(0)) priceLevel.tail = order.previous;
            else self.orders[order.next].previous = order.previous;
        }
        --priceLevel.orderCount;
        --book.openOrderCount;
        if (priceLevel.orderCount == 0) {
            if (order.isBuy) book.bids.remove(order.price);
            else book.asks.remove(order.price);
            if (order.isBuy) delete book.bidLevels[order.price];
            else delete book.askLevels[order.price];
        }
    }

    function _priorityKey(uint64 priorityFee, uint64 sequence) private pure returns (uint128) {
        return (uint128(priorityFee) << 64) | uint128(type(uint64).max - sequence);
    }

    /// @dev WAD-scaled price ratio bounded to the radix key range: a ratio that rounds to zero
    ///      maps to 1 and a ratio above uint128 saturates at the maximum.
    function _priceKey(bool isBuy, uint256 amountIn, uint256 amountOut) private pure returns (uint128) {
        uint256 price =
            isBuy ? Math.mulDiv(amountIn, PRICE_SCALE, amountOut) : Math.mulDiv(amountOut, PRICE_SCALE, amountIn);
        if (price == 0) return 1;
        if (price > type(uint128).max) return type(uint128).max;
        return uint128(price);
    }
}
