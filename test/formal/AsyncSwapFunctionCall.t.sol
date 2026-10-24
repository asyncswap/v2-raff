// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalOzE, AddressHarness} from "./FormalOzE.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapFunctionCall.lean` (OpenZeppelin
///         `Address.functionCall`, through `AddressHarness`).
contract AsyncSwapFunctionCallFormalTest is FormalOzE {
    AddressHarness h;

    function setUp() public override {
        super.setUp();
        h = new AddressHarness();
    }

    function _call(address t, bytes memory d) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = address(h).call(abi.encodeCall(AddressHarness.functionCall, (t, d)));
    }

    /// @dev Outcome of `call` on `h` plus the Responder's record afterwards, as one blob.
    function _outcome(bytes memory call) internal returns (bytes memory) {
        (bool ok, bytes memory ret) = address(h).call(call);
        (uint256 c, uint256 v, bytes memory d) = _record();
        return abi.encode(ok, ret, c, v, d);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapFunctionCall.lean:20 — `functionCall(t, d)` is
    ///         `functionCallWithValue(t, d, 0)`: same result and same final state, for any balance.
    function testFuzz_functionCall_eq_withValue(Target memory x, bytes memory d, uint128 bal) public {
        address t = _target(x, address(h));
        vm.deal(address(h), bal);
        uint256 snap = vm.snapshotState();
        bytes memory o1 = _outcome(abi.encodeCall(AddressHarness.functionCall, (t, d)));
        vm.revertToState(snap);
        bytes memory o2 = _outcome(abi.encodeCall(AddressHarness.functionCallWithValue, (t, d, 0)));
        assertEq(o1, o2, "same outcome and final state");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapFunctionCall.lean:35 — the outcome is `verifyCallResultFromTarget`
    ///         of the zero-value low-level call's `(ok, rd)`, in the world the call left.
    function testFuzz_functionCall_run(Target memory x, bytes memory d) public {
        address t = _target(x, address(h));
        (bool s, bytes memory rd) = _lowCall(t, 0, d);
        (uint256 calls0,,) = _record();
        vm.record();
        (bool ok, bytes memory ret) = _call(t, d);
        (bool expOk, bytes memory exp) = _verifySpec(t, s, rd);
        assertEq(ok, expOk, "outcome");
        if (!ok) {
            assertEq(ret, exp, "revert data");
            return;
        }
        assertEq(abi.decode(ret, (bytes)), exp, "returns rd");
        _assertNoWrites(address(h));
        if (x.toResponder) {
            (uint256 calls, uint256 value, bytes memory data) = _record();
            assertEq(calls, calls0 + 1, "one call");
            assertEq(value, 0, "zero value");
            assertEq(data, d, "data");
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapFunctionCall.lean:53 — on success the zero-value call returned
    ///         `(true, r)` and not (empty `r` from a code-less target).
    function testFuzz_functionCall_ok(Target memory x, bytes memory d) public {
        address t = _target(x, address(h));
        (bool s, bytes memory rd) = _lowCall(t, 0, d);
        (bool ok, bytes memory ret) = _call(t, d);
        if (!ok) return;
        bytes memory r = abi.decode(ret, (bytes));
        assertTrue(s, "call succeeded");
        assertEq(r, rd, "r is the call's return data");
        assertFalse(r.length == 0 && t.code.length == 0, "not empty from code-less target");
    }
}
