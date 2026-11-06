// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalBase} from "./FormalBase.sol";
import {ImmutableState} from "@async-swap/ImmutableState.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapBeforeAddLiquidity.lean`.
contract AsyncSwapBeforeAddLiquidityFormalTest is FormalBase {
    bytes4 constant SEL = 0x259982e5;

    /// @dev Raw fuzz inputs for one call. `fromManager` lets the fuzzer reach the PoolManager branch
    ///      without excluding any caller; `withOrder` puts the hook in a non-trivial state first.
    struct In {
        address caller;
        bool fromManager;
        address sender;
        address c0;
        address c1;
        uint24 fee;
        int24 ts;
        address hooks;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
        bytes data;
        bool withOrder;
    }

    function _calldata(In memory x) internal pure returns (bytes memory) {
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(x.c0),
            currency1: Currency.wrap(x.c1),
            fee: x.fee,
            tickSpacing: x.ts,
            hooks: IHooks(x.hooks)
        });
        return abi.encodeCall(
            IHooks.beforeAddLiquidity,
            (x.sender, k, ModifyLiquidityParams(x.tickLower, x.tickUpper, x.liquidityDelta, x.salt), x.data)
        );
    }

    /// @dev Calls the hook under `vm.record()`; returns the outcome and the number of hook SSTOREs.
    function _call(address caller, In memory x) internal returns (bool ok, bytes memory ret, uint256 nWrites) {
        if (x.withOrder) _placeOrder(alice, true, 1 ether, 1 ether);
        bytes memory cd = _calldata(x);
        vm.record();
        vm.prank(caller);
        (ok, ret) = address(hook).call(cd);
        (, bytes32[] memory writes) = vm.accesses(address(hook));
        nWrites = writes.length;
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeAddLiquidity.lean:19 — a caller other than the PoolManager reverts `NotPoolManager`.
    function testFuzz_beforeAddLiquidity_notPoolManager(In memory x) public {
        vm.assume(x.caller != address(manager));
        (bool ok, bytes memory ret,) = _call(x.caller, x);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(ImmutableState.NotPoolManager.selector));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeAddLiquidity.lean:26 — from the PoolManager, returns `0x259982e5` and writes nothing.
    function testFuzz_beforeAddLiquidity_ok(In memory x) public {
        (bool ok, bytes memory ret, uint256 nWrites) = _call(address(manager), x);
        assertTrue(ok);
        assertEq(ret, abi.encode(SEL));
        assertEq(nWrites, 0, "hook storage written");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeAddLiquidity.lean:35 — returns the selector with state unchanged iff the caller is the PoolManager, else reverts `NotPoolManager`.
    function testFuzz_beforeAddLiquidity_spec(In memory x) public {
        address caller = x.fromManager ? address(manager) : x.caller;
        (bool ok, bytes memory ret, uint256 nWrites) = _call(caller, x);
        if (caller == address(manager)) {
            assertTrue(ok);
            assertEq(ret, abi.encode(SEL));
            assertEq(nWrites, 0, "hook storage written");
        } else {
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(ImmutableState.NotPoolManager.selector));
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeAddLiquidity.lean:47 — any success leaves state unchanged, returns the selector, and had the PoolManager as caller.
    function testFuzz_beforeAddLiquidity_frame(In memory x) public {
        address caller = x.fromManager ? address(manager) : x.caller;
        (bool ok, bytes memory ret, uint256 nWrites) = _call(caller, x);
        if (ok) {
            assertEq(nWrites, 0, "hook storage written");
            assertEq(ret, abi.encode(SEL));
            assertEq(caller, address(manager));
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeAddLiquidity.lean:26 — real flow: adding liquidity through the PoolManager succeeds (the hook returned its selector) and the hook's storage is untouched.
    function test_beforeAddLiquidity_ok_viaPoolManager() public {
        vm.record();
        _addPoolLiquidity(1e18);
        (, bytes32[] memory writes) = vm.accesses(address(hook));
        assertEq(writes.length, 0);
    }
}
