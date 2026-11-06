// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickPrice} from "@async-swap/libraries/TickPrice.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice `TickPrice.poolBeatsLevel` against a real pool at tick 0, for both numeraire orientations. The swap tests
///         use pools whose numeraire is currency1; this covers the currency0 side, the fee window in both directions,
///         and the limit's range on every key.
contract TickPricePoolBeatsLevelTest is Test {
    using PoolIdLibrary for PoolKey;

    int24 constant MIN = TickMath.MIN_TICK;
    int24 constant MAX = TickMath.MAX_TICK;
    uint128 constant LAST_KEY = uint128(uint24(MAX - MIN)) + 1;

    IPoolManager manager;
    PoolId poolId;

    function setUp() public {
        manager = new PoolManager(address(this));
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (Currency c0, Currency c1) = address(a) < address(b)
            ? (Currency.wrap(address(a)), Currency.wrap(address(b)))
            : (Currency.wrap(address(b)), Currency.wrap(address(a)));
        PoolKey memory key = PoolKey(c0, c1, 3000, 60, IHooks(address(0)));
        manager.initialize(key, 2 ** 96);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        a.mint(address(this), 1e30);
        b.mint(address(this), 1e30);
        a.approve(address(lp), type(uint256).max);
        b.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(key, ModifyLiquidityParams(-887220, 887220, 1e21, 0), "");
        poolId = key.toId();
        vm.roll(100);
    }

    /// @dev The level key of a currency1/currency0 tick, as `TickPrice.key` maps it.
    function _key(bool quote1, int24 tick) internal pure returns (uint128) {
        return quote1 ? uint128(uint24(tick - MIN)) + 1 : uint128(uint24(MAX - tick)) + 1;
    }

    function _beats(bool quote1, bool isBuy, uint128 levelKey, int24 refTick, uint64 refBlock)
        internal
        view
        returns (bool, uint160)
    {
        return TickPrice.poolBeatsLevel(manager, poolId, quote1, isBuy, levelKey, refTick, refBlock);
    }

    /// Numeraire is currency0: a buy pays currency0, a zeroForOne swap that lowers the tick, so the limit is one tick
    /// above the ask's floor tick.
    function test_quote0Buy_limitIsOneTickAboveTheAsk() public view {
        (bool beats, uint160 limit) = _beats(false, true, _key(false, -100), 0, 0);
        assertTrue(beats, "the pool beats an ask below it");
        assertEq(limit, TickMath.getSqrtPriceAtTick(-99));
    }

    /// Numeraire is currency0: a sell is oneForZero and raises the tick, so the floor tick already stops short.
    function test_quote0Sell_limitIsTheBidTick() public view {
        (bool beats, uint160 limit) = _beats(false, false, _key(false, 100), 0, 0);
        assertTrue(beats, "the pool beats a bid above it");
        assertEq(limit, TickMath.getSqrtPriceAtTick(100));
    }

    function test_quote0_levelBetterThanThePoolGoesToTheBook() public view {
        (bool buyBeats,) = _beats(false, true, _key(false, 100), 0, 0);
        (bool sellBeats,) = _beats(false, false, _key(false, -100), 0, 0);
        assertFalse(buyBeats, "an ask better than the pool takes a buy first");
        assertFalse(sellBeats, "a bid better than the pool takes a sell first");
    }

    /// A quote1 buy raises the tick. With the pool below the reference, inside the window, it pays the dynamic fee:
    /// half the 500-tick gap, so an ask 100 ticks up beats the pool.
    function test_quote1Buy_feeWindowSendsTheOrderToTheBook() public view {
        (bool beats,) = _beats(true, true, _key(true, 100), 500, 100);
        assertFalse(beats, "the pool's 250-tick fee makes the ask better");
        (bool far, uint160 limit) = _beats(true, true, _key(true, 300), 500, 100);
        assertTrue(far, "an ask past the fee still loses to the pool");
        assertEq(limit, TickMath.getSqrtPriceAtTick(300));
    }

    function test_quote1Buy_outsideTheWindowPaysNoFee() public {
        vm.roll(103); // refBlock 100 + ORDERING_WINDOW 2, plus one
        (bool beats, uint160 limit) = _beats(true, true, _key(true, 100), 500, 100);
        assertTrue(beats, "no fee after the window");
        assertEq(limit, TickMath.getSqrtPriceAtTick(100));
    }

    function test_quote1Buy_awayFromTheReferencePaysNoFee() public view {
        // The pool is above the reference: a buy moves it further away and pays nothing.
        (bool beats,) = _beats(true, true, _key(true, 100), -500, 100);
        assertTrue(beats);
    }

    /// A price just below 2^128 is above the price at MAX_TICK, so floorTick returns MAX_TICK from its upper regime:
    /// the order sits on the end key.
    function test_priceJustBelowTwoTo128IsTheEndKey() public pure {
        assertEq(TickPrice.key(false, true, 1, type(uint128).max), LAST_KEY);
    }

    /// For any level the pool beats, the limit is strictly inside v4's price range, and a swap that lowers the tick
    /// stops at or above the level's floor tick.
    function testFuzz_limitIsAValidSwapLimit(bool quote1, bool isBuy, uint128 levelKey) public view {
        levelKey = uint128(bound(levelKey, 1, LAST_KEY));
        (bool beats, uint160 limit) = _beats(quote1, isBuy, levelKey, 0, 0);
        if (!beats) return;
        assertGt(limit, TickMath.MIN_SQRT_PRICE, "above v4's minimum");
        assertLt(limit, TickMath.MAX_SQRT_PRICE, "below v4's maximum");
        int24 offset = int24(int256(uint256(levelKey)) - 1);
        int24 levelTick = quote1 ? offset + MIN : MAX - offset;
        if (quote1 != isBuy) assertGe(limit, TickMath.getSqrtPriceAtTick(levelTick), "no trade past the level");
    }
}
