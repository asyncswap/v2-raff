// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalSlotsB} from "./FormalSlotsB.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

/// @notice Runs the real v4-core `CurrencyLibrary.transfer` and `StateLibrary` code (internal library
///         functions, inlined here by the compiler exactly as in AsyncSwap and the Router).
contract SpecCoreLibHarness {
    function transfer(Currency currency, address to, uint256 amount) external {
        CurrencyLibrary.transfer(currency, to, amount);
    }

    function poolStateSlot(PoolId poolId) external pure returns (bytes32) {
        return StateLibrary._getPoolStateSlot(poolId);
    }

    function getSlot0(IPoolManager manager, PoolId poolId) external view returns (uint160, int24, uint24, uint24) {
        return StateLibrary.getSlot0(manager, poolId);
    }

    function getLiquidity(IPoolManager manager, PoolId poolId) external view returns (uint128) {
        return StateLibrary.getLiquidity(manager, poolId);
    }

    receive() external payable {}
}

/// @dev A native-transfer recipient that accepts, or reverts with configured data.
contract SpecCoreReceiver {
    bool public reject;
    bytes public data;

    function set(bool r, bytes calldata d) external {
        reject = r;
        data = d;
    }

    receive() external payable {
        if (reject) {
            bytes memory d = data;
            assembly ("memory-safe") {
                revert(add(d, 0x20), mload(d))
            }
        }
    }
}

/// @dev A token whose `transfer` (any call other than `balanceOf` / `set`) returns, or reverts with,
///      configured bytes.
contract SpecCoreToken {
    bool public rev;
    bytes public ret;
    uint256 public bal;

    function set(bool r, bytes calldata d, uint256 b) external {
        rev = r;
        ret = d;
        bal = b;
    }

    function balanceOf(address) external view returns (uint256) {
        return bal;
    }

    fallback() external {
        bytes memory d = ret;
        if (rev) {
            assembly ("memory-safe") {
                revert(add(d, 0x20), mload(d))
            }
        }
        assembly ("memory-safe") {
            return(add(d, 0x20), mload(d))
        }
    }
}

