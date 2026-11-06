// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with Router
abstract contract RouterHandler is Properties {
    using PoolIdLibrary for PoolKey;

    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    /// @notice Place an order at a price between 1,000 and 4,000 USDC per ETH (pool spot is 2,000).
    function router_swap_clamped(bool sell, uint256 size, uint256 price, uint256 bid) public {
        uint256 quantity = clampBetween(size, 1e12, 10 ether);
        uint256 quote = quantity * clampBetween(price, MIN_PRICE, MAX_PRICE) / 1 ether;
        if (quote == 0) return;
        _swap(sell, sell ? quantity : quote, sell ? quote : quantity, clampBetween(bid, MIN_BID, 10e6));
    }

    /// @notice Near-zero stress: dust orders where `minPriorityFee` and the mulDiv chains round down.
    function router_swap_dust(bool sell, uint256 amountIn, uint256 amountOutMin, uint256 bid) public {
        _swap(sell, clampBetween(amountIn, 1, 1e6), clampBetween(amountOutMin, 1, 1e6), clampBetween(bid, 0, MIN_BID));
    }

    /// @notice Wide-price stress: limits far from spot, down to the tick-key clamps.
    function router_swap_extreme(bool sell, uint256 amountIn, uint256 amountOutMin) public {
        amountIn = clampBetween(amountIn, 1, sell ? 100 ether : 100_000e6);
        amountOutMin = clampBetween(amountOutMin, 1, type(uint128).max);
        _swap(sell, amountIn, amountOutMin, MIN_BID);
    }

    function router_fillOrder_clamped(uint256 entropy, bool capAtLive) public {
        (bool found, AsyncOrder memory order) = pickLiveOrder(entropy);
        if (!found) return;
        (uint256 amountIn, uint256 amountOutMin) = hook.asyncOrderInfo(poolId, orderId(order));
        order.amountIn = amountIn; // partial matches lower the live input
        uint256 gross = amountOutMin + hook.calculatePoolFee(0, amountOutMin);
        bool nativeOutput = !order.zeroForOne; // buys receive ETH (currency0)
        if (!nativeOutput) usdc.deal(actor, gross);
        router_fillOrder(order, capAtLive ? gross : type(uint256).max, nativeOutput ? gross : 0);
    }

    function router_cancelOrder_clamped(uint256 entropy) public {
        (bool found, AsyncOrder memory order) = pickLiveOrder(entropy);
        if (!found) return;
        actor = order.owner;
        router_cancelOrder(order);
    }

    /// @notice Cancel up to `count` live orders of one maker in one `multicall`.
    function router_multicallCancel_clamped(uint256 entropy, uint8 count) public {
        (bool found, AsyncOrder memory first) = pickLiveOrder(entropy);
        if (!found) return;
        actor = first.owner;
        AsyncOrder[] memory batch = _liveOrdersOf(actor, clampBetween(count, 1, 5));
        bytes[] memory calls = new bytes[](batch.length);
        for (uint256 i; i < batch.length; ++i) {
            calls[i] = abi.encodeCall(router.cancelOrder, (batch[i]));
        }
        router_multicall(calls);
    }

    function router_fillFromPoolLiquidity_clamped(uint256 entropy) public {
        (bool found, AsyncOrder memory order) = pickLiveOrder(entropy);
        if (!found) return;
        router_fillFromPoolLiquidity(order);
    }

    function router_matchBook_clamped(uint8 maxMatches) public {
        router_matchBook(key, uint8(clampBetween(maxMatches, 1, 8)));
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function router_multicall(bytes[] memory calls) public asActor {
        router.multicall(calls);
    }

    function router_cancelOrder(AsyncOrder memory order) public asActor {
        router.cancelOrder(order);
    }

    function router_fillFromPoolLiquidity(AsyncOrder memory order) public asActor {
        router.fillFromPoolLiquidity(order);
    }

    function router_fillOrder(AsyncOrder memory order, uint256 maxPrice, uint256 value) public asActor {
        router.fillOrder{value: value}(order, maxPrice, "");
    }

    function router_matchBook(PoolKey memory poolKey, uint8 maxMatches) public asActor {
        router.matchBook(poolKey, maxMatches);
    }

    function router_swap(AsyncOrder memory order, bytes memory userData, uint256 value) public asActor {
        router.swap{value: value}(order, userData);
    }

    // ――――――――――――――――――――――――― Internal ―――――――――――――――――――――――――

    /// @dev Builds the order, predicts the salt the hook will assign, places it and records it.
    function _swap(bool sell, uint256 amountIn, uint256 amountOutMin, uint256 bid) internal {
        AsyncOrder memory order = AsyncOrder(key, actor, sell, amountIn, amountOutMin, bid, SQRT_PRICE_2000, bytes32(0));
        if (sell) {
            // ETH input is paid from the tester's balance via msg.value.
        } else {
            usdc.deal(actor, amountIn);
        }
        if (bid != 0) usdc.deal(actor, bid);
        order.salt = _predictSalt(order);
        router_swap(
            order, abi.encode(AsyncSwap.UserParams(actor, address(router), amountOutMin, bid)), sell ? amountIn : 0
        );
        orders.push(order);
    }

    function _liveOrdersOf(address owner, uint256 max) internal view returns (AsyncOrder[] memory batch) {
        AsyncOrder[] memory buffer = new AsyncOrder[](max);
        uint256 n;
        for (uint256 i; i < orders.length && n < max; ++i) {
            if (orders[i].owner == owner && liveAmountIn(orders[i]) != 0) buffer[n++] = orders[i];
        }
        batch = new AsyncOrder[](n);
        for (uint256 i; i < n; ++i) {
            batch[i] = buffer[i];
        }
    }

    /// @dev Mirrors `AsyncSwap._createOrder`: msg.sender inside `_beforeSwap` is the PoolManager,
    ///      and the collision walk re-hashes while the id is taken.
    function _predictSalt(AsyncOrder memory order) internal view returns (bytes32 salt) {
        salt = keccak256(
            abi.encode(
                block.timestamp,
                block.number,
                address(manager),
                order.owner,
                order.amountIn,
                order.amountOutMin,
                order.priorityFee
            )
        );
        order.salt = salt;
        while (liveAmountIn(order) != 0) {
            salt = keccak256(abi.encode(salt));
            order.salt = salt;
        }
    }
}
