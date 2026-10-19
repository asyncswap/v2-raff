// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {IAsyncSwap} from "./utils/IAsyncSwap.sol";
import {AsyncOrder, AsyncOrderLibrary} from "./reference/AsyncOrder.sol";
import {AsyncFiller} from "./utils/IAsyncSwap.sol";

/// @dev Matching, priority, repricing, liquidity fills. Spec: `AsyncSwapSpec/Match.lean`, `Reduce.lean`
///      (`maker_limit_honored`, `runLegs_amountIn`, `runLegs_priorityFee`), `Priority.lean`,
///      `AsyncSwapProtocol/V2/Model.lean` (`matchLoop`, `matchBook`, `liquidityFillBody`).
contract MatchingTest is BaseTest {
    using AsyncOrderLibrary for AsyncOrder;
    using PoolIdLibrary for PoolKey;

    event OrdersMatched(
        PoolId indexed poolId, bytes32 indexed sellId, bytes32 indexed buyId, uint256 asset, uint256 quote
    );

    /// A crossing order is matched in the create unlock: no fee, both closed, hook claims back to zero.
    function test_match_fullFill() public {
        AsyncOrder memory s = _sell(key, maker, 1e18, 2e18, 0);
        bytes32 sellId = _place(s);
        AsyncOrder memory b = _buy(key, maker2, 2e18, 1e18, 0);
        uint256 maker1 = _bal(currency1, maker);
        uint256 maker2_0 = _bal(currency0, maker2);

        vm.expectEmit(true, true, true, true);
        emit OrdersMatched(key.toId(), sellId, b.orderId(), 1e18, 2e18);
        bytes32 buyId = _place(b);

        assertFalse(_open(key, sellId));
        assertFalse(_open(key, buyId));
        assertEq(_bal(currency1, maker), maker1 + 2e18);
        assertEq(_bal(currency0, maker2), maker2_0 + 1e18);
        assertEq(_claims(currency0, address(hook)), 0);
        assertEq(_claims(currency1, address(hook)), 0);
        assertEq(_claims(currency1, address(vault)), 0, "no protocol fee on matches");
        assertEq(hook.openOrders(key), 0);
    }

    function test_match_noCrossRests() public {
        bytes32 sellId = _place(_sell(key, maker, 1e18, 3e18, 0)); // ask 3
        bytes32 buyId = _place(_buy(key, maker2, 2e18, 1e18, 0)); // bid 2
        assertTrue(_open(key, sellId) && _open(key, buyId));
        assertEq(_claims(currency0, address(hook)), 1e18);
        assertEq(_claims(currency1, address(hook)), 2e18);
    }

    /// `maker_limit_honored` / `runLegs_amountIn`: across two partial legs the resting seller receives at
    /// least the minimum they signed and all of their input is consumed; the resting price sizes each leg.
    function test_match_partialFills_makerLimitHonored() public {
        AsyncOrder memory s = _sell(key, maker, 1e18, 2e18, 0); // ask 2
        bytes32 sellId = _place(s);
        uint256 maker1 = _bal(currency1, maker);

        bytes32 b1 = _place(_buy(key, maker2, 1e18, 0.5e18, 0)); // 1 quote at bid 2 → half the seller
        assertFalse(_open(key, b1));
        AsyncFiller.OrderInfo memory info = hook.getOrder(key, sellId);
        assertEq(info.amountIn, 0.5e18);
        assertEq(info.amountOutMin, 1e18);
        assertEq(info.priceKey, 2e18, "price key unchanged");
        assertEq(info.sequence, 1, "a partial fill keeps time priority");
        assertEq(_claims(currency0, address(hook)), 0.5e18);

        uint256 maker3_1 = _bal(currency1, maker3);
        bytes32 b2 = _place(_buy(key, maker3, 1.5e18, 0.5e18, 0)); // bid 3, but trades at the resting ask 2
        assertFalse(_open(key, sellId));
        // the buyer's minimum is met by 0.5 asset for 1 quote: it closes and the unused 0.5 quote is refunded
        assertFalse(_open(key, b2));
        assertEq(_bal(currency1, maker3), maker3_1 - 1e18, "buyer paid the resting price, rest refunded");
        assertEq(_bal(currency1, maker), maker1 + 2e18, "seller received exactly the signed minimum");
        assertEq(_claims(currency0, address(hook)), 0);
        assertEq(_claims(currency1, address(hook)), 0);
    }

    /// `bestAtPrice_priority` (PriorityFee mode): higher bid first, equal bids by earlier sequence.
    function test_priority_bidFirstThenFifo() public {
        bytes32 s1 = _place(_sell(prioKey, maker, 1e18, 2e18, 1e6));
        bytes32 s2 = _place(_sell(prioKey, maker2, 1e18, 2e18, 3e6));
        bytes32 s3 = _place(_sell(prioKey, maker3, 1e18, 2e18, 3e6));
        (bytes32 best,) = hook.bestOrder(prioKey, false);
        assertEq(best, s2);

        _place(_buy(prioKey, keeper, 2e18, 1e18, 1e5));
        assertFalse(_open(prioKey, s2));
        (best,) = hook.bestOrder(prioKey, false);
        assertEq(best, s3);

        _place(_buy(prioKey, keeper, 2e18, 1e18, 1e5));
        assertFalse(_open(prioKey, s3));
        (best,) = hook.bestOrder(prioKey, false);
        assertEq(best, s1);

        _place(_buy(prioKey, keeper, 2e18, 1e18, 1e5));
        assertFalse(_open(prioKey, s1));
        assertEq(hook.openOrders(prioKey), 0);
        assertEq(_claims(currency1, address(hook)), 0, "every bid settled");
    }

    /// `fifo_head_earliest` (FIFO mode).
    function test_fifo_earliestFirst() public {
        bytes32 s1 = _place(_sell(key, maker, 1e18, 2e18, 0));
        bytes32 s2 = _place(_sell(key, maker2, 1e18, 2e18, 0));
        (bytes32 best,) = hook.bestOrder(key, false);
        assertEq(best, s1);
        _place(_buy(key, keeper, 2e18, 1e18, 0));
        assertFalse(_open(key, s1));
        assertTrue(_open(key, s2));
    }

    /// `best_bid_is_max` / `best_ask_is_min`: the matched level is the best price.
    function test_match_bestPriceFirst() public {
        bytes32 askHigh = _place(_sell(key, maker, 1e18, 3e18, 0));
        bytes32 askLow = _place(_sell(key, maker2, 1e18, 2e18, 0));
        _place(_buy(key, keeper, 3e18, 1e18, 0)); // bid 3 crosses both; takes the lower ask first, at 2
        assertFalse(_open(key, askLow));
        assertTrue(_open(key, askHigh));
    }

    /// `reprice_sequence_last`: a repriced order re-enters behind every live order; `updatePrice_claims`.
    function test_reprice_reentersLast() public {
        AsyncOrder memory s1o = _sell(key, maker, 1e18, 2e18, 0);
        bytes32 s1 = _place(s1o);
        bytes32 s2 = _place(_sell(key, maker2, 1e18, 2e18, 0));
        uint256 claims0 = _claims(currency0, address(hook));
        vm.prank(maker);
        hook.updatePrice(key, s1, 2e18);
        (bytes32 best,) = hook.bestOrder(key, false);
        assertEq(best, s2);
        assertEq(hook.getOrder(key, s1).sequence, 3);
        assertEq(_claims(currency0, address(hook)), claims0, "repricing moves no claims");
        // reprice to a new level
        vm.prank(maker);
        hook.updatePrice(key, s1, 1e18);
        (best,) = hook.bestOrder(key, false);
        assertEq(best, s1);
        assertEq(hook.getOrder(key, s1).priceKey, 1e18);
    }

    function test_reprice_onlyOwnerAndNonZero() public {
        bytes32 s1 = _place(_sell(key, maker, 1e18, 2e18, 0));
        vm.prank(maker2);
        vm.expectRevert(abi.encodeWithSelector(AsyncFiller.NotOrderOwner.selector, s1));
        hook.updatePrice(key, s1, 1e18);
        vm.prank(maker);
        vm.expectRevert(AsyncFiller.ZeroAmountOutMin.selector);
        hook.updatePrice(key, s1, 0);
    }

    /// `matchBook`: a book crossed by a reprice is matched by any keeper.
    function test_matchBook_keeper() public {
        bytes32 sellId = _place(_sell(key, maker, 1e18, 3e18, 0));
        bytes32 buyId = _place(_buy(key, maker2, 2e18, 1e18, 0));
        vm.prank(maker);
        hook.updatePrice(key, sellId, 2e18); // now crossed, no automatic match
        assertTrue(_open(key, sellId) && _open(key, buyId));

        vm.prank(keeper);
        uint256 matches = router.matchBook(key, 8);
        assertEq(matches, 1);
        assertFalse(_open(key, sellId));
        assertFalse(_open(key, buyId));
    }

    function test_matchBook_boundsMaxMatches() public {
        vm.prank(keeper);
        vm.expectRevert();
        router.matchBook(key, 0);
        vm.prank(keeper);
        vm.expectRevert();
        router.matchBook(key, 9);
        vm.prank(keeper);
        assertEq(router.matchBook(key, 8), 0);
    }

    /// At most `MAX_MATCHES_PER_CALL` matches per create.
    function test_match_capPerCall() public {
        for (uint256 i = 0; i < 10; i++) {
            _place(_sell(key, maker, 1e17, 2e17, 0));
        }
        _place(_buy(key, maker2, 10e18, 1e18, 0)); // crosses all ten, but only eight are matched
        assertEq(hook.openOrders(key), 3); // 2 sells + the partially filled buy
        vm.prank(keeper);
        assertEq(router.matchBook(key, 8), 2);
        assertEq(hook.openOrders(key), 0); // the tenth leg meets the buyer's minimum: closed, 8 quote refunded
    }

    /// `liquidityFill_meets_min`: the whole escrow is swapped through the pool; the maker is paid the output.
    function test_fillFromPoolLiquidity() public {
        AsyncOrder memory s = _sell(key, maker, 1e15, 0.9e15, 0); // ask 0.9 at a 1:1 pool
        bytes32 id = _place(s);
        uint256 maker1 = _bal(currency1, maker);
        vm.prank(keeper);
        uint256 out = router.fillFromPoolLiquidity(s);
        assertGe(out, 0.9e15);
        assertLt(out, 1e15);
        assertEq(_bal(currency1, maker), maker1 + out);
        assertFalse(_open(key, id));
        assertEq(_claims(currency0, address(hook)), 0);
    }

    function test_fillFromPoolLiquidity_limitNotMet() public {
        AsyncOrder memory s = _sell(key, maker, 1e15, 2e15, 0);
        _place(s);
        vm.prank(keeper);
        vm.expectRevert();
        router.fillFromPoolLiquidity(s);
    }

    function test_fillFromPoolLiquidity_noLiquidity() public {
        AsyncOrder memory s = _sell(emptyKey, maker, 1e15, 0.9e15, 1e6);
        _place(s);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAsyncSwap.NoActiveLiquidity.selector));
        router.fillFromPoolLiquidity(s);
    }

    /// `runLegs_priorityFee`: donated so far plus the remainder equals the original bid; the remainder is
    /// donated on close. The hook never keeps any part of a bid.
    function test_match_bidDonatedProRata() public {
        bytes32 sellId = _place(_sell(prioKey, maker, 1e18, 2e18, 4e6));
        assertEq(_claims(currency1, address(hook)), 4e6);
        _place(_buy(prioKey, maker2, 1e18, 0.5e18, 1e5)); // half the seller
        AsyncFiller.OrderInfo memory info = hook.getOrder(prioKey, sellId);
        assertEq(info.priorityFee, 2e6, "half the bid donated");
        assertEq(_claims(currency1, address(hook)), 2e6 + 0, "the seller's remaining bid is the only claim left");
        _place(_buy(prioKey, maker3, 1e18, 0.5e18, 1e5));
        assertFalse(_open(prioKey, sellId));
        assertEq(_claims(currency1, address(hook)), 0);
    }
}
