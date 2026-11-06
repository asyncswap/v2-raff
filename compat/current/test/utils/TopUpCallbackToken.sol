// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {PoolKey, PoolIdLibrary} from "v4-core/types/PoolKey.sol";

/// @dev Etched over MockERC20; the first five storage slots deliberately match its layout.
contract TopUpCallbackToken {
    string public name;
    string public symbol;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    TopUpPaymentProbe immutable probe;

    constructor(TopUpPaymentProbe p) {
        probe = p;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        probe.onPayment();
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Matches from the token callback to test the order changing during payment.
contract TopUpPaymentProbe {
    using PoolIdLibrary for PoolKey;
    AsyncSwap immutable hook;
    PoolKey key;
    bytes32 immutable id;
    uint256 immutable oldFee;
    bool public called;

    constructor(AsyncSwap h, PoolKey memory k, bytes32 orderId, uint256 fee) {
        hook = h;
        key = k;
        id = orderId;
        oldFee = fee;
    }

    function onPayment() external {
        require(hook.asyncOrderPriorityFee(key.toId(), id) == oldFee, "unfunded bid became visible");
        called = true;
        hook.matchBook(key, 1);
    }
}
