// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {CurrencyLibrary} from "v4-core/types/Currency.sol";

/// @title NativeClaims
/// @notice Redeems native-ETH proceeds. The hook pays every native leg (maker output, filler escrow, cancel
///         refund) as ERC-6909 claims of currency0 in the PoolManager; the holder redeems them here for ETH.
/// @dev Spec: `AsyncSwapProtocol/V2/Model.lean` `redeemNative` / `redeem_settlement`: the caller's claims
///      drop by `amount`, the recipient receives `amount` of ETH, nothing else moves. The holder must first
///      `PoolManager.setOperator(address(this), true)` (or approve the amount) so the claims can be burned.
contract NativeClaims is IUnlockCallback {
    IPoolManager public immutable manager;

    error NotPoolManager();
    error ZeroAmount();
    error ZeroAddress();

    event Redeemed(address indexed account, address indexed recipient, uint256 amount);

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function redeem(uint256 amount, address recipient) external {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        manager.unlock(abi.encode(msg.sender, amount, recipient));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotPoolManager();
        (address account, uint256 amount, address recipient) = abi.decode(data, (address, uint256, address));
        manager.burn(account, CurrencyLibrary.ADDRESS_ZERO.toId(), amount);
        manager.take(CurrencyLibrary.ADDRESS_ZERO, recipient, amount);
        emit Redeemed(account, recipient, amount);
        return "";
    }
}
