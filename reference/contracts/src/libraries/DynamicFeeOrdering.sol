// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

/// @title Dynamic fee ordering on pool-liquidity fills
/// @notice Linked library called by `AsyncMatching` in the hook's context.
library DynamicFeeOrdering {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev Blocks a pool fill's starting tick stays the reference that later fills are measured against.
    uint256 internal constant ORDERING_WINDOW = 2;

    /// @notice A pool fill paid the dynamic fee, in `currency` (the fill's output): `toLps` donated to
    ///         in-range LPs and `toFeeVault` credited to the FeeVault, measured against `refTick`.
    event DynamicFeeCharged(
        PoolId indexed poolId,
        bytes32 indexed orderId,
        Currency indexed currency,
        uint256 toLps,
        uint256 toFeeVault,
        int24 refTick
    );

    /// @notice The pool tick before and after a completed pool fill, with the reference used for fee ordering.
    /// @dev Indexers can use these events as the price-movement log; fee calculation uses compact on-chain state.
    event PoolPriceObserved(
        PoolId indexed poolId,
        bytes32 indexed orderId,
        int24 tickBefore,
        int24 tickAfter,
        int24 refTick,
        uint64 observedBlock
    );

    /// @dev Dynamic fee on a pool fill that backruns a price move, taken from its output. The first pool fill in a window of
    ///      `ORDERING_WINDOW` blocks records its starting tick as the reference. A later fill in the
    ///      window that moves the price back toward the reference pays half the price gap it closes:
    ///      `amountOut * avgGap / 2`, with the gap averaged over the fill's start and end ticks (one
    ///      tick is about 0.01%), so splitting a backrun does not lower its total. A fill that crosses
    ///      the reference pays only on the share of its output from the side before the reference,
    ///      in proportion to the ticks on each side. Half of the fee
    ///      is donated to in-range LPs and half credited to the FeeVault as claims.
    function charge(
        AsyncFiller.State storage self,
        PoolKey calldata key,
        bytes32 id,
        Currency output,
        int24 tickBefore,
        uint256 amountOut
    ) public returns (uint256 fee) {
        IPoolManager manager = self.poolManager;
        (, int24 tickAfter,,) = manager.getSlot0(key.toId());
        if (self.refBlock == 0 || block.number > self.refBlock + ORDERING_WINDOW) {
            (self.refTick, self.refBlock) = (tickBefore, uint64(block.number));
        } else {
            int256 from = int256(tickBefore) - self.refTick;
            int256 to = int256(tickAfter) - self.refTick;
            // Only a fill toward the reference pays; the part past it closes no gap, and its output pays nothing.
            uint256 feeBase = amountOut;
            if (to * from < 0) {
                feeBase = amountOut * SignedMath.abs(from) / (SignedMath.abs(from) + SignedMath.abs(to));
            }
            if (to * from <= 0) to = 0;
            uint256 gapBefore = SignedMath.abs(from);
            uint256 gapAfter = SignedMath.abs(to);
            if (gapAfter < gapBefore) {
                fee = Math.min(feeBase * (gapBefore + gapAfter) / 40_000, amountOut / 2);
                _pay(self, key, id, output, fee);
            }
        }
        emit PoolPriceObserved(key.toId(), id, tickBefore, tickAfter, self.refTick, uint64(block.number));
    }

    /// @dev Half of `fee` to in-range LPs (all of it to the FeeVault if none are in range), the rest
    ///      to the FeeVault as claims.
    function _pay(AsyncFiller.State storage self, PoolKey calldata key, bytes32 id, Currency output, uint256 fee)
        private
    {
        IPoolManager manager = self.poolManager;
        uint256 toLps = manager.getLiquidity(key.toId()) == 0 ? 0 : fee / 2;
        if (toLps != 0) {
            bool zero = output == key.currency0;
            manager.donate(key, zero ? toLps : 0, zero ? 0 : toLps, "");
        }
        manager.mint(self.feeVault, output.toId(), fee - toLps);
        emit DynamicFeeCharged(key.toId(), id, output, toLps, fee - toLps, self.refTick);
    }
}
