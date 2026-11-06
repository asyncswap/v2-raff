// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, stdError} from "forge-std/Test.sol";
import {HuffNeoDeployer} from "foundry-huff-neo/HuffNeoDeployer.sol";
import {ClaimTransfers} from "../../reference/contracts/src/libraries/ClaimTransfers.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";

contract BatchManager {
    mapping(address => mapping(uint256 => uint256)) public balance;
    uint256 public calls;
    bytes32 public transferHash;

    function seed(address who, uint256 id, uint256 amount) external {
        balance[who][id] = amount;
    }

    function transfer(address to, uint256 id, uint256 amount) external returns (bool) {
        balance[msg.sender][id] -= amount;
        balance[to][id] += amount;
        ++calls;
        transferHash = keccak256(abi.encode(transferHash, to, id, amount));
        return true;
    }
}

interface IBatchHarness {
    function run(address manager, uint256[3][] calldata credits) external returns (uint256 count);
}

contract SolidityBatchHarness is IBatchHarness {
    function run(address manager, uint256[3][] calldata credits) external returns (uint256 count) {
        ClaimTransfers.Batch memory batch;
        for (uint256 i; i < credits.length; ++i) {
            ClaimTransfers.credit(
                batch,
                IPoolManager(manager),
                Currency.wrap(address(uint160(credits[i][0]))),
                address(uint160(credits[i][1])),
                credits[i][2]
            );
        }
        count = batch.count;
        ClaimTransfers.flush(batch, IPoolManager(manager));
    }
}

contract ClaimTransfersParityTest is Test {
    IBatchHarness huff;
    IBatchHarness solidityBatch;
    BatchManager hm;
    BatchManager sm;

    function setUp() public {
        huff = IBatchHarness(HuffNeoDeployer.deploy("src/experimental/ClaimTransfers.huff"));
        solidityBatch = new SolidityBatchHarness();
        hm = new BatchManager();
        sm = new BatchManager();
        for (uint256 id = 1; id <= 2; ++id) {
            hm.seed(address(huff), id, type(uint256).max);
            sm.seed(address(solidityBatch), id, type(uint256).max);
        }
    }

    function _compare(uint256[3][] memory credits) internal {
        assertEq(huff.run(address(hm), credits), solidityBatch.run(address(sm), credits), "unique credit count");
        assertEq(hm.calls(), sm.calls(), "coalesced transfer count");
        assertEq(hm.transferHash(), sm.transferHash(), "amounts and first-credit transfer order");
        for (uint256 id = 1; id <= 2; ++id) {
            assertEq(hm.balance(address(huff), id), sm.balance(address(solidityBatch), id), "escrow remainder");
        }
    }

    function testFuzz_duplicateCurrencyAndRecipient(uint256 seed) public {
        uint256[3][] memory credits = new uint256[3][](64);
        for (uint256 i; i < credits.length; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            credits[i] = [1 + (seed & 1), 100 + ((seed >> 8) % 17), uint256(uint64(seed >> 16))];
        }
        _compare(credits);
    }

    function test_capacityThirtyFourCreditsAndZeroAmounts() public {
        uint256[3][] memory credits = new uint256[3][](35);
        for (uint256 i; i < 34; ++i) {
            credits[i] = [1 + i % 2, 100 + i / 2, uint256(1)];
        }
        credits[34] = [uint256(1), 999, 0];
        _compare(credits);
        assertEq(hm.calls(), 34);
    }

    function test_selfTransfersDoNotAggregateOrOverflow() public {
        uint256[3][] memory credits = new uint256[3][](2);
        credits[0] = [uint256(1), uint256(uint160(address(huff))), type(uint256).max];
        credits[1] = credits[0];
        assertEq(huff.run(address(hm), credits), 0);
        credits[0][1] = uint256(uint160(address(solidityBatch)));
        credits[1][1] = uint256(uint160(address(solidityBatch)));
        assertEq(solidityBatch.run(address(sm), credits), 0);
        assertEq(hm.calls(), 2);
        assertEq(hm.calls(), sm.calls());
        assertEq(hm.balance(address(huff), 1), type(uint256).max);
        assertEq(sm.balance(address(solidityBatch), 1), type(uint256).max);
    }

    function test_accumulationOverflowRevertsBeforeTransfers() public {
        uint256[3][] memory credits = new uint256[3][](2);
        credits[0] = [uint256(1), 100, type(uint256).max];
        credits[1] = [uint256(1), 100, 1];
        vm.expectRevert(stdError.arithmeticError);
        huff.run(address(hm), credits);
        vm.expectRevert(stdError.arithmeticError);
        solidityBatch.run(address(sm), credits);
        assertEq(hm.calls(), 0);
        assertEq(sm.calls(), 0);
    }

    function test_failedFlushRollsBackEarlierTransfers() public {
        uint256[3][] memory credits = new uint256[3][](2);
        credits[0] = [uint256(1), 100, type(uint256).max];
        credits[1] = [uint256(1), 101, 1];
        vm.expectRevert(stdError.arithmeticError);
        huff.run(address(hm), credits);
        vm.expectRevert(stdError.arithmeticError);
        solidityBatch.run(address(sm), credits);
        assertEq(hm.calls(), 0);
        assertEq(sm.calls(), 0);
        assertEq(hm.balance(address(100), 1), 0);
        assertEq(hm.balance(address(huff), 1), type(uint256).max);
    }
}
