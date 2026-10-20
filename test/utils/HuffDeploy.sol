// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {HuffNeoDeployer} from "foundry-huff-neo/HuffNeoDeployer.sol";
import {HuffNeoConfig} from "foundry-huff-neo/HuffNeoConfig.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IAsyncSwap as AsyncSwap} from "interfaces/IAsyncSwap.sol";
import {IRouter as Router} from "interfaces/IRouter.sol";
import {INativeClaims as NativeClaims} from "interfaces/INativeClaims.sol";
import {IMatchingEngine as MatchingEngine} from "interfaces/IMatchingEngine.sol";
import {ISignatureTransfer} from "interfaces/ISignatureTransfer.sol";

/// @notice Deploys the Huff contracts in `src/` (compiled by `hnc` through `vm.ffi`). The tests are
///         asyncswap/contracts' own; their deploy lines call this library, and `interfaces/` gives them the ABI.
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
        _deployTo(HuffNeoDeployer.config().with_args(args).creation_code_with_args("src/AsyncSwap.huff"), target);
    }

    /// @notice The FeeClaims test hook (`calculatePoolFee = amount / 100`) at `target`.
    function feeTestHookTo(bytes memory args, address target) internal {
        HuffNeoConfig config = HuffNeoDeployer.config().with_args(args).with_constant("POOL_FEE_MODE", "0x01");
        _deployTo(config.creation_code_with_args("src/AsyncSwap.huff"), target);
    }

    /// @notice The hook built without the hook-address check, for constructor tests that deploy anywhere
    ///         (the Solidity tests override `validateHookAddress` for the same purpose).
    function unboundHookCreationCode(bytes memory args) internal returns (bytes memory) {
        HuffNeoConfig config = HuffNeoDeployer.config().with_args(args).with_constant("SKIP_HOOK_ADDRESS_CHECK", "0x01");
        return config.creation_code_with_args("src/AsyncSwap.huff");
    }

    /// @notice `create(code)`; a reverting constructor reverts with its own data (`new` semantics).
    function create(bytes memory code) internal returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(code, 0x20), mload(code))
            if iszero(deployed) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    function router(IPoolManager manager, AsyncSwap hook, ISignatureTransfer permit2) internal returns (Router) {
        bytes memory args = abi.encode(manager, hook, permit2);
        return Router(_create(HuffNeoDeployer.config().with_args(args).creation_code_with_args("src/Router.huff")));
    }

    function nativeClaims(IPoolManager manager) internal returns (NativeClaims) {
        bytes memory args = abi.encode(manager);
        return NativeClaims(
            _create(HuffNeoDeployer.config().with_args(args).creation_code_with_args("src/NativeClaims.huff"))
        );
    }

    function matchingEngine() internal returns (MatchingEngine) {
        return MatchingEngine(_create(HuffNeoDeployer.config().creation_code("src/MatchingEngine.huff")));
    }

    function radixHarness() internal returns (address) {
        return _create(HuffNeoDeployer.config().creation_code("test/harness/RadixHarness.huff"));
    }
}
