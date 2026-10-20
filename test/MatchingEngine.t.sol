// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HuffDeploy} from "./utils/HuffDeploy.sol";

import {Test, Vm} from "forge-std/Test.sol";
import {IMatchingEngine as MatchingEngine} from "src/interface/IMatchingEngine.sol";

contract MatchingEngineTest is Test {
    MatchingEngine private engine;
    bytes32 private constant MARKET = keccak256("ETH/USDC");
    uint128 private constant WAD = 1e18;

    function setUp() public {
        engine = HuffDeploy.matchingEngine();
    }

    function testBestPricesAreOrderedByTheRadixTree() public {
        _ask(3 * WAD, WAD);
        _ask(2 * WAD, WAD);
        _ask(5 * WAD, WAD);
        _bid(WAD, WAD);

        (bool hasAsk, uint128 bestAsk) = engine.bestPrice(MARKET, false);
        (bool hasBid, uint128 bestBid) = engine.bestPrice(MARKET, true);
        assertTrue(hasAsk && hasBid);
        assertEq(bestAsk, 2 * WAD);
        assertEq(bestBid, WAD);
    }

    function testPriceTimePriorityAndPartialFills() public {
        uint64 firstAsk = _ask(2 * WAD, 3 * WAD);
        uint64 secondAsk = _ask(2 * WAD, 4 * WAD);

        vm.recordLogs();
        uint64 bid = _bid(3 * WAD, 5 * WAD);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint64 maker, uint64 taker, uint128 quantity, uint128 price) = _firstFill(logs);

        assertEq(maker, firstAsk);
        assertEq(taker, bid);
        assertEq(quantity, 3 * WAD);
        assertEq(price, 2 * WAD);
        assertEq(engine.getOrder(MARKET, firstAsk).remaining, 0);
        assertEq(engine.getOrder(MARKET, secondAsk).remaining, 2 * WAD);
        assertEq(engine.getOrder(MARKET, bid).remaining, 0);
    }

    function testCancelUnlinksMiddleOfPriceLevel() public {
        uint64 first = _ask(2 * WAD, WAD);
        uint64 middle = _ask(2 * WAD, WAD);
        uint64 last = _ask(2 * WAD, WAD);

        vm.prank(engine.getOrder(MARKET, middle).owner);
        engine.cancelOrder(MARKET, middle);

        assertEq(engine.levelOrderCount(MARKET, false, 2 * WAD), 2);
        vm.recordLogs();
        uint64 bid = _bid(2 * WAD, WAD);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint64 maker,,,) = _firstFill(logs);
        assertEq(maker, first);
        assertEq(engine.getOrder(MARKET, last).remaining, WAD);
        assertEq(engine.getOrder(MARKET, bid).remaining, 0);
    }

    function testPartiallyFilledOrderKeepsItsTimePriority() public {
        uint64 firstAsk = _ask(2 * WAD, 5 * WAD);
        uint64 secondAsk = _ask(2 * WAD, 5 * WAD);
        _bid(2 * WAD, 2 * WAD);
        assertEq(engine.getOrder(MARKET, firstAsk).remaining, 3 * WAD);

        vm.recordLogs();
        _bid(2 * WAD, 2 * WAD);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint64 maker,,,) = _firstFill(logs);
        assertEq(maker, firstAsk);
        assertEq(engine.getOrder(MARKET, firstAsk).remaining, WAD);
        assertEq(engine.getOrder(MARKET, secondAsk).remaining, 5 * WAD);
    }

    function testCrossedRemainderCanBeClearedInBoundedChunks() public {
        uint64[9] memory asks;
        for (uint256 i; i < asks.length; ++i) {
            asks[i] = _ask(2 * WAD, WAD);
        }

        uint64 bid = _bid(2 * WAD, 9 * WAD);
        assertEq(engine.getOrder(MARKET, bid).remaining, WAD);
        assertEq(engine.levelOrderCount(MARKET, true, 2 * WAD), 1);
        assertEq(engine.levelOrderCount(MARKET, false, 2 * WAD), 1);

        uint8 cleared = engine.matchBook(MARKET, engine.MAX_MATCHES_PER_CALL());
        assertEq(cleared, 1);
        assertEq(engine.getOrder(MARKET, bid).remaining, 0);
        assertFalse(engine.getOrder(MARKET, bid).active);
        assertFalse(engine.getOrder(MARKET, asks[8]).active);
    }

    function testMatchBoundCannotBeRaisedByCaller() public {
        vm.expectRevert(MatchingEngine.InvalidMatchBound.selector);
        engine.matchBook(MARKET, 9);
        vm.expectRevert(MatchingEngine.InvalidMatchBound.selector);
        engine.matchBook(MARKET, 0);
    }

    function testFuzzBestAskMatchesMinimum(uint128[16] memory prices) public {
        uint128 expected = type(uint128).max;
        for (uint256 i; i < prices.length; ++i) {
            uint128 price = uint128(uint256(prices[i]) % (1000 * uint256(WAD))) + 1;
            if (price < expected) expected = price;
            _ask(price, WAD);
        }
        (bool found, uint128 best) = engine.bestPrice(MARKET, false);
        assertTrue(found);
        assertEq(best, expected);
    }

    function testGas_100OrdersAtDistinctPrices() public {
        uint256 startGas = gasleft();
        for (uint128 i = 1; i <= 100; ++i) {
            _ask(WAD + i * 1e12, WAD);
        }
        uint256 used = startGas - gasleft();
        emit log_named_uint("gas for 100 unique-price orders", used);
        assertEq(engine.levelOrderCount(MARKET, false, WAD + 100 * 1e12), 1);
    }

    function testGas_OneCallMatchesEightDistinctLevels() public {
        for (uint128 i = 2; i < 10; ++i) {
            _ask(i * WAD, WAD);
        }
        uint256 startGas = gasleft();
        _bid(10 * WAD, 8 * WAD);
        uint256 used = startGas - gasleft();
        emit log_named_uint("gas for one order matching eight levels", used);
        (bool hasAsk,) = engine.bestPrice(MARKET, false);
        assertFalse(hasAsk);
    }

    function _ask(uint128 price, uint128 amount) private returns (uint64 id) {
        id = engine.placeOrder(MARKET, false, amount, price);
    }

    function _bid(uint128 price, uint128 amount) private returns (uint64 id) {
        id = engine.placeOrder(MARKET, true, amount, price);
    }

    function _firstFill(Vm.Log[] memory logs)
        private
        returns (uint64 maker, uint64 taker, uint128 quantity, uint128 price)
    {
        bytes32 signature = keccak256("OrderFilled(bytes32,uint64,uint64,uint128,uint128,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(engine) || logs[i].topics[0] != signature) continue;
            (quantity, price,) = abi.decode(logs[i].data, (uint128, uint128, uint256));
            maker = uint64(uint256(logs[i].topics[2]));
            taker = uint64(uint256(logs[i].topics[3]));
            return (maker, taker, quantity, price);
        }
        fail("fill event not emitted");
    }
}
