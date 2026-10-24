// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalMatchD} from "./FormalMatchD.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapReduceMatchedOrders.lean`.
///         `_reduceMatchedOrders` is private; `_matchPair` runs it after `_settleTransfers`, reached through
///         `matchBook(key, 1)` (`FormalMatchD`). Its effects are the events after the four escrow-leg
///         events (priority-fee settlements, refunds) and the two orders' storage afterwards. Priority
///         fees are switched on (PriorityFee mode, paid bids) where the order of the two reductions has to
///         be visible.
contract AsyncSwapReduceMatchedOrdersFormalTest is FormalMatchD {
    /// @dev The reduction ops of one side (`_reduceAfterMatch`), as the trace shows them.
    function _sideOps(Case memory c, bytes32 id, uint256 used, uint256 received, bool sell, Run memory r)
        internal
        view
        returns (Op[] memory)
    {
        Trace memory t = _newTrace();
        _reduceOps(t, c, id, sell ? r.sell0 : r.buy0, used, received, sell ? c.k.currency0 : c.k.currency1);
        return _done(t);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapReduceMatchedOrders.lean:68 — the reduction of the sell order (asset in, quote out) followed by that of the buy order (quote in, asset out), sides and input currencies read at entry; nothing else.
    function testFuzz_reduceMatchedOrders_eq(uint256[6] memory s, uint8 flags) public {
        Case memory c = _mkCase(s, flags | 4 | 16 | 32);
        Run memory r = _exec(c);
        if (r.matched == 0) return;
        Op[] memory sellOps = _sideOps(c, c.sellId, r.asset, r.quote, true, r);
        Op[] memory buyOps = _sideOps(c, c.buyId, r.quote, r.asset, false, r);
        assertEq(r.ops.length, 4 + sellOps.length + buyOps.length + 1, "legs, sell reduction, buy reduction, event");
        for (uint256 i; i < sellOps.length; ++i) {
            _assertOp(r.ops[4 + i], sellOps[i], "sell reduction first");
        }
        for (uint256 i; i < buyOps.length; ++i) {
            _assertOp(r.ops[4 + sellOps.length + i], buyOps[i], "then the buy reduction");
        }
        _assertReductions(c, r);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapReduceMatchedOrders.lean:127 — the call succeeds exactly when the sell reduction succeeds and then the buy reduction succeeds (a PoolManager call of the buy reduction is mocked to revert).
    function testFuzz_reduceMatchedOrders_ok_iff(uint256[6] memory s, uint8 flags, bool failBuy, uint256 tag) public {
        Case memory c = _mkCase(s, flags);
        if (!failBuy) {
            Run memory r = _exec(c);
            if (r.matched == 0) return;
            _assertOps(r.ops, _expected(c, r));
            _assertReductions(c, r);
            return;
        }
        (bool matches, uint256 asset, uint256 quote) = _pre(c);
        if (!matches) return;
        Run memory pre;
        pre.sell0 = _info(c.pid, c.sellId);
        pre.buy0 = _info(c.pid, c.buyId);
        Op[] memory buyOps = _sideOps(c, c.buyId, quote, asset, false, pre);
        uint256 i;
        while (i < buyOps.length && (buyOps[i].kind == OP_FEE_DONATED || buyOps[i].kind == OP_FEE_FORFEITED)) ++i;
        if (i == buyOps.length) return; // the buy reduction makes no PoolManager call here
        bytes memory reason = abi.encodeWithSignature("MockedBuyReduction(uint256)", tag);
        _mockOpRevert(buyOps[i], reason);
        vm.expectRevert(reason);
        _run(_matchCalls(c.k));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapReduceMatchedOrders.lean:148 — on success the sell order held at least assetAmount at entry and the buy order at least quoteAmount once the sell side was reduced.
    function testFuzz_reduceMatchedOrders_ok_bounds(uint256[6] memory s, uint8 flags) public {
        Case memory c = _mkCase(s, flags);
        Run memory r = _exec(c);
        if (r.matched == 0) return;
        Op memory m = r.ops[r.ops.length - 1];
        assertLe(m.amount, r.sell0.amountIn, "assetAmount <= sell amountIn at entry");
        assertLe(m.amount2, r.buy0.amountIn, "quoteAmount <= buy amountIn (unchanged by the sell reduction)");
    }
}
