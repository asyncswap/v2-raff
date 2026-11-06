// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Vm} from "forge-std/Vm.sol";

/// @dev Fixture adapter: inspect/seed Huff's transient lock in the same transaction.
/// Restoring runtime before returning also permits observations during a recipient callback.
library TransientStorage {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function load(address target, bytes32 slot) internal returns (bytes32 value) {
        bytes memory code = target.code;
        vm.etch(target, hex"6000355c60005260206000f3");
        (bool ok, bytes memory ret) = target.call(abi.encode(slot));
        require(ok, "transient read");
        value = abi.decode(ret, (bytes32));
        vm.etch(target, code);
    }

    function store(address target, bytes32 slot, bytes32 value) internal {
        bytes memory code = target.code;
        vm.etch(target, hex"6020356000355d00");
        (bool ok,) = target.call(abi.encode(slot, value));
        require(ok, "transient write");
        vm.etch(target, code);
    }
}
