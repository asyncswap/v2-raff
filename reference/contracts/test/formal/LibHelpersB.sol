// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalBase} from "./FormalBase.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ShortString, ShortStrings} from "@openzeppelin/contracts/utils/ShortStrings.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {RadixPriceTree} from "@async-swap/libraries/RadixPriceTree.sol";

/// @notice Calls the real OpenZeppelin / v4 library internals that the AsyncSwap and Router models inline
///         (`formal/Refinement/Swarm/{AsyncSwap,Router}{Lib,}Helpers.lean`). The private helpers
///         `Address._revert` and `SafeERC20._callOptionalReturn` are reached through the internal
///         function that calls them.
contract OzLibHarnessB {
    /// @dev `Address._revert` is private; `verifyCallResultFromTarget(_, false, rd)` is exactly `_revert(rd)`.
    function revertVia(bytes memory rd) external view {
        Address.verifyCallResultFromTarget(address(this), false, rd);
    }

    function verify(address target, bool success, bytes memory rd) external view returns (bytes memory) {
        return Address.verifyCallResultFromTarget(target, success, rd);
    }

    function functionCallWithValue(address target, bytes memory data, uint256 value) external returns (bytes memory) {
        return Address.functionCallWithValue(target, data, value);
    }

    function functionCall(address target, bytes memory data) external returns (bytes memory) {
        return Address.functionCall(target, data);
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) external {
        SafeERC20.safeTransferFrom(token, from, to, value);
    }

    function byteLength(bytes32 sstr) external pure returns (uint256) {
        return ShortStrings.byteLength(ShortString.wrap(sstr));
    }

    function unsignedRoundsUp(Math.Rounding r) external pure returns (bool) {
        return Math.unsignedRoundsUp(r);
    }

    function mulDiv(uint256 x, uint256 y, uint256 d, Math.Rounding r) external pure returns (uint256) {
        return Math.mulDiv(x, y, d, r);
    }

    /// @dev Make a call (so there is return data to bubble), then `bubbleUpAndRevertWith`.
    function bubble(address target, bytes memory callData, bytes4 selector, bytes4 context) external {
        (bool ok,) = target.call(callData);
        ok;
        CustomRevert.bubbleUpAndRevertWith(target, selector, context);
    }

    receive() external payable {}
}

/// @notice Call target: calldata `abi.encode(bool ok, bytes rd)`; returns (or reverts with) `rd` raw.
contract ResponderB {
    fallback(bytes calldata data) external payable returns (bytes memory) {
        (bool ok, bytes memory rd) = abi.decode(data, (bool, bytes));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(rd, 0x20), mload(rd))
            }
        }
        assembly ("memory-safe") {
            return(add(rd, 0x20), mload(rd))
        }
    }
}

/// @notice Token whose every call returns (or reverts with) configured raw bytes, recording the calldata.
contract OptionalReturnTokenB {
    bool public reverts;
    bytes public answer;
    bytes public lastData;

    function configure(bool reverts_, bytes memory answer_) external {
        reverts = reverts_;
        answer = answer_;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        lastData = data;
        bytes memory rd = answer;
        if (reverts) {
            assembly ("memory-safe") {
                revert(add(rd, 0x20), mload(rd))
            }
        }
        assembly ("memory-safe") {
            return(add(rd, 0x20), mload(rd))
        }
    }
}

contract Eip712HarnessB is EIP712 {
    constructor(string memory name, string memory version) EIP712(name, version) {}

    function eip712Name() external view returns (string memory) {
        return _EIP712Name();
    }

    function eip712Version() external view returns (string memory) {
        return _EIP712Version();
    }
}

/// @notice The real `RadixPriceTree` on its own storage, with its fields readable.
contract RadixTreeHarnessB {
    using RadixPriceTree for RadixPriceTree.Tree;

    RadixPriceTree.Tree internal tree;

    function insert(uint128 price) external returns (bool) {
        return tree.insert(price);
    }

    function remove(uint128 price) external {
        tree.remove(price);
    }

    function root() external view returns (uint32) {
        return tree.root;
    }

    function nextNodeId() external view returns (uint32) {
        return tree.nextNodeId;
    }

    function freeIds() external view returns (uint32[] memory) {
        return tree.freeIds;
    }

    function node(uint32 id) external view returns (RadixPriceTree.Node memory) {
        return tree.nodes[id];
    }

    function leaf(uint128 price) external view returns (uint32) {
        return tree.leaves[price];
    }
}

