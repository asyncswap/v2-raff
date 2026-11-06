// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

/// @dev An asset with no `decimals()`: the hook falls back to a 1-unit floor.
contract NoDecimalsToken {}

/// @notice With a precision of 4, every order trades at least 0.0001 of a whole asset token: a sell's input and a
///         buy's minimum output. The floor comes from the asset's decimals once, when the pool is created.
contract AssetPrecisionTest is SetupHook {
    using PoolIdLibrary for PoolKey;

    uint256 constant FLOOR = 1e14; // 0.0001 of an 18-decimal token

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public override {
        hookAssetPrecision = 4;
        super.setUp();
        topUp(alice, 1_000 ether);
        topUp(bob, 1_000 ether);
    }

    function _order(address maker, bool zeroForOne, uint256 amountIn, uint256 amountOutMin)
        internal
        view
        returns (AsyncOrder memory)
    {
        return AsyncOrder({
            key: key,
            owner: maker,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            priorityFee: 0,
            sqrtPrice: 2 ** 96,
            salt: keccak256(
                abi.encode(block.timestamp, block.number, address(manager), maker, amountIn, amountOutMin, 0)
            )
        });
    }

    function _submit(AsyncOrder memory order) internal {
        MockERC20 input = order.zeroForOne ? token0 : token1;
        vm.startPrank(order.owner);
        input.approve(address(router), type(uint256).max);
        router.swap(
            order, abi.encode(AsyncSwap.UserParams(order.owner, address(router), order.amountOutMin, order.priorityFee))
        );
        vm.stopPrank();
    }

    /// @dev External hop so `vm.expectRevert` sees the Router call as one call.
    function submitExternal(AsyncOrder memory order) external {
        _submit(order);
    }

    function _id(AsyncOrder memory order) internal view returns (bytes32) {
        return _orderIdFor(order.owner, order.zeroForOne, order.salt);
    }

    /// @dev A pool pairing the numeraire (token1) with `asset`, opened at price 1.
    function _poolWith(address asset) internal returns (PoolId) {
        (address c0, address c1) = asset < address(token1) ? (asset, address(token1)) : (address(token1), asset);
        PoolKey memory k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), LPFeeLibrary.DYNAMIC_FEE_FLAG, 1, hook);
        manager.initialize(k, 2 ** 96);
        return k.toId();
    }

    function _tokenWithDecimals(uint8 decimals) internal returns (address) {
        return address(new MockERC20("Asset", "AST", decimals));
    }

    /* ------------------------------------------------------------------ floor per pool */

    function test_floorIsFourDecimalsOfAnEighteenDecimalAsset() public view {
        assertEq(hook.assetPrecision(), 4);
        assertEq(hook.minAssetAmount(poolId), FLOOR);
    }

    function test_floorFollowsAssetDecimals() public {
        assertEq(hook.minAssetAmount(_poolWith(_tokenWithDecimals(8))), 1e4, "0.0001 of an 8-decimal token");
        assertEq(hook.minAssetAmount(_poolWith(_tokenWithDecimals(6))), 100, "0.0001 of a 6-decimal token");
        assertEq(hook.minAssetAmount(_poolWith(_tokenWithDecimals(4))), 1, "4 decimals: 1 unit");
        assertEq(hook.minAssetAmount(_poolWith(_tokenWithDecimals(2))), 1, "fewer than 4 decimals: 1 unit");
    }

    function test_nativeAssetUsesEighteenDecimals() public {
        assertEq(hook.minAssetAmount(_poolWith(address(0))), FLOOR);
    }

    function test_tokenWithoutDecimalsGetsOneUnitFloor() public {
        assertEq(hook.minAssetAmount(_poolWith(address(new NoDecimalsToken()))), 1);
    }

    function test_reportedDecimalsAreCappedAt36() public {
        assertEq(hook.minAssetAmount(_poolWith(_tokenWithDecimals(255))), 1e32);
    }

    /* ------------------------------------------------------------------ sells */

    function test_RevertWhen_SellInputBelowFloor() public {
        AsyncOrder memory ask = _order(alice, true, FLOOR - 1, 1 ether);
        vm.expectRevert(); // BelowMinimumAssetAmount, wrapped by the PoolManager
        this.submitExternal(ask);
    }

    function test_sellAtFloorRests() public {
        AsyncOrder memory ask = _order(alice, true, FLOOR, 1 ether);
        _submit(ask);
        assertEq(hook.asyncOrder(poolId, _id(ask)), FLOOR);
    }

    /* ------------------------------------------------------------------ buys */

    function test_RevertWhen_BuyMinimumOutputBelowFloor() public {
        AsyncOrder memory bid = _order(bob, false, 1 ether, FLOOR - 1);
        vm.expectRevert();
        this.submitExternal(bid);
    }

    function test_buyAtFloorRests() public {
        AsyncOrder memory bid = _order(bob, false, 1 ether, FLOOR);
        _submit(bid);
        assertEq(hook.asyncOrder(poolId, _id(bid)), 1 ether);
    }

    function test_RevertWhen_BuyRepricedBelowFloor() public {
        AsyncOrder memory bid = _order(bob, false, 1 ether, FLOOR);
        _submit(bid);
        vm.prank(bob);
        vm.expectRevert(AsyncFiller.BelowMinimumAssetAmount.selector);
        hook.updatePrice(bid, FLOOR - 1);
    }
}
