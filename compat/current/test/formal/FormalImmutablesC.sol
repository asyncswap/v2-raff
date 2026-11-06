// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/// @notice Reads a deployed contract's immutables back from its runtime code. solc compiles each read of
///         an immutable to a `PUSH32` whose operand is zero in the artifact's `deployedBytecode` and is
///         filled in at deployment. Walking the artifact's opcodes and comparing each `PUSH32` operand with
///         the deployed code gives the set of distinct nonzero immutable values; the scan also checks that
///         the two codes agree everywhere else, so nothing outside an immutable slot differs.
abstract contract FormalImmutablesC is Test {
    /// @dev Distinct nonzero immutable values of the contract at `deployed`, built from `artifact`
    ///      (`"File.sol:Contract"`).
    function _immutables(string memory artifact, address deployed) internal view returns (bytes32[] memory vals) {
        bytes memory art = vm.getDeployedCode(artifact);
        bytes memory act = deployed.code;
        assertEq(act.length, art.length, "same code length");
        bytes32[] memory tmp = new bytes32[](64);
        uint256 n;
        bytes memory masked = bytes.concat(act); // a copy, with the immutable operands zeroed below
        uint256 i;
        while (i < art.length) {
            uint8 op = uint8(art[i]);
            if (op == 0x7f && i + 32 < art.length) {
                bytes32 a;
                bytes32 b;
                assembly ("memory-safe") {
                    a := mload(add(add(art, 0x21), i))
                    b := mload(add(add(act, 0x21), i))
                }
                if (a == 0 && b != 0) {
                    bool seen;
                    for (uint256 k; k < n; k++) {
                        if (tmp[k] == b) seen = true;
                    }
                    if (!seen) tmp[n++] = b;
                    assembly ("memory-safe") {
                        mstore(add(add(masked, 0x21), i), 0)
                    }
                }
                i += 33;
            } else if (op >= 0x60 && op < 0x7f) {
                i += uint256(op) - 0x5f + 1;
            } else {
                i++;
            }
        }
        assertEq(keccak256(masked), keccak256(art), "code differs only in immutable slots");
        vals = new bytes32[](n);
        for (uint256 k; k < n; k++) {
            vals[k] = tmp[k];
        }
    }

    function _contains(bytes32[] memory vals, bytes32 v) internal pure returns (bool) {
        for (uint256 k; k < vals.length; k++) {
            if (vals[k] == v) return true;
        }
        return false;
    }

    /// @dev The immutables are exactly `expected` (as a set; zero entries can't be seen and are skipped).
    function _assertImmutables(bytes32[] memory vals, bytes32[] memory expected) internal pure {
        for (uint256 k; k < expected.length; k++) {
            if (expected[k] != 0) require(_contains(vals, expected[k]), "expected immutable missing");
        }
        for (uint256 k; k < vals.length; k++) {
            require(_contains(expected, vals[k]), "unexpected immutable");
        }
    }
}
