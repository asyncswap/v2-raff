// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalProbesA} from "./FormalProbesA.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {Router} from "@async-swap/Router.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Bytecode checks of `formal/Refinement/Router.lean` (`Router.swap` / `cancelOrder` / `fillOrder` /
///         `unlockCallback`). `PoolManager.unlock` and the hook's calls are the theorems' opaque `Ext`
///         functions; they are mocked where the theorem quantifies over them.
contract RefinementRouterFormalTest is FormalProbesA {
    using PoolIdLibrary for PoolKey;

    struct SwapIn {
        address sender;
        address owner_;
        bool zeroForOne;
        bool native0;
        uint256 amountIn;
        uint256 amountOutMin;
        uint256 priorityFee;
        uint256 w0;
        uint256 w1;
        uint256 w2;
        uint256 w3;
        uint256 value;
        uint8 bad;
        uint8 noise;
        uint8 cut;
        bytes extra;
    }

    function _swapOrder(SwapIn memory s) internal view returns (AsyncOrder memory o) {
        o = _orderFromMaker(s.owner_, s.zeroForOne, s.amountIn, s.amountOutMin);
        o.priorityFee = s.priorityFee;
        if (s.native0) o.key.currency0 = Currency.wrap(address(0));
    }

    function _gross(uint256 p) internal view returns (bool overflow, uint256 g) {
        uint256 fee = hook.calculatePoolFee(0, p);
        unchecked {
            g = p + fee;
        }
        overflow = g < p;
    }

    /* ----------------------------------- swap ---------------------------------- */

    /// @notice formal/Refinement/Router.lean:155 — a `swap` that does not revert had >= 128 bytes of
    ///         userData, `msg.sender == owner`, UserParams `(owner, router, amountOutMin, priorityFee)` and
    ///         `msg.value == amountIn` for native input, else 0.
    function testFuzz_swap_sound(SwapIn memory s) public {
        uint8 b = s.bad & s.noise; // each guard broken with probability 1/4
        if (b & 1 == 0) s.owner_ = s.sender;
        AsyncOrder memory o = _swapOrder(s);
        if (b & 2 == 0) s.w0 = uint256(uint160(o.owner));
        if (b & 4 == 0) s.w1 = uint256(uint160(address(router)));
        if (b & 8 == 0) s.w2 = o.amountOutMin;
        if (b & 16 == 0) s.w3 = o.priorityFee;
        bool nativeIn = o.zeroForOne && Currency.unwrap(o.key.currency0) == address(0);
        if (b & 32 == 0) s.value = nativeIn ? o.amountIn : 0;
        bytes memory ud = abi.encode(s.w0, s.w1, s.w2, s.w3);
        if (b & 64 != 0) {
            uint256 n = s.cut % 128;
            assembly ("memory-safe") {
                mstore(ud, n)
            }
        } else if (b & 128 != 0) {
            ud = bytes.concat(ud, s.extra);
        }

        _mockUnlockOk();
        vm.deal(s.sender, s.value);
        vm.prank(s.sender);
        (bool ok,) = address(router).call{value: s.value}(abi.encodeCall(Router.swap, (o, ud)));
        if (ok) {
            assertGe(ud.length, 128, "userData has four words");
            assertEq(o.owner, s.sender, "owner == msg.sender");
            assertEq(s.w0, uint256(uint160(o.owner)), "up.user == owner");
            assertEq(s.w1, uint256(uint160(address(router))), "up.executor == router");
            assertEq(s.w2, o.amountOutMin, "up.amountOutMin == order.amountOutMin");
            assertEq(s.w3, o.priorityFee, "up.priorityFee == order.priorityFee");
            assertEq(s.value, nativeIn ? o.amountIn : 0, "msg.value carries exactly a native input");
        }
    }

    /// @notice formal/Refinement/Router.lean:168 — when the Router's guard holds, `swap` stores the caller
    ///         (USER) and the Router (FILLER) in transient storage and is exactly
    ///         `unlock(abi.encode(SwapCallback(Swap, order, 0)))`.
    function testFuzz_swap_complete(SwapIn memory s) public oneTx {
        s.owner_ = s.sender;
        AsyncOrder memory o = _swapOrder(s);
        bool nativeIn = o.zeroForOne && Currency.unwrap(o.key.currency0) == address(0);
        uint256 value = nativeIn ? o.amountIn : 0;
        bytes memory ud = bytes.concat(
            abi.encode(
                AsyncSwap.UserParams({
                    user: o.owner, executor: address(router), amountOutMin: o.amountOutMin, priorityFee: o.priorityFee
                })
            ),
            s.extra
        );
        _mockUnlockOk();
        vm.expectCall(address(manager), 0, abi.encodeCall(IPoolManager.unlock, (_cb(0, o, 0))), 1);
        vm.deal(s.sender, value);
        vm.prank(s.sender);
        router.swap{value: value}(o, ud);
        _assertTransient(s.sender, address(router));
    }

    /* -------------------------------- cancelOrder ------------------------------ */

    /// @notice formal/Refinement/Router.lean:197 — a `cancelOrder` that does not revert came from the owner.
    function testFuzz_cancelOrder_sound(AsyncOrder memory o, address sender, bool fromOwner) public {
        if (fromOwner) sender = o.owner;
        _mockUnlockOk();
        vm.prank(sender);
        (bool ok,) = address(router).call(abi.encodeCall(Router.cancelOrder, (o)));
        if (ok) assertEq(sender, o.owner, "msg.sender == order.owner");
    }

    /// @notice formal/Refinement/Router.lean:206 — from the owner, `cancelOrder` stores only USER := caller
    ///         and is exactly `unlock(abi.encode(SwapCallback(Cancel, order, 0)))`.
    function testFuzz_cancelOrder_complete(AsyncOrder memory o) public oneTx {
        _mockUnlockOk();
        vm.expectCall(address(manager), 0, abi.encodeCall(IPoolManager.unlock, (_cb(2, o, 0))), 1);
        vm.prank(o.owner);
        router.cancelOrder(o);
        // FILLER is untouched (still the fresh transaction's 0).
        _assertTransient(o.owner, address(0));
    }

    /* ------------------------------- unlockCallback ----------------------------- */

    /// @notice formal/Refinement/Router.lean:269 — from the PoolManager, the Cancel callback decodes back to
    ///         the same order and is exactly `HOOK.cancelOrder(order)`, returning empty bytes (a revert
    ///         there is the call's revert).
    function testFuzz_unlockCallback_cancel(AsyncOrder memory o, bool hookReverts, bytes memory err) public {
        bytes memory data = _cb(2, o, 0);
        if (hookReverts) {
            vm.mockCallRevert(address(hook), abi.encodeCall(AsyncSwap.cancelOrder, (o)), err);
            vm.prank(address(manager));
            vm.expectRevert(err);
            router.unlockCallback(data);
        } else {
            vm.mockCall(address(hook), abi.encodeWithSelector(AsyncSwap.cancelOrder.selector), "");
            vm.expectCall(address(hook), 0, abi.encodeCall(AsyncSwap.cancelOrder, (o)), 1);
            vm.prank(address(manager));
            bytes memory ret = router.unlockCallback(data);
            assertEq(ret.length, 0, "returns empty bytes");
        }
    }

    /// @notice formal/Refinement/Router.lean:318 — a FillOrder callback that does not revert had
    ///         `liveGross = p + calculatePoolFee(p) <= tload(MAX_PRICE)` for the hook's reported live price p.
    function testFuzz_unlockCallback_fill_maxPrice(
        address maker,
        bytes32 salt,
        uint256 amountIn,
        uint256 p,
        uint256 maxPrice,
        uint8 near
    ) public {
        AsyncOrder memory o = _orderFromMaker(maker, true, amountIn, p);
        o.salt = salt;
        (bool ovf, uint256 g) = _gross(p);
        if (near % 4 != 0 && !ovf) {
            unchecked {
                maxPrice = g + (near % 4) - 2; // g-1, g, g+1 (mod 2^256)
            }
        }

        // `fillOrder` (unlock mocked) leaves `maxPrice` in the transient MAX_PRICE slot.
        _mockUnlockOk();
        vm.prank(bob);
        router.fillOrder(o, maxPrice, "");
        vm.clearMockedCalls();

        vm.mockCall(
            address(hook),
            abi.encodeCall(AsyncSwap.asyncOrderInfo, (o.key.toId(), _routerOrderId(o))),
            abi.encode(amountIn, p)
        );
        vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.sync.selector), "");
        vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.settleFor.selector), abi.encode(uint256(0)));
        vm.mockCall(address(hook), abi.encodeWithSelector(AsyncSwap.executeOrder.selector), "");
        vm.mockCall(address(token1), abi.encodeWithSelector(token1.transferFrom.selector), abi.encode(true));
        vm.prank(address(manager));
        (bool ok,) = address(router).call(abi.encodeCall(Router.unlockCallback, (_cb(1, o, 0))));
        if (ok) {
            assertFalse(ovf, "gross did not overflow");
            assertLe(g, maxPrice, "liveGross <= maxPrice");
        }
    }

    /* --------------------------------- fillOrder -------------------------------- */

    /// @notice formal/Refinement/Router.lean:380 — a `fillOrder` that does not revert sent exactly the live
    ///         gross price when the output is native, and 0 for an ERC-20 output.
    function testFuzz_fillOrder_value_sound(
        address sender,
        AsyncOrder memory o,
        bool native0,
        uint256 a,
        uint256 p,
        uint256 value,
        bool exact,
        uint256 maxPrice
    ) public {
        o.key = key;
        if (native0) o.key.currency0 = Currency.wrap(address(0));
        bool nativeOut = !o.zeroForOne && native0;
        (bool ovf, uint256 g) = _gross(p);
        if (exact) value = nativeOut ? g : 0;
        vm.mockCall(
            address(hook), abi.encodeCall(AsyncSwap.asyncOrderInfo, (o.key.toId(), _routerOrderId(o))), abi.encode(a, p)
        );
        _mockUnlockOk();
        vm.deal(sender, value);
        vm.prank(sender);
        (bool ok,) = address(router).call{value: value}(abi.encodeCall(Router.fillOrder, (o, maxPrice, "")));
        if (ok) {
            if (nativeOut) {
                assertFalse(ovf, "gross did not overflow");
                assertEq(value, g, "native output: msg.value == liveGross");
            } else {
                assertEq(value, 0, "ERC-20 output: msg.value == 0");
            }
        }
    }

    /// @notice formal/Refinement/Router.lean:398 — a `fillOrder` that does not revert ran
    ///         `unlock(abi.encode(SwapCallback(FillOrder, order, 0)))` with `tload(MAX_PRICE) == maxPrice`.
    function testFuzz_fillOrder_forwards(address sender, AsyncOrder memory o, bool native0, uint256 p, uint256 maxPrice)
        public
        oneTx
    {
        o.key = key;
        if (native0) o.key.currency0 = Currency.wrap(address(0));
        bool nativeOut = !o.zeroForOne && native0;
        (bool ovf, uint256 g) = _gross(p);
        vm.assume(!(nativeOut && ovf));
        uint256 value = nativeOut ? g : 0;
        vm.mockCall(
            address(hook), abi.encodeCall(AsyncSwap.asyncOrderInfo, (o.key.toId(), _routerOrderId(o))), abi.encode(0, p)
        );
        _mockUnlockOk();
        vm.expectCall(address(manager), 0, abi.encodeCall(IPoolManager.unlock, (_cb(1, o, 0))), 1);
        vm.deal(sender, value);
        vm.prank(sender);
        (bool ok,) = address(router).call{value: value}(abi.encodeCall(Router.fillOrder, (o, maxPrice, "")));
        assertTrue(ok, "fillOrder with the exact value succeeds");
        _assertMaxPrice(maxPrice);
    }

    /// @notice formal/Refinement/Router.lean:425 — end to end through the real PoolManager and hook, a
    ///         `fillOrder` that does not revert filled at `liveGross <= maxPrice`.
    function testFuzz_fillOrder_maxPrice(uint256 amountOutMin, uint256 maxPrice, uint8 near) public {
        amountOutMin = bound(amountOutMin, 1, 50 ether);
        (AsyncOrder memory order,) = _placeOrder(alice, true, 1 ether, amountOutMin);
        (, uint256 g) = _gross(amountOutMin);
        if (near % 4 != 0) maxPrice = g + (near % 4) - 2; // g-1, g, g+1
        vm.prank(bob);
        (bool ok,) = address(router).call(abi.encodeCall(Router.fillOrder, (order, maxPrice, "")));
        if (ok) assertLe(g, maxPrice, "liveGross <= maxPrice");
    }
}
