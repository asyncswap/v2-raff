// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface ITransferObserver {
    function onTokenReceived() external;
}

/// @notice ERC20 that notifies one registered recipient on every `transfer` to it, the way a
///         token with receive hooks would. Used only to observe hook state mid-payout.
contract NotifyingERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public observer;
    mapping(address => bool) public blocked;

    function setObserver(address _observer) external {
        observer = _observer;
    }

    /// @dev Refuse transfers to `who`, the way a token with a blocklist (e.g. USDC) does.
    function setBlocked(address who, bool isBlocked) external {
        blocked[who] = isBlocked;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(!blocked[to], "blocked");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (to == observer) ITransferObserver(to).onTokenReceived();
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice A maker contract that, when paid, only reads the hook's record of one order.
contract OrderStateObserver is ITransferObserver {
    AsyncSwap immutable hook;
    PoolId immutable poolId;
    bytes32 public watched;
    bool public observed;
    uint256 public seenAmountIn;

    constructor(AsyncSwap _hook, PoolId _poolId) {
        hook = _hook;
        poolId = _poolId;
    }

    function watch(bytes32 id) external {
        watched = id;
    }

    function onTokenReceived() external {
        if (observed) return;
        observed = true;
        seenAmountIn = hook.asyncOrder(poolId, watched);
    }
}

/// @notice Regression tests for the Nethermind AuditAgent report
///         (audit/auditagent_report_1_ae602e60-d592-45ec-92ef-891968f087f0.md). Each test asserts
///         the behaviour a fix must produce, so it fails on the unfixed code.
contract NethermindAuditAgentTest is SetupHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");

    /// @dev Second pool: the notifying asset against the numeraire (token1).
    NotifyingERC20 asset;
    PoolKey assetKey;
    PoolId assetPoolId;
    OrderStateObserver maker;

    function setUp() public override {
        super.setUp();
        topUp(alice, 1_000 ether);
        topUp(bob, 1_000 ether);
        topUp(carol, 1_000 ether);
        topUp(seller, 1_000 ether);
        topUp(buyer, 1_000 ether);

        asset = new NotifyingERC20();
        (Currency c0, Currency c1) = address(asset) < Currency.unwrap(currency1)
            ? (Currency.wrap(address(asset)), currency1)
            : (currency1, Currency.wrap(address(asset)));
        assetKey =
            PoolKey({currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 1, hooks: hook});
        assetPoolId = assetKey.toId();
        manager.initialize(assetKey, 2 ** 96);

        maker = new OrderStateObserver(hook, assetPoolId);
        asset.setObserver(address(maker));
        vm.prank(owner);
        token1.transfer(address(maker), 1_000 ether);
        vm.startPrank(address(maker));
        hook.setExecutor(assetPoolId, address(router), true);
        token1.approve(address(router), type(uint256).max);
        vm.stopPrank();

        asset.mint(bob, 1_000 ether);
        vm.startPrank(bob);
        hook.setExecutor(assetPoolId, address(router), true);
        asset.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    /* ----------------------------------- main pool helpers ----------------------------------- */

    function _order(address who, bool zeroForOne, uint256 amountIn, uint256 amountOutMin)
        internal
        view
        returns (AsyncOrder memory)
    {
        return AsyncOrder({
            key: key,
            owner: who,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            priorityFee: 100_000,
            sqrtPrice: 2 ** 96,
            salt: _expectedSalt(who, amountIn, amountOutMin)
        });
    }

    function _submit(AsyncOrder memory order) internal {
        MockERC20 input = order.zeroForOne ? token0 : token1;
        vm.startPrank(order.owner);
        input.approve(address(router), order.amountIn + order.priorityFee);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: order.owner,
                    executor: address(router),
                    amountOutMin: order.amountOutMin,
                    priorityFee: order.priorityFee
                })
            )
        );
        vm.stopPrank();
    }

    function _id(AsyncOrder memory order) internal view returns (bytes32) {
        return _orderIdFor(order.owner, order.zeroForOne, order.salt);
    }

    /* ---------------------------------- asset pool helpers ----------------------------------- */

    function _assetIsZero() internal view returns (bool) {
        return Currency.unwrap(assetKey.currency0) == address(asset);
    }

    /// @dev Spends the numeraire (token1) for the notifying asset.
    function _buy(address who, uint256 amountIn, uint256 amountOutMin) internal view returns (AsyncOrder memory) {
        return AsyncOrder({
            key: assetKey,
            owner: who,
            zeroForOne: !_assetIsZero(),
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            priorityFee: 100_000,
            sqrtPrice: 2 ** 96,
            salt: keccak256(
                abi.encode(block.timestamp, block.number, address(manager), who, amountIn, amountOutMin, 100_000)
            )
        });
    }

    function _sell(address who, uint256 amountIn, uint256 amountOutMin) internal view returns (AsyncOrder memory) {
        AsyncOrder memory order = _buy(who, amountIn, amountOutMin);
        order.zeroForOne = !order.zeroForOne;
        return order;
    }

    function _assetId(AsyncOrder memory order) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, assetPoolId, order.owner, order.zeroForOne, order.salt));
    }

    function _submitMaker(AsyncOrder memory order) internal {
        maker.watch(_assetId(order));
        vm.prank(address(maker));
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: address(maker),
                    executor: address(router),
                    amountOutMin: order.amountOutMin,
                    priorityFee: 100_000
                })
            )
        );
    }

    function _submitBob(AsyncOrder memory order) internal {
        vm.prank(bob);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: bob, executor: address(router), amountOutMin: order.amountOutMin, priorityFee: 100_000
                })
            )
        );
    }

    /* ------------------------------------------------------------------------------------------ *
     *  Findings 1 and 2: an order's record reflects a settlement before any payout leaves the    *
     *  hook. A payout that runs token code while the record still shows the pre-settlement       *
     *  amount lets that code act on input the hook has already spent.                            *
     * ------------------------------------------------------------------------------------------ */

    /// Filler fill: the maker's output payout runs after the order is closed.
    function test_H1_fill_orderClosedBeforeMakerPayout() public {
        AsyncOrder memory order = _buy(address(maker), 100 ether, 100 ether);
        _submitMaker(order);

        vm.prank(bob);
        router.fillOrder(order, type(uint256).max, "");

        assertTrue(maker.observed(), "maker payout ran token code");
        assertEq(maker.seenAmountIn(), 0, "order still live during the maker payout");
        assertEq(hook.asyncOrder(assetPoolId, _assetId(order)), 0);
    }

    /// Pool-liquidity fill: the maker's output payout runs after the order is closed.
    function test_H2_poolLiquidityFill_orderClosedBeforeMakerPayout() public {
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        asset.mint(address(this), 1e30);
        vm.prank(owner);
        token1.transfer(address(this), 1e30);
        asset.approve(address(lp), type(uint256).max);
        token1.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(
            assetKey, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e24, salt: 0}), ""
        );

        AsyncOrder memory order = _buy(address(maker), 100 ether, 90 ether);
        _submitMaker(order);

        assertGt(asset.balanceOf(address(maker)), 90 ether, "order filled from pool liquidity");
        assertTrue(maker.observed(), "maker payout ran token code");
        assertEq(maker.seenAmountIn(), 0, "order still live during the maker payout");
    }

    /// Direct match: proceeds are credited as PoolManager claims, so no token code runs during the
    /// match at all, and the resting order is reduced.
    function test_H1_match_orderReducedBeforeMakerPayout() public {
        AsyncOrder memory resting = _buy(address(maker), 100 ether, 100 ether);
        _submitMaker(resting);

        _submitBob(_sell(bob, 40 ether, 40 ether));

        assertEq(asset.balanceOf(address(maker)), 0, "no ERC20 transfer during the match");
        assertEq(
            manager.balanceOf(address(maker), Currency.wrap(address(asset)).toId()),
            40 ether - _fee(40 ether),
            "partial match credited the maker in claims"
        );
        assertFalse(maker.observed(), "match payout ran no token code");
        assertEq(hook.asyncOrder(assetPoolId, _assetId(resting)), 60 ether);
    }

    /* ------------------------------------------------------------------------------------------ *
     *  Finding 5: `fillOrder` treats `order.amountIn` as the least input the filler accepts.     *
     *  `maxPrice` bounds what the filler pays; this bounds what they receive, so a partial      *
     *  match before the fill cannot leave the filler paying a full price for a remainder.        *
     * ------------------------------------------------------------------------------------------ */

    /// @dev Alice's 100:100 ask is matched down to 10 and repriced to 100 before Bob's fill lands.
    function _shrinkAndReprice() internal returns (AsyncOrder memory ask) {
        ask = _order(alice, true, 100 ether, 100 ether);
        ask.priorityFee = 1_000_000; // 10% remains after the fill, enough for the raised minimum.
        ask.salt = keccak256(
            abi.encode(
                block.timestamp, block.number, address(manager), alice, ask.amountIn, ask.amountOutMin, ask.priorityFee
            )
        );
        _submit(ask);
        _submit(_order(carol, false, 90 ether, 90 ether));
        vm.prank(alice);
        hook.updatePrice(ask, 100 ether);
    }

    function test_M5_RevertWhen_LiveInputBelowFillerExpectation() public {
        AsyncOrder memory ask = _shrinkAndReprice();
        (uint256 liveIn,) = hook.asyncOrderInfo(poolId, _id(ask));
        assertEq(liveIn, 10 ether);

        uint256 maxPrice = 100 ether + hook.calculatePoolFee(key.fee, 100 ether);
        vm.startPrank(bob);
        token1.approve(address(router), maxPrice);
        vm.expectRevert("Input below order.amountIn");
        router.fillOrder(ask, maxPrice, "");
        vm.stopPrank();
    }

    function test_M5_fillSucceeds_WhenFillerAcceptsLiveInput() public {
        AsyncOrder memory ask = _shrinkAndReprice();
        ask.amountIn = 10 ether;

        uint256 gross = 100 ether + hook.calculatePoolFee(key.fee, 100 ether);
        uint256 bobToken0Before = token0.balanceOf(bob);
        vm.startPrank(bob);
        token1.approve(address(router), gross);
        router.fillOrder(ask, gross, "");
        vm.stopPrank();
        assertEq(token0.balanceOf(bob) - bobToken0Before, 10 ether - _fee(10 ether));
    }

    /* ------------------------------------------------------------------------------------------ *
     *  Finding 6: a partial match leaves the unfilled input at the maker's own limit. Price      *
     *  improvement on the filled part is not credited against the remainder's minimum.           *
     * ------------------------------------------------------------------------------------------ */

    /// Seller asks >= 1 token1 per token0 and sells half at 1.5: the other half still needs 1 per token0.
    function test_M6_favorablePartialFill_keepsRemainderLimit() public {
        _submit(_order(buyer, false, 75 ether, 50 ether));
        AsyncOrder memory sell = _order(seller, true, 100 ether, 100 ether);
        _submit(sell);

        (uint256 amountIn, uint256 amountOutMin) = hook.asyncOrderInfo(poolId, _id(sell));
        assertEq(amountIn, 50 ether, "half the input remains");
        assertEq(amountOutMin, 50 ether, "remainder keeps the seller's 1:1 limit");
    }

    /// A partial fill that alone pays the whole original minimum still leaves the remainder resting.
    function test_M6_partialFillMeetingWholeMinimum_keepsRemainderResting() public {
        _submit(_order(buyer, false, 120 ether, 50 ether));
        AsyncOrder memory sell = _order(seller, true, 100 ether, 100 ether);
        uint256 sellerToken0Before = token0.balanceOf(seller);
        _submit(sell);

        (uint256 amountIn, uint256 amountOutMin) = hook.asyncOrderInfo(poolId, _id(sell));
        assertEq(amountIn, 50 ether, "unfilled input stays on the book");
        assertEq(amountOutMin, 50 ether, "remainder keeps the seller's 1:1 limit");
        assertEq(token0.balanceOf(seller), sellerToken0Before - 100 ether, "no unrequested refund");
    }

    /* ------------------------------------------------------------------------------------------ *
     *  Finding 4: priority bids go to the FeeVault, so liquidity added just before a fill        *
     *  captures none of them.                                                                    *
     * ------------------------------------------------------------------------------------------ */

    function test_M4_liquidityAddedBeforeFillGetsNoBid() public {
        // Liquidity arrives right before the order, as a just-in-time LP would place it.
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        vm.startPrank(owner);
        token0.transfer(address(this), 10_000 ether);
        token1.transfer(address(this), 10_000 ether);
        vm.stopPrank();
        token0.approve(address(lp), type(uint256).max);
        token1.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e24, salt: 0}), ""
        );
        (, uint256 growth1Before) = manager.getFeeGrowthGlobals(poolId);

        AsyncOrder memory ask = _order(alice, true, 1 ether, 0.95 ether);
        _submit(ask);

        assertEq(hook.asyncOrder(poolId, _id(ask)), 0, "filled from the pool");
        (, uint256 growth1After) = manager.getFeeGrowthGlobals(poolId);
        assertEq(growth1After, growth1Before, "no numeraire fee growth: the bid is not donated");
        assertEq(manager.balanceOf(address(hook.feeVault()), currency1.toId()), 100_000, "the bid goes to the FeeVault");
    }

    /* ------------------------------------------------------------------------------------------ *
     *  Finding 8: a new order joins the book-wide priority. A crossed backlog left by the        *
     *  8-match cap clears before a newer, worse-priced order on the same side.                   *
     * ------------------------------------------------------------------------------------------ */

    function test_M8_crossedBacklogClearsBeforeNewerOrder() public {
        address lastMaker;
        for (uint160 i = 1; i <= 9; ++i) {
            lastMaker = address(2000 + i);
            topUp(lastMaker, 2 ether);
            _submit(_order(lastMaker, true, 1 ether, 0.9 ether));
        }
        _submit(_order(bob, false, 20 ether, 20 ether));
        bytes32 backlogAsk = _id(_order(lastMaker, true, 1 ether, 0.9 ether));
        assertEq(hook.asyncOrder(poolId, backlogAsk), 1 ether, "precondition: the cap left a crossed ask");

        // A newer ask at a worse price (0.95) arrives.
        AsyncOrder memory newer = _order(carol, true, 1 ether, 0.95 ether);
        _submit(newer);

        assertEq(hook.asyncOrder(poolId, backlogAsk), 0, "the older, better-priced ask filled first");
        assertEq(hook.asyncOrder(poolId, _id(newer)), 0, "then the newer ask");
    }

    /* ------------------------------------------------------------------------------------------ *
     *  Finding 9: match proceeds are credited as claims, so a recipient the token refuses        *
     *  cannot block the match.                                                                   *
     * ------------------------------------------------------------------------------------------ */

    function test_M9_blockedRecipientDoesNotBlockMatch() public {
        AsyncOrder memory resting = _buy(address(maker), 100 ether, 100 ether);
        _submitMaker(resting);
        asset.setBlocked(address(maker), true);

        _submitBob(_sell(bob, 40 ether, 40 ether));

        assertEq(hook.asyncOrder(assetPoolId, _assetId(resting)), 60 ether, "the match went through");
        assertEq(
            manager.balanceOf(address(maker), Currency.wrap(address(asset)).toId()),
            40 ether - _fee(40 ether),
            "the blocked maker is credited claims"
        );
    }

    /* ------------------------------------------------------------------------------------------ *
     *  Finding 10: the maker of a crossed pair is the order created first. A reprice resets      *
     *  queue position but not that.                                                              *
     * ------------------------------------------------------------------------------------------ */

    function test_M10_repriceKeepsMakerRole() public {
        // The buy rests first at 1:1; the sell rests above it at 1.1, so they do not cross.
        AsyncOrder memory bid = _order(buyer, false, 12 ether, 12 ether);
        _submit(bid);
        _submit(_order(seller, true, 10 ether, 11 ether));
        uint256 sellerQuoteBefore = _quoteOf(seller);

        // The older buy reprices to 1.2, crossing the sell, and the book is cleared.
        vm.prank(buyer);
        hook.updatePrice(bid, 10 ether);
        router.matchBook(key, 1);

        // The buy is still the maker, so the trade is at its 1.2: 10 asset for 12 quote.
        // With the maker flipped to the sell it would be 1.1: 10 asset for 11 quote. The seller receives it less
        // the 0.02% trade fee.
        assertEq(_quoteOf(seller) - sellerQuoteBefore, 12 ether - _fee(12 ether), "price set by the older order");
    }

    /// @dev The 0.02% trade fee, rounded up.
    function _fee(uint256 x) internal pure returns (uint256) {
        return Math.mulDiv(x, 2, 10_000, Math.Rounding.Ceil);
    }

    /// @dev Quote received in any form: ERC-20 balance plus PoolManager claims.
    function _quoteOf(address who) internal view returns (uint256) {
        return token1.balanceOf(who) + manager.balanceOf(who, currency1.toId());
    }

    /// Buyer side: a cheap partial fill does not loosen the buyer's maximum price for the rest.
    function test_M6_favorablePartialFill_keepsBuyerRemainderLimit() public {
        _submit(_order(seller, true, 20 ether, 10 ether));
        AsyncOrder memory bid = _order(buyer, false, 100 ether, 100 ether);
        _submit(bid);

        (uint256 amountIn, uint256 amountOutMin) = hook.asyncOrderInfo(poolId, _id(bid));
        assertEq(amountIn, 90 ether, "buyer spent 10 for 20");
        assertEq(amountOutMin, 90 ether, "remainder keeps the buyer's 1:1 limit");
    }
}
