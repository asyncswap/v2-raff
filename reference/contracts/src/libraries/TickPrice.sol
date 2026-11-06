// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {DynamicFeeOrdering} from "@async-swap/libraries/DynamicFeeOrdering.sol";

/// @notice Book levels on Uniswap v4 ticks: an order sits at the floor tick (spacing 1, 0.01% steps)
///         of its exact currency1/currency0 limit. Levels are a fixed relative width at any price and
///         for any token decimals; the exact limit still decides crossing within a level.
library TickPrice {
    /// @notice Radix key of an order's level, ordered by numeraire per asset. Monotone in the exact
    ///         price, so distinct keys order prices strictly. Keys run from 1 to 2 * MAX_TICK + 1;
    ///         ratios beyond the v4 price range share the end keys.
    function key(bool isBuy, bool zeroForOne, uint256 amountIn, uint256 amountOut) public pure returns (uint128) {
        // currency1 per currency0: a currency0 seller's output over its input, otherwise the reverse.
        int24 tick = zeroForOne ? floorTick(amountOut, amountIn) : floorTick(amountIn, amountOut);
        return isBuy != zeroForOne
            ? uint128(uint24(tick - TickMath.MIN_TICK)) + 1
            : uint128(uint24(TickMath.MAX_TICK - tick)) + 1;
    }

    /// @notice Whether the pool has active liquidity and its current price is strictly better for an
    ///         incoming order than the best opposite level `levelKey` (below the best ask for a buy,
    ///         above the best bid for a sell), compared as keys; if so, also the limit a pool-first swap
    ///         may not cross. `quote1`: the numeraire is currency1, so the tick's price is already
    ///         numeraire per asset; otherwise it is flipped.
    /// @dev Inside the dynamic-fee window (`refTick`, `refBlock`; see `DynamicFeeOrdering`) a fill back toward the
    ///      reference pays about half the price gap it closes, so the pool's price counts that much worse: half the
    ///      gap, in ticks. The limit is the level's tick, one tick higher for a swap that lowers the tick (the key is
    ///      a floor tick, so the floor would trade past the level's exact price), kept inside the range v4 accepts.
    function poolBeatsLevel(
        IPoolManager manager,
        PoolId poolId,
        bool quote1,
        bool isBuy,
        uint128 levelKey,
        int24 refTick,
        uint64 refBlock
    ) public view returns (bool, uint160) {
        if (StateLibrary.getLiquidity(manager, poolId) == 0) return (false, 0);
        (, int24 tick,,) = StateLibrary.getSlot0(manager, poolId);
        uint128 poolKey =
            quote1 ? uint128(uint24(tick - TickMath.MIN_TICK)) + 1 : uint128(uint24(TickMath.MAX_TICK - tick)) + 1;
        // The incoming swap sells currency0, lowering the tick, for a quote1 sell or a quote0 buy.
        bool zeroForOne = quote1 != isBuy;
        if (
            refBlock != 0 && block.number <= refBlock + DynamicFeeOrdering.ORDERING_WINDOW
                && (zeroForOne ? tick > refTick : tick < refTick)
        ) {
            uint128 feeTicks = uint128(SignedMath.abs(int256(tick) - refTick) / 2);
            if (isBuy) poolKey += feeTicks;
            else poolKey = poolKey > feeTicks ? poolKey - feeTicks : 0;
        }
        if (isBuy ? poolKey >= levelKey : poolKey <= levelKey) return (false, 0);
        // The same mapping backwards: the level as a pool tick.
        int24 offset = int24(int256(uint256(levelKey)) - 1);
        int24 levelTick = quote1 ? offset + TickMath.MIN_TICK : TickMath.MAX_TICK - offset;
        if (zeroForOne && levelTick < TickMath.MAX_TICK) ++levelTick;
        uint160 limit = TickMath.getSqrtPriceAtTick(levelTick);
        if (limit <= TickMath.MIN_SQRT_PRICE) limit = TickMath.MIN_SQRT_PRICE + 1;
        else if (limit >= TickMath.MAX_SQRT_PRICE) limit = TickMath.MAX_SQRT_PRICE - 1;
        return (true, limit);
    }

    /// @notice Largest tick whose price is at most num/den, clamped to the v4 tick range. Monotone in
    ///         num/den. Two regimes keep sqrt(num/den) * 2^96 well inside one tick of exact.
    function floorTick(uint256 num, uint256 den) internal pure returns (int24) {
        uint256 sqrtPrice;
        if (num / den < 1 << 64) {
            sqrtPrice = Math.sqrt(Math.mulDiv(num, 1 << 192, den));
        } else {
            if (num / den >= 1 << 128) return TickMath.MAX_TICK;
            sqrtPrice = Math.sqrt(Math.mulDiv(num, 1 << 128, den)) << 32;
        }
        if (sqrtPrice < TickMath.MIN_SQRT_PRICE) return TickMath.MIN_TICK;
        if (sqrtPrice >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_TICK;
        return TickMath.getTickAtSqrtPrice(uint160(sqrtPrice));
    }
}
