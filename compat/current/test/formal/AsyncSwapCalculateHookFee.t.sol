// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalSlotsB} from "./FormalSlotsB.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapCalculateHookFee.lean`.
contract AsyncSwapCalculateHookFeeFormalTest is FormalSlotsB {
    function _call(address sender, uint256 x) internal returns (bool ok, bytes memory ret) {
        vm.prank(sender);
        (ok, ret) = address(hook).call(abi.encodeCall(AsyncSwap.calculateHookFee, (x)));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapCalculateHookFee.lean:20 — for any argument, succeeds with 0, world untouched.
    function testFuzz_calculateHookFee_run(address sender, uint256 x) public {
        vm.record();
        (bool ok, bytes memory ret) = _call(sender, x);
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint256)), 0);
        _assertNoHookWrites();
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapCalculateHookFee.lean:24 — never reverts.
    function testFuzz_calculateHookFee_never_reverts(address sender, uint256 x) public {
        (bool ok,) = _call(sender, x);
        assertTrue(ok);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapCalculateHookFee.lean:30 — ok (fee, w') iff fee = 0 ∧ w' = w.
    function testFuzz_calculateHookFee_ok_iff(uint256 x) public {
        vm.record();
        uint256 fee = hook.calculateHookFee(x);
        assertEq(fee, 0);
        _assertNoHookWrites();
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapCalculateHookFee.lean:38 — the result depends on neither argument nor env.
    function testFuzz_calculateHookFee_const(uint256 x, uint256 y, address s1, address s2, uint64 chainId) public {
        (, bytes memory r1) = _call(s1, x);
        vm.chainId(chainId);
        vm.warp(uint256(keccak256(abi.encode(y))) % 2 ** 40);
        (, bytes memory r2) = _call(s2, y);
        assertEq(r1, r2);
    }
}
