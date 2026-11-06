// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SetupHook} from "../test/SetupHook.t.sol";
import {HuffNeoDeployer} from "foundry-huff-neo/HuffNeoDeployer.sol";
import {console2} from "forge-std/console2.sol";

contract CurrentPortSizeTest is SetupHook {
    function test_creationCodeFitsInitcodeLimit() public {
        bytes memory hookCode = HuffNeoDeployer.config()
            .with_args(
                abi.encode(manager, currency1, address(this), address(router), hookMinOrderUsd, hookAssetPrecision)
            )
            .creation_code_with_args("src/current/AsyncSwap.huff");
        bytes memory routerCode = HuffNeoDeployer.config()
            .with_args(abi.encode(manager, hook, address(0), routerMevTaxGas))
            .creation_code_with_args("src/current/Router.huff");
        // EIP-3860 counts constructor arguments as part of initcode.
        assertLe(hookCode.length, 49_152, "hook initcode exceeds EIP-3860");
        assertLe(routerCode.length, 49_152, "Router initcode exceeds EIP-3860");
    }

    function test_deployedRuntimesIncludeImmutables() public view {
        // hnc checks MAIN; the deployed hook also appends seven immutable words.
        console2.log("Current Huff hook runtime", address(hook).code.length);
        console2.log("Current Huff Router runtime", address(router).code.length);
        assertLe(address(hook).code.length, 24_576, "hook including immutables exceeds EIP-170");
        assertLe(address(router).code.length, 24_576, "Router including immutables exceeds EIP-170");
    }
}
