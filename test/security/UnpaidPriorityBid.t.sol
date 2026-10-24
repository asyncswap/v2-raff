// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../SetupHook.t.sol";
import {IAsyncSwap as AsyncSwap} from "src/interface/IAsyncSwap.sol";
import {IAsyncFiller as AsyncFiller} from "src/interface/IAsyncFiller.sol";
import {AsyncOrder} from "src/interface/types/AsyncOrder.sol";
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

/// @notice Unpaid bids revert the entire unlock, leaving no persistent order or fee claim.
contract UnpaidPriorityBidTest is SetupHook {
    function test_unpaidPriorityBid_cannotBlockThePool() public {
        UnpaidBidMaker griefer = new UnpaidBidMaker(manager, hook, key);
        topUp(address(griefer), 1 ether);
        uint256 inputBefore = token0.balanceOf(address(griefer));
        uint256 inputEscrow = manager.balanceOf(address(hook), currency0.toId());
        uint256 feeEscrow = manager.balanceOf(address(hook), currency1.toId());
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        griefer.place();
        assertEq(token0.balanceOf(address(griefer)), inputBefore);
        assertEq(manager.balanceOf(address(hook), currency0.toId()), inputEscrow);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), feeEscrow);
        (bool found,,,) = hook.bestOrder(poolId, false);
        assertFalse(found);
    }
}
