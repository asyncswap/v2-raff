// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {CurrencySettler} from "@async-swap/libraries/CurrencySettler.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {SetupHook} from "../SetupHook.t.sol";
import {Currency, IPoolManager, SwapParams} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @dev Opens an order naming another account as maker and that account's executor (Router), funding it itself.
contract ThirdPartySubmitter {
    using CurrencySettler for Currency;

    IPoolManager pm;
    PoolKey key;
    address maker;
    address executor;

    constructor(IPoolManager _pm, PoolKey memory _key, address _maker, address _executor) {
        pm = _pm;
        key = _key;
        maker = _maker;
        executor = _executor;
    }

    function go() external {
        pm.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        pm.swap(
            key,
            SwapParams(true, -1 ether, 4295128740),
            abi.encode(AsyncSwap.UserParams({user: maker, executor: executor, amountOutMin: 1, priorityFee: 0}))
        );
        key.currency0.settle(pm, address(this), 1 ether, false);
        return "";
    }
}

/// @notice Only the declared executor itself may open orders for a maker.
contract OrderSpoofingTest is SetupHook {
    function test_RevertWhen_NonExecutorOpensOrderForMaker() public {
        address maker = makeAddr("maker");
        topUp(maker, 1 ether); // grants setExecutor(maker -> router)
        assertTrue(hook.isExecutor(poolId, maker, address(router)));

        ThirdPartySubmitter s = new ThirdPartySubmitter(manager, key, maker, address(router));
        token0.mint(address(s), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(AsyncFiller.NotAuthorizedExecutor.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        s.go();
    }
}
