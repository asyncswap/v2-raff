// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../../SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {MockERC20} from "../../utils/MockERC20.sol";

abstract contract DustBase is SetupHook {
    address alice = makeAddr("alice"); // seller (asset = token0)
    address bob = makeAddr("bob"); // buyer (numeraire = token1)

    function _order(address who, bool zeroForOne, uint256 amountIn, uint256 amountOutMin)
        internal
        view
        returns (AsyncOrder memory)
    {
        return AsyncOrder({
            key: key,
            owner: who,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            priorityFee: 0,
            sqrtPrice: 2 ** 96,
            salt: keccak256(abi.encode(block.timestamp, block.number, address(manager), who, amountIn, amountOutMin, 0))
        });
    }

    function _submit(AsyncOrder memory o) internal {
        MockERC20 input = o.zeroForOne ? token0 : token1;
        vm.startPrank(o.owner);
        input.approve(address(router), type(uint256).max);
        router.swap(o, abi.encode(AsyncSwap.UserParams(o.owner, address(router), o.amountOutMin, 0)));
        vm.stopPrank();
    }

    function submitExternal(AsyncOrder memory o) external {
        _submit(o);
    }

    /// @dev Seller rests first; buyer arrives and matches. Returns (buyer quote paid, buyer asset received,
    ///      seller quote received). Book proceeds are ERC-6909 claims.
    function _match(uint256 sellIn, uint256 sellMin, uint256 buyIn, uint256 buyMin)
        internal
        returns (uint256 paid, uint256 gotAsset, uint256 sellerGot)
    {
        _submit(_order(alice, true, sellIn, sellMin));
        uint256 b1 = token1.balanceOf(bob);
        uint256 bc0 = manager.balanceOf(bob, currency0.toId());
        uint256 ac1 = manager.balanceOf(alice, currency1.toId());
        _submit(_order(bob, false, buyIn, buyMin));
        // Unused buyer input refunded as claims too; count it back.
        paid = b1 - token1.balanceOf(bob) - manager.balanceOf(bob, currency1.toId());
        gotAsset = manager.balanceOf(bob, currency0.toId()) - bc0;
        sellerGot = manager.balanceOf(alice, currency1.toId()) - ac1;
        emit log_named_uint("buyer quote paid", paid);
        emit log_named_uint("buyer asset received", gotAsset);
        emit log_named_uint("seller quote received", sellerGot);
    }
}

/// @notice Candidate 4a: minOrder 0, no asset floor. A 1-wei asset match makes the ceil trade fee 100% of the buyer's
///         proceeds while the buyer still pays the full quote amount.
contract DustTradeFeeNoMinimumPoc is DustBase {
    function setUp() public override {
        super.setUp(); // hookMinOrderUsd = 0, hookAssetPrecision = max (floor 1)
        topUp(alice, 100 ether);
        topUp(bob, 100 ether);
    }

    function test_poc_buyerPaysQuoteReceivesZeroAsset() public {
        // Seller: 1 wei asset for >= 1000 quote. Buyer: 1000 quote for >= 1 wei asset.
        (uint256 paid, uint256 got, uint256 sellerGot) = _match(1, 1000, 1000, 1);
        assertEq(paid, 1000, "buyer paid full quote");
        assertEq(got, 0, "ceil fee took the whole 1-wei asset leg");
        assertEq(sellerGot, 999);
        assertLt(got, uint256(1) * 80 / 100 + 1, "buyer got <80% of 1 wei (0)");
    }

    /// Effective buyer fee rate for small asset legs: 1 wei on n wei (n <= 5000) instead of 0.02%.
    function test_poc_effectiveFeeRateOnSmallAssetLegs() public {
        (, uint256 got,) = _match(10, 10, 10, 10);
        emit log_named_uint("asset leg 10 wei: buyer got", got);
        assertEq(got, 9, "10% fee on a 10-wei leg");
    }

    /// Control: a normal-size match pays exactly 0.02% on each side.
    function test_control_normalMatchFee() public {
        (uint256 paid, uint256 got, uint256 sellerGot) = _match(1 ether, 1 ether, 1 ether, 1 ether);
        assertEq(paid, 1 ether);
        assertEq(got, 1 ether - 0.0002 ether);
        assertEq(sellerGot, 1 ether - 0.0002 ether);
    }
}

/// @notice Candidate 4b: production knobs (minOrder $10, precision 4). Dust legs cannot be opened.
contract DustTradeFeeProductionPoc is DustBase {
    function setUp() public override {
        hookMinOrderUsd = 10; // 1e7 numeraire base units (6 decimals)
        hookAssetPrecision = 4; // floor 1e14 for 18-decimal asset
        super.setUp();
        topUp(alice, 100 ether);
        topUp(bob, 100 ether);
    }

    function test_poc_dustOrdersRejectedUnderProductionKnobs() public {
        vm.expectRevert(); // BelowMinimumAssetAmount (1-wei sell)
        this.submitExternal(_order(alice, true, 1, 1e7));
        vm.expectRevert(); // BelowMinimumAssetAmount (buy for 1 wei asset)
        this.submitExternal(_order(bob, false, 1e7, 1));
    }

    /// A 1-wei sell remainder at a sane price closes and is refunded (its own minimum < minOrder).
    function test_poc_dustSellRemainderClosesAndRefunds() public {
        // Seller: 2e14+1 asset for 2e7 quote; buyer takes ~half with exactly minOrder.
        _submit(_order(alice, true, 2e14 + 1, 2e7));
        uint256 a0Claims = manager.balanceOf(alice, currency0.toId());
        _submit(_order(bob, false, 1e7, 1e14));
        bytes32 sellId = _orderIdFor(alice, true, _order(alice, true, 2e14 + 1, 2e7).salt);
        (uint256 rem, uint256 remMin) = hook.asyncOrderInfo(poolId, sellId);
        emit log_named_uint("sell remainder input", rem);
        emit log_named_uint("sell remainder min out", remMin);
        emit log_named_uint("seller asset refunded as claims", manager.balanceOf(alice, currency0.toId()) - a0Claims);
        assertTrue(rem == 0 || remMin >= 1e7, "a resting remainder still meets minOrder on its numeraire leg");
    }

    /// Control: smallest legal match (1e14 asset for 1e7 quote) pays exactly 0.02%.
    function test_control_smallestLegalMatchFee() public {
        (uint256 paid, uint256 got,) = _match(1e14, 1e7, 1e7, 1e14);
        assertEq(paid, 1e7);
        assertEq(got, 1e14 - 2e10);
    }
}
