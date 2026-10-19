// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

/// @notice PoolManager settlement helpers (the usual v4 `CurrencySettler`, kept in `src/` so the protocol does
///         not depend on v4-core's test utilities).
library CurrencySettler {
    /// @dev `settle(currency, manager, payer, amount, burn)`: pay `amount` of `currency` into the PoolManager,
    ///      either by burning the payer's ERC-6909 claims (`burn = true`) or by moving real tokens / native value.
    function settle(Currency currency, IPoolManager manager, address payer, uint256 amount, bool burn) internal {
        if (burn) {
            manager.burn(payer, currency.toId(), amount);
        } else if (currency.isAddressZero()) {
            manager.settle{value: amount}();
        } else {
            manager.sync(currency);
            if (payer != address(this)) {
                IERC20Minimal(Currency.unwrap(currency)).transferFrom(payer, address(manager), amount);
            } else {
                IERC20Minimal(Currency.unwrap(currency)).transfer(address(manager), amount);
            }
            manager.settle();
        }
    }

    /// @dev `take(currency, manager, recipient, amount, claims)`: pay `amount` out of the PoolManager, as ERC-6909
    ///      claims (`claims = true`) or as real tokens.
    function take(Currency currency, IPoolManager manager, address recipient, uint256 amount, bool claims) internal {
        if (claims) manager.mint(recipient, currency.toId(), amount);
        else manager.take(currency, recipient, amount);
    }
}
