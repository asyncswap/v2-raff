// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @notice `asyncswap/contracts` `AsyncFiller.OrderInfo`: an open order's fields, by the names the tests use.
///         The Huff packs them differently (`src/lib/Book.huff`); `FormalBase` translates.
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
