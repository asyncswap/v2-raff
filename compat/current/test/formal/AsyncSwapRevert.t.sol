// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalOzE, AddressHarness} from "./FormalOzE.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapRevert.lean` (OpenZeppelin
///         `Address._revert`, private, reached through `verifyCallResult(false, rd)` in `AddressHarness`).
contract AsyncSwapRevertFormalTest is FormalOzE {
    AddressHarness h;

    function setUp() public override {
        super.setUp();
        h = new AddressHarness();
    }

    function _call(bytes memory rd) internal view returns (bool ok, bytes memory ret) {
        (ok, ret) = address(h).staticcall(abi.encodeCall(AddressHarness.revert_, (rd)));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapRevert.lean:19 — always reverts: bubbles `rd` if non-empty, else
    ///         `FailedInnerCall`.
    function testFuzz_revert_run(bytes memory rd) public view {
        (bool ok, bytes memory ret) = _call(rd);
        assertFalse(ok);
        assertEq(ret, rd.length > 0 ? rd : abi.encodeWithSelector(Address.FailedInnerCall.selector));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapRevert.lean:26 — non-empty `rd` is bubbled up as it is.
    function testFuzz_revert_nonempty(bytes memory rd) public view {
        vm.assume(rd.length > 0);
        (bool ok, bytes memory ret) = _call(rd);
        assertFalse(ok);
        assertEq(ret, rd);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapRevert.lean:31 — empty `rd` reverts `FailedInnerCall`.
    function test_revert_empty() public view {
        (bool ok, bytes memory ret) = _call("");
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(Address.FailedInnerCall.selector));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapRevert.lean:36 — it never succeeds.
    function testFuzz_revert_never_ok(bytes memory rd) public view {
        (bool ok,) = _call(rd);
        assertFalse(ok);
    }
}
