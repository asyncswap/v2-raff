// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseHook} from "src/BaseHook.sol";
import {ImmutableState} from "src/ImmutableState.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

/// @notice A hook that claims the same callbacks as AsyncSwap but overrides none of them.
contract DefaultHook is BaseHook {
    constructor(IPoolManager manager) BaseHook(manager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeAddLiquidity = true;
        p.beforeSwap = true;
    }
}

/// @notice BaseHook's callbacks revert `HookNotImplemented` unless a hook overrides them.
contract BaseHookDefaultsTest is Test {
    IPoolManager manager;
    DefaultHook hook;
    PoolKey key;

    function setUp() public {
        manager = new PoolManager(address(this));
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG);
        address at = address(uint160(1 << 100) | flags);
        deployCodeTo("test/BaseHookDefaults.t.sol:DefaultHook", abi.encode(manager), at);
        hook = DefaultHook(at);
        key = PoolKey(Currency.wrap(address(1)), Currency.wrap(address(2)), 0, 1, IHooks(at));
    }

    function test_RevertWhen_CalledByAnyoneButThePoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, 2 ** 96);
    }

    function test_unimplementedCallbacksRevert() public {
        vm.startPrank(address(manager));
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.beforeInitialize(address(this), key, 2 ** 96);
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(this), key, ModifyLiquidityParams(-60, 60, 1, 0), "");
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1, 1), "");
        vm.stopPrank();
    }
}
