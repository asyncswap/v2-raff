// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {HookUnlockBase} from "./HookUnlockBase.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncMatching} from "@async-swap/libraries/AsyncMatching.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapMatchBook.lean`. A crossed book is
///         built for real: `k > 8` resting asks, then a large bid whose automatic `matchNewOrder`
///         stops at the 8-match cap, leaving `k - 8` asks crossing the resting bid.
contract AsyncSwapMatchBookFormalTest is HookUnlockBase {
    function _crossedBook(uint256 leftover) internal {
        uint256 k = 8 + leftover;
        for (uint256 i; i < k; ++i) {
            _placeOrder(alice, true, 1 ether + i, 1 ether + i);
        }
        _placeOrder(bob, false, 50 ether, 50 ether);
        (bool hasBid,,,) = hook.bestOrder(poolId, true);
        (bool hasAsk,,,) = hook.bestOrder(poolId, false);
        assertTrue(hasBid, "bid rests");
        assertEq(hasAsk, leftover != 0, "asks beyond the cap rest");
    }

    function _matchBook(PoolKey memory k, uint8 m) internal returns (uint8) {
        bytes[] memory r = _runR(_one(_c(address(hook), abi.encodeCall(hook.matchBook, (k, m)))));
        return abi.decode(r[0], (uint8));
    }

    function _countMatches(Vm.Log[] memory logs) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == AsyncSwap.AsyncOrdersMatched.selector) ++n;
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMatchBook.lean:96 — AsyncMatching.matchBook: a success had 1 <= maxMatches <= 8 and returns at most maxMatches (the count of AsyncOrdersMatched pairs).
    function testFuzz_asyncMatching_matchBook_ok(uint8 m, uint8 leftover) public {
        _crossedBook(bound(leftover, 0, 6));
        vm.recordLogs();
        try manager.unlock(abi.encode(_one(_c(address(hook), abi.encodeCall(hook.matchBook, (key, m)))))) returns (
            bytes memory raw
        ) {
            uint8 n = abi.decode(abi.decode(raw, (bytes[]))[0], (uint8));
            assertGe(m, 1);
            assertLe(m, 8);
            assertLe(n, m);
            assertEq(n, _countMatches(vm.getRecordedLogs()), "n = pairs matched");
        } catch {}
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMatchBook.lean:161 — maxMatches = 0 or maxMatches > 8 reverts InvalidMatchBound (any key, any state).
    function testFuzz_matchBook_invalidBound(PoolKey memory k, uint8 m, bool zero) public {
        m = zero ? 0 : uint8(bound(m, 9, 255));
        vm.expectRevert(AsyncMatching.InvalidMatchBound.selector);
        hook.matchBook(k, m);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMatchBook.lean:173 — a successful matchBook had 1 <= maxMatches <= 8 and returns at most maxMatches.
    function testFuzz_matchBook_ok(uint8 m, uint8 leftover, bool crossed) public {
        if (crossed) _crossedBook(bound(leftover, 0, 6));
        try this.matchBookExternal(key, m) returns (uint8 n) {
            assertGe(m, 1);
            assertLe(m, 8);
            assertLe(n, m);
        } catch {}
    }

    function matchBookExternal(PoolKey memory k, uint8 m) external returns (uint8) {
        return _matchBook(k, m);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapMatchBook.lean:180 — outside 1 <= maxMatches <= 8 there is no successful run (inside an unlock, on a crossed book).
    function testFuzz_matchBook_bound_noOk(uint8 m, bool zero, uint8 leftover) public {
        _crossedBook(bound(leftover, 0, 3));
        m = zero ? 0 : uint8(bound(m, 9, 255));
        try this.matchBookExternal(key, m) returns (uint8) {
            fail();
        } catch {}
    }
}
