// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HuffNeoDeployer} from "foundry-huff-neo/HuffNeoDeployer.sol";
import {TickPrice} from "../../reference/contracts/src/libraries/TickPrice.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

contract CurrentTickParityTest is Test {
    address kernel;

    function setUp() public {
        bytes memory code = HuffNeoDeployer.config().creation_code("src/experimental/CurrentTick.huff");
        address deployed;
        assembly ("memory-safe") { deployed := create(0, add(code, 32), mload(code)) }
        require(deployed != address(0));
        kernel = deployed;
    }

    function _compare(bool buy, bool zfo, uint256 input, uint256 output) internal view {
        (bool ok, bytes memory result) =
            kernel.staticcall(abi.encodeWithSignature("key(bool,bool,uint256,uint256)", buy, zfo, input, output));
        assertTrue(ok, "Huff key reverted");
        assertEq(abi.decode(result, (uint128)), TickPrice.key(buy, zfo, input, output), "tick key parity");
    }

    function testFuzz_fullWidthKey(bool buy, bool zfo, uint256 input, uint256 output) public view {
        _compare(buy, zfo, input == 0 ? 1 : input, output == 0 ? 1 : output);
    }

    function testFuzz_tickBoundaries(int24 raw) public view {
        int24 tick = int24(bound(int256(raw), -887272, 443600));
        uint256 sqrt = TickMath.getSqrtPriceAtTick(tick);
        uint256 numerator = sqrt * sqrt;
        for (uint256 flags; flags < 4; ++flags) {
            _compare(flags & 1 != 0, flags & 2 != 0, uint256(1) << 192, numerator);
            _compare(flags & 1 != 0, flags & 2 != 0, uint256(1) << 192, numerator - 1);
            _compare(flags & 1 != 0, flags & 2 != 0, uint256(1) << 192, numerator + 1);
        }
    }

    function test_extremesAndUnity() public view {
        for (uint256 flags; flags < 4; ++flags) {
            _compare(flags & 1 != 0, flags & 2 != 0, 1, 1);
            _compare(flags & 1 != 0, flags & 2 != 0, 1, type(uint256).max);
            _compare(flags & 1 != 0, flags & 2 != 0, type(uint256).max, 1);
        }
    }
}
