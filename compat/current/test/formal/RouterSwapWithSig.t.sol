// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalProbesA} from "./FormalProbesA.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {Router} from "@async-swap/Router.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/RouterSwapWithSig.lean`. `HOOK.isExecutor`,
///         `HOOK.setExecutorWithSig` and `PoolManager.unlock` are the theorems' opaque calls: mocked.
contract RouterSwapWithSigFormalTest is FormalProbesA {
    using PoolIdLibrary for PoolKey;

    /// @dev `abi.encode(SwapCallback(SwapWithSig, order, 0), permit)` (the Lean `swapWithSigData`).
    function _data(AsyncOrder memory o, Router.PermitData memory p) internal pure returns (bytes memory) {
        return abi.encode(Router.SwapCallback({action: Router.ActionType.SwapWithSig, order: o, maxMatches: 0}), p);
    }

    function _input(AsyncOrder memory o) internal pure returns (address) {
        return Currency.unwrap(o.zeroForOne ? o.key.currency0 : o.key.currency1);
    }

    function _isExecCall(AsyncOrder memory o) internal view returns (bytes memory) {
        return abi.encodeCall(AsyncSwap.isExecutor, (o.key.toId(), o.owner, address(router)));
    }

    function _grantCall(AsyncOrder memory o, Router.ExecutorGrant memory g) internal view returns (bytes memory) {
        return abi.encodeCall(
            AsyncSwap.setExecutorWithSig, (o.key, o.owner, address(router), true, g.nonce, g.deadline, g.signature)
        );
    }

    /// @notice formal/Refinement/Swarm/RouterSwapWithSig.lean:47 — a native input reverts with
    ///         "Native input needs swap()".
    function testFuzz_swapWithSig_native(
        address caller,
        AsyncOrder memory o,
        Router.PermitData memory p,
        Router.ExecutorGrant memory g
    ) public {
        if (o.zeroForOne) o.key.currency0 = Currency.wrap(address(0));
        else o.key.currency1 = Currency.wrap(address(0));
        vm.prank(caller);
        vm.expectRevert(bytes("Native input needs swap()"));
        router.swapWithSig(o, p, g);
    }

    /// @notice formal/Refinement/Swarm/RouterSwapWithSig.lean:55 — ERC-20 input and an empty grant
    ///         signature: no hook call, two transient stores, then exactly `unlock(swapWithSigData)`.
    function testFuzz_swapWithSig_noGrant(
        address caller,
        AsyncOrder memory o,
        Router.PermitData memory p,
        Router.ExecutorGrant memory g
    ) public oneTx {
        vm.assume(_input(o) != address(0));
        g.signature = "";
        _mockUnlockOk();
        vm.expectCall(address(hook), abi.encodeWithSelector(AsyncSwap.isExecutor.selector), 0);
        vm.expectCall(address(hook), abi.encodeWithSelector(AsyncSwap.setExecutorWithSig.selector), 0);
        vm.expectCall(address(manager), 0, abi.encodeCall(IPoolManager.unlock, (_data(o, p))), 1);
        vm.prank(caller);
        router.swapWithSig(o, p, g);
        _assertTransient(o.owner, address(router));
    }

    /// @notice formal/Refinement/Swarm/RouterSwapWithSig.lean:64, changed by the M-01 fix (Lean statement needs
    ///         updating): even when the hook already lists the Router as the owner's executor, a non-empty grant
    ///         is applied, so its nonce is spent and it cannot be replayed after a revocation.
    function testFuzz_swapWithSig_alreadyExecutor(
        address caller,
        AsyncOrder memory o,
        Router.PermitData memory p,
        Router.ExecutorGrant memory g
    ) public oneTx {
        vm.assume(_input(o) != address(0) && g.signature.length != 0);
        vm.mockCall(address(hook), _isExecCall(o), abi.encode(true));
        vm.mockCall(address(hook), _grantCall(o, g), "");
        _mockUnlockOk();
        vm.expectCall(address(hook), 0, _grantCall(o, g), 1);
        vm.expectCall(address(manager), 0, abi.encodeCall(IPoolManager.unlock, (_data(o, p))), 1);
        vm.prank(caller);
        router.swapWithSig(o, p, g);
        _assertTransient(o.owner, address(router));
    }

    /// @notice formal/Refinement/Swarm/RouterSwapWithSig.lean:75, changed by the M-01 fix (Lean statement needs
    ///         updating): the Router no longer reads `HOOK.isExecutor`, so a revert there cannot affect the call.
    function testFuzz_swapWithSig_neverReadsIsExecutor(
        address caller,
        AsyncOrder memory o,
        Router.PermitData memory p,
        Router.ExecutorGrant memory g,
        bytes memory err
    ) public oneTx {
        vm.assume(_input(o) != address(0) && g.signature.length != 0);
        vm.mockCallRevert(address(hook), _isExecCall(o), err);
        vm.mockCall(address(hook), _grantCall(o, g), "");
        _mockUnlockOk();
        vm.expectCall(address(hook), abi.encodeWithSelector(AsyncSwap.isExecutor.selector), 0);
        vm.prank(caller);
        router.swapWithSig(o, p, g);
        _assertTransient(o.owner, address(router));
    }

    /// @notice formal/Refinement/Swarm/RouterSwapWithSig.lean:88 — a non-empty grant, whether or not the Router
    ///         is already an executor: it calls `HOOK.setExecutorWithSig(key, owner, router, true, nonce, deadline, sig)`; a
    ///         revert there is the call's revert, else it continues with `unlock(swapWithSigData)`.
    function testFuzz_swapWithSig_grant(
        address caller,
        AsyncOrder memory o,
        Router.PermitData memory p,
        Router.ExecutorGrant memory g,
        bool grantReverts,
        bytes memory err
    ) public oneTx {
        vm.assume(_input(o) != address(0) && g.signature.length != 0);
        vm.mockCall(address(hook), _isExecCall(o), abi.encode(false));
        _mockUnlockOk();
        if (grantReverts) {
            vm.mockCallRevert(address(hook), _grantCall(o, g), err);
            vm.prank(caller);
            vm.expectRevert(err);
            router.swapWithSig(o, p, g);
        } else {
            vm.mockCall(address(hook), _grantCall(o, g), "");
            vm.expectCall(address(hook), 0, _grantCall(o, g), 1);
            vm.expectCall(address(manager), 0, abi.encodeCall(IPoolManager.unlock, (_data(o, p))), 1);
            vm.prank(caller);
            router.swapWithSig(o, p, g);
            _assertTransient(o.owner, address(router));
        }
    }

    /// @notice formal/Refinement/Swarm/RouterSwapWithSig.lean:107 — a `swapWithSig` that does not revert had a
    ///         non-native input currency.
    function testFuzz_swapWithSig_ok_input(
        address caller,
        AsyncOrder memory o,
        Router.PermitData memory p,
        Router.ExecutorGrant memory g,
        bool zeroIn,
        bool isExec
    ) public {
        if (zeroIn) {
            if (o.zeroForOne) o.key.currency0 = Currency.wrap(address(0));
            else o.key.currency1 = Currency.wrap(address(0));
        }
        vm.mockCall(address(hook), abi.encodeWithSelector(AsyncSwap.isExecutor.selector), abi.encode(isExec));
        vm.mockCall(address(hook), abi.encodeWithSelector(AsyncSwap.setExecutorWithSig.selector), "");
        _mockUnlockOk();
        vm.prank(caller);
        (bool ok,) = address(router).call(abi.encodeCall(Router.swapWithSig, (o, p, g)));
        if (ok) assertTrue(_input(o) != address(0), "input currency is not native");
    }

    /// @notice formal/Refinement/Swarm/RouterSwapWithSig.lean:116 — before `unlock` the Router writes only
    ///         transient storage (USER := owner, FILLER := router): no persistent storage write.
    function testFuzz_swapWithSigPre_get(
        address caller,
        AsyncOrder memory o,
        Router.PermitData memory p,
        Router.ExecutorGrant memory g,
        bool isExec
    ) public oneTx {
        vm.assume(_input(o) != address(0));
        vm.mockCall(address(hook), abi.encodeWithSelector(AsyncSwap.isExecutor.selector), abi.encode(isExec));
        vm.mockCall(address(hook), abi.encodeWithSelector(AsyncSwap.setExecutorWithSig.selector), "");
        _mockUnlockOk();
        vm.record();
        vm.prank(caller);
        router.swapWithSig(o, p, g);
        _assertNoWrites(address(router));
        _assertTransient(o.owner, address(router));
    }

    /// @notice formal/Refinement/Swarm/RouterSwapWithSig.lean:124 — the USER slot `unlock` sees is the order's
    ///         owner, never the caller.
    function testFuzz_swapWithSigPre_user(address caller, AsyncOrder memory o, Router.PermitData memory p)
        public
        oneTx
    {
        vm.assume(_input(o) != address(0));
        _mockUnlockOk();
        _seedTransient(caller); // USER := caller beforehand, so a missing write would show
        _mockUnlockOk();
        vm.prank(caller);
        router.swapWithSig(o, p, Router.ExecutorGrant({nonce: 0, deadline: 0, signature: ""}));
        _assertTransient(o.owner, address(router));
    }

    /// @notice formal/Refinement/Swarm/RouterSwapWithSig.lean:130 — the FILLER slot `unlock` sees is the Router.
    function testFuzz_swapWithSigPre_filler(address caller, AsyncOrder memory o, Router.PermitData memory p)
        public
        oneTx
    {
        vm.assume(_input(o) != address(0));
        _mockUnlockOk();
        vm.prank(caller);
        router.swapWithSig(o, p, Router.ExecutorGrant({nonce: 0, deadline: 0, signature: ""}));
        _assertTransient(o.owner, address(router));
    }
}
