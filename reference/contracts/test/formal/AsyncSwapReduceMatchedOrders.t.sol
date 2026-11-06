// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {FormalMatchD} from "./FormalMatchD.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapReduceMatchedOrders.lean`.
///         `_reduceMatchedOrders` is private; `_matchPair` runs it before `_settleTransfers`, reached through
///         `matchBook(key, 1)` (`FormalMatchD`). Its effects are the events before the four escrow-leg
///         events (priority-fee settlements) and the two orders' storage afterwards. Priority
///         fees are switched on (PriorityFee mode, paid bids) where the order of the two reductions has to
///         be visible.
contract AsyncSwapReduceMatchedOrdersFormalTest is FormalMatchD {
    /// @dev The reduction ops of one side (`_reduceAfterMatch`), as the trace shows them.
    function _sideOps(Case memory c, bytes32 id, uint256 used, bool sell, Run memory r)
        internal
        view
        returns (Op[] memory)
    {
        Trace memory t = _newTrace();
        _reduceOps(t, c, id, sell ? r.sell0 : r.buy0, used);
        return _done(t);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapReduceMatchedOrders.lean:68 — the reduction of the sell order (asset in, quote out) followed by that of the buy order (quote in, asset out), sides and input currencies read at entry; nothing else.
    function testFuzz_reduceMatchedOrders_eq(uint256[6] memory s, uint8 flags) public {
        Case memory c = _mkCase(s, flags | 4 | 16 | 32);
        Run memory r = _exec(c);
        if (r.matched == 0) return;
        Op[] memory sellOps = _sideOps(c, c.sellId, r.asset, true, r);
        Op[] memory buyOps = _sideOps(c, c.buyId, r.quote, false, r);
        _assertOps(r.ops, _expected(c, r));
        for (uint256 i; i < sellOps.length; ++i) {
            _assertOp(r.ops[i], sellOps[i], "sell reduction first");
        }
        for (uint256 i; i < buyOps.length; ++i) {
            _assertOp(r.ops[sellOps.length + i], buyOps[i], "then the buy reduction");
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
        AsyncFiller.OrderInfo memory sell0 = _info(c.pid, c.sellId);
        AsyncFiller.OrderInfo memory buy0 = _info(c.pid, c.buyId);
        uint256 fees = (_closes(sell0, asset) ? _paid(sell0) : _filled(sell0, asset))
            + (_closes(buy0, quote) ? _paid(buy0) : _filled(buy0, quote));
        if (fees == 0) return;
        address vault = address(hook.feeVault());
        uint256 vaultBefore = _claims(vault, currency1);
        uint256 buyerBefore = _claims(bob, c.k.currency0);
        uint256 sellerBefore = _claims(alice, c.k.currency1);
        bytes memory reason = abi.encodeWithSignature("MockedBatchSettlement(uint256)", tag);
        // The bid shares and the quote trade fee merge into one vault credit in currency1.
        _mockPayoutRevert(currency1, vault, fees + _tradeFee(quote), reason);
        vm.expectRevert(reason);
        _run(_matchCalls(c.k));
        assertEq(keccak256(abi.encode(_info(c.pid, c.sellId))), keccak256(abi.encode(sell0)), "sell restored");
        assertEq(keccak256(abi.encode(_info(c.pid, c.buyId))), keccak256(abi.encode(buy0)), "buy restored");
        assertEq(_claims(vault, currency1), vaultBefore, "vault unchanged");
        assertEq(_claims(bob, c.k.currency0), buyerBefore, "buyer unchanged");
        assertEq(_claims(alice, c.k.currency1), sellerBefore, "seller unchanged");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapReduceMatchedOrders.lean:148 — on success the sell order held at least assetAmount at entry and the buy order at least quoteAmount once the sell side was reduced.
    function testFuzz_reduceMatchedOrders_ok_bounds(uint256[6] memory s, uint8 flags) public {
        Case memory c = _mkCase(s, flags);
        Run memory r = _exec(c);
        if (r.matched == 0) return;
        Op memory m = _matchedOp(r.ops);
        assertLe(m.amount, r.sell0.amountIn, "assetAmount <= sell amountIn at entry");
        assertLe(m.amount2, r.buy0.amountIn, "quoteAmount <= buy amountIn (unchanged by the sell reduction)");
    }
}
