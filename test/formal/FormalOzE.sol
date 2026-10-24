// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";

/// @notice Call target with a scripted outcome. Every call from anyone but `admin` lands in the
///         fallback, which records it and then returns or reverts with the configured bytes.
///         `admin` configures it with `abi.encode(bool fail, bytes ret)` and reads the record back
///         with empty calldata. It has no functions, so no calldata can hit a selector by accident.
contract Responder {
    address immutable admin;
    bool fail;
    bytes ret;
    uint256 calls;
    uint256 lastValue;
    bytes lastData;

    constructor(address admin_) {
        admin = admin_;
    }

    fallback(bytes calldata data) external payable returns (bytes memory) {
        if (msg.sender == admin) {
            if (data.length == 0) return abi.encode(calls, lastValue, lastData);
            (fail, ret) = abi.decode(data, (bool, bytes));
            return "";
        }
        calls++;
        lastValue = msg.value;
        lastData = data;
        bytes memory r = ret;
        if (fail) {
            assembly ("memory-safe") {
                revert(add(r, 0x20), mload(r))
            }
        }
        assembly ("memory-safe") {
            return(add(r, 0x20), mload(r))
        }
    }
}

/// @notice The real OpenZeppelin `Address` internals, compiled with the project's settings.
///         `_revert` is private; `verifyCallResult(false, rd)` is the shortest path to it.
contract AddressHarness {
    function functionCall(address t, bytes memory d) external returns (bytes memory) {
        return Address.functionCall(t, d);
    }

    function functionCallWithValue(address t, bytes memory d, uint256 v) external returns (bytes memory) {
        return Address.functionCallWithValue(t, d, v);
    }

    function verifyCallResultFromTarget(address t, bool success, bytes memory rd) external view returns (bytes memory) {
        return Address.verifyCallResultFromTarget(t, success, rd);
    }

    /// @dev `verifyCallResult(false, rd)` is exactly `_revert(rd)`.
    function revert_(bytes memory rd) external pure {
        Address.verifyCallResult(false, rd);
    }
}

/// @notice The real OpenZeppelin `SafeERC20`. `_callOptionalReturn` is private and is reached through
///         `safeTransfer` / `safeTransferFrom`, which only encode the calldata and call it.
contract SafeERC20Harness {
    using SafeERC20 for IERC20;

    function safeTransferFrom(IERC20 t, address from, address to, uint256 value) external {
        t.safeTransferFrom(from, to, value);
    }

    function safeTransfer(IERC20 t, address to, uint256 value) external {
        t.safeTransfer(to, value);
    }
}

/// @notice The real v4-core `CustomRevert.bubbleUpAndRevertWith`. It wraps the return data of the
///         last call, so the harness first makes the call (`target.call(callData)`) whose return data
///         is wrapped, as the library's callers do.
contract CustomRevertHarness {
    function bubble(address target, bytes calldata callData, address c, bytes4 sel, bytes4 ctx) external {
        assembly ("memory-safe") {
            let p := mload(0x40)
            calldatacopy(p, callData.offset, callData.length)
            pop(call(gas(), target, 0, p, callData.length, 0, 0))
        }
        CustomRevert.bubbleUpAndRevertWith(c, sel, ctx);
    }
}

