// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

/// @notice The order-book types, errors and constants of `AsyncFiller` (Solidity v2), as the Huff hook keeps them.
library AsyncFiller {
    uint256 internal constant PRICE_SCALE = 1e18;
    uint64 internal constant MIN_PRIORITY_FEE = 100_000;
    uint64 internal constant MAX_PRIORITY_FEE = type(uint64).max;
    uint128 internal constant MAX_PRICE_KEY = type(uint128).max;

    enum OrderingMode {
        FIFO,
        PriorityFee
    }

    struct OrderInfo {
        address owner;
        bool zeroForOne;
        bool buy;
        uint64 priorityFee;
        uint64 sequence;
        uint128 priceKey;
        uint128 priorityKey;
        uint256 amountIn;
        uint256 amountOutMin;
        bytes32 previous;
        bytes32 next;
    }

    error OrderExists(bytes32 id);
    error OrderNotFound(bytes32 id);
    error ZeroAmountIn();
    error ZeroAmountOutMin();
    error PriorityFeeNotAllowed();
    error PriorityFeeTooLow(uint256 priorityFee);
    error PriorityFeeTooHigh(uint256 priorityFee);
    error NotOrderOwner(bytes32 id);
    error BookNotEmpty();

    /// @dev `_priceKey`, as the hook computes it.
    function priceKey(bool buy, uint256 amountIn, uint256 amountOut) internal pure returns (uint128) {
        uint256 raw =
            buy ? Math.mulDiv(amountIn, PRICE_SCALE, amountOut) : Math.mulDiv(amountOut, PRICE_SCALE, amountIn);
        if (raw == 0) return 1;
        if (raw > MAX_PRICE_KEY) return MAX_PRICE_KEY;
        return uint128(raw);
    }
}

/// @notice The Huff `AsyncSwap` hook (`src/AsyncSwap.huff`): the Solidity v2 hook's ABI.
interface IAsyncSwap is IHooks {
    /// @notice `hookData` of the creating swap.
    struct UserParams {
        address user;
        address executor;
        uint256 amountOutMin;
        uint256 priorityFee;
        bytes32 salt;
    }

    error NotPoolManager();
    error NotUnlocked();
    error HookNotImplemented();
    error ExactInputRequired();
    error AmountTooLarge(uint256 amountIn);
    error ExecutorMismatch(address expected, address actual);
    error UnauthorizedExecutor(address maker, address executor);
    error NotOwnerOrExecutor(bytes32 id);
    error InsufficientNativeDeposit(uint256 required, uint256 available);
    error SignatureExpired(uint256 deadline);
    error NonceAlreadyUsed(address signer, uint256 nonce);
    error InvalidSignature();
    error InvalidMaxMatches(uint256 maxMatches);
    error NoActiveLiquidity();
    error PartialLiquidityFill(uint256 amountIn, uint256 swapped);
    error LimitPriceNotMet(uint256 amountOutMin, uint256 amountOut);
    error NativeTransferFailed();
    error NumeraireRequired();
    error DynamicFeeRequired();
    error InvalidNumeraire();
    error Unauthorized();
    error ZeroAddress();

    event OrderCreated(
        PoolId indexed poolId,
        bytes32 indexed id,
        address indexed owner,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 priorityFee,
        bytes32 salt,
        uint64 sequence
    );
    event OrderFilled(
        PoolId indexed poolId, bytes32 indexed id, address indexed filler, uint256 amountIn, uint256 amountOut, uint256 fee
    );
    event OrderCancelled(PoolId indexed poolId, bytes32 indexed id, uint256 refund);
    event OrdersMatched(
        PoolId indexed poolId, bytes32 indexed sellId, bytes32 indexed buyId, uint256 asset, uint256 quote
    );
    event OrderReduced(
        PoolId indexed poolId, bytes32 indexed id, uint256 amountIn, uint256 amountOutMin, uint64 priorityFee
    );
    event OrderClosed(PoolId indexed poolId, bytes32 indexed id, uint256 refund);
    event OrderRepriced(PoolId indexed poolId, bytes32 indexed id, uint256 newAmountOutMin, uint64 sequence);
    event LiquidityFilled(PoolId indexed poolId, bytes32 indexed id, uint256 amountIn, uint256 amountOut);
    event ExecutorSet(PoolId indexed poolId, address indexed maker, address indexed executor, bool allow);
    event NonceInvalidated(address indexed signer, uint256 nonce);
    event OrderingModeSet(PoolId indexed poolId, AsyncFiller.OrderingMode mode);
    event Swept(Currency indexed currency, address indexed to, uint256 amount);
    event PriorityFeeDonated(PoolId indexed poolId, uint256 amount);
    event PriorityFeeForfeited(PoolId indexed poolId, uint256 amount);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function MAX_MATCHES_PER_CALL() external view returns (uint256);
    function POOL_LIQUIDITY_FILL_FEE() external view returns (uint24);
    function manager() external view returns (IPoolManager);
    function feeVault() external view returns (address);
    function numeraire() external view returns (Currency);
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function nonceUsed(address signer, uint256 nonce) external view returns (bool);

    function matchNewOrder(PoolKey calldata key, bytes32 id, uint256 maxMatches) external returns (uint256);
    function matchBook(PoolKey calldata key, uint256 maxMatches) external returns (uint256);
    function executeOrder(PoolKey calldata key, bytes32 id, address filler)
        external
        returns (uint256 amountIn, uint256 amountOut, uint256 fee);
    function cancelOrder(PoolKey calldata key, bytes32 id) external returns (uint256 refund);
    function fillFromPoolLiquidity(PoolKey calldata key, bytes32 id) external returns (uint256 amountOut);
    function updatePrice(PoolKey calldata key, bytes32 id, uint256 newAmountOutMin) external;
    function updatePriceWithSig(
        PoolKey calldata key,
        bytes32 id,
        uint256 newAmountOutMin,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external;
    function setExecutor(PoolKey calldata key, address executor, bool allow) external;
    function setExecutorWithSig(
        PoolKey calldata key,
        address maker,
        address executor,
        bool allow,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external;
    function invalidateNonce(uint256 nonce) external;
    function setOrderingMode(PoolKey calldata key, AsyncFiller.OrderingMode mode) external;
    function sweep(Currency currency, address to) external returns (uint256 amount);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
    function calculatePoolFee(uint24, uint256 amount) external pure returns (uint256);

    function getHookPermissions() external pure returns (Hooks.Permissions memory);
    function getOrder(PoolKey calldata key, bytes32 id) external view returns (AsyncFiller.OrderInfo memory);
    function isExecutor(PoolKey calldata key, address maker, address executor) external view returns (bool);
    function bestOrder(PoolKey calldata key, bool buySide) external view returns (bytes32 id, uint128 priceKey);
    function orderingMode(PoolKey calldata key) external view returns (AsyncFiller.OrderingMode);
    function openOrders(PoolKey calldata key) external view returns (uint256);
    function nextSequence(PoolKey calldata key) external view returns (uint64);
    function lastOrderId() external view returns (bytes32);
    function pendingNativeDeposit() external view returns (uint256);
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
