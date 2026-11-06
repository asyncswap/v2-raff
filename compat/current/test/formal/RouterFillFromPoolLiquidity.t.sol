// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalProbesA} from "./FormalProbesA.sol";
import {Router} from "@async-swap/Router.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/RouterFillFromPoolLiquidity.lean`. `PoolManager.unlock`
///         is the theorems' opaque call: mocked (ok with fuzzed return bytes, or reverting with fuzzed data).
contract RouterFillFromPoolLiquidityFormalTest is FormalProbesA {
    /// @notice formal/Refinement/Swarm/RouterFillFromPoolLiquidity.lean:28 — the call is two transient stores
    ///         (USER := caller, FILLER := router) then exactly `unlock(abi.encode(SwapCallback(PoolLiquidityFill, order, 0)))`.
    function testFuzz_fillFromPoolLiquidity_eq(address caller, AsyncOrder memory o, bytes memory ret) public oneTx {
        vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.unlock.selector), abi.encode(ret));
        vm.expectCall(address(manager), 0, abi.encodeCall(IPoolManager.unlock, (_cb(5, o, 0))), 1);
        vm.prank(caller);
        router.fillFromPoolLiquidity(o);
        _assertTransient(caller, address(router));
    }

    /// @notice formal/Refinement/Swarm/RouterFillFromPoolLiquidity.lean:37 — reverts exactly when `unlock`
    ///         reverts, with the same error.
    function testFuzz_fillFromPoolLiquidity_revert_iff(
        address caller,
        AsyncOrder memory o,
        bool unlockReverts,
        bytes memory err
    ) public {
        if (unlockReverts) {
            vm.mockCallRevert(address(manager), abi.encodeCall(IPoolManager.unlock, (_cb(5, o, 0))), err);
            vm.prank(caller);
            vm.expectRevert(err);
            router.fillFromPoolLiquidity(o);
        } else {
            vm.mockCall(address(manager), abi.encodeCall(IPoolManager.unlock, (_cb(5, o, 0))), abi.encode(err));
            vm.prank(caller);
            (bool ok,) = address(router).call(abi.encodeCall(Router.fillFromPoolLiquidity, (o)));
            assertTrue(ok, "unlock ok => call ok");
        }
    }

    /// @notice formal/Refinement/Swarm/RouterFillFromPoolLiquidity.lean:48 — succeeds exactly when `unlock`
    ///         succeeds; the Router writes no persistent storage of its own.
    function testFuzz_fillFromPoolLiquidity_ok_iff(address caller, AsyncOrder memory o, bytes memory ret) public {
        vm.mockCall(address(manager), abi.encodeCall(IPoolManager.unlock, (_cb(5, o, 0))), abi.encode(ret));
        vm.record();
        vm.prank(caller);
        (bool ok,) = address(router).call(abi.encodeCall(Router.fillFromPoolLiquidity, (o)));
        assertTrue(ok, "unlock ok => call ok");
        _assertNoWrites(address(router));
    }

    /// @notice formal/Refinement/Swarm/RouterFillFromPoolLiquidity.lean:58 — the two writes before `unlock`
    ///         touch only transient storage: USER := caller, FILLER := router, persistent storage unchanged.
    function testFuzz_fillFromPoolLiquidityPre_get(address caller, address seed, AsyncOrder memory o) public oneTx {
        _seedTransient(seed);
        _mockUnlockOk();
        vm.record();
        vm.prank(caller);
        router.fillFromPoolLiquidity(o);
        _assertNoWrites(address(router));
        _assertTransient(caller, address(router));
    }
}
