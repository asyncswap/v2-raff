// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {HuffNeoDeployer} from "foundry-huff-neo/HuffNeoDeployer.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

contract TickInversionTest is Test {
    address internal h;

    function setUp() public {
        h = HuffNeoDeployer.config().deploy("test/harness/TickInversionHarness.huff");
    }

    function _tick(uint160 price) internal view returns (int256) {
        (bool ok, bytes memory result) = h.staticcall(abi.encode(price));
        require(ok, "native inversion failed");
        return abi.decode(result, (int256));
    }

    function test_extremePrices() public view {
        assertEq(_tick(TickMath.MIN_SQRT_PRICE), int256(TickMath.MIN_TICK));
        assertEq(_tick(TickMath.MAX_SQRT_PRICE - 1), int256(TickMath.MAX_TICK) - 1);
    }

    function testFuzz_matchesV4TickMath(uint160 rawPrice) public view {
        uint160 price = uint160(bound(uint256(rawPrice), TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        assertEq(_tick(price), int256(TickMath.getTickAtSqrtPrice(price)));
    }

    function testFuzz_exactTickBoundaryAndNeighbours(int24 rawTick) public view {
        int24 tick = int24(bound(int256(rawTick), TickMath.MIN_TICK + 1, TickMath.MAX_TICK - 1));
        uint160 boundary = TickMath.getSqrtPriceAtTick(tick);
        assertEq(_tick(boundary), int256(tick), "at boundary");
        assertEq(_tick(boundary - 1), int256(tick) - 1, "below boundary");
        assertEq(_tick(boundary + 1), int256(tick), "above boundary");
    }
}
