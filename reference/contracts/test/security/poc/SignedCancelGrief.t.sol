// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PocSignedBase} from "./PocSignedBase.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {Router} from "@async-swap/Router.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Regression for L-01 (audit/lsp_security_review_2026-11-01.md). Signed cancels and reprices used to commit to
///         the order's live `amountIn` (and reprices to its queue sequence), so one small crossing match before the
///         relayer submitted voided the signature and left the remainder live at its old price. A cancel now covers
///         whatever remains, and a reprice applies its signed price to the remainder.
contract SignedCancelGriefPoc is PocSignedBase {
    uint256 constant CANCEL_NONCE = 1;
    // Attacker's dust bid: buys 0.01 token0 at exactly the maker's limit (0.95).
    uint256 constant DUST_QUOTE = 0.0095 ether;
    uint256 constant DUST_ASSET = 0.01 ether;

    function _createSigned() internal returns (AsyncOrder memory order) {
        order = _signedOrder(AMOUNT_OUT_MIN);
        Router.PermitData memory permit = _permit(order, 0, block.timestamp + 1 hours);
        vm.prank(relayer);
        router.swapWithSig(order, permit, _grant(0, block.timestamp + 1 hours));
        order.salt = _expectedSalt(maker, AMOUNT_IN, AMOUNT_OUT_MIN);
    }

    function _dustMatch() internal {
        _submit(_plainOrder(attacker, false, DUST_QUOTE, DUST_ASSET, 0));
        (uint256 liveIn,) = hook.asyncOrderInfo(poolId, _id(_signedOrderWithSalt()));
        assertEq(liveIn, AMOUNT_IN - DUST_ASSET, "dust partially matched");
    }

    function _signedOrderWithSalt() internal view returns (AsyncOrder memory order) {
        order = _signedOrder(AMOUNT_OUT_MIN);
        order.salt = _expectedSalt(maker, AMOUNT_IN, AMOUNT_OUT_MIN);
    }

    function test_dustMatchNoLongerBreaksRelayedCancel() public {
        AsyncOrder memory order = _createSigned();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _cancelSig(order, CANCEL_NONCE, deadline);
        _dustMatch();

        uint256 before = token0.balanceOf(maker);
        vm.prank(relayer);
        router.cancelWithSig(order, CANCEL_NONCE, deadline, sig);
        assertTrue(hook.nonceUsed(maker, CANCEL_NONCE), "nonce spent");
        assertEq(hook.asyncOrder(poolId, _id(order)), 0, "the remainder is cancelled");
        assertEq(token0.balanceOf(maker) - before, AMOUNT_IN - DUST_ASSET, "the remainder is refunded");
    }

    /// A lower price: a partly filled sell has spent the matched share of its bid, below the floor for a higher one.
    function test_dustMatchNoLongerBreaksRelayedReprice() public {
        AsyncOrder memory order = _createSigned();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _repriceSig(order, AMOUNT_IN, 0.9 ether, 9, deadline);
        _dustMatch();

        vm.prank(relayer);
        hook.updatePriceWithSig(order, AMOUNT_IN, 0.9 ether, 9, deadline, sig);
        (uint256 liveIn, uint256 liveMin) = hook.asyncOrderInfo(poolId, _id(order));
        assertEq(
            liveMin, Math.mulDiv(0.9 ether, liveIn, AMOUNT_IN, Math.Rounding.Ceil), "signed price on the remainder"
        );
    }

    /// The reprice count, not the queue sequence, versions the price: a reprice signed earlier cannot undo a later one.
    function test_staleRepriceCannotUndoALaterOne() public {
        AsyncOrder memory order = _createSigned();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory first = _repriceSig(order, AMOUNT_IN, 1.2 ether, 9, deadline);
        bytes memory second = _repriceSig(order, AMOUNT_IN, 1.3 ether, 10, deadline);

        hook.updatePriceWithSig(order, AMOUNT_IN, 1.3 ether, 10, deadline, second);
        assertEq(hook.orderReprices(poolId, _id(order)), 1);
        vm.expectRevert(AsyncSwap.InvalidSignature.selector);
        hook.updatePriceWithSig(order, AMOUNT_IN, 1.2 ether, 9, deadline, first);
        (, uint256 liveMin) = hook.asyncOrderInfo(poolId, _id(order));
        assertEq(liveMin, 1.3 ether, "the later reprice stands");
    }

    /// A reprice cannot be applied to a larger order than the one signed.
    function test_repriceRejectsSignedSizeBelowTheOrder() public {
        AsyncOrder memory order = _createSigned();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _repriceSig(order, AMOUNT_IN / 2, 0.6 ether, 9, deadline);
        vm.expectRevert(AsyncSwap.InvalidSignature.selector);
        hook.updatePriceWithSig(order, AMOUNT_IN / 2, 0.6 ether, 9, deadline, sig);
    }

    /// Control: no interference, the relayed cancel returns the full input.
    function test_control_cancelSucceedsWithoutInterference() public {
        AsyncOrder memory order = _createSigned();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _cancelSig(order, CANCEL_NONCE, deadline);
        uint256 before = token0.balanceOf(maker);
        vm.prank(relayer);
        router.cancelWithSig(order, CANCEL_NONCE, deadline, sig);
        emit log_named_uint("maker token0 refunded", token0.balanceOf(maker) - before);
        assertEq(token0.balanceOf(maker) - before, AMOUNT_IN);
    }
}
