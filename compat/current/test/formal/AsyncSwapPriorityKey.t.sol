// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {AsyncBookHarness, FormalRefA} from "./FormalHarnessesA.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapPriorityKey.lean`. The private
///         `AsyncFiller._priorityKey(priorityFee, sequence)` is observed through the real internal
///         `AsyncFiller._append` in PriorityFee mode, which stores
///         `order.priorityKey = _priorityKey(paidPriorityFee(order), order.sequence)`. With the bid escrowed,
///         `paidPriorityFee` is the stored `priorityFee`, so both arguments range over all of `uint64`.
contract AsyncSwapPriorityKeyFormalTest is FormalRefA {
    AsyncBookHarness h;

    function setUp() public {
        h = new AsyncBookHarness();
    }

    function _keyViaAppend(uint64 fee, uint64 seq, bool isBuy, uint128 price) internal returns (uint128) {
        bytes32 id = keccak256(abi.encode(fee, seq, isBuy, price));
        AsyncFiller.OrderInfo memory o;
        o.owner = address(0xA11CE);
        o.amountIn = 1;
        o.amountOutMin = 1;
        // The outer index accepts tick keys; fee and sequence still span all uint64 values.
        o.price = 1 + price % 1_774_545;
        o.isBuy = isBuy;
        o.sequence = seq;
        o.priorityFee = fee;
        h.setOrder(id, o);
        h.append(id);
        return h.order(id).priorityKey;
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapPriorityKey.lean:25 — for sequence <= 2^64 - 1 (every uint64) it
    ///         returns (fee << 64 mod 2^128) | (2^64 - 1 - sequence).
    function testFuzz_priorityKey_spec(uint64 fee, uint64 seq, bool isBuy, uint128 price) public {
        uint256 shl = (uint256(fee) << 64) % (uint256(1) << 128);
        assertEq(uint256(_keyViaAppend(fee, seq, isBuy, price)), shl | (uint256(type(uint64).max) - seq));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapPriorityKey.lean:42 — a success implies sequence <= 2^64 - 1 and
    ///         the key is (fee << 64) | (2^64 - 1 - sequence).
    function testFuzz_priorityKey_ok(uint64 fee, uint64 seq, bool isBuy, uint128 price) public {
        uint128 k = _keyViaAppend(fee, seq, isBuy, price);
        assertLe(uint256(seq), 2 ** 64 - 1);
        assertEq(uint256(k), ((uint256(fee) << 64) % 2 ** 128) | (2 ** 64 - 1 - uint256(seq)));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapPriorityKey.lean:54 — for a 64-bit fee and in-range sequence the key
    ///         is the spec key fee * 2^64 + (2^64 - 1 - sequence).
    function testFuzz_priorityKey_run(uint64 fee, uint64 seq, bool isBuy, uint128 price) public {
        assertEq(uint256(_keyViaAppend(fee, seq, isBuy, price)), uint256(fee) * 2 ** 64 + (2 ** 64 - 1 - uint256(seq)));
    }
}
