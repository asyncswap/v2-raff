// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LibHelpersCasesB} from "./LibHelpersB.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/RouterLibHelpers.lean`: the OpenZeppelin `Address`,
///         `SafeERC20`, `ShortStrings`, `EIP712` and v4 `CustomRevert` helpers the Router model inlines,
///         run on the real library code in a harness (`LibHelpersB.sol`). The private `_revert` and
///         `_callOptionalReturn` are reached through `verifyCallResultFromTarget` and `safeTransferFrom`.
contract RouterLibHelpersFormalTest is LibHelpersCasesB {
    /// @notice formal/Refinement/Swarm/RouterLibHelpers.lean:27 — `Address._revert(rd)` reverts with `rd` when it is non-empty, else `FailedInnerCall`.
    function testFuzz_revert_run(bytes memory rd) public {
        _checkRevert(rd);
    }

    /// @notice formal/Refinement/Swarm/RouterLibHelpers.lean:33 — `Address._revert` never returns.
    function testFuzz_revert_never_ok(bytes memory rd) public {
        _checkRevert(rd);
    }

    /// @notice formal/Refinement/Swarm/RouterLibHelpers.lean:37 — `verifyCallResultFromTarget`: a failed call reverts like `_revert`; a success with empty data from a codeless target reverts `AddressEmptyCode`; otherwise it returns the data.
    function testFuzz_verify_run(bool success, bytes memory rd, bool hasCode, uint256 seed) public {
        _checkVerify(success, rd, hasCode, seed);
    }

    /// @notice formal/Refinement/Swarm/RouterLibHelpers.lean:47 — `verifyCallResultFromTarget` returns `r` iff the call succeeded, not (empty data and no code), and `r = rd` (state unchanged).
    function testFuzz_verify_ok_iff(bool success, bytes memory rd, bool hasCode, uint256 seed) public {
        _checkVerify(success, rd, hasCode, seed);
    }

    /// @notice formal/Refinement/Swarm/RouterLibHelpers.lean:54 — `functionCallWithValue`: `AddressInsufficientBalance` when balance < value, else the low-level call followed by `verifyCallResultFromTarget`.
    function testFuzz_functionCallWithValue_run(
        uint256 balance,
        uint256 value,
        bool callOk,
        bytes memory rd,
        bool hasCode,
        uint256 seed
    ) public {
        _checkFunctionCallWithValue(balance, value, callOk, rd, hasCode, seed, false);
    }

    /// @notice formal/Refinement/Swarm/RouterLibHelpers.lean:68 — `functionCall` is the value-0 low-level call followed by `verifyCallResultFromTarget`.
    function testFuzz_functionCall_run(uint256 balance, bool callOk, bytes memory rd, bool hasCode, uint256 seed)
        public
    {
        _checkFunctionCallWithValue(balance, 0, callOk, rd, hasCode, seed, true);
    }

    /// @notice formal/Refinement/Swarm/RouterLibHelpers.lean:85 — `_callOptionalReturn` (via `safeTransferFrom`): the call's revert is passed on; otherwise empty data succeeds, a first word decoding to true succeeds, false reverts `SafeERC20FailedOperation`, undecodable data reverts.
    function testFuzz_callOptionalReturn_run(
        address from,
        address to,
        uint256 value,
        uint8 kind,
        bool b,
        bytes memory rd
    ) public {
        _checkSafeTransferFrom(from, to, value, kind, b, rd);
    }

    /// @notice formal/Refinement/Swarm/RouterLibHelpers.lean:106 — `safeTransferFrom` is `_callOptionalReturn` on `transferFrom(from, to, value)` calldata (selector 0x23b872dd).
    function testFuzz_safeTransferFrom_run(address from, address to, uint256 value, uint8 kind, bool b, bytes memory rd)
        public
    {
        _checkSafeTransferFrom(from, to, value, kind, b, rd);
    }

    /// @notice formal/Refinement/Swarm/RouterLibHelpers.lean:116 — a successful `safeTransferFrom` made a successful `transferFrom(from, to, value)` call whose data is not (empty from a codeless token) and passes the optional-return check.
    function testFuzz_safeTransferFrom_ok(address from, address to, uint256 value, uint8 kind, bool b, bytes memory rd)
        public
    {
        _checkSafeTransferFrom(from, to, value, kind, b, rd);
    }

    /// @notice formal/Refinement/Swarm/RouterLibHelpers.lean:134 — `CustomRevert.bubbleUpAndRevertWith` always reverts.
    function testFuzz_bubbleUpAndRevertWith_run(bool callOk, bytes memory rd, bytes4 selector, bytes4 context) public {
        _checkBubble(callOk, rd, selector, context);
    }

    /// @notice formal/Refinement/Swarm/RouterLibHelpers.lean:138 — `ShortStrings.byteLength` returns `sstr & 0xff`, reverting `InvalidShortString` above 31.
    function testFuzz_byteLength_run(bytes32 sstr) public {
        _checkByteLength(sstr);
    }

    /// @notice formal/Refinement/Swarm/RouterLibHelpers.lean:144 — a successful `byteLength` returns `sstr % 256`, at most 31, and writes nothing.
    function testFuzz_byteLength_ok(bytes32 sstr) public {
        _checkByteLength(sstr);
    }

    /// @notice formal/Refinement/Swarm/RouterLibHelpers.lean:157 — `_EIP712Name` is `toStringWithFallback(_name, _nameFallback)`: it returns the name (short or via the fallback slot) and writes nothing.
    function testFuzz_EIP712Name_run(string memory name, string memory version) public {
        _checkEip712(name, version, true);
        _checkDeployedEip712(address(router), "AsyncSwap Router", "1");
    }

    /// @notice formal/Refinement/Swarm/RouterLibHelpers.lean:165 — `_EIP712Version` is `toStringWithFallback(_version, _versionFallback)`: it returns the version and writes nothing.
    function testFuzz_EIP712Version_run(string memory name, string memory version) public {
        _checkEip712(name, version, false);
        _checkDeployedEip712(address(router), "AsyncSwap Router", "1");
    }
}
