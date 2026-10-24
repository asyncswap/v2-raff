// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {HookUnlockBase} from "./HookUnlockBase.sol";
import {IAsyncSwap as AsyncSwap} from "src/interface/IAsyncSwap.sol";
import {OrderSignatures} from "test/utils/OrderSignatures.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapSetExecutorWithSig.lean` (EOA maker,
///         EIP-712 signatures from `vm.sign`).
contract AsyncSwapSetExecutorWithSigFormalTest is HookUnlockBase {
    using PoolIdLibrary for PoolKey;

    uint256 constant MAKER_PK = 0xA11CE;
    address maker;

    function setUp() public override {
        super.setUp();
        maker = vm.addr(MAKER_PK);
        vm.warp(1_000_000);
    }

    function _sig(PoolKey memory k, address m, address e, bool allow, uint256 nonce, uint256 deadline, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 sh = OrderSignatures.hashSetExecutor(k, m, e, allow, nonce, deadline);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", hook.DOMAIN_SEPARATOR(), sh));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Maker-signed setExecutorWithSig on the fixture key, submitted by this contract.
    function _submit(address e, bool allow, uint256 nonce, uint256 deadline) internal {
        bytes memory sig = _sig(key, maker, e, allow, nonce, deadline, MAKER_PK);
        hook.setExecutorWithSig(key, maker, e, allow, nonce, deadline, sig);
    }

    function _otherKey() internal view returns (PoolKey memory k) {
        k = key;
        k.tickSpacing = 7;
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSetExecutorWithSig.lean:94 — an expired deadline reverts SignatureExpired (any signature, any nonce state).
    function testFuzz_setExecutorWithSig_expired(
        address e,
        bool allow,
        uint256 nonce,
        uint256 deadline,
        bool validSig,
        bytes memory junk
    ) public {
        deadline = bound(deadline, 0, block.timestamp - 1);
        bytes memory sig = validSig ? _sig(key, maker, e, allow, nonce, deadline, MAKER_PK) : junk;
        vm.expectRevert(AsyncSwap.SignatureExpired.selector);
        hook.setExecutorWithSig(key, maker, e, allow, nonce, deadline, sig);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSetExecutorWithSig.lean:103 — deadline ok but (maker, nonce) already used reverts NonceAlreadyUsed, even with a valid signature.
    function testFuzz_setExecutorWithSig_nonce_used(address e, bool allow, uint256 nonce, uint256 deadline, bool viaSig)
        public
    {
        deadline = bound(deadline, block.timestamp, type(uint256).max);
        if (viaSig) {
            _submit(e, !allow, nonce, deadline);
        } else {
            vm.prank(maker);
            hook.invalidateNonce(nonce);
        }
        bytes memory sig = _sig(key, maker, e, allow, nonce, deadline, MAKER_PK);
        vm.expectRevert(AsyncSwap.NonceAlreadyUsed.selector);
        hook.setExecutorWithSig(key, maker, e, allow, nonce, deadline, sig);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSetExecutorWithSig.lean:112 — deadline ok, fresh nonce, a signature rejected for maker reverts InvalidSignature (and nothing is written).
    function testFuzz_setExecutorWithSig_invalid_sig(
        address e,
        bool allow,
        uint256 nonce,
        uint256 deadline,
        uint256 wrongPk,
        bytes memory junk
    ) public {
        bool useJunk = wrongPk % 2 == 0;
        deadline = bound(deadline, block.timestamp, type(uint256).max);
        wrongPk = bound(wrongPk, 1, 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140);
        vm.assume(wrongPk != MAKER_PK);
        bytes memory sig = useJunk ? junk : _sig(key, maker, e, allow, nonce, deadline, wrongPk);
        vm.expectRevert(AsyncSwap.InvalidSignature.selector);
        hook.setExecutorWithSig(key, maker, e, allow, nonce, deadline, sig);
        assertFalse(hook.nonceUsed(maker, nonce), "revert rolls back the burn");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSetExecutorWithSig.lean:124 — all guards pass: the result is the nonce burn followed by isExecutor[maker][executor] = allow.
    function testFuzz_setExecutorWithSig_ok(address relayer, address e, bool allow, uint256 nonce, uint256 deadline)
        public
    {
        deadline = bound(deadline, block.timestamp, type(uint256).max);
        bytes memory sig = _sig(key, maker, e, allow, nonce, deadline, MAKER_PK);
        vm.prank(relayer);
        hook.setExecutorWithSig(key, maker, e, allow, nonce, deadline, sig);
        assertEq(hook.isExecutor(poolId, maker, e), allow);
        assertTrue(hook.nonceUsed(maker, nonce));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSetExecutorWithSig.lean:139 — any success passed every guard: the signature is valid for maker over exactly (key, maker, executor, allow, nonce, deadline); changing any one of them makes the same signature fail.
    struct Args {
        PoolKey k;
        address m;
        address ex;
        bool al;
        uint256 no;
        uint256 dl;
    }

    function testFuzz_setExecutorWithSig_ok_inv(
        address e,
        bool allow,
        uint256 nonce,
        uint256 deadline,
        uint8 tamper,
        address other
    ) public {
        deadline = bound(deadline, block.timestamp, type(uint256).max - 1);
        bytes memory sig = _sig(key, maker, e, allow, nonce, deadline, MAKER_PK);
        Args memory x = Args(key, maker, e, allow, nonce, deadline);
        tamper = tamper % 7;
        if (tamper == 1) x.k = _otherKey();
        if (tamper == 2) {
            vm.assume(other != maker);
            x.m = other;
        }
        if (tamper == 3) {
            vm.assume(other != e);
            x.ex = other;
        }
        if (tamper == 4) x.al = !allow;
        if (tamper == 5) x.no = nonce ^ 1;
        if (tamper == 6) x.dl = deadline + 1;
        (bool ok,) =
            address(hook).call(abi.encodeCall(hook.setExecutorWithSig, (x.k, x.m, x.ex, x.al, x.no, x.dl, sig)));
        assertEq(ok, tamper == 0, "succeeds iff the signed arguments are submitted unchanged");
        if (ok) {
            assertTrue(x.dl >= block.timestamp);
            assertTrue(hook.nonceUsed(maker, nonce));
            assertEq(hook.isExecutor(poolId, maker, e), allow);
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSetExecutorWithSig.lean:187 — exact effect: nonceUsed[maker][nonce] was false and becomes true, then isExecutor[maker][executor] = allow.
    function testFuzz_setExecutorWithSig_ok_state(address e, bool allow, uint256 nonce, uint256 deadline) public {
        deadline = bound(deadline, block.timestamp, type(uint256).max);
        vm.prank(maker);
        hook.setExecutor(poolId, e, !allow); // start from the opposite value so the write is visible
        bytes32 nslot = keccak256(abi.encode(nonce, keccak256(abi.encode(maker, NONCE_USED_SLOT))));
        assertEq(_loadHook(nslot), bytes32(0), "fresh nonce");
        _submit(e, allow, nonce, deadline);
        assertEq(_loadHook(nslot), bytes32(uint256(1)), "nonce burnt");
        bytes32 eslot = keccak256(abi.encode(e, keccak256(abi.encode(maker, _stateSlot(poolId) + 4))));
        assertEq(_loadHook(eslot), allow ? bytes32(uint256(1)) : bytes32(0), "isExecutor[maker][executor] = allow");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSetExecutorWithSig.lean:206 — frame: only maker's executor row in this pool changes; other makers/executors/pools, all orders, price books, ownership and other nonces are unchanged.
    function testFuzz_setExecutorWithSig_frame(
        address e,
        bool allow,
        uint256 nonce,
        address otherMaker,
        address otherExec
    ) public {
        uint256 otherNonce = nonce ^ 1;
        vm.assume(otherMaker != maker && otherExec != e);
        hook.transferOwnership(bob);
        (, bytes32 id) = _placeOrder(alice, true, 1 ether, 1 ether);
        PoolKey memory k2 = _otherKey();
        PoolId p2 = k2.toId();
        vm.prank(maker);
        hook.setExecutor(p2, e, !allow);
        bytes32 h = _frame(id, p2, e, otherMaker, otherExec, nonce, otherNonce);
        _submit(e, allow, nonce, block.timestamp);
        assertEq(_frame(id, p2, e, otherMaker, otherExec, nonce, otherNonce), h, "frame");
        assertTrue(hook.nonceUsed(maker, nonce));
        assertEq(hook.isExecutor(poolId, maker, e), allow);
    }

    function _frame(bytes32 id, PoolId p2, address e, address om, address oe, uint256 nonce, uint256 on)
        internal
        view
        returns (bytes32)
    {
        bytes32 h1 = keccak256(abi.encode(_orderWords(poolId, id), _bookWord0(poolId)));
        bytes32 h2 = keccak256(
            abi.encode(
                hook.isExecutor(poolId, om, e),
                hook.isExecutor(poolId, alice, address(router)),
                hook.isExecutor(poolId, maker, oe),
                hook.isExecutor(p2, maker, e)
            )
        );
        bytes32 h3 = keccak256(
            abi.encode(
                hook.nonceUsed(maker, on),
                hook.nonceUsed(om, nonce),
                _loadHook(bytes32(OWNER_SLOT)),
                _loadHook(bytes32(PENDING_OWNER_SLOT)),
                _loadHook(bytes32(_stateSlot(poolId)))
            )
        );
        return keccak256(abi.encode(h1, h2, h3));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSetExecutorWithSig.lean:252 — after a success, any call with the same (maker, nonce) reverts, whatever the other arguments or signature.
    function testFuzz_setExecutorWithSig_no_replay(
        address e,
        bool allow,
        uint256 nonce,
        address e2,
        bool allow2,
        uint256 deadline2,
        uint8 flags
    ) public {
        bool otherKey = flags & 1 != 0;
        bool freshSig = flags & 2 != 0;
        _submit(e, allow, nonce, block.timestamp);
        PoolKey memory k = otherKey ? _otherKey() : key;
        bytes memory sig = freshSig ? _sig(k, maker, e2, allow2, nonce, deadline2, MAKER_PK) : bytes("");
        vm.expectRevert(
            deadline2 < block.timestamp ? AsyncSwap.SignatureExpired.selector : AsyncSwap.NonceAlreadyUsed.selector
        );
        hook.setExecutorWithSig(k, maker, e2, allow2, nonce, deadline2, sig);
    }
}
