// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LibHelpersCasesB} from "./LibHelpersB.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/RouterHelpers.lean`: the library helpers the Router
///         model inlines, run on the real library code in a harness (`LibHelpersB.sol`).
contract RouterHelpersFormalTest is LibHelpersCasesB {
    /// @notice formal/Refinement/Swarm/RouterHelpers.lean:21 — `CustomRevert.bubbleUpAndRevertWith` always reverts, touching no state.
    function testFuzz_bubbleUpAndRevertWith_reverts(bool callOk, bytes memory rd, bytes4 selector, bytes4 context)
        public
    {
        _checkBubble(callOk, rd, selector, context);
    }

    /// @notice formal/Refinement/Swarm/RouterHelpers.lean:25 — `Address._revert` reverts with the return data, or `FailedInnerCall` when it is empty.
    function testFuzz_address_revert_run(bytes memory rd) public {
        _checkRevert(rd);
    }

    /// @notice formal/Refinement/Swarm/RouterHelpers.lean:31 — `verifyCallResultFromTarget` on a failed call reverts exactly like `_revert`.
    function testFuzz_verifyCallResult_fail(bytes memory rd, bool hasCode, uint256 seed) public {
        _checkVerify(false, rd, hasCode, seed);
    }

    /// @notice formal/Refinement/Swarm/RouterHelpers.lean:37 — on a successful call it returns the data unchanged, unless the data is empty and the target has no code (`AddressEmptyCode`).
    function testFuzz_verifyCallResult_ok(bytes memory rd, bool hasCode, uint256 seed) public {
        _checkVerify(true, rd, hasCode, seed);
    }

    /// @notice formal/Refinement/Swarm/RouterHelpers.lean:43 — `functionCallWithValue` reverts `AddressInsufficientBalance` when the balance is below `value`.
    function testFuzz_functionCallWithValue_insufficient(uint256 balance, uint256 value, bool callOk, bytes memory rd)
        public
    {
        balance = bound(balance, 0, type(uint256).max - 1);
        value = bound(value, balance + 1, type(uint256).max);
        _checkFunctionCallWithValue(balance, value, callOk, rd, true, 0, false);
    }

    /// @notice formal/Refinement/Swarm/RouterHelpers.lean:48 — with enough balance, `functionCallWithValue` is the low-level call followed by `verifyCallResultFromTarget`.
    function testFuzz_functionCallWithValue_eq(
        uint256 balance,
        uint256 value,
        bool callOk,
        bytes memory rd,
        bool hasCode,
        uint256 seed
    ) public {
        value = bound(value, 0, balance);
        _checkFunctionCallWithValue(balance, value, callOk, rd, hasCode, seed, false);
    }

    /// @notice formal/Refinement/Swarm/RouterHelpers.lean:54 — `functionCall` is the value-0 low-level call followed by `verifyCallResultFromTarget` (the balance check never fires).
    function testFuzz_functionCall_eq(uint256 balance, bool callOk, bytes memory rd, bool hasCode, uint256 seed)
        public
    {
        _checkFunctionCallWithValue(balance, 0, callOk, rd, hasCode, seed, true);
    }

    /// @notice formal/Refinement/Swarm/RouterHelpers.lean:63 — after the call returns `rd`, `_callOptionalReturn` (via `safeTransferFrom`) succeeds iff `rd` is empty or its first word decodes to true; false reverts `SafeERC20FailedOperation`.
    function testFuzz_callOptionalReturn_after(
        address from,
        address to,
        uint256 value,
        uint8 kind,
        bool b,
        bytes memory rd
    ) public {
        _checkSafeTransferFrom(from, to, value, uint8(bound(kind, 1, 3)), b, rd); // the call returned
    }

    /// @notice formal/Refinement/Swarm/RouterHelpers.lean:87 — when the inner `functionCall` reverts, `_callOptionalReturn` reverts with the same error.
    function testFuzz_callOptionalReturn_call_reverts(
        address from,
        address to,
        uint256 value,
        bool codeless,
        bytes memory rd
    ) public {
        _checkSafeTransferFrom(from, to, value, codeless ? 4 : 0, false, rd); // token reverts / AddressEmptyCode
    }

    /// @notice formal/Refinement/Swarm/RouterHelpers.lean:94 — `safeTransferFrom` is `_callOptionalReturn` on the `transferFrom(from, to, value)` calldata (selector 0x23b872dd).
    function testFuzz_safeTransferFrom_eq(address from, address to, uint256 value, uint8 kind, bool b, bytes memory rd)
        public
    {
        _checkSafeTransferFrom(from, to, value, kind, b, rd);
    }

    /// @notice formal/Refinement/Swarm/RouterHelpers.lean:104 — `byteLength` returns the low byte when it is at most 31, otherwise reverts `InvalidShortString`; it never writes.
    function testFuzz_byteLength_run(bytes32 s) public {
        _checkByteLength(s);
    }

    /// @notice formal/Refinement/Swarm/RouterHelpers.lean:110 — a successful `byteLength` returns at most 31 and leaves the state unchanged.
    function testFuzz_byteLength_le(bytes32 s) public {
        _checkByteLength(s);
    }

    /// @notice formal/Refinement/Swarm/RouterHelpers.lean:117 — `_EIP712Name` is `toStringWithFallback(_name, _nameFallback)`: it returns the name and writes nothing.
    function testFuzz_eip712Name_eq(string memory name, string memory version) public {
        _checkEip712(name, version, true);
        _checkDeployedEip712(address(router), "AsyncSwap Router", "1");
    }

    /// @notice formal/Refinement/Swarm/RouterHelpers.lean:125 — `_EIP712Version` is `toStringWithFallback(_version, _versionFallback)`: it returns the version and writes nothing.
    function testFuzz_eip712Version_eq(string memory name, string memory version) public {
        _checkEip712(name, version, false);
        _checkDeployedEip712(address(router), "AsyncSwap Router", "1");
    }
}
