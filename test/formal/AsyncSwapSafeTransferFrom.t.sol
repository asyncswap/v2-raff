// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalOzE, SafeERC20Harness} from "./FormalOzE.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapSafeTransferFrom.lean` (OpenZeppelin
///         `SafeERC20.safeTransferFrom`, through `SafeERC20Harness`). The token is a `Responder` with a
///         fuzzed scripted answer, or a fuzzed address.
contract AsyncSwapSafeTransferFromFormalTest is FormalOzE {
    SafeERC20Harness h;

    function setUp() public override {
        super.setUp();
        h = new SafeERC20Harness();
    }

    /// @dev `transferFromData fr to value`: selector 0x23b872dd and the three words.
    function _data(address fr, address to, uint256 value) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(bytes4(0x23b872dd), fr, to, value);
    }

    /// @dev `afterCall token s rd` as the theorem states it: `(true, "")` on success, else `(false, revertData)`.
    function _afterCall(address token, bool s, bytes memory rd) internal view returns (bool, bytes memory) {
        if (!s) return (false, rd.length > 0 ? rd : abi.encodeWithSelector(Address.FailedInnerCall.selector));
        if (rd.length == 0) {
            if (token.code.length == 0) {
                return (false, abi.encodeWithSelector(Address.AddressEmptyCode.selector, token));
            }
            return (true, "");
        }
        return _optionalSpec(token, rd);
    }

    function _call(address token, address fr, address to, uint256 value) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = address(h).call(abi.encodeCall(SafeERC20Harness.safeTransferFrom, (IERC20(token), fr, to, value)));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSafeTransferFrom.lean:39 — exactly one zero-value call with
    ///         `transferFrom(from, to, value)` calldata, then `afterCall` of its `(s, rd)`.
    function testFuzz_safeTransferFrom_spec(Target memory x, address fr, address to, uint256 value) public {
        address token = _target(x, address(h));
        bytes memory cd = _data(fr, to, value);
        (bool s, bytes memory rd) = _lowCall(token, 0, cd);
        (uint256 calls0,,) = _record();
        vm.record();
        (bool ok, bytes memory ret) = _call(token, fr, to, value);
        (bool expOk, bytes memory exp) = _afterCall(token, s, rd);
        assertEq(ok, expOk, "outcome");
        if (!ok) {
            assertEq(ret, exp, "revert data");
            return;
        }
        _assertNoWrites(address(h));
        if (x.toResponder) _assertOneCall(calls0, cd);
    }

    function _assertOneCall(uint256 calls0, bytes memory cd) internal {
        (uint256 calls, uint256 v, bytes memory data) = _record();
        assertEq(calls, calls0 + 1, "exactly one call");
        assertEq(v, 0, "value 0");
        assertEq(data, cd, "transferFrom calldata");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSafeTransferFrom.lean:91 — succeeds iff the call returned
    ///         `(true, rd)` with `rd` empty from a contract, or `rd` at least a word whose first word is 1; the
    ///         function writes nothing itself.
    function testFuzz_safeTransferFrom_ok_iff(Target memory x, address fr, address to, uint256 value) public {
        address token = _target(x, address(h));
        (bool s, bytes memory rd) = _lowCall(token, 0, _data(fr, to, value));
        vm.record();
        (bool ok,) = _call(token, fr, to, value);
        bool cond = s && ((rd.length == 0 && token.code.length != 0) || (rd.length >= 32 && _word0(rd) == 1));
        assertEq(ok, cond, "ok iff");
        if (ok) _assertNoWrites(address(h));
    }
}
