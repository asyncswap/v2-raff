// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {IAsyncSwap} from "./utils/IAsyncSwap.sol";
import {IRouter} from "./utils/IRouter.sol";
import {AsyncOrder, AsyncOrderLibrary} from "./reference/AsyncOrder.sol";
import {AsyncFiller} from "./utils/IAsyncSwap.sol";
import {ProtocolFee} from "./reference/ProtocolFee.sol";

/// @dev Create / fill / cancel / native / admin. Spec: `AsyncSwapProtocol/V2/Model.lean`, `V2/Settlement.lean`
///      (`fill_settlement`, `cancel_settlement`, `redeem_settlement`), `AsyncSwapSpec/Book.lean`, `Admin.lean`.
contract LifecycleTest is BaseTest {
    using AsyncOrderLibrary for AsyncOrder;

    /* ───────────────────────────────────── create ───────────────────────────────────── */

    function test_create_escrowsInputAsClaims() public {
        AsyncOrder memory o = _sell(key, maker, 1e18, 2e18, 0);
        uint256 before = _bal(currency0, maker);
        bytes32 id = _place(o);

        assertEq(id, o.orderId());
        assertEq(_bal(currency0, maker), before - 1e18);
        assertEq(_claims(currency0, address(hook)), 1e18, "escrow is the hook's claim");
        AsyncFiller.OrderInfo memory info = hook.getOrder(key, id);
        assertEq(info.owner, maker);
        assertTrue(info.zeroForOne);
        assertEq(info.amountIn, 1e18);
        assertEq(info.amountOutMin, 2e18);
        assertEq(info.priceKey, 2e18);
        assertEq(info.sequence, 1);
        assertEq(hook.openOrders(key), 1);
        (bytes32 bestAsk, uint128 askKey) = hook.bestOrder(key, false);
        assertEq(bestAsk, id);
        assertEq(askKey, 2e18);
    }

    /// `created_order_escrowed`: the bid is the hook's numeraire claim as soon as the create unlock ends.
    function test_create_bidEscrowedInSameUnlock() public {
        AsyncOrder memory o = _sell(prioKey, maker, 1e18, 2e18, 5e6);
        uint256 before1 = _bal(currency1, maker);
        bytes32 id = _place(o);
        assertEq(_bal(currency1, maker), before1 - 5e6);
        assertEq(_claims(currency1, address(hook)), 5e6);
        assertEq(hook.getOrder(prioKey, id).priorityFee, 5e6);
    }

    function test_create_modeGuards() public {
        // FIFO book: no bids.
        vm.expectRevert();
        _place(_sell(key, maker, 1e18, 2e18, 5e6));
        // PriorityFee book: at least MIN_PRIORITY_FEE.
        vm.expectRevert();
        _place(_sell(prioKey, maker, 1e18, 2e18, 0));
        vm.expectRevert();
        _place(_sell(prioKey, maker, 1e18, 2e18, 99_999));
        _place(_sell(prioKey, maker, 1e18, 2e18, 100_000));
    }

    function test_create_requiresExecutorGrant() public {
        vm.prank(maker);
        hook.setExecutor(key, address(router), false);
        vm.expectRevert();
        _place(_sell(key, maker, 1e18, 2e18, 0));
    }

    function test_create_onlyOwnerSubmits() public {
        AsyncOrder memory o = _sell(key, maker, 1e18, 2e18, 0);
        vm.prank(maker2);
        vm.expectRevert(IRouter.NotOrderOwner.selector);
        router.swap(o);
    }

    function test_create_zeroAmountsRejected() public {
        vm.expectRevert();
        _place(_sell(key, maker, 0, 2e18, 0));
        vm.expectRevert();
        _place(_sell(key, maker, 1e18, 0, 0));
    }

    /// The salt collision walk: the same salt twice yields two distinct open orders.
    function test_create_saltCollisionWalk() public {
        AsyncOrder memory o = _order(key, maker, true, 1e18, 2e18, 0, bytes32(uint256(1)));
        bytes32 id1 = _place(o);
        bytes32 id2 = _place(o);
        assertNotEq(id1, id2);
        assertTrue(_open(key, id1) && _open(key, id2));
        assertEq(hook.openOrders(key), 2);
    }

    /* ────────────────────────────────────── fill ────────────────────────────────────── */

    /// `fill_settlement`, `fill_fee_is_30bps`, `fill_output_conserved`.
    function test_fill_settlement() public {
        AsyncOrder memory o = _sell(key, maker, 1e18, 2e18, 0);
        bytes32 id = _place(o);
        uint256 fee = ProtocolFee.poolFee(2e18);
        uint256 live = 2e18 + fee;

        uint256 maker1 = _bal(currency1, maker);
        uint256 filler0 = _bal(currency0, filler);
        uint256 filler1 = _bal(currency1, filler);

        (uint256 amountIn, uint256 amountOut, uint256 paidFee) = _fill(o, filler);
        assertEq(amountIn, 1e18);
        assertEq(amountOut, 2e18);
        assertEq(paidFee, fee);
        assertEq(fee, 3 * live / 1000, "30 bps of gross");

        assertEq(_bal(currency1, maker), maker1 + 2e18, "maker receives the stored minimum");
        assertEq(_bal(currency1, filler), filler1 - live, "filler pays live gross");
        assertEq(_bal(currency0, filler), filler0 + 1e18, "filler receives the escrow");
        assertEq(_claims(currency1, address(vault)), fee, "vault receives the fee as claims");
        assertEq(_claims(currency0, address(hook)), 0);
        assertEq(_bal(currency0, address(hook)), 0);
        assertEq(_bal(currency1, address(hook)), 0);
        assertFalse(_open(key, id));
        assertEq(hook.openOrders(key), 0);
    }

    /// `fillOrder_ignores_calldata_amounts`: a stale struct cannot underpay the maker.
    function test_fill_usesStoredTerms() public {
        AsyncOrder memory o = _sell(key, maker, 1e18, 2e18, 0);
        _place(o);
        AsyncOrder memory stale = o;
        stale.amountOutMin = 1; // not part of the id
        uint256 maker1 = _bal(currency1, maker);
        vm.prank(filler);
        router.fillOrder(stale, type(uint256).max);
        assertEq(_bal(currency1, maker), maker1 + 2e18);
    }

    function test_fill_respectsMaxPrice() public {
        AsyncOrder memory o = _sell(key, maker, 1e18, 2e18, 0);
        _place(o);
        uint256 live = ProtocolFee.gross(2e18);
        vm.prank(filler);
        vm.expectRevert(abi.encodeWithSelector(IRouter.PriceAboveMax.selector, live, live - 1));
        router.fillOrder(o, live - 1);
    }

    /// `fill_requires_grant`: a maker who revoked the router cannot be filled through it.
    function test_fill_requiresExecutorGrant() public {
        AsyncOrder memory o = _sell(key, maker, 1e18, 2e18, 0);
        _place(o);
        vm.prank(maker);
        hook.setExecutor(key, address(router), false);
        vm.prank(filler);
        vm.expectRevert();
        router.fillOrder(o, type(uint256).max);
    }

    /// `fill_closes`: a filled order cannot be filled or cancelled again.
    function test_fill_closes() public {
        AsyncOrder memory o = _sell(key, maker, 1e18, 2e18, 0);
        _place(o);
        _fill(o, filler);
        vm.prank(filler);
        vm.expectRevert();
        router.fillOrder(o, type(uint256).max);
        vm.prank(maker);
        vm.expectRevert();
        router.cancelOrder(o);
    }

    /// The bid of a filled order is donated to active LPs (pool reserves grow, hook claims fall), never refunded.
    function test_fill_donatesBid() public {
        AsyncOrder memory o = _sell(prioKey, maker, 1e18, 2e18, 5e6);
        _place(o);
        uint256 pm1 = _bal(currency1, address(manager));
        uint256 maker1 = _bal(currency1, maker);
        _fill(o, filler);
        assertEq(_claims(currency1, address(hook)), 0, "bid left the hook");
        assertEq(_bal(currency1, maker), maker1 + 2e18, "bid not refunded");
        // PoolManager keeps the bid (donated) plus the fee claim backing, minus nothing.
        assertEq(_bal(currency1, address(manager)), pm1 + ProtocolFee.poolFee(2e18) + 2e18 - 2e18);
    }

    /// With no liquidity the bid is forfeited to the vault.
    function test_fill_forfeitsBidWithoutLiquidity() public {
        AsyncOrder memory o = _sell(emptyKey, maker, 1e18, 2e18, 5e6);
        _place(o);
        _fill(o, filler);
        assertEq(_claims(currency1, address(vault)), ProtocolFee.poolFee(2e18) + 5e6);
        assertEq(_claims(currency1, address(hook)), 0);
    }

    /* ───────────────────────────────────── cancel ───────────────────────────────────── */

    /// `cancel_settlement`: exactly the remaining escrow back; the bid is settled, not refunded.
    function test_cancel_settlement() public {
        AsyncOrder memory o = _buy(prioKey, maker, 2e18, 1e18, 5e6);
        bytes32 id = _place(o);
        assertEq(_claims(currency1, address(hook)), 2e18 + 5e6);
        uint256 maker1 = _bal(currency1, maker);
        vm.prank(maker);
        uint256 refund = router.cancelOrder(o);
        assertEq(refund, 2e18);
        assertEq(_bal(currency1, maker), maker1 + 2e18);
        assertEq(_claims(currency1, address(hook)), 0);
        assertFalse(_open(prioKey, id));
        (bytes32 bestBid,) = hook.bestOrder(prioKey, true);
        assertEq(bestBid, bytes32(0));
    }

    function test_cancel_onlyOwner() public {
        AsyncOrder memory o = _sell(key, maker, 1e18, 2e18, 0);
        _place(o);
        vm.prank(maker2);
        vm.expectRevert(IRouter.NotOrderOwner.selector);
        router.cancelOrder(o);
    }

    /// `no_unauthorized_close`: neither fill nor cancel without the maker's grant, directly on the hook either.
    function test_cancel_directCallNeedsOwnerOrExecutor() public {
        AsyncOrder memory o = _sell(key, maker, 1e18, 2e18, 0);
        bytes32 id = _place(o);
        vm.prank(maker2);
        vm.expectRevert(IAsyncSwap.NotUnlocked.selector);
        hook.cancelOrder(key, id);
    }

    /* ───────────────────────────────────── native ───────────────────────────────────── */

    /// Native input: the escrow is native; a fill pays it to the filler as ERC-6909 claims of currency0,
    /// redeemable through `NativeClaims` (`redeem_settlement`).
    function test_native_input_fill_and_redeem() public {
        AsyncOrder memory o = _sell(nativeKey, maker, 1 ether, 2e18, 0);
        uint256 makerEth = maker.balance;
        bytes32 id = _place(o);
        assertEq(maker.balance, makerEth - 1 ether);
        assertEq(_claims(CurrencyLibrary.ADDRESS_ZERO, address(hook)), 1 ether);
        assertEq(address(router).balance, 0);

        uint256 maker1 = _bal(currency1, maker);
        _fill(o, filler);
        assertFalse(_open(nativeKey, id));
        assertEq(_bal(currency1, maker), maker1 + 2e18);
        assertEq(_claims(CurrencyLibrary.ADDRESS_ZERO, filler), 1 ether, "filler paid in native claims");
        assertEq(_claims(CurrencyLibrary.ADDRESS_ZERO, address(hook)), 0);

        address recipient = makeAddr("recipient");
        vm.startPrank(filler);
        manager.setOperator(address(nativeClaims), true);
        nativeClaims.redeem(1 ether, recipient);
        vm.stopPrank();
        assertEq(recipient.balance, 1 ether);
        assertEq(_claims(CurrencyLibrary.ADDRESS_ZERO, filler), 0);
    }

    /// Native output: the filler's `msg.value` is exactly the live price; the maker is paid in native claims;
    /// the fee is a native claim of the vault; the hook keeps no ETH (`fill_settlement`: hook balances untouched).
    function test_native_output_fill() public {
        AsyncOrder memory o = _buy(nativeKey, maker, 2e18, 1 ether, 0);
        bytes32 id = _place(o);
        uint256 fee = ProtocolFee.poolFee(1 ether);
        uint256 live = 1 ether + fee;

        vm.prank(filler);
        vm.expectRevert(abi.encodeWithSelector(IRouter.InvalidMsgValue.selector, live, live - 1));
        router.fillOrder{value: live - 1}(o, live);

        uint256 fillerEth = filler.balance;
        uint256 filler1 = _bal(currency1, filler);
        vm.prank(filler);
        router.fillOrder{value: live}(o, live);
        assertFalse(_open(nativeKey, id));
        assertEq(filler.balance, fillerEth - live);
        assertEq(_bal(currency1, filler), filler1 + 2e18);
        assertEq(_claims(CurrencyLibrary.ADDRESS_ZERO, maker), 1 ether);
        assertEq(_claims(CurrencyLibrary.ADDRESS_ZERO, address(vault)), fee);
        assertEq(address(hook).balance, 0);
        assertEq(hook.pendingNativeDeposit(), 0);
    }

    function test_native_cancel_refundsAsClaims() public {
        AsyncOrder memory o = _sell(nativeKey, maker, 1 ether, 2e18, 0);
        _place(o);
        vm.prank(maker);
        router.cancelOrder(o);
        assertEq(_claims(CurrencyLibrary.ADDRESS_ZERO, maker), 1 ether);
        assertEq(_claims(CurrencyLibrary.ADDRESS_ZERO, address(hook)), 0);
    }

    function test_native_swapRequiresExactValue() public {
        AsyncOrder memory o = _sell(nativeKey, maker, 1 ether, 2e18, 0);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(IRouter.InvalidMsgValue.selector, 1 ether, 0.5 ether));
        router.swap{value: 0.5 ether}(o);
        AsyncOrder memory e = _sell(key, maker, 1e18, 2e18, 0);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(IRouter.InvalidMsgValue.selector, 0, 1));
        router.swap{value: 1}(e);
    }

    /* ─────────────────────────────────────── admin ─────────────────────────────────────── */

    /// `collect_settlement`: owner-only; moves exactly the vault's claims; no order or hook claim touched.
    function test_feeVault_collect() public {
        AsyncOrder memory o = _sell(key, maker, 1e18, 2e18, 0);
        _place(o);
        _place(_sell(key, maker2, 1e18, 3e18, 0));
        _fill(o, filler);
        uint256 fee = ProtocolFee.poolFee(2e18);
        address recipient = makeAddr("treasury");

        vm.prank(filler);
        vm.expectRevert(IAsyncSwap.Unauthorized.selector);
        vault.collect(currency1, recipient);

        vm.prank(protocolOwner);
        uint256 collected = vault.collect(currency1, recipient);
        assertEq(collected, fee);
        assertEq(_bal(currency1, recipient), fee);
        assertEq(_claims(currency1, address(vault)), 0);
        assertEq(_claims(currency0, address(hook)), 1e18, "maker2's escrow untouched");
        assertEq(hook.openOrders(key), 1);
    }

    /// `owner_change_only_via_accept`, `transfer_requires_owner`, `accept_clears_pending`.
    function test_ownership_twoStep() public {
        address next = makeAddr("next");
        vm.prank(next);
        vm.expectRevert(IAsyncSwap.Unauthorized.selector);
        hook.transferOwnership(next);
        vm.prank(protocolOwner);
        vm.expectRevert(IAsyncSwap.ZeroAddress.selector);
        hook.transferOwnership(address(0));
        vm.prank(protocolOwner);
        hook.transferOwnership(next);
        assertEq(hook.owner(), protocolOwner, "nominating does not transfer control");
        vm.prank(maker);
        vm.expectRevert(IAsyncSwap.Unauthorized.selector);
        hook.acceptOwnership();
        vm.prank(next);
        hook.acceptOwnership();
        assertEq(hook.owner(), next);
        assertEq(hook.pendingOwner(), address(0));
    }

    /// `sweep_settlement`: moves only the hook's own balance, never claims.
    function test_sweep() public {
        _place(_sell(key, maker, 1e18, 2e18, 0));
        MockERC20(Currency.unwrap(currency0)).transfer(address(hook), 7e18);
        vm.prank(maker);
        vm.expectRevert(IAsyncSwap.Unauthorized.selector);
        hook.sweep(currency0, maker);
        address to = makeAddr("sweepTo");
        vm.prank(protocolOwner);
        uint256 swept = hook.sweep(currency0, to);
        assertEq(swept, 7e18);
        assertEq(_bal(currency0, to), 7e18);
        assertEq(_claims(currency0, address(hook)), 1e18, "escrow claims untouched");
    }

    function test_setOrderingMode_requiresEmptyBook() public {
        _place(_sell(key, maker, 1e18, 2e18, 0));
        vm.prank(protocolOwner);
        vm.expectRevert(AsyncFiller.BookNotEmpty.selector);
        hook.setOrderingMode(key, AsyncFiller.OrderingMode.PriorityFee);
        vm.prank(maker);
        vm.expectRevert(IAsyncSwap.Unauthorized.selector);
        hook.setOrderingMode(emptyKey, AsyncFiller.OrderingMode.FIFO);
        vm.prank(protocolOwner);
        hook.setOrderingMode(emptyKey, AsyncFiller.OrderingMode.FIFO);
        assertEq(uint8(hook.orderingMode(emptyKey)), uint8(AsyncFiller.OrderingMode.FIFO));
    }

    function test_router_rejectsForeignHook() public {
        AsyncOrder memory o = _sell(key, maker, 1e18, 2e18, 0);
        o.key.hooks = IHooks(address(0xdead));
        vm.prank(maker);
        vm.expectRevert(IRouter.WrongHook.selector);
        router.swap(o);
    }
}
