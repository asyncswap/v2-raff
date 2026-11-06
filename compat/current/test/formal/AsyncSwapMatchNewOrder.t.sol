// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {HookUnlockBase} from "./HookUnlockBase.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapMatchNewOrder.lean`. The pending-match
///         hand-off is set by a real `_beforeSwap` inside the same unlock: the test contract is a maker
///         whose executor is itself (see `HookUnlockBase._createCalls`). The model renders the
///         library guard errors as `""`; the tests name the real selectors.
contract AsyncSwapMatchNewOrderFormalTest is HookUnlockBase {
    uint256 constant BID = 50 ether;

    function setUp() public override {
        super.setUp();
        hook.setExecutor(poolId, address(this), true);
        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);
    }

    /// @dev `k` resting asks from alice at price 1 (sell token0 for token1), each a distinct size.
    function _restingAsks(uint256 k) internal {
        for (uint256 i; i < k; ++i) {
            _placeOrder(alice, true, 1 ether + i, 1 ether + i);
        }
    }

    function _bid() internal view returns (AsyncOrder memory) {
        return _selfOrder(key, false, BID, BID, 100_000);
    }

    function _matchCall(address caller, AsyncOrder memory o) internal view returns (Call memory) {
        return _cAs(caller, address(hook), abi.encodeCall(hook.matchNewOrder, (o)));
    }

    function _createThenMatch(address caller, AsyncOrder memory o) internal view returns (Call[] memory) {
        return _push(_createCalls(key, false, BID, BID, 100_000), _matchCall(caller, o));
    }

    function _countMatches(Vm.Log[] memory logs) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == AsyncSwap.AsyncOrdersMatched.selector) ++n;
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMatchNewOrder.lean:74 — consumes the pending match; reverts NotAuthorizedExecutor unless id != 0 and sender = pending executor; OrderNotFound unless the stored owner is order.owner; else returns matchIncoming's count (one AsyncOrdersMatched each) and tries the pool fill on any remainder. (semantics changed by best-price routing, which tries the pool first when its spot beats the book; Lean statement needs updating)
    function testFuzz_matchNewOrder_run(bool asExecutor, bool ownerMatches, uint8 k, bool liquidity, address other)
        public
    {
        k = uint8(bound(k, 0, 4));
        _restingAsks(k);
        if (liquidity) _addPoolLiquidity(1e24);
        AsyncOrder memory o = _bid();
        bytes32 id = _idOf(o);
        vm.assume(other != address(this) && other != address(router));
        if (!ownerMatches) o.owner = other;
        Call[] memory cs = _createThenMatch(asExecutor ? address(router) : other, o);
        if (!asExecutor) {
            vm.expectRevert(AsyncFiller.NotAuthorizedExecutor.selector);
            _run(cs);
            return;
        }
        if (!ownerMatches) {
            vm.expectRevert(AsyncFiller.OrderNotFound.selector);
            _run(cs);
            return;
        }
        vm.recordLogs();
        bytes[] memory r = _runR(cs);
        uint8 n = abi.decode(r[r.length - 1], (uint8));
        assertEq(n, _countMatches(vm.getRecordedLogs()), "returns matchIncoming's count");
        if (!liquidity) assertGt(hook.asyncOrder(poolId, id), 0, "no LP: remainder rests");
        // The pending match was consumed: a second call in a fresh unlock (no swap) reverts.
        vm.expectRevert(AsyncFiller.NotAuthorizedExecutor.selector);
        hook.matchNewOrder(o);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMatchNewOrder.lean:140 — with no pending match (id = 0), or from anyone but the pending executor, it reverts.
    function testFuzz_matchNewOrder_unauthorized(address caller, bool pending, AsyncOrder memory any) public {
        if (!pending) {
            vm.prank(caller);
            vm.expectRevert(AsyncFiller.NotAuthorizedExecutor.selector);
            hook.matchNewOrder(any);
        } else {
            vm.assume(caller != address(router));
            vm.expectRevert(AsyncFiller.NotAuthorizedExecutor.selector);
            _run(_createThenMatch(caller, _bid()));
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMatchNewOrder.lean:169 — an order whose owner is not the stored owner of the pending id reverts, whoever calls (OrderNotFound for the pending executor).
    function testFuzz_matchNewOrder_wrongOwner(address owner_, address caller, bool asExecutor) public {
        vm.assume(owner_ != address(this));
        AsyncOrder memory o = _bid();
        o.owner = owner_;
        address c = asExecutor ? address(router) : caller;
        vm.expectRevert(
            c == address(router) ? AsyncFiller.OrderNotFound.selector : AsyncFiller.NotAuthorizedExecutor.selector
        );
        _run(_createThenMatch(c, o));
    }

    /// @dev create (pending set) → the maker cancels its own order → matchNewOrder(o).
    function _cancelledThenMatch(AsyncOrder memory o, AsyncOrder memory passed) internal view returns (Call[] memory) {
        Call[] memory cs = _createCalls(key, false, BID, BID, 100_000);
        cs = _push(cs, _c(address(hook), abi.encodeCall(hook.cancelOrder, (o))));
        return _push(cs, _matchCall(address(router), passed));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMatchNewOrder.lean:181 — matchIncoming reverts (OrderNotFound) when the incoming order has amountIn = 0 (reached: the pending order was cancelled in the same unlock and the passed owner equals the cleared stored owner, 0).
    function test_matchIncoming_empty() public {
        AsyncOrder memory o = _bid();
        AsyncOrder memory passed = _bid(); // a separate copy
        passed.owner = address(0);
        vm.expectRevert(AsyncFiller.OrderNotFound.selector);
        _run(_cancelledThenMatch(o, passed));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMatchNewOrder.lean:191 — if the pending order has amountIn = 0, matchNewOrder reverts (whatever owner is passed).
    function testFuzz_matchNewOrder_emptyOrder(address owner_) public {
        AsyncOrder memory o = _bid();
        AsyncOrder memory passed = _bid(); // a separate copy
        passed.owner = owner_;
        vm.expectRevert(AsyncFiller.OrderNotFound.selector);
        _run(_cancelledThenMatch(o, passed));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMatchNewOrder.lean:207 — right after the pending match is consumed, matchNewOrder reverts for every caller and every order.
    function testFuzz_matchNewOrder_reentry_reverts(address caller, AsyncOrder memory any, uint8 k) public {
        _restingAsks(bound(k, 0, 2));
        AsyncOrder memory o = _bid();
        Call[] memory cs = _push(_createThenMatch(address(router), o), _matchCall(caller, any));
        vm.expectRevert(AsyncFiller.NotAuthorizedExecutor.selector);
        _run(cs);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMatchNewOrder.lean:223 — matchIncoming returns at most MAX_MATCHES_PER_CALL = 8, however many crossing orders rest.
    function testFuzz_matchIncoming_le(uint8 k) public {
        k = uint8(bound(k, 0, 12));
        _restingAsks(k);
        bytes[] memory r = _runR(_createThenMatch(address(router), _bid()));
        uint8 n = abi.decode(r[r.length - 1], (uint8));
        assertLe(n, 8);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMatchNewOrder.lean:252 — a success was called by the pending executor, with a pending id != 0 whose stored owner is order.owner, and returns <= 8.
    function testFuzz_matchNewOrder_ok(uint8 k, address caller, address owner_, bool exec, bool own) public {
        k = uint8(bound(k, 0, 10));
        _restingAsks(k);
        AsyncOrder memory o = _bid();
        if (!own) o.owner = owner_;
        address c = exec ? address(router) : caller;
        try manager.unlock(abi.encode(_createThenMatch(c, o))) returns (bytes memory raw) {
            bytes[] memory r = abi.decode(raw, (bytes[]));
            uint8 n = abi.decode(r[r.length - 1], (uint8));
            assertEq(c, address(router), "sender = pending executor");
            assertEq(o.owner, address(this), "stored owner = order.owner");
            assertLe(n, 8);
        } catch {}
    }
}
