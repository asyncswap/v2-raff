// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

using AsyncOrderLibrary for AsyncOrder global;

/// @notice An async order for a swap in a Uniswap v4 pool (`asyncswap/contracts` `src/types/AsyncOrder.sol`).
/// @param key          The pool the order is placed against.
/// @param owner        The maker who supplied `amountIn` of the input currency.
/// @param zeroForOne   true => input is currency0, output is currency1.
/// @param amountIn     Input the maker escrowed.
/// @param amountOutMin Minimum output the maker accepts; the limit price is `amountOutMin / amountIn`.
/// @param priorityFee  Non-refundable USDC bid for equal-price priority.
/// @param sqrtPrice    Sqrt-price limit passed to `PoolManager.swap` on submission.
/// @param salt         Contract-assigned salt, emitted in `AsyncOrderCreated`; pass `bytes32(0)` on create.
struct AsyncOrder {
    PoolKey key;
    address owner;
    bool zeroForOne;
    uint256 amountIn;
    uint256 amountOutMin;
    uint256 priorityFee;
    uint160 sqrtPrice;
    bytes32 salt;
}

/// @notice Identity and pricing helpers for an `AsyncOrder`.
library AsyncOrderLibrary {
    using PoolIdLibrary for PoolKey;

    /// @notice keccak256(abi.encode(chainid, poolId, owner, zeroForOne, salt)): the hook's order id.
    function orderId(AsyncOrder calldata order) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, order.key.toId(), order.owner, order.zeroForOne, order.salt));
    }

    /// @notice The maker's limit price as 1e18-scaled output per input.
    function priceWad(AsyncOrder calldata order) internal pure returns (uint256) {
        return (order.amountOutMin * 1e18) / order.amountIn;
    }
}