/// @notice Shared scaffolding for the checks of the OpenZeppelin `Address` / `SafeERC20` and v4-core
///         `CustomRevert` theorems in `formal/Refinement/Swarm/`.
abstract contract FormalOzE is Test {
    address admin = makeAddr("responderAdmin");
    Responder responder;

    /// @dev A fuzzed call target: the `Responder` scripted to fail or return `_rd(kind, word, tail)`, or
    ///      the fuzzed address `t`.
    struct Target {
        address t;
        bool toResponder;
        bool fail;
        uint8 kind;
        uint256 word;
        bytes tail;
    }

    function _target(Target memory x, address harness) internal returns (address) {
        if (x.toResponder) {
            _configure(x.fail, _rd(x.kind, x.word, x.tail));
            return address(responder);
        }
        vm.assume(_plainTarget(x.t) && x.t != harness);
        return x.t;
    }

    function setUp() public virtual {
        responder = new Responder(admin);
    }

    function _configure(bool fail, bytes memory ret) internal {
        vm.prank(admin);
        (bool ok,) = address(responder).call(abi.encode(fail, ret));
        require(ok, "configure");
    }

    function _record() internal returns (uint256 calls, uint256 value, bytes memory data) {
        vm.prank(admin);
        (bool ok, bytes memory r) = address(responder).call("");
        require(ok, "record");
        (calls, value, data) = abi.decode(r, (uint256, uint256, bytes));
    }

    /// @dev Return data built from fuzz input, covering every branch the theorems distinguish:
    ///      empty, shorter than a word, first word `1`, first word `0`, any first word, raw bytes.
    function _rd(uint8 kind, uint256 word, bytes memory tail) internal pure returns (bytes memory) {
        kind %= 6;
        if (kind == 0) return "";
        if (kind == 1) {
            uint256 n = tail.length % 32;
            if (n == 0) n = 1;
            bytes memory s = new bytes(n);
            for (uint256 i; i < n; i++) {
                s[i] = i < tail.length ? tail[i] : bytes1(uint8(i + 1));
            }
            return s;
        }
        if (kind == 2) return abi.encodePacked(uint256(1), tail);
        if (kind == 3) return abi.encodePacked(uint256(0), tail);
        if (kind == 4) return abi.encodePacked(word, tail);
        return tail;
    }

    /// @dev The first 32-byte word of `rd` (`bytesWord (rd.take 32)`); needs `rd.length >= 32`.
    function _word0(bytes memory rd) internal pure returns (uint256 w) {
        assembly ("memory-safe") {
            w := mload(add(rd, 0x20))
        }
    }

    /// @dev Targets whose calls are deterministic and gas-bounded: not a precompile (some burn all
    ///      the forwarded gas on bad input, which the model's gas-free `lowCall` does not see) and not
    ///      a Foundry cheatcode / console / CREATE2-deployer address or this test.
    function _plainTarget(address t) internal view returns (bool) {
        return uint160(t) > 0x11 && t != address(vm) && t != 0x000000000000000000636F6e736F6c652e6c6f67
            && t != address(this) && t != 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    }

    /// @dev `Address.verifyCallResultFromTarget` as `verify_run` states it: `(true, rd)` on success,
    ///      else `(false, revertData)`. The model's "revert" bubbles `rd` as it is.
    function _verifySpec(address t, bool success, bytes memory rd) internal view returns (bool, bytes memory) {
        if (!success) {
            return (false, rd.length > 0 ? rd : abi.encodeWithSelector(Address.FailedInnerCall.selector));
        }
        if (rd.length == 0 && t.code.length == 0) {
            return (false, abi.encodeWithSelector(Address.AddressEmptyCode.selector, t));
        }
        return (true, rd);
    }

    /// @dev The tail of `_callOptionalReturn` once `functionCall` returned `rd` (`callOptionalReturn_after`).
    ///      The model's "abi.decode" error is empty revert data on the bytecode.
    function _optionalSpec(address token, bytes memory rd) internal pure returns (bool, bytes memory) {
        if (rd.length == 0) return (true, "");
        if (rd.length < 32) return (false, "");
        uint256 w = _word0(rd);
        if (w == 1) return (true, "");
        if (w == 0) return (false, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, token));
        return (false, "");
    }

    /// @dev The low-level call's outcome `ext.lowCall t v d`, observed from this contract and then
    ///      rolled back, so the call under test runs on the same state.
    function _lowCall(address t, uint256 v, bytes memory d) internal returns (bool s, bytes memory rd) {
        uint256 snap = vm.snapshotState();
        vm.deal(address(this), v);
        (s, rd) = t.call{value: v}(d);
        vm.revertToState(snap);
    }

    /// @dev No SSTORE to `a` since `vm.record()`.
    function _assertNoWrites(address a) internal view {
        (, bytes32[] memory writes) = vm.accesses(a);
        assertEq(writes.length, 0, "no storage writes");
    }
}
