// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalMatchD} from "./FormalMatchD.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapSettleMatchedPriorityFee.lean`.
///         `_settleMatchedPriorityFee` is private; `_reduceAfterMatch` runs it first, once per side of a
///         matched pair, reached through `matchBook(key, 1)` (`FormalMatchD`). The settlement it makes is
///         the side's first `PriorityFeeDonated` / `PriorityFeeForfeited` event (with the PoolManager
///         calls before it); the value it returns (`unfilled`) is what `_reduceAfterMatch` stores as the
///         order's `priorityFee` (partial) or settles for the owner on close.
contract AsyncSwapSettleMatchedPriorityFeeFormalTest is FormalMatchD {
    struct Side {
        bytes32 id;
        AsyncFiller.OrderInfo o0;
        AsyncFiller.OrderInfo o1;
        uint256 used;
    }

    function _sides(Case memory c, Run memory r) internal pure returns (Side[2] memory sd) {
        sd[0] = Side(c.sellId, r.sell0, r.sell1, r.asset);
        sd[1] = Side(c.buyId, r.buy0, r.buy1, r.quote);
    }

    /// @dev What `_settleMatchedPriorityFee` returned, read back from where `_reduceAfterMatch` put it.
    function _unfilled(Side memory x, Op[] memory ops) internal pure returns (uint256 u, bool known) {
        if (!_closes(x.o0, x.used)) return (x.o1.priorityFee, true);
        Op[] memory fees = _feesOf(ops, x.id);
        uint256 filled = _filled(x.o0, x.used);
        uint256 k = filled != 0 ? 1 : 0;
        return (fees.length > k ? fees[k].amount : 0, true);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSettleMatchedPriorityFee.lean:37 — no paid fee: returns 0, no effect; otherwise one `settlePriorityFee(owner, fee·inputUsed/oldInput)` and returns fee − filled.
    function testFuzz_settleMatchedPriorityFee_run(uint256[6] memory s, uint8 flags) public {
        Case memory c = _mkCase(s, flags | 4);
        Run memory r = _exec(c);
        if (r.matched == 0) return;
        _assertOps(r.ops, _expected(c, r));
        Side[2] memory sd = _sides(c, r);
        for (uint256 i; i < 2; ++i) {
            Side memory x = sd[i];
            uint256 fee = _paid(x.o0);
            Op[] memory fees = _feesOf(r.ops, x.id);
            (uint256 u,) = _unfilled(x, r.ops);
            if (fee == 0) {
                assertEq(fees.length, 0, "no paid fee: no settlement");
                assertEq(u, 0, "no paid fee: returns 0");
                continue;
            }
            uint256 filled = (fee * x.used) / x.o0.amountIn;
            if (filled != 0) {
                assertEq(fees[0].amount, filled, "settles fee * inputUsed / oldInput");
                assertEq(fees[0].who, x.o0.owner, "for orders[id].owner");
            }
            assertEq(u, fee - filled, "returns fee - filled");
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSettleMatchedPriorityFee.lean:81 — no escrowed (or a zero) fee: succeeds, returns 0 and leaves the world unchanged.
    function testFuzz_settleMatchedPriorityFee_no_fee(uint256[6] memory s, uint8 flags) public {
        // Tiny orders have a zero tiered minimum; exercise zero bids without an unpaid-bid state.
        uint256 f = (uint256(flags) | 64) & ~uint256(4);
        Case memory c = _mkCase(s, f);
        Run memory r = _exec(c);
        if (r.matched == 0) return;
        Side[2] memory sd = _sides(c, r);
        for (uint256 i; i < 2; ++i) {
            assertEq(_paid(sd[i].o0), 0);
            assertEq(_feesOf(r.ops, sd[i].id).length, 0, "no settlement");
            (uint256 u,) = _unfilled(sd[i], r.ops);
            assertEq(u, 0, "returns 0");
        }
        // No bid is forfeited: the FeeVault receives only the two trade fees.
        for (uint256 i; i < r.ops.length; ++i) {
            if (r.ops[i].who != address(hook.feeVault())) continue;
            assertEq(
                r.ops[i].amount,
                r.ops[i].cur == c.k.currency0.toId() ? _tradeFee(r.asset) : _tradeFee(r.quote),
                "nothing forfeited: trade fee only"
            );
        }
        _assertOps(r.ops, _expected(c, r));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSettleMatchedPriorityFee.lean:103 — matching path (inputUsed <= oldInput, oldInput != 0) with an escrowed fee: settles filled = fee·inputUsed/oldInput for the owner and returns fee − filled.
    function testFuzz_settleMatchedPriorityFee_matched(uint256[6] memory s, uint8 flags) public {
        Case memory c = _mkCase(s, flags | 4 | 16 | 32);
        Run memory r = _exec(c);
        if (r.matched == 0) return;
        Side[2] memory sd = _sides(c, r);
        for (uint256 i; i < 2; ++i) {
            Side memory x = sd[i];
            uint256 fee = _paid(x.o0);
            assertGt(fee, 0, "escrowed fee");
            assertLe(x.used, x.o0.amountIn, "inputUsed <= oldInput");
            uint256 filled = (fee * x.used) / x.o0.amountIn;
            Op[] memory fees = _feesOf(r.ops, x.id);
            if (filled != 0) {
                assertEq(fees[0].amount, filled, "matched share settled");
                assertEq(fees[0].who, x.o0.owner, "for the owner");
                assertEq(fees[0].kind, OP_FEE_FORFEITED, "forfeited to the FeeVault regardless of LP liquidity");
            }
            (uint256 u,) = _unfilled(x, r.ops);
            assertEq(u, fee - filled, "returns fee - filled");
        }
        _assertOps(r.ops, _expected(c, r));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSettleMatchedPriorityFee.lean:125 — on success unfilled <= fee, and either no fee (0, no effect) or one settlement of filled <= fee with unfilled + filled = fee.
    function testFuzz_settleMatchedPriorityFee_ok(uint256[6] memory s, uint8 flags) public {
        Case memory c = _mkCase(s, flags);
        Run memory r = _exec(c);
        if (r.matched == 0) return;
        Side[2] memory sd = _sides(c, r);
        for (uint256 i; i < 2; ++i) {
            Side memory x = sd[i];
            uint256 fee = _paid(x.o0);
            (uint256 u,) = _unfilled(x, r.ops);
            assertLe(u, fee, "unfilled <= fee");
            Op[] memory fees = _feesOf(r.ops, x.id);
            uint256 filled = fee == 0 ? 0 : (fee * x.used) / x.o0.amountIn;
            assertLe(filled, fee, "filled <= fee");
            assertEq(u + filled, fee, "unfilled + filled = fee");
            uint256 settled;
            for (uint256 j; j < fees.length; ++j) {
                settled += fees[j].amount;
            }
            // matched share, plus the unfilled share when the order closes: never more than the bid
            assertEq(settled, _closes(x.o0, x.used) ? fee : filled, "fee split exactly once");
        }
    }
}
