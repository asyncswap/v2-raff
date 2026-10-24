// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {CurrentHuffHarness} from "./CurrentHuffHarness.sol";

contract DeletedOrderTest is CurrentHuffHarness {
    function test_deletedFieldsAreZeroAndRecreationOverwritesRetainedWords() public {
        bytes32 sell = _rest(key, alice, true, 1e18, 1e9, 100000);
        bytes32 buy = _rest(key, bob, false, 1e9, 1e18, 100000);
        uint64 creation = hook.orderCreatedSequence(poolId, sell);
        _run(_one(_c(address(hook), abi.encodeCall(hook.matchBook, (key, 1)))));
        _assertDeleted(sell);
        _assertDeleted(buy);
        bytes32 recreated = _rest(key, alice, true, 1e18, 1e9, 100000);
        assertEq(recreated, sell);
        assertGt(hook.orderCreatedSequence(poolId, recreated), creation);
        (address maker, uint256 a, uint256 q,,,, uint64 fee) = hook.orderBookOrder(poolId, recreated);
        assertEq(maker, alice);
        assertEq(a, 1e18);
        assertEq(q, 1e9);
        assertEq(fee, 100000);
    }

    function _assertDeleted(bytes32 id) internal view {
        assertEq(hook.asyncOrder(poolId, id), 0);
        (uint256 a, uint256 q) = hook.asyncOrderInfo(poolId, id);
        assertEq(a, 0);
        assertEq(q, 0);
        assertEq(hook.asyncOrderPriorityFee(poolId, id), 0);
        assertEq(hook.orderCreatedSequence(poolId, id), 0);
        (address maker, uint256 input, uint256 minimum, uint128 price, bool buy, uint64 seq, uint64 fee) =
            hook.orderBookOrder(poolId, id);
        assertEq(maker, address(0));
        assertEq(input, 0);
        assertEq(minimum, 0);
        assertEq(price, 0);
        assertFalse(buy);
        assertEq(seq, 0);
        assertEq(fee, 0);
    }
}
