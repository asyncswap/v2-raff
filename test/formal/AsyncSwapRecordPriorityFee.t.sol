// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {HookUnlockBase} from "./HookUnlockBase.sol";
import {IAsyncFiller as AsyncFiller} from "src/interface/IAsyncFiller.sol";
import {AsyncOrder} from "src/interface/types/AsyncOrder.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapRecordPriorityFee.lean`. The pending
///         match is set by a real `_beforeSwap` inside the same unlock (the test contract is a maker
///         whose executor is itself), followed by the bid payment `sync`/`transfer`/`settleFor(hook)`
///         exactly as `Router._settlePriorityFee`. The model names the first two guard errors `""`.
contract AsyncSwapRecordPriorityFeeFormalTest is HookUnlockBase {
    function setUp() public override {
        super.setUp();
        hook.setExecutor(poolId, address(this), true);
        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);
    }

    function _priorityMode() internal {
        hook.setOrderingMode(key, AsyncFiller.OrderingMode.PriorityFee);
    }

    function _recordCall(address caller, address maker, uint256 amount) internal view returns (Call memory) {
        return _cAs(caller, address(hook), abi.encodeCall(hook.recordPriorityFee, (key, maker, amount)));
    }

    /// @dev create(bid) + pay bid to the hook's credit + recordPriorityFee(caller, maker, amount).
    function _flow(uint256 bid, address caller, address maker, uint256 amount) internal view returns (Call[] memory) {
        return _push(_createCalls(key, true, 1 ether, 1 ether, bid), _recordCall(caller, maker, amount));
    }

    /// @dev The revert a non-first record (bid already escrowed, or wrong amount) must hit, by guard order.
    function _expected(address caller, address maker) internal view returns (bytes4) {
        if (caller != address(this)) return AsyncFiller.NotAuthorizedExecutor.selector;
        if (maker != address(this)) return AsyncFiller.OrderNotFound.selector;
        return AsyncFiller.PriorityFeeNotEscrowed.selector;
    }

    function _bidOrder(uint256 bid) internal view returns (AsyncOrder memory) {
        return _selfOrder(key, true, 1 ether, 1 ether, bid);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapRecordPriorityFee.lean:87 — NotAuthorizedExecutor unless a match is pending and sender = its executor; OrderNotFound unless the stored owner is maker; PriorityFeeNotEscrowed unless live, unescrowed, amount = stored fee != 0; else mint exactly amount numeraire claims to the hook, set the flag, re-queue in priority mode.
    function testFuzz_recordPriorityFee_run(
        bool asExecutor,
        bool rightMaker,
        bool rightAmount,
        uint256 bid,
        address other,
        uint256 amount
    ) public {
        _priorityMode();
        bid = bound(bid, 100_000, type(uint64).max);
        vm.assume(other != address(this));
        if (rightAmount) amount = bid;
        else vm.assume(amount != bid);
        Call[] memory cs = _flow(bid, asExecutor ? address(this) : other, rightMaker ? address(this) : other, amount);
        if (!asExecutor) {
            vm.expectRevert(AsyncFiller.NotAuthorizedExecutor.selector);
            _run(cs);
        } else if (!rightMaker) {
            vm.expectRevert(AsyncFiller.OrderNotFound.selector);
            _run(cs);
        } else if (!rightAmount) {
            vm.expectRevert(AsyncFiller.PriorityFeeNotEscrowed.selector);
            _run(cs);
        } else {
            bytes32 id = _idOf(_bidOrder(bid));
            uint256 claimsBefore = _claims(address(hook), currency1);
            _run(cs);
            assertEq(_claims(address(hook), currency1) - claimsBefore, bid, "exactly amount numeraire claims to hook");
            assertTrue(_escrowedFlag(poolId, id), "priorityFeeEscrowed := true");
            assertEq(hook.asyncOrderPriorityFee(poolId, id), bid);
            // Re-queued with the paid bid: priorityKey = bid << 64 | (2^64-1 - sequence).
            uint128 pk = uint128(uint256(_orderWord(poolId, id, 7)));
            assertEq(pk, (uint128(bid) << 64) | uint128(type(uint64).max - _sequenceOf(poolId, id)), "re-queued");
            (,, bytes32 best,) = hook.bestOrder(poolId, false);
            assertEq(best, id);
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapRecordPriorityFee.lean:154 — without a pending match, or from anyone but the pending executor, it reverts.
    function testFuzz_recordPriorityFee_unauthorized(address caller, address maker, uint256 amount, bool pending)
        public
    {
        _priorityMode();
        if (!pending) {
            vm.prank(caller);
            vm.expectRevert(AsyncFiller.NotAuthorizedExecutor.selector);
            hook.recordPriorityFee(key, maker, amount);
        } else {
            vm.assume(caller != address(this));
            vm.expectRevert(AsyncFiller.NotAuthorizedExecutor.selector);
            _run(_flow(1e6, caller, maker, amount));
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapRecordPriorityFee.lean:160 — naming a maker other than the pending order's stored owner reverts (whoever calls).
    function testFuzz_recordPriorityFee_wrong_maker(address maker, address caller, bool asExecutor, uint256 amount)
        public
    {
        _priorityMode();
        vm.assume(maker != address(this));
        address c = asExecutor ? address(this) : caller;
        vm.expectRevert(
            c == address(this) ? AsyncFiller.OrderNotFound.selector : AsyncFiller.NotAuthorizedExecutor.selector
        );
        _run(_flow(1e6, c, maker, amount));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapRecordPriorityFee.lean:169 — once the pending order's bid is escrowed (a FIFO order is escrowed at creation; or after a record), any call reverts.
    function testFuzz_recordPriorityFee_escrowed_reverts(
        bool fifo,
        address caller,
        address maker,
        uint256 amount,
        bool asExec
    ) public {
        address c = asExec ? address(this) : caller;
        address mk = asExec ? address(this) : maker;
        Call[] memory cs;
        if (fifo) {
            cs = _push(_createCalls(key, true, 1 ether, 1 ether, 0), _recordCall(c, mk, amount));
        } else {
            _priorityMode();
            cs = _push(_flow(1e6, address(this), address(this), 1e6), _recordCall(c, mk, amount));
        }
        vm.expectRevert(_expected(c, mk));
        _run(cs);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapRecordPriorityFee.lean:181 — any amount other than the stored priorityFee reverts.
    function testFuzz_recordPriorityFee_amount_mismatch_reverts(
        uint256 bid,
        uint256 amount,
        address caller,
        bool asExec
    ) public {
        _priorityMode();
        bid = bound(bid, 100_000, type(uint64).max);
        vm.assume(amount != bid);
        address c = asExec ? address(this) : caller;
        vm.expectRevert(_expected(c, address(this)));
        _run(_flow(bid, c, address(this), amount));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapRecordPriorityFee.lean:197 — a success came from the pending executor, on the pending order owned by maker, live, unescrowed, amount = stored fee != 0, and minted exactly amount numeraire claims to the hook.
    function testFuzz_recordPriorityFee_ok(uint256 bid, uint256 amount, address maker, address caller, uint8 kind)
        public
    {
        _priorityMode();
        bid = bound(bid, 100_000, type(uint64).max);
        if (kind % 4 != 0) amount = bid;
        if (kind % 4 != 1) maker = address(this);
        if (kind % 4 != 2) caller = address(this);
        bytes32 id = _idOf(_bidOrder(bid));
        uint256 claimsBefore = _claims(address(hook), currency1);
        try manager.unlock(abi.encode(_flow(bid, caller, maker, amount))) {
            assertEq(caller, address(this), "pending executor");
            assertEq(maker, address(this), "stored owner = maker");
            assertEq(amount, bid, "amount = stored priorityFee");
            assertTrue(amount != 0);
            assertEq(_claims(address(hook), currency1) - claimsBefore, amount, "minted exactly amount");
            assertTrue(_escrowedFlag(poolId, id));
            assertEq(hook.asyncOrder(poolId, id), 1 ether, "live order");
        } catch {}
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapRecordPriorityFee.lean:264 — right after the flag write, recording the same pending order's bid again reverts, whoever calls and whatever maker/amount.
    function testFuzz_recordPriorityFee_twice_reverts(address caller, address maker, uint256 amount, uint8 kind)
        public
    {
        _priorityMode();
        if (kind % 2 == 0) {
            caller = address(this);
            maker = address(this);
        }
        if (kind % 3 == 0) amount = 1e6;
        Call[] memory cs = _push(_flow(1e6, address(this), address(this), 1e6), _recordCall(caller, maker, amount));
        vm.expectRevert(_expected(caller, maker));
        _run(cs);
    }
}
