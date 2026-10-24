// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;
import {CurrentHuffHarness} from "./CurrentHuffHarness.sol";

/// @notice Gross execution gas around the real unlock; refunds and transaction intrinsic gas excluded.
///         Storage touched by a dry run is explicitly cooled before measurement.
contract EligibleGasTest is CurrentHuffHarness {
    struct Accesses {
        address target;
        bytes32[] reads;
        bytes32[] writes;
    }

    function _measure(uint8 count) internal returns (uint256 used) {
        Call[] memory calls = new Call[]((uint256(count) + 7) / 8);
        for (uint256 j; j < calls.length; ++j) {
            uint8 n = uint8(uint256(count) - j * 8 > 8 ? 8 : uint256(count) - j * 8);
            calls[j] = _c(address(hook), abi.encodeCall(hook.matchBook, (key, n)));
        }
        uint256 snap = vm.snapshotState();
        vm.record();
        _run(calls);
        Accesses[] memory access = new Accesses[](5);
        address[5] memory targets =
            [address(hook), address(manager), address(token0), address(token1), address(hook.feeVault())];
        for (uint256 i; i < targets.length; ++i) {
            (bytes32[] memory r, bytes32[] memory w) = vm.accesses(targets[i]);
            access[i] = Accesses(targets[i], r, w);
        }
        assertTrue(vm.revertToState(snap));
        for (uint256 i; i < access.length; ++i) {
            for (uint256 j; j < access[i].reads.length; ++j) {
                vm.coolSlot(access[i].target, access[i].reads[j]);
            }
            for (uint256 j; j < access[i].writes.length; ++j) {
                vm.coolSlot(access[i].target, access[i].writes[j]);
            }
            vm.cool(access[i].target);
        }
        uint256 beforeGas = gasleft();
        bytes[] memory res = _runR(calls);
        used = beforeGas - gasleft();
        uint256 total;
        for (uint256 i; i < res.length; ++i) {
            total += abi.decode(res[i], (uint8));
        }
        assertEq(total, count);
        assertTrue(vm.revertToState(snap));
    }

    function _bench(uint256 blockers) internal {
        for (uint256 i; i < blockers; ++i) {
            _rest(key, address(uint160(0x1000 + i)), true, 2e15 - 1, 2_000_000, 100001 + i);
        }
        for (uint256 i; i < 32; ++i) {
            _rest(key, alice, true, 1e18, 1e9, 100000);
        }
        for (uint256 i; i < 32; ++i) {
            _rest(key, bob, false, 1e9, 1e18, 100000);
        }
        if (blockers == 128 && vm.envOr("EXPORT_GAS_FIXTURE", false)) {
            // dumpState exports touched accounts; ensure the Router's immutable runtime is included.
            vm.etch(address(router), address(router).code);
            vm.dumpState("deployments/eligible-gas-state.json");
            emit log_named_address("benchmark_router", address(router));
            emit log_named_bytes("benchmark_calldata", abi.encodeCall(router.matchBook, (key, 8)));
        }
        for (uint8 cap = 1; cap <= 32; cap *= 2) {
            emit log_named_uint("blockers", blockers);
            emit log_named_uint("matches", cap);
            emit log_named_uint("gross_gas", _measure(cap));
        }
    }

    function test_gasNoBlockers() public {
        _bench(0);
    }

    function test_gasOneBlocker() public {
        _bench(1);
    }

    function test_gasSixteenBlockers() public {
        _bench(16);
    }

    function test_gas128Blockers() public {
        _bench(128);
    }
}
