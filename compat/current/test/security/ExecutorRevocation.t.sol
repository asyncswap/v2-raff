// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {MockERC20} from "../utils/MockERC20.sol";

/// @notice Pins down that a maker can never revoke the trusted Router (so live orders always stay cancellable
///         and fillable through it), that other executors stay revocable, and that filling needs no grant from
///         the filler.
contract ExecutorRevocationTest is SetupHook {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        topUp(alice, 1_000 ether);
        topUp(bob, 1_000 ether);
    }

    function _order(address maker, bool zeroForOne, uint256 amountIn, uint256 amountOutMin)
        internal
        view
        returns (AsyncOrder memory)
    {
        return AsyncOrder({
            key: key,
            owner: maker,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            priorityFee: 100_000,
            sqrtPrice: 2 ** 96,
            salt: keccak256(
                abi.encode(block.timestamp, block.number, address(manager), maker, amountIn, amountOutMin, 100_000)
            )
        });
    }

    function _submit(AsyncOrder memory order) internal {
        MockERC20 input = order.zeroForOne ? token0 : token1;
        vm.startPrank(order.owner);
        input.approve(address(router), order.amountIn);
        token1.approve(address(router), order.amountIn + order.priorityFee);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: order.owner,
                    executor: address(router),
                    amountOutMin: order.amountOutMin,
                    priorityFee: order.priorityFee
                })
            )
        );
        vm.stopPrank();
    }

    function _id(AsyncOrder memory order) internal view returns (bytes32) {
        return _orderIdFor(order.owner, order.zeroForOne, order.salt);
    }

    function test_RevertWhen_MakerRevokesTrustedRouter() public {
        AsyncOrder memory ask = _order(alice, true, 1 ether, 1 ether);
        _submit(ask);

        vm.prank(alice);
        vm.expectRevert(AsyncSwap.CannotRevokeTrustedRouter.selector);
        hook.setExecutor(poolId, address(router), false);
        assertTrue(hook.isExecutor(poolId, alice, address(router)), "router still authorized");
    }

    /// Since the Router can't be revoked, the maker can always cancel a live order through it.
    function test_eoaCancelsThroughRouter() public {
        AsyncOrder memory ask = _order(alice, true, 1 ether, 1 ether);
        uint256 before = token0.balanceOf(alice);
        _submit(ask);

        vm.prank(alice);
        router.cancelOrder(ask);
        assertEq(hook.asyncOrder(poolId, _id(ask)), 0, "order cancelled");
        assertEq(token0.balanceOf(alice), before, "input refunded");
    }

    /// The Router still checks ownership: nobody else can cancel through it.
    function test_RevertWhen_NonOwnerCancelsThroughRouter() public {
        AsyncOrder memory ask = _order(alice, true, 1 ether, 1 ether);
        _submit(ask);

        vm.prank(bob);
        vm.expectRevert(bytes("Only owner can cancel"));
        router.cancelOrder(ask);
    }

    /// Other executors stay revocable, and a revoked one cannot cancel.
    function test_RevertWhen_RevokedOtherExecutorCancels() public {
        AsyncOrder memory ask = _order(alice, true, 1 ether, 1 ether);
        _submit(ask);
        vm.startPrank(alice);
        hook.setExecutor(poolId, bob, true);
        hook.setExecutor(poolId, bob, false);
        vm.stopPrank();
        assertFalse(hook.isExecutor(poolId, alice, bob), "bob revoked");

        vm.prank(bob);
        vm.expectRevert(AsyncFiller.NotAuthorizedExecutor.selector);
        hook.cancelOrder(ask);
    }

    /// Fillers need no grant of their own: the check is on the maker's grant to the Router.
    function test_fillerWithoutAnyGrantCanFill() public {
        AsyncOrder memory ask = _order(alice, true, 1 ether, 1 ether);
        _submit(ask);

        address carol = makeAddr("carol");
        token1.mint(carol, 2 ether);
        assertFalse(hook.isExecutor(poolId, carol, address(router)), "carol never granted anything");

        vm.startPrank(carol);
        token1.approve(address(router), type(uint256).max);
        router.fillOrder(ask, type(uint256).max, "");
        vm.stopPrank();
        assertEq(hook.asyncOrder(poolId, _id(ask)), 0, "carol filled");
        assertGt(token0.balanceOf(carol), 0, "carol received the maker's input");
    }
}
