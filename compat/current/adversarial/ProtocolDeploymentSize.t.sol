// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SetupHook} from "../test/SetupHook.t.sol";

contract ProtocolDeploymentSizeTest is SetupHook {
    function test_protocolRuntimesRemainDeployable() public {
        address[3] memory modules = [address(hook), address(router), address(hook.feeVault())];
        string[3] memory names = [string("Async Swap hook"), "Router", "FeeVault"];
        for (uint256 i; i < modules.length; ++i) {
            uint256 size = modules[i].code.length;
            emit log_named_uint(names[i], size);
            assertGt(size, 0, "module actually deployed");
            assertLe(size, 24_576, "runtime exceeds EIP-170");
        }
    }
}
