// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {NativeAsyncSwapTest} from "./NativeAsyncSwap.t.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {NativeClaims} from "src/NativeClaims.sol";
import {AsyncSwap} from "src/AsyncSwap.sol";
import {AsyncOrder} from "src/types/AsyncOrder.sol";

contract RejectETH {
    receive() external payable {
        revert("reject");
    }
}

contract ReenterRedemption {
    NativeClaims immutable claims;
    bool public blocked;
    bytes4 public reentryError;

    constructor(NativeClaims c) {
        claims = c;
    }

    receive() external payable {
        try claims.redeem(address(this), 1) {}
        catch (bytes memory reason) {
            blocked = true;
            if (reason.length >= 4) {
                bytes4 selector;
                assembly {
                    selector := mload(add(reason, 32))
                }
                reentryError = selector;
            }
        }
    }
}

contract NativeClaimsTest is NativeAsyncSwapTest {
    receive() external payable {}

    function test_nativeLpFillCreditsClaims() public {
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        vm.deal(address(this), 10_000 ether);
        erc20.mint(address(this), 10_000 ether);
        erc20.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity{value: 10_000 ether}(key, ModifyLiquidityParams(-60, 60, 1e24, bytes32(0)), "");
        AsyncOrder memory order = _order(alice, false, 1 ether, 0.95 ether);
        uint256 beforeEth = alice.balance;
        vm.startPrank(alice);
        erc20.approve(address(router), 1 ether + 100_000);
        router.swap(order, abi.encode(AsyncSwap.UserParams(alice, address(router), 0.95 ether, 100_000)));
        vm.stopPrank();
        assertEq(alice.balance, beforeEth);
        assertGe(manager.balanceOf(alice, 0), 0.95 ether);
        assertEq(hook.asyncOrder(poolId, _orderIdFor(alice, false, _expectedSalt(alice, 1 ether, 0.95 ether))), 0);
    }

    function _credit() private returns (NativeClaims claims) {
        claims = new NativeClaims(manager);
        AsyncOrder memory order = _order(alice, true, 1 ether, 1 ether);
        vm.startPrank(alice);
        router.swap{value: 1 ether}(order, abi.encode(AsyncSwap.UserParams(alice, address(router), 1 ether, 100_000)));
        router.cancelOrder(_withAssignedSalt(order));
        vm.stopPrank();
        assertEq(manager.balanceOf(alice, 0), 1 ether);
    }

    function test_redeemPartialToChosenRecipientThenNoDoubleSpend() public {
        NativeClaims claims = _credit();
        uint256 beforeBalance = bob.balance;
        vm.startPrank(alice);
        manager.approve(address(claims), 0, 1 ether);
        claims.redeem(bob, 0.4 ether);
        assertEq(manager.balanceOf(alice, 0), 0.6 ether);
        assertEq(bob.balance, beforeBalance + 0.4 ether);
        claims.redeem(bob, 0.6 ether);
        vm.expectRevert();
        claims.redeem(bob, 1);
        vm.stopPrank();
        assertEq(manager.balanceOf(alice, 0), 0);
        assertEq(bob.balance, beforeBalance + 1 ether);
    }

    function test_cannotRedeemAnotherOwnerOrCallCallback() public {
        NativeClaims claims = _credit();
        vm.prank(alice);
        manager.approve(address(claims), 0, 1 ether);
        vm.prank(bob);
        vm.expectRevert();
        claims.redeem(bob, 1 ether);
        vm.expectRevert(NativeClaims.OnlyPoolManager.selector);
        claims.unlockCallback(abi.encode(alice, bob, 1 ether));
        assertEq(manager.balanceOf(alice, 0), 1 ether);
    }

    function test_failedRedemptionPreservesClaimsAndAllowance() public {
        NativeClaims claims = _credit();
        RejectETH rejector = new RejectETH();
        vm.startPrank(alice);
        vm.expectRevert(); // No approval yet.
        claims.redeem(bob, 1 ether);
        manager.approve(address(claims), 0, 1 ether);
        vm.expectRevert();
        claims.redeem(address(rejector), 1 ether);
        assertEq(manager.balanceOf(alice, 0), 1 ether);
        assertEq(manager.allowance(alice, address(claims), 0), 1 ether);
        claims.redeem(bob, 1 ether);
        vm.stopPrank();
    }

    function test_reentrantRedemptionCannotUnlockAgain() public {
        NativeClaims claims = _credit();
        ReenterRedemption recipient = new ReenterRedemption(claims);
        vm.startPrank(alice);
        manager.approve(address(claims), 0, 1 ether);
        claims.redeem(address(recipient), 1 ether);
        vm.stopPrank();
        assertTrue(recipient.blocked());
        assertEq(recipient.reentryError(), NativeClaims.ReentrantRedemption.selector);
        assertEq(address(recipient).balance, 1 ether);
        assertEq(manager.balanceOf(alice, 0), 0);
    }
}
