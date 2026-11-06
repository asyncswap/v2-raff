// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalBase} from "./FormalBase.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {Router} from "@async-swap/Router.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice Helpers for the Router / AsyncSwap theorem checks (`formal/Refinement/{AsyncSwap,Router}.lean`
///         and `formal/Refinement/Swarm/Router*.lean`).
///
///         The Lean theorems treat `PoolManager.unlock` and the hook's calls as opaque `Ext` functions
///         and quantify over their behaviour; the tests stand them in with `vm.mockCall` /
///         `vm.mockCallRevert` so the Router's own bytecode is checked against every outcome.
///
///         The Router's transient slots (`USER_LOCATION`, `ASYNC_FILLER_LOCATION`, `MAX_PRICE_LOCATION`)
///         cannot be read with `vm.load`, but they persist for the whole test transaction, so
///         `_assertTransient` / `_assertMaxPrice` read them back through `unlockCallback` (pranked
///         as the PoolManager): the Swap branch forwards `tload(USER)` / `tload(FILLER)` as the
///         `UserParams` hook data of `PoolManager.swap`, and the FillOrder branch compares the live
///         price with `tload(MAX_PRICE)`.
abstract contract FormalProbesA is FormalBase {
    using PoolIdLibrary for PoolKey;

    bytes32 constant EIP712_TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function _mockUnlockOk() internal {
        vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.unlock.selector), abi.encode(bytes("")));
    }

    function _cb(uint8 action, AsyncOrder memory order, uint8 maxMatches) internal pure returns (bytes memory) {
        return
            abi.encode(Router.SwapCallback({action: Router.ActionType(action), order: order, maxMatches: maxMatches}));
    }

    function _probeOrder() internal view returns (AsyncOrder memory p) {
        p.key = key;
        p.zeroForOne = true;
    }

    /// @dev Assert `tload(USER_LOCATION) == user` and `tload(ASYNC_FILLER_LOCATION) == filler` in the
    ///      Router. Clears all mocks.
    function _assertTransient(address user, address filler) internal {
        vm.clearMockedCalls();
        vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.swap.selector), abi.encode(int256(0)));
        vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.sync.selector), "");
        vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.settle.selector), abi.encode(uint256(0)));
        vm.mockCall(address(hook), abi.encodeWithSelector(AsyncSwap.matchNewOrder.selector), abi.encode(uint8(0)));
        vm.expectCall(
            address(manager),
            abi.encodeCall(
                IPoolManager.swap,
                (
                    key,
                    SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: 0}),
                    abi.encode(AsyncSwap.UserParams({user: user, executor: filler, amountOutMin: 0, priorityFee: 0}))
                )
            )
        );
        vm.prank(address(manager));
        router.unlockCallback(_cb(0, _probeOrder(), 0));
        vm.clearMockedCalls();
    }

    /// @dev Assert `tload(MAX_PRICE_LOCATION) == maxPrice` in the Router: a live price of `maxPrice`
    ///      passes the FillOrder price check and `maxPrice + 1` fails it. Clears all mocks.
    function _assertMaxPrice(uint256 maxPrice) internal {
        vm.clearMockedCalls();
        vm.mockCall(address(hook), abi.encodeWithSelector(AsyncSwap.calculatePoolFee.selector), abi.encode(uint256(0)));
        vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.sync.selector), "");
        vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.settleFor.selector), abi.encode(uint256(0)));
        vm.mockCall(address(hook), abi.encodeWithSelector(AsyncSwap.executeOrder.selector), "");
        vm.mockCall(address(token1), abi.encodeWithSelector(token1.transferFrom.selector), abi.encode(true));
        if (maxPrice < type(uint256).max) {
            vm.mockCall(
                address(hook),
                abi.encodeWithSelector(AsyncSwap.asyncOrderInfo.selector),
                abi.encode(uint256(0), maxPrice + 1)
            );
            vm.prank(address(manager));
            vm.expectRevert(bytes("Price exceeds maxPrice"));
            router.unlockCallback(_cb(1, _probeOrder(), 0));
        }
        vm.mockCall(
            address(hook), abi.encodeWithSelector(AsyncSwap.asyncOrderInfo.selector), abi.encode(uint256(0), maxPrice)
        );
        vm.prank(address(manager));
        router.unlockCallback(_cb(1, _probeOrder(), 0));
        vm.clearMockedCalls();
    }

    /// @dev Put the Router's transient `USER_LOCATION` to `user` and `ASYNC_FILLER_LOCATION` to the
    ///      Router (via `fillFromPoolLiquidity` with a mocked `unlock`). Clears all mocks.
    function _seedTransient(address user) internal {
        _mockUnlockOk();
        AsyncOrder memory p = _probeOrder();
        vm.prank(user);
        router.fillFromPoolLiquidity(p);
        vm.clearMockedCalls();
    }

    /// @dev Signed cancels burn the hook's `nonceUsed[maker][nonce]`.
    function _cancelNonceSlot(address maker, uint256 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encode(nonce, keccak256(abi.encode(maker, NONCE_USED_SLOT))));
    }

    /// @dev `cancelWithSig` burns its nonce through `AsyncSwap.useNonce`, which requires the Router to
    ///      be the maker's executor on the order's pool.
    function _authRouter(AsyncOrder memory o) internal {
        vm.store(address(hook), _execSlot(o.key.toId(), o.owner, address(router)), bytes32(uint256(1)));
    }

    /// @dev `asyncOrders[poolId].isExecutor[maker][executor]` (State: poolManager, numeraire, feeVault,
    ///      orders, isExecutor -> offset 4).
    function _execSlot(PoolId pid, address maker, address executor) internal pure returns (bytes32) {
        bytes32 base = keccak256(abi.encode(PoolId.unwrap(pid), ASYNC_ORDERS_SLOT));
        bytes32 m = bytes32(uint256(base) + 4);
        return keccak256(abi.encode(executor, keccak256(abi.encode(maker, m))));
    }

    /// @dev `Router._orderId(order)`.
    function _routerOrderId(AsyncOrder memory o) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, o.key.toId(), o.owner, o.zeroForOne, o.salt));
    }

    function _assertNoWrites(address target) internal {
        (, bytes32[] memory writes) = vm.accesses(target);
        assertEq(writes.length, 0, "no persistent storage writes");
    }

    function _routerDomainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(EIP712_TYPE_HASH, keccak256("AsyncSwap Router"), keccak256("1"), block.chainid, address(router))
        );
    }

    function _digest(bytes32 domainSeparator, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _pk(uint256 seed) internal pure returns (uint256) {
        return bound(seed, 1, 115792089237316195423570985008687907852837564279074904382605163141518161494336);
    }
}
