// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Huff} from "./utils/Huff.sol";
import {IMathHarness} from "./utils/IMathHarness.sol";

/// @dev Spec: `AsyncSwapSpec/Fee.lean`, run against the Huff `POOL_FEE`.
contract ProtocolFeeTest is Test {
    IMathHarness m;

    function setUp() public {
        m = IMathHarness(Huff.deploy("test/harness/MathHarness.huff"));
    }

    /// `poolFee_eq`: the split form equals `net * 3 / 997`.
    function testFuzz_splitFormEqualsStraightforward(uint256 net) public view {
        net = bound(net, 0, type(uint256).max / 3);
        assertEq(m.poolFee(net), net * 3 / 997);
    }

    /// `poolFee_eq_30bps_of_gross`: exactly 30 bps of gross, rounded down.
    function testFuzz_thirtyBpsOfGross(uint256 net) public view {
        net = bound(net, 0, type(uint256).max / 4);
        uint256 fee = m.poolFee(net);
        assertEq(fee, 3 * (net + fee) / 1000);
    }

    /// `poolFee_le_net`, `poolFee_mono`, `poolFee_eq_zero_iff`.
    function testFuzz_boundsAndMonotone(uint256 a, uint256 b) public view {
        a = bound(a, 0, type(uint256).max / 4);
        b = bound(b, 0, type(uint256).max / 4);
        assertLe(m.poolFee(a), a);
        if (a <= b) assertLe(m.poolFee(a), m.poolFee(b));
        assertEq(m.poolFee(a) == 0, a < 333);
    }

    /// `poolFee_lt_two_pow_256`: no overflow on the whole `uint256` range.
    function test_noOverflowAtMax() public view {
        uint256 fee = m.poolFee(type(uint256).max);
        assertEq(fee, (type(uint256).max / 997) * 3 + ((type(uint256).max % 997) * 3) / 997);
    }
}