/// @notice Shared checks of the library-helper theorems; each `*FormalTest` names one theorem per test.
abstract contract LibHelpersCasesB is FormalBase {
    OzLibHarnessB internal _ozHarness;
    ResponderB internal _responder;

    function _oz() internal returns (OzLibHarnessB) {
        if (address(_ozHarness) == address(0)) _ozHarness = new OzLibHarnessB();
        return _ozHarness;
    }

    function _resp() internal returns (ResponderB) {
        if (address(_responder) == address(0)) _responder = new ResponderB();
        return _responder;
    }

    /// @dev An address with no code (not a precompile, not a deployed contract).
    function _noCode(uint256 seed) internal view returns (address a) {
        a = address(uint160(uint256(keccak256(abi.encode("formal.nocode", seed)))));
        assertEq(a.code.length, 0);
    }

    /// @dev `_revert(rd)`: the raw `rd` when non-empty, else `FailedInnerCall()`.
    function _revertData(bytes memory rd) internal pure returns (bytes memory) {
        return rd.length > 0 ? rd : abi.encodeWithSelector(Address.FailedInnerCall.selector);
    }

    // ------------------------------------------------------------ Address._revert

    function _checkRevert(bytes memory rd) internal {
        (bool ok, bytes memory ret) = address(_oz()).call(abi.encodeCall(OzLibHarnessB.revertVia, (rd)));
        assertFalse(ok, "_revert never returns");
        assertEq(ret, _revertData(rd), "revert data");
    }

    // ------------------------------------------------------------ verifyCallResultFromTarget

    function _checkVerify(bool success, bytes memory rd, bool hasCode, uint256 seed) internal {
        address target = hasCode ? address(_resp()) : _noCode(seed);
        (bool ok, bytes memory ret) = address(_oz()).call(abi.encodeCall(OzLibHarnessB.verify, (target, success, rd)));
        bool expectOk = success && !(rd.length == 0 && !hasCode);
        assertEq(ok, expectOk, "ok iff success and not (empty data from a codeless target)");
        if (!success) {
            assertEq(ret, _revertData(rd), "a failed call reverts like _revert");
        } else if (!expectOk) {
            assertEq(ret, abi.encodeWithSelector(Address.AddressEmptyCode.selector, target), "AddressEmptyCode");
        } else {
            assertEq(abi.decode(ret, (bytes)), rd, "returns the call's data unchanged");
        }
    }

    // ------------------------------------------------------------ functionCall(WithValue)

    /// @dev `functionCallWithValue(target, data, value)`: `AddressInsufficientBalance(this)` when
    ///      `balance < value`, else the low-level call then `verifyCallResultFromTarget`.
    function _checkFunctionCallWithValue(
        uint256 balance,
        uint256 value,
        bool callOk,
        bytes memory rd,
        bool hasCode,
        uint256 seed,
        bool viaFunctionCall
    ) internal {
        if (viaFunctionCall) value = 0;
        vm.deal(address(_oz()), balance);
        address target = hasCode ? address(_resp()) : _noCode(seed);
        uint256 targetBefore = target.balance;
        (bool ok, bytes memory ret) = _callWithValue(target, abi.encode(callOk, rd), value, viaFunctionCall);
        if (balance < value) {
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(Address.AddressInsufficientBalance.selector, address(_ozHarness)));
            return;
        }
        // The low-level call: a codeless target accepts anything and returns nothing.
        bool s = hasCode ? callOk : true;
        if (!hasCode) rd = "";
        bool expectOk = s && !(rd.length == 0 && !hasCode);
        assertEq(ok, expectOk, "outcome is verifyCallResultFromTarget of the low-level call");
        if (!s) {
            assertEq(ret, _revertData(rd));
        } else if (!expectOk) {
            assertEq(ret, abi.encodeWithSelector(Address.AddressEmptyCode.selector, target));
        } else {
            assertEq(abi.decode(ret, (bytes)), rd, "returns the call's data");
            assertEq(target.balance, targetBefore + value, "value forwarded");
            assertEq(address(_ozHarness).balance, balance - value);
        }
    }

    function _callWithValue(address target, bytes memory data, uint256 value, bool viaFunctionCall)
        internal
        returns (bool ok, bytes memory ret)
    {
        bytes memory cd = viaFunctionCall
            ? abi.encodeCall(OzLibHarnessB.functionCall, (target, data))
            : abi.encodeCall(OzLibHarnessB.functionCallWithValue, (target, data, value));
        (ok, ret) = address(_oz()).call(cd);
    }

    // ------------------------------------------------------------ SafeERC20

    /// @dev `kind`: 0 the token reverts with `rd`; 1 returns nothing; 2 returns `abi.encode(b) ++ rd`;
    ///      3 returns `rd` raw; 4 codeless token.
    function _checkSafeTransferFrom(address from, address to, uint256 value, uint8 kind, bool b, bytes memory rd)
        internal
    {
        kind = uint8(bound(kind, 0, 4));
        OptionalReturnTokenB tok;
        address token;
        bytes memory answer;
        if (kind == 4) {
            token = _noCode(uint256(keccak256(rd)));
        } else {
            tok = new OptionalReturnTokenB();
            token = address(tok);
            answer = kind == 0 ? rd : kind == 1 ? bytes("") : kind == 2 ? bytes.concat(abi.encode(b), rd) : rd;
            tok.configure(kind == 0, answer);
        }
        bytes memory expectedCalldata = abi.encodeCall(IERC20.transferFrom, (from, to, value));
        assertEq(
            expectedCalldata, abi.encodePacked(bytes4(0x23b872dd), abi.encode(from, to, value)), "transferFrom calldata"
        );
        (bool ok, bytes memory ret) =
            address(_oz()).call(abi.encodeCall(OzLibHarnessB.safeTransferFrom, (IERC20(token), from, to, value)));

        if (kind == 4) {
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(Address.AddressEmptyCode.selector, token), "codeless token");
            return;
        }
        if (kind == 0) {
            assertFalse(ok);
            assertEq(ret, _revertData(answer), "the inner call's revert is passed on");
            return;
        }
        if (answer.length == 0) {
            assertTrue(ok, "empty return data succeeds");
        } else if (answer.length < 32) {
            assertFalse(ok);
            assertEq(ret.length, 0, "short return data: abi.decode reverts without data");
        } else {
            uint256 word = uint256(bytes32(answer));
            if (word > 1) {
                assertFalse(ok);
                assertEq(ret.length, 0, "non-bool word: abi.decode reverts without data");
            } else if (word == 0) {
                assertFalse(ok);
                assertEq(ret, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, token));
            } else {
                assertTrue(ok, "true succeeds");
            }
        }
        if (ok) assertEq(tok.lastData(), expectedCalldata, "the call made is transferFrom(from, to, value)");
    }

    // ------------------------------------------------------------ CustomRevert

    function _checkBubble(bool callOk, bytes memory rd, bytes4 selector, bytes4 context) internal {
        address target = address(_resp());
        (bool ok, bytes memory ret) = address(_oz())
            .call(abi.encodeCall(OzLibHarnessB.bubble, (target, abi.encode(callOk, rd), selector, context)));
        assertFalse(ok, "bubbleUpAndRevertWith always reverts");
        assertEq(
            ret,
            abi.encodeWithSelector(CustomRevert.WrappedError.selector, target, selector, rd, abi.encodePacked(context)),
            "WrappedError(target, selector, returndata, context)"
        );
    }

    // ------------------------------------------------------------ ShortStrings

    function _checkByteLength(bytes32 s) internal {
        (bool ok, bytes memory ret) = address(_oz()).call(abi.encodeCall(OzLibHarnessB.byteLength, (s)));
        uint256 low = uint256(s) & 0xFF;
        if (low > 31) {
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(ShortStrings.InvalidShortString.selector));
        } else {
            assertTrue(ok);
            uint256 n = abi.decode(ret, (uint256));
            assertEq(n, low);
            assertEq(n, uint256(s) % 256);
            assertLe(n, 31);
        }
    }

    // ------------------------------------------------------------ EIP712

    /// @dev `_EIP712Name` / `_EIP712Version` return the constructor strings (short or via the
    ///      fallback slot) and write no storage.
    function _checkEip712(string memory name, string memory version, bool checkName) internal {
        _checkEip712Once(name, version, checkName);
        // Strings of 32+ bytes live in the fallback slot rather than the immutable ShortString.
        _checkEip712Once(string.concat("a domain string longer than 31 bytes: ", name), version, checkName);
        _checkEip712Once(name, string.concat("a version string longer than 31 bytes: ", version), checkName);
    }

    function _checkEip712Once(string memory name, string memory version, bool checkName) internal {
        Eip712HarnessB e = new Eip712HarnessB(name, version);
        vm.record();
        string memory got = checkName ? e.eip712Name() : e.eip712Version();
        (, bytes32[] memory writes) = vm.accesses(address(e));
        assertEq(writes.length, 0, "no SSTORE");
        assertEq(got, checkName ? name : version);
    }

    /// @dev The deployed contract's `eip712Domain()` reports the constructor name / version, read-only.
    function _checkDeployedEip712(address target, string memory name, string memory version) internal {
        vm.record();
        (, string memory n, string memory v,,,,) = EIP712(target).eip712Domain();
        (, bytes32[] memory writes) = vm.accesses(target);
        assertEq(writes.length, 0, "no SSTORE");
        assertEq(n, name);
        assertEq(v, version);
    }

    // ------------------------------------------------------------ Math

    function _checkUnsignedRoundsUp(uint8 r) internal {
        r = uint8(bound(r, 0, 3)); // Math.Rounding has four members
        assertEq(_oz().unsignedRoundsUp(Math.Rounding(r)), r % 2 == 1);
    }

    function fullMathMulDiv(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return FullMath.mulDiv(x, y, d);
    }

    /// @dev `mulDivRnd`: d = 0 -> Panic(0x12) when x*y < 2^256, else MathOverflowedMulDiv();
    ///      floor(x*y/d) >= 2^256 -> MathOverflowedMulDiv(); else the floor,
    ///      plus one (checked: Panic(0x11)) when rounding up (r odd) and x*y % d > 0.
    function _checkMulDivRounding(uint256 x, uint256 y, uint256 d, uint8 r) internal {
        r = uint8(bound(r, 0, 3));
        (bool ok, bytes memory ret) =
            address(_oz()).call(abi.encodeCall(OzLibHarnessB.mulDiv, (x, y, d, Math.Rounding(r))));
        uint256 hi;
        uint256 lo;
        assembly {
            let mm := mulmod(x, y, not(0))
            lo := mul(x, y)
            hi := sub(sub(mm, lo), lt(mm, lo))
        }
        if (d == 0) {
            // OpenZeppelin 5.0.2 checks `denominator <= prod1` before dividing: a zero `d` panics only when
            // the product fits one word.
            assertFalse(ok);
            if (hi == 0) {
                assertEq(ret, abi.encodeWithSignature("Panic(uint256)", 0x12), "d = 0, x*y < 2^256: panic 0x12");
            } else {
                assertEq(ret, abi.encodeWithSelector(Math.MathOverflowedMulDiv.selector), "d = 0, x*y >= 2^256");
            }
            return;
        }
        if (hi >= d) {
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(Math.MathOverflowedMulDiv.selector), "floor >= 2^256");
            return;
        }
        uint256 q = this.fullMathMulDiv(x, y, d);
        if (r % 2 == 1 && mulmod(x, y, d) > 0) {
            if (q == type(uint256).max) {
                assertFalse(ok);
                assertEq(ret, abi.encodeWithSignature("Panic(uint256)", 0x11), "q + 1 overflows");
                return;
            }
            q += 1;
        }
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint256)), q);
    }
}
