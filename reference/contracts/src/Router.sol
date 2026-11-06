// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISignatureTransfer} from "@async-swap/interfaces/ISignatureTransfer.sol";
import {OrderSignatures} from "@async-swap/libraries/OrderSignatures.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {CurrencySettler} from "@async-swap/libraries/CurrencySettler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager, SwapParams} from "v4-core/interfaces/IPoolManager.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {AsyncSwap} from "src/AsyncSwap.sol";

/// @title Router
/// @author @msakiart
/// @notice Thin entrypoint for makers (`swap`, `topUpPriorityFee`, `cancelOrder`, `cancelAndWithdraw`, `withdrawClaims`), fillers
///         (`fillOrder`) and keepers (`matchBook`, `fillFromPoolLiquidity`), batched with `multicall`. Each action
///         goes through `IPoolManager.unlock` so the hook can operate on PM debts. Native payouts/refunds are
///         PoolManager claims (ID 0), redeemable through NativeClaims or `withdrawClaims`; ERC20 payouts remain
///         direct.
///
///         Gasless variants (`swapWithSig`, `cancelWithSig`) take the maker's EIP-712 signature so a
///         relayer can submit. Signed creates pull input through Permit2 with the order as witness,
///         so the wallet shows the full order (tokens, amounts, pool) in one readable message.
///
///         `multicall` runs several of these as one atomic transaction, each as the caller (for example,
///         cancel many orders and withdraw the claims). It is not payable, so native-value actions
///         (`swap` with native input, `fillOrder` with native output) cannot reuse one `msg.value`.
///         Each action keeps its own PoolManager unlock and sets the transient slots it reads.
///
///         Order creation and fills (`swap`, `swapWithSig`, `fillOrder`, `fillFromPoolLiquidity`) pay an MEV tax
///         ("Priority Is All You Need", Robinson & White): `mevTax()`, the transaction's priority fee per gas times
///         `MEV_TAX_GAS`, in ETH on top of any native deposit, credited to the FeeVault as native claims. On a chain
///         that orders by priority fee, searchers racing for the same position bid it up, so most of what they race
///         for goes to the protocol; a transaction with no priority pays nothing. Inside `multicall`, which is not
///         payable, a taxed action needs a transaction with no priority.
contract Router is EIP712, Multicall {
    using CurrencySettler for Currency;
    using CurrencyLibrary for Currency;
    using SafeCast for *;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    IPoolManager immutable POOLMANAGER;
    AsyncSwap immutable HOOK;
    ISignatureTransfer public immutable PERMIT2;
    /// @notice Gas units the MEV tax charges per unit of priority fee: the tax on a transaction is its priority fee
    ///         per gas times this. Fixed at deployment.
    uint256 public immutable MEV_TAX_GAS;

    /// keccak256("Router.ActionType") - 1
    bytes32 constant ACTION_LOCATION = 0xf3b150ebf41dad0872df6788629edb438733cb4a5c9ea779b1b1f3614faffc69;
    /// keccak256("Router.User") - 1
    bytes32 constant USER_LOCATION = 0x3dde20d9bf5cc25a9f487c6d6b54d3c19e3fa4738b91a7a509d4fc4180a72356;
    /// keccak256("Router.AsyncFiller") - 1
    bytes32 constant ASYNC_FILLER_LOCATION = 0xd972a937b59dc5cb8c692dd9f211e85afa8def4caee6e05b31db0f53e16d02e0;
    /// @dev keccak256("asyncswap.router.maxPrice") - 1
    bytes32 constant MAX_PRICE_LOCATION = 0x6b4f8e2c9d5a0b7e1f3c2a8d4e9f0b6c5a1d8e7f2b3c4d5e6a7f8b9c0d1e2f30;
    /// keccak256("Router.MevTax") - 1
    bytes32 constant MEV_TAX_LOCATION = 0xe6251c15e22bdb44d13d4efeec6855e57f2b38fe36310ce3c709991726ed21da;

    enum ActionType {
        Swap,
        FillOrder,
        Cancel,
        SwapWithSig,
        MatchBook,
        PoolLiquidityFill,
        CancelAndWithdraw,
        WithdrawClaims,
        TopUpPriorityFee
    }

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

    /// @notice Optional signed `SetExecutor` grant, submitted to the hook ahead of the maker's first
    ///         gasless order on a pool. A supplied grant is always applied and its nonce spent, so leave
    ///         `signature` empty when the Router is already authorized.
    struct ExecutorGrant {
        uint256 nonce;
        uint256 deadline;
        bytes signature;
    }

    error SignatureExpired();
    error InvalidSignature();

    /// @notice A taxed action paid `amount` wei of MEV tax, credited to the FeeVault as native claims.
    event MevTaxPaid(address indexed payer, uint256 amount);

    constructor(IPoolManager _poolManager, AsyncSwap _hook, ISignatureTransfer _permit2, uint256 _mevTaxGas)
        EIP712("AsyncSwap Router", "1")
    {
        POOLMANAGER = _poolManager;
        HOOK = _hook;
        PERMIT2 = _permit2;
        MEV_TAX_GAS = _mevTaxGas;
    }

    /// @notice The MEV tax this transaction pays per taxed action, in wei: its priority fee per gas times
    ///         `MEV_TAX_GAS`.
    function mevTax() public view returns (uint256) {
        return tx.gasprice > block.basefee ? (tx.gasprice - block.basefee) * MEV_TAX_GAS : 0;
    }

    /// @dev Requires `msg.value` to be `deposit` plus the MEV tax, and records the tax for the unlock callback,
    ///      which credits it to the FeeVault.
    function _chargeMevTax(uint256 deposit) private {
        uint256 tax = mevTax();
        require(msg.value == deposit + tax, "msg.value != deposit + mevTax");
        if (tax == 0) return;
        assembly ("memory-safe") {
            tstore(MEV_TAX_LOCATION, tax)
        }
        emit MevTaxPaid(msg.sender, tax);
    }

    modifier onlyPoolManager() {
        require(msg.sender == address(POOLMANAGER), "Caller is not PoolManager");
        _;
    }

    /// @notice Maker submits a new async order. `userData` must encode `AsyncSwap.UserParams`
    ///         with `executor == address(this)` so the router is authorized to fill later.
    ///         `userData.amountOutMin` MUST equal `order.amountOutMin` — the router enforces
    ///         this so the limit price the maker signs in `order` is exactly what beforeSwap
    ///         stores via hookData.
    ///
    ///         The hook auto-assigns a salt on create and emits it in `AsyncOrderCreated`.
    ///         Submitters can pass `order.salt = bytes32(0)` on initial submission; the
    ///         field is only read on cancel / updatePrice / fill paths (where the maker
    ///         supplies the salt fetched from the indexer or event log).
    ///
    ///         Native input (currency0 = address(0) and zeroForOne = true, OR currency1 =
    ///         address(0) and zeroForOne = false) requires `msg.value == order.amountIn` —
    ///         the router holds the ETH and settles it to PM during unlock. For ERC20 input
    ///         the maker must approve the router for `amountIn` of the input token. Either way `msg.value`
    ///         also carries the MEV tax (`mevTax()`, zero without a priority fee).
    function swap(AsyncOrder calldata order, bytes memory userData) external payable {
        require(order.owner == msg.sender, "Only owner can swap");
        address onBehalf = address(this);
        AsyncSwap.UserParams memory userParams = abi.decode(userData, (AsyncSwap.UserParams));
        require(userParams.user == order.owner, "user mismatch");
        require(userParams.executor == address(this), "Use router as your executor!");
        require(userParams.amountOutMin == order.amountOutMin, "amountOutMin mismatch");
        require(userParams.priorityFee == order.priorityFee, "priorityFee mismatch");

        // msg.value invariant: the exact native deposit (none for ERC20 input) plus the MEV tax, so no ETH
        // accumulates in the router between calls.
        Currency input = order.zeroForOne ? order.key.currency0 : order.key.currency1;
        _chargeMevTax(input.isAddressZero() ? order.amountIn : 0);
        assembly ("memory-safe") {
            tstore(USER_LOCATION, caller())
            tstore(ASYNC_FILLER_LOCATION, onBehalf)
        }
        POOLMANAGER.unlock(abi.encode(SwapCallback({action: ActionType.Swap, order: order, maxMatches: 0})));
    }

    /// @notice Filler completes an open order, paying exactly the maker's live minimum. The maker
    ///         receives it less the 0.02% trade fee, and the filler the input less 0.02%.
    ///         For ERC20 output, approve the router for that amount. For native output,
    ///         `msg.value` must equal the live minimum;
    ///         a stale or excessive deposit reverts rather than stranding the difference. `msg.value`
    ///         also carries the MEV tax (`mevTax()`, zero without a priority fee).
    ///         Native output is currency1 for zeroForOne, otherwise currency0.
    ///
    ///         `maxPrice` caps the output the filler pays —
    ///         it protects fillers from a maker who front-runs them with `updatePrice` to
    ///         bump the order's stored price. Pass `type(uint256).max` to disable the check.
    ///         `order.amountIn` is the least input the filler accepts: the fill reverts if the
    ///         order's live input has dropped below it (e.g. after a partial match).
    function fillOrder(AsyncOrder calldata order, uint256 maxPrice, bytes calldata) external payable {
        address onBehalf = address(this);
        assembly ("memory-safe") {
            tstore(USER_LOCATION, caller())
            tstore(ASYNC_FILLER_LOCATION, onBehalf)
            tstore(MAX_PRICE_LOCATION, maxPrice)
        }
        // For native output, forward msg.value to the hook here — the hook will
        // settle it inside fill() during the unlock. Doing this before unlock
        // (rather than from unlockCallback) keeps the payable-only msg.value
        // read out of the non-payable callback.
        Currency output = order.zeroForOne ? order.key.currency1 : order.key.currency0;
        if (output.isAddressZero()) {
            // The caller's struct price may be stale after a maker reprices. Match the
            // total amount settled: maker net output plus protocol fee.
            (, uint256 livePrice) = HOOK.asyncOrderInfo(order.key.toId(), _orderId(order));
            livePrice += HOOK.calculatePoolFee(order.key.fee, livePrice);
            _chargeMevTax(livePrice);
            (bool ok,) = address(HOOK).call{value: livePrice}("");
            require(ok, "Native output transfer to hook failed");
        } else {
            _chargeMevTax(0);
        }
        POOLMANAGER.unlock(abi.encode(SwapCallback({action: ActionType.FillOrder, order: order, maxMatches: 0})));
    }

    /// @notice Relayer submits a maker's signed order. The maker signs a Permit2
    ///         `PermitWitnessTransferFrom` for `amountIn` of the input token with `spender = Router`
    ///         and the `AsyncOrder` witness (see `OrderSignatures`), so one signature both approves
    ///         the transfer and commits to the order. Input then lands in the hook escrow exactly as
    ///         in `swap`. Requires a prior Permit2 approval of the input token; native input is not
    ///         supported (use `swap`). The relayer pays the MEV tax for its transaction's priority in `msg.value`.
    function swapWithSig(AsyncOrder calldata order, PermitData calldata permit, ExecutorGrant calldata grant)
        external
        payable
    {
        Currency input = order.zeroForOne ? order.key.currency0 : order.key.currency1;
        require(!input.isAddressZero(), "Native input needs swap()");
        _chargeMevTax(0);
        // Apply a supplied grant, which spends its nonce: a skipped unspent grant would stay valid in public calldata,
        // and anyone could replay it after the maker revokes the Router. A grant someone already submitted has a
        // spent nonce and cannot be replayed, so it is skipped rather than reverting the order.
        if (grant.signature.length != 0 && !HOOK.nonceUsed(order.owner, grant.nonce)) {
            HOOK.setExecutorWithSig(
                order.key, order.owner, address(this), true, grant.nonce, grant.deadline, grant.signature
            );
        }
        address onBehalf = address(this);
        address maker = order.owner;
        assembly ("memory-safe") {
            tstore(USER_LOCATION, maker)
            tstore(ASYNC_FILLER_LOCATION, onBehalf)
        }
        POOLMANAGER.unlock(
            abi.encode(SwapCallback({action: ActionType.SwapWithSig, order: order, maxMatches: 0}), permit)
        );
    }

    /// @notice Relayer submits a maker's signed EIP-712 `CancelOrder`. Input returns to the maker.
    ///         The nonce is burnt in the hook's store, so `AsyncSwap.invalidateNonce` revokes it.
    function cancelWithSig(AsyncOrder calldata order, uint256 nonce, uint256 deadline, bytes calldata signature)
        external
    {
        if (block.timestamp > deadline) revert SignatureExpired();
        HOOK.useNonce(order.owner, nonce);
        bytes32 id = _orderId(order);
        bytes32 digest = _hashTypedDataV4(
            OrderSignatures.hashCancel(order, id, HOOK.orderCreatedSequence(order.key.toId(), id), nonce, deadline)
        );
        if (!SignatureChecker.isValidSignatureNow(order.owner, digest, signature)) revert InvalidSignature();
        POOLMANAGER.unlock(abi.encode(SwapCallback({action: ActionType.Cancel, order: order, maxMatches: 0})));
    }

    /// @notice EIP-712 domain separator for Router-verified signatures (`CancelOrder`).
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Maker cancels an unfilled order and reclaims their reserved input.
    function cancelOrder(AsyncOrder calldata order) external {
        require(msg.sender == order.owner, "Only owner can cancel");
        assembly ("memory-safe") {
            tstore(USER_LOCATION, caller())
        }
        POOLMANAGER.unlock(abi.encode(SwapCallback({action: ActionType.Cancel, order: order, maxMatches: 0})));
    }

    /// @notice Cancel an owned order and return its remaining input to the owner's wallet.
    /// @dev Native refunds are redeemed atomically. Approve this Router for claim ID 0 first.
    ///      Existing claims are untouched; a failed redemption rolls back the cancellation.
    function cancelAndWithdraw(AsyncOrder calldata order) external {
        require(msg.sender == order.owner, "Only owner can cancel");
        POOLMANAGER.unlock(
            abi.encode(SwapCallback({action: ActionType.CancelAndWithdraw, order: order, maxMatches: 0}))
        );
    }

    /// @notice Withdraw the caller's approved ERC-6909 claims directly to their wallet.
    /// @dev Approve exact currency claim allowances on PoolManager first. No operator grant is needed.
    function withdrawClaims(Currency[] calldata currencies, uint256[] calldata amounts) external {
        uint256 length = currencies.length;
        require(length != 0 && length <= 16 && length == amounts.length, "Invalid claims");
        for (uint256 i; i < length; ++i) {
            require(amounts[i] != 0, "Zero claim");
            for (uint256 j; j < i; ++j) {
                require(Currency.unwrap(currencies[i]) != Currency.unwrap(currencies[j]), "Duplicate currency");
            }
        }
        POOLMANAGER.unlock(abi.encode(ActionType.WithdrawClaims, msg.sender, currencies, amounts));
    }

    /// @notice Add `addedFee` numeraire units to the caller's remaining priority bid.
    /// @dev Requires an ERC20 approval to this Router. Leaves amount and price unchanged and resets
    ///      fee-tier FIFO age. No matching or MEV tax; use multicall with matchBook to attempt matching.
    ///      Only the order's identity fields are used; addedFee is a delta, not a target total.
    function topUpPriorityFee(AsyncOrder calldata order, uint256 addedFee) external {
        require(msg.sender == order.owner, "Only owner can top up");
        if (addedFee == 0) revert AsyncFiller.ZeroAmount();
        if (addedFee > type(uint64).max) revert AsyncFiller.PriorityFeeTooLarge();
        POOLMANAGER.unlock(abi.encode(ActionType.TopUpPriorityFee, order, addedFee));
    }

    /// @notice Anyone can continue a crossed book after a transaction hits the automatic match cap.
    /// @dev Work is capped at eight matched pairs per unlock to keep gas predictable.
    function matchBook(PoolKey calldata key, uint8 maxMatches) external {
        AsyncOrder memory placeholder;
        placeholder.key = key;
        POOLMANAGER.unlock(
            abi.encode(SwapCallback({action: ActionType.MatchBook, order: placeholder, maxMatches: maxMatches}))
        );
    }

    /// @notice Retry a resting order against the pool's active Uniswap v4 LP positions.
    /// @dev The order is left untouched when the pool cannot fully fill it at its minimum output. `msg.value` is
    ///      the MEV tax.
    function fillFromPoolLiquidity(AsyncOrder calldata order) external payable {
        _chargeMevTax(0);
        address onBehalf = address(this);
        assembly ("memory-safe") {
            tstore(USER_LOCATION, caller())
            tstore(ASYNC_FILLER_LOCATION, onBehalf)
        }
        POOLMANAGER.unlock(
            abi.encode(SwapCallback({action: ActionType.PoolLiquidityFill, order: order, maxMatches: 0}))
        );
    }

    /// @notice PM unlock-callback dispatcher. The action enum is read from transient storage, set
    ///         by the externally-callable entry above. Each branch must leave PM deltas net-zero.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        uint8 action;
        address user;
        address asyncFiller;
        assembly ("memory-safe") {
            tstore(ACTION_LOCATION, calldataload(0x44))
            action := tload(ACTION_LOCATION)
            user := tload(USER_LOCATION)
            asyncFiller := tload(ASYNC_FILLER_LOCATION)
        }
        _payMevTax();

        if (action == uint8(ActionType.WithdrawClaims)) {
            (, address owner, Currency[] memory currencies, uint256[] memory amounts) =
                abi.decode(data, (ActionType, address, Currency[], uint256[]));
            for (uint256 i; i < currencies.length; ++i) {
                _withdrawClaim(owner, currencies[i], amounts[i]);
            }
            return "";
        }
        if (action == uint8(ActionType.TopUpPriorityFee)) {
            (, AsyncOrder memory order, uint256 addedFee) = abi.decode(data, (ActionType, AsyncOrder, uint256));
            // Fund before rekeying: token callbacks cannot observe an unpaid priority increase.
            _settlePriorityFee(order.owner, addedFee);
            HOOK.topUpPriorityFee(order, addedFee);
            return "";
        }
        SwapCallback memory orderData = abi.decode(data, (SwapCallback));

        if (action == uint8(ActionType.Swap) || action == uint8(ActionType.SwapWithSig)) {
            // Trigger the hook via PM.swap; hook.beforeSwap pulls the maker's input as 6909.
            POOLMANAGER.swap(
                orderData.order.key,
                SwapParams(orderData.order.zeroForOne, -orderData.order.amountIn.toInt256(), orderData.order.sqrtPrice),
                abi.encode(
                    AsyncSwap.UserParams({
                        user: user,
                        executor: asyncFiller,
                        amountOutMin: orderData.order.amountOutMin,
                        priorityFee: orderData.order.priorityFee
                    })
                )
            );
            // Maker pays their input to PM (settling the swap). For native input the
            // router holds the ETH forwarded on swap(), and the native settle branch
            // pays from address(this) regardless of the `payer` argument.
            Currency input = orderData.order.zeroForOne ? orderData.order.key.currency0 : orderData.order.key.currency1;
            if (action == uint8(ActionType.SwapWithSig)) {
                (, PermitData memory permit) = abi.decode(data, (SwapCallback, PermitData));
                _settleWithPermit(input, orderData.order, permit);
            } else {
                input.settle(POOLMANAGER, user, orderData.order.amountIn, false);
            }
            _settlePriorityFee(orderData.order.owner, orderData.order.priorityFee);
            // The hook records the order during `swap`, but it only becomes matchable after
            // this maker's input has been settled into PoolManager escrow.
            HOOK.matchNewOrder(orderData.order);
        } else if (action == uint8(ActionType.FillOrder)) {
            // Read the LIVE price from hook storage — the caller's `order.amountOutMin` may be
            // stale if the maker called updatePrice after submitting.
            Currency output = orderData.order.zeroForOne ? orderData.order.key.currency1 : orderData.order.key.currency0;
            bytes32 id = _orderId(orderData.order);
            (uint256 liveAmountIn, uint256 livePrice) = HOOK.asyncOrderInfo(orderData.order.key.toId(), id);
            // `maxPrice` bounds what the filler pays and `order.amountIn` what they receive, so a
            // partial match before the fill cannot leave them paying a full price for a remainder.
            // A missing order (live input 0) is left for the hook to reject with `OrderNotFound`.
            require(liveAmountIn == 0 || liveAmountIn >= orderData.order.amountIn, "Input below order.amountIn");
            uint256 gross = livePrice + HOOK.calculatePoolFee(orderData.order.key.fee, livePrice);
            uint256 maxPrice;
            assembly ("memory-safe") {
                maxPrice := tload(MAX_PRICE_LOCATION)
            }
            require(gross <= maxPrice, "Price exceeds maxPrice");
            // For ERC20 output, pay `livePrice` from the filler straight into the PM and credit
            // it to the hook (filler must have approved this router for that amount); the hook
            // never spends its own token balance. For native output the ETH was already
            // forwarded in fillOrder() above.
            if (!output.isAddressZero()) {
                POOLMANAGER.sync(output);
                IERC20(Currency.unwrap(output)).safeTransferFrom(user, address(POOLMANAGER), gross);
                POOLMANAGER.settleFor(address(HOOK));
                // The pull ran the token's code: fill only the order as it was checked above.
                _requireUnchanged(orderData.order, id, liveAmountIn, livePrice);
            }
            HOOK.executeOrder(orderData.order, abi.encode(user));
        } else if (action == uint8(ActionType.CancelAndWithdraw)) {
            Currency input = orderData.order.zeroForOne ? orderData.order.key.currency0 : orderData.order.key.currency1;
            address owner = orderData.order.owner;
            uint256 beforeClaims = input.isAddressZero() ? POOLMANAGER.balanceOf(owner, 0) : 0;
            HOOK.cancelOrder(orderData.order);
            if (input.isAddressZero()) {
                _withdrawClaim(owner, input, POOLMANAGER.balanceOf(owner, 0) - beforeClaims);
            }
        } else if (action == uint8(ActionType.Cancel)) {
            HOOK.cancelOrder(orderData.order);
        } else if (action == uint8(ActionType.MatchBook)) {
            HOOK.matchBook(orderData.order.key, orderData.maxMatches);
        } else if (action == uint8(ActionType.PoolLiquidityFill)) {
            HOOK.tryFillOrderFromPoolLiquidity(orderData.order);
        }

        return "";
    }

    /// @dev Credits a recorded MEV tax, held by the Router since the entry call, to the FeeVault as native claims.
    function _payMevTax() private {
        uint256 tax;
        assembly ("memory-safe") {
            tax := tload(MEV_TAX_LOCATION)
            tstore(MEV_TAX_LOCATION, 0)
        }
        if (tax == 0) return;
        POOLMANAGER.settle{value: tax}();
        POOLMANAGER.mint(address(HOOK.feeVault()), 0, tax);
    }

    event ClaimWithdrawn(address indexed owner, Currency indexed currency, uint256 amount);

    function _withdrawClaim(address owner, Currency currency, uint256 amount) private {
        POOLMANAGER.burn(owner, currency.toId(), amount);
        POOLMANAGER.take(currency, owner, amount);
        emit ClaimWithdrawn(owner, currency, amount);
    }

    /// @dev Reverts unless the order still reads `(amountIn, amountOutMin)` in the hook.
    function _requireUnchanged(AsyncOrder memory order, bytes32 id, uint256 amountIn, uint256 amountOutMin)
        private
        view
    {
        (uint256 nowIn, uint256 nowOut) = HOOK.asyncOrderInfo(order.key.toId(), id);
        require(nowIn == amountIn && nowOut == amountOutMin, "Order changed during fill");
    }

    /// @dev Pays the maker's input into the PoolManager via Permit2. Permit2 verifies the maker's
    ///      signature over the transfer AND the order witness, so a relayer cannot alter the order.
    function _settleWithPermit(Currency input, AsyncOrder memory order, PermitData memory permit) private {
        POOLMANAGER.sync(input);
        PERMIT2.permitWitnessTransferFrom(
            ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({token: Currency.unwrap(input), amount: order.amountIn}),
                nonce: permit.nonce,
                deadline: permit.deadline
            }),
            ISignatureTransfer.SignatureTransferDetails({to: address(POOLMANAGER), requestedAmount: order.amountIn}),
            order.owner,
            OrderSignatures.hashOrder(order),
            OrderSignatures.PERMIT2_WITNESS_TYPE,
            permit.signature
        );
        POOLMANAGER.settle();
    }

    /// @dev Pays an initial bid or top-up in the pool's USDC numeraire, crediting the hook. Signed orders also require an ERC-20 approval for the bid; the
    ///      signed order commits to its amount.
    function _settlePriorityFee(address owner, uint256 amount) private {
        if (amount == 0) return;
        Currency numeraire = HOOK.numeraire();
        POOLMANAGER.sync(numeraire);
        IERC20(Currency.unwrap(numeraire)).safeTransferFrom(owner, address(POOLMANAGER), amount);
        POOLMANAGER.settleFor(address(HOOK));
    }

    /// @dev MUST match AsyncOrderLibrary.orderId exactly: (chainId, poolId, owner, zeroForOne, salt).
    function _orderId(AsyncOrder memory order) private view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, order.key.toId(), order.owner, order.zeroForOne, order.salt));
    }
}
