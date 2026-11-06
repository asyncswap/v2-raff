// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncMatching} from "@async-swap/libraries/AsyncMatching.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/// @notice M-02 fix (audit/lsp_security_review_2026-11-01.md): going first, the pool fills a new order up to the best
///         resting level and the book takes the rest. Before, a pool attempt that reached the level reverted as a
///         partial fill and the whole order matched the book, which let a front-run ask sell inside the pool's path.
contract PoolFirstPartialFillTest is SetupHook {
    using StateLibrary for IPoolManager;

    address alice = makeAddr("alice"); // resting ask
    address bob = makeAddr("bob"); // incoming buyer

    uint256 constant ASK_IN = 10 ether;
    uint256 constant ASK_OUT = 10.02 ether; // ~1.002, about 20 ticks above the pool's spot
    uint256 constant BID = 100_000;

    bytes32 constant LIQUIDITY_FILLED_TOPIC =
        keccak256("AsyncOrderLiquidityFilled(bytes32,bytes32,address,uint256,uint256)");
    bytes32 constant FEE_ACCRUED_TOPIC = keccak256("OrderFeeAccrued(bytes32,bytes32,address,uint256)");

    function setUp() public virtual override {
        super.setUp();
        topUp(alice, 1_000 ether);
        topUp(bob, 1_000 ether);
        // Thin full-range liquidity at spot 1.0: reaching the ask's level takes about 0.01 numeraire.
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);
        token0.approve(address(lp), type(uint256).max);
        token1.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(key, ModifyLiquidityParams(-887272, 887272, 10 ether, 0), "");
    }

    function _submit(address maker, bool zeroForOne, uint256 amountIn, uint256 amountOutMin)
        internal
        returns (AsyncOrder memory order, bytes32 id)
    {
        order = AsyncOrder(key, maker, zeroForOne, amountIn, amountOutMin, BID, 2 ** 96, bytes32(0));
        MockERC20 input = zeroForOne ? token0 : token1;
        vm.startPrank(maker);
        input.approve(address(router), amountIn + BID);
        router.swap(order, abi.encode(AsyncSwap.UserParams(maker, address(router), amountOutMin, BID)));
        vm.stopPrank();
        order.salt = _expectedSalt(maker, amountIn, amountOutMin);
        id = _orderIdFor(maker, zeroForOne, order.salt);
    }

    function _asset(address who) internal view returns (uint256) {
        return token0.balanceOf(who) + manager.balanceOf(who, currency0.toId());
    }

    /// @dev The swapped input of the order's pool fill, and the first fee accrued on it (the pool fill's 0.01%).
    function _poolFill(Vm.Log[] memory logs, bytes32 id) internal pure returns (uint256 swapped, uint256 fee) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length < 3 || logs[i].topics[2] != id) continue;
            if (logs[i].topics[0] == LIQUIDITY_FILLED_TOPIC) (swapped,) = abi.decode(logs[i].data, (uint256, uint256));
            if (logs[i].topics[0] == FEE_ACCRUED_TOPIC && fee == 0) fee = abi.decode(logs[i].data, (uint256));
        }
    }

    function test_poolFillsToTheBookLevelThenTheBookTakesTheRest() public {
        (, bytes32 askId) = _submit(alice, true, ASK_IN, ASK_OUT);
        uint256 before = _asset(bob);

        vm.recordLogs();
        (, bytes32 bidId) = _submit(bob, false, 5 ether, 2 ether);
        (uint256 swapped, uint256 fee) = _poolFill(vm.getRecordedLogs(), bidId);
        uint256 got = _asset(bob) - before;

        assertGt(swapped, 0, "the pool filled part of the order");
        assertLt(swapped, 0.1 ether, "only up to the ask's level");
        uint256 fullFee = (uint256(5 ether) + 9_999) / 10_000;
        assertEq(fee, Math.mulDiv(fullFee, swapped, 5 ether - fullFee, Math.Rounding.Ceil), "0.01% of the pool part");
        assertLt(fee, fullFee);

        (, int24 tick,,) = manager.getSlot0(poolId);
        assertGt(tick, 0, "the pool moved up from spot");
        assertLe(tick, 20, "but not past the ask (1.002 is tick ~19.98)");

        // The rest matched the ask at its price: bob does better than the ask alone would give him.
        uint256 bookOnly = Math.mulDiv(5 ether, ASK_IN, ASK_OUT);
        bookOnly -= AsyncFiller.tradeFee(bookOnly);
        assertGt(got, bookOnly, "pool part plus book beats the book alone");
        assertEq(hook.asyncOrder(poolId, bidId), 0, "the buy is done");
        assertGt(hook.asyncOrder(poolId, askId), 0, "the ask keeps its remainder");
        assertEq(
            manager.balanceOf(address(hook), currency1.toId()),
            hook.asyncOrderPriorityFee(poolId, askId),
            "numeraire escrow = the ask's unspent bid"
        );
        assertEq(manager.balanceOf(address(hook), currency0.toId()), hook.asyncOrder(poolId, askId), "escrow = ask");
    }

    /// The book does not cross the remainder: it rests with the maker's own limit and a pro-rata bid.
    function test_remainderRestsAtTheMakersLimit() public {
        (, bytes32 askId) = _submit(alice, true, ASK_IN, ASK_OUT);
        uint256 bidIn = 10 ether;
        uint256 bidOut = Math.mulDiv(bidIn, 10_000, 10_015); // limit 1.0015: below the ask, above the pool's average

        vm.recordLogs();
        (, bytes32 bidId) = _submit(bob, false, bidIn, bidOut);
        (uint256 swapped, uint256 fee) = _poolFill(vm.getRecordedLogs(), bidId);
        assertGt(swapped, 0, "the pool filled part of the order");

        uint256 consumed = swapped + fee;
        uint256 remaining = bidIn - consumed;
        (uint256 amountIn, uint256 amountOutMin) = hook.asyncOrderInfo(poolId, bidId);
        uint256 bid = hook.asyncOrderPriorityFee(poolId, bidId);
        assertEq(amountIn, remaining, "the rest rests");
        assertEq(amountOutMin, Math.mulDiv(bidOut, remaining, bidIn, Math.Rounding.Ceil), "at the maker's limit");
        assertEq(bid, BID - Math.mulDiv(BID, consumed, bidIn), "the filled share of the bid is spent");
        assertEq(
            manager.balanceOf(address(hook), currency1.toId()),
            remaining + bid + hook.asyncOrderPriorityFee(poolId, askId),
            "escrow = remainder + both bids"
        );
        // The pool part was credited as claims, not transferred.
        assertGt(manager.balanceOf(bob, currency0.toId()), 0, "pool output as claims");
    }
}

