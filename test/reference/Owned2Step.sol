// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Two-step ownership.
/// @dev Spec: `AsyncSwapSpec/Admin.lean`. `owner` changes only through `acceptOwnership`, and only to the
///      nominated `pendingOwner` (`owner_change_only_via_accept`); nominating never transfers control; the zero
///      address can never be nominated; accepting clears the nomination.
abstract contract Owned2Step {
    address public owner;
    address public pendingOwner;

    error Unauthorized();
    error ZeroAddress();

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        address previous = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, msg.sender);
    }
}
