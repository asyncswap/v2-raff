// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with TokenClaims
abstract contract TokenClaimsHandler is Properties {
    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    function tokenClaims_redeem_clamped(uint256 amount, bool full) public {
        uint256 balance = manager.balanceOf(actor, uint160(address(usdc)));
        if (balance == 0) return;
        tokenClaims_redeem(Currency.wrap(address(usdc)), actor, full ? balance : clampBetween(amount, 1, balance));
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function tokenClaims_redeem(Currency currency, address recipient, uint256 amount) public asActor {
        tokenClaims.redeem(currency, recipient, amount);
    }
}
