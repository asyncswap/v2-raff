// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Standalone price-time matching benchmark (`src/MatchingEngine.huff`): a radix-indexed limit book that
///         emits deterministic fill instructions and custodies nothing.
interface IMatchingEngine {
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

    function PRICE_SCALE() external view returns (uint128);
    function MAX_MATCHES_PER_CALL() external view returns (uint8);
    function placeOrder(bytes32 market, bool isBuy, uint128 amount, uint128 price) external returns (uint64 orderId);
    function matchBook(bytes32 market, uint8 maxMatches) external returns (uint8 matched);
    function cancelOrder(bytes32 market, uint64 orderId) external;
    function getOrder(bytes32 market, uint64 orderId) external view returns (Order memory);
    function bestPrice(bytes32 market, bool isBuy) external view returns (bool found, uint128 price);
    function levelOrderCount(bytes32 market, bool isBuy, uint128 price) external view returns (uint32);
}
