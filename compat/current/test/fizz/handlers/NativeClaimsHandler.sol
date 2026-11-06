// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with NativeClaims
abstract contract NativeClaimsHandler is Properties {
    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    function nativeClaims_redeem_clamped(uint256 amount, bool full) public {
        uint256 balance = manager.balanceOf(actor, 0);
        if (balance == 0) return;
        nativeClaims_redeem(actor, full ? balance : clampBetween(amount, 1, balance));
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function nativeClaims_redeem(address recipient, uint256 amount) public asActor {
        nativeClaims.redeem(recipient, amount);
    }
}
