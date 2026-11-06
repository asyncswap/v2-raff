// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PocSignedBase} from "./PocSignedBase.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {Router} from "@async-swap/Router.sol";
import {OrderSignatures} from "@async-swap/libraries/OrderSignatures.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";

/// @notice Regression for M-01 (audit/lsp_security_review_2026-11-01.md). `Router.swapWithSig` used to skip a signed
///         SetExecutor grant when the Router was already an executor, leaving its nonce live: anyone could replay it
///         from public calldata after the maker revoked the Router. A supplied grant is now always applied, so its
///         nonce is spent and a revocation stands.
contract GrantReplayPoc is PocSignedBase {
    uint256 constant GRANT_NONCE = 5;

    function _relaySignedCreate(Router.ExecutorGrant memory grant) internal returns (AsyncOrder memory order) {
        order = _signedOrder(AMOUNT_OUT_MIN);
        Router.PermitData memory permit = _permit(order, 0, block.timestamp + 1 hours);
        vm.prank(relayer);
        router.swapWithSig(order, permit, grant);
        order.salt = _expectedSalt(maker, AMOUNT_IN, AMOUNT_OUT_MIN);
    }

    /// The trusted Router can't be revoked, so the grant can't be replayed to undo a revocation; it is still spent.
    function _assertRevocationStands(Router.ExecutorGrant memory grant, AsyncOrder memory order) internal {
        vm.prank(maker);
        vm.expectRevert(AsyncSwap.CannotRevokeTrustedRouter.selector);
        hook.setExecutor(poolId, address(router), false);

        vm.warp(block.timestamp + 1 days);
        vm.prank(attacker);
        vm.expectRevert(AsyncSwap.NonceAlreadyUsed.selector);
        hook.setExecutorWithSig(key, maker, address(router), true, grant.nonce, grant.deadline, grant.signature);
        assertTrue(hook.isExecutor(poolId, maker, address(router)), "router stays authorized");

        (uint256 live,) = hook.asyncOrderInfo(poolId, _id(order));
        assertEq(live, AMOUNT_IN, "the maker's order is untouched");
    }

    /// The case M-01 exploited: the Router was already authorized, yet the supplied grant is still spent.
    function test_grantSpentEvenWhenRouterAlreadyExecutor() public {
        vm.prank(maker);
        hook.setExecutor(poolId, address(router), true);

        Router.ExecutorGrant memory grant = _grant(GRANT_NONCE, block.timestamp + 7 days);
        AsyncOrder memory order = _relaySignedCreate(grant);
        assertTrue(hook.nonceUsed(maker, GRANT_NONCE), "grant spent although the Router was already an executor");

        _assertRevocationStands(grant, order);
    }

    /// The Router was not yet authorized: the grant authorizes it and is spent, as before the fix.
    function test_grantSpentWhenRouterNotYetExecutor() public {
        Router.ExecutorGrant memory grant = _grant(GRANT_NONCE, block.timestamp + 7 days);
        AsyncOrder memory order = _relaySignedCreate(grant);
        assertTrue(hook.nonceUsed(maker, GRANT_NONCE), "grant consumed");

        _assertRevocationStands(grant, order);
    }

    /// A signed revocation of the trusted Router is rejected too, and its nonce stays unspent.
    function test_RevertWhen_SignedRevocationOfTrustedRouter() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 structHash = OrderSignatures.hashSetExecutor(key, maker, address(router), false, GRANT_NONCE, deadline);
        bytes memory signature = _sign(_digest(hook.DOMAIN_SEPARATOR(), structHash));

        vm.prank(attacker);
        vm.expectRevert(AsyncSwap.CannotRevokeTrustedRouter.selector);
        hook.setExecutorWithSig(key, maker, address(router), false, GRANT_NONCE, deadline, signature);
        assertFalse(hook.nonceUsed(maker, GRANT_NONCE), "nonce not spent");
    }
}
