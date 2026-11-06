// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {HookUnlockBase} from "./HookUnlockBase.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {MockERC20} from "../utils/MockERC20.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapCancelOrder.lean`.
contract AsyncSwapCancelOrderFormalTest is HookUnlockBase {
    using PoolIdLibrary for PoolKey;

    address carol = makeAddr("carol"); // executor alice authorises directly

    function setUp() public override {
        super.setUp();
        vm.prank(alice);
        hook.setExecutor(poolId, carol, true);
    }

    function _cancelAs(address caller, AsyncOrder memory order) internal {
        _run(_one(_cAs(caller, address(hook), abi.encodeCall(hook.cancelOrder, (order)))));
    }

    function _input(AsyncOrder memory order) internal view returns (MockERC20) {
        return order.zeroForOne ? token0 : token1;
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapCancelOrder.lean:74 — cancelOrder is exactly: NotAuthorizedExecutor unless sender = owner or owner's executor; else OrderNotFound if stored amountIn = 0; else the refund tail.
    function testFuzz_cancelOrder_run(uint8 callerKind, bool exists, bool zeroForOne, uint256 amountIn, uint256 fakeIn)
        public
    {
        amountIn = bound(amountIn, 1, 50 ether);
        (AsyncOrder memory order, bytes32 id) = _placeOrder(alice, zeroForOne, amountIn, 1 ether);
        if (!exists) order.salt = keccak256(abi.encode(order.salt));
        order.amountIn = fakeIn; // calldata amount is never used
        address caller = callerKind % 3 == 0 ? alice : callerKind % 3 == 1 ? carol : bob; // bob: unauthorised
        if (caller == bob) {
            vm.expectRevert(AsyncFiller.NotAuthorizedExecutor.selector);
            _cancelAs(caller, order);
            return;
        }
        if (!exists) {
            vm.expectRevert(AsyncFiller.OrderNotFound.selector);
            _cancelAs(caller, order);
            return;
        }
        MockERC20 input = _input(order);
        uint256 makerBefore = input.balanceOf(alice);
        uint256 claimsBefore = _claims(address(hook), Currency.wrap(address(input)));
        _cancelAs(caller, order);
        assertEq(input.balanceOf(alice) - makerBefore, amountIn, "owner refunded stored amountIn");
        assertEq(
            claimsBefore - _claims(address(hook), Currency.wrap(address(input))),
            amountIn + (zeroForOne ? 0 : 100_000),
            "claims burned"
        );
        assertEq(hook.asyncOrder(poolId, id), 0, "order cleared");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapCancelOrder.lean:101 — a caller that is neither owner nor the owner's executor reverts NotAuthorizedExecutor, whatever order it submits.
    function testFuzz_cancelOrder_unauthorized(address caller, bool exists, bytes32 salt) public {
        (AsyncOrder memory order,) = _placeOrder(alice, true, 1 ether, 1 ether);
        if (!exists) order.salt = salt;
        vm.assume(caller != alice && !hook.isExecutor(poolId, alice, caller));
        vm.expectRevert(AsyncFiller.NotAuthorizedExecutor.selector);
        _cancelAs(caller, order);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapCancelOrder.lean:108 — an authorised caller cancelling an order with no stored input reverts OrderNotFound.
    function testFuzz_cancelOrder_notFound(bool asOwner, bool zeroForOne, bytes32 salt, uint256 amountIn) public {
        AsyncOrder memory order = _orderFromMaker(alice, zeroForOne, amountIn, 1);
        order.salt = salt;
        vm.assume(hook.asyncOrder(poolId, _idOf(order)) == 0);
        vm.expectRevert(AsyncFiller.OrderNotFound.selector);
        _cancelAs(asOwner ? alice : carol, order);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapCancelOrder.lean:172 — a successful cancel was authorised, had stored amt != 0, burned amt input claims from the hook, paid the same amt of the same currency to order.owner (claims if native), and settled the escrowed bid.
    function testFuzz_cancelOrder_ok(uint256 amountIn, bool zeroForOne, bool asOwner, uint256 fakeIn) public {
        amountIn = bound(amountIn, 1, 50 ether);
        (AsyncOrder memory order, bytes32 id) = _placeOrder(alice, zeroForOne, amountIn, 1 ether);
        order.amountIn = fakeIn;
        MockERC20 input = _input(order);
        Currency inC = Currency.wrap(address(input));
        uint256 makerBefore = input.balanceOf(alice);
        uint256 callerBefore = input.balanceOf(carol);
        uint256 claimsBefore = _claims(address(hook), inC);
        uint256 pmBefore = input.balanceOf(address(manager));
        _cancelAs(asOwner ? alice : carol, order);
        assertEq(input.balanceOf(alice) - makerBefore, amountIn, "owner paid stored amountIn");
        assertEq(input.balanceOf(carol), callerBefore, "executor paid nothing");
        assertEq(
            claimsBefore - _claims(address(hook), inC),
            amountIn + (zeroForOne ? 0 : 100_000),
            "input and bid claims settled"
        );
        assertEq(pmBefore - input.balanceOf(address(manager)), amountIn, "only amt left the PoolManager");
        assertEq(hook.asyncOrder(poolId, id), 0, "order cleared");
        bytes32[5] memory w = _orderWords(poolId, id);
        for (uint256 i; i < 5; ++i) {
            assertEq(w[i], bytes32(0), "orders[id] := default");
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapCancelOrder.lean:172 — (native-input branch) the refund of a native-input order is minted as ERC-6909 claims (id 0) to order.owner.
    function testFuzz_cancelOrder_ok_nativeInput(uint256 amountIn) public {
        amountIn = bound(amountIn, 1, 50 ether);
        PoolKey memory nk = _initNativePool();
        vm.deal(alice, amountIn);
        vm.prank(alice);
        hook.setExecutor(nk.toId(), address(router), true);
        AsyncOrder memory order = AsyncOrder({
            key: nk,
            owner: alice,
            zeroForOne: true,
            amountIn: amountIn,
            amountOutMin: 1 ether,
            priorityFee: 100_000,
            sqrtPrice: uint160(2 ** 96),
            salt: bytes32(0)
        });
        vm.prank(alice);
        router.swap{value: amountIn}(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: alice, executor: address(router), amountOutMin: 1 ether, priorityFee: 100_000
                })
            )
        );
        order.salt = _saltOf(alice, amountIn, 1 ether, 100_000);
        Currency eth = Currency.wrap(address(0));
        uint256 hookBefore = _claims(address(hook), eth);
        uint256 ethBefore = alice.balance;
        _cancelAs(alice, order);
        assertEq(_claims(alice, eth), amountIn, "native refund minted as claims to owner");
        assertEq(alice.balance, ethBefore, "no ETH pushed to owner");
        assertEq(hookBefore - _claims(address(hook), eth), amountIn, "hook claims burned");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapCancelOrder.lean:172 — (bid branch) cancelling an order whose bid was escrowed settles exactly that bid (no active LP: forfeited to the FeeVault) besides refunding the stored input.
    function testFuzz_cancelOrder_ok_paidBid(uint256 bid, uint256 amountIn) public {
        bid = bound(bid, 100_000, 10 ether);
        amountIn = bound(amountIn, 1, 50 ether);
        AsyncOrder memory order = _orderFromMaker(alice, true, amountIn, 1 ether);
        order.priorityFee = bid;
        vm.prank(alice);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 1 ether, priorityFee: bid})
            )
        );
        order.salt = _saltOf(alice, amountIn, 1 ether, bid);
        bytes32 id = _idOf(order);
        assertEq(hook.asyncOrderPriorityFee(poolId, id), bid, "bid escrowed");
        address vault = address(hook.feeVault());
        uint256 vaultBefore = _claims(vault, currency1);
        uint256 hookNumBefore = _claims(address(hook), currency1);
        uint256 makerBefore = token0.balanceOf(alice);
        _cancelAs(alice, order);
        assertEq(_claims(vault, currency1) - vaultBefore, bid, "escrowed bid settled (forfeited)");
        assertEq(hookNumBefore - _claims(address(hook), currency1), bid, "bid claims left the hook");
        assertEq(token0.balanceOf(alice) - makerBefore, amountIn, "input refunded");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapCancelOrder.lean:215 — once orders[id] is cleared, cancelling the same order again reverts (OrderNotFound for an authorised caller; NotAuthorizedExecutor otherwise).
    function testFuzz_cancelOrder_reentry_reverts(uint8 callerKind, bool sameUnlock) public {
        (AsyncOrder memory order,) = _placeOrder(alice, true, 1 ether, 1 ether);
        address caller = callerKind % 3 == 0 ? alice : callerKind % 3 == 1 ? carol : bob;
        bytes memory data = abi.encodeCall(hook.cancelOrder, (order));
        if (sameUnlock) {
            Call[] memory cs = new Call[](2);
            cs[0] = _cAs(alice, address(hook), data);
            cs[1] = _cAs(caller, address(hook), data);
            vm.expectRevert(
                caller == bob ? AsyncFiller.NotAuthorizedExecutor.selector : AsyncFiller.OrderNotFound.selector
            );
            _run(cs);
        } else {
            _cancelAs(alice, order);
            vm.expectRevert(
                caller == bob ? AsyncFiller.NotAuthorizedExecutor.selector : AsyncFiller.OrderNotFound.selector
            );
            _cancelAs(caller, order);
        }
    }
}
