// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalMatchD} from "./FormalMatchD.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapTransferEscrow.lean`. `_transferEscrow` is
///         private; `_settleTransfers` calls it twice per matched pair (asset leg: currency0 to the buyer;
///         quote leg: currency1 to the seller), reached through `matchBook(key, 1)` (`FormalMatchD`). Each
///         leg is the first four PoolManager events of the match: `burn` from the hook, then the payout
///         (`mint` of claims for native ETH, an ERC-20 `take` otherwise). Reverts are injected with
///         `vm.mockCallRevert` on the exact PoolManager calldata of one leg.
contract AsyncSwapTransferEscrowFormalTest is FormalMatchD {
    /// @dev The two legs, as `_settleTransfers` runs them: (currency0 → buyer, asset), (currency1 → seller, quote).
    function _legs(Case memory c, Run memory r) internal view returns (Op[] memory) {
        Trace memory t = _newTrace();
        _escrowLeg(t, c.k.currency0, r.buy0.owner, r.asset);
        _escrowLeg(t, c.k.currency1, r.sell0.owner, r.quote);
        return _done(t);
    }

    function _reason(uint256 tag) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("MockedPoolManagerCall(uint256)", tag);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapTransferEscrow.lean:49 — a run is exactly `burn(hook, currency, amount)` then the payout (`mint(recipient, 0, amount)` if native, else `take(currency, recipient, amount)`).
    function testFuzz_transferEscrow_run(uint256[6] memory s, uint8 flags) public {
        Case memory c = _mkCase(s, flags);
        Run memory r = _exec(c);
        if (r.matched == 0) return;
        _assertOps(_prefix(r.ops, 4), _legs(c, r));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapTransferEscrow.lean:67 — if burning the hook's claims reverts, `_transferEscrow` reverts with the same reason and pays nothing.
    function testFuzz_transferEscrow_burn_reverts(uint256[6] memory s, uint8 flags, bool quoteLeg, uint256 tag) public {
        Case memory c = _mkCase(s, flags);
        (bool matches, uint256 asset, uint256 quote) = _pre(c);
        if (!matches) return;
        _mockLeg(c, asset, quote, quoteLeg ? 3 : 1, _reason(tag));
        uint256 bobBefore = c.native ? _claims(bob, c.k.currency0) : token0.balanceOf(bob);
        vm.expectRevert(_reason(tag));
        _run(_matchCalls(c.k));
        assertEq(c.native ? _claims(bob, c.k.currency0) : token0.balanceOf(bob), bobBefore, "nothing paid out");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapTransferEscrow.lean:75 — native currency: after the burn, exactly `mint(recipient, 0, amount)` follows and its result is the function's result.
    function testFuzz_transferEscrow_native(uint256[6] memory s, uint8 flags, bool failMint, uint256 tag) public {
        Case memory c = _mkCase(s, flags | 2);
        (bool matches, uint256 asset, uint256 quote) = _pre(c);
        if (!matches) return;
        if (failMint) {
            _mockLeg(c, asset, quote, 2, _reason(tag)); // mint(buyer, 0, asset)
            vm.expectRevert(_reason(tag));
            _run(_matchCalls(c.k));
        } else {
            Run memory r = _exec(c);
            assertEq(r.matched, 1);
            _assertOp(r.ops[0], Op(OP_BURN, address(hook), 0, asset, 0, 0, 0), "burn of native claims");
            _assertOp(r.ops[1], Op(OP_MINT, bob, 0, asset, 0, 0, 0), "then mint(recipient, 0, amount)");
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapTransferEscrow.lean:83 — ERC-20 currency: after the burn, exactly `take(currency, recipient, amount)` follows and its result is the function's result.
    function testFuzz_transferEscrow_erc20(uint256[6] memory s, uint8 flags, bool quoteLeg, bool failTake, uint256 tag)
        public
    {
        Case memory c = _mkCase(s, flags & ~uint8(2));
        (bool matches, uint256 asset, uint256 quote) = _pre(c);
        if (!matches) return;
        if (failTake) {
            _mockLeg(c, asset, quote, quoteLeg ? 4 : 2, _reason(tag));
            vm.expectRevert(_reason(tag));
            _run(_matchCalls(c.k));
        } else {
            Run memory r = _exec(c);
            uint256 i = quoteLeg ? 2 : 0;
            (address token, address to, uint256 amount) =
                quoteLeg ? (address(token1), alice, quote) : (address(token0), bob, asset);
            _assertOp(r.ops[i], Op(OP_BURN, address(hook), uint256(uint160(token)), amount, 0, 0, 0), "burn");
            _assertOp(r.ops[i + 1], Op(OP_TAKE, to, uint256(uint160(token)), amount, 0, 0, 0), "then take");
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapTransferEscrow.lean:94 — success: the burn of `amount` of `currency` from the hook, then the payout of the same amount of the same currency to the recipient; nothing else.
    function testFuzz_transferEscrow_ok(uint256[6] memory s, uint8 flags) public {
        Case memory c = _mkCase(s, flags);
        Run memory r = _exec(c);
        if (r.matched == 0) return;
        for (uint256 leg; leg < 2; ++leg) {
            Op memory b = r.ops[2 * leg];
            Op memory p = r.ops[2 * leg + 1];
            assertEq(b.kind, OP_BURN, "burn first");
            assertEq(b.who, address(hook), "from the hook");
            assertEq(p.amount, b.amount, "same amount paid out");
            assertEq(p.cur, b.cur, "same currency paid out");
            assertEq(p.kind, b.cur == 0 ? OP_MINT : OP_TAKE, "mint claims iff native");
        }
        _assertOps(_prefix(r.ops, 4), _legs(c, r));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapTransferEscrow.lean:108 — `_transferEscrow` reverts exactly when the burn reverts, or the burn succeeds and the payout reverts.
    function testFuzz_transferEscrow_reverts_iff(uint256[6] memory s, uint8 flags, uint8 mode, uint256 tag) public {
        Case memory c = _mkCase(s, flags);
        (bool matches, uint256 asset, uint256 quote) = _pre(c);
        if (!matches) return;
        mode %= 5; // 0: neither call reverts; 1/3: the burn of a leg; 2/4: its payout
        _mockLeg(c, asset, quote, mode, _reason(tag));
        if (mode == 0) {
            bytes[] memory res = _runR(_matchCalls(c.k));
            assertEq(abi.decode(res[0], (uint8)), 1, "no revert");
        } else {
            vm.expectRevert(_reason(tag));
            _run(_matchCalls(c.k));
        }
    }
}
