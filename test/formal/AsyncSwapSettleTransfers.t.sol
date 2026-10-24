// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalMatchD} from "./FormalMatchD.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapSettleTransfers.lean`. `_settleTransfers` is
///         private; `_matchPair` runs it once per matched pair, reached through `matchBook(key, 1)`
///         (`FormalMatchD`). Its effects are the first four PoolManager events of the match. The sides
///         are read from the stored orders: the sell is alice's `zeroForOne` order (input currency0), the
///         buy is bob's (input currency1, the numeraire).
contract AsyncSwapSettleTransfersFormalTest is FormalMatchD {
    function _reason(uint256 tag) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("MockedPoolManagerCall(uint256)", tag);
    }

    /// @dev `inputOf key order`: currency0 when it sells token 0.
    function _inputOf(Case memory c, bool zeroForOne) internal pure returns (Currency) {
        return zeroForOne ? c.k.currency0 : c.k.currency1;
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSettleTransfers.lean:57 — the asset leg (sell input → buy owner, assetAmount), then the quote leg (buy input → sell owner, quoteAmount), with parties and currencies read at entry.
    function testFuzz_settleTransfers_run(uint256[6] memory s, uint8 flags) public {
        Case memory c = _mkCase(s, flags);
        Run memory r = _exec(c);
        if (r.matched == 0) return;
        Trace memory t = _newTrace();
        _escrowLeg(t, _inputOf(c, r.sell0.zeroForOne), r.buy0.owner, r.asset);
        _escrowLeg(t, _inputOf(c, r.buy0.zeroForOne), r.sell0.owner, r.quote);
        _assertOps(_prefix(r.ops, 4), _done(t));
        assertEq(r.buy0.owner, bob);
        assertEq(r.sell0.owner, alice);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSettleTransfers.lean:79 — it reverts exactly when the asset leg reverts, or that leg succeeds and the quote leg reverts, each with its own reason.
    function testFuzz_settleTransfers_reverts_iff(uint256[6] memory s, uint8 flags, uint8 mode, uint256 tag) public {
        Case memory c = _mkCase(s, flags);
        (bool matches, uint256 asset, uint256 quote) = _pre(c);
        if (!matches) return;
        mode %= 5; // 0 none; 1/2 asset leg burn/payout; 3/4 quote leg burn/payout
        _mockLeg(c, asset, quote, mode, _reason(tag));
        if (mode == 0) {
            bytes[] memory res = _runR(_matchCalls(c.k));
            assertEq(abi.decode(res[0], (uint8)), 1, "both legs succeed: no revert");
        } else {
            vm.expectRevert(_reason(tag));
            _run(_matchCalls(c.k));
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSettleTransfers.lean:104 — success is exactly four PoolManager calls in order: burn(hook, sellInput, asset), payout of asset to the buyer, burn(hook, buyInput, quote), payout of quote to the seller; each burn equals the payout in the same currency.
    function testFuzz_settleTransfers_ok(uint256[6] memory s, uint8 flags) public {
        Case memory c = _mkCase(s, flags);
        Run memory r = _exec(c);
        if (r.matched == 0) return;
        assertGe(r.ops.length, 5);
        assertEq(r.ops[0].kind, OP_BURN);
        assertEq(r.ops[2].kind, OP_BURN);
        assertEq(r.ops[0].cur, _inputOf(c, true).toId(), "asset leg burns the sell input");
        assertEq(r.ops[2].cur, _inputOf(c, false).toId(), "quote leg burns the buy input");
        assertEq(r.ops[0].amount, r.asset);
        assertEq(r.ops[2].amount, r.quote);
        assertEq(r.ops[1].amount, r.ops[0].amount, "asset burned = asset paid");
        assertEq(r.ops[3].amount, r.ops[2].amount, "quote burned = quote paid");
        assertEq(r.ops[1].who, bob, "asset to the buyer");
        assertEq(r.ops[3].who, alice, "quote to the seller");
        // the 5th op onwards belongs to `_reduceMatchedOrders` / the match event, not to the legs
        Trace memory t = _newTrace();
        _escrowLeg(t, c.k.currency0, bob, r.asset);
        _escrowLeg(t, c.k.currency1, alice, r.quote);
        _assertOps(_prefix(r.ops, 4), _done(t));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSettleTransfers.lean:132 — `self.poolManager` is unchanged by the first leg, so both legs go to the same PoolManager.
    function testFuzz_settleTransfers_ok_same_manager(uint256[6] memory s, uint8 flags) public {
        Case memory c = _mkCase(s, flags);
        (bool matches, uint256 asset, uint256 quote) = _pre(c);
        if (!matches) return;
        (IPoolManager pm0,,) = hook.asyncOrders(c.pid);
        assertEq(address(pm0), address(manager));
        // both legs' burns are calls to that one PoolManager
        vm.expectCall(address(manager), abi.encodeCall(IPoolManager.burn, (address(hook), c.k.currency0.toId(), asset)));
        vm.expectCall(address(manager), abi.encodeCall(IPoolManager.burn, (address(hook), c.k.currency1.toId(), quote)));
        Run memory r = _exec(c);
        assertEq(r.matched, 1);
        (IPoolManager pm1,,) = hook.asyncOrders(c.pid);
        assertEq(address(pm1), address(pm0), "poolManager unchanged");
    }
}
