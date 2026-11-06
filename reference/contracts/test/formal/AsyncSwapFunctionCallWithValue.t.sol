// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalOzE, AddressHarness} from "./FormalOzE.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapFunctionCallWithValue.lean` (OpenZeppelin
///         `Address.functionCallWithValue`, through `AddressHarness`). The low-level call goes to a
///         `Responder` with a fuzzed scripted outcome, or to a fuzzed address.
contract AsyncSwapFunctionCallWithValueFormalTest is FormalOzE {
    AddressHarness h;

    function setUp() public override {
        super.setUp();
        h = new AddressHarness();
    }

    function _call(address t, bytes memory d, uint256 v) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = address(h).call(abi.encodeCall(AddressHarness.functionCallWithValue, (t, d, v)));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapFunctionCallWithValue.lean:20 — balance below `value` reverts
    ///         `AddressInsufficientBalance` (before any call).
    function testFuzz_functionCallWithValue_reverts_insufficient(
        Target memory x,
        bytes memory d,
        uint256 bal,
        uint256 v
    ) public {
        address t = _target(x, address(h));
        bal = bound(bal, 0, type(uint128).max);
        vm.assume(bal < v);
        vm.deal(address(h), bal);
        (uint256 calls0,,) = _record();
        (bool ok, bytes memory ret) = _call(t, d, v);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(Address.AddressInsufficientBalance.selector, address(h)));
        (uint256 calls,,) = _record();
        assertEq(calls, calls0, "no call made");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapFunctionCallWithValue.lean:36 — with enough balance, the outcome is
    ///         `verifyCallResultFromTarget` of the low-level call's `(ok, rd)`, in the world the call left.
    function testFuzz_functionCallWithValue_run(Target memory x, bytes memory d, uint256 bal, uint256 v) public {
        address t = _target(x, address(h));
        bal = bound(bal, 0, type(uint128).max);
        v = bound(v, 0, bal);
        vm.deal(address(h), bal);
        (bool s, bytes memory rd) = _lowCall(t, v, d);
        (uint256 calls0,,) = _record();
        vm.record();
        (bool ok, bytes memory ret) = _call(t, d, v);
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
            assertEq(value, v, "value");
            assertEq(data, d, "data");
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapFunctionCallWithValue.lean:54 — on success: balance >= value, the
    ///         low-level call returned `(true, r)`, and not (empty `r` from a code-less target).
    function testFuzz_functionCallWithValue_ok(Target memory x, bytes memory d, uint256 bal, uint256 v) public {
        address t = _target(x, address(h));
        bal = bound(bal, 0, type(uint128).max);
        v = bound(v, 0, type(uint128).max);
        vm.deal(address(h), bal);
        (bool s, bytes memory rd) = _lowCall(t, v, d);
        (bool ok, bytes memory ret) = _call(t, d, v);
        if (!ok) return;
        bytes memory r = abi.decode(ret, (bytes));
        assertGe(bal, v, "balance guard held");
        assertTrue(s, "call succeeded");
        assertEq(r, rd, "r is the call's return data");
        assertFalse(r.length == 0 && t.code.length == 0, "not empty from code-less target");
    }
}
