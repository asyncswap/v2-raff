// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {IPoolManager, SwapParams} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

/// @notice A custom executor that creates a sell order and, before settling its input, asks the hook to
///         match the book.
contract PendingOrderExecutor {
    using PoolIdLibrary for PoolKey;

    IPoolManager immutable pm;
    AsyncSwap immutable hook;
    PoolKey key;
    uint8 public matchedWhilePending;

    constructor(IPoolManager _pm, AsyncSwap _hook, PoolKey memory _key) {
        pm = _pm;
        hook = _hook;
        key = _key;
    }

    function place() external {
        hook.setExecutor(key.toId(), address(this), true);
        pm.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        pm.swap(
            key,
            SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1),
            abi.encode(
                AsyncSwap.UserParams({
                    user: address(this), executor: address(this), amountOutMin: 1 ether, priorityFee: 100_000
                })
            )
        );
        matchedWhilePending = hook.matchBook(key, 1);
        pm.sync(key.currency0);
        MockERC20(Currency.unwrap(key.currency0)).transfer(address(pm), 1 ether);
        pm.settle();
        pm.sync(key.currency1);
        MockERC20(Currency.unwrap(key.currency1)).transfer(address(pm), 100_000);
        pm.settleFor(address(hook));
        return "";
    }
}

/// @notice The Router acts on an order only in the state it checked: a fill re-validates the order
///         after pulling the filler's tokens, and a new order is not matchable until its input is
///         settled and the Router hands it to `matchNewOrder`.
contract RouterOrderWindowTest is SetupHook {
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
            salt: _expectedSalt(maker, amountIn, amountOutMin)
        });
    }

    function _submit(AsyncOrder memory order) internal {
        MockERC20 input = order.zeroForOne ? token0 : token1;
        vm.startPrank(order.owner);
        input.approve(address(router), order.amountIn + order.priorityFee);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: order.owner, executor: address(router), amountOutMin: order.amountOutMin, priorityFee: 100_000
                })
            )
        );
        vm.stopPrank();
    }

    /// The fill path reads the order, pulls the filler's ERC-20 (which runs token code), then executes:
    /// an order that reads differently after the pull is not filled.
    function test_RevertWhen_OrderChangesDuringFillPayment() public {
        AsyncOrder memory ask = _order(alice, true, 10 ether, 10 ether);
        _submit(ask);
        bytes32 id = _orderIdFor(alice, true, ask.salt);

        bytes[] memory reads = new bytes[](2);
        reads[0] = abi.encode(uint256(10 ether), uint256(10 ether)); // before the pull: as stored
        reads[1] = abi.encode(uint256(5 ether), uint256(10 ether)); // after the pull: shrunk
        vm.mockCalls(address(hook), abi.encodeCall(hook.asyncOrderInfo, (poolId, id)), reads);

        uint256 gross = 10 ether + hook.calculatePoolFee(key.fee, 10 ether);
        vm.startPrank(bob);
        token1.approve(address(router), gross);
        vm.expectRevert("Order changed during fill");
        router.fillOrder(ask, gross, "");
        vm.stopPrank();
    }

    /// An order created inside an unlock is not matched before its input is settled. Only the Router can create
    /// one, and it settles the input and hands the order to `matchNewOrder` in the same unlock; a custom executor
    /// that would call `matchBook` in between can't open the order at all.
    function test_pendingOrder_notMatchableBeforeInputSettled() public {
        _submit(_order(alice, true, 5 ether, 50 ether)); // unrelated ask: the PoolManager holds token0
        _submit(_order(bob, false, 1 ether, 1 ether)); // resting bid that the new ask crosses

        PendingOrderExecutor executor = new PendingOrderExecutor(manager, hook, key);
        topUp(address(executor), 10 ether);
        vm.expectRevert(_notTrustedRouter());
        executor.place();
    }
}
