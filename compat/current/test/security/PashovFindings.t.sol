// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../SetupHook.t.sol";
import {PocSignedBase} from "./poc/PocSignedBase.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {Router} from "@async-swap/Router.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Regression tests for the findings of audit/pashov_security_review_2026-11-01.md. In every pool here the
///         numeraire is currency1 (quote1): a buy pays token1 for token0, a sell pays token0 for token1.
abstract contract PashovBase is SetupHook {
    using StateLibrary for IPoolManager;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address mallory = makeAddr("mallory");

    bytes32 constant DYNAMIC_FEE_TOPIC = keccak256("DynamicFeeCharged(bytes32,bytes32,address,uint256,uint256,int24)");
    bytes32 constant LIQUIDITY_FILLED_TOPIC =
        keccak256("AsyncOrderLiquidityFilled(bytes32,bytes32,address,uint256,uint256)");

    function setUp() public virtual override {
        super.setUp();
        topUp(alice, 1_000_000 ether);
        topUp(bob, 1_000_000 ether);
        topUp(carol, 1_000_000 ether);
        topUp(mallory, 1_000_000 ether);
    }

    function _liquidity(int24 lower, int24 upper, int256 amount) internal {
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);
        token0.approve(address(lp), type(uint256).max);
        token1.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, amount, 0), "");
    }

    /// @dev A Router order. `sell` gives `amountIn` token0 for at least `amountOutMin` token1.
    function _order(address maker, bool sell, uint256 amountIn, uint256 amountOutMin, uint256 bid)
        internal
        returns (AsyncOrder memory order, bytes32 id)
    {
        order = AsyncOrder(key, maker, sell, amountIn, amountOutMin, bid, 2 ** 96, bytes32(0));
        vm.startPrank(maker);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        router.swap(order, abi.encode(AsyncSwap.UserParams(maker, address(router), amountOutMin, bid)));
        vm.stopPrank();
        order.salt =
            keccak256(abi.encode(block.timestamp, block.number, address(manager), maker, amountIn, amountOutMin, bid));
        id = _orderIdFor(maker, sell, order.salt);
    }

    function _sqrtPrice() internal view returns (uint160 p) {
        (p,,,) = manager.getSlot0(poolId);
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(poolId);
    }

    function _count(Vm.Log[] memory logs, bytes32 topic, bytes32 id) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic && logs[i].topics.length > 2 && logs[i].topics[2] == id) ++n;
        }
    }
}

/// Finding 2: a dust order at the clamped end key made `poolBeatsLevel` return a limit v4 rejects, so every new order
/// on the other side skipped the pool.
contract ExtremeLevelTest is PashovBase {
    function setUp() public override {
        super.setUp();
        _liquidity(-887220, 887220, 1_000 ether);
    }

    function test_dustAskAtTheEndKeyDoesNotBlockPoolBuys() public {
        (, bytes32 askId) = _order(mallory, true, 1, 2 ** 130, 0);
        (, bytes32 buyId) = _order(bob, false, 10 ether, 9 ether, 0);
        assertEq(hook.asyncOrder(poolId, buyId), 0, "the buy fills from the pool");
        assertEq(hook.asyncOrder(poolId, askId), 1, "the dust ask is untouched");
    }

    function test_dustBidAtTheEndKeyDoesNotBlockPoolSells() public {
        (, bytes32 bidId) = _order(mallory, false, 1, 2 ** 130, 0);
        (, bytes32 sellId) = _order(bob, true, 10 ether, 9 ether, 0);
        assertEq(hook.asyncOrder(poolId, sellId), 0, "the sell fills from the pool");
        assertEq(hook.asyncOrder(poolId, bidId), 1, "the dust bid is untouched");
    }
}

/// Finding 11: the pool-first limit was the floor tick of the best level, so a sell in a quote1 pool filled below the
/// resting bid.
contract PoolFirstOvershootTest is PashovBase {
    function setUp() public override {
        super.setUp();
        _liquidity(-887220, 887220, 1_000 ether);
    }

    function test_poolFirstSellDoesNotTradeBelowTheBid() public {
        // Alice bids 0.99995 token1 per token0: inside tick -1 (0.9999 .. 1.0), below the pool at tick 0.
        (, bytes32 bidId) = _order(alice, false, 9.9995 ether, 10 ether, 0);
        assertEq(hook.asyncOrder(poolId, bidId), 9.9995 ether, "the bid rests");

        (, bytes32 sellId) = _order(bob, true, 10 ether, 9 ether, 0);
        assertEq(hook.asyncOrder(poolId, sellId), 0, "the sell is filled");
        assertGe(_sqrtPrice(), TickMath.getSqrtPriceAtTick(0), "the pool did not sell below the bid's tick");
        assertEq(hook.asyncOrder(poolId, bidId), 0, "the bid took the sell");
    }
}

