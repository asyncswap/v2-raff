// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice The order book's types, events and errors (`asyncswap/contracts` `AsyncFiller`), which the hook emits
///         and raises.
interface IAsyncFiller {
    enum OrderingMode {
        FIFO,
        PriorityFee
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
}
