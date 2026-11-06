// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalSlotsB} from "./FormalSlotsB.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapSweep.lean`.
contract AsyncSwapSweepFormalTest is FormalSlotsB {
    function _setOwner(address o) internal {
        vm.store(address(hook), bytes32(OWNER_SLOT), bytes32(uint256(uint160(o))));
    }

    /// @dev Pick the swept currency: token0, token1 or native ETH; fund the hook with `amount`.
    function _fund(uint8 which, uint256 amount) internal returns (Currency c) {
        which %= 3;
        if (which == 0) {
            c = currency0;
            token0.mint(address(hook), amount);
        } else if (which == 1) {
            c = currency1;
            token1.mint(address(hook), amount);
        } else {
            c = CurrencyLibrary.ADDRESS_ZERO;
            vm.deal(address(hook), amount);
        }
    }

    function _call(address sender, Currency c, address to) internal returns (bool ok, bytes memory ret) {
        vm.prank(sender);
        (ok, ret) = address(hook).call(abi.encodeCall(AsyncSwap.sweep, (c, to)));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSweep.lean:36 — non-owner reverts NotOwner.
    function testFuzz_sweep_notOwner(address o, address sender, address currency, address to) public {
        vm.assume(sender != o);
        _setOwner(o);
        vm.prank(sender);
        vm.expectRevert(AsyncSwap.NotOwner.selector);
        hook.sweep(Currency.wrap(currency), to);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSweep.lean:43 — owner with `to = 0` reverts ZeroAddress (any currency).
    function testFuzz_sweep_zeroTo(address o, address currency) public {
        _setOwner(o);
        vm.prank(o);
        vm.expectRevert(AsyncSwap.ZeroAddress.selector);
        hook.sweep(Currency.wrap(currency), address(0));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSweep.lean:51 — reverts unless sender = owner ∧ to ≠ 0.
    function testFuzz_sweep_reverts_unless(
        address o,
        address sender,
        bool isOwner,
        uint8 which,
        uint128 amount,
        address to
    ) public {
        if (isOwner) sender = o;
        _setOwner(o);
        Currency c = _fund(which, amount);
        if (!(sender == o && to != address(0))) {
            (bool ok,) = _call(sender, c, to);
            assertFalse(ok);
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSweep.lean:62 — owner, to ≠ 0: the call is "read own balance, transfer
    ///         all of it to `to`", nothing else.
    function testFuzz_sweep_run(uint8 which, uint128 amount, uint256 toSeed) public {
        address to = makeAddr(string(abi.encode(toSeed))); // plain EOA, accepts ETH
        Currency c = _fund(which, amount);
        uint256 hookBefore = c.balanceOf(address(hook));
        uint256 toBefore = c.balanceOf(to);
        vm.record();
        hook.sweep(c, to);
        _assertNoHookWrites();
        assertEq(c.balanceOf(address(hook)), 0, "whole balance left the hook");
        assertEq(c.balanceOf(to), toBefore + hookBefore, "and went to `to`");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSweep.lean:81 — on success: sender = owner, to ≠ 0, and the final state
    ///         is the transfer of the full starting balance.
    function testFuzz_sweep_ok(address o, address sender, bool isOwner, uint8 which, uint128 amount, address to)
        public
    {
        if (isOwner) sender = o;
        _setOwner(o);
        Currency c = _fund(which, amount);
        uint256 hookBefore = c.balanceOf(address(hook));
        uint256 toBefore = c.balanceOf(to);
        (bool ok,) = _call(sender, c, to);
        if (ok) {
            assertEq(sender, o);
            assertTrue(to != address(0));
            if (to != address(hook)) {
                assertEq(c.balanceOf(address(hook)), 0);
                assertEq(c.balanceOf(to), toBefore + hookBefore);
            } else {
                assertEq(c.balanceOf(address(hook)), hookBefore);
            }
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSweep.lean:104 — the real transfers (ERC20/native) leave the hook's
    ///         storage alone, so a successful sweep writes no hook storage.
    function testFuzz_sweep_storage_unchanged(uint8 which, uint128 amount, address to) public {
        Currency c = _fund(which, amount);
        vm.record();
        (bool ok,) = _call(address(this), c, to);
        if (ok) _assertNoHookWrites();
    }
}
