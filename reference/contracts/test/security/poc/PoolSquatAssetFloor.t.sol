// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../../SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {MockERC20} from "../../utils/MockERC20.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Regression for L-02 (audit/lsp_security_review_2026-11-01.md). `_minAssetAmount` used to staticcall
///         `decimals()` on an address with no code, which succeeds with empty data and gave a 1-unit floor: a squatter
///         who initialized the pool before the token was deployed fixed its asset floor at 1 wei forever. An asset
///         with no code now reverts `AssetHasNoCode`, so the pool can only be opened once the token exists.
contract PoolSquatAssetFloorPoc is SetupHook {
    using PoolIdLibrary for PoolKey;

    address tokenDeployer = makeAddr("tokenDeployer");
    address squatter = makeAddr("squatter");
    address alice = makeAddr("alice");

    function setUp() public override {
        hookAssetPrecision = 4; // production: floor 1e14 for an 18-decimal asset
        hookMinOrderUsd = 10; // production default
        super.setUp();
    }

    function _keyFor(address asset, int24 spacing) internal view returns (PoolKey memory k) {
        (address c0, address c1) = asset < address(token1) ? (asset, address(token1)) : (address(token1), asset);
        k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), LPFeeLibrary.DYNAMIC_FEE_FLAG, spacing, hook);
    }

    /// @dev Sell `amountIn` of `asset` on pool `k` for at least `amountOutMin` numeraire. Returns the stored input.
    function _sell(PoolKey memory k, address asset, uint256 amountIn, uint256 amountOutMin) internal returns (uint256) {
        bool zeroForOne = Currency.unwrap(k.currency0) == asset;
        AsyncOrder memory o = AsyncOrder({
            key: k,
            owner: alice,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            priorityFee: 0,
            sqrtPrice: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            salt: keccak256(
                abi.encode(block.timestamp, block.number, address(manager), alice, amountIn, amountOutMin, 0)
            )
        });
        vm.startPrank(alice);
        hook.setExecutor(k.toId(), address(router), true);
        MockERC20(asset).approve(address(router), type(uint256).max);
        router.swap(o, abi.encode(AsyncSwap.UserParams(alice, address(router), amountOutMin, 0)));
        vm.stopPrank();
        bytes32 id = keccak256(abi.encode(block.chainid, k.toId(), alice, zeroForOne, o.salt));
        return hook.asyncOrder(k.toId(), id);
    }

    function sellExternal(PoolKey memory k, address asset, uint256 amountIn, uint256 amountOutMin) external {
        _sell(k, asset, amountIn, amountOutMin);
    }

    function test_cannotSquatPoolBeforeTokenIsDeployed() public {
        address predicted = vm.computeCreateAddress(tokenDeployer, vm.getNonce(tokenDeployer));
        assertEq(predicted.code.length, 0);
        PoolKey memory squat = _keyFor(predicted, 1);

        // The squatter cannot open the canonical pool before the token exists.
        vm.prank(squatter);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(AsyncSwap.AssetHasNoCode.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(squat, TickMath.MAX_SQRT_PRICE - 1);
        assertEq(hook.minAssetAmount(squat.toId()), 0, "pool not opened");

        // Once the token launches at the predicted address, the same key opens with the proper floor.
        vm.prank(tokenDeployer);
        MockERC20 asset = new MockERC20("Launch", "LNCH", 18);
        assertEq(address(asset), predicted);
        asset.mint(alice, 1 ether);
        manager.initialize(squat, 2 ** 96);
        assertEq(hook.minAssetAmount(squat.toId()), 1e14, "canonical pool gets the 0.0001-token floor");
        vm.expectRevert(); // BelowMinimumAssetAmount wrapped by PoolManager
        this.sellExternal(squat, address(asset), 1, 10e6);
    }

    /// Control: the pool initialized after the token exists has the 1e14 floor and rejects 1-wei sells.
    function test_control_poolAfterDeployHasFloor() public {
        vm.prank(tokenDeployer);
        MockERC20 asset = new MockERC20("Launch", "LNCH", 18);
        asset.mint(alice, 1 ether);
        PoolKey memory k = _keyFor(address(asset), 1);
        manager.initialize(k, 2 ** 96);
        emit log_named_uint("honest pool asset floor", hook.minAssetAmount(k.toId()));
        assertEq(hook.minAssetAmount(k.toId()), 1e14);
        vm.expectRevert(); // BelowMinimumAssetAmount wrapped by PoolManager
        this.sellExternal(k, address(asset), 1, 10e6);
        assertEq(_sell(k, address(asset), 1e14, 10e6), 1e14, "floor-sized sell accepted");
    }
}
