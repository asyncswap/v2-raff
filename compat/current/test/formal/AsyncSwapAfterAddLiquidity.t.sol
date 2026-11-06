// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalBase} from "./FormalBase.sol";
import {BaseHook} from "@async-swap/BaseHook.sol";
import {ImmutableState} from "@async-swap/ImmutableState.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapAfterAddLiquidity.lean`.
contract AsyncSwapAfterAddLiquidityFormalTest is FormalBase {
    /// @dev Raw fuzz inputs for one call. `fromManager` lets the fuzzer reach the PoolManager branch
    ///      without excluding any caller.
    struct In {
        address caller;
        bool fromManager;
        address sender;
        address c0;
        address c1;
        uint24 fee;
        int24 ts;
        address hooks;
        uint256 u0;
        uint256 u1;
        int256 i0;
        int256 i1;
        bool flag;
        bytes data;
        bool withOrder;
    }

    function _key(In memory x) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(x.c0),
            currency1: Currency.wrap(x.c1),
            fee: x.fee,
            tickSpacing: x.ts,
            hooks: IHooks(x.hooks)
        });
    }

    function _calldata(In memory x) internal pure returns (bytes memory) {
        PoolKey memory k = _key(x);
        return abi.encodeCall(
            IHooks.afterAddLiquidity,
            (
                x.sender,
                k,
                ModifyLiquidityParams(int24(x.i0), int24(x.i1), int256(x.u0), bytes32(x.u1)),
                BalanceDelta.wrap(x.i0),
                BalanceDelta.wrap(x.i1),
                x.data
            )
        );
    }

    function _call(address caller, In memory x) internal returns (bool ok, bytes memory ret) {
        if (x.withOrder) _placeOrder(alice, true, 1 ether, 1 ether);
        vm.prank(caller);
        (ok, ret) = address(hook).call(_calldata(x));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAfterAddLiquidity.lean:20 — a caller other than the PoolManager reverts `NotPoolManager`.
    function testFuzz_afterAddLiquidity_notPoolManager(In memory x) public {
        vm.assume(x.caller != address(manager));
        (bool ok, bytes memory ret) = _call(x.caller, x);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(ImmutableState.NotPoolManager.selector));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAfterAddLiquidity.lean:28 — from the PoolManager, the unimplemented hook reverts `HookNotImplemented`.
    function testFuzz_afterAddLiquidity_poolManager(In memory x) public {
        (bool ok, bytes memory ret) = _call(address(manager), x);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(BaseHook.HookNotImplemented.selector));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAfterAddLiquidity.lean:37 — always reverts: `HookNotImplemented` if the caller is the PoolManager, else `NotPoolManager`.
    function testFuzz_afterAddLiquidity_spec(In memory x) public {
        address caller = x.fromManager ? address(manager) : x.caller;
        (bool ok, bytes memory ret) = _call(caller, x);
        assertFalse(ok);
        assertEq(
            ret,
            caller == address(manager)
                ? abi.encodeWithSelector(BaseHook.HookNotImplemented.selector)
                : abi.encodeWithSelector(ImmutableState.NotPoolManager.selector)
        );
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAfterAddLiquidity.lean:49 — no successful run (hence no storage writes, no return value).
    function testFuzz_afterAddLiquidity_never_ok(In memory x) public {
        address caller = x.fromManager ? address(manager) : x.caller;
        (bool ok,) = _call(caller, x);
        assertFalse(ok, "hook entry point succeeded");
    }
}
