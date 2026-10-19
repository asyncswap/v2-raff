// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {IAsyncSwap as AsyncSwap, AsyncFiller} from "../utils/IAsyncSwap.sol";
import {IRouter} from "../utils/IRouter.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {ISignatureTransfer} from "./ISignatureTransfer.sol";
import {AsyncOrder, AsyncOrderLibrary} from "./AsyncOrder.sol";
import {AsyncMatching} from "./AsyncMatching.sol";
import {CurrencySettler} from "./CurrencySettler.sol";
import {OrderSignatures} from "./OrderSignatures.sol";

/// @title Router (Solidity reference)
/// @notice The user-facing entry points: it opens the PoolManager unlock, moves the maker's / filler's tokens
///         into the PoolManager, and calls the hook. Makers must have granted the Router as their executor
///         (`AsyncSwap.setExecutor`, or a signed grant bundled into `swapWithSig`).
/// @dev Spec: `AsyncSwapProtocol/V2/Model.lean` (`swap`, `matchBook`, `fillOrder`, `cancelOrder`,
///      `cancelWithSig`, `fillFromPoolLiquidity`), `AsyncSwapProtocol/Model.lean` (`swapWithSig`),
///      `AsyncSwapSpec/Hashing.lean` (`routerPermit_inj`, `hashCancel_inj`, domain separation).
contract Router is IUnlockCallback, EIP712 {
    using AsyncOrderLibrary for AsyncOrder;
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;
    AsyncSwap public immutable hook;
    ISignatureTransfer public immutable permit2;

    uint256 public constant MAX_MATCHES = AsyncMatching.MAX_MATCHES_PER_CALL;

    /// @notice Unordered nonces for signed cancels (this contract's EIP-712 domain).
    mapping(address => mapping(uint256 => bool)) public cancelNonceUsed;

    enum Action {
        Create,
        Fill,
        Cancel,
        MatchBook,
        LiquidityFill
    }

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

    struct CreateData {
        AsyncOrder order;
        bool usePermit;
        PermitData permit;
    }

    struct FillData {
        PoolKey key;
        bytes32 id;
        address filler;
        Currency output;
        uint256 live;
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

    constructor(IPoolManager _manager, AsyncSwap _hook, ISignatureTransfer _permit2) EIP712("AsyncSwapRouter", "2") {
        manager = _manager;
        hook = _hook;
        permit2 = _permit2;
    }

    /* ─────────────────────────────────── create ─────────────────────────────────── */

    /// @notice `Router.swap`: open an order for `msg.sender`. ERC-20 input and bid are pulled with the maker's
    ///         allowance to this contract; a native input is `msg.value`. Then the order is matched against the
    ///         book up to `MAX_MATCHES` times.
    function swap(AsyncOrder calldata order) external payable returns (bytes32 id) {
        _checkHook(order.key);
        if (order.owner != msg.sender) revert NotOrderOwner();
        Currency input = order.input();
        if (input.isAddressZero()) {
            if (msg.value != order.amountIn) revert InvalidMsgValue(order.amountIn, msg.value);
        } else if (msg.value != 0) {
            revert InvalidMsgValue(0, msg.value);
        }
        bytes memory result =
            manager.unlock(abi.encode(Action.Create, abi.encode(CreateData(order, false, PermitData(0, 0, "")))));
        id = abi.decode(result, (bytes32));
    }

    /// @notice `Router.swapWithSig`: a relayer opens an order the maker signed. The input is pulled through
    ///         Permit2 with the order as witness (`hashOrder`); an optional signed executor grant for this
    ///         contract is applied first. ERC-20 input only. A non-zero bid is pulled with the maker's allowance.
    function swapWithSig(AsyncOrder calldata order, PermitData calldata permit, ExecutorGrant calldata grant)
        external
        returns (bytes32 id)
    {
        _checkHook(order.key);
        if (order.input().isAddressZero()) revert NativeInputNotSupported();
        if (grant.present && !hook.isExecutor(order.key, order.owner, address(this))) {
            hook.setExecutorWithSig(
                order.key, order.owner, address(this), true, grant.nonce, grant.deadline, grant.signature
            );
        }
        bytes memory result = manager.unlock(abi.encode(Action.Create, abi.encode(CreateData(order, true, permit))));
        id = abi.decode(result, (bytes32));
    }

    /* ──────────────────────────────────── fill ──────────────────────────────────── */

    /// @notice `Router.fillOrder`: pay the live gross output — stored minimum plus fee — capped by `maxPrice`,
    ///         and receive the whole escrow. A native output is `msg.value`, exactly the live price.
    function fillOrder(AsyncOrder calldata order, uint256 maxPrice)
        external
        payable
        returns (uint256 amountIn, uint256 amountOut, uint256 fee)
    {
        _checkHook(order.key);
        bytes32 id = order.orderId();
        AsyncFiller.OrderInfo memory info = hook.getOrder(order.key, id);
        if (info.amountIn == 0) revert OrderNotFound(id);
        uint256 live = info.amountOutMin + hook.calculatePoolFee(order.key.fee, info.amountOutMin);
        if (live > maxPrice) revert PriceAboveMax(live, maxPrice);

        Currency output = info.zeroForOne ? order.key.currency1 : order.key.currency0;
        if (output.isAddressZero()) {
            if (msg.value != live) revert InvalidMsgValue(live, msg.value);
            (bool ok,) = address(hook).call{value: live}("");
            if (!ok) revert NativeTransferFailed();
        } else if (msg.value != 0) {
            revert InvalidMsgValue(0, msg.value);
        }

        bytes memory result =
            manager.unlock(abi.encode(Action.Fill, abi.encode(FillData(order.key, id, msg.sender, output, live))));
        return abi.decode(result, (uint256, uint256, uint256));
    }

    /* ─────────────────────────────────── cancel ─────────────────────────────────── */

    /// @notice `Router.cancelOrder`: the maker cancels; the remaining escrow is refunded, the bid is not.
    function cancelOrder(AsyncOrder calldata order) external returns (uint256 refund) {
        _checkHook(order.key);
        if (order.owner != msg.sender) revert NotOrderOwner();
        bytes memory result = manager.unlock(abi.encode(Action.Cancel, abi.encode(order.key, order.orderId())));
        refund = abi.decode(result, (uint256));
    }

    /// @notice `Router.cancelWithSig`: the maker signs `CancelOrder(maker, tokenIn, tokenOut, amountIn(stored),
    ///         orderId, nonce, deadline)` in this contract's domain; anyone submits it.
    function cancelWithSig(AsyncOrder calldata order, uint256 nonce, uint256 deadline, bytes calldata signature)
        external
        returns (uint256 refund)
    {
        _checkHook(order.key);
        bytes32 id = order.orderId();
        AsyncFiller.OrderInfo memory info = hook.getOrder(order.key, id);
        if (info.amountIn == 0) revert OrderNotFound(id);
        if (block.timestamp > deadline) revert SignatureExpired(deadline);
        if (cancelNonceUsed[info.owner][nonce]) revert NonceAlreadyUsed(info.owner, nonce);
        cancelNonceUsed[info.owner][nonce] = true;
        bytes32 digest = _hashTypedDataV4(
            OrderSignatures.hashCancel(order.key, info.owner, info.zeroForOne, info.amountIn, id, nonce, deadline)
        );
        if (!SignatureChecker.isValidSignatureNow(info.owner, digest, signature)) revert InvalidSignature();
        bytes memory result = manager.unlock(abi.encode(Action.Cancel, abi.encode(order.key, id)));
        refund = abi.decode(result, (uint256));
    }

    /* ────────────────────────────── keeper entry points ────────────────────────────── */

    /// @notice `Router.matchBook`: anyone continues a crossed book, at most `maxMatches ≤ MAX_MATCHES` times.
    function matchBook(PoolKey calldata key, uint256 maxMatches) external returns (uint256 matches) {
        _checkHook(key);
        bytes memory result = manager.unlock(abi.encode(Action.MatchBook, abi.encode(key, maxMatches)));
        matches = abi.decode(result, (uint256));
    }

    /// @notice `fillFromPoolLiquidity`: anyone swaps an order's escrow through the pool when that meets its minimum.
    function fillFromPoolLiquidity(AsyncOrder calldata order) external returns (uint256 amountOut) {
        _checkHook(order.key);
        bytes memory result = manager.unlock(abi.encode(Action.LiquidityFill, abi.encode(order.key, order.orderId())));
        amountOut = abi.decode(result, (uint256));
    }

    /* ─────────────────────────────── unlock callback ─────────────────────────────── */

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotPoolManager();
        (Action action, bytes memory payload) = abi.decode(data, (Action, bytes));
        if (action == Action.Create) {
            return abi.encode(_create(abi.decode(payload, (CreateData))));
        }
        if (action == Action.Fill) {
            return _fill(abi.decode(payload, (FillData)));
        }
        if (action == Action.Cancel) {
            (PoolKey memory key, bytes32 id) = abi.decode(payload, (PoolKey, bytes32));
            return abi.encode(hook.cancelOrder(key, id));
        }
        if (action == Action.MatchBook) {
            (PoolKey memory key, uint256 maxMatches) = abi.decode(payload, (PoolKey, uint256));
            return abi.encode(hook.matchBook(key, maxMatches));
        }
        (PoolKey memory lkey, bytes32 lid) = abi.decode(payload, (PoolKey, bytes32));
        return abi.encode(hook.fillFromPoolLiquidity(lkey, lid));
    }

    /// @dev `swapBody`: `PoolManager.swap` → `beforeSwap` opens the order and takes the input and bid as the
    ///      hook's claims; the Router settles the maker's input for itself and the bid for the hook; then the
    ///      new order is matched.
    function _create(CreateData memory d) private returns (bytes32 id) {
        AsyncOrder memory o = d.order;
        manager.swap(
            o.key,
            SwapParams({
                zeroForOne: o.zeroForOne, amountSpecified: -int256(o.amountIn), sqrtPriceLimitX96: o.sqrtPrice
            }),
            abi.encode(AsyncSwap.UserParams(o.owner, address(this), o.amountOutMin, o.priorityFee, o.salt))
        );
        id = hook.lastOrderId();

        Currency input = o.input();
        if (input.isAddressZero()) {
            manager.settle{value: o.amountIn}();
        } else if (d.usePermit) {
            manager.sync(input);
            permit2.permitWitnessTransferFrom(
                ISignatureTransfer.PermitTransferFrom({
                    permitted: ISignatureTransfer.TokenPermissions(Currency.unwrap(input), o.amountIn),
                    nonce: d.permit.nonce,
                    deadline: d.permit.deadline
                }),
                ISignatureTransfer.SignatureTransferDetails(address(manager), o.amountIn),
                o.owner,
                OrderSignatures.hashOrder(o),
                OrderSignatures.permit2WitnessType(),
                d.permit.signature
            );
            manager.settle();
        } else {
            input.settle(manager, o.owner, o.amountIn, false);
        }

        if (o.priorityFee != 0) {
            Currency numeraire = hook.numeraire();
            manager.sync(numeraire);
            IERC20Minimal(Currency.unwrap(numeraire)).transferFrom(o.owner, address(manager), o.priorityFee);
            manager.settleFor(address(hook));
        }

        hook.matchNewOrder(o.key, id, MAX_MATCHES);
    }

    /// @dev `fillBody`: an ERC-20 output is pulled from the filler and credited to the hook; a native output
    ///      was forwarded to the hook before the unlock.
    function _fill(FillData memory f) private returns (bytes memory) {
        if (!f.output.isAddressZero()) {
            manager.sync(f.output);
            IERC20Minimal(Currency.unwrap(f.output)).transferFrom(f.filler, address(manager), f.live);
            manager.settleFor(address(hook));
        }
        (uint256 amountIn, uint256 amountOut, uint256 fee) = hook.executeOrder(f.key, f.id, f.filler);
        return abi.encode(amountIn, amountOut, fee);
    }

    function _checkHook(PoolKey calldata key) private view {
        if (address(key.hooks) != address(hook)) revert WrongHook();
    }
}
