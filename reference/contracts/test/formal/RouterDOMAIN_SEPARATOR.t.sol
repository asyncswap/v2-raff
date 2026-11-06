// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalProbesA} from "./FormalProbesA.sol";
import {Router} from "@async-swap/Router.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/RouterDOMAIN_SEPARATOR.lean`.
contract RouterDOMAIN_SEPARATORFormalTest is FormalProbesA {
    /// @notice formal/Refinement/Swarm/RouterDOMAIN_SEPARATOR.lean:29 — `DOMAIN_SEPARATOR` succeeds, leaves
    ///         storage unchanged and returns the EIP-712 separator (cached on the deploy chain, else rebuilt
    ///         as `keccak256(abi.encode(TYPE_HASH, hashedName, hashedVersion, chainid, this))`).
    function testFuzz_DOMAIN_SEPARATOR_spec(uint64 chainId, bool sameChain, address caller) public {
        if (!sameChain) vm.chainId(chainId);
        vm.record();
        vm.prank(caller);
        bytes32 got = router.DOMAIN_SEPARATOR();
        _assertNoWrites(address(router));
        assertEq(got, _routerDomainSeparator(), "domain separator");
    }

    /// @notice formal/Refinement/Swarm/RouterDOMAIN_SEPARATOR.lean:40 — `DOMAIN_SEPARATOR` never reverts.
    function testFuzz_DOMAIN_SEPARATOR_never_reverts(uint64 chainId, address caller, uint256 ts) public {
        vm.chainId(chainId);
        vm.warp(ts);
        vm.prank(caller);
        (bool ok,) = address(router).call(abi.encodeCall(Router.DOMAIN_SEPARATOR, ()));
        assertTrue(ok, "never reverts");
    }

    /// @notice formal/Refinement/Swarm/RouterDOMAIN_SEPARATOR.lean:45 — on success storage is unchanged and the
    ///         result is the domain separator.
    function testFuzz_DOMAIN_SEPARATOR_preserves(uint64 chainId, address caller) public {
        vm.chainId(chainId);
        bytes32 nameSlot = vm.load(address(router), bytes32(0));
        bytes32 versionSlot = vm.load(address(router), bytes32(uint256(1)));
        vm.record();
        vm.prank(caller);
        bytes32 got = router.DOMAIN_SEPARATOR();
        _assertNoWrites(address(router));
        assertEq(vm.load(address(router), bytes32(0)), nameSlot);
        assertEq(vm.load(address(router), bytes32(uint256(1))), versionSlot);
        assertEq(got, _routerDomainSeparator(), "result is the domain separator");
    }
}
