// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RadixPriceTree} from "@async-swap/libraries/RadixPriceTree.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MatchingEngine
/// @notice Standalone price-time matching harness. It maintains a radix-indexed
///         limit book and emits deterministic fill instructions.
/// @dev Algorithm and gas benchmark only: it does not custody or settle tokens.
///      Live orders settle through the AsyncSwap hook and AsyncMatching.
contract MatchingEngine {
    using RadixPriceTree for RadixPriceTree.Tree;

    uint128 public constant PRICE_SCALE = 1e18;
    uint8 public constant MAX_MATCHES_PER_CALL = 8;

    struct Order {
        address owner;
        uint128 price;
        uint128 remaining;
        uint64 sequence;
        uint64 previous;
        uint64 next;
        bool isBuy;
        bool active;
    }

    struct Level {
        uint64 head;
        uint64 tail;
        uint32 orderCount;
    }

    struct Book {
        uint64 nextOrderId;
        uint64 nextSequence;
        RadixPriceTree.Tree bids;
        RadixPriceTree.Tree asks;
        mapping(uint128 price => Level) bidLevels;
        mapping(uint128 price => Level) askLevels;
        mapping(uint64 orderId => Order) orders;
    }

    mapping(bytes32 market => Book) private books;
    bool private entered;

    error ZeroAmount();
    error ZeroPrice();
    error InvalidMatchBound();
    error NotOrderOwner();
    error OrderNotFound();
    error ReentrantCall();

    event OrderPlaced(
        bytes32 indexed market,
        uint64 indexed orderId,
        address indexed owner,
        bool isBuy,
        uint128 amount,
        uint128 price,
        uint64 sequence
    );
    event OrderCancelled(bytes32 indexed market, uint64 indexed orderId, address indexed owner);
    event OrderFilled(
        bytes32 indexed market,
        uint64 indexed makerOrderId,
        uint64 indexed takerOrderId,
        uint128 amount,
        uint128 price,
        uint256 quoteAmount
    );

    modifier nonReentrant() {
        if (entered) revert ReentrantCall();
        entered = true;
        _;
        entered = false;
    }

    /// @notice Submit a limit order. Crossing orders match immediately, up to
    ///         eight fills; any remainder rests at its limit price.
    /// @param market Identifier for a pair and settlement domain chosen by the caller.
    /// @param isBuy True for a bid, false for an ask.
    /// @param amount Base quantity in the engine's fixed-point units.
    /// @param price Quote per base, scaled by 1e18.
    function placeOrder(bytes32 market, bool isBuy, uint128 amount, uint128 price)
        external
        nonReentrant
        returns (uint64 orderId)
    {
        if (amount == 0) revert ZeroAmount();
        if (price == 0) revert ZeroPrice();

        Book storage book = books[market];
        orderId = ++book.nextOrderId;
        uint64 sequence = ++book.nextSequence;
        Order storage incoming = book.orders[orderId];
        incoming.owner = msg.sender;
        incoming.price = price;
        incoming.remaining = amount;
        incoming.sequence = sequence;
        incoming.isBuy = isBuy;
        incoming.active = true;

        _matchIncoming(book, market, orderId);
        if (incoming.remaining == 0) delete book.orders[orderId];
        else _append(book, orderId);
        emit OrderPlaced(market, orderId, msg.sender, isBuy, amount, price, sequence);
    }

    /// @notice Continue clearing a crossed book after an order hit its per-call
    ///         fill cap. Work is bounded by `maxMatches` and anyone may call it.
    function matchBook(bytes32 market, uint8 maxMatches) external nonReentrant returns (uint8 matched) {
        if (maxMatches == 0 || maxMatches > MAX_MATCHES_PER_CALL) revert InvalidMatchBound();
        Book storage book = books[market];
        while (matched < maxMatches) {
            if (!_clearBestPair(book, market)) break;
            unchecked {
                ++matched;
            }
        }
    }

    function cancelOrder(bytes32 market, uint64 orderId) external nonReentrant {
        Book storage book = books[market];
        Order storage order = book.orders[orderId];
        if (!order.active) revert OrderNotFound();
        if (order.owner != msg.sender) revert NotOrderOwner();
        _remove(book, orderId);
        emit OrderCancelled(market, orderId, msg.sender);
    }

    function getOrder(bytes32 market, uint64 orderId) external view returns (Order memory) {
        return books[market].orders[orderId];
    }

    function bestPrice(bytes32 market, bool isBuy) external view returns (bool found, uint128 price) {
        Book storage book = books[market];
        return isBuy ? book.bids.best(true) : book.asks.best(false);
    }

    function levelOrderCount(bytes32 market, bool isBuy, uint128 price) external view returns (uint32) {
        Book storage book = books[market];
        return isBuy ? book.bidLevels[price].orderCount : book.askLevels[price].orderCount;
    }

    function _matchIncoming(Book storage book, bytes32 market, uint64 incomingId) private returns (uint8 matched) {
        Order storage incoming = book.orders[incomingId];
        while (matched < MAX_MATCHES_PER_CALL && incoming.remaining != 0) {
            bool incomingBuy = incoming.isBuy;
            (bool found, uint128 opposingPrice) = incomingBuy ? book.asks.best(false) : book.bids.best(true);
            if (!found || (incomingBuy ? incoming.price < opposingPrice : incoming.price > opposingPrice)) break;

            Level storage level = incomingBuy ? book.askLevels[opposingPrice] : book.bidLevels[opposingPrice];
            uint64 makerId = level.head;
            Order storage maker = book.orders[makerId];
            uint128 quantity = incoming.remaining < maker.remaining ? incoming.remaining : maker.remaining;
            _fill(book, market, makerId, incomingId, quantity, maker.price);
            if (maker.remaining == 0) _remove(book, makerId);
            unchecked {
                ++matched;
            }
        }
    }

    function _fill(Book storage book, bytes32 market, uint64 makerId, uint64 takerId, uint128 quantity, uint128 price)
        private
    {
        Order storage maker = book.orders[makerId];
        Order storage taker = book.orders[takerId];
        maker.remaining -= quantity;
        taker.remaining -= quantity;
        uint256 quoteAmount = Math.mulDiv(quantity, price, PRICE_SCALE);
        emit OrderFilled(market, makerId, takerId, quantity, price, quoteAmount);
    }

    function _clearBestPair(Book storage book, bytes32 market) private returns (bool) {
        (bool hasBid, uint128 bidPrice) = book.bids.best(true);
        (bool hasAsk, uint128 askPrice) = book.asks.best(false);
        if (!hasBid || !hasAsk || bidPrice < askPrice) return false;

        _clearOrders(book, market, book.bidLevels[bidPrice].head, book.askLevels[askPrice].head);
        return true;
    }

    function _clearOrders(Book storage book, bytes32 market, uint64 bidId, uint64 askId) private {
        Order storage bid = book.orders[bidId];
        Order storage ask = book.orders[askId];
        uint64 makerId = ask.sequence < bid.sequence ? askId : bidId;
        uint64 takerId = makerId == bidId ? askId : bidId;
        uint128 quantity = bid.remaining < ask.remaining ? bid.remaining : ask.remaining;
        _fill(book, market, makerId, takerId, quantity, book.orders[makerId].price);
        if (bid.remaining == 0) _remove(book, bidId);
        if (ask.remaining == 0) _remove(book, askId);
    }

    function _append(Book storage book, uint64 orderId) private {
        Order storage order = book.orders[orderId];
        Level storage level = order.isBuy ? book.bidLevels[order.price] : book.askLevels[order.price];
        if (level.orderCount == 0) {
            if (order.isBuy) book.bids.insert(order.price);
            else book.asks.insert(order.price);
        }
        order.previous = level.tail;
        if (level.tail == 0) level.head = orderId;
        else book.orders[level.tail].next = orderId;
        level.tail = orderId;
        ++level.orderCount;
    }

    function _remove(Book storage book, uint64 orderId) private {
        Order storage order = book.orders[orderId];
        Level storage level = order.isBuy ? book.bidLevels[order.price] : book.askLevels[order.price];
        if (order.previous == 0) level.head = order.next;
        else book.orders[order.previous].next = order.next;
        if (order.next == 0) level.tail = order.previous;
        else book.orders[order.next].previous = order.previous;
        --level.orderCount;
        if (level.orderCount == 0) {
            if (order.isBuy) book.bids.remove(order.price);
            else book.asks.remove(order.price);
            if (order.isBuy) delete book.bidLevels[order.price];
            else delete book.askLevels[order.price];
        }
        delete book.orders[orderId];
    }
}
