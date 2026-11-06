// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "./SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @notice `Router.multicall` runs several Router actions as the caller in one atomic transaction. It replaces
///         the BatchActions, BatchCancels and BatchClaims contracts, without their executor and operator grants.
contract RouterMulticallTest is SetupHook {
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
        input.approve(address(router), type(uint256).max);
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

    function _cancel(AsyncOrder memory order) internal view returns (bytes memory) {
        return abi.encodeCall(router.cancelOrder, (order));
    }

    function test_cancelTwoOrdersInOneTransaction() public {
        AsyncOrder memory a = _order(alice, true, 1 ether, 2 ether);
        _submit(a);
        AsyncOrder memory b = _order(alice, true, 2 ether, 4 ether);
        _submit(b);
        uint256 before = token0.balanceOf(alice);

        bytes[] memory calls = new bytes[](2);
        calls[0] = _cancel(a);
        calls[1] = _cancel(b);
        vm.prank(alice);
        router.multicall(calls);

        assertEq(hook.asyncOrder(poolId, _id(a)), 0, "a cancelled");
        assertEq(hook.asyncOrder(poolId, _id(b)), 0, "b cancelled");
        assertEq(token0.balanceOf(alice) - before, 3 ether, "both inputs refunded");
    }

    /// A match pays alice in claims; she cancels her other order and withdraws those claims together.
    function test_cancelAndWithdrawClaimsInOneTransaction() public {
        _submit(_order(alice, true, 1 ether, 1 ether));
        _submit(_order(bob, false, 1 ether, 1 ether));
        uint256 claims = manager.balanceOf(alice, currency1.toId());
        assertEq(claims, 1 ether - Math.mulDiv(1 ether, 2, 10_000, Math.Rounding.Ceil), "alice paid in claims");

        AsyncOrder memory open = _order(alice, true, 2 ether, 4 ether);
        _submit(open);
        Currency[] memory currencies = new Currency[](1);
        currencies[0] = currency1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = claims;
        uint256 before0 = token0.balanceOf(alice);
        uint256 before1 = token1.balanceOf(alice);

        bytes[] memory calls = new bytes[](2);
        calls[0] = _cancel(open);
        calls[1] = abi.encodeCall(router.withdrawClaims, (currencies, amounts));
        vm.startPrank(alice);
        manager.approve(address(router), currency1.toId(), claims); // exact allowance, no operator grant
        router.multicall(calls);
        vm.stopPrank();

        assertEq(hook.asyncOrder(poolId, _id(open)), 0, "order cancelled");
        assertEq(token0.balanceOf(alice) - before0, 2 ether, "input refunded");
        assertEq(manager.balanceOf(alice, currency1.toId()), 0, "claims burned");
        assertEq(token1.balanceOf(alice) - before1, claims, "claims paid out");
    }

    /// Each call runs as the caller, so another maker's order in the batch reverts the whole batch.
    function test_RevertWhen_BatchIncludesAnotherMakersOrder() public {
        AsyncOrder memory mine = _order(alice, true, 1 ether, 2 ether);
        _submit(mine);
        AsyncOrder memory theirs = _order(bob, true, 1 ether, 3 ether);
        _submit(theirs);

        bytes[] memory calls = new bytes[](2);
        calls[0] = _cancel(mine);
        calls[1] = _cancel(theirs);
        vm.prank(alice);
        vm.expectRevert("Only owner can cancel");
        router.multicall(calls);

        assertEq(hook.asyncOrder(poolId, _id(mine)), 1 ether, "the first cancel rolled back");
        assertEq(hook.asyncOrder(poolId, _id(theirs)), 1 ether, "bob's order untouched");
    }

    function test_RevertWhen_OneCallFails_wholeBatchRollsBack() public {
        AsyncOrder memory a = _order(alice, true, 1 ether, 2 ether);
        _submit(a);

        bytes[] memory calls = new bytes[](2);
        calls[0] = _cancel(a);
        calls[1] = _cancel(a); // already closed by the first call
        vm.prank(alice);
        vm.expectRevert();
        router.multicall(calls);
        assertEq(hook.asyncOrder(poolId, _id(a)), 1 ether, "the first cancel rolled back");
    }

    /// Not payable: one `msg.value` can never be counted by several native-value calls.
    function test_RevertWhen_MulticallSentEth() public {
        vm.deal(alice, 1 ether);
        bytes[] memory calls = new bytes[](0);
        vm.prank(alice);
        (bool ok,) = address(router).call{value: 1 ether}(abi.encodeCall(router.multicall, (calls)));
        assertFalse(ok, "multicall rejects ETH");
    }

    /// The filler's price cap is per call: a high cap on the first fill does not carry over to the second.
    function test_maxPriceDoesNotCarryAcrossCalls() public {
        AsyncOrder memory cheap = _order(alice, true, 1 ether, 1 ether);
        _submit(cheap);
        AsyncOrder memory dear = _order(alice, true, 1 ether, 3 ether);
        _submit(dear);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(router.fillOrder, (cheap, type(uint256).max, ""));
        calls[1] = abi.encodeCall(router.fillOrder, (dear, 2 ether, ""));
        vm.prank(bob);
        vm.expectRevert("Price exceeds maxPrice");
        router.multicall(calls);

        calls[1] = abi.encodeCall(router.fillOrder, (dear, 3 ether, ""));
        vm.prank(bob);
        router.multicall(calls);
        assertEq(hook.asyncOrder(poolId, _id(cheap)), 0, "cheap filled");
        assertEq(hook.asyncOrder(poolId, _id(dear)), 0, "dear filled");
    }

    /// A maker places an order and fills another in one transaction; each call sets its own caller slots.
    function test_swapThenFillInOneTransaction() public {
        AsyncOrder memory ask = _order(alice, true, 1 ether, 1 ether);
        _submit(ask);
        AsyncOrder memory bid = _order(bob, false, 1 ether, 0.5 ether);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(router.fillOrder, (ask, type(uint256).max, ""));
        calls[1] = abi.encodeCall(
            router.swap,
            (bid, abi.encode(AsyncSwap.UserParams(bob, address(router), bid.amountOutMin, bid.priorityFee)))
        );
        vm.startPrank(bob);
        token1.approve(address(router), type(uint256).max);
        router.multicall(calls);
        vm.stopPrank();

        assertEq(hook.asyncOrder(poolId, _id(ask)), 0, "ask filled by bob");
        assertEq(hook.asyncOrder(poolId, _id(bid)), 1 ether, "bob's bid rests as his own order");
        (address maker,,,,,,) = hook.orderBookOrder(poolId, _id(bid));
        assertEq(maker, bob, "the swap ran as bob");
    }
}
