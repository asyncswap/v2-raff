// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with FeeVault
abstract contract FeeVaultHandler is Properties {
    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    function feeVault_secondary(bool native) public {
        _feeVault_collect(native ? Currency.wrap(address(0)) : Currency.wrap(address(usdc)), admin);
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function _feeVault_collect(Currency currency, address recipient) internal asAdmin {
        feeVault.collect(currency, recipient);
    }
}