/// @notice The same, with a $1e12 minimum (1e18 base units with the 6-decimal mock numeraire), so the pool part can
///         leave a remainder below the minimum.
contract PoolFirstPartialFillMinimumTest is PoolFirstPartialFillTest {
    function setUp() public override {
        hookMinOrderUsd = 1e12;
        super.setUp();
    }

    /// A remainder below the minimum that the book does not take is refunded, not left resting.
    function test_dustRemainderIsRefunded() public {
        (, bytes32 askId) = _submit(alice, true, ASK_IN, ASK_OUT);
        uint256 bidIn = 1.005 ether;
        uint256 bidOut = Math.mulDiv(bidIn, 10_000, 10_015);
        uint256 claimsBefore = manager.balanceOf(bob, currency1.toId());

        vm.recordLogs();
        (, bytes32 bidId) = _submit(bob, false, bidIn, bidOut);
        (uint256 swapped, uint256 fee) = _poolFill(vm.getRecordedLogs(), bidId);
        assertGt(swapped, 0, "the pool filled part of the order");
        assertLt(bidIn - swapped - fee, 1 ether, "the remainder is below the minimum");

        assertEq(hook.asyncOrder(poolId, bidId), 0, "the dust is not left resting");
        assertEq(
            manager.balanceOf(bob, currency1.toId()) - claimsBefore,
            bidIn - swapped - fee,
            "remainder refunded as claims"
        );
        assertEq(hook.asyncOrder(poolId, askId), ASK_IN, "the ask is untouched");
        assertEq(manager.balanceOf(address(hook), currency1.toId()), BID, "numeraire escrow = the ask's bid");
    }

    /// A remainder below the minimum that the book crosses is matched, not refunded.
    function test_dustRemainderStillMatchesTheBook() public {
        (, bytes32 askId) = _submit(alice, true, ASK_IN, ASK_OUT);
        uint256 claimsBefore = manager.balanceOf(bob, currency1.toId());

        (, bytes32 bidId) = _submit(bob, false, 1.005 ether, 0.9 ether);
        assertEq(hook.asyncOrder(poolId, bidId), 0, "the buy is done");
        assertLt(hook.asyncOrder(poolId, askId), ASK_IN, "the ask took the remainder");
        assertEq(manager.balanceOf(bob, currency1.toId()), claimsBefore, "nothing refunded");
    }
}
