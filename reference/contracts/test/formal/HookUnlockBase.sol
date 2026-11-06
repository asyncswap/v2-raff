// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalBase} from "./FormalBase.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {SwapParams} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {MockERC20} from "../utils/MockERC20.sol";

/// @notice Drives hook entry points that must run inside `PoolManager.unlock`. The test contract is
///         the unlock callback: `_run(calls)` unlocks and executes `calls` in order (each optionally
///         pranked as `caller`), bubbling the first revert unchanged so `vm.expectRevert` on the
///         `_run` sees the hook's own revert data. The test contract can also act as a maker whose
///         executor is itself (`_createCalls`), which sets the hook's transient pending-match hand-off
///         to (`id`, `address(this)`) inside the same unlock — the only way to reach
///         `matchNewOrder` with a pending match without the Router.
abstract contract HookUnlockBase is FormalBase, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    struct Call {
        address caller;
        address target;
        uint256 value;
        bytes data;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not PM");
        Call[] memory calls = abi.decode(data, (Call[]));
        bytes[] memory results = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            results[i] = _exec(calls[i]);
        }
        return abi.encode(results);
    }

    function _exec(Call memory c) internal returns (bytes memory r) {
        bool ok;
        if (c.caller != address(this)) vm.prank(c.caller);
        (ok, r) = c.target.call{value: c.value}(c.data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(r, 32), mload(r))
            }
        }
    }

    /// @dev No return decoding, so a preceding `vm.expectRevert` (which turns the revert data into
    ///      the call's return value) is not tripped by a decode failure.
    function _run(Call[] memory calls) internal {
        manager.unlock(abi.encode(calls));
    }

    function _runR(Call[] memory calls) internal returns (bytes[] memory) {
        return abi.decode(manager.unlock(abi.encode(calls)), (bytes[]));
    }

    /* ------------------------------ call builders ------------------------------ */

    function _c(address target, bytes memory data) internal view returns (Call memory) {
        return Call({caller: address(this), target: target, value: 0, data: data});
    }

    function _cAs(address caller, address target, bytes memory data) internal pure returns (Call memory) {
        return Call({caller: caller, target: target, value: 0, data: data});
    }

    function _one(Call memory a) internal pure returns (Call[] memory cs) {
        cs = new Call[](1);
        cs[0] = a;
    }

    function _cat(Call[] memory a, Call[] memory b) internal pure returns (Call[] memory cs) {
        cs = new Call[](a.length + b.length);
        for (uint256 i; i < a.length; ++i) {
            cs[i] = a[i];
        }
        for (uint256 i; i < b.length; ++i) {
            cs[a.length + i] = b[i];
        }
    }

    function _push(Call[] memory a, Call memory b) internal pure returns (Call[] memory) {
        return _cat(a, _one(b));
    }

    /// @dev Calls (inside an unlock) that create an order owned by this contract and executed by the Router (the
    ///      hook's one trusted swap caller): authorize the Router, `PoolManager.swap` as the Router with
    ///      `UserParams(this, router, ...)`, then settle the ERC20 input for the Router, then (if any) pay the priority
    ///      bid to the hook's credit, exactly as `Router` does. Leaves the pending-match hand-off set to the Router; the
    ///      caller appends `matchNewOrder` as the Router.
    function _createCalls(PoolKey memory k, bool zeroForOne, uint256 amountIn, uint256 amountOutMin, uint256 bid)
        internal
        view
        returns (Call[] memory cs)
    {
        Currency input = zeroForOne ? k.currency0 : k.currency1;
        cs = new Call[](bid == 0 ? 5 : 8);
        cs[0] = _c(address(hook), abi.encodeCall(hook.setExecutor, (k.toId(), address(router), true)));
        cs[1] = _cAs(
            address(router),
            address(manager),
            abi.encodeCall(
                manager.swap,
                (
                    k,
                    SwapParams(zeroForOne, -int256(amountIn), uint160(2 ** 96)),
                    abi.encode(
                        AsyncSwap.UserParams({
                            user: address(this), executor: address(router), amountOutMin: amountOutMin, priorityFee: bid
                        })
                    )
                )
            )
        );
        cs[2] = _c(address(manager), abi.encodeCall(manager.sync, (input)));
        cs[3] = _c(Currency.unwrap(input), abi.encodeCall(MockERC20.transfer, (address(manager), amountIn)));
        cs[4] = _c(address(manager), abi.encodeCall(manager.settleFor, (address(router))));
        if (bid != 0) {
            Currency num = currency1; // the fixture hook's numeraire (no external call: keeps vm.expectRevert aimed at the unlock)
            cs[5] = _c(address(manager), abi.encodeCall(manager.sync, (num)));
            cs[6] = _c(Currency.unwrap(num), abi.encodeCall(MockERC20.transfer, (address(manager), bid)));
            cs[7] = _c(address(manager), abi.encodeCall(manager.settleFor, (address(hook))));
        }
    }

    /// @dev Pre-pay `amount` of ERC20 `output` to the hook's PoolManager credit, as `Router.fillOrder`.
    function _payToHookCalls(Currency output, uint256 amount) internal view returns (Call[] memory cs) {
        cs = new Call[](3);
        cs[0] = _c(address(manager), abi.encodeCall(manager.sync, (output)));
        cs[1] = _c(Currency.unwrap(output), abi.encodeCall(MockERC20.transfer, (address(manager), amount)));
        cs[2] = _c(address(manager), abi.encodeCall(manager.settleFor, (address(hook))));
    }

    /* --------------------------------- orders ---------------------------------- */

    function _selfOrder(PoolKey memory k, bool zeroForOne, uint256 amountIn, uint256 amountOutMin, uint256 bid)
        internal
        view
        returns (AsyncOrder memory o)
    {
        o = AsyncOrder({
            key: k,
            owner: address(this),
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            priorityFee: bid,
            sqrtPrice: uint160(2 ** 96),
            salt: _saltOf(address(this), amountIn, amountOutMin, bid)
        });
    }

    function _saltOf(address user, uint256 amountIn, uint256 amountOutMin, uint256 bid)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(block.timestamp, block.number, address(manager), user, amountIn, amountOutMin, bid));
    }

    function _idOf(AsyncOrder memory o) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, o.key.toId(), o.owner, o.zeroForOne, o.salt));
    }

    /// @dev `_placeOrder` on an arbitrary pool key (ERC20 input only), via the Router.
    function _placeOrderOn(PoolKey memory k, address maker, bool zeroForOne, uint256 amountIn, uint256 amountOutMin)
        internal
        returns (AsyncOrder memory order, bytes32 id)
    {
        vm.prank(maker);
        hook.setExecutor(k.toId(), address(router), true);
        order = AsyncOrder({
            key: k,
            owner: maker,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            priorityFee: 100_000,
            sqrtPrice: uint160(2 ** 96),
            salt: bytes32(0)
        });
        vm.prank(maker);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: maker, executor: address(router), amountOutMin: amountOutMin, priorityFee: 100_000
                })
            )
        );
        order.salt = _saltOf(maker, amountIn, amountOutMin, 100_000);
        id = _idOf(order);
    }

    /// @dev A second pool of the same hook with native ETH as currency0 and the numeraire as currency1.
    function _initNativePool() internal returns (PoolKey memory k) {
        k = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(1),
            hooks: hook
        });
        manager.initialize(k, 2 ** 96);
    }

    /* ---------------------------- raw storage reads ----------------------------- */

    /// @dev `asyncOrders[pid]` base slot; fields: poolManager, numeraire, feeVault, orders, isExecutor.
    function _stateSlot(PoolId pid) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(PoolId.unwrap(pid), ASYNC_ORDERS_SLOT)));
    }

    /// @dev `asyncOrders[pid].orders[id]` base slot (5 words: owner, amountIn, amountOutMin,
    ///      {price, isBuy, zeroForOne, sequence}, {priorityFee, priorityKey}).
    function _orderSlot(PoolId pid, bytes32 id) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(id, _stateSlot(pid) + 3)));
    }

    function _orderWords(PoolId pid, bytes32 id) internal view returns (bytes32[5] memory w) {
        uint256 s = _orderSlot(pid, id);
        for (uint256 i; i < 5; ++i) {
            w[i] = _loadHook(bytes32(s + i));
        }
    }

    function _sequenceOf(PoolId pid, bytes32 id) internal view returns (uint64) {
        return uint64(uint256(_loadHook(bytes32(_orderSlot(pid, id) + 3))) >> 144);
    }

    /// @dev `priceBooks[pid]` word 0: {nextSequence, openOrderCount}.
    function _bookWord0(PoolId pid) internal view returns (bytes32) {
        return _loadHook(keccak256(abi.encode(PoolId.unwrap(pid), PRICE_BOOKS_SLOT)));
    }

    function _nextSequence(PoolId pid) internal view returns (uint64) {
        return uint64(uint256(_bookWord0(pid)));
    }

    function _claims(address who, Currency c) internal view returns (uint256) {
        return manager.balanceOf(who, c.toId());
    }

    receive() external payable {}
}
