// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalSlotsB} from "./FormalSlotsB.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapGetHookPermissions.lean`.
contract AsyncSwapGetHookPermissionsFormalTest is FormalSlotsB {
    function _hookPerms() internal pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _call(address sender) internal returns (bool ok, bytes memory ret) {
        vm.prank(sender);
        (ok, ret) = address(hook).call(abi.encodeCall(AsyncSwap.getHookPermissions, ()));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapGetHookPermissions.lean:29 — succeeds with `hookPerms`, world untouched.
    function testFuzz_getHookPermissions_run(address sender, uint64 chainId) public {
        vm.chainId(chainId);
        vm.record();
        (bool ok, bytes memory ret) = _call(sender);
        assertTrue(ok);
        assertEq(ret, abi.encode(_hookPerms()));
        _assertNoHookWrites();
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapGetHookPermissions.lean:33 — never reverts.
    function testFuzz_getHookPermissions_never_reverts(address sender) public {
        (bool ok,) = _call(sender);
        assertTrue(ok);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapGetHookPermissions.lean:39 — ok (p, w') iff p = hookPerms ∧ w' = w.
    function test_getHookPermissions_ok_iff() public {
        vm.record();
        Hooks.Permissions memory p = hook.getHookPermissions();
        _assertNoHookWrites();
        assertEq(abi.encode(p), abi.encode(_hookPerms()));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapGetHookPermissions.lean:47 — exactly the four before* flags are set.
    function test_getHookPermissions_fields() public {
        vm.record();
        Hooks.Permissions memory p = hook.getHookPermissions();
        _assertNoHookWrites();
        assertTrue(p.beforeInitialize);
        assertFalse(p.afterInitialize);
        assertTrue(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertTrue(p.beforeSwap);
        assertFalse(p.afterSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertTrue(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
    }
}
