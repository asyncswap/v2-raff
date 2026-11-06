// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "../Base.sol";
import {Properties} from "../Properties.sol";
import {AsyncFiller} from "src/libraries/AsyncFiller.sol";

/// @notice Handles the interaction with AsyncSwap
abstract contract AsyncSwapHandler is Properties {
    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    /// @notice Maker reprices a live order to a price in the handler range.
    function asyncSwap_updatePrice_clamped(uint256 entropy, uint256 price) public {
        (bool found, AsyncOrder memory order) = pickLiveOrder(entropy);
        if (!found) return;
        uint256 remaining = liveAmountIn(order);
        uint256 p = clampBetween(price, MIN_PRICE, MAX_PRICE);
        uint256 newMinimum = order.zeroForOne ? remaining * p / 1 ether : remaining * 1 ether / p;
        if (newMinimum == 0) return;
        actor = order.owner;
        asyncSwap_updatePrice(order, newMinimum);
    }

    /// @notice Type-boundary stress: reprice to an arbitrary minimum up to uint256 max.
    function asyncSwap_updatePrice_extreme(uint256 entropy, uint256 newAmountOutMin) public {
        (bool found, AsyncOrder memory order) = pickLiveOrder(entropy);
        if (!found) return;
        actor = order.owner;
        asyncSwap_updatePrice(order, clampGt(newAmountOutMin, 0));
    }

    /// @notice Sends ETH to the hook outside any fill, through `receive()` or by force.
    function asyncSwap_donateETH(uint256 amount, bool force) public {
        amount = clampBetween(amount, 1, 10 ether);
        if (force) {
            Actor(payable(actor)).forceSendETH(address(hook), clampLte(amount, actor.balance));
        } else {
            (bool ok,) = address(hook).call{value: amount}("");
            require(ok);
        }
    }

    /// @notice Low-frequency owner and maker configuration.
    function asyncSwap_secondary(uint8 selector, uint256 arg0, bool arg1) public {
        selector = uint8(selector % 3);
        if (selector == 0) _asyncSwap_setExecutor(arg1);
        else if (selector == 1) _asyncSwap_sweep(arg1);
        else _asyncSwap_invalidateNonce(arg0);
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function asyncSwap_updatePrice(AsyncOrder memory order, uint256 newAmountOutMin) public asActor {
        hook.updatePrice(order, newAmountOutMin);
    }

    /// @dev Toggling the Router off strands the actor's cancels and fills until it is re-enabled.
    function _asyncSwap_setExecutor(bool allow) internal asActor {
        hook.setExecutor(poolId, address(router), allow);
    }

    function _asyncSwap_sweep(bool native) internal asAdmin {
        hook.sweep(native ? Currency.wrap(address(0)) : Currency.wrap(address(usdc)), admin);
    }

    function _asyncSwap_invalidateNonce(uint256 nonce) internal asActor {
        hook.invalidateNonce(nonce);
    }
}
