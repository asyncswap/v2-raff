// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SetupHook} from "./SetupHook.t.sol";
import {AsyncSwap} from "src/AsyncSwap.sol";
import {AsyncOrder} from "src/types/AsyncOrder.sol";
import {TopUpCallbackToken, TopUpPaymentProbe} from "./utils/TopUpCallbackToken.sol";
import {PoolKey, PoolIdLibrary} from "v4-core/types/PoolKey.sol";

contract IncomingFundingProbe {
    using PoolIdLibrary for PoolKey;
    AsyncSwap immutable hook;
    PoolKey key;
    bytes32 immutable id;
    uint256 public calls;

    constructor(AsyncSwap h, PoolKey memory k, bytes32 pendingId) {
        hook = h;
        key = k;
        id = pendingId;
    }

    function onPayment() external {
        ++calls;
        // The funding callback must see neither a persistent arrival nor a matchable unpaid bid.
        require(hook.asyncOrder(key.toId(), id) == 0, "pending record persisted");
        require(hook.matchBook(key, 8) == 0, "matched before funding completed");
    }
}

contract IncomingMemoryFundingTest is SetupHook {
    function test_fundingCallbacksCannotMatchPendingOrder() public {
        _run(false);
    }

    function test_failedFundingRollsBackPendingAndAllowsRetry() public {
        _run(true);
    }

    function _run(bool failFirst) private {
        address seller = address(0x91001);
        address buyer = address(0x91002);
        topUp(seller, 1e25);
        topUp(buyer, 1e25);
        vm.prank(seller);
        token0.approve(address(router), type(uint256).max);
        AsyncOrder memory ask = AsyncOrder(key, seller, true, 1 ether, 1_000e6, 0, 2 ** 96, bytes32(0));
        vm.prank(seller);
        router.swap(ask, abi.encode(AsyncSwap.UserParams(seller, address(router), 1_000e6, 0)));
        bytes32 salt = keccak256(
            abi.encode(
                block.timestamp,
                block.number,
                address(manager),
                buyer,
                uint256(1_000e6),
                uint256(1 ether),
                uint256(100_000)
            )
        );
        bytes32 id = _orderIdFor(buyer, false, salt);
        IncomingFundingProbe probe = new IncomingFundingProbe(hook, key, id);
        TopUpCallbackToken replacement = new TopUpCallbackToken(TopUpPaymentProbe(address(probe)));
        bytes memory original = address(token1).code;
        if (failFirst) deal(address(token1), buyer, 1_000e6);
        vm.etch(address(token1), address(replacement).code);
        AsyncOrder memory bid = AsyncOrder(key, buyer, false, 1_000e6, 1 ether, 100_000, 2 ** 96, bytes32(0));
        bytes memory params = abi.encode(AsyncSwap.UserParams(buyer, address(router), 1 ether, 100_000));
        if (failFirst) {
            vm.prank(buyer);
            vm.expectRevert();
            router.swap(bid, params);
            assertEq(probe.calls(), 0, "failed input/bid settlement rolls back callbacks");
            assertEq(hook.asyncOrder(poolId, id), 0);
            vm.etch(address(token1), original);
            token1.mint(buyer, 100_000);
            vm.etch(address(token1), address(replacement).code);
        }
        vm.prank(buyer);
        router.swap(bid, params);
        assertEq(probe.calls(), 2, "both input and priority fee must be funded");
        assertEq(hook.asyncOrder(poolId, id), 0, "fully matched arrival never rests");
        assertEq(manager.balanceOf(buyer, currency0.toId()), 1 ether - 1 ether / 5000);
        assertEq(manager.balanceOf(seller, currency1.toId()), 1_000e6 - 1_000e6 / 5000);
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0);
    }
}
