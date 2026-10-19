// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title AsyncMatching
/// @notice Order-to-order matching amounts.
/// @dev Spec: `AsyncSwapSpec/Match.lean`. The resting (earlier-sequence) side's price sizes the trade; the
///      incoming side's limit is then checked. `matchAmounts_sound`: whenever the result is non-zero, neither
///      escrow is overspent and neither side executes below its limit price; `matchAmounts_cross`: a non-zero
///      result implies the limit prices cross, so the book's price check is a filter, not the safety mechanism.
///      Rounding favours the resting order by at most one unit of its output (`*_tight`).
library AsyncMatching {
    /// @dev `MAX_MATCHES_PER_CALL`: the create unlock and `matchBook` perform at most this many matches.
    uint256 internal constant MAX_MATCHES_PER_CALL = 8;

    /// @notice `_matchAmounts(sell, buy, restingBuy)`, line for line.
    /// @param sellIn  the seller's remaining input (asset)
    /// @param sellMin the seller's remaining minimum output (quote)
    /// @param buyIn   the buyer's remaining input (quote)
    /// @param buyMin  the buyer's remaining minimum output (asset)
    /// @param restingBuy whether the buyer is the older order
    /// @return asset  asset units moving seller → buyer (`0` when no match is possible)
    /// @return quote  quote units moving buyer → seller
    function matchAmounts(uint256 sellIn, uint256 sellMin, uint256 buyIn, uint256 buyMin, bool restingBuy)
        internal
        pure
        returns (uint256 asset, uint256 quote)
    {
        if (restingBuy) {
            // quote = sell.amountIn * buy.amountIn / buy.amountOutMin, capped at buy.amountIn
            quote = Math.mulDiv(sellIn, buyIn, buyMin);
            if (quote > buyIn) quote = buyIn;
            if (quote == 0) return (0, 0);
            asset = Math.mulDiv(quote, buyMin, buyIn, Math.Rounding.Ceil);
            if (sellIn < asset) return (0, 0);
            uint256 sellerMinimum = Math.mulDiv(asset, sellMin, sellIn, Math.Rounding.Ceil);
            if (quote < sellerMinimum) return (0, 0);
        } else {
            // asset = buy.amountIn * sell.amountIn / sell.amountOutMin, capped at sell.amountIn
            asset = Math.mulDiv(buyIn, sellIn, sellMin);
            if (asset > sellIn) asset = sellIn;
            if (asset == 0) return (0, 0);
            quote = Math.mulDiv(asset, sellMin, sellIn, Math.Rounding.Ceil);
            if (buyIn < quote) return (0, 0);
            uint256 buyerMinimum = Math.mulDiv(quote, buyMin, buyIn, Math.Rounding.Ceil);
            if (asset < buyerMinimum) return (0, 0);
        }
    }
}
