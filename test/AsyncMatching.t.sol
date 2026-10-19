// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Huff} from "./utils/Huff.sol";
import {IMathHarness} from "./utils/IMathHarness.sol";
import {AsyncMatching} from "./reference/AsyncMatching.sol";

/// @dev Spec: `AsyncSwapSpec/Match.lean`, run against the Huff `MATCH_AMOUNTS`.
contract AsyncMatchingTest is Test {
    uint256 constant MAX = type(uint128).max;
    IMathHarness m;

    function setUp() public {
        m = IMathHarness(Huff.deploy("test/harness/MathHarness.huff"));
    }

    /// The Huff routine equals the Solidity `_matchAmounts` on every input in the protocol's range.
    function testFuzz_equalsReference(uint256 sellIn, uint256 sellMin, uint256 buyIn, uint256 buyMin, bool restingBuy)
        public
        view
    {
        sellIn = bound(sellIn, 1, MAX);
        sellMin = bound(sellMin, 1, type(uint256).max);
        buyIn = bound(buyIn, 1, MAX);
        buyMin = bound(buyMin, 1, type(uint256).max);
        (uint256 a, uint256 q) = AsyncMatching.matchAmounts(sellIn, sellMin, buyIn, buyMin, restingBuy);
        (uint256 ha, uint256 hq) = m.matchAmounts(sellIn, sellMin, buyIn, buyMin, restingBuy);
        assertEq(ha, a, "asset");
        assertEq(hq, q, "quote");
    }

    /// `matchAmounts_sound`: a non-zero match never overspends either escrow and never executes either side
    /// below its limit price; `matchAmounts_cross`: therefore the limits cross.
    function testFuzz_sound(uint256 sellIn, uint256 sellMin, uint256 buyIn, uint256 buyMin, bool restingBuy)
        public
        view
    {
        sellIn = bound(sellIn, 1, MAX);
        sellMin = bound(sellMin, 1, MAX);
        buyIn = bound(buyIn, 1, MAX);
        buyMin = bound(buyMin, 1, MAX);
        (uint256 asset, uint256 quote) = m.matchAmounts(sellIn, sellMin, buyIn, buyMin, restingBuy);
        assertEq(asset == 0, quote == 0);
        if (asset == 0) return;
        assertLe(asset, sellIn, "asset_le_sell_escrow");
        assertLe(quote, buyIn, "quote_le_buy_escrow");
        assertLe(asset * sellMin, quote * sellIn, "seller_limit");
        assertLe(quote * buyMin, asset * buyIn, "buyer_limit");
        assertLe(buyMin * sellMin, buyIn * sellIn, "limits cross");
    }

    /// `matchAmounts_restingBuy_tight` / `matchAmounts_restingSell_tight`: the resting side is favoured by
    /// strictly less than one unit of its output.
    function testFuzz_tight(uint256 sellIn, uint256 sellMin, uint256 buyIn, uint256 buyMin, bool restingBuy)
        public
        view
    {
        sellIn = bound(sellIn, 1, MAX);
        sellMin = bound(sellMin, 1, MAX);
        buyIn = bound(buyIn, 1, MAX);
        buyMin = bound(buyMin, 1, MAX);
        (uint256 asset, uint256 quote) = m.matchAmounts(sellIn, sellMin, buyIn, buyMin, restingBuy);
        if (asset == 0) return;
        if (restingBuy) assertLt(asset * buyIn, quote * buyMin + buyIn);
        else assertLt(quote * sellIn, asset * sellMin + sellIn);
    }

    function test_exactCross() public view {
        // seller: 1 asset for ≥ 2 quote; buyer: 2 quote for ≥ 1 asset; seller rests.
        (uint256 asset, uint256 quote) = m.matchAmounts(1e18, 2e18, 2e18, 1e18, false);
        assertEq(asset, 1e18);
        assertEq(quote, 2e18);
        // buyer rests: same.
        (asset, quote) = m.matchAmounts(1e18, 2e18, 2e18, 1e18, true);
        assertEq(asset, 1e18);
        assertEq(quote, 2e18);
    }

    function test_noCrossIsNoMatch() public view {
        // seller asks 3, buyer bids 2.
        (uint256 asset, uint256 quote) = m.matchAmounts(1e18, 3e18, 2e18, 1e18, false);
        assertEq(asset, 0);
        assertEq(quote, 0);
        (asset, quote) = m.matchAmounts(1e18, 3e18, 2e18, 1e18, true);
        assertEq(asset, 0);
        assertEq(quote, 0);
    }

    /// The resting side's price sizes the trade: a seller resting at 2 against a buyer bidding 3 trades at 2.
    function test_restingPriceSizesTrade() public view {
        (uint256 asset, uint256 quote) = m.matchAmounts(1e18, 2e18, 3e18, 1e18, false);
        assertEq(asset, 1e18);
        assertEq(quote, 2e18);
        // buyer resting at 3: the seller gets 3.
        (asset, quote) = m.matchAmounts(1e18, 2e18, 3e18, 1e18, true);
        assertEq(asset, 1e18);
        assertEq(quote, 3e18);
    }
}
