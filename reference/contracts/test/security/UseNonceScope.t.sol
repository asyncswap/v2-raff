// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../SetupHook.t.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice `useNonce` burns a maker's nonce in the one space every signed action shares. Only the
///         Router, which verifies the maker's cancel signature, may burn it, with or without a grant. An
///         executor the maker approved, on any pool, must not.
contract UseNonceScopeTest is SetupHook {
    address alice = makeAddr("alice");
    address evil = makeAddr("evil-executor");

    function test_otherExecutorCannotBurnTheMakersNonce() public {
        PoolId otherPool = PoolId.wrap(keccak256("some other pool"));
        vm.prank(alice);
        hook.setExecutor(otherPool, evil, true);

        vm.prank(evil);
        vm.expectRevert(AsyncFiller.NotAuthorizedExecutor.selector);
        hook.useNonce(alice, 7);
        assertFalse(hook.nonceUsed(alice, 7), "the maker's signed actions stay valid");
    }

    function test_executorOnThisPoolCannotBurnTheMakersNonce() public {
        vm.prank(alice);
        hook.setExecutor(poolId, evil, true);

        vm.prank(evil);
        vm.expectRevert(AsyncFiller.NotAuthorizedExecutor.selector);
        hook.useNonce(alice, 7);
        assertFalse(hook.nonceUsed(alice, 7));
    }
}
