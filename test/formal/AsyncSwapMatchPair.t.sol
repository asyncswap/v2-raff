// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalMatchD} from "./FormalMatchD.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {stdError} from "forge-std/StdError.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapMatchPair.lean`. `_matchPair` is private;
///         `matchBook(key, 1)` runs it exactly once, as `_matchPair(bidId, askId)`, on a crossed book of
///         one resting sell and one resting buy (`FormalMatchD`). Its result is `matchBook`'s return
///         value (1 for `true`), its effects are the decoded PoolManager / hook event trace and the two
///         orders' storage. Skipped pairs are written with `vm.store` (an emptied order, or both orders
///         on one side) while the book keys still cross, so `matchBook` reaches `_matchPair`.
contract AsyncSwapMatchPairFormalTest is FormalMatchD {
    /// @notice formal/Refinement/Swarm/AsyncSwapMatchPair.lean:143 — an empty order or two orders on the same side: `_matchPair` returns false and leaves the world unchanged.
    function testFuzz_matchPair_skip(uint256[6] memory s, uint8 flags, uint8 mode) public {
        Case memory c = _mkCase(s, flags);
        if (!_strictCross(c)) return;
        _makeSkip(c, mode);
        vm.record();
        Run memory r = _exec(c);
        (, bytes32[] memory writes) = vm.accesses(address(hook));
        assertEq(r.matched, 0, "false");
        assertEq(r.ops.length, 0, "no transfer, settlement or event");
        assertEq(writes.length, 0, "no hook SSTORE");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMatchPair.lean:164 — a non-skipped pair is `_matchAmounts` (older side resting), then false with no effect on a zero amount, else `_settleTransfers` then `_reduceMatchedOrders`, then true.
    function testFuzz_matchPair_eq(uint256[6] memory s, uint8 flags) public {
        Case memory c = _mkCase(s, flags);
        if (!_strictCross(c)) return;
        vm.record();
        Run memory r = _exec(c);
        (, bytes32[] memory writes) = vm.accesses(address(hook));
        if (r.asset == 0 || r.quote == 0) {
            assertEq(r.matched, 0, "zero amount: false");
            assertEq(r.ops.length, 0, "zero amount: no effect");
            assertEq(writes.length, 0, "zero amount: no hook SSTORE");
        } else {
            assertEq(r.matched, 1, "true");
            _assertOps(r.ops, _expected(c, r));
            _assertReductions(c, r);
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMatchPair.lean:208 — the `_matchAmounts` run inside `_matchPair` (orders read at entry) leaves the world unchanged and returns `amountsOf` (the spec amounts).
    function testFuzz_matchRun_ok(uint256[6] memory s, uint8 flags) public {
        Case memory c = _mkCase(s, flags);
        if (!_strictCross(c)) return;
        vm.record();
        Run memory r = _exec(c);
        (, bytes32[] memory writes) = vm.accesses(address(hook));
        if (r.asset == 0 || r.quote == 0) {
            assertEq(r.matched, 0, "zero spec amount: false");
            assertEq(writes.length, 0, "world unchanged");
        } else {
            Op memory m = r.ops[r.ops.length - 1];
            assertEq(m.kind, OP_MATCHED, "match event");
            assertEq(m.amount, r.asset, "assetAmount = amountsOf");
            assertEq(m.amount2, r.quote, "quoteAmount = amountsOf");
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMatchPair.lean:221 — every successful run is a skip (false, no effect), a zero spec amount (false, no effect), or non-zero spec amounts: true after `_settleTransfers` then `_reduceMatchedOrders` with those amounts.
    function testFuzz_matchPair_ok(uint256[6] memory s, uint8 flags, uint8 mode) public {
        Case memory c = _mkCase(s, flags);
        if (!_strictCross(c)) return;
        bool skip = mode % 5 != 4;
        if (skip) _makeSkip(c, mode);
        vm.record();
        Run memory r = _exec(c);
        (, bytes32[] memory writes) = vm.accesses(address(hook));
        if (skip || r.asset == 0 || r.quote == 0) {
            assertEq(r.matched, 0, "false");
            assertEq(r.ops.length, 0, "no effect");
            assertEq(writes.length, 0, "no hook SSTORE");
        } else {
            assertEq(r.matched, 1, "true");
            _assertOps(r.ops, _expected(c, r));
            _assertReductions(c, r);
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMatchPair.lean:273 — a true result: non-zero spec amounts within both escrows and both limits; burn/payout of the asset leg, burn/payout of the quote leg, then the sell and buy reductions consuming exactly assetAmount and quoteAmount.
    function testFuzz_matchPair_true(uint256[6] memory s, uint8 flags) public {
        Case memory c = _mkCase(s, flags);
        Run memory r = _exec(c);
        if (r.matched == 0) return;
        assertTrue(r.asset != 0 && r.quote != 0, "non-zero amounts");
        assertLe(r.asset, r.sell0.amountIn, "asset <= sell escrow");
        assertLe(r.quote, r.buy0.amountIn, "quote <= buy escrow");
        assertLe(r.asset * r.sell0.amountOutMin, r.quote * r.sell0.amountIn, "seller limit");
        assertLe(r.quote * r.buy0.amountOutMin, r.asset * r.buy0.amountIn, "buyer limit");
        Op[] memory want = _expected(c, r);
        _assertOps(_prefix(r.ops, 4), _prefix(want, 4)); // the two escrow legs, in order
        _assertOps(r.ops, want);
        if (!_closes(r.sell0, r.asset, r.quote)) assertEq(r.sell1.amountIn, r.sell0.amountIn - r.asset, "sell used");
        if (!_closes(r.buy0, r.quote, r.asset)) assertEq(r.buy1.amountIn, r.buy0.amountIn - r.quote, "buy used");
        _assertReductions(c, r);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMatchPair.lean:319 — a revert never happens on a skipped pair; otherwise it is the revert of `_matchAmounts`, `_settleTransfers` (non-zero amounts) or `_reduceMatchedOrders`. Every PoolManager.burn is mocked to revert.
    function testFuzz_matchPair_error(uint256[6] memory s, uint8 flags, uint8 mode, uint256 tag) public {
        Case memory c = _mkCase(s, flags);
        if (!_strictCross(c)) return;
        bool skip = mode % 5 != 4;
        if (skip) _makeSkip(c, mode);
        bytes memory reason = abi.encodeWithSignature("MockedBurn(uint256)", tag);
        vm.mockCallRevert(address(manager), abi.encodeWithSelector(IPoolManager.burn.selector), reason);
        (uint256 asset, uint256 quote) = _spec(
            _info(c.pid, c.sellId).amountIn,
            _info(c.pid, c.sellId).amountOutMin,
            _info(c.pid, c.buyId).amountIn,
            _info(c.pid, c.buyId).amountOutMin,
            c.restingBuy
        );
        if (skip || asset == 0 || quote == 0) {
            bytes[] memory res = _runR(_matchCalls(c.k));
            assertEq(abi.decode(res[0], (uint8)), 0, "no revert, false");
        } else {
            vm.expectRevert(reason); // the asset leg's burn, inside `_settleTransfers`
            _run(_matchCalls(c.k));
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMatchPair.lean:364 — a non-skipped pair whose resting (older) order has amountOutMin = 0 reverts with panic 0x12 when `sell.amountIn * buy.amountIn < 2^256` and with `MathOverflowedMulDiv` otherwise. With `small`, both amounts are below 2^128 so the product fits one word.
    function testFuzz_matchPair_reverts_restingZero(
        uint256[6] memory s,
        bool rb,
        uint256 sellIn,
        uint256 buyIn,
        bool small
    ) public {
        Case memory c = _mkCase(s, rb ? 1 : 0);
        if (!_strictCross(c)) return;
        uint256 maxIn = small ? type(uint128).max : type(uint256).max;
        sellIn = bound(sellIn, 1, maxIn);
        buyIn = bound(buyIn, 1, maxIn);
        _storeWord(c.pid, c.sellId, 1, sellIn);
        _storeWord(c.pid, c.buyId, 1, buyIn);
        _storeWord(c.pid, rb ? c.buyId : c.sellId, 2, 0);
        // sell.amountIn * buy.amountIn < 2^256 (buyIn >= 1)
        if (sellIn <= type(uint256).max / buyIn) vm.expectRevert(stdError.divisionError);
        else vm.expectRevert(Math.MathOverflowedMulDiv.selector);
        _run(_matchCalls(c.k));
    }
}
