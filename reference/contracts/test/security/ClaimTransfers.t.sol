// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {ClaimTransfers} from "../../src/libraries/ClaimTransfers.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";

contract ClaimTransferManager {
    mapping(address => mapping(uint256 => uint256)) public balance;
    uint256 public calls;

    function seed(address owner, uint256 id, uint256 amount) external {
        balance[owner][id] = amount;
    }

    function transfer(address to, uint256 id, uint256 amount) external returns (bool) {
        balance[msg.sender][id] -= amount;
        balance[to][id] += amount;
        ++calls;
        return true;
    }
}

contract ClaimTransfersTest is Test {
    function test_aggregatesByRecipientAndCurrencyInFirstCreditOrder() public {
        ClaimTransferManager m = new ClaimTransferManager();
        IPoolManager manager = IPoolManager(address(m));
        Currency a = Currency.wrap(address(1));
        Currency b = Currency.wrap(address(2));
        address alice = address(3);
        m.seed(address(this), 1, 1000);
        m.seed(address(this), 2, 1000);
        ClaimTransfers.Batch memory batch;
        ClaimTransfers.credit(batch, manager, a, alice, 100);
        ClaimTransfers.credit(batch, manager, b, alice, 400);
        ClaimTransfers.credit(batch, manager, a, alice, 200);
        assertEq(batch.count, 2);
        assertEq(batch.credits[0].amount, 300);
        assertEq(batch.credits[1].amount, 400);
        assertEq(m.calls(), 0);
        ClaimTransfers.flush(batch, manager);
        assertEq(m.calls(), 2);
        assertEq(m.balance(alice, 1), 300);
        assertEq(m.balance(alice, 2), 400);
        assertEq(m.balance(address(this), 1), 700);
        assertEq(m.balance(address(this), 2), 600);
    }

    function test_selfCreditsDoNotAggregateOrOverflow() public {
        ClaimTransferManager m = new ClaimTransferManager();
        IPoolManager manager = IPoolManager(address(m));
        Currency a = Currency.wrap(address(1));
        m.seed(address(this), 1, type(uint256).max);
        ClaimTransfers.Batch memory batch;
        ClaimTransfers.credit(batch, manager, a, address(this), type(uint256).max);
        ClaimTransfers.credit(batch, manager, a, address(this), type(uint256).max);
        assertEq(batch.count, 0);
        assertEq(m.calls(), 2);
        assertEq(m.balance(address(this), 1), type(uint256).max);
    }

    function test_capacityCoversThirtyThreeDistinctCredits() public {
        ClaimTransferManager m = new ClaimTransferManager();
        IPoolManager manager = IPoolManager(address(m));
        Currency a = Currency.wrap(address(1));
        m.seed(address(this), 1, 33);
        ClaimTransfers.Batch memory batch;
        for (uint160 i = 1; i <= 33; ++i) {
            ClaimTransfers.credit(batch, manager, a, address(i), 1);
        }
        assertEq(batch.count, 33);
        ClaimTransfers.flush(batch, manager);
        assertEq(m.calls(), 33);
        assertEq(m.balance(address(this), 1), 0);
    }
}
