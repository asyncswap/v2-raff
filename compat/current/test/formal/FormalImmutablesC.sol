// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/// @notice Read immutable values from the compiler's declared runtime ranges, including narrow Solar
///         operands. Mask only those ranges, then check that every other byte matches the artifact.
abstract contract FormalImmutablesC is Test {
    // parseJson encodes object fields alphabetically: length precedes start.
    struct ImmutableRange {
        uint256 length;
        uint256 start;
    }

    /// @dev Distinct nonzero immutable values of the contract at `deployed`, built from `artifact`
    ///      (`"File.sol:Contract"`).
    function _immutables(string memory artifact, address deployed) internal view returns (bytes32[] memory vals) {
        bytes memory art = vm.getDeployedCode(artifact);
        bytes memory act = deployed.code;
        assertEq(act.length, art.length, "same code length");
        bytes32[] memory tmp = new bytes32[](64);
        uint256 n;
        bytes memory masked = bytes.concat(act); // a copy, with the immutable operands zeroed below
        string memory json = vm.readFile(vm.getArtifactPathByDeployedCode(art));
        string memory base = ".deployedBytecode.immutableReferences";
        string[] memory keys = vm.parseJsonKeys(json, base);
        for (uint256 i; i < keys.length; i++) {
            ImmutableRange[] memory ranges =
                abi.decode(vm.parseJson(json, string.concat(base, ".", keys[i])), (ImmutableRange[]));
            for (uint256 j; j < ranges.length; j++) {
                ImmutableRange memory r = ranges[j];
                require(
                    r.length > 0 && r.length <= 32 && r.length <= art.length && r.start <= art.length - r.length,
                    "invalid immutable range"
                );
                bytes32 b;
                for (uint256 k; k < r.length; k++) {
                    require(art[r.start + k] == 0, "immutable placeholder is not zero");
                    // PUSHn operands are big-endian. Normalize short integers/addresses to bytes32.
                    b = bytes32((uint256(b) << 8) | uint8(act[r.start + k]));
                    masked[r.start + k] = 0;
                }
                if (b != 0) {
                    bool seen;
                    for (uint256 k; k < n; k++) {
                        if (tmp[k] == b) seen = true;
                    }
                    if (!seen) tmp[n++] = b;
                }
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
