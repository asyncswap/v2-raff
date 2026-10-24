// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {HuffNeoDeployer} from "foundry-huff-neo/HuffNeoDeployer.sol";

contract ExactBoundTest is Test {
    address internal h;

    function setUp() public {
        h = HuffNeoDeployer.config().deploy("test/harness/ExactBoundHarness.huff");
    }

    function _roundTrip(uint256 n, uint256 d) internal {
        (bool ok, bytes memory result) = h.call(abi.encode(uint256(1), n, d));
        assertTrue(ok);
        (uint256 actualN, uint256 actualD) = abi.decode(result, (uint256, uint256));
        assertEq(actualN, n);
        assertEq(actualD, d);
        (ok, result) = h.staticcall(abi.encode(uint256(0)));
        assertTrue(ok);
        (actualN, actualD) = abi.decode(result, (uint256, uint256));
        assertEq(actualN, n);
        assertEq(actualD, d);
    }

    function test_wideCompactWideReuse() public {
        _roundTrip(type(uint256).max, type(uint256).max - 1);
        _roundTrip(type(uint128).max, type(uint128).max);
        _roundTrip(1, uint256(type(uint128).max) + 1);
        _roundTrip(1, 1);
        _roundTrip(uint256(type(uint128).max) + 1, 1);
    }

    function testFuzz_exactFullWidthRoundTrips(uint256 n, uint256 d) public {
        n = bound(n, 1, type(uint256).max);
        d = bound(d, 1, type(uint256).max);
        _roundTrip(n, d);
        _roundTrip(uint128(n) | 1, uint128(d) | 1);
        _roundTrip(n, d);
    }
}
