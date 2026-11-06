// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CurrentHuffDeploy} from "../support/CurrentHuffDeploy.sol";
import {TickPrice} from "@async-swap/libraries/TickPrice.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

interface IPoolPriorityParity {
    function poolBeatsLevel(IPoolManager, PoolId, bool, bool, uint128, int24, uint64)
        external
        view
        returns (bool, uint160);
}

contract PoolPriorityParityTest is Test {
    IPoolPriorityParity kernel;
    IPoolManager constant MANAGER = IPoolManager(address(0xBEEF));
    PoolId constant PID = PoolId.wrap(bytes32(uint256(1)));

    function setUp() public {
        kernel = IPoolPriorityParity(CurrentHuffDeploy.deploy("test/harness/PoolPriorityHarness.huff", ""));
        vm.etch(address(MANAGER), hex"00");
    }

    struct Case {
        int24 tick;
        int24 referenceTick;
        uint64 referenceBlock;
        uint64 currentBlock;
        uint128 liquidity;
        uint128 level;
        bool quote1;
        bool buy;
    }

    function test_sellFeeKeepsPositivePoolKey() public {
        testFuzz_poolPriorityMatchesSolidity(Case(3352, 2808, 100, 100, 1, 890100, true, false));
        testFuzz_poolPriorityMatchesSolidity(Case(-3352, -2808, 100, 100, 1, 890100, false, false));
    }

    // Differential coverage adds arbitrary pool/reference ticks and both fee directions to the copied tests.
    function testFuzz_poolPriorityMatchesSolidity(Case memory c) public {
        c.tick = int24(bound(int256(c.tick), -887272, 887272));
        c.referenceTick = int24(bound(int256(c.referenceTick), -887272, 887272));
        c.referenceBlock = uint64(bound(c.referenceBlock, 0, 1_000_000));
        vm.roll(bound(c.currentBlock, 0, 1_000_002));
        c.level = uint128(bound(c.level, 1, 1_774_545));
        bytes32 slot = keccak256(abi.encode(PID, uint256(6)));
        vm.mockCall(
            address(MANAGER),
            abi.encodeWithSignature("extsload(bytes32)", slot),
            abi.encode(uint256(uint24(c.tick)) << 160)
        );
        vm.mockCall(
            address(MANAGER),
            abi.encodeWithSignature("extsload(bytes32)", bytes32(uint256(slot) + 3)),
            abi.encode(c.liquidity)
        );
        (bool expected, uint160 expectedLimit) =
            TickPrice.poolBeatsLevel(MANAGER, PID, c.quote1, c.buy, c.level, c.referenceTick, c.referenceBlock);
        (bool actual, uint160 actualLimit) =
            kernel.poolBeatsLevel(MANAGER, PID, c.quote1, c.buy, c.level, c.referenceTick, c.referenceBlock);
        assertEq(actual, expected, "pool/book selection");
        assertEq(actualLimit, expectedLimit, "pool swap limit");
    }
}
