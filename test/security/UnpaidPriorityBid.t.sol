// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {IPoolManager, SwapParams} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey, PoolIdLibrary} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "../utils/MockERC20.sol";

/// @notice A maker that calls the PoolManager itself: it places an order with the largest priority bid
///         and never pays the bid, then later cancels.
contract UnpaidBidMaker {
    using PoolIdLibrary for PoolKey;

    IPoolManager immutable pm;
    AsyncSwap immutable hook;
    PoolKey key;
    AsyncOrder cancelling;
    bool cancelMode;

    constructor(IPoolManager _pm, AsyncSwap _hook, PoolKey memory _key) {
        pm = _pm;
        hook = _hook;
        key = _key;
    }

    function place() external {
        hook.setExecutor(key.toId(), address(this), true);
        pm.unlock("");
    }

    function cancel(AsyncOrder memory order) external {
        cancelling = order;
        cancelMode = true;
        pm.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        if (cancelMode) {
            hook.cancelOrder(cancelling);
            return "";
        }
        // Sell 1 wei of currency0, claiming the maximum bid, and settle only the input.
        pm.swap(
            key,
            SwapParams(true, -1, TickMath.MIN_SQRT_PRICE + 1),
            abi.encode(
                AsyncSwap.UserParams({
                    user: address(this), executor: address(this), amountOutMin: 1, priorityFee: type(uint64).max
                })
            )
        );
        pm.sync(key.currency0);
        MockERC20(Currency.unwrap(key.currency0)).transfer(address(pm), 1);
        pm.settle();
        return "";
    }
}

/// @notice An unpaid priority bid buys no priority and blocks nothing: crossing orders still trade,
///         the book still matches, and the maker can always cancel (so the pool can leave PriorityFee mode).
contract UnpaidPriorityBidTest is SetupHook {
    function test_unpaidPriorityBid_cannotBlockThePool() public {
        hook.setOrderingMode(key, AsyncFiller.OrderingMode.PriorityFee);
        UnpaidBidMaker griefer = new UnpaidBidMaker(manager, hook, key);
        topUp(address(griefer), 1 ether);

        vm.recordLogs();
        griefer.place();
        bytes32 salt = _createdSalt();

        // A taker crossing that price level still trades (before the fix this reverted with PriorityFeeNotEscrowed).
        address taker = makeAddr("taker");
        topUp(taker, 10 ether);
        AsyncOrder memory bid = AsyncOrder({
            key: key,
            owner: taker,
            zeroForOne: false,
            amountIn: 1 ether,
            amountOutMin: 0.5 ether,
            priorityFee: 100_000,
            sqrtPrice: 2 ** 96,
            salt: bytes32(0)
        });
        vm.startPrank(taker);
        token1.approve(address(router), type(uint256).max);
        router.swap(
            bid,
            abi.encode(
                AsyncSwap.UserParams({
                    user: taker, executor: address(router), amountOutMin: 0.5 ether, priorityFee: 100_000
                })
            )
        );
        vm.stopPrank();

        // The unpaid order can always be cancelled, if it is still on the book.
        AsyncOrder memory unpaid = AsyncOrder({
            key: key,
            owner: address(griefer),
            zeroForOne: true,
            amountIn: 1,
            amountOutMin: 1,
            priorityFee: type(uint64).max,
            sqrtPrice: 0,
            salt: salt
        });
        if (hook.asyncOrder(poolId, keccak256(abi.encode(block.chainid, poolId, address(griefer), true, salt))) != 0) {
            griefer.cancel(unpaid);
        }
        assertEq(hook.asyncOrder(poolId, keccak256(abi.encode(block.chainid, poolId, address(griefer), true, salt))), 0);
    }

    function _createdSalt() private returns (bytes32 salt) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = AsyncFiller.AsyncOrderCreated.selector;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) (,,, salt) = abi.decode(logs[i].data, (bool, uint256, uint256, bytes32));
        }
    }
}
