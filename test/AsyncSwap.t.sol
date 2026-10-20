// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "./SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

contract AsyncSwapTest is SetupHook {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    address alice = makeAddr("alice"); // maker
    address bob = makeAddr("bob"); // filler

    function setUp() public override {
        super.setUp();
        topUp(alice, 100 ether);
        topUp(bob, 100 ether);
    }

    function _orderFromMaker(address maker, bool zeroForOne, uint256 amountIn, uint256 amountOutMin)
        internal
        view
        returns (AsyncOrder memory)
    {
        // Submitters pass `salt = bytes32(0)`; the hook assigns the real salt in `_createOrder`.
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

    /// @dev After router.swap, patch `order.salt` to the hook-assigned salt so cancel/fill/updatePrice
    ///      compute the same orderId the hook stored under.
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

    function _addPoolLiquidity(int128 liquidity) internal returns (PoolModifyLiquidityTest lp) {
        lp = new PoolModifyLiquidityTest(manager);
        token0.mint(address(this), 10_000 ether);
        token1.mint(address(this), 10_000 ether);
        token0.approve(address(lp), type(uint256).max);
        token1.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: liquidity, salt: bytes32(0)}), ""
        );
    }

    function test_lpLiquidityFillsOrderWhenMakerMinimumIsMet() public {
        _addPoolLiquidity(1e24);
        AsyncOrder memory order = _orderFromMaker(alice, true, 1 ether, 0.95 ether);
        uint256 makerOutputBefore = token1.balanceOf(alice);

        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: alice, executor: address(router), amountOutMin: order.amountOutMin, priorityFee: 0
                })
            )
        );
        vm.stopPrank();

        bytes32 id = _orderIdFor(alice, true, _expectedSalt(alice, order.amountIn, order.amountOutMin));
        assertEq(hook.asyncOrder(poolId, id), 0, "LP filled order completely");
        assertGe(token1.balanceOf(alice) - makerOutputBefore, order.amountOutMin, "maker receives minimum output");
        (uint256 feeGrowth0, uint256 feeGrowth1) = manager.getFeeGrowthGlobals(poolId);
        assertTrue(feeGrowth0 > 0 || feeGrowth1 > 0, "v4 fee growth accrues to active LPs");
        (,,, uint24 feeAfter) = manager.getSlot0(poolId);
        assertEq(feeAfter, 0, "temporary LP fill fee is restored after execution");
    }

    function test_lpLiquidityFillsReverseDirection() public {
        _addPoolLiquidity(1e24);
        AsyncOrder memory order = _orderFromMaker(alice, false, 1 ether, 0.95 ether);
        uint256 makerOutputBefore = token0.balanceOf(alice);

        vm.startPrank(alice);
        token1.approve(address(router), type(uint256).max);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: alice, executor: address(router), amountOutMin: order.amountOutMin, priorityFee: 0
                })
            )
        );
        vm.stopPrank();

        bytes32 id = _orderIdFor(alice, false, _expectedSalt(alice, order.amountIn, order.amountOutMin));
        assertEq(hook.asyncOrder(poolId, id), 0, "reverse-direction LP fill completes");
        assertGe(token0.balanceOf(alice) - makerOutputBefore, order.amountOutMin, "reverse maker receives minimum");
    }

    function test_lpPriceFailureLeavesOrderOpenAndRetryCanFill() public {
        AsyncOrder memory order = _orderFromMaker(alice, true, 1 ether, 1.01 ether);
        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: alice, executor: address(router), amountOutMin: order.amountOutMin, priorityFee: 0
                })
            )
        );
        vm.stopPrank();

        bytes32 id = _orderIdFor(alice, true, _expectedSalt(alice, order.amountIn, order.amountOutMin));
        assertEq(hook.asyncOrder(poolId, id), order.amountIn, "order rests without sufficient LP quote");

        _addPoolLiquidity(1e24);
        order.salt = _expectedSalt(alice, order.amountIn, order.amountOutMin);
        vm.prank(bob);
        router.fillFromPoolLiquidity(order);
        assertEq(hook.asyncOrder(poolId, id), order.amountIn, "order remains because LP output is below limit");

        // Tighten to a price the pool can satisfy, then retry against the same LP positions.
        vm.prank(alice);
        hook.updatePrice(order, 0.95 ether);
        order.amountOutMin = 0.95 ether;
        vm.prank(bob);
        router.fillFromPoolLiquidity(order);
        assertEq(hook.asyncOrder(poolId, id), 0, "permissionless retry fills at accepted price");
    }

    /* ------------------------- executor authorization ------------------------- */

    function test_setExecutor_emitsGrant() public {
        address executor = makeAddr("executor");

        vm.expectEmit(true, true, true, true, address(hook));
        emit AsyncSwap.ExecutorSet(poolId, alice, executor, true);
        vm.prank(alice);
        hook.setExecutor(poolId, executor, true);

        assertTrue(hook.isExecutor(poolId, alice, executor), "executor authorized");
    }

    function test_setExecutor_emitsRevocation() public {
        // topUp authorizes the Router for alice during setup.
        vm.expectEmit(true, true, true, true, address(hook));
        emit AsyncSwap.ExecutorSet(poolId, alice, address(router), false);
        vm.prank(alice);
        hook.setExecutor(poolId, address(router), false);

        assertFalse(hook.isExecutor(poolId, alice, address(router)), "executor revoked");
    }

    /* --------------------------------- create --------------------------------- */

    function test_swap_createsOrderWithPrice() public {
        uint256 amountIn = 1 ether;
        uint256 amountOutMin = 0.95 ether;

        AsyncOrder memory order = _orderFromMaker(alice, true, amountIn, amountOutMin);

        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: alice, executor: address(router), amountOutMin: amountOutMin, priorityFee: 0
                })
            )
        );
        vm.stopPrank();

        bytes32 id = _orderIdFor(alice, true, _expectedSalt(alice, amountIn, amountOutMin));
        (uint256 storedIn, uint256 storedOutMin) = hook.asyncOrderInfo(poolId, id);
        assertEq(storedIn, amountIn, "amountIn stored");
        assertEq(storedOutMin, amountOutMin, "amountOutMin stored");
        assertTrue(hook.isExecutor(poolId, alice, address(router)), "router authorized");
    }

    function test_priceBookSortsBidsAndPreservesFifoAtPrice() public {
        AsyncOrder memory first = _orderFromMaker(alice, true, 1 ether, 0.9 ether);
        AsyncOrder memory second = _orderFromMaker(alice, true, 2 ether, 1.8 ether);
        AsyncOrder memory lowerBid = _orderFromMaker(alice, true, 1 ether, 0.95 ether);

        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        router.swap(
            first,
            abi.encode(
                AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 0.9 ether, priorityFee: 0})
            )
        );
        router.swap(
            second,
            abi.encode(
                AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 1.8 ether, priorityFee: 0})
            )
        );
        router.swap(
            lowerBid,
            abi.encode(
                AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 0.95 ether, priorityFee: 0})
            )
        );
        vm.stopPrank();

        bytes32 firstId = _orderIdFor(alice, true, _expectedSalt(alice, 1 ether, 0.9 ether));
        bytes32 secondId = _orderIdFor(alice, true, _expectedSalt(alice, 2 ether, 1.8 ether));
        (bool found, uint128 price, bytes32 bestId,) = hook.bestOrder(poolId, false);
        assertTrue(found, "ask exists");
        assertEq(bestId, firstId, "best ask is lowest price, earliest at tie");
        (bytes32 head, bytes32 tail, uint32 count) = hook.orderBookLevel(poolId, false, price);
        assertEq(head, firstId, "FIFO head");
        assertEq(tail, secondId, "FIFO tail");
        assertEq(count, 2, "two orders at best price");
        (address maker, uint256 amountIn, uint256 amountOutMin,, bool isBuy, bytes32 previous, bytes32 next) =
            hook.orderBookOrder(poolId, head);
        assertEq(maker, alice, "maker is readable");
        assertEq(amountIn, 1 ether, "input amount is readable");
        assertEq(amountOutMin, 0.9 ether, "limit output is readable");
        assertFalse(isBuy, "side is readable");
        assertEq(previous, bytes32(0), "head has no previous order");
        assertEq(next, tail, "head links to next FIFO order");
    }

    function test_priceBookReturnsHighestNumeraireBid() public {
        AsyncOrder memory lowerBid = _orderFromMaker(alice, false, 0.9 ether, 1 ether);
        AsyncOrder memory higherBid = _orderFromMaker(alice, false, 0.95 ether, 1 ether);
        vm.startPrank(alice);
        token1.approve(address(router), type(uint256).max);
        router.swap(
            lowerBid,
            abi.encode(
                AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 1 ether, priorityFee: 0})
            )
        );
        router.swap(
            higherBid,
            abi.encode(
                AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 1 ether, priorityFee: 0})
            )
        );
        vm.stopPrank();

        (bool found,, bytes32 bestId,) = hook.bestOrder(poolId, true);
        assertTrue(found, "bid exists");
        assertEq(
            bestId, _orderIdFor(alice, false, _expectedSalt(alice, 0.95 ether, 1 ether)), "best bid is highest price"
        );
    }

    function test_priceBookUpdateAndCancelMaintainBestLevel() public {
        AsyncOrder memory first = _orderFromMaker(alice, true, 1 ether, 0.9 ether);
        AsyncOrder memory second = _orderFromMaker(alice, true, 1 ether, 0.95 ether);
        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        router.swap(
            first,
            abi.encode(
                AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 0.9 ether, priorityFee: 0})
            )
        );
        router.swap(
            second,
            abi.encode(
                AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 0.95 ether, priorityFee: 0})
            )
        );
        vm.stopPrank();

        first = _withAssignedSalt(first);
        second = _withAssignedSalt(second);
        vm.prank(alice);
        hook.updatePrice(first, 0.8 ether);
        (bool found,, bytes32 bestId,) = hook.bestOrder(poolId, false);
        assertTrue(found, "book still has orders");
        assertEq(bestId, _orderIdFor(alice, true, first.salt), "updated order is reindexed at its improved price");

        vm.prank(alice);
        router.cancelOrder(first);
        (found,, bestId,) = hook.bestOrder(poolId, false);
        assertTrue(found, "other order remains");
        assertEq(bestId, _orderIdFor(alice, true, second.salt), "cancel removes order from price index");
    }

    /* ----------------------------------- fill ---------------------------------- */

    function test_fill_makerReceivesPricedOutput_fillerReceivesInput() public {
        uint256 amountIn = 1 ether;
        uint256 amountOutMin = 0.95 ether;

        AsyncOrder memory order = _orderFromMaker(alice, true, amountIn, amountOutMin);

        // Maker submits.
        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: alice, executor: address(router), amountOutMin: amountOutMin, priorityFee: 0
                })
            )
        );
        vm.stopPrank();

        // Patch salt for the fill leg.
        order = _withAssignedSalt(order);

        uint256 aliceToken0Before = token0.balanceOf(alice);
        uint256 aliceToken1Before = token1.balanceOf(alice);
        uint256 bobToken0Before = token0.balanceOf(bob);
        uint256 bobToken1Before = token1.balanceOf(bob);

        // Bob fills — must pay amountOutMin of token1 (the maker's output side).
        vm.startPrank(bob);
        token1.approve(address(router), type(uint256).max);
        router.fillOrder(order, type(uint256).max, "");
        vm.stopPrank();

        // Order is gone.
        bytes32 id = _orderIdFor(alice, true, order.salt);
        (uint256 leftIn,) = hook.asyncOrderInfo(poolId, id);
        assertEq(leftIn, 0, "order cleared after full fill");

        // Maker received amountOutMin of REAL token1 — no 6909 withdrawal step needed.
        assertEq(token1.balanceOf(alice) - aliceToken1Before, amountOutMin, "maker received real token1");
        assertEq(manager.balanceOf(alice, currency1.toId()), 0, "maker has no leftover 6909 of currency1");
        // Filler received amountIn of real token0 in exchange.
        assertEq(token0.balanceOf(bob) - bobToken0Before, amountIn, "filler got real token0");
        assertEq(
            bobToken1Before - token1.balanceOf(bob),
            amountOutMin + hook.calculatePoolFee(key.fee, amountOutMin),
            "filler paid token1"
        );
        assertEq(aliceToken0Before, token0.balanceOf(alice), "maker token0 unchanged post-fill");
    }

    function test_crossingOrdersMatchAndTransferEscrowedTokens() public {
        uint256 assetAmount = 100 ether;
        uint256 askMinimum = 90 ether;
        uint256 quoteAmount = 100 ether;
        uint256 bidMinimum = 90 ether;
        AsyncOrder memory ask = _orderFromMaker(alice, true, assetAmount, askMinimum);
        AsyncOrder memory bid = _orderFromMaker(bob, false, quoteAmount, bidMinimum);

        uint256 aliceQuoteBefore = token1.balanceOf(alice);
        uint256 bobAssetBefore = token0.balanceOf(bob);
        uint256 bobQuoteBefore = token1.balanceOf(bob);

        vm.startPrank(alice);
        token0.approve(address(router), assetAmount);
        router.swap(
            ask,
            abi.encode(
                AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: askMinimum, priorityFee: 0})
            )
        );
        vm.stopPrank();

        vm.startPrank(bob);
        token1.approve(address(router), quoteAmount);
        router.swap(
            bid,
            abi.encode(
                AsyncSwap.UserParams({user: bob, executor: address(router), amountOutMin: bidMinimum, priorityFee: 0})
            )
        );
        vm.stopPrank();

        bytes32 askId = _orderIdFor(alice, true, _expectedSalt(alice, assetAmount, askMinimum));
        bytes32 bidId = _orderIdFor(bob, false, _expectedSalt(bob, quoteAmount, bidMinimum));
        (uint256 askLeft,) = hook.asyncOrderInfo(poolId, askId);
        (uint256 bidLeft,) = hook.asyncOrderInfo(poolId, bidId);
        assertEq(askLeft, 0, "ask completed");
        assertEq(bidLeft, 0, "bid completed");
        assertEq(token1.balanceOf(alice) - aliceQuoteBefore, askMinimum, "seller receives ask minimum");
        assertEq(token0.balanceOf(bob) - bobAssetBefore, assetAmount, "buyer receives matched asset");
        assertEq(bobQuoteBefore - token1.balanceOf(bob), askMinimum, "buyer pays resting ask price");
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0, "asset escrow claims consumed");
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0, "quote escrow claims consumed");
    }

    function test_crossingOrdersPartiallyFillAndKeepResidualOnBook() public {
        uint256 assetAmount = 100 ether;
        uint256 askMinimum = 90 ether;
        uint256 quoteAmount = 50 ether;
        uint256 bidMinimum = 40 ether;
        AsyncOrder memory ask = _orderFromMaker(alice, true, assetAmount, askMinimum);
        AsyncOrder memory bid = _orderFromMaker(bob, false, quoteAmount, bidMinimum);

        vm.startPrank(alice);
        token0.approve(address(router), assetAmount);
        router.swap(
            ask,
            abi.encode(
                AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: askMinimum, priorityFee: 0})
            )
        );
        vm.stopPrank();

        vm.startPrank(bob);
        token1.approve(address(router), quoteAmount);
        router.swap(
            bid,
            abi.encode(
                AsyncSwap.UserParams({user: bob, executor: address(router), amountOutMin: bidMinimum, priorityFee: 0})
            )
        );
        vm.stopPrank();

        bytes32 askId = _orderIdFor(alice, true, _expectedSalt(alice, assetAmount, askMinimum));
        bytes32 bidId = _orderIdFor(bob, false, _expectedSalt(bob, quoteAmount, bidMinimum));
        (uint256 askLeft, uint256 askMinimumLeft) = hook.asyncOrderInfo(poolId, askId);
        (uint256 bidLeft,) = hook.asyncOrderInfo(poolId, bidId);
        assertGt(askLeft, 0, "unmatched ask remainder stays open");
        assertLt(askLeft, assetAmount, "ask input is reduced by partial fill");
        assertLt(askMinimumLeft, askMinimum, "ask minimum is reduced by output received");
        assertEq(bidLeft, 0, "bid completed and excess quote returned");
        assertEq(manager.balanceOf(address(hook), currency0.toId()), askLeft, "remaining asset remains escrowed");
        vm.prank(alice);
        router.cancelOrder(_withAssignedSalt(ask));
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0, "cancel releases residual escrow");
    }

    function test_priorityFeeBreaksEqualPriceTiesAfterPricePriority() public {
        hook.setOrderingMode(key, AsyncFiller.OrderingMode.PriorityFee);
        AsyncOrder memory earlierLowBid = _withPriorityFee(_orderFromMaker(alice, true, 1 ether, 0.9 ether), 1 ether);
        AsyncOrder memory laterHighBid = _withPriorityFee(_orderFromMaker(bob, true, 1 ether, 0.9 ether), 2 ether);
        uint256 bobNumeraireBefore = token1.balanceOf(bob);

        vm.startPrank(alice);
        token0.approve(address(router), 1 ether);
        token1.approve(address(router), 1 ether);
        router.swap(
            earlierLowBid,
            abi.encode(
                AsyncSwap.UserParams({
                    user: alice, executor: address(router), amountOutMin: 0.9 ether, priorityFee: 1 ether
                })
            )
        );
        vm.stopPrank();

        vm.startPrank(bob);
        token0.approve(address(router), 1 ether);
        token1.approve(address(router), 2 ether);
        router.swap(
            laterHighBid,
            abi.encode(
                AsyncSwap.UserParams({
                    user: bob, executor: address(router), amountOutMin: 0.9 ether, priorityFee: 2 ether
                })
            )
        );
        vm.stopPrank();

        bytes32 lowId = _orderIdFor(alice, true, earlierLowBid.salt);
        bytes32 highId = _orderIdFor(bob, true, laterHighBid.salt);
        (bool found,, bytes32 bestId,) = hook.bestOrder(poolId, false);
        assertTrue(found);
        assertEq(bestId, highId, "better price remains primary; higher bid wins an equal-price tie");

        uint256 takerPriorityFee = 100_000;
        AsyncOrder memory incomingBid =
            _withPriorityFee(_orderFromMaker(alice, false, 1 ether, 1 ether), takerPriorityFee);
        // Use a third maker so the order salt and balances are independent of the resting ask.
        address taker = makeAddr("priorityTaker");
        topUp(taker, 2 ether);
        incomingBid.owner = taker;
        vm.startPrank(taker);
        token1.approve(address(router), 1 ether + takerPriorityFee);
        router.swap(
            incomingBid,
            abi.encode(
                AsyncSwap.UserParams({
                    user: taker, executor: address(router), amountOutMin: 1 ether, priorityFee: takerPriorityFee
                })
            )
        );
        vm.stopPrank();

        assertEq(hook.asyncOrder(poolId, highId), 0, "higher-bid order is matched first");
        assertEq(hook.asyncOrder(poolId, lowId), 1 ether, "lower-bid equal-price order remains open");
        assertLt(token1.balanceOf(bob), bobNumeraireBefore, "the non-refundable bid is charged");
        assertGt(
            manager.balanceOf(address(hook.feeVault()), currency1.toId()),
            0,
            "bids with no active LPs are routed to the FeeVault"
        );
    }

    function test_priorityFeeBelowTenCentsReverts() public {
        hook.setOrderingMode(key, AsyncFiller.OrderingMode.PriorityFee);
        AsyncOrder memory order = _withPriorityFee(_orderFromMaker(alice, true, 1 ether, 0.9 ether), 99_999);

        vm.startPrank(alice);
        token0.approve(address(router), order.amountIn);
        token1.approve(address(router), order.priorityFee);
        vm.expectRevert(); // linked-library errors are wrapped by the hook
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: alice,
                    executor: address(router),
                    amountOutMin: order.amountOutMin,
                    priorityFee: order.priorityFee
                })
            )
        );
        vm.stopPrank();
    }

    function test_partialMatchAndCancelForfeitTheEntirePriorityBid() public {
        hook.setOrderingMode(key, AsyncFiller.OrderingMode.PriorityFee);
        uint256 bidAmount = 2 ether;
        AsyncOrder memory ask = _withPriorityFee(_orderFromMaker(alice, true, 100 ether, 90 ether), bidAmount);
        uint256 buyPriorityFee = 100_000;
        AsyncOrder memory buy = _withPriorityFee(_orderFromMaker(bob, false, 50 ether, 40 ether), buyPriorityFee);
        uint256 usdcBefore = token1.balanceOf(alice);

        vm.startPrank(alice);
        token0.approve(address(router), ask.amountIn);
        token1.approve(address(router), bidAmount);
        router.swap(
            ask,
            abi.encode(
                AsyncSwap.UserParams({
                    user: alice, executor: address(router), amountOutMin: ask.amountOutMin, priorityFee: bidAmount
                })
            )
        );
        vm.stopPrank();
        vm.startPrank(bob);
        token1.approve(address(router), buy.amountIn + buyPriorityFee);
        router.swap(
            buy,
            abi.encode(
                AsyncSwap.UserParams({
                    user: bob, executor: address(router), amountOutMin: buy.amountOutMin, priorityFee: buyPriorityFee
                })
            )
        );
        vm.stopPrank();

        bytes32 askId = _orderIdFor(alice, true, ask.salt);
        uint256 remainingBid = hook.asyncOrderPriorityFee(poolId, askId);
        assertGt(remainingBid, 0, "unfilled portion stays escrowed");
        assertLt(remainingBid, bidAmount, "only the filled proportion is settled");
        vm.prank(alice);
        router.cancelOrder(ask);
        assertEq(token1.balanceOf(alice) - usdcBefore, 48 ether, "the full bid remains charged after cancellation");
        assertEq(
            manager.balanceOf(address(hook.feeVault()), currency1.toId()),
            bidAmount + buyPriorityFee,
            "filled and canceled bid portions both leave maker escrow"
        );
    }

    function test_filledPriorityBidIsDonatedToActiveLpsInsideFill() public {
        hook.setOrderingMode(key, AsyncFiller.OrderingMode.PriorityFee);
        _addPoolLiquidity(1e24);
        uint256 bidAmount = 1 ether;
        AsyncOrder memory ask = _withPriorityFee(_orderFromMaker(alice, true, 1 ether, 0.95 ether), bidAmount);
        token1.approve(address(router), bidAmount);
        (uint256 growth0Before, uint256 growth1Before) = manager.getFeeGrowthGlobals(poolId);

        vm.startPrank(alice);
        token0.approve(address(router), ask.amountIn);
        token1.approve(address(router), bidAmount);
        router.swap(
            ask,
            abi.encode(
                AsyncSwap.UserParams({
                    user: alice, executor: address(router), amountOutMin: ask.amountOutMin, priorityFee: bidAmount
                })
            )
        );
        vm.stopPrank();

        (uint256 growth0After, uint256 growth1After) = manager.getFeeGrowthGlobals(poolId);
        assertTrue(
            growth0After > growth0Before || growth1After > growth1Before,
            "successful fill donates to active LP fee growth"
        );
        assertEq(
            manager.balanceOf(address(hook), currency1.toId()), 0, "priority bid claims are consumed by the donation"
        );
    }

    function test_matchBookContinuesAfterAutomaticMatchBound() public {
        uint256 askInput = 1 ether;
        uint256 askMinimum = 0.9 ether;
        for (uint160 i = 1; i <= 9; ++i) {
            address maker = address(1000 + i);
            topUp(maker, 2 ether);
            AsyncOrder memory ask = _orderFromMaker(maker, true, askInput, askMinimum);
            vm.startPrank(maker);
            token0.approve(address(router), askInput);
            router.swap(
                ask,
                abi.encode(
                    AsyncSwap.UserParams({
                        user: maker, executor: address(router), amountOutMin: askMinimum, priorityFee: 0
                    })
                )
            );
            vm.stopPrank();
        }

        AsyncOrder memory bid = _orderFromMaker(bob, false, 20 ether, 20 ether);
        vm.startPrank(bob);
        token1.approve(address(router), bid.amountIn);
        router.swap(
            bid,
            abi.encode(
                AsyncSwap.UserParams({
                    user: bob, executor: address(router), amountOutMin: bid.amountOutMin, priorityFee: 0
                })
            )
        );
        vm.stopPrank();

        (bool found,,,) = hook.bestOrder(poolId, false);
        assertTrue(found, "one ask remains after eight-match automatic cap");
        for (uint160 i = 1; i <= 9; ++i) {
            address maker = address(1000 + i);
            bytes32 askId = _orderIdFor(maker, true, _expectedSalt(maker, askInput, askMinimum));
            (uint256 remaining,) = hook.asyncOrderInfo(poolId, askId);
            assertEq(remaining, i == 9 ? askInput : 0, "price-time matching leaves only the ninth order");
        }
        router.matchBook(key, 1);
        (found,,,) = hook.bestOrder(poolId, false);
        assertFalse(found, "permissionless continuation clears the last crossed ask");
    }

    function test_fill_revertsWhenOrderMissing() public {
        AsyncOrder memory order = _orderFromMaker(alice, true, 1 ether, 1 ether);
        vm.startPrank(bob);
        token1.approve(address(router), type(uint256).max);
        // Router is alice's executor (topUp grants it), but the order itself
        // was never created — fall through to OrderNotFound.
        vm.expectRevert(AsyncFiller.OrderNotFound.selector);
        router.fillOrder(order, type(uint256).max, "");
        vm.stopPrank();
    }

    /* ----------------------------- update price ----------------------------- */

    function test_updatePrice_makerCanRaisePrice() public {
        uint256 amountIn = 1 ether;
        AsyncOrder memory order = _orderFromMaker(alice, true, amountIn, 0.9 ether);

        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 0.9 ether, priorityFee: 0})
            )
        );
        // Patch salt before updatePrice.
        order = _withAssignedSalt(order);
        // Now raise the limit price — filler must pay more.
        hook.updatePrice(order, 1.2 ether);
        vm.stopPrank();

        bytes32 id = _orderIdFor(alice, true, order.salt);
        (, uint256 outMin) = hook.asyncOrderInfo(poolId, id);
        assertEq(outMin, 1.2 ether);
    }

    function test_updatePrice_revertsForNonOwner() public {
        uint256 amountIn = 1 ether;
        AsyncOrder memory order = _orderFromMaker(alice, true, amountIn, 0.9 ether);

        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 0.9 ether, priorityFee: 0})
            )
        );
        vm.stopPrank();

        order = _withAssignedSalt(order);

        vm.prank(bob);
        vm.expectRevert(AsyncFiller.NotOrderOwner.selector);
        hook.updatePrice(order, 1.2 ether);
    }

    /* -------------------------------- cancel -------------------------------- */

    function test_cancel_makerReclaimsInput() public {
        uint256 amountIn = 1 ether;
        AsyncOrder memory order = _orderFromMaker(alice, true, amountIn, 0.9 ether);

        uint256 aliceToken0Before = token0.balanceOf(alice);

        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 0.9 ether, priorityFee: 0})
            )
        );
        order = _withAssignedSalt(order);
        router.cancelOrder(order);
        vm.stopPrank();

        bytes32 id = _orderIdFor(alice, true, order.salt);
        (uint256 leftIn,) = hook.asyncOrderInfo(poolId, id);
        assertEq(leftIn, 0, "order deleted");
        // Maker reclaimed REAL input tokens — net zero on token0 balance, no 6909 left over.
        assertEq(token0.balanceOf(alice), aliceToken0Before, "maker reclaimed real input");
        assertEq(manager.balanceOf(alice, currency0.toId()), 0, "no leftover 6909 of currency0");
    }

    function test_cancel_revertsForNonOwner() public {
        AsyncOrder memory order = _orderFromMaker(alice, true, 1 ether, 0.9 ether);
        vm.prank(bob);
        vm.expectRevert("Only owner can cancel");
        router.cancelOrder(order);
    }

    /* ----------------------------- reverse direction ----------------------------- */

    function test_fill_reverseDirection_token1ForToken0() public {
        uint256 amountIn = 2 ether;
        uint256 amountOutMin = 1.8 ether;

        AsyncOrder memory order = _orderFromMaker(alice, false, amountIn, amountOutMin);

        vm.startPrank(alice);
        token1.approve(address(router), type(uint256).max);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: alice, executor: address(router), amountOutMin: amountOutMin, priorityFee: 0
                })
            )
        );
        vm.stopPrank();

        order = _withAssignedSalt(order);

        uint256 bobToken0Before = token0.balanceOf(bob);
        uint256 bobToken1Before = token1.balanceOf(bob);
        uint256 aliceToken0Before = token0.balanceOf(alice);

        vm.startPrank(bob);
        token0.approve(address(router), type(uint256).max);
        router.fillOrder(order, type(uint256).max, "");
        vm.stopPrank();

        // Maker received real currency0 (the maker's chosen output); filler paid currency0 and
        // received currency1 (the maker's input).
        assertEq(token0.balanceOf(alice) - aliceToken0Before, amountOutMin, "maker received real token0");
        assertEq(
            bobToken0Before - token0.balanceOf(bob),
            amountOutMin + hook.calculatePoolFee(key.fee, amountOutMin),
            "filler paid token0"
        );
        assertEq(token1.balanceOf(bob) - bobToken1Before, amountIn, "filler received token1");
    }

    /* ------------------------- multiple orders per maker ------------------------- */

    function test_swap_twoOrdersSameMaker_distinctSalts() public {
        // Distinct (amountIn, amountOutMin) tuples => distinct salts => distinct orderIds.
        AsyncOrder memory o1 = _orderFromMaker(alice, true, 1 ether, 0.9 ether);
        AsyncOrder memory o2 = _orderFromMaker(alice, true, 0.5 ether, 0.45 ether);

        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        router.swap(
            o1,
            abi.encode(
                AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 0.9 ether, priorityFee: 0})
            )
        );
        token0.approve(address(router), type(uint256).max);
        router.swap(
            o2,
            abi.encode(
                AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 0.45 ether, priorityFee: 0})
            )
        );
        vm.stopPrank();

        bytes32 id1 = _orderIdFor(alice, true, _expectedSalt(alice, 1 ether, 0.9 ether));
        bytes32 id2 = _orderIdFor(alice, true, _expectedSalt(alice, 0.5 ether, 0.45 ether));
        (uint256 in1,) = hook.asyncOrderInfo(poolId, id1);
        (uint256 in2,) = hook.asyncOrderInfo(poolId, id2);
        assertEq(in1, 1 ether, "order 1 stored");
        assertEq(in2, 0.5 ether, "order 2 stored");
    }

    /// @notice With contract-assigned salts, duplicate (user, amountIn, amountOutMin) tuples in the
    ///         same block trigger the in-contract salt-walk: the second order lands on a re-hashed
    ///         salt rather than colliding. Both submissions must succeed and produce distinct ids.
    function test_swap_duplicateParamsTriggerSaltWalk() public {
        AsyncOrder memory order = _orderFromMaker(alice, true, 1 ether, 0.9 ether);

        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 0.9 ether, priorityFee: 0})
            )
        );
        token0.approve(address(router), type(uint256).max);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 0.9 ether, priorityFee: 0})
            )
        );
        vm.stopPrank();

        // First salt = base prediction; second salt = keccak256(firstSalt) per the walk.
        bytes32 firstSalt = _expectedSalt(alice, 1 ether, 0.9 ether);
        bytes32 secondSalt = keccak256(abi.encode(firstSalt));
        bytes32 id1 = _orderIdFor(alice, true, firstSalt);
        bytes32 id2 = _orderIdFor(alice, true, secondSalt);
        assertTrue(id1 != id2, "salt-walk produced distinct ids");
        (uint256 in1,) = hook.asyncOrderInfo(poolId, id1);
        (uint256 in2,) = hook.asyncOrderInfo(poolId, id2);
        assertEq(in1, 1 ether, "first order stored");
        assertEq(in2, 1 ether, "second order stored after salt walk");
    }

    /* ----------------------- updated price affects fill ----------------------- */

    function test_fill_usesUpdatedPrice() public {
        uint256 amountIn = 1 ether;
        AsyncOrder memory order = _orderFromMaker(alice, true, amountIn, 0.8 ether);

        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 0.8 ether, priorityFee: 0})
            )
        );
        order = _withAssignedSalt(order);
        // Maker raises price after submission.
        hook.updatePrice(order, 1.1 ether);
        vm.stopPrank();

        uint256 bobToken1Before = token1.balanceOf(bob);
        uint256 aliceToken1Before = token1.balanceOf(alice);
        vm.startPrank(bob);
        token1.approve(address(router), type(uint256).max);
        router.fillOrder(order, type(uint256).max, "");
        vm.stopPrank();

        // Filler paid the *updated* 1.1 ether, not the original 0.8 ether.
        assertEq(
            bobToken1Before - token1.balanceOf(bob),
            1.1 ether + hook.calculatePoolFee(key.fee, 1.1 ether),
            "filler paid updated price"
        );
        assertEq(token1.balanceOf(alice) - aliceToken1Before, 1.1 ether, "maker received updated price");
    }

    /* -------------------- ordering invariants after cancel -------------------- */

    function test_fill_revertsAfterCancel() public {
        uint256 amountIn = 1 ether;
        AsyncOrder memory order = _orderFromMaker(alice, true, amountIn, 0.9 ether);

        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 0.9 ether, priorityFee: 0})
            )
        );
        order = _withAssignedSalt(order);
        router.cancelOrder(order);
        vm.stopPrank();

        // Now Bob tries to fill — order is gone.
        vm.startPrank(bob);
        token1.approve(address(router), type(uint256).max);
        vm.expectRevert(AsyncFiller.OrderNotFound.selector);
        router.fillOrder(order, type(uint256).max, "");
        vm.stopPrank();
    }

    function test_cancel_revertsAfterFill() public {
        uint256 amountIn = 1 ether;
        AsyncOrder memory order = _orderFromMaker(alice, true, amountIn, 0.9 ether);

        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 0.9 ether, priorityFee: 0})
            )
        );
        vm.stopPrank();

        order = _withAssignedSalt(order);

        vm.startPrank(bob);
        token1.approve(address(router), type(uint256).max);
        router.fillOrder(order, type(uint256).max, "");
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(AsyncFiller.OrderNotFound.selector);
        router.cancelOrder(order);
    }
}
