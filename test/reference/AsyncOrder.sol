// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

/// @notice An async limit order, as signed by its maker and passed to the Router.
/// @dev Spec: `AsyncSwapSpec/Hashing.lean` (`AsyncOrder`), `AsyncSwapProtocol/V2/Model.lean` (`Order`).
///      `sqrtPrice` is forwarded to the PoolManager as the swap's price limit; because the hook consumes the
///      whole exact input the pool never reads it (`Pool.swap` returns before its limit checks on a zero
///      amount). `salt` is the hook's: `_createOrder` walks it until the order id is free.
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

library AsyncOrderLibrary {
    using PoolIdLibrary for PoolKey;

    /// @dev `keccak256(abi.encode(chainId, poolId, owner, zeroForOne, salt))` — `Hashing.orderId`.
    ///      Amounts are not part of the id, which is why signed cancels and reprices carry a nonce.
    function orderId(PoolId poolId, address owner, bool zeroForOne, bytes32 salt) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, poolId, owner, zeroForOne, salt));
    }

    function orderId(AsyncOrder memory o) internal view returns (bytes32) {
        return orderId(o.key.toId(), o.owner, o.zeroForOne, o.salt);
    }

    /// @dev `OrderSignatures.tokens`: `(tokenIn, tokenOut)` by direction.
    function tokens(AsyncOrder memory o) internal pure returns (Currency tokenIn, Currency tokenOut) {
        return o.zeroForOne ? (o.key.currency0, o.key.currency1) : (o.key.currency1, o.key.currency0);
    }

    function input(AsyncOrder memory o) internal pure returns (Currency) {
        return o.zeroForOne ? o.key.currency0 : o.key.currency1;
    }

    function output(AsyncOrder memory o) internal pure returns (Currency) {
        return o.zeroForOne ? o.key.currency1 : o.key.currency0;
    }
}
