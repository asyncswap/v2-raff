// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalBase} from "./FormalBase.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {MockERC20} from "../utils/MockERC20.sol";

contract InitRelay {
    function init(IPoolManager m, PoolKey memory k, uint160 p) external {
        m.initialize(k, p);
    }
}

/// @notice Area 2: open pool initialization through the real PoolManager.
contract AsyncSwapInitAccessTest is FormalBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function _freshKey() internal returns (PoolKey memory) {
        MockERC20 t = new MockERC20("X", "X", 18);
        address n = Currency.unwrap(hook.numeraire());
        (address a, address b) = address(t) < n ? (address(t), n) : (n, address(t));
        return PoolKey(Currency.wrap(a), Currency.wrap(b), LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(address(hook)));
    }

    function _initialized(PoolKey memory k) internal view returns (bool) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(k.toId());
        return sqrtPriceX96 != 0;
    }

    /// Pool creation is open: any caller can initialize a valid numeraire pool at any price.
    function testFuzz_anyoneCanInitialize(address caller, uint160 p) public {
        p = uint160(bound(p, 4295128739, 1461446703485210103287273052203988822378723970341));
        PoolKey memory k = _freshKey();
        vm.prank(caller);
        manager.initialize(k, p);
        assertTrue(_initialized(k), "initialized");
    }

    /// A periphery relay (PositionManager-like) can initialize too.
    function test_relayCanInitialize() public {
        InitRelay r = new InitRelay();
        PoolKey memory k = _freshKey();
        r.init(manager, k, 2 ** 96);
        assertTrue(_initialized(k), "initialized");
    }

    /// Ownership handover does not affect who may initialize.
    function test_ownershipHandoverDoesNotGateInit(address newOwner) public {
        address old = hook.owner();
        vm.assume(newOwner != old && newOwner != address(0));
        vm.prank(old);
        hook.transferOwnership(newOwner);
        vm.prank(newOwner);
        hook.acceptOwnership();
        assertEq(hook.owner(), newOwner, "owner handed over");

        PoolKey memory k = _freshKey();
        vm.prank(old);
        manager.initialize(k, 2 ** 96);
        assertTrue(_initialized(k), "old owner initialized");
    }
}
