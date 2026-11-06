// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @dev At most 16 makers and the FeeVault can each receive two currencies in eight matches.
library ClaimTransfers {
    struct Credit {
        Currency currency;
        address recipient;
        uint256 amount;
    }

    struct Batch {
        Credit[34] credits;
        uint256 count;
    }

    function credit(Batch memory batch, IPoolManager manager, Currency currency, address recipient, uint256 amount)
        internal
    {
        if (amount == 0) return;
        // A self-transfer is net zero; do not combine repeated self-credits beyond the available balance.
        if (recipient == address(this)) {
            manager.transfer(recipient, currency.toId(), amount);
            return;
        }
        for (uint256 i; i < batch.count; ++i) {
            Credit memory item = batch.credits[i];
            if (item.currency == currency && item.recipient == recipient) {
                batch.credits[i].amount += amount;
                return;
            }
        }
        batch.credits[batch.count++] = Credit(currency, recipient, amount);
    }

    function flush(Batch memory batch, IPoolManager manager) internal {
        for (uint256 i; i < batch.count; ++i) {
            Credit memory item = batch.credits[i];
            manager.transfer(item.recipient, item.currency.toId(), item.amount);
        }
    }
}
