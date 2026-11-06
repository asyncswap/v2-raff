// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalSlotsB} from "./FormalSlotsB.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapDOMAIN_SEPARATOR.lean`.
contract AsyncSwapDOMAIN_SEPARATORFormalTest is FormalSlotsB {
    bytes32 constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev `domainSep env`: the cached separator when (self, chainid) match the cached values (deployment at the
    ///      hook address on chain 31337), else the rebuilt one. Both equal this formula with the current chainid.
    function _domainSep() internal view returns (bytes32) {
        return keccak256(abi.encode(TYPE_HASH, keccak256("AsyncSwap"), keccak256("1"), block.chainid, address(hook)));
    }

    function _call(address sender) internal returns (bool ok, bytes memory ret) {
        vm.prank(sender);
        (ok, ret) = address(hook).call(abi.encodeCall(AsyncSwap.DOMAIN_SEPARATOR, ()));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapDOMAIN_SEPARATOR.lean:29 — always succeeds, storage unchanged, returns
    ///         the cached or rebuilt EIP-712 domain separator.
    function testFuzz_DOMAIN_SEPARATOR_spec(address sender, uint64 chainId, bool sameChain) public {
        if (!sameChain) vm.chainId(chainId);
        vm.record();
        (bool ok, bytes memory ret) = _call(sender);
        assertTrue(ok);
        assertEq(abi.decode(ret, (bytes32)), _domainSep());
        _assertNoHookWrites();
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapDOMAIN_SEPARATOR.lean:40 — never reverts.
    function testFuzz_DOMAIN_SEPARATOR_never_reverts(address sender, uint64 chainId) public {
        vm.chainId(chainId);
        (bool ok,) = _call(sender);
        assertTrue(ok);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapDOMAIN_SEPARATOR.lean:45 — on success storage is unchanged and the
    ///         result is `domainSep env`.
    function testFuzz_DOMAIN_SEPARATOR_preserves(uint64 chainId, bool sameChain) public {
        if (!sameChain) vm.chainId(chainId);
        vm.record();
        bytes32 r = hook.DOMAIN_SEPARATOR();
        _assertNoHookWrites();
        assertEq(r, _domainSep());
    }
}
