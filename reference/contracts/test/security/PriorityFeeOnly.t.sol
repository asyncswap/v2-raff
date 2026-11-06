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

/// @notice A custom executor that creates an order declaring a bid, and settles only the order's input.
contract BidSkippingExecutor {
    using PoolIdLibrary for PoolKey;

    IPoolManager immutable pm;
    AsyncSwap immutable hook;
    PoolKey key;

    constructor(IPoolManager _pm, AsyncSwap _hook, PoolKey memory _key) {
        pm = _pm;
        hook = _hook;
        key = _key;
    }

    function place(bool payBid) external {
        hook.setExecutor(key.toId(), address(this), true);
        pm.unlock(abi.encode(payBid));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        pm.swap(
            key,
            SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1),
            abi.encode(
                AsyncSwap.UserParams({
                    user: address(this), executor: address(this), amountOutMin: 1 ether, priorityFee: 100_000
                })
            )
        );
        pm.sync(key.currency0);
        MockERC20(Currency.unwrap(key.currency0)).transfer(address(pm), 1 ether);
        pm.settle();
        if (abi.decode(data, (bool))) {
            pm.sync(key.currency1);
            MockERC20(Currency.unwrap(key.currency1)).transfer(address(pm), 100_000);
            pm.settleFor(address(hook));
        }
        return "";
    }
}

abstract contract PriorityFeeOnlyBase is SetupHook {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public virtual override {
        super.setUp();
        topUp(alice, 1_000 ether);
        topUp(bob, 1_000 ether);
    }

    function _ask(address maker, uint256 fee) internal view returns (AsyncOrder memory) {
        return AsyncOrder({
            key: key,
            owner: maker,
            zeroForOne: true,
            amountIn: 1 ether,
            amountOutMin: 1 ether,
            priorityFee: fee,
            sqrtPrice: 2 ** 96,
            salt: keccak256(abi.encode(block.timestamp, block.number, address(manager), maker, 1 ether, 1 ether, fee))
        });
    }

    function _submit(AsyncOrder memory order) internal {
        vm.startPrank(order.owner);
        token0.approve(address(router), order.amountIn);
        token1.approve(address(router), order.priorityFee);
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

    /// @dev External hop so `vm.expectRevert` sees the Router call as one call.
    function submitExternal(AsyncOrder memory order) external {
        _submit(order);
    }
}

/// @notice Every pool orders equal prices by paid bid, then time; zero bids are valid and retain
///         time priority behind paid bids.
contract PriorityFeeOnlyTest is PriorityFeeOnlyBase {
    /// A pool nobody configured accepts a zero bid without any USDC allowance.
    function test_newPoolOrderCanHaveNoBid() public {
        AsyncOrder memory noBid = _ask(alice, 0);
        _submit(noBid);
        bytes32 id = _orderIdFor(alice, true, noBid.salt);
        assertEq(hook.asyncOrder(poolId, id), noBid.amountIn);
        assertEq(hook.asyncOrderPriorityFee(poolId, id), 0);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0);
    }

    function test_zeroBidsKeepTimePriorityAndAllowRepricing() public {
        AsyncOrder memory first = _ask(alice, 0);
        _submit(first);
        AsyncOrder memory second = _ask(bob, 0);
        _submit(second);
        (,, bytes32 best,) = hook.bestOrder(poolId, false);
        assertEq(best, _orderIdFor(alice, true, first.salt));
        vm.prank(alice);
        hook.updatePrice(first, 2 ether);
        (,, best,) = hook.bestOrder(poolId, false);
        assertEq(best, _orderIdFor(bob, true, second.salt));
        assertEq(hook.asyncOrderPriorityFee(poolId, _orderIdFor(alice, true, first.salt)), 0);
    }

    /// Equal prices queue by bid in a pool nobody configured: the later, higher bid is first.
    function test_newPool_equalPricesQueueByBid() public {
        _submit(_ask(alice, 100_000));
        AsyncOrder memory higher = _ask(bob, 200_000);
        _submit(higher);
        (,, bytes32 best,) = hook.bestOrder(poolId, false);
        assertEq(best, _orderIdFor(bob, true, higher.salt), "the higher bid is first at its price");
    }

    /// @dev A second hook (same permission flags, a high address bit set) whose one trusted swap caller is a
    ///      custom executor: the bid rules are the hook's own, whoever the trusted caller is.
    function _hookTrustingExecutor() internal returns (AsyncSwap h, PoolKey memory k, BidSkippingExecutor e) {
        address at = address(uint160(_hookAddress()) | (uint160(1) << 159));
        h = AsyncSwap(payable(at));
        k = PoolKey(key.currency0, key.currency1, key.fee, key.tickSpacing, h);
        e = new BidSkippingExecutor(manager, h, k);
        deployCodeTo(
            "AsyncSwap.sol", abi.encode(manager, currency1, address(this), address(e), uint256(0), type(uint8).max), at
        );
        manager.initialize(k, 2 ** 96);
        topUp(address(e), 10 ether);
    }

    /// The hook's trusted caller that declares a bid and does not pay it cannot finish its unlock.
    function test_RevertWhen_ExecutorSkipsTheBid() public {
        (,, BidSkippingExecutor executor) = _hookTrustingExecutor();
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        executor.place(false);
    }

    function test_customExecutor_canRestOrderWhenBidIsPaid() public {
        (AsyncSwap h, PoolKey memory k, BidSkippingExecutor executor) = _hookTrustingExecutor();
        executor.place(true);
        (bool found,, bytes32 id, address maker) = h.bestOrder(k.toId(), false);
        assertTrue(found);
        assertEq(maker, address(executor));
        assertEq(h.asyncOrder(k.toId(), id), 1 ether);
        assertEq(h.asyncOrderPriorityFee(k.toId(), id), 100_000);
        assertEq(manager.balanceOf(address(h), currency1.toId()), 100_000);
    }

    /// A custom executor is not the hook's trusted Router: it can't open an order at all.
    function test_RevertWhen_UntrustedExecutorOpensOrder() public {
        BidSkippingExecutor executor = new BidSkippingExecutor(manager, hook, key);
        topUp(address(executor), 10 ether);
        vm.expectRevert(_notTrustedRouter());
        executor.place(true);
    }

    function test_equalBids_keepSubmissionOrder() public {
        AsyncOrder memory first = _ask(alice, 100_000);
        _submit(first);
        _submit(_ask(bob, 100_000));
        (,, bytes32 best,) = hook.bestOrder(poolId, false);
        assertEq(best, _orderIdFor(alice, true, first.salt));
    }

    /// There is no ordering mode to switch.
    function test_setOrderingModeIsGone() public {
        (bool ok,) = address(hook)
            .call(
                abi.encodeWithSignature("setOrderingMode((address,address,uint24,int24,address),uint8)", key, uint8(0))
            );
        assertFalse(ok, "setOrderingMode still exists");
    }
}

/// @notice A hook deployed for an 18-decimal numeraire scales its $0.10 bid cap to 0.1 ether.
contract PriorityFeeCap18DecimalTest is PriorityFeeOnlyBase {
    function setUp() public override {
        numeraireDecimals = 18;
        super.setUp();
    }

    function test_18DecimalNumeraireUsesScaledOptionalBidFloor() public {
        assertEq(hook.priorityFeeCap(), 0.1 ether);
        AsyncOrder memory order = _ask(alice, 100_000);
        order.amountIn = 100 ether;
        order.amountOutMin = 100 ether;
        vm.expectRevert();
        this.submitExternal(order);

        order.priorityFee = 0.1 ether;
        _submit(order);
    }
}
