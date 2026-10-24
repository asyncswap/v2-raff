// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalSlotsB} from "./FormalSlotsB.sol";
import {IAsyncSwap as AsyncSwap} from "src/interface/IAsyncSwap.sol";
import {IAsyncFiller as AsyncFiller} from "src/interface/IAsyncFiller.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapSetOrderingMode.lean`.
///         `mode` ranges over the ABI domain of `AsyncFiller.OrderingMode` ({0, 1}).
contract AsyncSwapSetOrderingModeFormalTest is FormalSlotsB {
    using PoolIdLibrary for PoolKey;

    struct Pre {
        uint64 nextSequence;
        uint64 openOrderCount;
        bool oldMode;
    }

    function _setOwner(address o) internal {
        vm.store(address(hook), bytes32(OWNER_SLOT), bytes32(uint256(uint160(o))));
    }

    /// @dev Model pool id `keccak [currency0, currency1, fee, toUnsigned 256 tickSpacing, hooks]`.
    function _modelPoolId(PoolKey memory k) internal pure returns (PoolId) {
        return PoolId.wrap(
            keccak256(
                abi.encode(k.currency0, k.currency1, uint256(k.fee), uint256(int256(k.tickSpacing)), address(k.hooks))
            )
        );
    }

    /// @dev Put `priceBooks[poolId(k)]` header in an arbitrary state.
    function _setBook(PoolKey memory k, Pre memory pre) internal returns (bytes32 slot) {
        slot = _bookSlot(_modelPoolId(k));
        vm.store(address(hook), slot, _bookWord(pre.nextSequence, pre.openOrderCount, pre.oldMode ? 1 : 0));
    }

    function _mode(bool m) internal pure returns (AsyncFiller.OrderingMode) {
        return m ? AsyncFiller.OrderingMode.PriorityFee : AsyncFiller.OrderingMode.FIFO;
    }

    function _call(address sender, PoolKey memory k, bool m) internal returns (bool ok, bytes memory ret) {
        vm.prank(sender);
        (ok, ret) = address(hook).call(abi.encodeCall(AsyncSwap.setOrderingMode, (k, _mode(m))));
    }

    function _one(bytes32 s) internal pure returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = s;
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSetOrderingMode.lean:24 — NotOwner; else InvalidOrderingModeChange if
    ///         openOrderCount ≠ 0; else the only write is `priceBooks[key.toId()].orderingMode := mode`.
    function testFuzz_setOrderingMode_run(
        address o,
        address sender,
        bool isOwner,
        PoolKey memory k,
        Pre memory pre,
        bool noOpen,
        bool m
    ) public {
        if (isOwner) sender = o;
        if (noOpen) pre.openOrderCount = 0;
        _setOwner(o);
        bytes32 slot = _setBook(k, pre);
        assertEq(PoolId.unwrap(k.toId()), PoolId.unwrap(_modelPoolId(k)), "model poolId = toId");
        vm.record();
        (bool ok, bytes memory ret) = _call(sender, k, m);
        if (sender != o) {
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(AsyncSwap.NotOwner.selector));
            _assertNoHookWrites();
        } else if (pre.openOrderCount != 0) {
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(AsyncFiller.InvalidOrderingModeChange.selector));
            _assertNoHookWrites();
        } else {
            assertTrue(ok);
            _assertWritesWithin(_one(slot));
            assertEq(_loadHook(slot), _bookWord(pre.nextSequence, 0, m ? 1 : 0));
            assertEq(uint8(hook.orderingMode(k.toId())), m ? 1 : 0);
            return;
        }
        assertEq(_loadHook(slot), _bookWord(pre.nextSequence, pre.openOrderCount, pre.oldMode ? 1 : 0));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSetOrderingMode.lean:38 — non-owner callers revert NotOwner.
    function testFuzz_setOrderingMode_notOwner(address o, address sender, PoolKey memory k, Pre memory pre, bool m)
        public
    {
        vm.assume(sender != o);
        _setOwner(o);
        _setBook(k, pre);
        vm.prank(sender);
        vm.expectRevert(AsyncSwap.NotOwner.selector);
        hook.setOrderingMode(k, _mode(m));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSetOrderingMode.lean:44 — any successful call was made by the owner.
    function testFuzz_setOrderingMode_ok_owner(address o, address sender, bool isOwner, PoolKey memory k, bool m)
        public
    {
        if (isOwner) sender = o;
        _setOwner(o);
        (bool ok,) = _call(sender, k, m);
        if (ok) assertEq(sender, o);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSetOrderingMode.lean:53 — success iff owner ∧ openOrderCount = 0, with
    ///         the single write to `priceBooks[poolId]`. Also run on the fixture pool with a real open order.
    function testFuzz_setOrderingMode_ok_iff(
        address o,
        address sender,
        bool isOwner,
        PoolKey memory k,
        Pre memory pre,
        bool noOpen,
        bool m,
        bool realPool
    ) public {
        if (isOwner) sender = o;
        if (realPool) {
            k = key;
            if (!noOpen) _placeOrder(alice, true, 1 ether, 0.9 ether);
            bytes32 w = _loadHook(_bookSlot(poolId));
            pre = Pre(uint64(uint256(w)), uint64(uint256(w) >> 64), uint8(uint256(w) >> 128) == 1);
        } else {
            if (noOpen) pre.openOrderCount = 0;
            _setBook(k, pre);
        }
        _setOwner(o);
        bytes32 slot = _bookSlot(k.toId());
        vm.record();
        (bool ok,) = _call(sender, k, m);
        assertEq(ok, sender == o && pre.openOrderCount == 0);
        if (ok) {
            _assertWritesWithin(_one(slot));
            assertEq(_loadHook(slot), _bookWord(pre.nextSequence, 0, m ? 1 : 0));
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSetOrderingMode.lean:67 — on success only priceBooks changes, other pools'
    ///         books are unchanged, and this pool's book differs only in orderingMode.
    function testFuzz_setOrderingMode_ok_state(PoolKey memory k, Pre memory pre, bool m, uint256 otherSeed) public {
        pre.openOrderCount = 0;
        bytes32 slot = _setBook(k, pre);
        PoolKey memory other =
            PoolKey(k.currency0, k.currency1, uint24(otherSeed), int24(int256(otherSeed >> 24)), k.hooks);
        vm.assume(PoolId.unwrap(other.toId()) != PoolId.unwrap(k.toId()));
        bytes32 otherSlot = _bookSlot(other.toId());
        vm.store(address(hook), otherSlot, bytes32(otherSeed));
        address o = hook.owner();
        bytes32 bidsRoot = _loadHook(_add(slot, 1));
        (bool ok,) = _call(o, k, m);
        assertTrue(ok);
        assertEq(_loadHook(slot), _bookWord(pre.nextSequence, 0, m ? 1 : 0), "only orderingMode changed");
        assertEq(_loadHook(_add(slot, 1)), bidsRoot, "rest of book unchanged");
        assertEq(_loadHook(otherSlot), bytes32(otherSeed), "other pool's book unchanged");
        assertEq(hook.owner(), o, "other fields unchanged");
    }

    /// @notice Domain note (no theorem): the model takes `mode : Nat`, so `setOrderingMode_run` predicts NotOwner for a
    ///         non-owner and a write of `mode` for the owner even when mode ≥ 2. The bytecode ABI-decodes the enum first
    ///         and reverts with empty data for mode ≥ 2, for every caller, before `onlyOwner` runs.
    function testFuzz_note_setOrderingMode_outOfRangeMode_revertsBeforeGuard(address sender, uint8 mode) public {
        mode = uint8(bound(mode, 2, 255));
        vm.prank(sender);
        (bool ok, bytes memory ret) =
            address(hook).call(abi.encodeWithSelector(AsyncSwap.setOrderingMode.selector, key, uint256(mode)));
        assertFalse(ok);
        assertEq(ret.length, 0, "ABI-decoding revert, not NotOwner");
    }
}
