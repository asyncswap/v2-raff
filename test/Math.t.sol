// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Huff} from "./utils/Huff.sol";
import {IMathHarness} from "./utils/IMathHarness.sol";

/// @dev The Huff `MUL_DIV` / `MUL_DIV_UP` / `PRICE_KEY` / `PRIORITY_KEY` against OpenZeppelin `Math` and the
///      Solidity `AsyncFiller` keys, results and reverts alike.
contract MathTest is Test {
    IMathHarness m;
    MathReference r;

    function setUp() public {
        m = IMathHarness(Huff.deploy("test/harness/MathHarness.huff"));
        r = new MathReference();
    }

    function _same(bytes memory huffCall) internal {
        (bool okH, bytes memory outH) = address(m).call(huffCall);
        (bool okR, bytes memory outR) = address(r).call(huffCall);
        assertEq(okH, okR, "success");
        assertEq(outH, outR, "output");
    }

    function testFuzz_mulDiv(uint256 x, uint256 y, uint256 d) public {
        _same(abi.encodeCall(IMathHarness.mulDiv, (x, y, d)));
    }

    function testFuzz_mulDivSmall(uint128 x, uint128 y, uint128 d) public {
        _same(abi.encodeCall(IMathHarness.mulDiv, (x, y, d)));
    }

    function testFuzz_mulDivUp(uint256 x, uint256 y, uint256 d) public {
        _same(abi.encodeCall(IMathHarness.mulDivUp, (x, y, d)));
    }

    function testFuzz_mulDivUpNearMax(uint256 x, uint256 d) public {
        d = bound(d, 1, type(uint256).max);
        _same(abi.encodeCall(IMathHarness.mulDivUp, (x, d - 1, d)));
        _same(abi.encodeCall(IMathHarness.mulDivUp, (type(uint256).max, x, x)));
    }

    function test_mulDivEdges() public {
        _same(abi.encodeCall(IMathHarness.mulDiv, (0, 0, 0)));
        _same(abi.encodeCall(IMathHarness.mulDiv, (type(uint256).max, type(uint256).max, type(uint256).max)));
        _same(abi.encodeCall(IMathHarness.mulDiv, (type(uint256).max, type(uint256).max, type(uint256).max - 1)));
        _same(abi.encodeCall(IMathHarness.mulDiv, (type(uint256).max, 2, 1)));
        _same(abi.encodeCall(IMathHarness.mulDivUp, (type(uint256).max, 1, 1)));
        _same(abi.encodeCall(IMathHarness.mulDivUp, (type(uint256).max, 3, 2)));
    }

    function testFuzz_priceKey(bool buy, uint256 amountIn, uint256 amountOut) public {
        _same(abi.encodeCall(IMathHarness.priceKey, (buy, amountIn, amountOut)));
    }

    function testFuzz_priceKeyInRange(bool buy, uint128 amountIn, uint256 amountOut) public {
        _same(abi.encodeCall(IMathHarness.priceKey, (buy, amountIn, amountOut)));
    }

    function testFuzz_priorityKey(uint64 fee, uint64 sequence) public {
        _same(abi.encodeCall(IMathHarness.priorityKey, (fee, sequence)));
    }
}

contract MathReference {
    function mulDiv(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return Math.mulDiv(x, y, d);
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return Math.mulDiv(x, y, d, Math.Rounding.Ceil);
    }

    /// @dev `AsyncFiller.priceKey`.
    function priceKey(bool buy, uint256 amountIn, uint256 amountOut) external pure returns (uint128) {
        uint256 raw = buy ? Math.mulDiv(amountIn, 1e18, amountOut) : Math.mulDiv(amountOut, 1e18, amountIn);
        if (raw == 0) return 1;
        if (raw > type(uint128).max) return type(uint128).max;
        return uint128(raw);
    }

    /// @dev `AsyncFiller.priorityKey`.
    function priorityKey(uint64 fee, uint64 sequence) external pure returns (uint128) {
        return (uint128(fee) << 64) | uint128(type(uint64).max - sequence);
    }
}
