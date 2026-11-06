// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;
import {FormalMatchD} from "../formal/FormalMatchD.sol";

contract EligibleRemainderTest is FormalMatchD {
    function test_refreshWhenPriceKeyAndFeeAreUnchanged() public {
        // A small fill of a large ask: its bid share rounds to zero and the ceiling nudges its
        // exact ask by about 3e-13, inside its tick.
        uint256 size = 1e30;
        uint256 minimum = 3e12 + 1;
        uint256 quote = 3e6;
        uint256 asset = quote * size / minimum;
        bytes32 first = _rest(key, alice, true, size, minimum, 100_000);
        uint128 tick = _info(poolId, first).price;
        _rest(key, bob, false, quote, asset, 100_000);
        _run(_matchCalls(key));
        uint256 remaining = size - asset;
        assertEq(_info(poolId, first).amountIn, remaining);
        assertGt(_info(poolId, first).amountOutMin * size, minimum * remaining, "ceiling raised the exact ask");
        assertEq(_info(poolId, first).priorityFee, 100_000, "bid unchanged");
        assertEq(_info(poolId, first).price, tick, "same tick");
        // The raised exact ask no longer crosses an identical buy, though its tick, rank and
        // sequence are unchanged; a fresh ask at the original price does.
        bytes32 eligible = _rest(key, alice, true, size, minimum, 100_000);
        bytes32 buy = _rest(key, bob, false, quote, asset, 100_000);
        vm.recordLogs();
        _run(_matchCalls(key));
        Op[] memory ops = _ops(vm.getRecordedLogs());
        Op memory trade = _matchedOp(ops);
        assertEq(trade.kind, OP_MATCHED);
        assertEq(trade.tag, eligible);
        assertEq(trade.tag2, buy);
        assertEq(_info(poolId, first).amountIn, remaining);
    }
}
