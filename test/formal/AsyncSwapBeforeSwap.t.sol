// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalBase} from "./FormalBase.sol";
import {IAsyncSwap as AsyncSwap} from "src/interface/IAsyncSwap.sol";
import {IAsyncSwap as ImmutableState} from "src/interface/IAsyncSwap.sol";
import {IAsyncFiller as AsyncFiller} from "src/interface/IAsyncFiller.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {stdError} from "forge-std/Test.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean`.
/// @dev Guard theorems are checked by calling `hook.beforeSwap` directly (pranked as the PoolManager
///      or not). Success-path theorems need the real `poolManager.mint` (the model's opaque
///      `call_IPoolManager_mint`) and `_createOrder` (`fn_AsyncSwap_createOrder_1681`) to run, so the
///      call is made inside a real `manager.unlock` callback; the test then settles the hook's
///      escrow debt with `settleFor(hook)` so the unlock can close. This exposes the hook's raw
///      return tuple, which a full `manager.swap` would consume.
contract AsyncSwapBeforeSwapFormalTest is FormalBase, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    bytes4 constant SEL = 0x575e24b4;

    struct Call {
        address caller;
        address sender;
        PoolKey key;
        SwapParams params;
        bytes hd;
    }

    /// @dev Raw fuzz inputs; the bools steer into the guarded branches without excluding raw values.
    struct In {
        address caller;
        bool fromManager;
        address sender;
        bool senderIsExecutor;
        bool fixtureKey;
        address c0;
        address c1;
        uint24 fee;
        int24 ts;
        bool zeroForOne;
        int256 amountSpecified;
        bool steerAmount;
        uint160 sqrtPriceLimit;
        bool validHd;
        address user;
        address executor;
        uint256 amountOutMin;
        uint256 priorityFee;
        bool zeroPriorityFee;
        bytes extra;
        bool authorize;
    }

    // ---------------------------------------------------------------- harness

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        Call memory c = abi.decode(data, (Call));
        vm.prank(c.caller);
        (bool ok, bytes memory ret) =
            address(hook).call(abi.encodeCall(IHooks.beforeSwap, (c.sender, c.key, c.params, c.hd)));
        if (ok) {
            // Pay the escrow the hook minted as claims so the unlock closes.
            uint256 amt = uint256(-c.params.amountSpecified);
            Currency cur = c.params.zeroForOne ? c.key.currency0 : c.key.currency1;
            _settleForHook(cur, amt);
        }
        return abi.encode(ok, ret);
    }

    /// @dev Credit the hook `amt` of `cur` in the PoolManager. Fixture tokens are paid for real; for
    ///      a fuzzed (arbitrary-address) currency the ERC20 balance read is mocked, since the hook
    ///      itself never touches the currency in `beforeSwap`.
    function _settleForHook(Currency cur, uint256 amt) internal {
        address t = Currency.unwrap(cur);
        if (t == address(0)) {
            vm.deal(address(this), amt);
            manager.sync(cur);
            manager.settleFor{value: amt}(address(hook));
        } else if (t == address(token0) || t == address(token1)) {
            manager.sync(cur);
            MockERC20(t).mint(address(manager), amt);
            manager.settleFor(address(hook));
        } else {
            bytes memory bal = abi.encodeWithSignature("balanceOf(address)", address(manager));
            vm.mockCall(t, bal, abi.encode(uint256(0)));
            manager.sync(cur);
            vm.mockCall(t, bal, abi.encode(amt));
            manager.settleFor(address(hook));
            vm.clearMockedCalls();
        }
    }

    function _inUnlock(Call memory c) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = abi.decode(manager.unlock(abi.encode(c)), (bool, bytes));
    }

    function _direct(Call memory c) internal returns (bool ok, bytes memory ret) {
        vm.prank(c.caller);
        (ok, ret) = address(hook).call(abi.encodeCall(IHooks.beforeSwap, (c.sender, c.key, c.params, c.hd)));
    }

    function _rawKey(address c0, address c1, uint24 fee, int24 ts) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: fee,
            tickSpacing: ts,
            hooks: IHooks(address(hook))
        });
    }

    function _hd(address user, address executor, uint256 aom, uint256 pf, bytes memory extra)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(
            abi.encode(AsyncSwap.UserParams({user: user, executor: executor, amountOutMin: aom, priorityFee: pf})),
            extra
        );
    }

    /// @dev `hdWord hd pos` of the model: the big-endian word at byte `pos` (only read when in range).
    function _word(bytes memory hd, uint256 pos) internal pure returns (uint256 w) {
        assembly {
            w := mload(add(add(hd, 0x20), pos))
        }
    }

    /// @dev The model's `guards`.
    function _guards(Call memory c) internal view returns (bool) {
        int256 a = c.params.amountSpecified;
        return c.caller == address(manager) && a <= 0 && a != type(int256).min && c.hd.length >= 128
            && _word(c.hd, 0) < 2 ** 160 && _word(c.hd, 32) < 2 ** 160 && uint256(uint160(c.sender)) == _word(c.hd, 32);
    }

    /// @dev The model's `delta params` = toSigned 256 ((toUnsigned 256 (wrapI 128 (-a))) << 128).
    function _delta(int256 a) internal pure returns (int256) {
        unchecked {
            return int256(uint256(uint128(int128(-a))) << 128);
        }
    }

    function _claimBalance(Currency cur) internal view returns (uint256) {
        return manager.balanceOf(address(hook), cur.toId());
    }

    function _build(In memory x) internal returns (Call memory c) {
        c.caller = x.fromManager ? address(manager) : x.caller;
        if (!x.fixtureKey) {
            // Forge's own addresses (the cheatcode contract, console, CREATE2 factory) aren't tokens:
            // a `balanceOf` sent to `address(vm)` is rejected as an unknown cheatcode.
            assumeNotForgeAddress(x.c0);
            assumeNotForgeAddress(x.c1);
        }
        c.key = x.fixtureKey ? key : _rawKey(x.c0, x.c1, x.fee, x.ts);
        int256 a = x.amountSpecified;
        if (x.steerAmount) a = -int256(bound(uint256(a < 0 ? -(a + 1) : a), 0, 2 ** 127 - 1));
        c.params = SwapParams({zeroForOne: x.zeroForOne, amountSpecified: a, sqrtPriceLimitX96: x.sqrtPriceLimit});
        uint256 pf = x.zeroPriorityFee ? 0 : x.priorityFee;
        c.hd = x.validHd ? _hd(x.user, x.executor, x.amountOutMin, pf, x.extra) : x.extra;
        c.sender = x.senderIsExecutor ? x.executor : x.sender;
        if (x.authorize) {
            vm.prank(x.user);
            hook.setExecutor(c.key.toId(), x.executor, true);
        }
    }

    /// @dev Concrete prediction of the model's `tail` (real mint + `_createOrder`) succeeding, for
    ///      calls that pass `guards`. Returns (known, ok); `known = false` where the prediction would
    ///      need `Math.mulDiv`'s overflow condition (a huge `amountOutMin` against a tiny input).
    function _tailOk(Call memory c) internal view returns (bool known, bool ok) {
        uint256 amt = uint256(-c.params.amountSpecified);
        address user = address(uint160(_word(c.hd, 0)));
        address executor = address(uint160(_word(c.hd, 32)));
        uint256 aom = _word(c.hd, 64);
        uint256 pf = _word(c.hd, 96);
        if (amt > uint256(int256(type(int128).max))) return (true, false); // mint: SafeCastOverflow
        if (!hook.isExecutor(c.key.toId(), user, executor)) return (true, false);
        if (amt == 0 || aom == 0) return (true, false);
        // The fixture's pools are FIFO: a non-zero priority fee reverts.
        if (pf != 0) return (true, false);
        if (aom > type(uint128).max) return (false, false);
        return (true, true);
    }

    function _assertTailEffects(Call memory c, bytes memory ret, uint256 claimsBefore) internal view {
        uint256 amt = uint256(-c.params.amountSpecified);
        (bytes4 sel, int256 d, uint24 fee) = abi.decode(ret, (bytes4, int256, uint24));
        assertEq(sel, SEL, "selector");
        assertEq(d, _delta(c.params.amountSpecified), "delta");
        assertEq(fee, 0, "lp fee override");
        Currency cur = c.params.zeroForOne ? c.key.currency0 : c.key.currency1;
        assertEq(_claimBalance(cur), claimsBefore + amt, "mint(this, specified, amountTaken)");
        address user = address(uint160(_word(c.hd, 0)));
        bytes32 salt = _expectedSalt(user, amt, _word(c.hd, 64));
        bytes32 id = keccak256(abi.encode(block.chainid, c.key.toId(), user, c.params.zeroForOne, salt));
        assertEq(hook.asyncOrder(c.key.toId(), id), amt, "_createOrder(poolId, zfo, amountTaken, ...)");
    }

    // ---------------------------------------------------------------- guards

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean:78 — a caller other than the PoolManager reverts `NotPoolManager`.
    function testFuzz_beforeSwap_notPoolManager(
        address caller,
        address sender,
        address c0,
        address c1,
        uint24 fee,
        int24 ts,
        SwapParams memory params,
        bytes memory hd
    ) public {
        vm.assume(caller != address(manager));
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        vm.prank(caller);
        hook.beforeSwap(sender, _rawKey(c0, c1, fee, ts), params, hd);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean:84 — from the PoolManager, `amountSpecified > 0` reverts `ExactInputOnly`.
    function testFuzz_beforeSwap_exactInputOnly(
        address sender,
        address c0,
        address c1,
        uint24 fee,
        int24 ts,
        SwapParams memory params,
        bytes memory hd
    ) public {
        vm.assume(params.amountSpecified > 0);
        vm.expectRevert(AsyncSwap.ExactInputOnly.selector);
        vm.prank(address(manager));
        hook.beforeSwap(sender, _rawKey(c0, c1, fee, ts), params, hd);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean:91 — from the PoolManager, `amountSpecified = type(int256).min` panics 0x11.
    function testFuzz_beforeSwap_negOverflow(
        address sender,
        address c0,
        address c1,
        uint24 fee,
        int24 ts,
        bool zeroForOne,
        uint160 limit,
        bytes memory hd
    ) public {
        SwapParams memory params = SwapParams(zeroForOne, type(int256).min, limit);
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(address(manager));
        hook.beforeSwap(sender, _rawKey(c0, c1, fee, ts), params, hd);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean:101 — from the PoolManager with a valid exact-input amount, hook data that is short or has a dirty address word reverts in `abi.decode` (empty revert data).
    function testFuzz_beforeSwap_badDecode(
        address sender,
        address c0,
        address c1,
        uint24 fee,
        int24 ts,
        bool zeroForOne,
        int256 a,
        uint160 limit,
        bytes memory hd
    ) public {
        vm.assume(a <= 0 && a != type(int256).min);
        vm.assume(!(hd.length >= 128 && _word(hd, 0) < 2 ** 160 && _word(hd, 32) < 2 ** 160));
        Call memory c = Call(address(manager), sender, _rawKey(c0, c1, fee, ts), SwapParams(zeroForOne, a, limit), hd);
        (bool ok, bytes memory ret) = _direct(c);
        assertFalse(ok);
        assertEq(ret.length, 0, "abi.decode reverts with empty data");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean:101 — as above, with 4+ well-sized words where the user or executor word is not an address.
    function testFuzz_beforeSwap_badDecode_dirtyAddress(
        address sender,
        bool zeroForOne,
        int256 a,
        uint256 w0,
        uint256 w1,
        uint256 w2,
        uint256 w3,
        bytes memory extra
    ) public {
        vm.assume(a <= 0 && a != type(int256).min);
        vm.assume(!(w0 < 2 ** 160 && w1 < 2 ** 160));
        bytes memory hd = bytes.concat(abi.encode(w0, w1, w2, w3), extra);
        Call memory c = Call(address(manager), sender, key, SwapParams(zeroForOne, a, 0), hd);
        (bool ok, bytes memory ret) = _direct(c);
        assertFalse(ok);
        assertEq(ret.length, 0, "abi.decode reverts with empty data");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean:143 — past decode, `sender != hookData.executor` reverts (model: empty reason; bytecode: `NotAuthorizedExecutor()`).
    function testFuzz_beforeSwap_notExecutor(
        address sender,
        address c0,
        address c1,
        uint24 fee,
        int24 ts,
        bool zeroForOne,
        int256 a,
        address user,
        address executor,
        uint256 aom,
        uint256 pf,
        bytes memory extra
    ) public {
        vm.assume(a <= 0 && a != type(int256).min);
        vm.assume(sender != executor);
        Call memory c = Call(
            address(manager),
            sender,
            _rawKey(c0, c1, fee, ts),
            SwapParams(zeroForOne, a, 0),
            _hd(user, executor, aom, pf, extra)
        );
        (bool ok, bytes memory ret) = _direct(c);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(AsyncFiller.NotAuthorizedExecutor.selector));
    }

    // ---------------------------------------------------------------- success path

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean:161 — under the guards the call is exactly `mint(this, specified, amountTaken)` then `_createOrder(...)` then returns `(0x575e24b4, delta, 0)`.
    function testFuzz_beforeSwap_run_ok(
        bool zeroForOne,
        uint256 amt,
        address user,
        address executor,
        uint256 aom,
        bytes memory extra
    ) public {
        amt = bound(amt, 1, 2 ** 127 - 1);
        aom = bound(aom, 1, type(uint128).max);
        vm.prank(user);
        hook.setExecutor(poolId, executor, true);
        Call memory c = Call(
            address(manager), executor, key, SwapParams(zeroForOne, -int256(amt), 0), _hd(user, executor, aom, 0, extra)
        );
        Currency cur = zeroForOne ? currency0 : currency1;
        uint256 before = _claimBalance(cur);
        (bool ok, bytes memory ret) = _inUnlock(c);
        assertTrue(ok, "guards and tail succeed but call reverted");
        _assertTailEffects(c, ret, before);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean:161 — tail error propagation: under the guards, the outcome is the tail's (`mint` then `_createOrder`), including their reverts.
    function testFuzz_beforeSwap_run_ok_tailErrors(
        bool zeroForOne,
        uint256 amt,
        address user,
        address executor,
        uint256 aom,
        uint256 pf,
        bool authorize,
        bool unlocked
    ) public {
        amt = bound(amt, 0, uint256(type(int256).max));
        aom = bound(aom, 0, type(uint128).max);
        if (authorize) {
            vm.prank(user);
            hook.setExecutor(poolId, executor, true);
        }
        Call memory c = Call(
            address(manager), executor, key, SwapParams(zeroForOne, -int256(amt), 0), _hd(user, executor, aom, pf, "")
        );
        bytes memory expected;
        if (!unlocked) {
            expected = abi.encodeWithSelector(IPoolManager.ManagerLocked.selector);
        } else if (amt > uint256(int256(type(int128).max))) {
            expected = abi.encodeWithSelector(SafeCast.SafeCastOverflow.selector);
        } else if (!hook.isExecutor(poolId, user, executor)) {
            expected = abi.encodeWithSelector(AsyncFiller.NotAuthorizedExecutor.selector);
        } else if (amt == 0 || aom == 0) {
            expected = abi.encodeWithSelector(AsyncFiller.ZeroAmount.selector);
        } else if (pf != 0) {
            expected = abi.encodeWithSelector(AsyncFiller.InvalidOrderingModeChange.selector);
        }
        (bool ok, bytes memory ret) = unlocked ? _inUnlock(c) : _direct(c);
        if (expected.length == 0) {
            assertTrue(ok);
        } else {
            assertFalse(ok);
            assertEq(ret, expected);
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean:178 — every success satisfies the guards and equals the `mint`-then-`_createOrder` tail.
    /// forge-config: default.fuzz.runs = 2048
    function testFuzz_beforeSwap_ok_inv(In memory x) public {
        Call memory c = _build(x);
        uint256 before = _claimBalance(c.params.zeroForOne ? c.key.currency0 : c.key.currency1);
        (bool ok, bytes memory ret) = _inUnlock(c);
        if (ok) {
            assertTrue(_guards(c), "success without guards");
            _assertTailEffects(c, ret, before);
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean:200 — every success returns `(0x575e24b4, delta(params), 0)`.
    /// forge-config: default.fuzz.runs = 2048
    function testFuzz_beforeSwap_ok_returns(In memory x) public {
        Call memory c = _build(x);
        (bool ok, bytes memory ret) = _inUnlock(c);
        if (ok) {
            (bytes4 sel, int256 d, uint24 fee) = abi.decode(ret, (bytes4, int256, uint24));
            assertEq(sel, SEL);
            assertEq(d, _delta(c.params.amountSpecified));
            assertEq(fee, 0);
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean:213 — succeeds iff the def's guards hold and the external `mint` and `_createOrder` succeed.
    /// forge-config: default.fuzz.runs = 2048
    function testFuzz_beforeSwap_succeeds_iff(In memory x) public {
        Call memory c = _build(x);
        bool g = _guards(c);
        (bool known, bool tailOk) = g ? _tailOk(c) : (true, false);
        (bool ok,) = _inUnlock(c);
        if (ok) assertTrue(g, "success without guards");
        if (known) assertEq(ok, g && tailOk, "outcome != guards && tail succeeds");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean:288 — on success with `-amountSpecified < 2^127`, returns `(selector, amountTaken * 2^128, 0)`.
    /// forge-config: default.fuzz.runs = 2048
    function testFuzz_beforeSwap_ok_delta(In memory x) public {
        Call memory c = _build(x);
        (bool ok, bytes memory ret) = _inUnlock(c);
        if (ok && -c.params.amountSpecified < 2 ** 127) {
            (bytes4 sel, int256 d, uint24 fee) = abi.decode(ret, (bytes4, int256, uint24));
            assertEq(sel, SEL);
            assertEq(d, -c.params.amountSpecified * int256(2 ** 128));
            assertEq(fee, 0);
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean:161 — real flow: a Router swap escrows the input as hook claims and opens the order (the PoolManager consumed the hook's delta).
    function test_beforeSwap_run_ok_viaRouter() public {
        uint256 before = _claimBalance(currency0);
        (, bytes32 id) = _placeOrder(alice, true, 1 ether, 0.5 ether);
        assertEq(_claimBalance(currency0), before + 1 ether);
        assertEq(hook.asyncOrder(poolId, id), 1 ether);
    }
}
