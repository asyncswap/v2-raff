// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {HuffNeoDeployer} from "foundry-huff-neo/HuffNeoDeployer.sol";
import {HuffNeoConfig} from "foundry-huff-neo/HuffNeoConfig.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {Router} from "@async-swap/Router.sol";
import {NativeClaims} from "@async-swap/NativeClaims.sol";
import {MatchingEngine} from "@async-swap/MatchingEngine.sol";
import {ISignatureTransfer} from "@async-swap/interfaces/ISignatureTransfer.sol";

/// @notice Deploys the Huff contracts in `huff/` (compiled by `hnc` through `vm.ffi`). The tests are
///         asyncswap/contracts' own; their deploy lines call this library instead of deploying the Solidity in
///         `src/`, which only supplies the types and ABI.
library HuffDeploy {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function _create(bytes memory code) private returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(code, 0x20), mload(code))
        }
        require(deployed != address(0), "HuffDeploy: deployment failed");
    }

    /// @dev forge-std `deployCodeTo`: run the constructor *at* `target` and install the runtime it returns.
    function _deployTo(bytes memory creation, address target) private {
        vm.etch(target, creation);
        (bool ok, bytes memory runtime) = target.call("");
        require(ok, "HuffDeploy: constructor reverted");
        vm.etch(target, runtime);
    }

    /// @notice The hook at `target`: `deployCodeTo("AsyncSwap.sol", args, target)`.
    function hookTo(bytes memory args, address target) internal {
        _deployTo(HuffNeoDeployer.config().with_args(args).creation_code_with_args("huff/AsyncSwap.huff"), target);
    }

    /// @notice The FeeClaims test hook (`calculatePoolFee = amount / 100`) at `target`.
    function feeTestHookTo(bytes memory args, address target) internal {
        HuffNeoConfig config = HuffNeoDeployer.config().with_args(args).with_constant("POOL_FEE_MODE", "0x01");
        _deployTo(config.creation_code_with_args("huff/AsyncSwap.huff"), target);
    }

    function hookCreationCode(bytes memory args) internal returns (bytes memory) {
        return HuffNeoDeployer.config().with_args(args).creation_code_with_args("huff/AsyncSwap.huff");
    }

    function router(IPoolManager manager, AsyncSwap hook, ISignatureTransfer permit2) internal returns (Router) {
        bytes memory args = abi.encode(manager, hook, permit2);
        return Router(_create(HuffNeoDeployer.config().with_args(args).creation_code_with_args("huff/Router.huff")));
    }

    function nativeClaims(IPoolManager manager) internal returns (NativeClaims) {
        bytes memory args = abi.encode(manager);
        return NativeClaims(
            _create(HuffNeoDeployer.config().with_args(args).creation_code_with_args("huff/NativeClaims.huff"))
        );
    }

    function matchingEngine() internal returns (MatchingEngine) {
        return MatchingEngine(_create(HuffNeoDeployer.config().creation_code("huff/MatchingEngine.huff")));
    }

    function radixHarness() internal returns (address) {
        return _create(HuffNeoDeployer.config().creation_code("huff/test/RadixHarness.huff"));
    }
}
