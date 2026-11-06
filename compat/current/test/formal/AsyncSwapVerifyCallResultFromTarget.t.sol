// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalOzE, AddressHarness} from "./FormalOzE.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapVerifyCallResultFromTarget.lean`
///         (OpenZeppelin `Address.verifyCallResultFromTarget`, through `AddressHarness`).
contract AsyncSwapVerifyCallResultFromTargetFormalTest is FormalOzE {
    AddressHarness h;

    function setUp() public override {
        super.setUp();
        h = new AddressHarness();
    }

    function _target(address t, bool withCode) internal view returns (address) {
        return withCode ? address(responder) : t;
    }

    function _call(address t, bool success, bytes memory rd) internal view returns (bool ok, bytes memory ret) {
        (ok, ret) = address(h).staticcall(abi.encodeCall(AddressHarness.verifyCallResultFromTarget, (t, success, rd)));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapVerifyCallResultFromTarget.lean:19 — a failed call bubbles `rd`
    ///         (or `FailedInnerCall` if empty); success with empty data from a code-less target reverts
    ///         `AddressEmptyCode`; otherwise it returns `rd`.
    function testFuzz_verify_run(address t, bool withCode, bool success, bytes memory rd) public view {
        t = _target(t, withCode);
        (bool ok, bytes memory ret) = _call(t, success, rd);
        (bool expOk, bytes memory exp) = _verifySpec(t, success, rd);
        assertEq(ok, expOk, "reverts as verify_run says");
        if (ok) assertEq(abi.decode(ret, (bytes)), exp, "returns returndata");
        else assertEq(ret, exp, "revert data");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapVerifyCallResultFromTarget.lean:32 — succeeds iff `success` and not
    ///         (empty data and no code at `t`); then the result is `rd`.
    function testFuzz_verify_ok_iff(address t, bool withCode, bool success, bytes memory rd) public view {
        t = _target(t, withCode);
        (bool ok, bytes memory ret) = _call(t, success, rd);
        assertEq(ok, success && !(rd.length == 0 && t.code.length == 0), "ok iff");
        if (ok) assertEq(abi.decode(ret, (bytes)), rd, "r = rd");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapVerifyCallResultFromTarget.lean:47 — a successful run leaves the
    ///         state as it found it.
    function testFuzz_verify_frame(address t, bool withCode, bool success, bytes memory rd) public {
        t = _target(t, withCode);
        vm.record();
        (bool ok,) = address(h).call(abi.encodeCall(AddressHarness.verifyCallResultFromTarget, (t, success, rd)));
        if (ok) {
            _assertNoWrites(address(h));
            _assertNoWrites(t);
        }
    }
}
