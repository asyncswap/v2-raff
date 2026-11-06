// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AsyncFiller} from "./AsyncFiller.sol";
import {CurrencySettler} from "./CurrencySettler.sol";
import {EligiblePrice} from "./EligiblePrice.sol";
import {RadixPriceTree} from "./RadixPriceTree.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice Funded priority amendments, linked separately to keep the hook within EIP-170.
library PriorityFeeUpdates {
    using CurrencySettler for Currency;
    using RadixPriceTree for RadixPriceTree.Tree;

    event AsyncOrderPriorityFeeUpdated(
        PoolId indexed poolId, bytes32 indexed orderId, uint256 addedFee, uint256 newPriorityFee
    );

    /// @dev The hook admits only its trusted Router, which authenticates the maker and pays the delta.
    function topUp(
        AsyncFiller.State storage self,
        AsyncFiller.Book storage book,
        PoolId poolId,
        bytes32 id,
        uint256 addedFee
    ) public {
        AsyncFiller.OrderInfo storage order = self.orders[id];
        if (order.amountIn == 0) revert AsyncFiller.OrderNotFound();
        if (addedFee == 0) revert AsyncFiller.ZeroAmount();
        if (addedFee > type(uint64).max - uint256(order.priorityFee)) revert AsyncFiller.PriorityFeeTooLarge();
        uint64 newFee = order.priorityFee + uint64(addedFee);
        if (newFee < AsyncFiller.minPriorityFee(order.isBuy ? order.amountIn : order.amountOutMin, book.priorityFeeCap))
        {
            revert AsyncFiller.PriorityFeeTooSmall();
        }

        AsyncFiller.PriceLevel storage level = order.isBuy ? book.bidLevels[order.price] : book.askLevels[order.price];
        // Rekey only the inner queue: the price level and its order count have not changed.
        EligiblePrice.remove(level.priorityOrders, level.exactBounds, order.priorityKey, order.isBuy);
        delete level.priorityOrderIds[order.priorityKey];
        order.priorityFee = newFee;
        // A changed bid joins the back of its new fee tier; original maker age stays intact.
        order.sequence = ++book.nextSequence;
        order.priorityKey = (uint128(newFee) << 64) | uint128(type(uint64).max - order.sequence);
        level.priorityOrders.insert(order.priorityKey);
        level.priorityOrderIds[order.priorityKey] = id;
        AsyncFiller.refreshExactPrice(self, book, id);

        // Minting consumes the Router's credit; PoolManager rejects an unlock with any unpaid debt.
        self.numeraire.take(self.poolManager, address(this), addedFee, true);
        emit AsyncOrderPriorityFeeUpdated(poolId, id, addedFee, newFee);
    }
}
