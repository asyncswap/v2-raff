// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {HookHelpersCasesB} from "./HookHelpersB.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapLibHelpers.lean`: the OpenZeppelin / v4
///         library helpers the AsyncSwap model inlines, run on the real library code in a harness
///         (`LibHelpersB.sol`), and `AsyncFiller._priorityKey`, read back from the hook's stored order.
contract AsyncSwapLibHelpersFormalTest is HookHelpersCasesB {
    /// @notice formal/Refinement/Swarm/AsyncSwapLibHelpers.lean:20 — `Address._revert(rd)` reverts with `rd` when it is non-empty, else `FailedInnerCall`.
    function testFuzz_revert_run(bytes memory rd) public {
        _checkRevert(rd);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapLibHelpers.lean:26 — `Address._revert` never returns.
    function testFuzz_revert_never_ok(bytes memory rd) public {
        _checkRevert(rd);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapLibHelpers.lean:30 — `verifyCallResultFromTarget`: a failed call reverts like `_revert`; a success with empty data from a codeless target reverts `AddressEmptyCode`; otherwise it returns the data.
    function testFuzz_verify_run(bool success, bytes memory rd, bool hasCode, uint256 seed) public {
        _checkVerify(success, rd, hasCode, seed);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapLibHelpers.lean:40 — `verifyCallResultFromTarget` returns `r` iff the call succeeded, not (empty data and no code), and `r = rd` (state unchanged).
    function testFuzz_verify_ok_iff(bool success, bytes memory rd, bool hasCode, uint256 seed) public {
        _checkVerify(success, rd, hasCode, seed);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapLibHelpers.lean:47 — `functionCallWithValue`: `AddressInsufficientBalance` when balance < value, else the low-level call followed by `verifyCallResultFromTarget`.
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

    /// @notice formal/Refinement/Swarm/AsyncSwapLibHelpers.lean:61 — `functionCall` is the value-0 low-level call followed by `verifyCallResultFromTarget`.
    function testFuzz_functionCall_run(uint256 balance, bool callOk, bytes memory rd, bool hasCode, uint256 seed)
        public
    {
        _checkFunctionCallWithValue(balance, 0, callOk, rd, hasCode, seed, true);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapLibHelpers.lean:78 — `_callOptionalReturn` (via `safeTransferFrom`): the call's revert is passed on; otherwise empty data succeeds, a first word decoding to true succeeds, false reverts `SafeERC20FailedOperation`, undecodable data reverts.
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

    /// @notice formal/Refinement/Swarm/AsyncSwapLibHelpers.lean:99 — `safeTransferFrom` is `_callOptionalReturn` on `transferFrom(from, to, value)` calldata (selector 0x23b872dd).
    function testFuzz_safeTransferFrom_run(address from, address to, uint256 value, uint8 kind, bool b, bytes memory rd)
        public
    {
        _checkSafeTransferFrom(from, to, value, kind, b, rd);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapLibHelpers.lean:107 — a successful `safeTransferFrom` made a successful `transferFrom(from, to, value)` call whose data is not (empty from a codeless token) and passes the optional-return check.
    function testFuzz_safeTransferFrom_ok(address from, address to, uint256 value, uint8 kind, bool b, bytes memory rd)
        public
    {
        _checkSafeTransferFrom(from, to, value, kind, b, rd);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapLibHelpers.lean:125 — `CustomRevert.bubbleUpAndRevertWith` always reverts.
    function testFuzz_bubbleUpAndRevertWith_run(bool callOk, bytes memory rd, bytes4 selector, bytes4 context) public {
        _checkBubble(callOk, rd, selector, context);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapLibHelpers.lean:129 — `ShortStrings.byteLength` returns `sstr & 0xff`, reverting `InvalidShortString` above 31.
    function testFuzz_byteLength_run(bytes32 sstr) public {
        _checkByteLength(sstr);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapLibHelpers.lean:135 — a successful `byteLength` returns `sstr % 256`, at most 31, and writes nothing.
    function testFuzz_byteLength_ok(bytes32 sstr) public {
        _checkByteLength(sstr);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapLibHelpers.lean:148 — `_EIP712Name` is `toStringWithFallback(_name, _nameFallback)`: it returns the name (short or via the fallback slot) and writes nothing.
    function testFuzz_EIP712Name_run(string memory name, string memory version) public {
        _checkEip712(name, version, true);
        _checkDeployedEip712(address(hook), "AsyncSwap", "1");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapLibHelpers.lean:156 — `_EIP712Version` is `toStringWithFallback(_version, _versionFallback)`: it returns the version and writes nothing.
    function testFuzz_EIP712Version_run(string memory name, string memory version) public {
        _checkEip712(name, version, false);
        _checkDeployedEip712(address(hook), "AsyncSwap", "1");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapLibHelpers.lean:171 — for fee < 2^64 and seq <= 2^64 - 1, `_priorityKey(fee, seq)` returns `fee * 2^64 + (2^64 - 1 - seq)` (FIFO pools store fee 0, PriorityFee pools the paid bid).
    function testFuzz_priorityKey_run(uint64 fee, uint64 seq, bool priorityMode, bool zeroForOne) public {
        _checkPriorityKey(fee, seq, priorityMode, zeroForOne);
    }
}
