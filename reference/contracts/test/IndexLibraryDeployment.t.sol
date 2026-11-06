// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployTickBitmap} from "../script/00_DeployTickBitmap.s.sol";
import {DeployEligiblePrice} from "../script/00_DeployEligiblePrice.s.sol";
import {TickBitmap} from "@async-swap/libraries/TickBitmap.sol";
import {EligiblePrice} from "@async-swap/libraries/EligiblePrice.sol";

import {DeployPriorityFeeUpdates} from "../script/00_DeployPriorityFeeUpdates.s.sol";
import {PriorityFeeUpdates} from "@async-swap/libraries/PriorityFeeUpdates.sol";

/// @dev Test stand-in for the deterministic proxy's salt || initcode calldata format.
contract IndexCreate2Proxy {
    fallback() external payable {
        bytes32 salt = bytes32(msg.data[:32]);
        bytes memory initcode = msg.data[32:];
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(callvalue(), add(initcode, 32), mload(initcode), salt)
        }
        require(deployed != address(0), "CREATE2 failed");
    }
}

contract IndexLibraryDeploymentTest is Test {
    address constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function setUp() public {
        vm.etch(FACTORY, type(IndexCreate2Proxy).runtimeCode);
    }

    function test_bitmapPredictionAndIdempotentDryRun() public {
        DeployTickBitmap script = new DeployTickBitmap();
        string memory previous = vm.envOr("DEPLOY_DRY_RUN", string("false"));
        vm.setEnv("DEPLOY_DRY_RUN", "true");
        address target = script.predicted();
        script.run();
        assertEq(target.code.length, type(TickBitmap).runtimeCode.length);
        assertLe(target.code.length, 24_576);
        bytes32 hash = target.codehash;
        script.run();
        assertEq(target.codehash, hash, "existing library preserved");
        vm.setEnv("DEPLOY_DRY_RUN", previous);
    }

    function test_eligiblePredictionAndIdempotentDryRun() public {
        DeployEligiblePrice script = new DeployEligiblePrice();
        string memory previous = vm.envOr("DEPLOY_DRY_RUN", string("false"));
        vm.setEnv("DEPLOY_DRY_RUN", "true");
        address target = script.predicted();
        script.run();
        assertEq(target.code.length, type(EligiblePrice).runtimeCode.length);
        assertLe(target.code.length, 24_576);
        bytes32 hash = target.codehash;
        script.run();
        assertEq(target.codehash, hash, "existing library preserved");
        vm.setEnv("DEPLOY_DRY_RUN", previous);
    }

    function test_topUpPredictionAndIdempotentDryRun() public {
        DeployPriorityFeeUpdates script = new DeployPriorityFeeUpdates();
        string memory previous = vm.envOr("DEPLOY_DRY_RUN", string("false"));
        vm.setEnv("DEPLOY_DRY_RUN", "true");
        address target = script.predicted();
        script.run();
        assertEq(target.code.length, type(PriorityFeeUpdates).runtimeCode.length);
        assertLe(target.code.length, 24_576);
        bytes32 hash = target.codehash;
        script.run();
        assertEq(target.codehash, hash, "existing library preserved");
        vm.setEnv("DEPLOY_DRY_RUN", previous);
    }

    function test_missingFactoryRejected() public {
        vm.etch(FACTORY, "");
        DeployTickBitmap bitmap = new DeployTickBitmap();
        DeployEligiblePrice eligible = new DeployEligiblePrice();
        DeployPriorityFeeUpdates topup = new DeployPriorityFeeUpdates();
        vm.expectRevert("CREATE2 deployer missing on this chain");
        bitmap.run();
        vm.expectRevert("CREATE2 deployer missing on this chain");
        eligible.run();
        vm.expectRevert("CREATE2 deployer missing on this chain");
        topup.run();
    }
}
