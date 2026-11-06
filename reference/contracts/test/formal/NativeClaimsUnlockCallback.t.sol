// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalBase} from "./FormalBase.sol";
import {NativeClaims} from "@async-swap/NativeClaims.sol";
import {Currency, IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {stdError} from "forge-std/Test.sol";

/// @dev Mints native ERC-6909 claims (id 0) to any address inside a real PoolManager unlock.
contract NCUClaimMinter {
    IPoolManager immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function mint(address to, uint256 amount) external payable {
        pm.unlock(abi.encode(to, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address to, uint256 amount) = abi.decode(data, (address, uint256));
        pm.settle{value: amount}();
        pm.mint(to, 0, amount);
        return "";
    }
}

/// @notice Bytecode checks of `formal/Refinement/Swarm/NativeClaimsUnlockCallback.lean`.
contract NativeClaimsUnlockCallbackFormalTest is FormalBase {
    NativeClaims claims;
    NCUClaimMinter minter;
    uint256 constant ADDR_MASK = (1 << 160) - 1;
    Currency constant NATIVE = Currency.wrap(address(0));

    function setUp() public override {
        super.setUp();
        claims = new NativeClaims(manager);
        minter = new NCUClaimMinter(manager);
    }

    /* ---------------- helpers ---------------- */

    function _give(address to, uint256 amount) internal {
        if (amount == 0) return;
        vm.deal(address(minter), amount);
        minter.mint(to, amount);
    }

    struct DataIn {
        uint8 flags; // bit0/bit1: keep word0/word1 unmasked; bit2: truncate to cut % 96 bytes
        bytes32 w0;
        bytes32 w1;
        bytes32 w2;
        bytes extra;
        uint256 cut;
    }

    function _data(DataIn memory din) internal pure returns (bytes memory d) {
        bytes32 w0 = din.flags & 1 == 0 ? bytes32(uint256(din.w0) & ADDR_MASK) : din.w0;
        bytes32 w1 = din.flags & 2 == 0 ? bytes32(uint256(din.w1) & ADDR_MASK) : din.w1;
        d = abi.encodePacked(w0, w1, din.w2, din.extra);
        if (din.flags & 4 != 0) {
            uint256 n = din.cut % 96;
            assembly {
                mstore(d, n)
            }
        }
    }

    function _word(bytes memory d, uint256 pos) internal pure returns (uint256 w) {
        for (uint256 i; i < 32; i++) {
            w <<= 8;
            if (pos + i < d.length) w |= uint8(d[pos + i]);
        }
    }

    /// @dev The Lean `decodes data`: three words, the first two addresses.
    function _decodes(bytes memory d) internal pure returns (bool) {
        return d.length >= 96 && _word(d, 0) < (1 << 160) && _word(d, 32) < (1 << 160);
    }

    function _call(address sender, bytes memory d) internal returns (bool ok, bytes memory ret) {
        vm.prank(sender);
        (ok, ret) = address(claims).call(abi.encodeCall(NativeClaims.unlockCallback, (d)));
    }

    function _viaUnlock(bytes memory d) internal returns (bool ok, bytes memory ret) {
        vm.prank(address(claims));
        (ok, ret) = address(manager).call(abi.encodeCall(IPoolManager.unlock, (d)));
    }

    /// @dev A code-less recipient so that `take` of ETH succeeds.
    function _eoa(uint256 seed) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("ncu-rcpt", seed)))));
    }

    /// @dev Real `burn(owner, 0, amount)` (msg.sender = NativeClaims) reverts iff amount > int128 max, or the
    ///      allowance (not an operator, not the owner itself, not infinite) is short, or the balance is short.
    function _burnReverts(address o, uint256 amount) internal view returns (bool) {
        if (amount > uint256(uint128(type(int128).max))) return true;
        if (o != address(claims) && !manager.isOperator(o, address(claims))) {
            uint256 a = manager.allowance(o, address(claims), 0);
            if (a != type(uint256).max && a < amount) return true;
        }
        return manager.balanceOf(o, 0) < amount;
    }

    /* ---------------- theorems ---------------- */

    /// @notice formal/Refinement/Swarm/NativeClaimsUnlockCallback.lean:46 — unlockCallback = OnlyPoolManager if sender !=
    ///         poolManager, else abi.decode revert unless data decodes, else burn(owner,0,amount) then take(native,recipient,amount).
    function testFuzz_unlockCallback_run(address sender, bool senderIsManager, DataIn memory din, uint96 claim) public {
        _give(alice, claim);
        vm.prank(alice);
        manager.approve(address(claims), 0, type(uint256).max);
        if (senderIsManager) sender = address(manager);
        bytes memory d = _data(din);

        (bool ok, bytes memory ret) = _call(sender, d);
        assertFalse(ok);
        if (sender != address(manager)) {
            assertEq(ret, abi.encodeWithSelector(NativeClaims.OnlyPoolManager.selector));
        } else if (!_decodes(d)) {
            assertEq(ret.length, 0, "abi.decode revert");
        } else {
            // `calls`: burn first; outside an unlock it reverts ManagerLocked and that propagates
            assertEq(ret, abi.encodeWithSelector(IPoolManager.ManagerLocked.selector));
        }
    }

    /// @notice formal/Refinement/Swarm/NativeClaimsUnlockCallback.lean:46 — (unlocked) the same characterization through a
    ///         real unlock: well-formed data runs burn(owner,0,amount) then take(native,recipient,amount) and returns "".
    function testFuzz_unlockCallback_run_unlocked(DataIn memory din, uint96 claim, bool ownerIsAlice, uint256 rSeed)
        public
    {
        _give(alice, claim);
        vm.prank(alice);
        manager.approve(address(claims), 0, type(uint256).max);
        bytes memory d = _data(din);
        // Point the words at alice / a code-less recipient / a reachable amount when asked, so success is exercised.
        if (ownerIsAlice && d.length >= 96 && _word(d, 0) < (1 << 160)) {
            address recipient = _eoa(rSeed);
            uint256 amount = bound(_word(d, 64), 0, uint256(claim) + 1);
            bytes memory tail = new bytes(d.length - 96);
            for (uint256 i; i < tail.length; i++) {
                tail[i] = d[96 + i];
            }
            d = abi.encodePacked(abi.encode(alice, recipient, amount), tail);
        }
        address o = address(uint160(_word(d, 0)));
        address r = address(uint160(_word(d, 32)));
        uint256 amt = _word(d, 64);
        bool burnRev = _decodes(d) && _burnReverts(o, amt);
        uint256 rBefore = r.balance;
        uint256 oBefore = manager.balanceOf(o, 0);

        (bool ok, bytes memory ret) = _viaUnlock(d);
        if (!_decodes(d)) {
            assertFalse(ok);
            assertEq(ret.length, 0);
        } else if (burnRev) {
            assertFalse(ok);
        } else if (r.code.length == 0 && r != address(manager) && uint160(r) > 0xffff) {
            // take of ETH to a code-less, non-precompile recipient cannot revert
            assertTrue(ok);
            assertEq(abi.decode(ret, (bytes)), "");
            assertEq(manager.balanceOf(o, 0), oBefore - amt);
            assertEq(r.balance, rBefore + amt);
        }
    }

    /// @notice formal/Refinement/Swarm/NativeClaimsUnlockCallback.lean:70 — any sender other than poolManager reverts OnlyPoolManager.
    function testFuzz_unlockCallback_onlyPoolManager(address sender, bytes memory d, uint96 claim) public {
        vm.assume(sender != address(manager));
        _give(alice, claim);
        vm.prank(sender);
        vm.expectRevert(NativeClaims.OnlyPoolManager.selector);
        claims.unlockCallback(d);
    }

    /// @notice formal/Refinement/Swarm/NativeClaimsUnlockCallback.lean:76 — sender == poolManager and malformed data reverts (abi.decode).
    function testFuzz_unlockCallback_badData(DataIn memory din) public {
        bytes memory d = _data(din);
        vm.assume(!_decodes(d));
        (bool ok, bytes memory ret) = _call(address(manager), d);
        assertFalse(ok);
        assertEq(ret.length, 0);
        (ok, ret) = _viaUnlock(d);
        assertFalse(ok);
        assertEq(ret.length, 0);
    }

    /// @notice formal/Refinement/Swarm/NativeClaimsUnlockCallback.lean:85 — success implies sender == poolManager, data decodes,
    ///         ret == "", burn(owner,0,amount) then take(native,recipient,amount) with the same amount, final world = take's.
    function testFuzz_unlockCallback_ok(uint96 claim, uint256 amount, uint256 rSeed, bytes memory extra) public {
        _give(alice, claim);
        _give(bob, 1 ether); // another owner's claim, must be untouched
        vm.prank(alice);
        manager.approve(address(claims), 0, type(uint256).max);
        amount = bound(amount, 0, uint256(claim) + 1);
        address recipient = _eoa(rSeed);
        bytes memory d = abi.encodePacked(abi.encode(alice, recipient, amount), extra);

        bool expectOk = amount <= claim;
        if (expectOk) {
            vm.expectCall(address(manager), abi.encodeCall(IPoolManager.burn, (alice, 0, amount)), 1);
            vm.expectCall(address(manager), abi.encodeCall(IPoolManager.take, (NATIVE, recipient, amount)), 1);
        }
        (bool ok, bytes memory ret) = _viaUnlock(d);
        assertEq(ok, expectOk);
        if (ok) {
            assertTrue(_decodes(d));
            assertEq(abi.decode(ret, (bytes)), "");
            assertEq(manager.balanceOf(alice, 0), uint256(claim) - amount);
            assertEq(recipient.balance, amount);
            assertEq(manager.balanceOf(bob, 0), 1 ether);
        }
        // and never directly from a non-manager sender
        (ok,) = _call(alice, d);
        assertFalse(ok);
    }

    /// @notice formal/Refinement/Swarm/NativeClaimsUnlockCallback.lean:112 — if burn reverts, the callback reverts with the
    ///         same error (no take).
    function testFuzz_unlockCallback_burn_fails(uint96 claim, uint256 amount, uint256 allow, uint256 rSeed) public {
        _give(alice, claim);
        address recipient = _eoa(rSeed);
        // (a) locked manager: burn reverts ManagerLocked
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManager.take.selector), 0);
        (bool ok, bytes memory ret) = _call(address(manager), abi.encode(alice, recipient, amount));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(IPoolManager.ManagerLocked.selector));

        // (b) unlocked, but burn reverts (amount above balance or allowance, or above int128)
        if (amount % 2 == 0) amount = bound(amount, 0, uint256(claim) + 1);
        if (allow % 2 == 0) allow = bound(allow, 0, uint256(claim) + 1);
        vm.prank(alice);
        manager.approve(address(claims), 0, allow);
        vm.assume(_burnReverts(alice, amount));
        bytes memory expected;
        if (amount > uint256(uint128(type(int128).max))) {
            expected = abi.encodeWithSelector(SafeCast.SafeCastOverflow.selector);
        } else {
            expected = stdError.arithmeticError; // allowance or balance underflow
        }
        (ok, ret) = _viaUnlock(abi.encode(alice, recipient, amount));
        assertFalse(ok);
        assertEq(ret, expected);
        assertEq(recipient.balance, 0);
        assertEq(manager.balanceOf(alice, 0), claim);
    }

    /// @notice formal/Refinement/Swarm/NativeClaimsUnlockCallback.lean:119 — reverts iff sender != poolManager, data does
    ///         not decode, burn reverts, or (burn ok and) take reverts.
    function testFuzz_unlockCallback_reverts_iff(
        address sender,
        bool senderIsManager,
        uint96 claim,
        uint256 allow,
        uint8 ownerSel,
        uint256 amount,
        uint256 rSeed,
        DataIn memory din
    ) public {
        _give(alice, claim);
        vm.prank(alice);
        manager.approve(address(claims), 0, allow);
        if (senderIsManager) sender = address(manager);
        address recipient = _eoa(rSeed);
        address o = ownerSel % 3 == 0 ? alice : ownerSel % 3 == 1 ? bob : address(claims);
        if (amount % 2 == 0) amount = bound(amount, 0, uint256(claim) + 1);
        bytes memory d = din.flags & 8 != 0 ? _data(din) : abi.encode(o, recipient, amount);
        bool decodes = _decodes(d);

        // direct call (manager locked: burn always reverts ManagerLocked)
        (bool ok,) = _call(sender, d);
        bool rhsDirect = sender != address(manager) || !decodes || true; /* burn: ManagerLocked */
        assertEq(!ok, rhsDirect);

        // through a real unlock (sender = poolManager)
        bool burnRev = decodes && _burnReverts(address(uint160(_word(d, 0))), _word(d, 64));
        address r = address(uint160(_word(d, 32)));
        bool takeMayRevert =
            decodes && !burnRev && !(r.code.length == 0 && r != address(manager) && uint160(r) > 0xffff);
        (ok,) = _viaUnlock(d);
        if (!takeMayRevert) assertEq(!ok, !decodes || burnRev);
    }

    /// @notice formal/Refinement/Swarm/NativeClaimsUnlockCallback.lean:154 — on success the owner and recipient words are
    ///         addresses (< 2^160).
    function testFuzz_unlockCallback_ok_args(bytes32 hi0, bytes32 hi1, uint96 claim, uint256 amount, uint256 rSeed)
        public
    {
        _give(alice, claim);
        vm.prank(alice);
        manager.approve(address(claims), 0, type(uint256).max);
        amount = bound(amount, 0, claim);
        address recipient = _eoa(rSeed);
        // Dirty the high 96 bits of the owner / recipient words with fuzzed bits (often zero by the masks below).
        uint256 w0 = uint256(uint160(alice)) | (uint256(hi0) % 2 == 1 ? (uint256(hi0) >> 160) << 160 : 0);
        uint256 w1 = uint256(uint160(recipient)) | (uint256(hi1) % 2 == 1 ? (uint256(hi1) >> 160) << 160 : 0);
        bytes memory d = abi.encode(w0, w1, amount);
        (bool ok,) = _viaUnlock(d);
        if (ok) {
            assertLt(_word(d, 0), 1 << 160);
            assertLt(_word(d, 32), 1 << 160);
        }
        assertEq(ok, w0 < (1 << 160) && w1 < (1 << 160));
    }
}
