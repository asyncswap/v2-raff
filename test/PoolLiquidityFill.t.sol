// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {HuffDeploy} from "./utils/HuffDeploy.sol";

import {SetupHook} from "./SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {Router} from "@async-swap/Router.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {ISignatureTransfer} from "@async-swap/interfaces/ISignatureTransfer.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {Permit2Bytecode} from "./utils/Permit2Bytecode.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Edge cases of the guarded pool-liquidity fill path (`AsyncMatching.fillFromPoolLiquidity`).
///         The happy paths live in AsyncSwap.t.sol; this file covers the revert branches, the
///         interaction with book matching, escrow accounting, access control and a fuzzed
///         "fill or rest untouched" property.
contract PoolLiquidityFillTest is SetupHook {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    bytes32 constant LIQUIDITY_FILLED_TOPIC =
        keccak256("AsyncOrderLiquidityFilled(bytes32,bytes32,address,uint256,uint256)");
    bytes32 constant MATCHED_TOPIC = keccak256("AsyncOrdersMatched(bytes32,bytes32,bytes32,uint256,uint256)");

    address alice = makeAddr("alice"); // maker
    address bob = makeAddr("bob"); // resting counterparty / permissionless retrier

    function setUp() public override {
        super.setUp();
        topUp(alice, 10_000 ether);
        topUp(bob, 100 ether);
    }

    /* ----------------------------------- helpers ----------------------------------- */

    function _order(address maker, bool zeroForOne, uint256 amountIn, uint256 amountOutMin)
        internal
        view
        returns (AsyncOrder memory)
    {
        return AsyncOrder({
            key: key,
            owner: maker,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            priorityFee: 0,
            sqrtPrice: 2 ** 96,
            salt: bytes32(0)
        });
    }

    function _withAssignedSalt(AsyncOrder memory order) internal view returns (AsyncOrder memory) {
        order.salt = _expectedSalt(order.owner, order.amountIn, order.amountOutMin);
        return order;
    }

    function _withPriorityFee(AsyncOrder memory order, uint256 priorityFee) internal view returns (AsyncOrder memory) {
        order.priorityFee = priorityFee;
        order.salt = keccak256(
            abi.encode(
                block.timestamp,
                block.number,
                address(manager),
                order.owner,
                order.amountIn,
                order.amountOutMin,
                priorityFee
            )
        );
        return order;
    }

    function _id(AsyncOrder memory order) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, poolId, order.owner, order.zeroForOne, order.salt));
    }

    /// @dev Submit through the Router as the maker. Returns the order patched with its assigned salt.
    function _submit(AsyncOrder memory order) internal returns (AsyncOrder memory) {
        MockERC20 input = order.zeroForOne ? token0 : token1;
        vm.startPrank(order.owner);
        input.approve(address(router), order.amountIn);
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
        return order.priorityFee == 0 ? _withAssignedSalt(order) : order;
    }

    /// @dev Concentrated position around the 1:1 pool price. 1e24 liquidity over [-60, 60] holds
    ///      roughly 3,000 units of each token, so orders above that exhaust the range.
    function _addPoolLiquidity(int128 liquidity, int24 tickLower, int24 tickUpper) internal {
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);
        token0.approve(address(lp), type(uint256).max);
        token1.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidity, salt: 0}),
            ""
        );
    }

    function _addPoolLiquidity(int128 liquidity) internal {
        _addPoolLiquidity(liquidity, -60, 60);
    }

    function _escrow(Currency currency) internal view returns (uint256) {
        return manager.balanceOf(address(hook), currency.toId());
    }

    function _countTopic(Vm.Log[] memory logs, bytes32 topic) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic) ++n;
        }
    }

    function _assertPoolUntouched(uint160 sqrtPriceBefore) internal view {
        (uint160 sqrtPrice,,, uint24 lpFee) = manager.getSlot0(poolId);
        assertEq(sqrtPrice, sqrtPriceBefore, "failed fill must not move the pool price");
        assertEq(lpFee, 0, "failed fill must restore the dynamic LP fee");
    }

    /* ------------------------------ revert branches ------------------------------ */

    /// No LP position at all: `NoActiveLiquidity` is swallowed, the order rests with full escrow.
    function test_noLiquidity_orderRestsAndEscrowIsIntact() public {
        assertEq(manager.getLiquidity(poolId), 0, "precondition: empty pool");
        AsyncOrder memory order = _order(alice, true, 1 ether, 1);

        vm.recordLogs();
        order = _submit(order);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(hook.asyncOrder(poolId, _id(order)), 1 ether, "order rests");
        assertEq(_escrow(currency0), 1 ether, "maker input stays escrowed as hook claims");
        assertEq(_countTopic(logs, LIQUIDITY_FILLED_TOPIC), 0, "no liquidity-fill event");
        _assertPoolUntouched(2 ** 96);

        // A permissionless retry on the still-empty pool is a no-op, not a revert.
        vm.prank(bob);
        router.fillFromPoolLiquidity(order);
        assertEq(hook.asyncOrder(poolId, _id(order)), 1 ether, "retry leaves the order resting");
        assertEq(_escrow(currency0), 1 ether, "retry leaves escrow intact");
    }

    /// Liquidity exists but only out of range of the current tick: `getLiquidity` is zero.
    function test_outOfRangeLiquidityCountsAsNoLiquidity() public {
        _addPoolLiquidity(1e24, 120, 240); // entirely above the current tick 0
        assertEq(manager.getLiquidity(poolId), 0, "precondition: nothing active at tick 0");

        AsyncOrder memory order = _submit(_order(alice, true, 1 ether, 1));
        assertEq(hook.asyncOrder(poolId, _id(order)), 1 ether, "order rests when active liquidity is zero");
        assertEq(_escrow(currency0), 1 ether);
        _assertPoolUntouched(2 ** 96);
    }

    /// An order larger than the in-range inventory runs the curve dry. The swap would only
    /// partially consume the input, so `PartialLiquidityFill` reverts the whole attempt and
    /// the pool state (price, fee) is rolled back with it.
    function test_orderLargerThanRangeIsRejectedAtomically() public {
        _addPoolLiquidity(1e24); // ~3,000 token0 of capacity below tick 0
        uint256 amountIn = 5_000 ether;
        AsyncOrder memory order = _order(alice, true, amountIn, 1); // limit cannot be the reason

        vm.recordLogs();
        order = _submit(order);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(hook.asyncOrder(poolId, _id(order)), amountIn, "oversized order rests");
        assertEq(_escrow(currency0), amountIn, "full input remains escrowed");
        assertEq(_countTopic(logs, LIQUIDITY_FILLED_TOPIC), 0);
        _assertPoolUntouched(2 ** 96);

        // Adding depth later lets the same order fill through the permissionless retry.
        _addPoolLiquidity(1e25);
        vm.prank(bob);
        router.fillFromPoolLiquidity(order);
        assertEq(hook.asyncOrder(poolId, _id(order)), 0, "deeper pool fills the resting order");
        assertEq(_escrow(currency0), 0, "escrow fully released");
    }

    /// Limit-price failure must leave the dynamic fee and the price exactly where they were.
    function test_limitFailureRestoresFeeAndPrice() public {
        _addPoolLiquidity(1e24);
        AsyncOrder memory order = _submit(_order(alice, true, 1 ether, 1.5 ether));
        assertEq(hook.asyncOrder(poolId, _id(order)), 1 ether, "limit above pool price rests");
        _assertPoolUntouched(2 ** 96);

        vm.prank(bob);
        router.fillFromPoolLiquidity(order);
        assertEq(hook.asyncOrder(poolId, _id(order)), 1 ether);
        _assertPoolUntouched(2 ** 96);
    }

    /// In priority-fee mode a failed pool fill must not touch the maker's escrowed bid: it is
    /// neither donated nor forfeited until the order actually fills or terminates.
    function test_failedPoolFillKeepsPriorityBidEscrowed() public {
        hook.setOrderingMode(key, AsyncFiller.OrderingMode.PriorityFee);
        uint256 bid = 1 ether;
        AsyncOrder memory order = _withPriorityFee(_order(alice, true, 1 ether, 0.95 ether), bid);

        vm.startPrank(alice);
        token1.approve(address(router), bid);
        vm.stopPrank();
        order = _submit(order); // no liquidity: the LP attempt fails

        bytes32 id = _id(order);
        assertEq(hook.asyncOrder(poolId, id), 1 ether, "order rests");
        assertEq(hook.asyncOrderPriorityFee(poolId, id), bid, "bid still attached to the order");
        assertEq(_escrow(currency1), bid, "bid still held as hook claims");
        assertEq(manager.balanceOf(address(hook.feeVault()), currency1.toId()), 0, "nothing forfeited");
    }

    /* ------------------------------ successful fills ------------------------------ */

    /// A fill burns exactly the maker's escrow, pays the maker in ERC20 (not claims), moves the
    /// pool price in the swap direction and reports the real amounts in the event.
    function test_fillAccountingAndEvent() public {
        _addPoolLiquidity(1e24);
        uint256 amountIn = 2 ether;
        uint256 makerOutBefore = token1.balanceOf(alice);

        vm.recordLogs();
        AsyncOrder memory order = _submit(_order(alice, true, amountIn, 1.9 ether));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 received = token1.balanceOf(alice) - makerOutBefore;
        assertGe(received, 1.9 ether, "maker paid at least the limit");
        assertLt(received, amountIn, "pool fee and impact reduce output below 1:1");
        assertEq(hook.asyncOrder(poolId, _id(order)), 0, "order removed");
        assertEq(_escrow(currency0), 0, "input escrow burned");
        assertEq(_escrow(currency1), 0, "hook holds no output claims");
        assertEq(manager.balanceOf(alice, currency1.toId()), 0, "ERC20 output is transferred, not minted as claims");

        (uint160 sqrtPriceAfter,,, uint24 feeAfter) = manager.getSlot0(poolId);
        assertLt(sqrtPriceAfter, 2 ** 96, "zeroForOne fill lowers the pool price");
        assertEq(feeAfter, 0, "temporary 30 bps fee restored");

        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != LIQUIDITY_FILLED_TOPIC) continue;
            (uint256 loggedIn, uint256 loggedOut) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(loggedIn, amountIn, "event amountIn");
            assertEq(loggedOut, received, "event amountOut matches what the maker received");
            ++seen;
        }
        assertEq(seen, 1, "exactly one liquidity-fill event");
    }

    /// Book first, pool second: the incoming order matches a resting counterparty for part of
    /// its size and the pool absorbs only the remainder.
    function test_bookMatchesFirstThenPoolFillsRemainder() public {
        _addPoolLiquidity(1e24);
        // Bob bids 0.5 token1 for at least 0.5 token0 (1:1).
        _submit(_order(bob, false, 0.5 ether, 0.5 ether));
        assertEq(_escrow(currency1), 0.5 ether, "bob's bid rests (pool is 1:1 minus fee, below his limit)");

        uint256 aliceOutBefore = token1.balanceOf(alice);
        vm.recordLogs();
        AsyncOrder memory ask = _submit(_order(alice, true, 1 ether, 0.95 ether));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countTopic(logs, MATCHED_TOPIC), 1, "one book match");
        assertEq(_countTopic(logs, LIQUIDITY_FILLED_TOPIC), 1, "one pool fill for the remainder");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != LIQUIDITY_FILLED_TOPIC) continue;
            (uint256 loggedIn,) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(loggedIn, 0.5 ether, "pool only sees what the book left");
        }
        assertEq(hook.asyncOrder(poolId, _id(ask)), 0, "ask fully executed");
        assertEq(_escrow(currency0), 0, "no token0 escrow left");
        assertEq(_escrow(currency1), 0, "bob's bid fully consumed");
        uint256 received = token1.balanceOf(alice) - aliceOutBefore;
        assertGe(received, 0.95 ether, "maker limit respected across both legs");
        assertGt(received, 0.5 ether + 0.49 ether, "0.5 from bob plus ~0.5 from the pool");
    }

    /// After a partial book match, the shrunken remainder (and its reduced minimum) is what the
    /// pool is asked to fill on a later permissionless retry.
    function test_retryFillsPartiallyMatchedRemainder() public {
        _submit(_order(bob, false, 0.5 ether, 0.5 ether));
        AsyncOrder memory ask = _submit(_order(alice, true, 1 ether, 0.95 ether)); // no pool yet
        bytes32 id = _id(ask);
        (uint256 remaining, uint256 remainingMin) = hook.asyncOrderInfo(poolId, id);
        assertEq(remaining, 0.5 ether, "half matched against bob");
        assertEq(remainingMin, 0.45 ether, "minimum reduced by what bob already paid");

        _addPoolLiquidity(1e24);
        vm.prank(bob);
        router.fillFromPoolLiquidity(ask);
        assertEq(hook.asyncOrder(poolId, id), 0, "remainder filled from the pool");
        assertEq(_escrow(currency0), 0);
    }

    /// The 30 bps fill fee is charged on the maker's input and accrues to the active LP: the
    /// position ends holding the whole input (curve share plus fee share) and paid out less
    /// than 1:1 in the other token.
    function test_lpCollectsFillFeeOnWithdraw() public {
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);
        token0.approve(address(lp), type(uint256).max);
        token1.approve(address(lp), type(uint256).max);
        uint256 t0Before = token0.balanceOf(address(this));
        uint256 t1Before = token1.balanceOf(address(this));
        lp.modifyLiquidity(key, ModifyLiquidityParams(-60, 60, 1e24, 0), "");

        uint256 amountIn = 10 ether;
        _submit(_order(alice, true, amountIn, 9 ether));

        (uint256 feeGrowth0, uint256 feeGrowth1) = manager.getFeeGrowthGlobals(poolId);
        uint256 expectedGrowth0 = (amountIn * 3 / 1000) * (2 ** 128) / 1e24; // fee * Q128 / liquidity
        assertApproxEqRel(feeGrowth0, expectedGrowth0, 0.01e18, "30 bps of the input accrues as token0 fee growth");
        assertEq(feeGrowth1, 0, "no fee charged on the output side");

        lp.modifyLiquidity(key, ModifyLiquidityParams(-60, 60, -1e24, 0), "");
        uint256 t0Net = token0.balanceOf(address(this)) - t0Before; // > 0: LP absorbed the input
        uint256 t1Net = t1Before - token1.balanceOf(address(this)); // > 0: LP paid the output
        assertApproxEqAbs(
            t0Net, amountIn, 1e6, "LP ends holding the maker's full input (curve share + fee), minus rounding dust"
        );
        assertLt(t1Net, amountIn, "LP paid less than 1:1");
        assertGt(t1Net, amountIn * 99 / 100, "...but only by the fee plus a little impact");
    }

    /* ------------------------------- access control ------------------------------- */

    function test_directSelfCallEntryIsRejected() public {
        _addPoolLiquidity(1e24);
        AsyncOrder memory order = _submit(_order(alice, true, 1 ether, 1.5 ether));
        vm.expectRevert(AsyncSwap.NotSelf.selector);
        hook.fillOrderFromPoolLiquidity(order, _id(order));
        vm.prank(address(router));
        vm.expectRevert(AsyncSwap.NotSelf.selector);
        hook.fillOrderFromPoolLiquidity(order, _id(order));
    }

    function test_retryRequiresMakerAuthorizedExecutor() public {
        AsyncOrder memory order = _submit(_order(alice, true, 1 ether, 1.5 ether));
        _addPoolLiquidity(1e24);
        vm.prank(alice);
        hook.setExecutor(poolId, address(router), false);

        vm.prank(bob);
        vm.expectRevert(AsyncFiller.NotAuthorizedExecutor.selector);
        router.fillFromPoolLiquidity(order);
        assertEq(hook.asyncOrder(poolId, _id(order)), 1 ether, "order untouched");
    }

    function test_retryUnknownOrderReverts() public {
        _addPoolLiquidity(1e24);
        AsyncOrder memory ghost = _withAssignedSalt(_order(alice, true, 1 ether, 0.5 ether));
        vm.prank(bob);
        vm.expectRevert(AsyncFiller.OrderNotFound.selector);
        router.fillFromPoolLiquidity(ghost);
    }

    /// A filled order cannot be retried: its id is gone from storage.
    function test_retryAfterFillReverts() public {
        _addPoolLiquidity(1e24);
        AsyncOrder memory order = _submit(_order(alice, true, 1 ether, 0.95 ether));
        assertEq(hook.asyncOrder(poolId, _id(order)), 0, "precondition: filled on submit");
        vm.prank(bob);
        vm.expectRevert(AsyncFiller.OrderNotFound.selector);
        router.fillFromPoolLiquidity(order);
    }

    /* ---------------------------------- property ---------------------------------- */

    /// For any size and limit, a submit either fills completely at or above the limit with no
    /// escrow left, or rests with the full input escrowed and the pool untouched. Never anything
    /// in between.
    function testFuzz_fillOrRestUntouched(uint256 amountIn, uint256 limitBps, bool zeroForOne) public {
        _addPoolLiquidity(1e24);
        amountIn = bound(amountIn, 1e12, 100 ether);
        limitBps = bound(limitBps, 9_000, 10_100);
        uint256 amountOutMin = amountIn * limitBps / 10_000;
        vm.assume(amountOutMin > 0);

        Currency input = zeroForOne ? currency0 : currency1;
        MockERC20 output = zeroForOne ? token1 : token0;
        uint256 outBefore = output.balanceOf(alice);

        AsyncOrder memory order = _submit(_order(alice, zeroForOne, amountIn, amountOutMin));
        uint256 remaining = hook.asyncOrder(poolId, _id(order));
        uint256 received = output.balanceOf(alice) - outBefore;

        if (remaining == 0) {
            assertGe(received, amountOutMin, "filled: limit honored");
            assertEq(_escrow(input), 0, "filled: escrow burned");
            (uint160 sqrtPrice,,, uint24 fee) = manager.getSlot0(poolId);
            assertTrue(zeroForOne ? sqrtPrice < 2 ** 96 : sqrtPrice > 2 ** 96, "filled: price moved with the swap");
            assertEq(fee, 0, "filled: fee restored");
        } else {
            assertEq(remaining, amountIn, "rest: nothing partially consumed");
            assertEq(received, 0, "rest: maker paid nothing");
            assertEq(_escrow(input), amountIn, "rest: full escrow");
            _assertPoolUntouched(2 ** 96);
        }
    }
}

