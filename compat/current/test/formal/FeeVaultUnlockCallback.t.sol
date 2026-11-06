// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalBase} from "./FormalBase.sol";
import {FeeVault} from "@async-swap/FeeVault.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {Currency, IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC6909Claims} from "v4-core/interfaces/external/IERC6909Claims.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";

/// @dev Mints ERC-6909 claims of an ERC-20 to any address inside a real PoolManager unlock
///      (in two halves, so a total above int128 is reachable).
contract FVUClaimMinter {
    IPoolManager immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function mint(address to, address token, uint256 amount) external {
        pm.unlock(abi.encode(to, token, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address to, address token, uint256 amount) = abi.decode(data, (address, address, uint256));
        Currency c = Currency.wrap(token);
        for (uint256 i; i < 2; i++) {
            uint256 part = i == 0 ? amount / 2 : amount - amount / 2;
            if (part == 0) continue;
            pm.sync(c);
            MockERC20(token).transfer(address(pm), part);
            pm.settle();
            pm.mint(to, c.toId(), part);
        }
        return "";
    }
}

/// @notice Bytecode checks of `formal/Refinement/Swarm/FeeVaultUnlockCallback.lean`.
contract FeeVaultUnlockCallbackFormalTest is FormalBase {
    FeeVault vault;
    FVUClaimMinter minter;

    uint256 constant ADDR_MASK = (1 << 160) - 1;

    function setUp() public override {
        super.setUp();
        vault = hook.feeVault();
        minter = new FVUClaimMinter(manager);
    }

    /* ---------------- helpers ---------------- */

    function _give(address to, MockERC20 t, uint256 amount) internal {
        if (amount == 0) return;
        t.mint(address(minter), amount);
        minter.mint(to, address(t), amount);
    }

    /// @dev Build `data` from fuzz words. flags bit0/bit1: keep word0/word1 as fuzzed (else masked to an
    ///      address); bit2: truncate to `cut % 64` bytes; bit3: word0 := currency1.
    struct DataIn {
        uint8 flags;
        bytes32 w0;
        bytes32 w1;
        bytes extra;
        uint256 cut;
    }

    function _data(DataIn memory din) internal view returns (bytes memory d) {
        (uint8 flags, bytes32 w0, bytes32 w1, bytes memory extra, uint256 cut) =
            (din.flags, din.w0, din.w1, din.extra, din.cut);
        if (flags & 8 != 0) w0 = bytes32(uint256(uint160(Currency.unwrap(currency1))));
        else if (flags & 1 == 0) w0 = bytes32(uint256(w0) & ADDR_MASK);
        if (flags & 2 == 0) w1 = bytes32(uint256(w1) & ADDR_MASK);
        d = abi.encodePacked(w0, w1, extra);
        if (flags & 4 != 0) {
            uint256 n = cut % 64;
            assembly {
                mstore(d, n)
            }
        }
    }

    /// @dev The Lean `word data pos` (in-bounds part only, zero-padded) and `decodes data`.
    function _word(bytes memory d, uint256 pos) internal pure returns (uint256 w) {
        for (uint256 i; i < 32; i++) {
            w <<= 8;
            if (pos + i < d.length) w |= uint8(d[pos + i]);
        }
    }

    function _decodes(bytes memory d) internal pure returns (bool) {
        return d.length >= 64 && _word(d, 0) < (1 << 160) && _word(d, 32) < (1 << 160);
    }

    function _call(address sender, bytes memory d) internal returns (bool ok, bytes memory ret) {
        vm.prank(sender);
        (ok, ret) = address(vault).call(abi.encodeCall(FeeVault.unlockCallback, (d)));
    }

    /// @dev Drive the callback through the real PoolManager unlock (sender = poolManager, unlocked).
    function _viaUnlock(bytes memory d) internal returns (bool ok, bytes memory ret) {
        vm.prank(address(vault));
        (ok, ret) = address(manager).call(abi.encodeCall(IPoolManager.unlock, (d)));
    }

    function _claim(uint256 currencyWord) internal view returns (uint256) {
        return manager.balanceOf(address(vault), currencyWord);
    }

    /* ---------------- theorems ---------------- */

    /// @notice formal/Refinement/Swarm/FeeVaultUnlockCallback.lean:59 — unlockCallback = Unauthorized if sender != poolManager,
    ///         else abi.decode revert unless data decodes, else body (balance read; "" with world unchanged if 0, else burn+take).
    function testFuzz_unlockCallback_run(address sender, bool senderIsManager, DataIn memory din, uint96 claim) public {
        _give(address(vault), token1, claim);
        if (senderIsManager) sender = address(manager);
        bytes memory d = _data(din);
        uint256 before = _decodes(d) ? _claim(_word(d, 0)) : 0;

        (bool ok, bytes memory ret) = _call(sender, d);
        if (sender != address(manager)) {
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(FeeVault.Unauthorized.selector));
        } else if (!_decodes(d)) {
            assertFalse(ok);
            assertEq(ret.length, 0, "abi.decode revert");
        } else if (before == 0) {
            assertTrue(ok);
            assertEq(abi.decode(ret, (bytes)), "");
            assertEq(_claim(_word(d, 0)), 0);
        } else {
            // body = burnTake; burn outside an unlock reverts and that revert propagates
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(IPoolManager.ManagerLocked.selector));
        }

        // The same `data` through a real unlock (sender = poolManager, manager unlocked).
        address recipient = address(uint160(_word(d, 32)));
        uint256 recBefore =
            _decodes(d) && _word(d, 0) == uint160(Currency.unwrap(currency1)) ? token1.balanceOf(recipient) : 0;
        (ok, ret) = _viaUnlock(d);
        if (!_decodes(d)) {
            assertFalse(ok);
            assertEq(ret.length, 0, "abi.decode revert");
        } else {
            assertTrue(ok);
            assertEq(abi.decode(ret, (bytes)), "");
            assertEq(_claim(_word(d, 0)), 0, "whole own balance burned");
            if (_word(d, 0) == uint160(Currency.unwrap(currency1)) && recipient != address(manager)) {
                assertEq(token1.balanceOf(recipient), recBefore + before, "recipient took the burned amount");
            }
        }
    }

    /// @notice formal/Refinement/Swarm/FeeVaultUnlockCallback.lean:86 — any sender other than poolManager reverts Unauthorized.
    function testFuzz_unlockCallback_unauthorized(address sender, bytes memory d, uint96 claim) public {
        vm.assume(sender != address(manager));
        _give(address(vault), token1, claim);
        vm.prank(sender);
        vm.expectRevert(FeeVault.Unauthorized.selector);
        vault.unlockCallback(d);
    }

    /// @notice formal/Refinement/Swarm/FeeVaultUnlockCallback.lean:92 — sender == poolManager and malformed data reverts (abi.decode).
    function testFuzz_unlockCallback_badData(DataIn memory din) public {
        bytes memory d = _data(din);
        vm.assume(!_decodes(d));
        (bool ok, bytes memory ret) = _call(address(manager), d);
        assertFalse(ok);
        assertEq(ret.length, 0);
        // also inside a real unlock
        (ok, ret) = _viaUnlock(d);
        assertFalse(ok);
        assertEq(ret.length, 0);
    }

    /// @notice formal/Refinement/Swarm/FeeVaultUnlockCallback.lean:98 — if the balanceOf view reverts, the callback reverts with the same reason.
    function testFuzz_unlockCallback_view_reverts(address currency, address recipient, bytes memory reason) public {
        bytes memory d = abi.encode(currency, recipient);
        vm.mockCallRevert(
            address(manager),
            abi.encodeCall(IERC6909Claims.balanceOf, (address(vault), uint256(uint160(currency)))),
            reason
        );
        (bool ok, bytes memory ret) = _call(address(manager), d);
        assertFalse(ok);
        assertEq(ret, reason);
    }

    /// @notice formal/Refinement/Swarm/FeeVaultUnlockCallback.lean:105 — zero vault balance: returns "" with no external call
    ///         beyond the view and the world unchanged.
    function testFuzz_unlockCallback_zero(address currency, address recipient, bytes memory extra, uint96 aliceClaim)
        public
    {
        // Another account's claim of the same currency must not matter.
        _give(alice, token1, aliceClaim);
        vm.assume(manager.balanceOf(address(vault), uint256(uint160(currency))) == 0);
        bytes memory d = abi.encodePacked(abi.encode(currency, recipient), extra);
        uint256 aliceBefore = manager.balanceOf(alice, uint256(uint160(currency)));

        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManager.burn.selector), 0);
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManager.take.selector), 0);
        vm.prank(address(manager));
        bytes memory ret = vault.unlockCallback(d);
        assertEq(ret, "");
        assertEq(manager.balanceOf(alice, uint256(uint160(currency))), aliceBefore);
        assertEq(manager.balanceOf(address(vault), uint256(uint160(currency))), 0);
    }

    /// @notice formal/Refinement/Swarm/FeeVaultUnlockCallback.lean:113 — nonzero vault balance: exactly burn(self, currency, amount)
    ///         then take(currency, recipient, amount) with the same amount.
    function testFuzz_unlockCallback_nonzero(uint96 amount, address recipient, bytes memory extra) public {
        amount = uint96(bound(amount, 1, type(uint96).max)); // theorem hypothesis amount != 0
        vm.assume(recipient != address(manager));
        _give(address(vault), token1, amount);
        uint256 id = currency1.toId();
        bytes memory d = abi.encodePacked(abi.encode(currency1, recipient), extra);
        uint256 recBefore = token1.balanceOf(recipient);

        vm.expectCall(address(manager), abi.encodeCall(IPoolManager.burn, (address(vault), id, amount)), 1);
        vm.expectCall(address(manager), abi.encodeCall(IPoolManager.take, (currency1, recipient, amount)), 1);
        (bool ok, bytes memory ret) = _viaUnlock(d);
        assertTrue(ok);
        assertEq(abi.decode(ret, (bytes)), "");
        assertEq(manager.balanceOf(address(vault), id), 0);
        assertEq(token1.balanceOf(recipient), recBefore + amount);
    }

    /// @notice formal/Refinement/Swarm/FeeVaultUnlockCallback.lean:125 — success implies sender == poolManager, data decodes,
    ///         ret == "", and either (balance 0, world unchanged) or (burn then take of that balance).
    function testFuzz_unlockCallback_ok(address sender, uint8 mode, DataIn memory din, uint96 claim) public {
        _give(address(vault), token1, claim);
        bytes memory d = _data(din);
        bool decodes = _decodes(d);
        uint256 cw = decodes ? _word(d, 0) : 0;
        address recipient = address(uint160(_word(d, 32)));
        bool isTok = decodes && cw == uint160(Currency.unwrap(currency1));
        uint256 before = decodes ? _claim(cw) : 0;
        uint256 recBefore = isTok ? token1.balanceOf(recipient) : 0;

        bool ok;
        bytes memory ret;
        if (mode % 3 == 0) {
            (ok, ret) = _call(sender, d); // arbitrary sender, manager locked
        } else if (mode % 3 == 1) {
            sender = address(manager);
            (ok, ret) = _call(sender, d); // poolManager, locked
        } else {
            sender = address(manager);
            (ok, ret) = _viaUnlock(d); // poolManager, unlocked (unlock returns the callback's bytes)
        }
        if (!ok) return;
        ret = abi.decode(ret, (bytes));
        assertEq(sender, address(manager), "sender == poolManager");
        assertTrue(decodes, "decodes");
        assertEq(ret.length, 0, "ret == []");
        if (before == 0) {
            assertEq(_claim(cw), 0, "world unchanged");
            if (isTok) assertEq(token1.balanceOf(recipient), recBefore);
        } else {
            assertEq(_claim(cw), 0, "burned own balance");
            if (isTok && recipient != address(manager)) assertEq(token1.balanceOf(recipient), recBefore + before);
        }
    }

    /// @notice formal/Refinement/Swarm/FeeVaultUnlockCallback.lean:165 — whenever the callback succeeds after burning the
    ///         vault's own balance `amount`, the take is of exactly that amount, and no other account's claim is touched.
    function testFuzz_unlockCallback_take_eq_own_balance(uint96 amount, uint96 aliceClaim, address recipient) public {
        amount = uint96(bound(amount, 1, type(uint96).max)); // hypothesis amount != 0
        vm.assume(recipient != address(manager));
        _give(address(vault), token1, amount);
        _give(alice, token1, aliceClaim);
        uint256 id = currency1.toId();
        uint256 recBefore = token1.balanceOf(recipient);

        vm.expectCall(address(manager), abi.encodeCall(IPoolManager.burn, (address(vault), id, amount)), 1);
        vm.expectCall(address(manager), abi.encodeCall(IPoolManager.take, (currency1, recipient, amount)), 1);
        (bool ok,) = _viaUnlock(abi.encode(currency1, recipient));
        assertTrue(ok);
        assertEq(token1.balanceOf(recipient), recBefore + amount);
        assertEq(manager.balanceOf(alice, id), aliceClaim, "another owner's claim untouched");
    }

    /// @notice formal/Refinement/Swarm/FeeVaultUnlockCallback.lean:182 — nonzero balance and burn reverts => the callback
    ///         reverts with the same error (nothing taken).
    function testFuzz_unlockCallback_burn_fails(uint96 amount, address recipient) public {
        amount = uint96(bound(amount, 1, type(uint96).max));
        _give(address(vault), token1, amount);
        // (a) manager locked: burn reverts ManagerLocked
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManager.take.selector), 0);
        (bool ok, bytes memory ret) = _call(address(manager), abi.encode(currency1, recipient));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(IPoolManager.ManagerLocked.selector));
    }

    /// @notice formal/Refinement/Swarm/FeeVaultUnlockCallback.lean:182 — (b) inside a real unlock, a balance above int128 makes
    ///         burn revert SafeCastOverflow and the callback reverts with that error.
    function test_unlockCallback_burn_fails_overflow() public {
        MockERC20 junk = new MockERC20("Junk", "JNK", 18);
        uint256 huge = uint256(uint128(type(int128).max)) + 1;
        _give(address(vault), junk, huge);
        assertEq(manager.balanceOf(address(vault), uint256(uint160(address(junk)))), huge);
        (bool ok, bytes memory ret) = _viaUnlock(abi.encode(address(junk), alice));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(SafeCast.SafeCastOverflow.selector));
        assertEq(manager.balanceOf(address(vault), uint256(uint160(address(junk)))), huge);
    }

    /// @notice formal/Refinement/Swarm/FeeVaultUnlockCallback.lean:191 — reverts iff sender != poolManager, data does not decode,
    ///         or the body (balance read / burn / take) reverts.
    function testFuzz_unlockCallback_reverts_iff(address sender, bool senderIsManager, DataIn memory din, uint96 claim)
        public
    {
        _give(address(vault), token1, claim);
        if (senderIsManager) sender = address(manager);
        bytes memory d = _data(din);
        bool decodes = _decodes(d);
        uint256 before = decodes ? _claim(_word(d, 0)) : 0;

        // Direct call (manager locked): the body reverts iff the balance is nonzero (burn: ManagerLocked).
        (bool ok,) = _call(sender, d);
        assertEq(!ok, sender != address(manager) || !decodes || before != 0, "direct");

        // Through a real unlock: burn/take of an ERC-20 claim below int128 never reverts.
        (ok,) = _viaUnlock(d);
        assertEq(!ok, !decodes, "via unlock");
    }
}
