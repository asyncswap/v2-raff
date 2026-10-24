// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {AsyncOrder} from "./types/AsyncOrder.sol";
import {ISignatureTransfer} from "./ISignatureTransfer.sol";

/// @notice Entry point for makers, fillers and relayers (`src/Router.huff`). Every action goes through
///         `IPoolManager.unlock`.
interface IRouter {
    /// @notice What `unlockCallback` does (`src/Router.huff`'s `ACTION_*` constants).
    enum ActionType {
        Swap,
        FillOrder,
        Cancel,
        SwapWithSig,
        MatchBook,
        PoolLiquidityFill
    }

    /// @notice `unlockCallback`'s data: `abi.encode(SwapCallback)`, then the action's own arguments.
    struct SwapCallback {
        ActionType action;
        AsyncOrder order;
        uint8 maxMatches;
    }

    /// @notice Permit2 signature + nonce/deadline for a signed create.
    struct PermitData {
        uint256 nonce;
        uint256 deadline;
        bytes signature;
    }

    /// @notice Optional signed `SetExecutor` grant; leave `signature` empty when the Router is authorized.
    struct ExecutorGrant {
        uint256 nonce;
        uint256 deadline;
        bytes signature;
    }

    error SignatureExpired();
    error InvalidSignature();
    error NonceAlreadyUsed();

    function PERMIT2() external view returns (ISignatureTransfer);
    /// @dev Historical fixture ABI only: current cancellations share hook.nonceUsed.
    function cancelNonceUsed(address maker, uint256 nonce) external view returns (bool);
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

    /// @notice Submit a new order; `userData` is `abi.encode(IAsyncSwap.UserParams)` with this Router as executor.
    function swap(AsyncOrder calldata order, bytes memory userData) external payable;
    /// @notice Fill an open order, paying its live net price plus the fee, capped at `maxPrice`.
    function fillOrder(AsyncOrder calldata order, uint256 maxPrice, bytes calldata data) external payable;
    function swapWithSig(AsyncOrder calldata order, PermitData calldata permit, ExecutorGrant calldata grant) external;
    function cancelWithSig(AsyncOrder calldata order, uint256 nonce, uint256 deadline, bytes calldata signature)
        external;
    function cancelOrder(AsyncOrder calldata order) external;
    function matchBook(PoolKey calldata key, uint8 maxMatches) external;
    function fillFromPoolLiquidity(AsyncOrder calldata order) external;
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}
