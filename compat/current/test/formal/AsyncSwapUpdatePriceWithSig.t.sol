// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {HookUnlockBase} from "./HookUnlockBase.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {OrderSignatures} from "@async-swap/libraries/OrderSignatures.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean` (EOA maker,
///         EIP-712 signatures from `vm.sign`; a relayer submits).
contract AsyncSwapUpdatePriceWithSigFormalTest is HookUnlockBase {
    uint256 constant MAKER_PK = 0xA11CE;
    address maker;
    address relayer = makeAddr("relayer");

    function setUp() public override {
        super.setUp();
        maker = vm.addr(MAKER_PK);
        topUp(maker, 100 ether);
        vm.startPrank(maker);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        vm.stopPrank();
        vm.warp(1_000_000);
    }

    struct U {
        uint256 n;
        uint256 nonce;
        uint256 deadline;
    }

    /// @dev The input the last signature was made against: `_submit` passes it, read before any `expectRevert`.
    uint256 signedIn;

    function _sig(AsyncOrder memory o, uint256 storedIn, U memory u, uint256 pk) internal returns (bytes memory) {
        signedIn = storedIn;
        bytes32 id = _idOf(o);
        bytes32 sh = OrderSignatures.hashUpdatePrice(
            o,
            id,
            storedIn,
            u.n,
            hook.orderCreatedSequence(poolId, id),
            hook.orderReprices(poolId, id),
            u.nonce,
            u.deadline
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", hook.DOMAIN_SEPARATOR(), sh)));
        return abi.encodePacked(r, s, v);
    }

    function _validSig(AsyncOrder memory o, U memory u) internal returns (bytes memory) {
        return _sig(o, hook.asyncOrder(poolId, _idOf(o)), u, MAKER_PK);
    }

    function _submit(address caller, AsyncOrder memory o, U memory u, bytes memory sig) internal {
        vm.prank(caller);
        hook.updatePriceWithSig(o, signedIn, u.n, u.nonce, u.deadline, sig);
    }

    function _order() internal returns (AsyncOrder memory o) {
        (o,) = _placeOrder(maker, true, 1 ether, 1 ether);
    }

    function _future(uint256 d) internal view returns (uint256) {
        return bound(d, block.timestamp, type(uint256).max);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean:59 — _verify: SignatureExpired if deadline < now; else NonceAlreadyUsed if burnt; else burn, then InvalidSignature unless the signature is valid for maker.
    function testFuzz_verify_run(bool expired, bool used, bool valid, uint256 nonce, uint256 d, uint256 n) public {
        AsyncOrder memory o = _order();
        U memory u = U(bound(n, 1, 1e30), nonce, expired ? bound(d, 0, block.timestamp - 1) : _future(d));
        if (used) {
            vm.prank(maker);
            hook.invalidateNonce(nonce);
        }
        bytes memory sig = valid ? _validSig(o, u) : _sig(o, 1 ether, u, 0xBAD);
        bytes4 err = expired
            ? AsyncSwap.SignatureExpired.selector
            : used ? AsyncSwap.NonceAlreadyUsed.selector : !valid ? AsyncSwap.InvalidSignature.selector : bytes4(0);
        if (err != bytes4(0)) {
            vm.expectRevert(err);
            _submit(relayer, o, u, sig);
            assertEq(hook.nonceUsed(maker, nonce), used, "a revert never burns");
        } else {
            _submit(relayer, o, u, sig);
            assertTrue(hook.nonceUsed(maker, nonce), "burnt");
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean:79 — _verify over hashUpdatePrice(order, id, stored amountIn, n, nonce, deadline), then ZeroAmount, then OrderNotFound, then the reprice; no NotOrderOwner guard. (semantics changed by L-01: the hash binds createdSequence and the reprice count, and a smaller live input scales the signed minimum; Lean statement needs updating)
    function testFuzz_updatePriceWithSig_run(bool zero, bool exists, uint256 n, uint256 nonce, uint256 d) public {
        AsyncOrder memory o = _order();
        if (!exists) o.salt = bytes32(uint256(o.salt) ^ 4);
        U memory u = U(zero ? 0 : bound(n, 1, 1e30), nonce, _future(d));
        bytes memory sig = _validSig(o, u); // signed over the stored amountIn (0 for a missing order)
        if (zero) {
            vm.expectRevert(AsyncFiller.ZeroAmount.selector);
            _submit(relayer, o, u, sig);
        } else if (!exists) {
            vm.expectRevert(AsyncFiller.OrderNotFound.selector);
            _submit(relayer, o, u, sig);
        } else {
            _submit(relayer, o, u, sig);
            (, uint256 out) = hook.asyncOrderInfo(poolId, _idOf(o));
            assertEq(out, u.n);
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean:108 — an expired deadline reverts SignatureExpired.
    function testFuzz_updatePriceWithSig_expired(
        AsyncOrder memory o,
        uint256 n,
        uint256 nonce,
        uint256 d,
        bytes memory sig
    ) public {
        d = bound(d, 0, block.timestamp - 1);
        vm.expectRevert(AsyncSwap.SignatureExpired.selector);
        hook.updatePriceWithSig(o, o.amountIn, n, nonce, d, sig);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean:114 — deadline ok and (owner, nonce) used reverts NonceAlreadyUsed (even with a valid signature).
    function testFuzz_updatePriceWithSig_nonceUsed(uint256 n, uint256 nonce, uint256 d) public {
        AsyncOrder memory o = _order();
        vm.prank(maker);
        hook.invalidateNonce(nonce);
        U memory u = U(bound(n, 1, 1e30), nonce, _future(d));
        bytes memory sig = _validSig(o, u);
        vm.expectRevert(AsyncSwap.NonceAlreadyUsed.selector);
        _submit(relayer, o, u, sig);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean:122 — a signature rejected for order.owner over the digest reverts InvalidSignature (wrong signer, tampered amount, or junk bytes).
    function testFuzz_updatePriceWithSig_invalidSig(uint8 how, uint256 n, uint256 nonce, uint256 d, bytes memory junk)
        public
    {
        AsyncOrder memory o = _order();
        U memory u = U(bound(n, 1, 1e30), nonce, _future(d));
        bytes memory sig;
        if (how % 3 == 0) sig = _sig(o, 1 ether, u, 0xBAD);
        else if (how % 3 == 1) sig = _sig(o, 0.5 ether, u, MAKER_PK); // signed for a smaller order than the live one
        else sig = junk;
        vm.expectRevert(AsyncSwap.InvalidSignature.selector);
        _submit(relayer, o, u, sig);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean:132 — once _verify passes, n = 0 reverts ZeroAmount.
    function testFuzz_updatePriceWithSig_zero(uint256 nonce, uint256 d, bool exists) public {
        AsyncOrder memory o = _order();
        if (!exists) o.salt = bytes32(uint256(o.salt) ^ 4);
        U memory u = U(0, nonce, _future(d));
        bytes memory sig = _validSig(o, u);
        vm.expectRevert(AsyncFiller.ZeroAmount.selector);
        _submit(relayer, o, u, sig);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean:139 — once _verify passes, n != 0 on a missing order reverts OrderNotFound.
    function testFuzz_updatePriceWithSig_notFound(bytes32 salt, uint256 n, uint256 nonce, uint256 d) public {
        AsyncOrder memory o = _orderFromMaker(maker, true, 1 ether, 1 ether);
        o.salt = salt;
        vm.assume(hook.asyncOrder(poolId, _idOf(o)) == 0);
        U memory u = U(bound(n, 1, type(uint256).max), nonce, _future(d));
        bytes memory sig = _validSig(o, u);
        vm.expectRevert(AsyncFiller.OrderNotFound.selector);
        _submit(relayer, o, u, sig);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean:150 — the NotOrderOwner guard never fires (any submitter, any arguments); a valid signature from any relayer succeeds.
    function testFuzz_updatePriceWithSig_noOwnerGuard(address caller, uint256 n, uint256 nonce, uint256 d, bool valid)
        public
    {
        AsyncOrder memory o = _order();
        vm.assume(caller != maker);
        U memory u = U(n % 3 == 0 ? 0 : bound(n, 1, 1e30), nonce, d);
        bytes memory sig = valid ? _validSig(o, u) : _sig(o, 1 ether, u, 0xBAD);
        vm.prank(caller);
        (bool ok, bytes memory ret) =
            address(hook).call(abi.encodeCall(hook.updatePriceWithSig, (o, signedIn, u.n, u.nonce, u.deadline, sig)));
        if (!ok) assertTrue(bytes4(ret) != AsyncFiller.NotOrderOwner.selector, "NotOrderOwner never fires");
        if (valid && u.n != 0 && u.deadline >= block.timestamp) assertTrue(ok, "relayer success");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean:183 — a successful _verify passed the deadline, found the nonce fresh, accepted the signature for the owner, and left exactly the nonce burn.
    function testFuzz_verify_ok_inv(uint256 n, uint256 nonce, uint256 d, uint256 otherNonce) public {
        AsyncOrder memory o = _order();
        vm.assume(otherNonce != nonce);
        U memory u = U(bound(n, 1, 1e30), nonce, _future(d));
        bytes memory sig = _validSig(o, u);
        assertFalse(hook.nonceUsed(maker, nonce), "was fresh");
        _submit(relayer, o, u, sig);
        assertTrue(u.deadline >= block.timestamp);
        assertTrue(hook.nonceUsed(maker, nonce), "burnt");
        assertFalse(hook.nonceUsed(maker, otherNonce), "only that nonce");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean:219 — a missing order (or n = 0) always reverts, whatever the signature.
    function testFuzz_updatePriceWithSig_missing_reverts(
        bool zero,
        bytes32 salt,
        uint256 n,
        uint256 nonce,
        uint256 d,
        bool valid
    ) public {
        AsyncOrder memory o = _order();
        if (!zero) {
            o.salt = salt;
            vm.assume(hook.asyncOrder(poolId, _idOf(o)) == 0);
        }
        U memory u = U(zero ? 0 : n, nonce, d);
        bytes memory sig = valid ? _validSig(o, u) : _sig(o, 0, u, 0xBAD);
        vm.expectRevert();
        _submit(relayer, o, u, sig);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean:242 — success: deadline held, nonce was fresh, signature valid for the owner over (owner, tokens, stored amountIn, n, id, nonce, deadline), n != 0, order live; storage is the nonce burn plus the reprice (amountOutMin = n, price key >= 1, fresh sequence).
    function testFuzz_updatePriceWithSig_ok(uint256 n, uint256 nonce, uint256 d) public {
        AsyncOrder memory o = _order();
        bytes32 id = _idOf(o);
        U memory u = U(bound(n, 1, 1e30), nonce, _future(d));
        bytes memory sig = _validSig(o, u);
        uint64 seq = _nextSequence(poolId);
        bytes32[5] memory b = _orderWords(poolId, id);
        _submit(relayer, o, u, sig);
        (uint256 inA, uint256 out) = hook.asyncOrderInfo(poolId, id);
        assertEq(out, u.n);
        assertEq(inA, 1 ether);
        (,,, uint128 p,,,) = hook.orderBookOrder(poolId, id);
        assertGe(p, 1);
        assertEq(_sequenceOf(poolId, id), seq + 1);
        assertEq(_nextSequence(poolId), seq + 1);
        bytes32[5] memory a = _orderWords(poolId, id);
        assertEq(a[0], b[0], "owner");
        assertEq(a[1], b[1], "amountIn");
        assertTrue(hook.nonceUsed(maker, nonce));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean:297 — after a success nonceUsed is the old map plus (owner, nonce), and any later call with the same owner and nonce reverts.
    function testFuzz_updatePriceWithSig_burns_nonce(
        uint256 n,
        uint256 nonce,
        uint256 otherNonce,
        uint256 n2,
        uint256 d2,
        bool sameOrder
    ) public {
        AsyncOrder memory o = _order();
        vm.assume(otherNonce != nonce);
        vm.prank(maker);
        hook.invalidateNonce(otherNonce);
        U memory u = U(bound(n, 1, 1e30), nonce, block.timestamp);
        _submit(relayer, o, u, _validSig(o, u));
        assertTrue(hook.nonceUsed(maker, nonce));
        assertTrue(hook.nonceUsed(maker, otherNonce), "old entries kept");
        assertFalse(hook.nonceUsed(alice, nonce), "other owners untouched");
        AsyncOrder memory o2 = sameOrder ? o : _orderFromMaker(maker, false, 3 ether, 3 ether);
        U memory u2 = U(n2, nonce, d2);
        bytes memory sig2 = _validSig(o2, u2);
        vm.expectRevert();
        _submit(relayer, o2, u2, sig2);
    }
}