/// Finding 3: inside the 2-block window, a pool fill back toward the reference pays the dynamic fee, but the venue
/// choice compared spot prices only, so it skipped a better book order.
contract VenueDynamicFeeTest is PashovBase {
    using StateLibrary for IPoolManager;

    function setUp() public override {
        super.setUp();
        _liquidity(-887220, 887220, 1_000 ether);
    }

    function test_orderMovingBackTowardTheReferenceMatchesTheBookFirst() public {
        // Carol's buy is the first pool fill in the window: the reference is tick 0, the pool moves up about 10%.
        _order(carol, false, 50 ether, 1, 0);
        int24 moved = _tick();
        assertGt(moved, 500, "carol moved the pool");

        // Alice bids at 99.5% of the new pool price: a sell to her beats the pool after its dynamic fee.
        uint256 price = Math.mulDiv(uint256(_sqrtPrice()) * uint256(_sqrtPrice()), 1e18, 1 << 192);
        uint256 bidIn = price * 995 / 1000; // token1 for 1 token0
        (, bytes32 bidId) = _order(alice, false, bidIn, 1 ether, 0);
        assertEq(hook.asyncOrder(poolId, bidId), bidIn, "the bid rests below the pool");

        vm.recordLogs();
        (, bytes32 sellId) = _order(bob, true, 1 ether, 0.5 ether, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(hook.asyncOrder(poolId, sellId), 0, "the sell is filled");
        assertEq(hook.asyncOrder(poolId, bidId), 0, "the book bid took the sell");
        assertEq(_count(logs, DYNAMIC_FEE_TOPIC, sellId), 0, "the sell paid no dynamic fee");
    }
}

/// Finding 1: a pool fill that crossed the reference tick paid the gap fee on its whole output, including the output
/// past the reference, which closes no gap.
contract FeeBaseTest is PashovBase {
    function setUp() public override {
        super.setUp();
        _liquidity(-887220, 887220, 1_000 ether);
    }

    function test_feeIsChargedOnlyOnTheOutputThatClosesTheGap() public {
        _order(carol, false, 20 ether, 1, 0); // first fill in the window: reference tick 0
        int24 tickBefore = _tick();
        assertGt(tickBefore, 0);

        vm.recordLogs();
        (, bytes32 sellId) = _order(bob, true, 60 ether, 1, 0); // crosses back past the reference
        Vm.Log[] memory logs = vm.getRecordedLogs();
        int24 tickAfter = _tick();
        assertLt(tickAfter, 0, "the sell crossed the reference");

        uint256 fee;
        uint256 net;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == DYNAMIC_FEE_TOPIC) {
                (uint256 toLps, uint256 toVault,) = abi.decode(logs[i].data, (uint256, uint256, int24));
                fee = toLps + toVault;
            }
            if (logs[i].topics[0] == LIQUIDITY_FILLED_TOPIC && logs[i].topics[2] == sellId) {
                (, net) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        uint256 gross = net + fee;
        uint256 from = SignedMath.abs(int256(tickBefore));
        uint256 past = SignedMath.abs(int256(tickAfter));
        uint256 expected = Math.min(gross * from / (from + past) * from / 40_000, gross / 2);
        assertEq(fee, expected, "fee on the share of output that closes the gap");
        assertLt(fee, gross * from / 40_000, "less than the fee on the whole output");
    }
}

/// Finding 8: a pool-first fill limited at a far book level ran past the last liquidity range, left the price where no
/// liquidity is active, and every later pool fill reverted with NoActiveLiquidity. A fill that would leave no active
/// liquidity now reverts, so the order uses the book and the pool stays usable.
contract EmptyRangeTest is PashovBase {
    using StateLibrary for IPoolManager;

    function setUp() public override {
        super.setUp();
        _liquidity(-100, 100, 1e21); // about 5 token1 of depth above tick 0
    }

    function test_poolFillCannotParkThePriceInAnEmptyRange() public {
        // Mallory rests a dust ask far above (tick ~5000), then buys more than the whole range holds.
        (AsyncOrder memory ask,) = _order(mallory, true, 1e15, 1.65e15, 0);
        (AsyncOrder memory buy, bytes32 buyId) = _order(mallory, false, 20 ether, 16.6 ether, 0); // limit ~1.2
        assertLt(_tick(), 100, "the price did not leave the range");
        assertGt(manager.getLiquidity(poolId), 0, "liquidity stays active");
        assertEq(hook.asyncOrder(poolId, buyId), 20 ether, "the buy rests on the book instead");
        vm.startPrank(mallory);
        router.cancelOrder(ask);
        router.cancelOrder(buy);
        vm.stopPrank();

        vm.roll(block.number + 3); // outside the dynamic-fee window
        (, bytes32 sellId) = _order(bob, true, 1 ether, 0.5 ether, 0);
        assertEq(hook.asyncOrder(poolId, sellId), 0, "a later sell fills from the pool");
    }
}

/// Finding 7 (acknowledged, see audit/README.md): `_reduceAfterMatch` rounds a remainder's minimum up, so a partly matched
/// order's exact ratio ends slightly worse than the maker signed, and an equal newer order moves ahead of it. Rounding
/// down instead lets a worse dust remainder jump ahead (`test_worsePriceCannotJumpAheadWithBidOrAge`), so the fix is to
/// rank by the signed ratio. This test pins today's behaviour; flip the last assertion when that fix lands.
contract RemainderRoundingKnownIssueTest is PashovBase {
    function test_knownIssue_partlyMatchedOrderFallsBehindAnEqualOrder() public {
        // A and B ask 3 token0 for 6_000_000_001 token1 base units; A is older and pays a bid.
        (, bytes32 aId) = _order(alice, true, 3e18, 6_000_000_001, 100_000);
        (, bytes32 bId) = _order(carol, true, 3e18, 6_000_000_001, 0);
        (bool found,, bytes32 best,) = hook.bestOrder(poolId, false);
        assertTrue(found);
        assertEq(best, aId, "before the match, A is ahead: same price, higher bid");

        // Bob buys 10_000_000 token1 worth: a partial match of A at A's price.
        _order(bob, false, 10_000_000, 4e15, 0);
        assertLt(hook.asyncOrder(poolId, aId), 3e18, "A was partly matched");
        assertEq(hook.asyncOrder(poolId, bId), 3e18, "B is untouched");

        (, uint256 aMin) = hook.asyncOrderInfo(poolId, aId);
        uint256 aIn = hook.asyncOrder(poolId, aId);
        assertGt(aMin * 3e18, 6_000_000_001 * aIn, "A's remainder now asks more per token than A signed");

        (,, best,) = hook.bestOrder(poolId, false);
        assertEq(best, bId, "known issue: B moves ahead of A");
    }
}

/// Finding 10: a copied grant submitted before the relayer spent its nonce, so the relayer's swapWithSig reverted.
contract GrantFrontRunTest is PocSignedBase {
    function test_frontRunGrantDoesNotRevertTheRelayedOrder() public {
        AsyncOrder memory order = _signedOrder(AMOUNT_OUT_MIN);
        Router.PermitData memory permit = _permit(order, 0, block.timestamp + 1 hours);
        Router.ExecutorGrant memory grant = _grant(3, block.timestamp + 1 hours);

        vm.prank(attacker);
        hook.setExecutorWithSig(key, maker, address(router), true, grant.nonce, grant.deadline, grant.signature);

        vm.prank(relayer);
        router.swapWithSig(order, permit, grant);
        order.salt = _expectedSalt(maker, AMOUNT_IN, AMOUNT_OUT_MIN);
        assertEq(hook.asyncOrder(poolId, _id(order)), AMOUNT_IN, "the order is placed");
    }
}

/// A 1-wei dynamic fee rounds the LP half to zero, so all of it goes to the FeeVault and nothing is donated. The pool
/// is thin, so a few wei move the price by whole ticks.
contract DustDynamicFeeTest is PashovBase {
    function setUp() public override {
        super.setUp();
        _liquidity(-887220, 887220, 1e6);
    }

    function test_oneWeiFeeGoesWhollyToTheVault() public {
        _order(carol, false, 30_500, 1, 0); // first fill in the window: reference tick 0, pool up about 600 ticks
        uint256 gap = uint256(int256(_tick()));
        assertGt(gap, 500, "carol moved the pool up");
        // A sell back toward the reference pays about out * gap / 20_000: about 1.5 wei here, whose LP half rounds to 0.
        vm.recordLogs();
        (, bytes32 sellId) = _order(bob, true, 30_000 / gap, 1, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(hook.asyncOrder(poolId, sellId), 0, "the dust sell filled from the pool");
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == DYNAMIC_FEE_TOPIC) {
                (uint256 toLps, uint256 toVault,) = abi.decode(logs[i].data, (uint256, uint256, int24));
                assertEq(toLps, 0, "nothing donated");
                assertEq(toVault, 1, "the whole 1-wei fee to the vault");
                seen = true;
            }
        }
        assertTrue(seen, "the dust sell paid a dynamic fee");
    }
}
