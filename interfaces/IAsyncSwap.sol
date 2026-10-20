// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {AsyncOrder} from "./types/AsyncOrder.sol";
import {IAsyncFiller} from "./IAsyncFiller.sol";
import {IFeeVault} from "./IFeeVault.sol";

/// @notice The Async Swap v2 hook (`src/AsyncSwap.huff`): converts an exact-input swap into an open async order,
///         matches crossing orders at the resting limit, and lets authorized executors fill or cancel.
interface IAsyncSwap is IHooks {
    /// @notice `hookData` of `IPoolManager.swap`.
    struct UserParams {
        address user;
        address executor;
        uint256 amountOutMin;
        uint256 priorityFee;
    }

    event HookSwap(
        bytes32 indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint128 hookLPfeeAmount0,
        uint128 hookLPfeeAmount1
    );
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event Swept(Currency indexed currency, address indexed to, uint256 amount);
    event NonceInvalidated(address indexed maker, uint256 nonce);
    event ExecutorSet(PoolId indexed poolId, address indexed maker, address indexed executor, bool allow);
    event AsyncOrdersMatched(
        PoolId indexed poolId,
        bytes32 indexed sellOrderId,
        bytes32 indexed buyOrderId,
        uint256 assetAmount,
        uint256 numeraireAmount
    );
    event AsyncOrderLiquidityFilled(
        PoolId indexed poolId, bytes32 indexed orderId, address indexed maker, uint256 amountIn, uint256 amountOut
    );

    error NotPoolManager();
    error HookNotImplemented();
    error ExactInputOnly();
    error UnaccountedNativeOutput();
    error NotOwner();
    error ZeroAddress();
    error SignatureExpired();
    error InvalidSignature();
    error NonceAlreadyUsed();
    error InvalidNumeraire();
    error NumeraireRequired();
    error DynamicFeeRequired();
    error NotSelf();
    error InvalidMatchBound();
    error PartialLiquidityFill();
    error LimitPriceNotMet();
    error NoActiveLiquidity();

    receive() external payable;

    function poolManager() external view returns (IPoolManager);
    function feeVault() external view returns (IFeeVault);
    function numeraire() external view returns (Currency);
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function nonceUsed(address maker, uint256 nonce) external view returns (bool);
    function asyncOrders(PoolId poolId)
        external
        view
        returns (IPoolManager poolManager, Currency numeraire, address feeVault);
    function getHookPermissions() external pure returns (Hooks.Permissions memory);

    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
    function sweep(Currency currency, address to) external;

    function asyncOrder(PoolId poolId, bytes32 orderId) external view returns (uint256 amountIn);
    function asyncOrderInfo(PoolId poolId, bytes32 orderId)
        external
        view
        returns (uint256 amountIn, uint256 amountOutMin);
    function asyncOrderPriorityFee(PoolId poolId, bytes32 orderId) external view returns (uint256);
    function orderingMode(PoolId poolId) external view returns (IAsyncFiller.OrderingMode);
    function bestOrder(PoolId poolId, bool isBuy)
        external
        view
        returns (bool found, uint128 priceKey, bytes32 orderId, address maker);
    function orderBookLevel(PoolId poolId, bool isBuy, uint128 priceKey)
        external
        view
        returns (bytes32 head, bytes32 tail, uint32 count);
    function orderBookOrder(PoolId poolId, bytes32 orderId)
        external
        view
        returns (
            address maker,
            uint256 amountIn,
            uint256 amountOutMin,
            uint128 priceKey,
            bool isBuy,
            bytes32 previousOrderId,
            bytes32 nextOrderId
        );
    function isExecutor(PoolId poolId, address maker, address executor) external view returns (bool);
    function calculateHookFee(uint256) external pure returns (uint256);
    /// @notice Fee added to the maker's net output: 0.3% of gross output, rounded down.
    function calculatePoolFee(uint24, uint256 amount) external pure returns (uint256);

    function setOrderingMode(PoolKey calldata key, IAsyncFiller.OrderingMode mode) external;
    function recordPriorityFee(PoolKey calldata key, address maker, uint256 amount) external;
    /// @param data abi.encode(filler).
    function executeOrder(AsyncOrder calldata order, bytes calldata data) external;
    function matchNewOrder(AsyncOrder calldata order) external returns (uint8 matched);
    function tryFillOrderFromPoolLiquidity(AsyncOrder calldata order) external returns (bool filled);
    function fillOrderFromPoolLiquidity(AsyncOrder calldata order, bytes32 id) external;
    function matchBook(PoolKey calldata key, uint8 maxMatches) external returns (uint8 matched);
    function updatePrice(AsyncOrder calldata order, uint256 newAmountOutMin) external;
    function cancelOrder(AsyncOrder calldata order) external;
    function setExecutor(PoolId poolId, address executor, bool allow) external;
    function setExecutorWithSig(
        PoolKey calldata key,
        address maker,
        address executor,
        bool allow,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external;
    function updatePriceWithSig(
        AsyncOrder calldata order,
        uint256 newAmountOutMin,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external;
    function invalidateNonce(uint256 nonce) external;
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        );
}
