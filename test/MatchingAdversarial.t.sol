// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {NativeAsyncSwapTest} from "./NativeAsyncSwap.t.sol";
import {AsyncSwap} from "src/AsyncSwap.sol";
import {AsyncOrder} from "src/types/AsyncOrder.sol";
import {Router} from "src/Router.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

contract RejectingNativeBuyer {
    using PoolIdLibrary for PoolKey;

    function place(Router router, AsyncSwap hook, MockERC20 token, PoolKey calldata key) external {
        hook.setExecutor(key.toId(), address(router), true);
        token.approve(address(router), 1 ether);
        AsyncOrder memory order = AsyncOrder(key, address(this), false, 1 ether, 1 ether, 0, 2 ** 96, bytes32(0));
        router.swap(order, abi.encode(AsyncSwap.UserParams(address(this), address(router), 1 ether, 0)));
    }

    receive() external payable {
        revert("reject native settlement");
    }
}

/// @notice Native recipients cannot block matching by rejecting ETH.
contract MatchingAdversarialTest is NativeAsyncSwapTest {
    function test_rejectingBestBuyerReceivesClaimsWithoutBlocking() public {
        RejectingNativeBuyer rejector = new RejectingNativeBuyer();
        erc20.mint(address(rejector), 1 ether);
        rejector.place(router, hook, erc20, key);

        vm.deal(alice, 2 ether);
        vm.prank(alice);
        hook.setExecutor(poolId, address(router), true);
        AsyncOrder memory sell = _order(alice, true, 1 ether, 1 ether);
        bytes memory data = abi.encode(AsyncSwap.UserParams(alice, address(router), 1 ether, 0));
        vm.prank(alice);
        router.swap{value: 1 ether}(sell, data);
        assertEq(alice.balance, 1 ether);
        assertEq(manager.balanceOf(address(rejector), 0), 1 ether);
        assertEq(address(rejector).balance, 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        (bool found,,,) = hook.bestOrder(poolId, true);
        assertFalse(found, "bid fully matched");
    }
}
