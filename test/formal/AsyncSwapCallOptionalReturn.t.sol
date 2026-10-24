// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalOzE, AddressHarness, SafeERC20Harness} from "./FormalOzE.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapCallOptionalReturn.lean` (OpenZeppelin
///         `SafeERC20._callOptionalReturn`, private, reached through `safeTransfer`, which only encodes
///         `transfer(to, value)` and calls it). The hypothesis `Address.functionCall tok d = r` is
///         evaluated on the real `Address.functionCall` (`AddressHarness`) on the same state.
contract AsyncSwapCallOptionalReturnFormalTest is FormalOzE {
    SafeERC20Harness h;
    AddressHarness a;

    function setUp() public override {
        super.setUp();
        h = new SafeERC20Harness();
        a = new AddressHarness();
    }

    function _data(address to, uint256 value) internal pure returns (bytes memory) {
        return abi.encodeCall(IERC20.transfer, (to, value));
    }

    /// @dev `Address.functionCall(tok, d)` on the current state, rolled back afterwards.
    function _functionCall(address tok, bytes memory d) internal returns (bool ok, bytes memory ret) {
        uint256 snap = vm.snapshotState();
        (ok, ret) = address(a).call(abi.encodeCall(AddressHarness.functionCall, (tok, d)));
        vm.revertToState(snap);
    }

    function _call(address tok, address to, uint256 value) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = address(h).call(abi.encodeCall(SafeERC20Harness.safeTransfer, (IERC20(tok), to, value)));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapCallOptionalReturn.lean:23 — if `functionCall` reverts, it reverts
    ///         with the same error.
    function testFuzz_callOptionalReturn_call_reverts(Target memory x, address to, uint256 value) public {
        // Failing calls: a reverting token, or a code-less address (empty success -> AddressEmptyCode).
        x.fail = true;
        address tok = _target(x, address(h));
        vm.assume(tok != address(a));
        if (!x.toResponder) vm.assume(tok.code.length == 0);
        (bool fcOk, bytes memory e) = _functionCall(tok, _data(to, value));
        assertFalse(fcOk, "hypothesis: functionCall reverts");
        (bool ok, bytes memory ret) = _call(tok, to, value);
        assertFalse(ok);
        assertEq(ret, e, "same error");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapCallOptionalReturn.lean:31 — once `functionCall` returned `rd`, the
    ///         outcome depends on `rd` alone: empty or first word 1 succeeds, first word 0 reverts
    ///         `SafeERC20FailedOperation`, short or non-bool reverts (abi.decode); no further writes.
    function testFuzz_callOptionalReturn_after(uint8 kind, uint256 word, bytes memory tail, address to, uint256 value)
        public
    {
        _configure(false, _rd(kind, word, tail));
        address tok = address(responder);
        (bool fcOk, bytes memory fcRet) = _functionCall(tok, _data(to, value));
        assertTrue(fcOk, "hypothesis: functionCall returns rd");
        bytes memory rd = abi.decode(fcRet, (bytes));
        (uint256 calls0,,) = _record();
        vm.record();
        (bool ok, bytes memory ret) = _call(tok, to, value);
        (bool expOk, bytes memory exp) = _optionalSpec(tok, rd);
        assertEq(ok, expOk, "outcome");
        if (!ok) {
            assertEq(ret, exp, "revert data");
        } else {
            _assertNoWrites(address(h));
            (uint256 calls,,) = _record();
            assertEq(calls, calls0 + 1, "world is the one the call left");
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapCallOptionalReturn.lean:61 — on success the zero-value call to the
    ///         token with the calldata returned `(true, rd)`, not empty from a code-less target, and `rd` is
    ///         empty or a word whose first word is 1.
    function testFuzz_callOptionalReturn_ok(Target memory x, address to, uint256 value) public {
        address tok = _target(x, address(h));
        vm.assume(tok != address(a));
        (bool s, bytes memory rd) = _lowCall(tok, 0, _data(to, value));
        (bool ok,) = _call(tok, to, value);
        if (!ok) return;
        assertTrue(s, "call succeeded");
        assertFalse(rd.length == 0 && tok.code.length == 0, "not empty from code-less target");
        assertTrue(rd.length == 0 || (rd.length >= 32 && _word0(rd) == 1), "rd empty or true");
        if (x.toResponder) {
            (, uint256 v, bytes memory data) = _record();
            assertEq(v, 0, "zero value");
            assertEq(data, _data(to, value), "calldata");
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapCallOptionalReturn.lean:109 — return data of at least a word whose
    ///         first word is 0 reverts `SafeERC20FailedOperation(token)`.
    function testFuzz_callOptionalReturn_false_reverts(bytes memory tail, address to, uint256 value) public {
        _configure(false, abi.encodePacked(uint256(0), tail));
        address tok = address(responder);
        (bool fcOk,) = _functionCall(tok, _data(to, value));
        assertTrue(fcOk, "hypothesis: functionCall returns rd");
        (bool ok, bytes memory ret) = _call(tok, to, value);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, tok));
    }
}
