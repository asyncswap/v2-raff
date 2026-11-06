// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployIncomingMatchingLibrary} from "../script/00_DeployIncomingMatching.s.sol";

/// @dev Same salt+initcode CREATE2 interface as the deployment proxy, installed only in a test VM.
contract IncomingCreate2FactoryFixture {
    fallback() external payable {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            let size := sub(calldatasize(), 32)
            calldatacopy(ptr, 32, size)
            let deployed := create2(callvalue(), ptr, size, calldataload(0))
            if iszero(deployed) { revert(0, 0) }
            mstore(ptr, deployed)
            return(add(ptr, 12), 20)
        }
    }
}

contract IncomingLibraryDeploymentTest is Test {
    address constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function test_deterministicDeploymentAndIdempotentRerun() public {
        vm.chainId(31337);
        vm.etch(FACTORY, address(new IncomingCreate2FactoryFixture()).code);
        DeployIncomingMatchingLibrary script = new DeployIncomingMatchingLibrary();
        address predicted = script.predicted();
        assertEq(predicted.code.length, 0);
        bool previousDryRun = vm.envOr("DEPLOY_DRY_RUN", false);
        vm.setEnv("DEPLOY_DRY_RUN", "true");
        script.run();
        assertGt(predicted.code.length, 0);
        bytes32 codeHash = predicted.codehash;
        script.run();
        vm.setEnv("DEPLOY_DRY_RUN", previousDryRun ? "true" : "false");
        assertEq(script.predicted(), predicted);
        assertEq(predicted.codehash, codeHash, "repeat run must preserve deployed code");
        (bool ok, bytes memory result) = predicted.staticcall(abi.encodeWithSignature("pending(bytes32)", bytes32(0)));
        assertTrue(ok, "deployed library dispatcher is callable");
        assertFalse(abi.decode(result, (bool)));
    }
}
