// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MatchingReferenceTest} from "./MatchingReference.t.sol";

/// @notice The memory candidate must compete with the whole stored book after every fill.
contract IncomingMemoryReferenceTest is MatchingReferenceTest {
    function test_referenceIncomingBidYieldsAfterPartialFill() public {
        for (uint256 i; i < 3; ++i) {
            _submit(true, 1 ether, 1_000e6, 0);
        }
        _submit(false, 2_000e6, 4 ether, 200_000);
        _reprice(3, 2 ether);
        _submit(false, 3_000e6, 3 ether, 300_000);
        assertEq(expected.length, 3);
        assertEq(expected[0].bid, _id(refs[4]), "incoming highest bid first");
        assertEq(expected[1].bid, _id(refs[3]), "remaining bid ties older resting order");
        assertEq(expected[2].bid, _id(refs[4]), "incoming regains priority after resting reduction");
        assertEq(refs[4].input, 1_000e6, "persist the incoming remainder");
        assertEq(refs[4].fee, 100_000);
    }

    function test_referenceBacklogContinuesAfterIncomingCloses() public {
        for (uint256 i; i < 3; ++i) {
            _submit(true, 1 ether, 1_000e6, 0);
        }
        _submit(false, 3_000e6, 6 ether, 100_000);
        _reprice(3, 3 ether);
        _submit(false, 1_000e6, 1 ether, 500_000);
        assertEq(expected.length, 3);
        assertEq(expected[0].bid, _id(refs[4]));
        assertEq(expected[1].bid, _id(refs[3]));
        assertEq(expected[2].bid, _id(refs[3]));
        assertEq(refs[4].input, 0, "incoming has closed but bounded matching continues");
    }

    function test_referenceBacklogConsumesBudgetBeforeIncoming() public {
        for (uint256 i; i < 9; ++i) {
            _submit(true, 1 ether, 1_000e6, 0);
        }
        _submit(false, 9_000e6, 18 ether, 100_000);
        _reprice(9, 9 ether);
        _submit(false, 1_000e6, 2 ether, 0);
        assertEq(expected.length, 8, "one budget shared with backlog");
        for (uint256 i; i < 8; ++i) {
            assertEq(expected[i].bid, _id(refs[9]));
        }
        assertEq(refs[10].input, 1_000e6, "unselected arrival is persisted intact");
        _clear(8);
        assertEq(expected.length, 1);
        _topUpFee(10, 100_000);
        _cancel(10);
    }
}
