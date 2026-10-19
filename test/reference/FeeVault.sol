// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {Owned2Step} from "./Owned2Step.sol";

/// @title FeeVault
/// @notice Holds protocol fees and forfeited bids as ERC-6909 claims in the PoolManager.
/// @dev Spec: `AsyncSwapProtocol/Model.lean` `collectFees` / `collect_settlement`: owner-only; moves exactly
///      the vault's claims in that currency to the recipient; touches no order and no hook claim.
contract FeeVault is IUnlockCallback, Owned2Step {
    IPoolManager public immutable manager;

    error NotPoolManager();

    event FeesCollected(Currency indexed currency, address indexed recipient, uint256 amount);

    constructor(IPoolManager _manager, address _owner) Owned2Step(_owner) {
        manager = _manager;
    }

    /// @notice Burn every claim of `currency` the vault holds and send the tokens to `recipient`.
    function collect(Currency currency, address recipient) external onlyOwner returns (uint256 amount) {
        if (recipient == address(0)) revert ZeroAddress();
        amount = abi.decode(manager.unlock(abi.encode(currency, recipient)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotPoolManager();
        (Currency currency, address recipient) = abi.decode(data, (Currency, address));
        uint256 amount = manager.balanceOf(address(this), currency.toId());
        if (amount != 0) {
            manager.burn(address(this), currency.toId(), amount);
            manager.take(currency, recipient, amount);
        }
        emit FeesCollected(currency, recipient, amount);
        return abi.encode(amount);
    }
}
