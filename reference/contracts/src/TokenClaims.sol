// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @notice Redeems the caller's PoolManager currency claims to a chosen recipient.
/// @dev Approve this contract for the currency claim ID on PoolManager before redeeming.
/// Claim ownership and allowances are enforced by PoolManager.burn. No hook escrow is accessible.
contract TokenClaims {
    IPoolManager public immutable poolManager;
    bool private _redeeming;

    error OnlyPoolManager();
    error InvalidRedemption();
    error ReentrantRedemption();
    event ClaimsRedeemed(address indexed owner, address indexed recipient, Currency indexed currency, uint256 amount);

    modifier nonReentrant() {
        if (_redeeming) revert ReentrantRedemption();
        _redeeming = true;
        _;
        _redeeming = false;
    }

    constructor(IPoolManager manager) {
        poolManager = manager;
    }

    function redeem(Currency currency, address recipient, uint256 amount) external nonReentrant {
        if (recipient == address(0) || amount == 0) revert InvalidRedemption();
        poolManager.unlock(abi.encode(msg.sender, currency, recipient, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (address owner, Currency currency, address recipient, uint256 amount) =
            abi.decode(data, (address, Currency, address, uint256));
        // Burn first. A failed transfer atomically restores both claims and allowance.
        poolManager.burn(owner, currency.toId(), amount);
        poolManager.take(currency, recipient, amount);
        emit ClaimsRedeemed(owner, recipient, currency, amount);
        return "";
    }
}
