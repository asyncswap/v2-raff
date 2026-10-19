// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {AsyncOrder} from "../reference/AsyncOrder.sol";
import {IAsyncSwap} from "./IAsyncSwap.sol";
import {ISignatureTransfer} from "../reference/ISignatureTransfer.sol";

/// @notice The Router's ABI (Solidity v2 `Router`), implemented in Huff by `src/Router.huff`.
interface IRouter {
    struct PermitData {
        uint256 nonce;
        uint256 deadline;
        bytes signature;
    }

    struct ExecutorGrant {
        bool present;
        uint256 nonce;
        uint256 deadline;
        bytes signature;
    }

    error NotPoolManager();
    error WrongHook();
    error NotOrderOwner();
    error OrderNotFound(bytes32 id);
    error NativeInputNotSupported();
    error InvalidMsgValue(uint256 expected, uint256 actual);
    error PriceAboveMax(uint256 live, uint256 maxPrice);
    error SignatureExpired(uint256 deadline);
    error NonceAlreadyUsed(address signer, uint256 nonce);
    error InvalidSignature();
    error NativeTransferFailed();

    function manager() external view returns (IPoolManager);
    function hook() external view returns (IAsyncSwap);
    function permit2() external view returns (ISignatureTransfer);
    function MAX_MATCHES() external view returns (uint256);
    function cancelNonceUsed(address signer, uint256 nonce) external view returns (bool);

    function swap(AsyncOrder calldata order) external payable returns (bytes32 id);
    function swapWithSig(AsyncOrder calldata order, PermitData calldata permit, ExecutorGrant calldata grant)
        external
        returns (bytes32 id);
    function fillOrder(AsyncOrder calldata order, uint256 maxPrice)
        external
        payable
        returns (uint256 amountIn, uint256 amountOut, uint256 fee);
    function cancelOrder(AsyncOrder calldata order) external returns (uint256 refund);
    function cancelWithSig(AsyncOrder calldata order, uint256 nonce, uint256 deadline, bytes calldata signature)
        external
        returns (uint256 refund);
    function matchBook(PoolKey calldata key, uint256 maxMatches) external returns (uint256 matches);
    function fillFromPoolLiquidity(AsyncOrder calldata order) external returns (uint256 amountOut);
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

interface IFeeVault {
    error NotPoolManager();
    error Unauthorized();
    error ZeroAddress();

    event FeesCollected(Currency indexed currency, address indexed recipient, uint256 amount);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function manager() external view returns (IPoolManager);
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
    function collect(Currency currency, address recipient) external returns (uint256 amount);
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

interface INativeClaims {
    error NotPoolManager();
    error ZeroAmount();
    error ZeroAddress();

    event Redeemed(address indexed account, address indexed recipient, uint256 amount);

    function manager() external view returns (IPoolManager);
    function redeem(uint256 amount, address recipient) external;
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}
