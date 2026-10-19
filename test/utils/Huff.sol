// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {HuffNeoDeployer} from "foundry-huff-neo/HuffNeoDeployer.sol";

/// @notice Compiles Huff sources with `hnc` (through foundry-huff-neo's `vm.ffi`) and deploys them.
library Huff {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Creation code of `file` (e.g. `"src/AsyncSwap.huff"`) followed by the ABI-encoded `args`.
    function creationCode(string memory file, bytes memory args) internal returns (bytes memory) {
        return HuffNeoDeployer.config().with_args(args).creation_code_with_args(file);
    }

    function deploy(string memory file, bytes memory args) internal returns (address deployed) {
        bytes memory code = creationCode(file, args);
        assembly ("memory-safe") {
            deployed := create(0, add(code, 0x20), mload(code))
        }
        require(deployed != address(0), "Huff: deployment failed");
    }

    function deploy(string memory file) internal returns (address) {
        return deploy(file, "");
    }

    /// @dev Runs the constructor *at* `target` (so its storage writes land there) and installs the runtime
    ///      code it returns: how a hook is put at an address whose low bits carry its permission flags.
    function deployTo(string memory file, bytes memory args, address target) internal {
        vm.etch(target, creationCode(file, args));
        (bool ok, bytes memory runtime) = target.call("");
        require(ok, "Huff: constructor reverted");
        vm.etch(target, runtime);
    }
}
