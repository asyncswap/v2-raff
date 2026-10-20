// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;
import {SetupHook} from "../SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";

/// @notice `order.owner`, `UserParams.user`, and the submitting account must agree; a mismatch
///         reverts before any input is transferred.
contract MakerIdentityTest is SetupHook {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        topUp(alice, 10 ether);
    }

    function _reject(address orderOwner, address dataUser, string memory reason) internal {
        AsyncOrder memory order = AsyncOrder(key, orderOwner, true, 1 ether, 0.9 ether, 0, 2 ** 96, bytes32(0));
        uint256 beforeBalance = token0.balanceOf(alice);
        vm.startPrank(alice);
        token0.approve(address(router), 1 ether);
        vm.expectRevert(bytes(reason));
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: dataUser, executor: address(router), amountOutMin: 0.9 ether, priorityFee: 0
                })
            )
        );
        vm.stopPrank();
        assertEq(token0.balanceOf(alice), beforeBalance, "maker input unchanged");
        bytes32 id = _orderIdFor(alice, true, _expectedSalt(alice, 1 ether, 0.9 ether));
        (uint256 stored,) = hook.asyncOrderInfo(poolId, id);
        assertEq(stored, 0, "no unexpected order created");
    }

    function test_mismatchedOwnerRevertsBeforeTransfer() public {
        _reject(bob, alice, "Only owner can swap");
    }

    function test_mismatchedUserDataRevertsBeforeTransfer() public {
        _reject(alice, bob, "user mismatch");
    }
}
