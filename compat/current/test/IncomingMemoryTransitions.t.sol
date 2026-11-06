// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CurrentHuffDeploy} from "compat/current/support/CurrentHuffDeploy.sol";

import {SetupHook} from "./SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {Router} from "@async-swap/Router.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {TopUpCallbackToken, TopUpPaymentProbe} from "./utils/TopUpCallbackToken.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {IPoolManager, ModifyLiquidityParams} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey, PoolIdLibrary} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

contract IncomingMutationProbe {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    enum Action {
        Liquidity,
        Reprice,
        Cancel
    }
    IPoolManager immutable manager;
    AsyncSwap immutable hook;
    PoolKey key;
    AsyncOrder target;
    Action action;
    bool public called;

    constructor(IPoolManager pm, AsyncSwap h, PoolKey memory k) {
        manager = pm;
        hook = h;
        key = k;
    }

    function arm(Action a, AsyncOrder memory order) external {
        action = a;
        target = order;
    }

    function onPayment() external {
        if (called) return;
        called = true;
        if (action == Action.Liquidity) {
            (BalanceDelta delta,) = manager.modifyLiquidity(key, ModifyLiquidityParams(-60, 60, 1e24, 0), "");
            _pay(key.currency0, uint256(-int256(delta.amount0())));
            _pay(key.currency1, uint256(-int256(delta.amount1())));
            // Restore the outer Router payment's sync point after the nested LP settlements.
            manager.sync(key.currency1);
        } else if (action == Action.Reprice) {
            hook.updatePrice(target, 3 ether);
        } else {
            hook.cancelOrder(target);
        }
        require(hook.matchBook(key, 8) == 0, "funding window became matchable");
    }

    function _pay(Currency currency, uint256 amount) private {
        manager.sync(currency);
        MockERC20(Currency.unwrap(currency)).transferFrom(address(this), address(manager), amount);
        manager.settle();
    }
}

contract IncomingBatchActor {
    using PoolIdLibrary for PoolKey;

    function run(Router router, AsyncSwap hook, PoolKey calldata key) external {
        hook.setExecutor(key.toId(), address(router), true);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(router), type(uint256).max);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(router), type(uint256).max);
        AsyncOrder memory order = AsyncOrder(key, address(this), false, 2 ether, 1 ether, 100_000, 2 ** 96, 0);
        bytes memory params = abi.encode(AsyncSwap.UserParams(address(this), address(router), 1 ether, 100_000));
        router.swap(order, params); // memory fill
        router.swap(order, params); // persistent arrival: no remaining opposite order
        order.zeroForOne = true;
        order.amountIn = 1 ether;
        order.amountOutMin = 2 ether;
        router.swap(order, abi.encode(AsyncSwap.UserParams(address(this), address(router), 2 ether, 100_000)));
    }
}

