// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "v4-core/types/Currency.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {IAsyncSwap} from "./utils/IAsyncSwap.sol";
import {IRouter} from "./utils/IRouter.sol";
import {AsyncOrder, AsyncOrderLibrary} from "./reference/AsyncOrder.sol";
import {OrderSignatures} from "./reference/OrderSignatures.sol";
import {ISignatureTransfer} from "./reference/ISignatureTransfer.sol";

/// @dev Signed actions. Spec: `AsyncSwapSpec/Admin.lean` (`verify_no_replay`, `verify_respects_deadline`,
///      `nonce_monotone`), `Hashing.lean` (witness binding, domain separation),
///      `AsyncSwapProtocol/Model.lean` (`swapWithSig`, `cancelWithSig`, `updatePriceWithSig`).
contract SignaturesTest is BaseTest {
    using AsyncOrderLibrary for AsyncOrder;

    address relayer = makeAddr("relayer");

    function test_setExecutorWithSig() public {
        address executor = makeAddr("executor");
        bytes memory sig = _sign(
            makerPk, _hookDigest(OrderSignatures.hashSetExecutor(key, maker, executor, true, 1, block.timestamp + 1))
        );
        vm.prank(relayer);
        hook.setExecutorWithSig(key, maker, executor, true, 1, block.timestamp + 1, sig);
        assertTrue(hook.isExecutor(key, maker, executor));
        assertTrue(hook.nonceUsed(maker, 1));

        // replay
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IAsyncSwap.NonceAlreadyUsed.selector, maker, 1));
        hook.setExecutorWithSig(key, maker, executor, true, 1, block.timestamp + 1, sig);

        // wrong signer
        bytes memory bad = _sign(
            maker2Pk, _hookDigest(OrderSignatures.hashSetExecutor(key, maker, executor, true, 2, block.timestamp + 1))
        );
        vm.expectRevert(IAsyncSwap.InvalidSignature.selector);
        hook.setExecutorWithSig(key, maker, executor, true, 2, block.timestamp + 1, bad);

        // expired
        bytes memory late = _sign(
            makerPk, _hookDigest(OrderSignatures.hashSetExecutor(key, maker, executor, true, 3, block.timestamp - 1))
        );
        vm.expectRevert(abi.encodeWithSelector(IAsyncSwap.SignatureExpired.selector, block.timestamp - 1));
        hook.setExecutorWithSig(key, maker, executor, true, 3, block.timestamp - 1, late);
    }

    function test_invalidateNonce() public {
        vm.prank(maker);
        hook.invalidateNonce(9);
        bytes memory sig = _sign(
            makerPk, _hookDigest(OrderSignatures.hashSetExecutor(key, maker, relayer, true, 9, block.timestamp + 1))
        );
        vm.expectRevert(abi.encodeWithSelector(IAsyncSwap.NonceAlreadyUsed.selector, maker, 9));
        hook.setExecutorWithSig(key, maker, relayer, true, 9, block.timestamp + 1, sig);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(IAsyncSwap.NonceAlreadyUsed.selector, maker, 9));
        hook.invalidateNonce(9);
    }

    /// `hashUpdatePrice_inj`: bound to the stored input; a different amount is a different message.
    function test_updatePriceWithSig() public {
        AsyncOrder memory s = _sell(key, maker, 1e18, 2e18, 0);
        bytes32 id = _place(s);
        bytes32 structHash = OrderSignatures.hashUpdatePrice(key, maker, true, 1e18, 3e18, id, 5, block.timestamp + 1);
        bytes memory sig = _sign(makerPk, _hookDigest(structHash));
        vm.prank(relayer);
        hook.updatePriceWithSig(key, id, 3e18, 5, block.timestamp + 1, sig);
        assertEq(hook.getOrder(key, id).amountOutMin, 3e18);

        // the same signature cannot reprice to something else
        bytes32 other = OrderSignatures.hashUpdatePrice(key, maker, true, 1e18, 4e18, id, 6, block.timestamp + 1);
        bytes memory wrongUse = _sign(makerPk, _hookDigest(other));
        vm.expectRevert(IAsyncSwap.InvalidSignature.selector);
        hook.updatePriceWithSig(key, id, 5e18, 6, block.timestamp + 1, wrongUse);
    }

    /// `cancelWithSig_requires_sig`, `cancelWithSig_no_replay`, `digest_ne_of_contract` (router domain only).
    function test_cancelWithSig() public {
        AsyncOrder memory s = _sell(key, maker, 1e18, 2e18, 0);
        bytes32 id = _place(s);
        bytes32 structHash = OrderSignatures.hashCancel(key, maker, true, 1e18, id, 1, block.timestamp + 1);

        // a signature in the hook's domain is not valid for the router
        bytes memory hookDomain = _sign(makerPk, _hookDigest(structHash));
        vm.prank(relayer);
        vm.expectRevert(IRouter.InvalidSignature.selector);
        router.cancelWithSig(s, 1, block.timestamp + 1, hookDomain);

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _routerDomain(), structHash));
        bytes memory sig = _sign(makerPk, digest);
        uint256 maker0 = _bal(currency0, maker);
        vm.prank(relayer);
        // the nonce was burned by the failed attempt above? No: the router checks the signature after burning
        // its nonce, and the revert rolled that back.
        uint256 refund = router.cancelWithSig(s, 1, block.timestamp + 1, sig);
        assertEq(refund, 1e18);
        assertEq(_bal(currency0, maker), maker0 + 1e18);
        assertTrue(router.cancelNonceUsed(maker, 1));

        // no replay (the order is gone and the nonce is burned)
        vm.prank(relayer);
        vm.expectRevert();
        router.cancelWithSig(s, 1, block.timestamp + 1, sig);
    }

    /// `routerPermit_inj`: the Permit2 message fixes token, amount, spender, nonce, deadline and the order
    /// witness; a relayer cannot substitute any of them. The signed executor grant is applied first.
    function test_swapWithSig_permit2() public {
        AsyncOrder memory s = _sell(key, maker3, 1e18, 2e18, 0);
        vm.prank(maker3);
        hook.setExecutor(key, address(router), false); // the grant comes with the signature

        uint256 deadline = block.timestamp + 1;
        IRouter.PermitData memory permit = IRouter.PermitData(11, deadline, _permitSig(maker3Pk, s, 11, deadline));
        IRouter.ExecutorGrant memory grant = IRouter.ExecutorGrant(
            true,
            12,
            deadline,
            _sign(
                maker3Pk, _hookDigest(OrderSignatures.hashSetExecutor(key, maker3, address(router), true, 12, deadline))
            )
        );

        uint256 maker0 = _bal(currency0, maker3);
        vm.prank(relayer);
        bytes32 id = router.swapWithSig(s, permit, grant);
        assertTrue(_open(key, id));
        assertEq(_bal(currency0, maker3), maker0 - 1e18);
        assertEq(_claims(currency0, address(hook)), 1e18);
        assertTrue(hook.isExecutor(key, maker3, address(router)));

        // amount substitution fails: the witness and the permitted amount both change
        AsyncOrder memory bigger = _sell(key, maker3, 1e18, 2e18, 0); // a copy: `= s` would alias memory
        bigger.amountIn = 2e18;
        bigger.salt = bytes32(uint256(99));
        IRouter.PermitData memory permit2b = IRouter.PermitData(13, deadline, _permitSig(maker3Pk, s, 13, deadline));
        vm.prank(relayer);
        vm.expectRevert();
        router.swapWithSig(bigger, permit2b, IRouter.ExecutorGrant(false, 0, 0, ""));

        // salt is not covered by the witness: a second use with a new salt needs a new nonce, not a new signature
        AsyncOrder memory resalted = _sell(key, maker3, 1e18, 2e18, 0);
        resalted.salt = bytes32(uint256(5));
        IRouter.PermitData memory permitReplay = IRouter.PermitData(11, deadline, permit.signature);
        vm.prank(relayer);
        vm.expectRevert();
        router.swapWithSig(resalted, permitReplay, IRouter.ExecutorGrant(false, 0, 0, ""));
    }

    function test_swapWithSig_rejectsNativeInput() public {
        AsyncOrder memory s = _sell(nativeKey, maker, 1 ether, 2e18, 0);
        vm.prank(relayer);
        vm.expectRevert(IRouter.NativeInputNotSupported.selector);
        router.swapWithSig(s, IRouter.PermitData(1, block.timestamp + 1, ""), IRouter.ExecutorGrant(false, 0, 0, ""));
    }

    /* ─────────────────────────────────── helpers ─────────────────────────────────── */

    function _routerDomain() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("AsyncSwapRouter"),
                keccak256("2"),
                block.chainid,
                address(router)
            )
        );
    }

    /// Permit2's `hashWithWitness` for `PermitWitnessTransferFrom` with the IRouter as spender.
    function _permitSig(uint256 pk, AsyncOrder memory o, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 typeHash = keccak256(
            abi.encodePacked(
                "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,",
                OrderSignatures.permit2WitnessType()
            )
        );
        bytes32 tokenPermissions = keccak256(
            abi.encode(
                keccak256("TokenPermissions(address token,uint256 amount)"), Currency.unwrap(o.input()), o.amountIn
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(typeHash, tokenPermissions, address(router), nonce, deadline, OrderSignatures.hashOrder(o))
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", permit2.DOMAIN_SEPARATOR(), structHash));
        return _sign(pk, digest);
    }
}
