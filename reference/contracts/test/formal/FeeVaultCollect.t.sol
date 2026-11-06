// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalBase} from "./FormalBase.sol";
import {FeeVault} from "@async-swap/FeeVault.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {Currency, IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/// @dev Mints ERC-6909 claims (native or ERC-20) to any address inside a real PoolManager unlock.
contract FVCClaimMinter {
    IPoolManager immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function mint(address to, address token, uint256 amount) external payable {
        pm.unlock(abi.encode(to, token, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address to, address token, uint256 amount) = abi.decode(data, (address, address, uint256));
        Currency c = Currency.wrap(token);
        if (token == address(0)) {
            pm.settle{value: amount}();
        } else {
            pm.sync(c);
            MockERC20(token).transfer(address(pm), amount);
            pm.settle();
        }
        pm.mint(to, c.toId(), amount);
        return "";
    }
}

/// @notice Bytecode checks of `formal/Refinement/Swarm/FeeVaultCollect.lean`.
contract FeeVaultCollectFormalTest is FormalBase {
    string constant LEAN = "formal/Refinement/Swarm/FeeVaultCollect.lean";

    FeeVault vault;
    FVCClaimMinter minter;
    Currency constant NATIVE = Currency.wrap(address(0));

    function setUp() public override {
        super.setUp();
        vault = hook.feeVault();
        minter = new FVCClaimMinter(manager);
    }

    /* ---------------- helpers ---------------- */

    function _giveVault(uint256 tokAmt, uint256 ethAmt) internal {
        if (tokAmt != 0) {
            token1.mint(address(minter), tokAmt);
            minter.mint(address(vault), address(token1), tokAmt);
        }
        if (ethAmt != 0) {
            vm.deal(address(minter), ethAmt);
            minter.mint(address(vault), address(0), ethAmt);
        }
    }

    /// @dev Optionally hand ownership of the hook to `bob`, so `hook.owner()` is not the deployer.
    function _maybeMoveOwner(bool move) internal returns (address o) {
        if (move) {
            hook.transferOwnership(bob);
            vm.prank(bob);
            hook.acceptOwnership();
        }
        o = hook.owner();
    }

    function _pickCurrency(uint8 sel, address arbitrary) internal view returns (Currency) {
        sel %= 4;
        if (sel == 0) return currency1;
        if (sel == 1) return NATIVE;
        if (sel == 2) return currency0;
        return Currency.wrap(arbitrary);
    }

    function _known(Currency c) internal view returns (bool) {
        return c == NATIVE || c == currency0 || c == currency1;
    }

    function _bal(Currency c, address who) internal view returns (uint256) {
        if (!_known(c)) return 0;
        return c.balanceOf(who);
    }

    /// @dev Run `poolManager.unlock(abi.encode(currency, recipient))` as the vault from the current
    ///      world (the call `collect` makes) and report its outcome; the world is then restored.
    function _oracleUnlock(Currency c, address recipient)
        internal
        returns (bool ok, bytes memory ret, uint256 recBal, uint256 vaultClaim)
    {
        uint256 snap = vm.snapshotState();
        vm.prank(address(vault));
        (ok, ret) = address(manager).call(abi.encodeCall(IPoolManager.unlock, (abi.encode(c, recipient))));
        recBal = _bal(c, recipient);
        vaultClaim = manager.balanceOf(address(vault), c.toId());
        vm.revertToState(snap);
    }

    struct Oracle {
        bool ok;
        bytes ret;
        uint256 recBal;
        uint256 vaultClaim;
    }

    function _oracle(Currency c, address recipient) internal returns (Oracle memory r) {
        (r.ok, r.ret, r.recBal, r.vaultClaim) = _oracleUnlock(c, recipient);
    }

    function _collect(address sender, Currency c, address recipient) internal returns (bool ok, bytes memory ret) {
        vm.prank(sender);
        (ok, ret) = address(vault).call(abi.encodeCall(FeeVault.collect, (c, recipient)));
    }

    /* ---------------- theorems ---------------- */

    /// @notice formal/Refinement/Swarm/FeeVaultCollect.lean:31 — collect = Unauthorized if sender != owner,
    ///         else ZeroAddress if recipient == 0, else exactly the outcome/world of unlock(abi.encode(currency, recipient)).
    function testFuzz_collect_run(
        address sender,
        uint8 flags,
        address arbitrary,
        address recipient,
        uint96 tokAmt,
        uint96 ethAmt
    ) public {
        _giveVault(tokAmt, ethAmt);
        address o = _maybeMoveOwner(flags & 2 != 0);
        if (flags & 1 != 0) sender = o;
        Currency c = _pickCurrency(flags >> 2, arbitrary);

        Oracle memory r = _oracle(c, recipient);
        (bool ok, bytes memory ret) = _collect(sender, c, recipient);

        if (sender != o) {
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(FeeVault.Unauthorized.selector));
        } else if (recipient == address(0)) {
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(FeeVault.ZeroAddress.selector));
        } else {
            assertEq(ok, r.ok, "collect succeeds iff its unlock succeeds");
            if (!ok) {
                assertEq(ret, r.ret, "unlock's revert propagates");
            } else {
                assertEq(_bal(c, recipient), r.recBal, "final world = unlock's world (recipient)");
                assertEq(
                    manager.balanceOf(address(vault), c.toId()), r.vaultClaim, "final world = unlock's world (vault)"
                );
            }
        }
    }

    /// @notice formal/Refinement/Swarm/FeeVaultCollect.lean:58 — if the hook.owner() view reverts, collect reverts with the same reason.
    function testFuzz_collect_owner_view_reverts(
        address sender,
        uint8 sel,
        address arbitrary,
        address recipient,
        bytes memory reason
    ) public {
        Currency c = _pickCurrency(sel, arbitrary);
        vm.mockCallRevert(address(hook), abi.encodeWithSignature("owner()"), reason);
        (bool ok, bytes memory ret) = _collect(sender, c, recipient);
        assertFalse(ok);
        assertEq(ret, reason);
    }

    /// @notice formal/Refinement/Swarm/FeeVaultCollect.lean:64 — a caller other than hook.owner() reverts Unauthorized.
    function testFuzz_collect_unauthorized(
        address sender,
        bool moveOwner,
        uint8 sel,
        address arbitrary,
        address recipient
    ) public {
        address o = _maybeMoveOwner(moveOwner);
        vm.assume(sender != o);
        Currency c = _pickCurrency(sel, arbitrary);
        vm.prank(sender);
        vm.expectRevert(FeeVault.Unauthorized.selector);
        vault.collect(c, recipient);
    }

    /// @notice formal/Refinement/Swarm/FeeVaultCollect.lean:70 — the owner with recipient == 0 reverts ZeroAddress.
    function testFuzz_collect_zero_recipient(bool moveOwner, uint8 sel, address arbitrary, uint96 tokAmt) public {
        _giveVault(tokAmt, 0);
        address o = _maybeMoveOwner(moveOwner);
        Currency c = _pickCurrency(sel, arbitrary);
        vm.prank(o);
        vm.expectRevert(FeeVault.ZeroAddress.selector);
        vault.collect(c, address(0));
    }

    /// @notice formal/Refinement/Swarm/FeeVaultCollect.lean:78 — success implies sender == owner, recipient != 0, and
    ///         unlock(abi.encode(currency, recipient)) was called and succeeded with the final world being its world.
    function testFuzz_collect_ok(bool moveOwner, bool native, uint96 amt, uint256 recipientSeed) public {
        uint256 tokAmt = native ? 0 : amt;
        uint256 ethAmt = native ? amt : 0;
        _giveVault(tokAmt, ethAmt);
        address o = _maybeMoveOwner(moveOwner);
        Currency c = native ? NATIVE : currency1;
        // A code-less recipient, so the take can succeed and the success case is exercised.
        address recipient = address(uint160(uint256(keccak256(abi.encode("rcpt", recipientSeed)))));
        vm.assume(recipient.code.length == 0 && recipient != address(0));

        uint256 before = _bal(c, recipient);
        vm.expectCall(address(manager), abi.encodeCall(IPoolManager.unlock, (abi.encode(c, recipient))), 1);
        (bool ok,) = _collect(o, c, recipient);
        assertTrue(ok);
        // conclusions
        assertEq(o, hook.owner());
        assertTrue(recipient != address(0));
        assertEq(_bal(c, recipient), before + amt);
        assertEq(manager.balanceOf(address(vault), c.toId()), 0);
    }

    /// @notice formal/Refinement/Swarm/FeeVaultCollect.lean:101 — any successful collect was sent by hook.owner().
    function testFuzz_collect_only_owner(
        address sender,
        bool moveOwner,
        uint8 sel,
        address arbitrary,
        address recipient,
        uint96 tokAmt
    ) public {
        _giveVault(tokAmt, 0);
        address o = _maybeMoveOwner(moveOwner);
        Currency c = _pickCurrency(sel, arbitrary);
        (bool ok,) = _collect(sender, c, recipient);
        if (ok) assertEq(sender, o);
    }

    /// @notice formal/Refinement/Swarm/FeeVaultCollect.lean:108 — collect reverts iff the owner view reverts, the sender
    ///         is not the owner, recipient == 0, or unlock(abi.encode(currency, recipient)) reverts.
    function testFuzz_collect_reverts_iff(
        address sender,
        uint8 flags,
        address arbitrary,
        address recipient,
        uint96 tokAmt,
        uint96 ethAmt
    ) public {
        _giveVault(tokAmt, ethAmt);
        address o = _maybeMoveOwner(flags & 2 != 0);
        if (flags & 1 != 0) sender = o;
        Currency c = _pickCurrency(flags >> 2, arbitrary);
        (bool oOk,,,) = _oracleUnlock(c, recipient);
        bool rhs = sender != o || recipient == address(0) || !oOk; // the real owner() view never reverts
        (bool ok,) = _collect(sender, c, recipient);
        assertEq(!ok, rhs);
    }
}
