// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalMatchD} from "./FormalMatchD.sol";

/// @notice Runtime checks for direct ERC-6909 claim settlement, event order, and failure rollback.
contract AsyncSwapTransferEscrowFormalTest is FormalMatchD {
    function _reason(uint256 tag) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("MockedPoolManagerCall(uint256)", tag);
    }

    /// @notice Check the direct claim-transfer path and its observable result.
    function testFuzz_transferEscrow_run(uint256[6] memory s, uint8 flags) public {
        Case memory c = _mkCase(s, flags);
        Run memory r = _exec(c);
        if (r.matched == 0) return;
        _assertOps(_legsOf(r.ops), _legOps(c, r));
    }

    /// @notice Check the direct claim-transfer path and its observable result.
    function testFuzz_transferEscrow_claim_transfer_reverts(
        uint256[6] memory s,
        uint8 flags,
        bool quoteLeg,
        uint256 tag
    ) public {
        Case memory c = _mkCase(s, flags);
        (bool matches, uint256 asset, uint256 quote) = _pre(c);
        if (!matches) return;
        if ((quoteLeg ? quote - _tradeFee(quote) : asset - _tradeFee(asset)) == 0) return; // zero net: no transfer
        _mockLeg(c, asset, quote, quoteLeg ? 3 : 1, _reason(tag));
        uint256 bobBefore = _claims(bob, c.k.currency0);
        vm.expectRevert(_reason(tag));
        _run(_matchCalls(c.k));
        assertEq(_claims(bob, c.k.currency0), bobBefore, "earlier claim credit rolled back");
    }

    /// @notice Check the direct claim-transfer path and its observable result.
    function testFuzz_transferEscrow_native(uint256[6] memory s, uint8 flags, bool failTransfer, uint256 tag) public {
        Case memory c = _mkCase(s, flags | 2);
        (bool matches, uint256 asset, uint256 quote) = _pre(c);
        if (!matches) return;
        uint256 assetNet = asset - _tradeFee(asset);
        if (assetNet == 0) return; // the buyer's whole asset went to the trade fee: no buyer transfer
        if (failTransfer) {
            _mockLeg(c, asset, quote, 2, _reason(tag)); // transfer native claims to the buyer
            vm.expectRevert(_reason(tag));
            _run(_matchCalls(c.k));
        } else {
            Run memory r = _exec(c);
            assertEq(r.matched, 1);
            Op[] memory legs = _legsOf(r.ops);
            _assertOp(legs[0], Op(OP_TRANSFER, bob, 0, assetNet, 0, 0, 0), "native claim transfer");
            assertEq(_claims(address(hook.feeVault()), c.k.currency0), _tradeFee(asset), "vault native fee");
        }
    }

    /// @notice Check the direct claim-transfer path and its observable result.
    function testFuzz_transferEscrow_erc20(
        uint256[6] memory s,
        uint8 flags,
        bool quoteLeg,
        bool failTransfer,
        uint256 tag
    ) public {
        Case memory c = _mkCase(s, flags & ~uint8(2));
        (bool matches, uint256 asset, uint256 quote) = _pre(c);
        if (!matches) return;
        uint256 assetNet = asset - _tradeFee(asset);
        uint256 quoteNet = quote - _tradeFee(quote);
        if ((quoteLeg ? quoteNet : assetNet) == 0) return; // zero net: the leg is skipped
        if (failTransfer) {
            _mockLeg(c, asset, quote, quoteLeg ? 4 : 2, _reason(tag));
            vm.expectRevert(_reason(tag));
            _run(_matchCalls(c.k));
        } else {
            Op[] memory legs = _legsOf(_exec(c).ops);
            uint256 i = quoteLeg && assetNet != 0 ? 1 : 0;
            (address token, address to, uint256 amount) =
                quoteLeg ? (address(token1), alice, quoteNet) : (address(token0), bob, assetNet);
            _assertOp(legs[i], Op(OP_TRANSFER, to, uint256(uint160(token)), amount, 0, 0, 0), "claim transfer");
        }
    }

    /// @notice Check the direct claim-transfer path and its observable result.
    function testFuzz_transferEscrow_ok(uint256[6] memory s, uint8 flags) public {
        Case memory c = _mkCase(s, flags);
        Run memory r = _exec(c);
        if (r.matched == 0) return;
        Op[] memory legs = _legsOf(r.ops);
        // Two legs, less any whose net after the trade fee is zero.
        assertEq(legs.length, (r.asset - _tradeFee(r.asset) != 0 ? 1 : 0) + (r.quote - _tradeFee(r.quote) != 0 ? 1 : 0));
        for (uint256 leg; leg < legs.length; ++leg) {
            assertEq(legs[leg].kind, OP_TRANSFER);
        }
        _assertOps(legs, _legOps(c, r));
    }

    /// @notice Check the direct claim-transfer path and its observable result.
    function testFuzz_transferEscrow_reverts_iff(uint256[6] memory s, uint8 flags, uint8 mode, uint256 tag) public {
        Case memory c = _mkCase(s, flags);
        (bool matches, uint256 asset, uint256 quote) = _pre(c);
        if (!matches) return;
        mode %= 5; // 0: neither call reverts; 1/3: the burn of a leg; 2/4: its payout
        _mockLeg(c, asset, quote, mode, _reason(tag));
        // A leg whose net after the trade fee is zero is never transferred, so its mock cannot fire.
        if (mode == 0 || (mode <= 2 ? asset - _tradeFee(asset) : quote - _tradeFee(quote)) == 0) {
            bytes[] memory res = _runR(_matchCalls(c.k));
            assertEq(abi.decode(res[0], (uint8)), 1, "no revert");
        } else {
            vm.expectRevert(_reason(tag));
            _run(_matchCalls(c.k));
        }
    }
}
