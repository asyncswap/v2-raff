// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalProbesA} from "./FormalProbesA.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {Router} from "@async-swap/Router.sol";
import {OrderSignatures} from "@async-swap/libraries/OrderSignatures.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/RouterCancelWithSig.lean`. `HOOK.asyncOrderInfo` and
///         `PoolManager.unlock` are the theorems' opaque calls: mocked, except in the no-replay check,
///         which runs the real PoolManager and hook.
contract RouterCancelWithSigFormalTest is FormalProbesA {
    using PoolIdLibrary for PoolKey;

    function _cancelDigest(AsyncOrder memory o, uint256 nonce, uint256 deadline) internal view returns (bytes32) {
        return _digest(
            router.DOMAIN_SEPARATOR(),
            OrderSignatures.hashCancel(
                o, _routerOrderId(o), hook.orderCreatedSequence(o.key.toId(), _routerOrderId(o)), nonce, deadline
            )
        );
    }

    function _sig(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _mockInfo(AsyncOrder memory o, uint256 amountIn) internal {
        _authRouter(o);
        vm.mockCall(
            address(hook),
            abi.encodeCall(AsyncSwap.asyncOrderInfo, (o.key.toId(), _routerOrderId(o))),
            abi.encode(amountIn, uint256(0))
        );
    }

    function _keyed(AsyncOrder memory o, uint256 pkSeed) internal view returns (uint256 pk) {
        pk = _pk(pkSeed);
        o.owner = vm.addr(pk);
        o.key = key;
    }

    /// @notice formal/Refinement/Swarm/RouterCancelWithSig.lean:107 — `deadline < block.timestamp` reverts
    ///         with `SignatureExpired`, before anything else.
    function testFuzz_cancelWithSig_expired(
        address caller,
        AsyncOrder memory o,
        uint256 nonce,
        uint256 deadline,
        uint256 ts,
        bytes memory sig,
        bool used
    ) public {
        vm.assume(deadline < type(uint256).max);
        vm.warp(bound(ts, deadline + 1, type(uint256).max));
        if (used) vm.store(address(hook), _cancelNonceSlot(o.owner, nonce), bytes32(uint256(1)));
        vm.prank(caller);
        vm.expectRevert(Router.SignatureExpired.selector);
        router.cancelWithSig(o, nonce, deadline, sig);
    }

    /// @notice formal/Refinement/Swarm/RouterCancelWithSig.lean:112 — not expired and `(owner, nonce)` used
    ///         reverts with `NonceAlreadyUsed`.
    function testFuzz_cancelWithSig_nonce_used(
        address caller,
        AsyncOrder memory o,
        uint256 nonce,
        uint256 deadline,
        uint256 ts,
        bytes memory sig
    ) public {
        ts = bound(ts, 0, deadline);
        vm.warp(ts);
        _authRouter(o);
        vm.store(address(hook), _cancelNonceSlot(o.owner, nonce), bytes32(uint256(1)));
        vm.prank(caller);
        vm.expectRevert(AsyncSwap.NonceAlreadyUsed.selector);
        router.cancelWithSig(o, nonce, deadline, sig);
    }

    /// @notice formal/Refinement/Swarm/RouterCancelWithSig.lean:118 (semantics changed by L-01; Lean statement
    ///         needs updating) — the cancel digest no longer covers the order's size, so the Router never reads
    ///         `HOOK.asyncOrderInfo`: with that view reverting, a bad signature still reverts `InvalidSignature`.
    function testFuzz_cancelWithSig_neverReadsOrderInfo(
        address caller,
        AsyncOrder memory o,
        uint256 nonce,
        uint256 deadline,
        bytes memory sig,
        bytes memory err
    ) public {
        vm.assume(deadline >= block.timestamp);
        _authRouter(o);
        vm.assume(!SignatureChecker.isValidSignatureNow(o.owner, _cancelDigest(o, nonce, deadline), sig));
        vm.mockCallRevert(
            address(hook), abi.encodeCall(AsyncSwap.asyncOrderInfo, (o.key.toId(), _routerOrderId(o))), err
        );
        vm.prank(caller);
        vm.expectRevert(Router.InvalidSignature.selector);
        router.cancelWithSig(o, nonce, deadline, sig);
    }

    /// @notice formal/Refinement/Swarm/RouterCancelWithSig.lean:150 — a signature `isValidSignatureNow`
    ///         rejects for `order.owner` over the cancel digest reverts with `InvalidSignature`.
    function testFuzz_cancelWithSig_invalid_sig(
        address caller,
        AsyncOrder memory o,
        uint256 pkSeed,
        uint256 otherSeed,
        uint256 amountIn,
        uint256 nonce,
        uint256 deadline,
        bool randomBytes,
        bytes memory junk
    ) public {
        uint256 pk = _keyed(o, pkSeed);
        vm.assume(deadline >= block.timestamp);
        _mockInfo(o, amountIn);
        bytes32 digest = _cancelDigest(o, nonce, deadline);
        bytes memory sig = randomBytes ? junk : _sig(_pk(otherSeed), digest);
        vm.assume(!SignatureChecker.isValidSignatureNow(o.owner, digest, sig)); // the theorem's hS
        pk;
        _mockUnlockOk();
        vm.prank(caller);
        vm.expectRevert(Router.InvalidSignature.selector);
        router.cancelWithSig(o, nonce, deadline, sig);
    }

    /// @notice formal/Refinement/Swarm/RouterCancelWithSig.lean:163 — all guards pass: the call is exactly
    ///         `unlock(abi.encode(SwapCallback(Cancel, order, 0)))`.
    function testFuzz_cancelWithSig_ok(
        address caller,
        AsyncOrder memory o,
        uint256 pkSeed,
        uint256 amountIn,
        uint256 nonce,
        uint256 deadline
    ) public {
        uint256 pk = _keyed(o, pkSeed);
        vm.assume(deadline >= block.timestamp);
        _mockInfo(o, amountIn);
        bytes memory sig = _sig(pk, _cancelDigest(o, nonce, deadline));
        _mockUnlockOk();
        vm.expectCall(address(manager), 0, abi.encodeCall(IPoolManager.unlock, (_cb(2, o, 0))), 1);
        vm.prank(caller);
        router.cancelWithSig(o, nonce, deadline, sig);
    }

    struct Inv {
        address caller;
        uint256 pkSeed;
        uint256 otherSeed;
        uint256 amountIn;
        uint256 nonce;
        uint256 signedNonce;
        uint256 deadline;
        uint256 signedDeadline;
        uint8 bad;
        uint8 noise;
    }

    /// @notice formal/Refinement/Swarm/RouterCancelWithSig.lean:178 — any successful run had a live deadline,
    ///         a fresh `(owner, nonce)`, and `isValidSignatureNow(owner, digest(nonce, deadline))`. (Semantics
    ///         changed by L-01: the digest no longer covers the live amountIn; Lean statement needs updating.)
    function testFuzz_cancelWithSig_ok_inv(AsyncOrder memory o, Inv memory s) public {
        uint256 pk = _keyed(o, s.pkSeed);
        uint8 b = s.bad & s.noise;
        if (b & 1 == 0) s.deadline = bound(s.deadline, block.timestamp, type(uint256).max);
        if (b & 2 != 0) vm.store(address(hook), _cancelNonceSlot(o.owner, s.nonce), bytes32(uint256(1)));
        if (b & 4 == 0) s.otherSeed = s.pkSeed;
        if (b & 16 == 0) s.signedNonce = s.nonce;
        if (b & 32 == 0) s.signedDeadline = s.deadline;
        pk;
        _mockInfo(o, s.amountIn);
        bytes memory sig = _sig(_pk(s.otherSeed), _cancelDigest(o, s.signedNonce, s.signedDeadline));
        bool freshBefore = vm.load(address(hook), _cancelNonceSlot(o.owner, s.nonce)) == bytes32(0);
        _mockUnlockOk();
        vm.prank(s.caller);
        (bool ok,) = address(router).call(abi.encodeCall(Router.cancelWithSig, (o, s.nonce, s.deadline, sig)));
        if (ok) {
            assertGe(s.deadline, block.timestamp, "deadline held");
            assertTrue(freshBefore, "(owner, nonce) was fresh");
            assertTrue(
                SignatureChecker.isValidSignatureNow(o.owner, _cancelDigest(o, s.nonce, s.deadline), sig),
                "signature valid for owner over the live cancel digest"
            );
        }
    }

    /// @notice formal/Refinement/Swarm/RouterCancelWithSig.lean:224 — on success the only write before
    ///         `unlock` is the hook's `nonceUsed[owner][nonce] = true` (fresh before); the Router writes no
    ///         storage and no transient slot.
    function testFuzz_cancelWithSig_ok_state(
        address caller,
        AsyncOrder memory o,
        uint256 pkSeed,
        uint256 amountIn,
        uint256 nonce,
        uint256 deadline,
        address otherMaker,
        uint256 otherNonce
    ) public {
        uint256 pk = _keyed(o, pkSeed);
        vm.assume(deadline >= block.timestamp && caller != address(0));
        vm.assume(otherMaker != o.owner || otherNonce != nonce);
        _mockInfo(o, amountIn);
        bytes memory sig = _sig(pk, _cancelDigest(o, nonce, deadline));
        bytes32 slot = _cancelNonceSlot(o.owner, nonce);
        bytes32 otherSlot = _cancelNonceSlot(otherMaker, otherNonce);
        bytes32 otherBefore = vm.load(address(hook), otherSlot);
        _mockUnlockOk();
        vm.record();
        vm.prank(caller);
        router.cancelWithSig(o, nonce, deadline, sig);
        (, bytes32[] memory routerWrites) = vm.accesses(address(router));
        assertEq(routerWrites.length, 0, "the Router writes no storage");
        (, bytes32[] memory writes) = vm.accesses(address(hook));
        for (uint256 i; i < writes.length; i++) {
            assertEq(writes[i], slot, "only the hook's nonceUsed[owner][nonce] is written");
        }
        assertEq(uint256(vm.load(address(hook), slot)), 1, "nonce burnt");
        assertEq(vm.load(address(hook), otherSlot), otherBefore, "other nonces unchanged");
        // Fresh transaction: USER and FILLER are still 0 (cancelWithSig writes no transient slot).
        _assertTransient(address(0), address(0));
    }

    /// @notice formal/Refinement/Swarm/RouterCancelWithSig.lean:254 — from the state handed to `unlock`
    ///         (`(owner, nonce)` burnt), any `cancelWithSig` with the same owner and nonce reverts.
    function testFuzz_cancelWithSig_reentry_reverts(
        address caller,
        AsyncOrder memory o,
        uint256 nonce,
        uint256 deadline,
        uint256 ts,
        bytes memory sig
    ) public {
        vm.warp(ts);
        vm.store(address(hook), _cancelNonceSlot(o.owner, nonce), bytes32(uint256(1)));
        _mockUnlockOk();
        vm.prank(caller);
        (bool ok,) = address(router).call(abi.encodeCall(Router.cancelWithSig, (o, nonce, deadline, sig)));
        assertFalse(ok, "reverts");
    }

    /// @notice formal/Refinement/Swarm/RouterCancelWithSig.lean:266 — after a successful `cancelWithSig`
    ///         (real PoolManager and hook), any later `cancelWithSig` with the same `(owner, nonce)` reverts.
    function testFuzz_cancelWithSig_no_replay(
        uint256 pkSeed,
        uint256 nonce,
        AsyncOrder memory o2,
        uint256 deadline2,
        bytes memory sig2,
        address relayer,
        bool replaySameSig
    ) public {
        uint256 pk = _pk(pkSeed);
        address maker = vm.addr(pk);
        vm.assume(maker != alice && maker != bob && maker.code.length == 0);
        topUp(maker, 10 ether);
        vm.prank(maker);
        token0.approve(address(router), type(uint256).max);
        (AsyncOrder memory o,) = _placeOrder(maker, true, 1 ether, 0.9 ether);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sig(pk, _cancelDigest(o, nonce, deadline));
        vm.prank(relayer);
        router.cancelWithSig(o, nonce, deadline, sig);

        o2.owner = maker;
        if (replaySameSig) {
            o2 = o;
            deadline2 = deadline;
            sig2 = sig;
        }
        vm.prank(relayer);
        (bool ok,) = address(router).call(abi.encodeCall(Router.cancelWithSig, (o2, nonce, deadline2, sig2)));
        assertFalse(ok, "replay reverts");
    }
}
