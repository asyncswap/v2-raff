// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {DustBase} from "./poc/DustTradeFee.t.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";

/// @notice The asset floor alone: minOrder 0, precision 4, the testnet deployment's constructor arguments. Without a
///         dollar minimum no remainder closes as dust, so these cover what that minimum used to rule out.
contract NoDollarMinimumTest is DustBase {
    uint256 constant FLOOR = 1e14; // 0.0001 of an 18-decimal asset

    function setUp() public override {
        hookMinOrderUsd = 0;
        hookAssetPrecision = 4;
        super.setUp();
        topUp(alice, 1000 ether);
        topUp(bob, 1000 ether);
    }

    function test_floorIsTheOnlyMinimum() public {
        (uint256 paid, uint256 got,) = _match(FLOOR, 200_000, 200_000, FLOOR); // 0.0001 ETH at $2,000: $0.20
        assertEq(paid, 200_000);
        assertEq(got, FLOOR - FLOOR / 5000);
    }

    function test_belowTheFloorReverts() public {
        bytes memory reason = abi.encodeWithSelector(AsyncFiller.BelowMinimumAssetAmount.selector);
        try this.submitExternal(_order(alice, true, FLOOR - 1, 200_000)) {
            revert("sell below the floor was accepted");
        } catch (bytes memory err) {
            assertTrue(_contains(err, reason), "sell reverts with the floor error");
        }
        try this.submitExternal(_order(bob, false, 200_000, FLOOR - 1)) {
            revert("buy below the floor was accepted");
        } catch (bytes memory err) {
            assertTrue(_contains(err, reason), "buy reverts with the floor error");
        }
    }

    /// @dev The hook's error arrives inside v4's WrappedError.
    function _contains(bytes memory data, bytes memory part) private pure returns (bool) {
        for (uint256 i; i + part.length <= data.length; ++i) {
            bool same = true;
            for (uint256 j; j < part.length && same; ++j) {
                same = data[i + j] == part[j];
            }
            if (same) return true;
        }
        return false;
    }

    /// A sell asking nothing has no dollar minimum to stop it. It must not break the book for anyone else.
    function test_sellAskingNothingLeavesTheBookWorking() public {
        try this.submitExternal(_order(alice, true, FLOOR, 0)) {
            emit log("sell with zero minimum accepted");
        } catch {
            emit log("sell with zero minimum rejected");
        }
        vm.warp(block.timestamp + 1);
        _submit(_order(bob, false, 2_000_000, 1e15));
        hook.matchBook(key, 8);
        vm.warp(block.timestamp + 1);
        _submit(_order(alice, true, 1e15, 2_000_000));
        hook.matchBook(key, 8);
    }

    /// Two resting bids, then a sell that a partial match leaves with a remainder of any size. Whatever is left,
    /// matching must not revert, and a later crossing pair must still trade.
    function testFuzz_remaindersNeverStallTheBook(uint256 remainder, uint256 bidPrice, uint256 askPrice) public {
        remainder = bound(remainder, 1, FLOOR * 5); // leaves the older bid with room for the last sell
        bidPrice = bound(bidPrice, 1e3, 1e4); // units per 1e12 wei: $1,000 to $10,000 per ETH
        askPrice = bound(askPrice, 1e3, bidPrice);
        uint256 worse = bidPrice * FLOOR / 1e12;

        _submit(_order(bob, false, worse * 10, FLOOR * 10)); // older, worse-or-equal bid
        vm.warp(block.timestamp + 1);
        _submit(_order(bob, false, worse + worse / 100, FLOOR)); // newer bid, 1% better, taken first
        vm.warp(block.timestamp + 1);
        uint256 sellIn = FLOOR + remainder;
        _submit(_order(alice, true, sellIn, askPrice * sellIn / 1e12 + 1));
        hook.matchBook(key, 8);

        vm.warp(block.timestamp + 1);
        uint256 before = token0.balanceOf(bob) + manager.balanceOf(bob, currency0.toId());
        _submit(_order(alice, true, FLOOR, 1)); // far below every bid
        hook.matchBook(key, 8);
        assertGt(
            token0.balanceOf(bob) + manager.balanceOf(bob, currency0.toId()), before, "a crossing pair still trades"
        );
    }
}
