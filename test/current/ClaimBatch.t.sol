// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {CurrentHuffHarness} from "./CurrentHuffHarness.sol";
import {IERC6909Claims} from "v4-core/interfaces/external/IERC6909Claims.sol";

contract ClaimBatchTest is CurrentHuffHarness {
    function test_laterTransferFailureRestoresOrdersAndEarlierCredits() public {
        bytes32 sell = _rest(key, alice, true, 1e18, 1e9, 100000);
        bytes32 buy = _rest(key, bob, false, 1e9, 1e18, 100000);
        bytes32 sellBefore = keccak256(abi.encode(_info(poolId, sell)));
        bytes32 buyBefore = keccak256(abi.encode(_info(poolId, buy)));
        address vault = address(hook.feeVault());
        uint256 vaultBefore = manager.balanceOf(vault, currency1.toId());
        uint256 buyerBefore = manager.balanceOf(bob, currency0.toId());
        uint256 sellerBefore = manager.balanceOf(alice, currency1.toId());
        bytes memory reason = abi.encodeWithSignature("ClaimTransferRejected()");
        vm.mockCallRevert(
            address(manager), abi.encodeCall(IERC6909Claims.transfer, (alice, currency1.toId(), 1e9)), reason
        );
        vm.expectRevert(reason);
        _run(_one(_c(address(hook), abi.encodeCall(hook.matchBook, (key, 1)))));
        assertEq(keccak256(abi.encode(_info(poolId, sell))), sellBefore);
        assertEq(keccak256(abi.encode(_info(poolId, buy))), buyBefore);
        assertEq(manager.balanceOf(vault, currency1.toId()), vaultBefore);
        assertEq(manager.balanceOf(bob, currency0.toId()), buyerBefore);
        assertEq(manager.balanceOf(alice, currency1.toId()), sellerBefore);
    }
}
