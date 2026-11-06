// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;
import {IERC6909Claims} from "v4-core/interfaces/external/IERC6909Claims.sol";

import {FormalMatchD} from "./FormalMatchD.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @notice Runtime checks for direct ERC-6909 claim settlement, event order, and failure rollback.
contract AsyncSwapSettleTransfersFormalTest is FormalMatchD {
    function _reason(uint256 tag) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("MockedPoolManagerCall(uint256)", tag);
    }

    /// @dev `inputOf key order`: currency0 when it sells token 0.
    function _inputOf(Case memory c, bool zeroForOne) internal pure returns (Currency) {
        return zeroForOne ? c.k.currency0 : c.k.currency1;
    }

    /// @notice Check the direct claim-transfer path and its observable result.
    function testFuzz_settleTransfers_run(uint256[6] memory s, uint8 flags) public {
        Case memory c = _mkCase(s, flags);
        Run memory r = _exec(c);
        if (r.matched == 0) return;
        Trace memory t = _newTrace();
        // Each side receives its proceeds less the 0.02% trade fee (the vault's credits are excluded by `_legsOf`).
        _credit(t, _inputOf(c, r.sell0.zeroForOne), r.buy0.owner, r.asset - _tradeFee(r.asset));
        _credit(t, _inputOf(c, r.buy0.zeroForOne), r.sell0.owner, r.quote - _tradeFee(r.quote));
        _assertOps(_legsOf(r.ops), _done(t));
        assertEq(r.buy0.owner, bob);
        assertEq(r.sell0.owner, alice);
    }

    /// @notice Check the direct claim-transfer path and its observable result.
    function testFuzz_settleTransfers_reverts_iff(uint256[6] memory s, uint8 flags, uint8 mode, uint256 tag) public {
        Case memory c = _mkCase(s, flags);
        (bool matches, uint256 asset, uint256 quote) = _pre(c);
        if (!matches) return;
        mode %= 5; // 0 none; 1/2 asset leg burn/payout; 3/4 quote leg burn/payout
        _mockLeg(c, asset, quote, mode, _reason(tag));
        // A leg whose net (after the trade fee) is zero is never transferred, so its mock cannot fire.
        if (mode == 0 || (mode <= 2 ? asset - _tradeFee(asset) : quote - _tradeFee(quote)) == 0) {
            bytes[] memory res = _runR(_matchCalls(c.k));
            assertEq(abi.decode(res[0], (uint8)), 1, "both legs succeed: no revert");
        } else {
            vm.expectRevert(_reason(tag));
            _run(_matchCalls(c.k));
        }
    }

    /// @notice Check the direct claim-transfer path and its observable result.
    function testFuzz_settleTransfers_ok(uint256[6] memory s, uint8 flags) public {
        Case memory c = _mkCase(s, flags);
        Run memory r = _exec(c);
        if (r.matched == 0) return;
        Op[] memory legs = _legsOf(r.ops);
        uint256 assetNet = r.asset - _tradeFee(r.asset);
        uint256 quoteNet = r.quote - _tradeFee(r.quote);
        // A zero net credit is skipped by the batch.
        assertEq(legs.length, (assetNet != 0 ? 1 : 0) + (quoteNet != 0 ? 1 : 0));
        uint256 i;
        if (assetNet != 0) {
            assertEq(legs[i].kind, OP_TRANSFER);
            assertEq(legs[i].cur, _inputOf(c, true).toId());
            assertEq(legs[i].amount, assetNet);
            assertEq(legs[i++].who, bob);
        }
        if (quoteNet != 0) {
            assertEq(legs[i].kind, OP_TRANSFER);
            assertEq(legs[i].cur, _inputOf(c, false).toId());
            assertEq(legs[i].amount, quoteNet);
            assertEq(legs[i].who, alice);
        }
        Trace memory t = _newTrace();
        _credit(t, c.k.currency0, bob, assetNet);
        _credit(t, c.k.currency1, alice, quoteNet);
        _assertOps(legs, _done(t));
        // The vault receives both trade fees.
        assertEq(_claims(address(hook.feeVault()), c.k.currency0), _tradeFee(r.asset), "vault asset fee");
    }

    /// @notice Check the direct claim-transfer path and its observable result.
    function testFuzz_settleTransfers_ok_same_manager(uint256[6] memory s, uint8 flags) public {
        Case memory c = _mkCase(s, flags);
        (bool matches, uint256 asset, uint256 quote) = _pre(c);
        if (!matches) return;
        (IPoolManager pm0,,,,) = hook.asyncOrders(c.pid);
        assertEq(address(pm0), address(manager));
        // Every claim transfer (net legs and the vault's trade fees) uses the configured PoolManager.
        address vault = address(hook.feeVault());
        uint256 assetNet = asset - _tradeFee(asset);
        uint256 quoteNet = quote - _tradeFee(quote);
        if (assetNet != 0) {
            vm.expectCall(
                address(manager), abi.encodeCall(IERC6909Claims.transfer, (bob, c.k.currency0.toId(), assetNet))
            );
        }
        if (quoteNet != 0) {
            vm.expectCall(
                address(manager), abi.encodeCall(IERC6909Claims.transfer, (alice, c.k.currency1.toId(), quoteNet))
            );
        }
        vm.expectCall(
            address(manager), abi.encodeCall(IERC6909Claims.transfer, (vault, c.k.currency0.toId(), _tradeFee(asset)))
        );
        Run memory r = _exec(c);
        assertEq(r.matched, 1);
        (IPoolManager pm1,,,,) = hook.asyncOrders(c.pid);
        assertEq(address(pm1), address(pm0), "poolManager unchanged");
    }
}
