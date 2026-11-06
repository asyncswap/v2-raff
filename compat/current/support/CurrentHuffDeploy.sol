// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {HuffNeoDeployer} from "foundry-huff-neo/HuffNeoDeployer.sol";

/// @dev Only deployment changes in the copied public-API suite. Solidity contracts supply ABI types,
///      while these helpers always compile hand-written .huff sources and install their bytecode.
library CurrentHuffDeploy {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function deploy(string memory source, bytes memory args) internal returns (address deployed) {
        bytes memory code = HuffNeoDeployer.config().with_args(args).creation_code_with_args(source);
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
            if iszero(deployed) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    function hookTo(bytes memory args, address target) internal {
        bytes memory code =
            HuffNeoDeployer.config().with_args(args).creation_code_with_args("src/current/AsyncSwap.huff");
        installConstructor(code, target);
    }

    /// Test-only equivalent of overriding validateHookAddress in a Solidity constructor harness.
    function constructorTo(bytes memory args, address target) internal {
        bytes memory code = HuffNeoDeployer.config()
            .with_constant("SKIP_HOOK_ADDRESS_CHECK", "0x01")
            .with_args(args)
            .creation_code_with_args("src/current/AsyncSwap.huff");
        installConstructor(code, target);
    }

    /// Test-only equivalent of the upstream FeeTestHook's 1% pool-fee override.
    function feeHookTo(bytes memory args, address target) internal {
        bytes memory code = HuffNeoDeployer.config()
            .with_constant("POOL_FEE_MODE", "0x01")
            .with_args(args)
            .creation_code_with_args("src/current/AsyncSwap.huff");
        installConstructor(code, target);
    }

    function routerConstructorTo(bytes memory args, address target) internal {
        bytes memory code = HuffNeoDeployer.config().with_args(args).creation_code_with_args("src/current/Router.huff");
        installConstructor(code, target);
    }

    function installConstructor(bytes memory code, address target) private {
        // Match forge-std's deployCodeTo: run the constructor at the final hook permission address.
        vm.etch(target, code);
        (bool ok, bytes memory runtime) = target.call("");
        if (!ok) {
            assembly ("memory-safe") { revert(add(runtime, 32), mload(runtime)) }
        }
        require(runtime.length != 0, "Huff constructor returned no runtime");
        vm.etch(target, runtime);
    }
}
