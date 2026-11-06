// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalProbesA} from "./FormalProbesA.sol";
import {Router} from "@async-swap/Router.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/RouterMatchBook.lean`. `PoolManager.unlock` is the
///         theorems' opaque call: mocked (ok with fuzzed return bytes, or reverting with fuzzed data).
contract RouterMatchBookFormalTest is FormalProbesA {
    /// @dev The Lean `matchBookData`: action MatchBook, the key, a zero placeholder order, `maxMatches`.
    function _mbData(PoolKey memory k, uint8 maxMatches) internal pure returns (bytes memory) {
        AsyncOrder memory placeholder;
        placeholder.key = k;
        return _cb(4, placeholder, maxMatches);
    }

    /// @notice formal/Refinement/Swarm/RouterMatchBook.lean:27 — `matchBook` is exactly one
    ///         `unlock(matchBookData(key, maxMatches))` call, with no transient or persistent write of its own.
    function testFuzz_matchBook_eq(address caller, address seed, PoolKey memory k, uint8 maxMatches, bytes memory ret)
        public
        oneTx
    {
        _seedTransient(seed);
        vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.unlock.selector), abi.encode(ret));
        vm.expectCall(address(manager), 0, abi.encodeCall(IPoolManager.unlock, (_mbData(k, maxMatches))), 1);
        vm.record();
        vm.prank(caller);
        router.matchBook(k, maxMatches);
        _assertNoWrites(address(router));
        _assertTransient(seed, address(router)); // untouched by matchBook
    }

    /// @notice formal/Refinement/Swarm/RouterMatchBook.lean:34 — reverts exactly when `unlock` reverts, with
    ///         the same error.
    function testFuzz_matchBook_revert_iff(
        address caller,
        PoolKey memory k,
        uint8 maxMatches,
        bool unlockReverts,
        bytes memory err
    ) public {
        if (unlockReverts) {
            vm.mockCallRevert(address(manager), abi.encodeCall(IPoolManager.unlock, (_mbData(k, maxMatches))), err);
            vm.prank(caller);
            vm.expectRevert(err);
            router.matchBook(k, maxMatches);
        } else {
            vm.mockCall(
                address(manager), abi.encodeCall(IPoolManager.unlock, (_mbData(k, maxMatches))), abi.encode(err)
            );
            vm.prank(caller);
            (bool ok,) = address(router).call(abi.encodeCall(Router.matchBook, (k, maxMatches)));
            assertTrue(ok, "unlock ok => call ok");
        }
    }

    /// @notice formal/Refinement/Swarm/RouterMatchBook.lean:43 — succeeds exactly when `unlock` succeeds; the
    ///         Router writes no storage of its own.
    function testFuzz_matchBook_ok_iff(address caller, PoolKey memory k, uint8 maxMatches, bytes memory ret) public {
        vm.mockCall(address(manager), abi.encodeCall(IPoolManager.unlock, (_mbData(k, maxMatches))), abi.encode(ret));
        vm.record();
        vm.prank(caller);
        (bool ok,) = address(router).call(abi.encodeCall(Router.matchBook, (k, maxMatches)));
        assertTrue(ok, "unlock ok => call ok");
        _assertNoWrites(address(router));
    }
}