/// @notice The production shape: an 18-decimal asset against 6-decimal USDC, pool priced at
///         2,000 USDC per asset. Checks that raw-unit limits and the fill fee behave across the
///         decimal gap in both directions.
contract PoolLiquidityFillSixDecimalTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // sqrt(2000e6 / 1e18) * 2^96, i.e. 2,000 USDC per asset with the asset as currency0.
    uint160 constant SQRT_PRICE_2000 = 3543191142285914327220224;
    int24 constant TICK_2000 = -200311;

    IPoolManager manager;
    AsyncSwap hook;
    Router router;
    MockERC20 asset;
    MockERC20 usdc;
    PoolKey key;
    PoolId poolId;
    address maker = makeAddr("maker");

    function setUp() public {
        manager = new PoolManager(address(this));
        // Fixed addresses pin the currency ordering: asset is currency0, USDC is currency1.
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Asset", "ASSET", uint8(18)), address(0x10000));
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("USD Coin", "USDC", uint8(6)), address(0x20000));
        asset = MockERC20(address(0x10000));
        usdc = MockERC20(address(0x20000));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        HuffDeploy.hookTo(abi.encode(manager, Currency.wrap(address(usdc)), address(this)), address(flags));
        hook = AsyncSwap(payable(address(flags)));
        router = HuffDeploy.router(manager, hook, ISignatureTransfer(Permit2Bytecode.PERMIT2));

        key = PoolKey(
            Currency.wrap(address(asset)), Currency.wrap(address(usdc)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 1, hook
        );
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_2000);

        // ~1% band around the current price; 1e20 liquidity is ~10k asset / ~20M USDC of depth.
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        asset.mint(address(this), 1e30);
        usdc.mint(address(this), 1e30);
        asset.approve(address(lp), type(uint256).max);
        usdc.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(key, ModifyLiquidityParams(TICK_2000 - 100, TICK_2000 + 100, 1e20, 0), "");

        asset.mint(maker, 1_000 ether);
        usdc.mint(maker, 10_000_000e6);
        vm.startPrank(maker);
        asset.approve(address(router), type(uint256).max);
        usdc.approve(address(router), type(uint256).max);
        hook.setExecutor(poolId, address(router), true);
        vm.stopPrank();
    }

    function _submit(bool zeroForOne, uint256 amountIn, uint256 amountOutMin) internal returns (bytes32 id) {
        AsyncOrder memory order = AsyncOrder(key, maker, zeroForOne, amountIn, amountOutMin, 0, SQRT_PRICE_2000, 0);
        vm.prank(maker);
        router.swap(order, abi.encode(AsyncSwap.UserParams(maker, address(router), amountOutMin, 0)));
        bytes32 salt =
            keccak256(abi.encode(block.timestamp, block.number, address(manager), maker, amountIn, amountOutMin, 0));
        return keccak256(abi.encode(block.chainid, poolId, maker, zeroForOne, salt));
    }

    function test_sellAssetForUsdcAtMarket() public {
        uint256 usdcBefore = usdc.balanceOf(maker);
        bytes32 id = _submit(true, 1 ether, 1_990e6);
        assertEq(hook.asyncOrder(poolId, id), 0, "1 asset fills against the pool");
        uint256 received = usdc.balanceOf(maker) - usdcBefore;
        assertGe(received, 1_990e6, "limit in raw USDC units honored");
        assertLe(received, 2_000e6 * 997 / 1000, "at most spot minus the 30 bps fill fee");
    }

    function test_buyAssetWithUsdcAtMarket() public {
        uint256 assetBefore = asset.balanceOf(maker);
        bytes32 id = _submit(false, 2_000e6, 0.99 ether);
        assertEq(hook.asyncOrder(poolId, id), 0, "2,000 USDC fills against the pool");
        uint256 received = asset.balanceOf(maker) - assetBefore;
        assertGe(received, 0.99 ether, "limit in asset wei honored");
        assertLe(received, 0.997 ether, "at most spot minus the fill fee");
    }

    function test_limitAboveSpotRestsOnBothSides() public {
        bytes32 ask = _submit(true, 1 ether, 2_001e6);
        assertEq(hook.asyncOrder(poolId, ask), 1 ether, "ask above spot rests");
        bytes32 bid = _submit(false, 2_000e6, 1.001 ether);
        assertEq(hook.asyncOrder(poolId, bid), 2_000e6, "bid above spot rests");
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 1 ether, "asset escrow");
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 2_000e6, "USDC escrow");
        (uint160 sqrtPrice,,, uint24 fee) = manager.getSlot0(poolId);
        assertEq(sqrtPrice, SQRT_PRICE_2000, "resting orders leave the pool price untouched");
        assertEq(fee, 0, "fee restored after both failed attempts");
    }

    /// A dust-sized USDC input must not produce a zero-output "fill". `outputDelta <= 0` is a
    /// LimitPriceNotMet, so the order rests instead of being deleted for nothing.
    function test_dustInputNeverFillsForZeroOutput() public {
        uint256 assetBefore = asset.balanceOf(maker);
        bytes32 id = _submit(false, 1, 1); // 1 raw USDC unit for at least 1 wei of asset
        uint256 remaining = hook.asyncOrder(poolId, id);
        uint256 received = asset.balanceOf(maker) - assetBefore;
        if (remaining == 0) assertGe(received, 1, "if it filled, it paid at least the limit");
        else assertEq(received, 0, "if it rests, nothing was paid");
    }
}
