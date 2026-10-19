// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {AsyncOrder, AsyncOrderLibrary} from "./AsyncOrder.sol";

/// @title OrderSignatures
/// @notice EIP-712 struct hashes for every signed maker action and the Permit2 witness.
/// @dev Spec: `AsyncSwapSpec/Hashing.lean`. The type strings are transcribed exactly; the theorems there say
///      what each hash binds. `hashOrder` (the Permit2 witness) covers maker, both tokens, the amounts, the bid
///      and the pool — not `sqrtPrice` (never read by v4) nor `salt` (assigned by the hook).
library OrderSignatures {
    using AsyncOrderLibrary for AsyncOrder;

    string internal constant POOL_KEY_TYPE =
        "PoolKey(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)";
    string internal constant ASYNC_ORDER_TYPE =
        "AsyncOrder(address maker,address tokenIn,address tokenOut,uint256 amountIn,uint256 amountOutMin,uint256 priorityFee,PoolKey pool)";
    string internal constant SET_EXECUTOR_TYPE =
        "SetExecutor(address maker,address executor,bool allow,PoolKey pool,uint256 nonce,uint256 deadline)";
    string internal constant UPDATE_PRICE_TYPE =
        "UpdatePrice(address maker,address tokenIn,address tokenOut,uint256 amountIn,uint256 newAmountOutMin,bytes32 orderId,uint256 nonce,uint256 deadline)";
    string internal constant CANCEL_ORDER_TYPE =
        "CancelOrder(address maker,address tokenIn,address tokenOut,uint256 amountIn,bytes32 orderId,uint256 nonce,uint256 deadline)";
    string internal constant TOKEN_PERMISSIONS_TYPE = "TokenPermissions(address token,uint256 amount)";

    bytes32 internal constant POOL_KEY_TYPEHASH = keccak256(bytes(POOL_KEY_TYPE));
    bytes32 internal constant UPDATE_PRICE_TYPEHASH = keccak256(bytes(UPDATE_PRICE_TYPE));
    bytes32 internal constant CANCEL_ORDER_TYPEHASH = keccak256(bytes(CANCEL_ORDER_TYPE));

    /// @dev `keccak256(abi.encodePacked(ASYNC_ORDER_TYPE, POOL_KEY_TYPE))`: EIP-712 appends referenced struct types.
    function asyncOrderTypehash() internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(ASYNC_ORDER_TYPE, POOL_KEY_TYPE));
    }

    function setExecutorTypehash() internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(SET_EXECUTOR_TYPE, POOL_KEY_TYPE));
    }

    /// @dev The string Permit2 appends to its own `PermitWitnessTransferFrom(...)` stub.
    function permit2WitnessType() internal pure returns (string memory) {
        return string(abi.encodePacked("AsyncOrder witness)", ASYNC_ORDER_TYPE, POOL_KEY_TYPE, TOKEN_PERMISSIONS_TYPE));
    }

    function hashPoolKey(PoolKey memory k) internal pure returns (bytes32) {
        return keccak256(abi.encode(POOL_KEY_TYPEHASH, k.currency0, k.currency1, k.fee, k.tickSpacing, k.hooks));
    }

    /// @dev The Permit2 witness (`Hashing.hashOrder`).
    function hashOrder(AsyncOrder memory o) internal pure returns (bytes32) {
        (Currency tokenIn, Currency tokenOut) = o.tokens();
        return keccak256(
            abi.encode(
                asyncOrderTypehash(),
                o.owner,
                tokenIn,
                tokenOut,
                o.amountIn,
                o.amountOutMin,
                o.priorityFee,
                hashPoolKey(o.key)
            )
        );
    }

    function hashSetExecutor(
        PoolKey memory k,
        address maker,
        address executor,
        bool allow,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(setExecutorTypehash(), maker, executor, allow, hashPoolKey(k), nonce, deadline));
    }

    /// @dev `amountIn` is the *stored* input the hook reads, so a reprice signature is bound to the live order.
    function hashUpdatePrice(
        PoolKey memory k,
        address maker,
        bool zeroForOne,
        uint256 amountIn,
        uint256 newAmountOutMin,
        bytes32 orderId,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        (Currency tokenIn, Currency tokenOut) = zeroForOne ? (k.currency0, k.currency1) : (k.currency1, k.currency0);
        return keccak256(
            abi.encode(
                UPDATE_PRICE_TYPEHASH, maker, tokenIn, tokenOut, amountIn, newAmountOutMin, orderId, nonce, deadline
            )
        );
    }

    function hashCancel(
        PoolKey memory k,
        address maker,
        bool zeroForOne,
        uint256 amountIn,
        bytes32 orderId,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        (Currency tokenIn, Currency tokenOut) = zeroForOne ? (k.currency0, k.currency1) : (k.currency1, k.currency0);
        return
            keccak256(abi.encode(CANCEL_ORDER_TYPEHASH, maker, tokenIn, tokenOut, amountIn, orderId, nonce, deadline));
    }
}
