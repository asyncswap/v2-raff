// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {AsyncMatching} from "@async-swap/libraries/AsyncMatching.sol";
import {OrderSignatures} from "@async-swap/libraries/OrderSignatures.sol";
import {AsyncOrder, AsyncOrderLibrary} from "@async-swap/types/AsyncOrder.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {CurrencySettler} from "@async-swap/libraries/CurrencySettler.sol";
import {IPoolManager, ModifyLiquidityParams, SwapParams} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {FeeVault} from "src/FeeVault.sol";
import {BaseHook} from "src/BaseHook.sol";

/// @title AsyncSwap
/// @author @msakiart
/// @notice Uniswap v4 hook that converts an exact-input swap into an open async order: the maker
///         deposits their input via `_beforeSwap`. Crossing orders settle directly at the resting
///         limit; fillers settle unmatched orders.
///
///         Makers can also act by EIP-712 signature (`setExecutorWithSig`, `updatePriceWithSig`) so a
///         relayer pays gas and the wallet shows a readable message. See `OrderSignatures` for types.
contract AsyncSwap is BaseHook, EIP712 {
    using SafeCast for *;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using AsyncFiller for AsyncFiller.State;
    using AsyncFiller for AsyncFiller.Book;
    using AsyncOrderLibrary for AsyncOrder;

    /// @notice Per-pool order book.
    mapping(PoolId poolId => AsyncFiller.State) public asyncOrders;
    mapping(PoolId poolId => AsyncFiller.Book) private priceBooks;

    /// @notice Protocol owner authorized to collect vault fees and sweep stranded balances.
    address public owner;

    /// @notice Address nominated by `transferOwnership`; becomes owner on `acceptOwnership`.
    address public pendingOwner;

    /// @notice Holds fee claims separately from open-order escrow.
    FeeVault public immutable feeVault;

    /// @notice Chain-specific USDC address. Every pool must include this exact currency.
    Currency public immutable numeraire;

    /// @notice Unordered nonces consumed by signed maker actions (`setExecutorWithSig`, `updatePriceWithSig`).
    mapping(address maker => mapping(uint256 nonce => bool)) public nonceUsed;

    /// @notice Pool-level swap-event mirror; bytes32 poolId for indexer compatibility.
    /// @dev    See https://github.com/OpenZeppelin/uniswap-hooks BaseAsyncSwap for the source pattern.
    event HookSwap(
        bytes32 indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint128 hookLPfeeAmount0,
        uint128 hookLPfeeAmount1
    );

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

    /// @notice Emitted when ownership is transferred.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when the owner nominates a new owner.
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when the owner sweeps an accumulated balance.
    event Swept(Currency indexed currency, address indexed to, uint256 amount);

    /// @notice Emitted when a maker burns a nonce, consumed or revoked.
    event NonceInvalidated(address indexed maker, uint256 nonce);

    /// @notice Emitted after each successful direct or signed executor authorization update.
    /// @dev `allow` is the resulting permission, including when the value is unchanged.
    event ExecutorSet(PoolId indexed poolId, address indexed maker, address indexed executor, bool allow);

    /// @notice Pairwise direct escrow match; emitted by the linked matcher at the hook address.
    event AsyncOrdersMatched(
        PoolId indexed poolId,
        bytes32 indexed sellOrderId,
        bytes32 indexed buyOrderId,
        uint256 assetAmount,
        uint256 numeraireAmount
    );

    /// @notice An open order was fully executed against active Uniswap v4 pool liquidity.
    event AsyncOrderLiquidityFilled(
        PoolId indexed poolId, bytes32 indexed orderId, address indexed maker, uint256 amountIn, uint256 amountOut
    );

    /// @notice Restricts a call to the protocol owner.
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev Transient slot — keccak256("asyncswap.hook.pendingNativeDeposit") - 1.
    ///      Tracks ETH deposited to this contract within the current tx via
    ///      `receive()`, so `executeOrder` can settle native output only out of
    ///      the filler's just-received deposit rather than the contract's
    ///      accumulated balance (which may include donations, stranded ETH,
    ///      or in-flight native-input escrow). Cleared after each settle.
    bytes32 constant PENDING_NATIVE_DEPOSIT_SLOT = 0x9c2a7e4f3b1d8a5c6e0f2d4b7a9c1e3d5f8b6a0c2e4d7b9f1a3c5e7d9b1f3a50;
    /// @dev Transient hand-off from `_beforeSwap` to the Router after it settles the new input.
    bytes32 constant PENDING_MATCH_ID_SLOT = 0x247d5e35be7fbfd4d95fd66ea940bfb4ee942bef70db6afae46dc83ce0f89eb2;
    bytes32 constant PENDING_MATCH_EXECUTOR_SLOT = 0x9583e36f799bab8c4d06dc676d85ba05b4dfbde5934d5684d8e431d0fd3948da;

    /// @notice Hook params decoded from the `hookData` of `IPoolManager.swap`. The maker sets
    ///         `amountOutMin` (their limit price); `executor` is the address authorized to call fill.
    ///         Salt is contract-assigned at create time (see `_createOrder`) and emitted in
    ///         `AsyncOrderCreated` — the maker fetches it from the event log to reference the
    ///         order in cancel / updatePrice later.
    struct UserParams {
        address user;
        address executor;
        uint256 amountOutMin;
        uint256 priorityFee;
    }

    /// @param _owner Explicit protocol owner. Not `msg.sender`: CREATE2 deployments run the
    ///               constructor from the deterministic deployer, which could never act as owner.
    constructor(IPoolManager _poolManager, Currency _numeraire, address _owner)
        BaseHook(_poolManager)
        EIP712("AsyncSwap", "1")
    {
        if (Currency.unwrap(_numeraire).code.length == 0) revert InvalidNumeraire();
        if (_owner == address(0)) revert ZeroAddress();
        numeraire = _numeraire;
        owner = _owner;
        feeVault = new FeeVault(_poolManager);
        emit OwnershipTransferred(address(0), _owner);
    }

    /// @notice Start a two-step ownership transfer. The deployer (or a factory) should call this after
    ///         deployment to hand control to the intended fee recipient / governance address, which
    ///         then calls `acceptOwnership`.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Complete a two-step ownership transfer. Only the nominated `pendingOwner` may call.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /// @notice Sweep an accumulated balance of `currency` held by this hook to `to`.
    /// @dev    Between transactions the hook's raw balance holds only stranded funds or donations;
    ///         fees belong to feeVault. Maker input is escrowed as ERC-6909
    ///         claims in the PoolManager, and the transient native-deposit ledger is cleared at the
    ///         end of every tx, so no per-order escrow lives in the hook's balance across calls.
    function sweep(Currency currency, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = currency.balanceOfSelf();
        currency.transfer(to, amount);
        emit Swept(currency, to, amount);
    }

    /// @inheritdoc BaseHook
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal virtual override returns (bytes4) {
        if (!(key.currency0 == numeraire || key.currency1 == numeraire)) revert NumeraireRequired();
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) revert DynamicFeeRequired();
        asyncOrders[key.toId()].poolManager = poolManager;
        asyncOrders[key.toId()].numeraire = numeraire;
        asyncOrders[key.toId()].feeVault = address(feeVault);
        return this.beforeInitialize.selector;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // true
            afterInitialize: false,
            beforeAddLiquidity: true, // true
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // true
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // true
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @inheritdoc BaseHook
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        // LP positions supply the inventory used by the guarded order-fill path below.
        return this.beforeAddLiquidity.selector;
    }

    /// @notice Read an order's currently-open input amount. Returns 0 if the order does not exist.
    function asyncOrder(PoolId poolId, bytes32 orderId) external view returns (uint256 amountIn) {
        return asyncOrders[poolId].orders[orderId].amountIn;
    }

    /// @notice Read both legs of an open order. Returns (0, 0) if the order does not exist.
    function asyncOrderInfo(PoolId poolId, bytes32 orderId)
        external
        view
        returns (uint256 amountIn, uint256 amountOutMin)
    {
        AsyncFiller.OrderInfo storage info = asyncOrders[poolId].orders[orderId];
        return (info.amountIn, info.amountOutMin);
    }

    /// @notice The priority bid an order has escrowed; a bid that was never paid reads as 0.
    function asyncOrderPriorityFee(PoolId poolId, bytes32 orderId) external view returns (uint256) {
        return AsyncFiller.paidPriorityFee(asyncOrders[poolId].orders[orderId]);
    }

    function orderingMode(PoolId poolId) external view returns (AsyncFiller.OrderingMode) {
        return priceBooks[poolId].orderingMode;
    }

    function setOrderingMode(PoolKey calldata key, AsyncFiller.OrderingMode mode) external onlyOwner {
        PoolId poolId = key.toId();
        AsyncMatching.setOrderingMode(priceBooks[poolId], poolId, mode);
    }

    /// @notice Convert the just-settled USDC bid into an ERC-6909 claim owned by the hook.
    /// @dev Called by the order's authorized executor inside the Router's PoolManager unlock.
    function recordPriorityFee(PoolKey calldata key, address maker, uint256 amount) external {
        bytes32 id;
        address executor;
        assembly ("memory-safe") {
            id := tload(PENDING_MATCH_ID_SLOT)
            executor := tload(PENDING_MATCH_EXECUTOR_SLOT)
        }
        if (id == bytes32(0) || msg.sender != executor) revert AsyncFiller.NotAuthorizedExecutor();
        AsyncFiller.State storage state = asyncOrders[key.toId()];
        if (state.orders[id].owner != maker) revert AsyncFiller.OrderNotFound();
        AsyncMatching.recordPriorityFee(state, priceBooks[key.toId()], id, amount, numeraire);
    }

    /// @notice Return the best live limit order for a pool side. `isBuy` is true
    ///         when the maker escrows the pool numeraire to buy the other asset.
    ///         `priceKey` is a WAD-scaled raw-amount ratio for sorting within this pool,
    ///         not a human-readable price. Equal-price orders follow submission order.
    function bestOrder(PoolId poolId, bool isBuy)
        external
        view
        returns (bool found, uint128 priceKey, bytes32 orderId, address maker)
    {
        return AsyncMatching.bestOrder(asyncOrders[poolId], priceBooks[poolId], isBuy);
    }

    /// @notice Return the first and last order under the pool's configured ordering mode, plus count.
    function orderBookLevel(PoolId poolId, bool isBuy, uint128 priceKey)
        external
        view
        returns (bytes32 head, bytes32 tail, uint32 count)
    {
        return AsyncMatching.level(priceBooks[poolId], isBuy, priceKey);
    }

    /// @notice Read one live order and its FIFO neighbor when the pool uses FIFO ordering.
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
        )
    {
        AsyncFiller.OrderInfo storage info = asyncOrders[poolId].orders[orderId];
        return (info.owner, info.amountIn, info.amountOutMin, info.price, info.isBuy, info.previous, info.next);
    }

    function isExecutor(PoolId poolId, address maker, address executor) external view returns (bool) {
        return asyncOrders[poolId].isExecutor[maker][executor];
    }

    function calculateHookFee(uint256) public pure returns (uint256) {
        return 0;
    }

    /// @notice Fee added to the maker's net output: 0.3% of gross output, rounded down.
    function calculatePoolFee(uint24, uint256 amount) public pure virtual returns (uint256) {
        // net * 3 / 997 is equivalent to 30 bps of gross (net + fee), rounded down.
        // Split the calculation to avoid overflowing for large uint256 amounts.
        return (amount / 997) * 3 + ((amount % 997) * 3) / 997;
    }

    /// @notice Fill `order` in full. Must be called from an authorized executor (router) that has
    ///         already paid the filler's gross output within the same unlock: for ERC20 output via
    ///         `PoolManager.settleFor(hook)`, for native output by sending ETH to this hook.
    /// @param  data abi.encode(filler) — the address that should receive the maker's input.
    function executeOrder(AsyncOrder calldata order, bytes calldata data) external {
        address filler = abi.decode(data, (address));
        bytes32 id = order.orderId();

        // Native-output settlement may only consume ETH that the filler deposited
        // in this tx (via the Router's pre-unlock forward). Stranded balance is
        // not drawable. Decrement the per-tx ledger to amountOutMin's worth.
        Currency output = order.zeroForOne ? order.key.currency1 : order.key.currency0;
        if (output.isAddressZero()) {
            uint256 pending;
            assembly ("memory-safe") { pending := tload(PENDING_NATIVE_DEPOSIT_SLOT) }
            (, uint256 amountOutMin) = (this.asyncOrderInfo(order.key.toId(), id));
            amountOutMin += calculatePoolFee(order.key.fee, amountOutMin);
            if (pending < amountOutMin) revert UnaccountedNativeOutput();
            assembly ("memory-safe") {
                tstore(PENDING_NATIVE_DEPOSIT_SLOT, sub(pending, amountOutMin))
            }
        }
        AsyncFiller.State storage state = asyncOrders[order.key.toId()];
        uint256 fee = calculatePoolFee(order.key.fee, state.orders[id].amountOutMin);
        AsyncMatching.fill(
            state,
            priceBooks[order.key.toId()],
            AsyncMatching.FillParams({
                order: order,
                id: id,
                hook: address(this),
                executor: msg.sender,
                filler: filler,
                feeVault: address(feeVault),
                fee: fee
            })
        );
    }

    /// @notice Match the order just created by the current Router unlock callback.
    /// @dev The Router calls this only after settling the maker's input. The transient hand-off
    ///      prevents stale order ids or a different executor from triggering a match.
    function matchNewOrder(AsyncOrder calldata order) external returns (uint8 matched) {
        bytes32 id;
        address executor;
        assembly ("memory-safe") {
            id := tload(PENDING_MATCH_ID_SLOT)
            executor := tload(PENDING_MATCH_EXECUTOR_SLOT)
            tstore(PENDING_MATCH_ID_SLOT, 0)
            tstore(PENDING_MATCH_EXECUTOR_SLOT, 0)
        }
        if (id == bytes32(0) || msg.sender != executor) revert AsyncFiller.NotAuthorizedExecutor();
        AsyncFiller.State storage state = asyncOrders[order.key.toId()];
        if (state.orders[id].owner != order.owner) revert AsyncFiller.OrderNotFound();
        matched = AsyncMatching.matchIncoming(state, priceBooks[order.key.toId()], order.key, id, address(this));
        if (state.orders[id].amountIn != 0) {
            // A failed quote, insufficient active liquidity, or a price outside the maker's
            // minimum reverts only this external self-call. The order itself remains resting.
            try this.fillOrderFromPoolLiquidity(order, id) {} catch {}
        }
    }

    /// @notice Permissionless executor entry for retrying a resting order against current pool LPs.
    /// @dev Must run inside PoolManager.unlock. Router calls this after validating the request path.
    function tryFillOrderFromPoolLiquidity(AsyncOrder calldata order) external returns (bool filled) {
        if (!asyncOrders[order.key.toId()].isExecutor[order.owner][msg.sender]) {
            revert AsyncFiller.NotAuthorizedExecutor();
        }
        bytes32 id = order.orderId();
        if (asyncOrders[order.key.toId()].orders[id].amountIn == 0) revert AsyncFiller.OrderNotFound();
        try this.fillOrderFromPoolLiquidity(order, id) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev The self-call boundary makes a failed AMM attempt atomic while preserving the resting
    ///      order. PoolManager skips hook callbacks when the hook itself is the swap caller, so this
    ///      swap does not create an order.
    function fillOrderFromPoolLiquidity(AsyncOrder calldata order, bytes32 id) external {
        if (msg.sender != address(this)) revert NotSelf();
        PoolId poolId = order.key.toId();
        AsyncFiller.State storage state = asyncOrders[poolId];
        AsyncMatching.fillFromPoolLiquidity(
            state, priceBooks[poolId], order.key, id, state.orders[id].owner, address(this)
        );
    }

    /// @notice Permissionlessly continue a crossed book inside a PoolManager unlock.
    /// @dev The Router exposes the unlock wrapper; each call processes at most eight pairs.
    function matchBook(PoolKey calldata key, uint8 maxMatches) external returns (uint8 matched) {
        return AsyncMatching.matchBook(asyncOrders[key.toId()], priceBooks[key.toId()], key, maxMatches, address(this));
    }

    /// @notice Maker updates the limit price of an unfilled order. Direct call from the maker —
    ///         pure state mutation, no PM interaction, so no unlock or router needed.
    function updatePrice(AsyncOrder calldata order, uint256 newAmountOutMin) external {
        bytes32 id = order.orderId();
        AsyncMatching.updatePrice(
            asyncOrders[order.key.toId()],
            priceBooks[order.key.toId()],
            AsyncMatching.UpdateParams({order: order, id: id, newAmountOutMin: newAmountOutMin, caller: msg.sender})
        );
    }

    /// @notice Maker cancels an unfilled order. Must be called via an authorized executor inside
    ///         an `IPoolManager.unlock` context. The executor must have asserted maker identity.
    function cancelOrder(AsyncOrder calldata order) external {
        bytes32 id = order.orderId();
        AsyncMatching.cancel(
            asyncOrders[order.key.toId()],
            priceBooks[order.key.toId()],
            AsyncMatching.CancelParams({order: order, id: id, hook: address(this), executor: msg.sender})
        );
    }

    /// @inheritdoc BaseHook
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookParams)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (params.amountSpecified > 0) revert ExactInputOnly();

        PoolId poolId = key.toId();
        uint256 amountTaken = uint256(-params.amountSpecified);
        UserParams memory hookData = abi.decode(hookParams, (UserParams));
        // Bind the declared executor to the actual swap caller so nobody can open orders
        // attributed to a maker through an executor they do not control.
        if (sender != hookData.executor) revert AsyncFiller.NotAuthorizedExecutor();

        Currency specified = params.zeroForOne ? key.currency0 : key.currency1;

        // Escrow the entire deposit; fees are earned only on successful fill.
        specified.take(poolManager, address(this), amountTaken, true);
        _createOrder(poolId, params.zeroForOne, amountTaken, hookData, specified == numeraire);

        if (specified == key.currency0) {
            emit HookSwap(PoolId.unwrap(poolId), sender, amountTaken.toInt128(), 0, 0, 0);
        } else {
            emit HookSwap(PoolId.unwrap(poolId), sender, 0, amountTaken.toInt128(), 0, 0);
        }

        BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(int128(-params.amountSpecified), 0);
        return (BaseHook.beforeSwap.selector, beforeSwapDelta, 0);
    }

    /// @dev Extracted to keep `_beforeSwap` stack-shallow.
    function _createOrder(PoolId poolId, bool zeroForOne, uint256 amountIn, UserParams memory hookData, bool isBuy)
        private
    {
        AsyncFiller.State storage state = asyncOrders[poolId];

        // executor must already be authorised by the user — no implicit grant via hookData.
        if (!state.isExecutor[hookData.user][hookData.executor]) revert AsyncFiller.NotAuthorizedExecutor();
        if (amountIn == 0 || hookData.amountOutMin == 0) revert AsyncFiller.ZeroAmount();

        // Contract-assigned salt — derived from immutable order params + block context
        // so the maker doesn't need to pick a nonce. The orderId preimage MUST match
        // `AsyncOrderLibrary.orderId` (chainId, poolId, owner, zeroForOne, salt), since
        // the cancel/updatePrice/fill paths recompute the id via the library.
        bytes32 salt = keccak256(
            abi.encode(
                block.timestamp,
                block.number,
                msg.sender,
                hookData.user,
                amountIn,
                hookData.amountOutMin,
                hookData.priorityFee
            )
        );
        bytes32 id = keccak256(abi.encode(block.chainid, poolId, hookData.user, zeroForOne, salt));
        // Collision walk: the same maker submitting identical (amountIn, amountOutMin) twice
        // in one block lands on the same salt. Re-hash with an attempt counter until the
        // slot is free. The caller pays the extra gas.
        while (state.orders[id].amountIn != 0) {
            salt = keccak256(abi.encode(salt));
            id = keccak256(abi.encode(block.chainid, poolId, hookData.user, zeroForOne, salt));
        }

        AsyncMatching.addOrder(
            state,
            priceBooks[poolId],
            AsyncFiller.NewOrder({
                id: id,
                owner: hookData.user,
                amountIn: amountIn,
                amountOutMin: hookData.amountOutMin,
                isBuy: isBuy,
                zeroForOne: zeroForOne,
                priorityFee: hookData.priorityFee
            })
        );
        assembly ("memory-safe") {
            tstore(PENDING_MATCH_ID_SLOT, id)
            tstore(PENDING_MATCH_EXECUTOR_SLOT, mload(add(hookData, 0x20)))
        }
        emit AsyncFiller.AsyncOrderCreated(poolId, id, hookData.user, zeroForOne, amountIn, hookData.amountOutMin, salt);
    }

    /// @notice Maker explicitly authorises an executor (typically the Router) to submit
    ///         and fill orders on their behalf. Without this grant, `_createOrder` reverts
    ///         on the maker's first swap. Pass `allow = false` to revoke an executor.
    function setExecutor(PoolId poolId, address executor, bool allow) external {
        asyncOrders[poolId].isExecutor[msg.sender][executor] = allow;
        emit ExecutorSet(poolId, msg.sender, executor, allow);
    }

    /// @notice Signed `setExecutor`: anyone may submit the maker's EIP-712 `SetExecutor` grant.
    ///         Lets a relayer authorize the Router before the maker's first gasless order on a pool.
    function setExecutorWithSig(
        PoolKey calldata key,
        address maker,
        address executor,
        bool allow,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _verify(
            maker,
            OrderSignatures.hashSetExecutor(key, maker, executor, allow, nonce, deadline),
            nonce,
            deadline,
            signature
        );
        PoolId poolId = key.toId();
        asyncOrders[poolId].isExecutor[maker][executor] = allow;
        emit ExecutorSet(poolId, maker, executor, allow);
    }

    /// @notice Signed `updatePrice`: anyone may submit the maker's EIP-712 `UpdatePrice` message.
    function updatePriceWithSig(
        AsyncOrder calldata order,
        uint256 newAmountOutMin,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        PoolId poolId = order.key.toId();
        bytes32 id = order.orderId();
        uint256 amountIn = asyncOrders[poolId].orders[id].amountIn;
        _verify(
            order.owner,
            OrderSignatures.hashUpdatePrice(order, id, amountIn, newAmountOutMin, nonce, deadline),
            nonce,
            deadline,
            signature
        );
        asyncOrders[poolId].updatePrice(priceBooks[poolId], order, id, newAmountOutMin, order.owner);
    }

    /// @notice Revoke a signed action before a relayer submits it.
    function invalidateNonce(uint256 nonce) external {
        if (nonceUsed[msg.sender][nonce]) revert NonceAlreadyUsed();
        nonceUsed[msg.sender][nonce] = true;
        emit NonceInvalidated(msg.sender, nonce);
    }

    /// @notice EIP-712 domain separator for this hook's signed actions.
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @dev Checks deadline, burns the nonce, then validates an EOA or ERC-1271 signature.
    function _verify(address maker, bytes32 structHash, uint256 nonce, uint256 deadline, bytes calldata signature)
        private
    {
        if (block.timestamp > deadline) revert SignatureExpired();
        if (nonceUsed[maker][nonce]) revert NonceAlreadyUsed();
        nonceUsed[maker][nonce] = true;
        emit NonceInvalidated(maker, nonce);
        if (!SignatureChecker.isValidSignatureNow(maker, _hashTypedDataV4(structHash), signature)) {
            revert InvalidSignature();
        }
    }

    /// @notice Accept ETH transfers. The Router (or any caller paying for a native-output
    /// fill) forwards `msg.value` to the hook before triggering `executeOrder`. The hook
    /// records the deposit on a transient slot so `executeOrder` settles only against the
    /// filler's same-transaction deposit. ETH sent without a follow-up `executeOrder` stays
    /// in the hook balance and is recoverable only through `sweep`.
    receive() external payable {
        assembly ("memory-safe") {
            let cur := tload(PENDING_NATIVE_DEPOSIT_SLOT)
            tstore(PENDING_NATIVE_DEPOSIT_SLOT, add(cur, callvalue()))
        }
    }
}
