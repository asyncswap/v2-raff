// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SetupHook} from "./SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {TickPrice} from "@async-swap/libraries/TickPrice.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Slow specification: scan all orders, compare rational limits, and settle at maker price.
/// @dev No production tree, selection, matching, fee or reduction helper is used. TickPrice is shared
///      only to reproduce the documented queue-age reset when rounding moves a remainder to a new tick.
///      Inputs are deliberately bounded so ordinary cross products fit uint256.
contract MatchingReferenceTest is SetupHook {
    struct RefOrder {
        AsyncOrder order;
        uint256 input;
        uint256 minimum;
        uint256 fee;
        uint64 sequence;
        uint64 created;
    }

    struct Fill {
        bytes32 ask;
        bytes32 bid;
        uint256 asset;
        uint256 quote;
    }
    RefOrder[] internal refs;
    Fill[] internal expected;
    uint64 internal sequence;
    mapping(address => uint256) internal assetClaims;
    mapping(address => uint256) internal quoteClaims;
    uint256 internal partialFills;
    uint256 internal dustClosures;
    uint256 internal reprices;
    uint256 internal matches;
    bytes32 constant MATCH = keccak256("AsyncOrdersMatched(bytes32,bytes32,bytes32,uint256,uint256)");

    function _ceil(uint256 n, uint256 d) internal pure returns (uint256) {
        return n / d + (n % d == 0 ? 0 : 1);
    }

    function _id(RefOrder storage r) internal view returns (bytes32) {
        return _orderIdFor(r.order.owner, r.order.zeroForOne, r.order.salt);
    }

    function _tick(RefOrder storage r) internal view returns (uint128) {
        return TickPrice.key(!r.order.zeroForOne, r.order.zeroForOne, r.input, r.minimum);
    }

    function _best(bool buy) internal view returns (uint256 best) {
        best = type(uint256).max;
        for (uint256 i; i < refs.length; ++i) {
            RefOrder storage a = refs[i];
            if (a.input == 0 || a.order.zeroForOne == buy) continue;
            if (best == type(uint256).max) {
                best = i;
                continue;
            }
            RefOrder storage b = refs[best];
            uint256 l = buy ? a.input * b.minimum : a.minimum * b.input;
            uint256 r = buy ? b.input * a.minimum : b.minimum * a.input;
            bool ahead = l == r ? (a.fee == b.fee ? a.sequence < b.sequence : a.fee > b.fee) : (buy ? l > r : l < r);
            if (ahead) best = i;
        }
    }

    function _reduce(uint256 index, uint256 consumed) internal {
        RefOrder storage r = refs[index];
        uint128 oldTick = _tick(r);
        uint256 rest = r.input - consumed;
        uint256 feeSpent = r.fee * consumed / r.input;
        quoteClaims[address(hook.feeVault())] += feeSpent;
        r.fee -= feeSpent;
        r.minimum = _ceil(r.minimum * rest, r.input);
        r.input = rest;
        if (rest == 0 || (r.order.zeroForOne ? r.minimum : rest) < hookMinOrderUsd * 1e6) {
            if (rest != 0) {
                ++dustClosures;
                if (r.order.zeroForOne) assetClaims[r.order.owner] += rest;
                else quoteClaims[r.order.owner] += rest;
            }
            quoteClaims[address(hook.feeVault())] += r.fee;
            r.input = 0;
            r.minimum = 0;
            r.fee = 0;
            r.sequence = 0;
        } else {
            ++partialFills;
            if (_tick(r) != oldTick) r.sequence = ++sequence;
        }
    }

    function _clearModel(uint8 bound) internal {
        delete expected;
        for (uint256 i; i < bound; ++i) {
            uint256 bi = _best(true);
            uint256 ai = _best(false);
            if (bi == type(uint256).max || ai == type(uint256).max) break;
            RefOrder storage b = refs[bi];
            RefOrder storage a = refs[ai];
            if (b.input * a.input < a.minimum * b.minimum) break;
            // Spend as much of the older maker's input as the other side can afford.
            bool makerBuy = b.created < a.created;
            RefOrder storage maker = makerBuy ? b : a;
            RefOrder storage taker = makerBuy ? a : b;
            uint256 used = taker.input * maker.input / maker.minimum;
            if (used > maker.input) used = maker.input;
            uint256 paid = _ceil(used * maker.minimum, maker.input);
            // Integer settlement must satisfy the taker's proportional minimum too.
            if (used == 0 || paid == 0 || used * taker.input < paid * taker.minimum) break;
            uint256 asset = makerBuy ? paid : used;
            uint256 quote = makerBuy ? used : paid;
            expected.push(Fill(_id(a), _id(b), asset, quote));
            ++matches;
            uint256 af = _ceil(asset, 5000);
            uint256 qf = _ceil(quote, 5000);
            assetClaims[b.order.owner] += asset - af;
            quoteClaims[a.order.owner] += quote - qf;
            assetClaims[address(hook.feeVault())] += af;
            quoteClaims[address(hook.feeVault())] += qf;
            // Sell is reduced first: tick changes consume queue sequence in that order.
            _reduce(ai, asset);
            _reduce(bi, quote);
        }
    }

    function _events(Vm.Log[] memory logs) internal view {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics.length != 4 || logs[i].topics[0] != MATCH) continue;
            assertLt(n, expected.length, "unexpected match");
            Fill storage f = expected[n++];
            assertEq(logs[i].topics[2], f.ask, "ask selected");
            assertEq(logs[i].topics[3], f.bid, "bid selected");
            (uint256 asset, uint256 quote) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(asset, f.asset, "asset execution");
            assertEq(quote, f.quote, "quote execution");
        }
        assertEq(n, expected.length, "missing match");
    }

    function _check() internal view {
        uint256 assetEscrow;
        uint256 quoteEscrow;
        for (uint256 i; i < refs.length; ++i) {
            RefOrder storage r = refs[i];
            (, uint256 ai, uint256 ao,,, uint64 seq, uint64 fee) = hook.orderBookOrder(poolId, _id(r));
            assertEq(ai, r.input, "remaining input");
            assertEq(ao, r.minimum, "remaining minimum");
            assertEq(seq, r.sequence, "queue age");
            assertEq(fee, r.fee, "remaining fee");
            if (r.input != 0) assertEq(hook.orderCreatedSequence(poolId, _id(r)), r.created, "maker age");
            assertEq(manager.balanceOf(r.order.owner, currency0.toId()), assetClaims[r.order.owner], "asset claim");
            assertEq(manager.balanceOf(r.order.owner, currency1.toId()), quoteClaims[r.order.owner], "quote claim");
            if (r.order.zeroForOne) assetEscrow += r.input;
            else quoteEscrow += r.input;
            quoteEscrow += r.fee;
        }
        assertEq(manager.balanceOf(address(hook), currency0.toId()), assetEscrow, "asset escrow");
        assertEq(manager.balanceOf(address(hook), currency1.toId()), quoteEscrow, "quote escrow");
        address vault = address(hook.feeVault());
        assertEq(manager.balanceOf(vault, currency0.toId()), assetClaims[vault], "asset fees");
        assertEq(manager.balanceOf(vault, currency1.toId()), quoteClaims[vault], "quote fees");
        for (uint256 side; side < 2; ++side) {
            bool buy = side == 0;
            uint256 best = _best(buy);
            (bool found,, bytes32 id,) = hook.bestOrder(poolId, buy);
            assertEq(found, best != type(uint256).max, "best exists");
            if (found) assertEq(id, _id(refs[best]), "best exact price/fee/age");
        }
    }

    function _submit(bool sell, uint256 input, uint256 minimum, uint256 fee) internal {
        address actor = address(uint160(0x70000 + refs.length));
        topUp(actor, 1e30);
        vm.prank(actor);
        token0.approve(address(router), type(uint256).max);
        vm.roll(block.number + 1);
        AsyncOrder memory o = AsyncOrder(key, actor, sell, input, minimum, fee, 2 ** 96, bytes32(0));
        vm.recordLogs();
        vm.prank(actor);
        router.swap(o, abi.encode(AsyncSwap.UserParams(actor, address(router), minimum, fee)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        o.salt = keccak256(abi.encode(block.timestamp, block.number, address(manager), actor, input, minimum, fee));
        uint64 next = ++sequence;
        refs.push(RefOrder(o, input, minimum, fee, next, next));
        _clearModel(8);
        _events(logs);
        _check();
    }

    function _clear(uint8 n) internal {
        vm.recordLogs();
        router.matchBook(key, n);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _clearModel(n);
        _events(logs);
        _check();
    }

    function _reprice(uint256 index, uint256 minimum) internal {
        RefOrder storage r = refs[index];
        if (r.input == 0 || minimum == 0) return;
        if ((r.order.zeroForOne ? minimum : r.input) < hookMinOrderUsd * 1e6) return;
        uint256 requiredFee = minimum / 1000;
        if (requiredFee > 100_000) requiredFee = 100_000;
        if (r.order.zeroForOne && r.fee != 0 && minimum > r.minimum && r.fee < requiredFee) return;
        vm.prank(r.order.owner);
        hook.updatePrice(r.order, minimum);
        r.minimum = minimum;
        r.sequence = ++sequence;
        ++reprices;
        // A reprice resets queue age, preserves maker age, and does not clear the book.
        _check();
    }

    function _topUpFee(uint256 index, uint256 addedFee) internal {
        RefOrder storage r = refs[index];
        if (r.input == 0) return;
        // Independent admission rule: the resulting bid meets the remaining order's minimum.
        uint256 floor = (r.order.zeroForOne ? r.minimum : r.input) / 1000;
        if (floor > 100_000) floor = 100_000;
        if (r.fee + addedFee < floor) addedFee = floor - r.fee;
        vm.prank(r.order.owner);
        router.topUpPriorityFee(r.order, addedFee);
        r.fee += addedFee;
        r.sequence = ++sequence;
        _check();
    }

    function _cancel(uint256 index) internal {
        RefOrder storage r = refs[index];
        if (r.input == 0) return;
        vm.prank(r.order.owner);
        router.cancelOrder(r.order);
        quoteClaims[address(hook.feeVault())] += r.fee;
        r.input = 0;
        r.minimum = 0;
        r.fee = 0;
        r.sequence = 0;
        _check();
    }

    function testFuzz_referenceMixedOperations(uint256 seed) public {
        for (uint256 step; step < 64; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 action = seed % 8;
            uint256 index = refs.length == 0 ? 0 : (seed >> 8) % refs.length;
            if (action < 4 || refs.length == 0) {
                bool sell = seed & 256 != 0;
                uint256 amount = (1 + ((seed >> 16) % 8)) * 0.25 ether + (seed >> 32) % 13;
                // Alternate a wide spread with exact limits close enough to share tick levels.
                uint256 price = step % 2 == 0 ? 2_000e6 + (seed >> 48) % 100_000 : (1_000 + (seed >> 48) % 2001) * 1e6;
                uint256 quote = amount * price / 1 ether;
                uint256 fee = (seed >> 80) % 3 == 0 ? 0 : 100_000 + (seed >> 96) % 10 * 100_000;
                _submit(sell, sell ? amount : quote, sell ? quote : amount, fee);
            } else if (action == 4) {
                _cancel(index);
            } else if (action == 6) {
                _topUpFee(index, 1 + (seed >> 96) % 1_000_000);
            } else if (action == 5) {
                RefOrder storage r = refs[index];
                uint256 price = (1_000 + (seed >> 48) % 2001) * 1e6;
                _reprice(index, r.order.zeroForOne ? r.input * price / 1 ether : r.input * 1 ether / price);
            } else {
                _clear(uint8(1 + (seed >> 120) % 8));
            }
        }
        for (uint256 i; i < 8; ++i) {
            _clear(8);
        }
    }

    function test_referenceTopUpsPreserveMakerAgeAndSettleNewBid() public {
        _submit(true, 2 ether, 4_000e6, 100_000);
        _submit(false, 6_000e6, 6 ether, 100_000);
        _topUpFee(0, 200_000);
        _reprice(1, 2 ether);
        _clear(1);
        assertEq(expected[0].quote, 4_000e6, "original maker sets settlement price");
        assertEq(refs[0].input, 0);
        assertGt(quoteClaims[address(hook.feeVault())], 300_000);
    }

    function test_referenceBacklogClearsInBoundedCalls() public {
        for (uint256 i; i < 20; ++i) {
            _submit(true, 1 ether, 2_000e6, 100_000);
        }
        _submit(false, 60_000e6, 60 ether, 100_000);
        _reprice(20, 20 ether);
        assertEq(matches, 0);
        _clear(8);
        assertEq(expected.length, 8);
        _clear(8);
        assertEq(expected.length, 8);
        _clear(8);
        assertEq(expected.length, 4);
        _clear(8);
        assertEq(expected.length, 0);
        assertEq(matches, 20);
        assertGt(partialFills, 0);
    }

    function test_referenceExactPriceFeeAndMakerAge() public {
        _submit(true, 2 ether, 4_000e6, 100_000);
        _submit(true, 1 ether, 2_000e6, 500_000);
        _submit(false, 1_000e6, 0.5 ether, 100_000);
        assertEq(expected[0].ask, _id(refs[1]));
        _submit(false, 3_000e6, 3 ether, 100_000);
        _reprice(0, 1_000e6);
        _clear(1);
        assertEq(expected[0].ask, _id(refs[0]));
        assertEq(expected[0].quote, 1_000e6, "repriced old maker sets price");
        assertGt(partialFills, 0);
        assertGt(reprices, 0);
    }
}

contract DustMatchingReferenceTest is MatchingReferenceTest {
    function setUp() public override {
        hookMinOrderUsd = 1;
        super.setUp();
    }

    function test_referenceClosesAndRefundsDust() public {
        _submit(true, 1 ether, 2_000e6, 100_000);
        _submit(false, 1_999_500_000, 0.5 ether, 100_000);
        assertEq(dustClosures, 1);
        assertGt(assetClaims[refs[0].order.owner], 0);
    }
}