contract IncomingMemoryTransitionsTest is SetupHook {
    using StateLibrary for IPoolManager;

    function _place(address actor, bool sell, uint256 input, uint256 minimum, uint256 fee)
        private
        returns (AsyncOrder memory order)
    {
        order = AsyncOrder(key, actor, sell, input, minimum, fee, 2 ** 96, 0);
        vm.prank(actor);
        router.swap(order, abi.encode(AsyncSwap.UserParams(actor, address(router), minimum, fee)));
        order.salt = keccak256(abi.encode(block.timestamp, block.number, address(manager), actor, input, minimum, fee));
    }

    function _fundActor(address actor) private {
        topUp(actor, 1e25);
        vm.prank(actor);
        token0.approve(address(router), type(uint256).max);
    }

    function test_liquidityActivatedDuringFundingUsesBetterPool() public {
        address seller = address(0x92001);
        address buyer = address(0x92002);
        _fundActor(seller);
        _fundActor(buyer);
        AsyncOrder memory ask = _place(seller, true, 1 ether, 2 ether, 0);
        IncomingMutationProbe probe = new IncomingMutationProbe(manager, hook, key);
        _fundActor(address(probe));
        vm.startPrank(address(probe));
        token0.approve(address(probe), type(uint256).max);
        token1.approve(address(probe), type(uint256).max);
        vm.stopPrank();
        probe.arm(IncomingMutationProbe.Action.Liquidity, ask);
        TopUpCallbackToken token = new TopUpCallbackToken(TopUpPaymentProbe(address(probe)));
        vm.etch(address(token1), address(token).code);
        uint256 beforeAsset = token0.balanceOf(buyer);
        assertEq(manager.getLiquidity(poolId), 0);
        AsyncOrder memory bid = _place(buyer, false, 2 ether, 1 ether, 100_000);
        assertTrue(probe.called());
        assertGt(manager.getLiquidity(poolId), 0);
        assertGe(token0.balanceOf(buyer) - beforeAsset, 1 ether, "better LP venue pays output tokens");
        assertEq(hook.asyncOrder(poolId, _orderIdFor(buyer, false, bid.salt)), 0);
        bytes32 askId = _orderIdFor(seller, true, ask.salt);
        assertEq(hook.asyncOrder(poolId, askId), 1 ether, "worse resting ask remains untouched");
        assertEq(hook.orderCreatedSequence(poolId, askId), 1);
        assertEq(manager.balanceOf(address(hook.feeVault()), currency1.toId()), 2 ether / 10_000 + 100_000);
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 1 ether);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0);
    }

    function test_repriceDuringFundingRechecksOppositeOrder() public {
        _mutate(IncomingMutationProbe.Action.Reprice);
    }

    function test_cancelDuringFundingRechecksOppositeOrder() public {
        _mutate(IncomingMutationProbe.Action.Cancel);
    }

    function _mutate(IncomingMutationProbe.Action action) private {
        address buyer = address(0x92003);
        IncomingMutationProbe probe = new IncomingMutationProbe(manager, hook, key);
        _fundActor(address(probe));
        _fundActor(buyer);
        AsyncOrder memory ask = _place(address(probe), true, 1 ether, 2 ether, 0);
        probe.arm(action, ask);
        TopUpCallbackToken token = new TopUpCallbackToken(TopUpPaymentProbe(address(probe)));
        vm.etch(address(token1), address(token).code);
        AsyncOrder memory bid = _place(buyer, false, 2 ether, 1 ether, 100_000);
        assertTrue(probe.called());
        bytes32 bidId = _orderIdFor(buyer, false, bid.salt);
        assertEq(hook.asyncOrder(poolId, bidId), 2 ether, "stale crossing decision must not force a fill");
        assertEq(hook.orderCreatedSequence(poolId, bidId), 2, "funding callback does not reset arrival age");
        assertEq(hook.asyncOrderPriorityFee(poolId, bidId), 100_000);
        assertEq(manager.balanceOf(buyer, currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 2 ether + 100_000);
        bytes32 askId = _orderIdFor(address(probe), true, ask.salt);
        if (action == IncomingMutationProbe.Action.Cancel) {
            assertEq(hook.asyncOrder(poolId, askId), 0);
            assertEq(manager.balanceOf(address(hook), currency0.toId()), 0);
        } else {
            (, uint256 minimum) = hook.asyncOrderInfo(poolId, askId);
            assertEq(minimum, 3 ether);
            assertEq(manager.balanceOf(address(hook), currency0.toId()), 1 ether);
        }
    }

    function test_sequentialSwapsClearStageWithinOneOuterCall() public {
        address seller = address(0x92004);
        _fundActor(seller);
        _place(seller, true, 1 ether, 2 ether, 0);
        IncomingBatchActor actor = new IncomingBatchActor();
        _fundActor(address(actor));
        actor.run(router, hook, key);
        (bool bid,,,) = hook.bestOrder(poolId, true);
        (bool ask,,,) = hook.bestOrder(poolId, false);
        assertFalse(bid);
        assertFalse(ask);
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0);
        assertEq(manager.balanceOf(address(actor), currency0.toId()), 2 * (1 ether - 1 ether / 5000));
        assertEq(manager.balanceOf(address(actor), currency1.toId()), 2 ether - 2 ether / 5000);
    }
}

contract IncomingMemoryQuoteZeroTest is SetupHook {
    function _deployHook() internal override {
        vm.mockCall(Currency.unwrap(currency0), abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        CurrentHuffDeploy.hookTo(
            abi.encode(manager, currency0, address(this), address(router), uint256(0), type(uint8).max), _hookAddress()
        );
        hook = AsyncSwap(payable(_hookAddress()));
    }

    function test_quoteZeroPartialMemoryFillThenTopUp() public {
        address seller = address(0x93001);
        address buyer = address(0x93002);
        topUp(seller, 1e25);
        topUp(buyer, 1e25);
        vm.prank(seller);
        token0.approve(address(router), type(uint256).max);
        vm.prank(buyer);
        token0.approve(address(router), type(uint256).max);
        AsyncOrder memory ask = AsyncOrder(key, seller, false, 1 ether, 2_000e6, 100_000, 2 ** 96, 0);
        vm.prank(seller);
        router.swap(ask, abi.encode(AsyncSwap.UserParams(seller, address(router), 2_000e6, 100_000)));
        AsyncOrder memory bid = AsyncOrder(key, buyer, true, 4_000e6, 2 ether, 200_000, 2 ** 96, 0);
        vm.prank(buyer);
        router.swap(bid, abi.encode(AsyncSwap.UserParams(buyer, address(router), 2 ether, 200_000)));
        bid.salt = keccak256(
            abi.encode(
                block.timestamp,
                block.number,
                address(manager),
                buyer,
                uint256(4_000e6),
                uint256(2 ether),
                uint256(200_000)
            )
        );
        bytes32 id = _orderIdFor(buyer, true, bid.salt);
        (uint256 input, uint256 minimum) = hook.asyncOrderInfo(poolId, id);
        assertEq(input, 2_000e6);
        assertEq(minimum, 1 ether);
        assertEq(hook.asyncOrderPriorityFee(poolId, id), 100_000);
        assertEq(hook.orderCreatedSequence(poolId, id), 2);
        vm.prank(buyer);
        router.topUpPriorityFee(bid, 100_000);
        assertEq(hook.asyncOrderPriorityFee(poolId, id), 200_000);
        assertEq(hook.orderCreatedSequence(poolId, id), 2);
        assertEq(manager.balanceOf(buyer, currency1.toId()), 1 ether - 1 ether / 5000);
        assertEq(manager.balanceOf(seller, currency0.toId()), 2_000e6 - 2_000e6 / 5000);
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 2_000e6 + 200_000);
        assertEq(manager.balanceOf(address(hook.feeVault()), currency0.toId()), 2_000e6 / 5000 + 200_000);
        assertEq(manager.balanceOf(address(hook.feeVault()), currency1.toId()), 1 ether / 5000);
    }
}
