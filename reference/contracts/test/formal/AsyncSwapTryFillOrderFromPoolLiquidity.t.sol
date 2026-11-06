// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {HookUnlockBase} from "./HookUnlockBase.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapTryFillOrderFromPoolLiquidity.lean`.
///         The model renders both library guard errors as `""`; the tests name the real selectors.
contract AsyncSwapTryFillOrderFromPoolLiquidityFormalTest is HookUnlockBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function setUp() public override {
        super.setUp();
        vm.prank(alice);
        hook.setExecutor(poolId, address(this), true);
    }

    function _tryCall(address caller, AsyncOrder memory o) internal view returns (Call[] memory) {
        return _one(_cAs(caller, address(hook), abi.encodeCall(hook.tryFillOrderFromPoolLiquidity, (o))));
    }

    function _try(address caller, AsyncOrder memory o) internal returns (bool) {
        return abi.decode(_runR(_tryCall(caller, o))[0], (bool));
    }

    /// @dev Would the self-call `fillOrderFromPoolLiquidity(o, id, 0)` succeed from the current state?
    ///      Runs it (pranked as the hook) and rolls the state back.
    function _selfFillSucceeds(AsyncOrder memory o, bytes32 id) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        Call[] memory cs =
            _one(_cAs(address(hook), address(hook), abi.encodeCall(hook.fillOrderFromPoolLiquidity, (o, id, 0))));
        try manager.unlock(abi.encode(cs)) {
            ok = true;
        } catch {
            ok = false;
        }
        vm.revertToState(snap);
    }

    /// @dev An order that rests and a pool that may or may not be able to fill it.
    function _setup(uint256 amountIn, uint256 limitBps, bool zeroForOne, bool liquidity)
        internal
        returns (AsyncOrder memory o, bytes32 id)
    {
        amountIn = bound(amountIn, 1e6, 10 ether);
        uint256 amountOutMin = amountIn * bound(limitBps, 1, 20_000) / 10_000 + 1;
        (o, id) = _placeOrder(alice, zeroForOne, amountIn, amountOutMin);
        if (liquidity) _addPoolLiquidity(1e24);
    }

    function _snapshot(bytes32 id) internal view returns (bytes32 h) {
        (uint160 sqrtP,,,) = manager.getSlot0(poolId);
        h = keccak256(
            abi.encode(
                _orderWords(poolId, id),
                _bookWord0(poolId),
                _claims(address(hook), currency0),
                _claims(address(hook), currency1),
                token0.balanceOf(alice),
                token1.balanceOf(alice),
                sqrtP
            )
        );
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapTryFillOrderFromPoolLiquidity.lean:46 — whole behaviour: revert unless executor; revert if no stored order; else true with the self-call's world if it succeeds, false with the starting world if it reverts.
    function testFuzz_tryFillOrderFromPoolLiquidity_eq(
        bool authorised,
        bool exists,
        bool liquidity,
        uint256 amountIn,
        uint256 limitBps,
        bool zeroForOne
    ) public {
        (AsyncOrder memory o, bytes32 id) = _setup(amountIn, limitBps, zeroForOne, liquidity);
        if (!exists) o.salt = bytes32(uint256(o.salt) + 1);
        address caller = authorised ? address(this) : bob;
        if (!authorised) {
            vm.expectRevert(AsyncFiller.NotAuthorizedExecutor.selector);
            _run(_tryCall(caller, o));
            return;
        }
        if (!exists) {
            vm.expectRevert(AsyncFiller.OrderNotFound.selector);
            _run(_tryCall(caller, o));
            return;
        }
        bool expected = _selfFillSucceeds(o, id);
        bytes32 before = _snapshot(id);
        bool filled = _try(caller, o);
        assertEq(filled, expected, "result = outcome of the self-call");
        if (filled) assertEq(hook.asyncOrder(poolId, id), 0, "self-call's world");
        else assertEq(_snapshot(id), before, "starting world");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapTryFillOrderFromPoolLiquidity.lean:72 — a caller the owner has not authorised as executor on the pool reverts (NotAuthorizedExecutor).
    function testFuzz_tryFillOrderFromPoolLiquidity_notExecutor(address caller, bool exists, bytes32 salt) public {
        (AsyncOrder memory o,) = _placeOrder(alice, true, 1 ether, 1 ether);
        if (!exists) o.salt = salt;
        vm.assume(!hook.isExecutor(poolId, alice, caller));
        vm.prank(caller);
        vm.expectRevert(AsyncFiller.NotAuthorizedExecutor.selector);
        hook.tryFillOrderFromPoolLiquidity(o);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapTryFillOrderFromPoolLiquidity.lean:79 — an order with no stored input reverts, whoever calls (OrderNotFound for an executor; NotAuthorizedExecutor fires first otherwise — the model names both "").
    function testFuzz_tryFillOrderFromPoolLiquidity_notFound(address caller, bytes32 salt, bool zeroForOne) public {
        AsyncOrder memory o = _orderFromMaker(alice, zeroForOne, 1 ether, 1 ether);
        o.salt = salt;
        vm.assume(hook.asyncOrder(poolId, _idOf(o)) == 0);
        bool exec = hook.isExecutor(poolId, alice, caller);
        vm.prank(caller);
        vm.expectRevert(exec ? AsyncFiller.OrderNotFound.selector : AsyncFiller.NotAuthorizedExecutor.selector);
        hook.tryFillOrderFromPoolLiquidity(o);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapTryFillOrderFromPoolLiquidity.lean:88 — both guards passing, the result is exactly the caught self-call: true with its world, or false with the starting world.
    function testFuzz_tryFillOrderFromPoolLiquidity_pass(
        bool viaRouter,
        bool liquidity,
        uint256 amountIn,
        uint256 limitBps,
        bool zeroForOne
    ) public {
        (AsyncOrder memory o, bytes32 id) = _setup(amountIn, limitBps, zeroForOne, liquidity);
        bool expected = _selfFillSucceeds(o, id);
        bytes32 before = _snapshot(id);
        bool filled = _try(viaRouter ? address(router) : address(this), o);
        assertEq(filled, expected);
        if (!filled) assertEq(_snapshot(id), before);
        else assertEq(hook.asyncOrder(poolId, id), 0);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapTryFillOrderFromPoolLiquidity.lean:103 — on success both guards held, and either true with the fill applied or false with the world unchanged.
    function testFuzz_tryFillOrderFromPoolLiquidity_ok(
        uint8 callerKind,
        bool exists,
        bool liquidity,
        uint256 amountIn,
        uint256 limitBps,
        bool zeroForOne
    ) public {
        (AsyncOrder memory o, bytes32 id) = _setup(amountIn, limitBps, zeroForOne, liquidity);
        if (!exists) o.salt = bytes32(uint256(o.salt) + 1);
        address caller = callerKind % 3 == 0 ? address(this) : callerKind % 3 == 1 ? address(router) : bob;
        bytes32 before = _snapshot(id);
        uint256 storedBefore = hook.asyncOrder(poolId, _idOf(o));
        try manager.unlock(abi.encode(_tryCall(caller, o))) returns (bytes memory r) {
            bool filled = abi.decode(abi.decode(r, (bytes[]))[0], (bool));
            assertTrue(hook.isExecutor(poolId, alice, caller), "guard 1 held");
            assertTrue(storedBefore != 0, "guard 2 held");
            if (filled) assertEq(hook.asyncOrder(poolId, id), 0, "fill applied");
            else assertEq(_snapshot(id), before, "world unchanged");
        } catch {}
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapTryFillOrderFromPoolLiquidity.lean:129 — it reverts exactly when the caller is not an authorised executor or the stored order is empty (a reverting fill is caught).
    function testFuzz_tryFillOrderFromPoolLiquidity_reverts_iff(
        address caller,
        bool exists,
        bool liquidity,
        uint256 amountIn,
        uint256 limitBps,
        bool zeroForOne
    ) public {
        (AsyncOrder memory o,) = _setup(amountIn, limitBps, zeroForOne, liquidity);
        if (!exists) o.salt = bytes32(uint256(o.salt) + 1);
        bool guardFails = !hook.isExecutor(poolId, alice, caller) || hook.asyncOrder(poolId, _idOf(o)) == 0;
        bool reverted;
        try manager.unlock(abi.encode(_tryCall(caller, o))) {}
        catch {
            reverted = true;
        }
        assertEq(reverted, guardFails);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapTryFillOrderFromPoolLiquidity.lean:151 — a false result leaves the world exactly as it was.
    function testFuzz_tryFillOrderFromPoolLiquidity_false_noop(
        bool liquidity,
        uint256 amountIn,
        uint256 limitBps,
        bool zeroForOne
    ) public {
        (AsyncOrder memory o, bytes32 id) = _setup(amountIn, limitBps, zeroForOne, liquidity);
        bytes32 before = _snapshot(id);
        if (!_try(address(this), o)) assertEq(_snapshot(id), before);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapTryFillOrderFromPoolLiquidity.lean:160 — no write of its own: when the self-call leaves the hook's storage unchanged (here: it reverts), every hook slot touched during the call holds its old value afterwards.
    function testFuzz_tryFillOrderFromPoolLiquidity_storage(
        uint256 amountIn,
        uint256 limitBps,
        bool zeroForOne,
        bool liquidity
    ) public {
        // Limit above anything the pool can pay, so the self-call reverts after doing work.
        amountIn = bound(amountIn, 1e6, 10 ether);
        (AsyncOrder memory o, bytes32 id) =
            _placeOrder(alice, zeroForOne, amountIn, amountIn * bound(limitBps, 10_001, 30_000) / 10_000);
        if (liquidity) _addPoolLiquidity(1e24);
        assertFalse(_selfFillSucceeds(o, id));
        // Pass 1: which hook slots does the call touch?
        uint256 snap = vm.snapshotState();
        vm.record();
        _try(address(this), o);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(hook));
        vm.revertToState(snap);
        bytes32[] memory before = new bytes32[](reads.length + writes.length);
        for (uint256 i; i < reads.length; ++i) {
            before[i] = _loadHook(reads[i]);
        }
        for (uint256 i; i < writes.length; ++i) {
            before[reads.length + i] = _loadHook(writes[i]);
        }
        // Pass 2: the real call, then compare every touched slot.
        assertFalse(_try(address(this), o));
        for (uint256 i; i < reads.length; ++i) {
            assertEq(_loadHook(reads[i]), before[i], "read slot changed");
        }
        for (uint256 i; i < writes.length; ++i) {
            assertEq(_loadHook(writes[i]), before[reads.length + i], "written slot changed");
        }
    }
}