/// @notice Bytecode checks of the named specs in `formal/Refinement/Swarm/SpecCoreAsyncSwap.lean` and
///         `formal/Refinement/Swarm/SpecCoreRouter.lean`:
///         - `CreateOrderSpec` (`AsyncSwap._createOrder`, private): through the real hook's
///           `beforeSwap`, called from inside a real `manager.unlock` (as the PoolManager), so the real
///           `mint` and `_createOrder` run, and the transient hand-off can be read in the same transaction.
///         - `TransferSpec` (v4-core `CurrencyLibrary.transfer`): on the real library code through
///           `SpecCoreLibHarness`, and through the hook's `sweep`, which reaches AsyncSwap's own copy.
///         - `PoolStateSlotSpec` (v4-core `StateLibrary._getPoolStateSlot`) and the `getSlot0` /
///           `getLiquidity` bridges, against the real PoolManager.
contract SpecCoreFormalTest is FormalSlotsB, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    bytes32 constant PENDING_MATCH_EXECUTOR = 0x9583e36f799bab8c4d06dc676d85ba05b4dfbde5934d5684d8e431d0fd3948da;
    bytes4 constant TRANSFER_SELECTOR = 0xa9059cbb;

    SpecCoreLibHarness lib;
    SpecCoreReceiver receiver;
    SpecCoreToken tok;

    struct Swap {
        address user;
        address executor;
        bool zeroForOne;
        uint256 amt;
        uint256 aom;
        uint256 pf;
        uint256 times; // how many identical `beforeSwap` calls to make in the one unlock
    }

    struct Out {
        bool ok;
        bytes ret;
        uint256 tId;
        uint256 tExecutor;
        uint256 tNative;
    }

    function setUp() public override {
        super.setUp();
        lib = new SpecCoreLibHarness();
        receiver = new SpecCoreReceiver();
        tok = new SpecCoreToken();
    }

    // ================================================================ `_createOrder` harness

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        Swap memory s = abi.decode(data, (Swap));
        Out memory o;
        bytes memory hd = abi.encode(
            AsyncSwap.UserParams({user: s.user, executor: s.executor, amountOutMin: s.aom, priorityFee: s.pf})
        );
        SwapParams memory params = SwapParams(s.zeroForOne, -int256(s.amt), 0);
        for (uint256 i; i < s.times; ++i) {
            vm.prank(address(manager));
            (o.ok, o.ret) = address(hook).call(abi.encodeCall(IHooks.beforeSwap, (s.executor, key, params, hd)));
            if (!o.ok) return abi.encode(o);
        }
        o.tId = _tload(address(hook), PENDING_MATCH_ID);
        o.tExecutor = _tload(address(hook), PENDING_MATCH_EXECUTOR);
        o.tNative = _tload(address(hook), PENDING_NATIVE_DEPOSIT);
        // Pay the escrow the hook minted as claims, so the unlock closes.
        Currency cur = s.zeroForOne ? currency0 : currency1;
        manager.sync(cur);
        MockERC20(Currency.unwrap(cur)).mint(address(manager), s.amt * s.times);
        manager.settleFor(address(hook));
        manager.sync(currency1);
        token1.mint(address(manager), s.pf * s.times);
        manager.settleFor(address(hook));
        return abi.encode(o);
    }

    function _run(Swap memory s) internal returns (Out memory o) {
        o = abi.decode(manager.unlock(abi.encode(s)), (Out));
    }

    /// @dev The spec's `salt0`: `keccak256(abi.encode(timestamp, number, msg.sender = PoolManager, user,
    ///      amountIn, amountOutMin, priorityFee))`.
    function _salt0(Swap memory s) internal view returns (bytes32) {
        return keccak256(abi.encode(block.timestamp, block.number, address(manager), s.user, s.amt, s.aom, s.pf));
    }

    /// @dev The spec's `idAt k`.
    function _idAt(Swap memory s, uint256 k) internal view returns (bytes32) {
        bytes32 salt = _salt0(s);
        for (uint256 i; i < k; ++i) {
            salt = keccak256(abi.encode(salt));
        }
        return keccak256(abi.encode(block.chainid, poolId, s.user, s.zeroForOne, salt));
    }

    function _isExecutorSlot(address user, address executor) internal view returns (bytes32) {
        return keccak256(abi.encode(executor, keccak256(abi.encode(user, uint256(_stateSlot(poolId)) + 4))));
    }

    function _authorise(Swap memory s) internal {
        vm.prank(s.user);
        hook.setExecutor(poolId, s.executor, true);
    }

    function _swap(address user, address executor, bool zfo, uint256 amt, uint256 aom, uint256 pf)
        internal
        pure
        returns (Swap memory)
    {
        return Swap(user, executor, zfo, amt, aom, pf, 1);
    }

    // ================================================================ CreateOrderSpec

    /// @notice formal/Refinement/Swarm/SpecCoreAsyncSwap.lean:111 — `CreateOrderSpec.notAuthorised`: without `isExecutor[user][executor]`, `_createOrder` reverts `NotAuthorizedExecutor()`, whatever the amounts.
    function testFuzz_CreateOrderSpec_notAuthorised(
        address user,
        address executor,
        bool zfo,
        uint256 amt,
        uint256 aom,
        bool grantOther
    ) public {
        executor = address(router); // the hook's one trusted swap caller
        amt = bound(amt, 0, 2 ** 127 - 1);
        aom = bound(aom, 0, type(uint128).max);
        Swap memory s = _swap(user, executor, zfo, amt, aom, 100_000);
        if (grantOther) {
            // A grant in the other direction, or to another executor, does not count.
            vm.prank(executor);
            hook.setExecutor(poolId, user, true);
            vm.prank(user);
            hook.setExecutor(poolId, address(uint160(executor) ^ 1), true);
        }
        vm.assume(!hook.isExecutor(poolId, user, executor));
        Out memory o = _run(s);
        assertFalse(o.ok);
        assertEq(o.ret, abi.encodeWithSelector(AsyncFiller.NotAuthorizedExecutor.selector));
    }

    /// @notice formal/Refinement/Swarm/SpecCoreAsyncSwap.lean:115 — `CreateOrderSpec.zeroAmount`: authorised, with `amountIn = 0` or `amountOutMin = 0`, `_createOrder` reverts `ZeroAmount()`.
    function testFuzz_CreateOrderSpec_zeroAmount(
        address user,
        address executor,
        bool zfo,
        uint256 amt,
        uint256 aom,
        bool zeroIn,
        uint256 pf
    ) public {
        executor = address(router); // the hook's one trusted swap caller
        amt = zeroIn ? 0 : bound(amt, 0, 2 ** 127 - 1);
        aom = zeroIn ? bound(aom, 0, type(uint128).max) : 0;
        // The zero check comes before addOrder's priority-fee checks.
        Swap memory s = _swap(user, executor, zfo, amt, aom, pf);
        _authorise(s);
        Out memory o = _run(s);
        assertFalse(o.ok);
        assertEq(o.ret, abi.encodeWithSelector(AsyncFiller.ZeroAmount.selector));
    }

    /// @dev Occupy the first `k` ids of the walk (nonzero `amountIn`) so the walk stops at step `k`.
    function _occupy(Swap memory s, uint256 k, uint256 seed) internal returns (bytes32[] memory taken) {
        taken = new bytes32[](k);
        for (uint256 j; j < k; ++j) {
            taken[j] = _idAt(s, j);
            uint256 v = uint256(keccak256(abi.encode(seed, j))) | 1;
            vm.store(address(hook), _add(_orderSlot(poolId, taken[j]), 1), bytes32(v));
        }
    }

    /// @dev The slots `_createOrder` must not write: owner, pendingOwner, the pool state's header
    ///      (poolManager, numeraire, feeVault), the executor grant, EIP-712 fallback strings, and every
    ///      slot of the orders the walk skipped.
    function _assertNoForbiddenWrites(Swap memory s, bytes32[] memory taken) internal view {
        bytes32[] memory writes = _hookWrites();
        bytes32 st = _stateSlot(poolId);
        for (uint256 i; i < writes.length; ++i) {
            bytes32 x = writes[i];
            assertTrue(x != bytes32(OWNER_SLOT) && x != bytes32(PENDING_OWNER_SLOT), "owner");
            assertTrue(x != bytes32(0) && x != bytes32(uint256(1)), "EIP-712 fallback strings");
            assertTrue(x != st && x != _add(st, 1) && x != _add(st, 2), "pool state header");
            assertTrue(x != _isExecutorSlot(s.user, s.executor), "executor grant");
            for (uint256 j; j < taken.length; ++j) {
                bytes32 o = _orderSlot(poolId, taken[j]);
                for (uint256 f; f < 8; ++f) {
                    assertTrue(x != _add(o, f), "skipped order");
                }
            }
        }
    }

    function _assertWrote(bytes32 slot) internal view {
        bytes32[] memory writes = _hookWrites();
        bool found;
        for (uint256 i; i < writes.length; ++i) {
            if (writes[i] == slot) found = true;
        }
        assertTrue(found, "expected SSTORE missing");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean:227 — note, not a test of a new theorem: `beforeSwap_frame`'s `hcreate` (that `_createOrder` leaves the hook's storage unchanged) is false on the bytecode, which stores the new order; so that theorem holds only vacuously, and `beforeSwap_frame_of_spec` replaces it.
    function test_note_beforeSwap_frame_hcreate_false() public {
        Swap memory s = _swap(alice, address(router), true, 1 ether, 0.5 ether, 100_000);
        _authorise(s);
        vm.record();
        Out memory o = _run(s);
        assertTrue(o.ok);
        _assertWrote(_add(_orderSlot(poolId, _idAt(s, 0)), 1));
        assertEq(hook.asyncOrder(poolId, _idAt(s, 0)), 1 ether, "_createOrder changed the hook's storage");
    }

    /// @dev The order record `addOrder` stores for `newOrderOf id amountIn hd isBuy zfo` at sequence `seq`.
    function _assertStored(Swap memory s, bytes32 id, uint64 seq, bytes32) internal view {
        bytes32 o = _orderSlot(poolId, id);
        bool isBuy = !s.zeroForOne; // specified == numeraire (currency1)
        uint256 price = AsyncFiller._priceKey(isBuy, s.zeroForOne, s.amt, s.aom);
        assertEq(uint256(_loadHook(o)), uint256(uint160(s.user)), "owner = hookData.user");
        assertEq(uint256(_loadHook(_add(o, 1))), s.amt, "amountIn");
        assertEq(uint256(_loadHook(_add(o, 2))), s.aom, "amountOutMin = hookData.amountOutMin");
        uint256 packed = uint256(_loadHook(_add(o, 3)));
        assertEq(uint128(packed), price, "price key");
        assertEq((packed >> 128) & 0xff, isBuy ? 1 : 0, "isBuy");
        assertEq((packed >> 136) & 0xff, s.zeroForOne ? 1 : 0, "zeroForOne");
        assertEq(uint64(packed >> 144), seq, "sequence");
        uint256 bidWord = uint256(_loadHook(_add(o, 4)));
        assertEq(uint64(bidWord), s.pf, "priorityFee");
        assertEq(uint128(bidWord >> 64), (s.pf << 64) | (type(uint64).max - seq), "priority key");
        // `_append` linked it at the tail of its level.
        (, bytes32 tail,) = hook.orderBookLevel(poolId, isBuy, uint128(price));
        assertEq(tail, id, "appended at the tail");
    }

    /// @notice formal/Refinement/Swarm/SpecCoreAsyncSwap.lean:119 — `CreateOrderSpec.run`: authorised with nonzero amounts and the walk stopping at step `k` (the first `k` ids occupied), `_createOrder` is `addOrder(newOrderOf (idAt k) …)` then `tstore(PENDING_MATCH_ID, id)`, `tstore(PENDING_MATCH_EXECUTOR, executor)`, and nothing else.
    function testFuzz_CreateOrderSpec_run(
        address user,
        address executor,
        bool zfo,
        uint256 amt,
        uint256 aom,
        uint256 k,
        uint256 seed
    ) public {
        executor = address(router); // the hook's one trusted swap caller
        Swap memory s =
            _swap(user, executor, zfo, bound(amt, 1, 2 ** 127 - 1), bound(aom, 1, type(uint128).max), 100_000);
        _checkRun(s, bound(k, 0, 4), seed);
    }

    function _takenAmounts(bytes32[] memory taken) internal view returns (uint256[] memory a) {
        a = new uint256[](taken.length);
        for (uint256 j; j < taken.length; ++j) {
            a[j] = uint256(_loadHook(_add(_orderSlot(poolId, taken[j]), 1)));
        }
    }

    function _checkRun(Swap memory s, uint256 k, uint256 seed) internal {
        _authorise(s);
        bytes32[] memory taken = _occupy(s, k, seed);
        uint256[] memory takenIn = _takenAmounts(taken);
        uint64 seq = uint64(uint256(_loadHook(_bookSlot(poolId)))) + 1;
        vm.record();
        Out memory o = _run(s);
        assertTrue(o.ok, "guards pass and the walk stops: _createOrder succeeds");
        bytes32 id = _idAt(s, k);
        assertEq(o.tId, uint256(id), "tstore(PENDING_MATCH_ID_SLOT, id at the walk's stop)");
        assertEq(o.tExecutor, uint256(uint160(s.executor)), "tstore(PENDING_MATCH_EXECUTOR_SLOT, executor)");
        assertEq(o.tNative, 0, "no other transient slot");
        _assertStored(s, id, seq, bytes32(0));
        _assertNoForbiddenWrites(s, taken);
        _assertWrote(_add(_orderSlot(poolId, id), 1));
        uint256[] memory takenAfter = _takenAmounts(taken);
        for (uint256 j; j < k; ++j) {
            assertEq(takenAfter[j], takenIn[j], "skipped order kept");
        }
        assertTrue(hook.isExecutor(poolId, s.user, s.executor), "grant kept");
    }

    /// @notice formal/Refinement/Swarm/SpecCoreAsyncSwap.lean:167 — `createBody_frame`: a successful `createBody` writes only pool `poolId`'s order state and book (no owner, pending owner, EIP-712 strings, pool header, executor grant, or skipped order), and leaves the hand-off slots holding `id` and `executor`, with other transient slots untouched.
    function testFuzz_createBody_frame(
        address user,
        address executor,
        bool zfo,
        uint256 amt,
        uint256 aom,
        uint256 k,
        uint256 seed
    ) public {
        executor = address(router); // the hook's one trusted swap caller
        Swap memory s =
            _swap(user, executor, zfo, bound(amt, 1, 2 ** 127 - 1), bound(aom, 1, type(uint128).max), 100_000);
        _checkRun(s, bound(k, 0, 4), seed);
    }

    /// @notice formal/Refinement/Swarm/SpecCoreAsyncSwap.lean:262 — `beforeSwap_frame_of_spec`: a successful `beforeSwap` (real `mint`, then `_createOrder`) changes only pool `poolId`'s state and book plus the two hand-off slots, which hold the walk's id and `hookData.executor`; the fixture's other pool stays untouched.
    function testFuzz_beforeSwap_frame_of_spec(
        address user,
        address executor,
        bool zfo,
        uint256 amt,
        uint256 aom,
        uint256 k,
        uint256 seed
    ) public {
        executor = address(router); // the hook's one trusted swap caller
        Swap memory s =
            _swap(user, executor, zfo, bound(amt, 1, 2 ** 127 - 1), bound(aom, 1, type(uint128).max), 100_000);
        PoolId other = PoolId.wrap(keccak256(abi.encode(seed, "other pool")));
        bytes32 otherState = _stateSlot(other);
        bytes32 otherBook = _bookSlot(other);
        _checkRun(s, bound(k, 0, 4), seed);
        bytes32[] memory writes = _hookWrites();
        for (uint256 i; i < writes.length; ++i) {
            for (uint256 f; f < 5; ++f) {
                assertTrue(writes[i] != _add(otherState, f) && writes[i] != _add(otherBook, f), "other pool");
            }
        }
    }

    /// @notice formal/Refinement/Swarm/SpecCoreAsyncSwap.lean:119 — `CreateOrderSpec.run`, natural collisions: the same maker repeating an identical order in one transaction gets ids `idAt 0`, `idAt 1`, `idAt 2`.
    function testFuzz_CreateOrderSpec_run_repeat(address user, address executor, bool zfo, uint256 amt, uint256 aom)
        public
    {
        executor = address(router); // the hook's one trusted swap caller
        amt = bound(amt, 1, 2 ** 120);
        aom = bound(aom, 1, type(uint128).max);
        Swap memory s = _swap(user, executor, zfo, amt, aom, 100_000);
        s.times = 3;
        _authorise(s);
        uint64 seq = uint64(uint256(_loadHook(_bookSlot(poolId))));
        Out memory o = _run(s);
        assertTrue(o.ok);
        for (uint256 k; k < 3; ++k) {
            assertEq(hook.asyncOrder(poolId, _idAt(s, k)), amt, "walk step k holds the k-th copy");
        }
        _assertStored(s, _idAt(s, 2), seq + 3, _idAt(s, 1));
        assertEq(o.tId, uint256(_idAt(s, 2)), "the last id is handed off");
    }

    /// @notice formal/Refinement/Swarm/SpecCoreAsyncSwap.lean:119 — `CreateOrderSpec.run` propagates `addOrder`'s guards: in FIFO a nonzero priority fee reverts `InvalidOrderingModeChange`; in PriorityFee mode a fee below the minimum reverts `PriorityFeeTooSmall`, above `2^64 - 1` `PriorityFeeTooLarge`, otherwise the order is stored with that fee.
    function testFuzz_CreateOrderSpec_run_addOrderGuards(
        address user,
        address executor,
        bool zfo,
        uint256 amt,
        uint256 aom,
        uint256 pf,
        bool priority
    ) public {
        executor = address(router); // the hook's one trusted swap caller
        amt = bound(amt, 1, 2 ** 127 - 1);
        aom = bound(aom, 1, type(uint128).max);
        Swap memory s = _swap(user, executor, zfo, amt, aom, pf);
        _authorise(s);
        uint64 seq = uint64(uint256(_loadHook(_bookSlot(poolId)))) + 1;
        bytes memory expected;
        if (pf != 0 && pf < _tieredMinFee(zfo ? aom : amt)) {
            expected = abi.encodeWithSelector(AsyncFiller.PriorityFeeTooSmall.selector);
        } else if (pf > type(uint64).max) {
            expected = abi.encodeWithSelector(AsyncFiller.PriorityFeeTooLarge.selector);
        }
        Out memory o = _run(s);
        if (expected.length != 0) {
            assertFalse(o.ok);
            assertEq(o.ret, expected);
        } else {
            assertTrue(o.ok);
            if (!priority) _assertStored(s, _idAt(s, 0), seq, bytes32(0));
            else assertEq(hook.asyncOrder(poolId, _idAt(s, 0)), amt);
            assertEq(o.tId, uint256(_idAt(s, 0)));
        }
    }

    /// @dev `AsyncFiller.minPriorityFee`: min($0.10, 0.1% of the order).
    function _tieredMinFee(uint256 notional) internal pure returns (uint256) {
        return notional / 1000 < 100_000 ? notional / 1000 : 100_000;
    }

    // ================================================================ TransferSpec

    function _wrapped(bytes memory ret)
        internal
        pure
        returns (bytes4 sel, address target, bytes4 fsel, bytes memory reason, bytes memory details)
    {
        require(ret.length >= 4, "short revert data");
        sel = bytes4(ret);
        bytes memory body = new bytes(ret.length - 4);
        for (uint256 i; i < body.length; ++i) {
            body[i] = ret[i + 4];
        }
        (target, fsel, reason, details) = abi.decode(body, (address, bytes4, bytes, bytes));
    }

    function _assertWrapped(bytes memory ret, address target, bytes4 fsel, bytes memory reason, bytes4 context)
        internal
        pure
    {
        (bytes4 sel, address t, bytes4 f, bytes memory r, bytes memory d) = _wrapped(ret);
        assertEq(sel, CustomRevert.WrappedError.selector, "WrappedError");
        assertEq(t, target, "reverting contract");
        assertEq(f, fsel, "reverting selector");
        assertEq(r, reason, "bubbled-up reason");
        assertEq(d, abi.encodePacked(context), "additional context");
    }

    /// @dev Native branch, any recipient kind: an accepting contract, a rejecting one, an EOA.
    function _checkNative(uint8 kind, address eoa, bytes memory reason, uint256 amount, uint256 balance) internal {
        vm.deal(address(lib), balance);
        address to;
        bool accepts;
        if (kind % 3 == 0) {
            receiver.set(false, "");
            to = address(receiver);
            accepts = true;
        } else if (kind % 3 == 1) {
            receiver.set(true, reason);
            to = address(receiver);
        } else {
            assumeNotPrecompile(eoa);
            assumeNotForgeAddress(eoa);
            vm.assume(eoa.code.length == 0 && eoa != address(lib));
            to = eoa;
            accepts = true;
        }
        bool ok = accepts && amount <= balance;
        uint256 toBefore = to.balance;
        if (ok) vm.expectCall(to, amount, "");
        vm.record();
        (bool success, bytes memory ret) =
            address(lib).call(abi.encodeCall(SpecCoreLibHarness.transfer, (CurrencyLibrary.ADDRESS_ZERO, to, amount)));
        (, bytes32[] memory writes) = vm.accesses(address(lib));
        assertEq(writes.length, 0, "transfer writes no storage of its own");
        assertEq(success, ok, "succeeds iff the value call succeeds");
        if (ok) {
            assertEq(to.balance, toBefore + amount, "value = amount");
            assertEq(address(lib).balance, balance - amount);
        } else {
            _assertWrapped(
                ret,
                to,
                bytes4(0),
                amount <= balance ? reason : bytes(""),
                CurrencyLibrary.NativeTransferFailed.selector
            );
            assertEq(address(lib).balance, balance, "nothing moved");
        }
    }

    /// @dev Return data of the mock token's `transfer`, by mode.
    function _tokenReturn(uint8 mode, uint256 word, bytes memory extra)
        internal
        pure
        returns (bool rev, bytes memory rd)
    {
        mode = mode % 6;
        if (mode == 0) rd = "";
        else if (mode == 1) rd = bytes.concat(abi.encode(uint256(1)), extra);
        else if (mode == 2) rd = bytes.concat(abi.encode(word), extra);
        else if (mode == 3) rd = extra.length >= 32 ? bytes.concat(bytes31(bytes32(extra))) : extra;
        else if (mode == 4) rd = abi.encode(false);
        else (rev, rd) = (true, extra);
    }

    function _okReturn(bytes memory rd) internal pure returns (bool) {
        return rd.length == 0 || (rd.length >= 32 && uint256(bytes32(rd)) == 1);
    }

    function _checkErc20(uint8 mode, uint256 word, bytes memory extra, address to, uint256 amount) internal {
        (bool rev, bytes memory rd) = _tokenReturn(mode, word, extra);
        tok.set(rev, rd, 0);
        bool ok = !rev && _okReturn(rd);
        vm.expectCall(address(tok), 0, abi.encodeWithSelector(TRANSFER_SELECTOR, to, amount), 1);
        vm.record();
        (bool success, bytes memory ret) =
            address(lib).call(abi.encodeCall(SpecCoreLibHarness.transfer, (Currency.wrap(address(tok)), to, amount)));
        (, bytes32[] memory writes) = vm.accesses(address(lib));
        assertEq(writes.length, 0, "transfer writes no storage of its own");
        assertEq(success, ok, "succeeds iff the call succeeds and okReturn(returndata)");
        if (!ok) {
            _assertWrapped(ret, address(tok), TRANSFER_SELECTOR, rd, CurrencyLibrary.ERC20TransferFailed.selector);
        }
    }

    /// @notice formal/Refinement/Swarm/SpecCoreAsyncSwap.lean:331 — `TransferSpec.native`: for currency 0, one call to `to` with value `amount` and empty calldata; it succeeds iff that call does, and otherwise reverts `WrappedError(to, 0, reason, NativeTransferFailed)`; no storage write of its own.
    function testFuzz_TransferSpec_native(uint8 kind, address eoa, bytes memory reason, uint256 amount, uint256 balance)
        public
    {
        balance = bound(balance, 0, 1e30);
        amount = bound(amount, 0, 2e30);
        _checkNative(kind, eoa, reason, amount, balance);
    }

    /// @notice formal/Refinement/Swarm/SpecCoreAsyncSwap.lean:342 — `TransferSpec.erc20`: for a token, one call with value 0 and `transfer(to, amount)` calldata; it succeeds iff the call succeeds and returns nothing or a first word of exactly 1, and otherwise reverts `WrappedError(token, transfer.selector, returndata, ERC20TransferFailed)`; no storage write of its own.
    function testFuzz_TransferSpec_erc20(uint8 mode, uint256 word, bytes memory extra, address to, uint256 amount)
        public
    {
        _checkErc20(mode, word, extra, to, amount);
    }

    /// @notice formal/Refinement/Swarm/SpecCoreAsyncSwap.lean:342 — `TransferSpec.erc20` for a currency with no code: the call succeeds with empty return data, so the transfer succeeds (v4-core does not check code size).
    function testFuzz_TransferSpec_erc20_noCode(address token, address to, uint256 amount) public {
        assumeNotPrecompile(token);
        assumeNotForgeAddress(token);
        vm.assume(token != address(0) && token.code.length == 0);
        vm.expectCall(token, 0, abi.encodeWithSelector(TRANSFER_SELECTOR, to, amount), 1);
        lib.transfer(Currency.wrap(token), to, amount);
    }

    /// @notice formal/Refinement/Swarm/SpecCoreAsyncSwap.lean:357 — `TransferSpec.ok_iff`: `transfer` succeeds exactly when its one call succeeds (and, for a token, the return data passes `okReturn`), across both branches.
    function testFuzz_TransferSpec_ok_iff(
        bool native,
        uint8 mode,
        uint256 word,
        bytes memory extra,
        address eoa,
        uint256 amount
    ) public {
        if (native) _checkNative(mode, eoa, extra, bound(amount, 0, 2e18), 1e18);
        else _checkErc20(mode, word, extra, eoa, amount);
    }

    /// @notice formal/Refinement/Swarm/SpecCoreAsyncSwap.lean:376 — `TransferSpec.frame`: with a call that does not touch the caller's storage, a successful transfer leaves it unchanged (no SSTORE on the caller in either branch).
    function testFuzz_TransferSpec_frame(bool native, uint256 amount, address to) public {
        assumeNotPrecompile(to);
        assumeNotForgeAddress(to);
        vm.assume(to.code.length == 0 && to != address(lib));
        amount = bound(amount, 0, 1e18);
        vm.deal(address(lib), 1e18);
        tok.set(false, abi.encode(true), 0);
        vm.record();
        lib.transfer(native ? CurrencyLibrary.ADDRESS_ZERO : Currency.wrap(address(tok)), to, amount);
        (, bytes32[] memory writes) = vm.accesses(address(lib));
        assertEq(writes.length, 0);
    }

    /// @notice formal/Refinement/Swarm/SpecCoreAsyncSwap.lean:331 — `TransferSpec` on AsyncSwap's own copy (`fn_CurrencyLibrary_transfer_4290`), through `sweep`: native to an accepting / rejecting recipient, and to a token with fuzzed return data; the hook writes no storage.
    function testFuzz_TransferSpec_viaSweep(
        bool native,
        bool reject,
        bytes memory reason,
        uint256 bal,
        uint8 mode,
        uint256 word,
        address to
    ) public {
        bal = bound(bal, 0, 1e30);
        vm.record();
        if (native) {
            vm.deal(address(hook), bal);
            receiver.set(reject, reason);
            uint256 before = address(receiver).balance;
            (bool success, bytes memory ret) =
                address(hook).call(abi.encodeCall(AsyncSwap.sweep, (CurrencyLibrary.ADDRESS_ZERO, address(receiver))));
            assertEq(success, !reject);
            if (reject) {
                _assertWrapped(ret, address(receiver), bytes4(0), reason, CurrencyLibrary.NativeTransferFailed.selector);
            } else {
                assertEq(address(receiver).balance, before + bal);
            }
        } else {
            vm.assume(to != address(0));
            (bool rev, bytes memory rd) = _tokenReturn(mode, word, reason);
            tok.set(rev, rd, bal);
            bool ok = !rev && _okReturn(rd);
            vm.expectCall(address(tok), 0, abi.encodeWithSelector(TRANSFER_SELECTOR, to, bal), 1);
            (bool success, bytes memory ret) =
                address(hook).call(abi.encodeCall(AsyncSwap.sweep, (Currency.wrap(address(tok)), to)));
            assertEq(success, ok);
            if (!ok) {
                _assertWrapped(ret, address(tok), TRANSFER_SELECTOR, rd, CurrencyLibrary.ERC20TransferFailed.selector);
            }
        }
        _assertNoHookWrites();
    }

    /// @notice formal/Refinement/Swarm/SpecCoreRouter.lean:52 — Router `TransferSpec.native` (`fn_CurrencyLibrary_transfer_2524`, the same v4-core library): as the AsyncSwap test.
    function testFuzz_Router_TransferSpec_native(
        uint8 kind,
        address eoa,
        bytes memory reason,
        uint256 amount,
        uint256 balance
    ) public {
        balance = bound(balance, 0, 1e30);
        amount = bound(amount, 0, 2e30);
        _checkNative(kind, eoa, reason, amount, balance);
    }

    /// @notice formal/Refinement/Swarm/SpecCoreRouter.lean:62 — Router `TransferSpec.erc20`: as the AsyncSwap test.
    function testFuzz_Router_TransferSpec_erc20(
        uint8 mode,
        uint256 word,
        bytes memory extra,
        address to,
        uint256 amount
    ) public {
        _checkErc20(mode, word, extra, to, amount);
    }

    /// @notice formal/Refinement/Swarm/SpecCoreRouter.lean:77 — Router `TransferSpec.ok_iff`: as the AsyncSwap test.
    function testFuzz_Router_TransferSpec_ok_iff(
        bool native,
        uint8 mode,
        uint256 word,
        bytes memory extra,
        address eoa,
        uint256 amount
    ) public {
        if (native) _checkNative(mode, eoa, extra, bound(amount, 0, 2e18), 1e18);
        else _checkErc20(mode, word, extra, eoa, amount);
    }

    /// @notice formal/Refinement/Swarm/SpecCoreRouter.lean:97 — Router `TransferSpec.frame`: as the AsyncSwap test.
    function testFuzz_Router_TransferSpec_frame(bool native, uint256 amount, address to) public {
        testFuzz_TransferSpec_frame(native, amount, to);
    }

    // ================================================================ PoolStateSlotSpec

    /// @notice formal/Refinement/Swarm/SpecCoreAsyncSwap.lean:402 — `PoolStateSlotSpec.pure_ok`: `_getPoolStateSlot` never reverts and writes nothing (it runs under STATICCALL).
    function testFuzz_PoolStateSlotSpec_pure_ok(bytes32 id) public {
        vm.record();
        (bool ok, bytes memory ret) =
            address(lib).staticcall(abi.encodeCall(SpecCoreLibHarness.poolStateSlot, (PoolId.wrap(id))));
        assertTrue(ok);
        assertEq(ret.length, 32);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(lib));
        assertEq(reads.length + writes.length, 0, "touches no storage");
    }

    /// @notice formal/Refinement/Swarm/SpecCoreAsyncSwap.lean:404 — `PoolStateSlotSpec.value`: it returns `keccak256(abi.encodePacked(poolId, bytes32(uint256(6))))`.
    function testFuzz_PoolStateSlotSpec_value(bytes32 id) public view {
        assertEq(lib.poolStateSlot(PoolId.wrap(id)), keccak256(abi.encode(id, uint256(6))));
    }

    /// @notice formal/Refinement/Swarm/SpecCoreAsyncSwap.lean:414 — `getLiquidity_of_spec`: `getLiquidity` is the low 128 bits of `extsload(keccak256(poolId ‖ 6) + 3)` (fixture pool with fuzzed liquidity, or a fuzzed pool id).
    function testFuzz_getLiquidity_of_spec(bytes32 id, bool fixture, uint256 liq) public {
        if (fixture) {
            id = PoolId.unwrap(poolId);
            liq = bound(liq, 1, 1e24);
            _addPoolLiquidity(int128(int256(liq)));
        }
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(id, uint256(6)))) + 3);
        vm.expectCall(address(manager), abi.encodeWithSignature("extsload(bytes32)", slot));
        uint128 l = lib.getLiquidity(manager, PoolId.wrap(id));
        assertEq(l, uint128(uint256(manager.extsload(slot))));
        if (fixture) assertEq(l, liq);
    }

    /// @notice formal/Refinement/Swarm/SpecCoreAsyncSwap.lean:439 — `getSlot0_of_spec`: `getSlot0` decodes `extsload(keccak256(poolId ‖ 6))` (`slot0Of`).
    function testFuzz_getSlot0_of_spec(bytes32 id, bool fixture, uint256 data) public {
        if (fixture) id = PoolId.unwrap(poolId);
        bytes32 slot = keccak256(abi.encode(id, uint256(6)));
        if (!fixture) vm.store(address(manager), slot, bytes32(data));
        uint256 d = uint256(manager.extsload(slot));
        vm.expectCall(address(manager), abi.encodeWithSignature("extsload(bytes32)", slot));
        (uint160 p, int24 t, uint24 pf, uint24 lf) = lib.getSlot0(manager, PoolId.wrap(id));
        assertEq(p, uint160(d), "sqrtPriceX96 = low 160 bits");
        assertEq(t, int24(uint24(d >> 160)), "tick = signextend(2, d >> 160)");
        assertEq(pf, uint24(d >> 184), "protocolFee");
        assertEq(lf, uint24(d >> 208), "lpFee");
        if (fixture) assertEq(p, 2 ** 96, "fixture pool initialised at price 1");
    }

    /// @notice formal/Refinement/Swarm/SpecCoreAsyncSwap.lean:453 — `getLiquidity_zero_of_spec`: a pool whose `extsload(slot + 3)` has zero low 128 bits reads liquidity 0 (fresh pool ids, and high bits set by `vm.store`).
    function testFuzz_getLiquidity_zero_of_spec(bytes32 id, uint128 high) public {
        vm.assume(id != PoolId.unwrap(poolId));
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(id, uint256(6)))) + 3);
        vm.store(address(manager), slot, bytes32(uint256(high) << 128));
        assertEq(lib.getLiquidity(manager, PoolId.wrap(id)), 0);
    }
}
