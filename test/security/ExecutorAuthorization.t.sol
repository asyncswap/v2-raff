// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {IPoolManager, SwapParams} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

/// @notice Orders can only be opened and filled by an executor the maker has authorized. A
///         caller running its own PoolManager unlock with `UserParams` naming a maker as `user`
///         and itself as `executor` is rejected at create, and its direct `executeOrder` call on
///         the maker's live order is rejected as well.
contract UnauthorizedExecutor is IUnlockCallback {
    using CurrencySettler for Currency;
    IPoolManager public immutable manager;
    AsyncSwap public immutable hook;
    address public maker;
    PoolKey public poolKey;
    AsyncOrder public makerOrder;

    constructor(IPoolManager _manager, AsyncSwap _hook) {
        manager = _manager;
        hook = _hook;
    }

    function run(address _maker, PoolKey calldata _key, AsyncOrder calldata _makerOrder) external {
        maker = _maker;
        poolKey = _key;
        makerOrder = _makerOrder;
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager), "only PM");
        bool zeroForOne = makerOrder.zeroForOne;
        SwapParams memory sp = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -1,
            sqrtPriceLimitX96: zeroForOne
                ? uint160(4295128740)
                : uint160(1461446703485210103287273052203988822378723970341)
        });
        // hookData names the maker as `user` and this contract as `executor`; the maker never
        // authorized `address(this)`, so the hook rejects the create.
        manager.swap(
            poolKey,
            sp,
            abi.encode(AsyncSwap.UserParams({user: maker, executor: address(this), amountOutMin: 1, priorityFee: 0}))
        );
        Currency input = zeroForOne ? poolKey.currency0 : poolKey.currency1;
        input.settle(manager, address(this), 1, false);

        // executeOrder on the maker's live order from an unauthorized executor also reverts.
        Currency output = makerOrder.zeroForOne ? poolKey.currency1 : poolKey.currency0;
        IERC20Minimal(Currency.unwrap(output)).transfer(address(hook), makerOrder.amountOutMin);
        hook.executeOrder(makerOrder, abi.encode(address(this)));
        return "";
    }
}

contract ExecutorAuthorizationTest is SetupHook {
    address maker = makeAddr("maker");

    function setUp() public override {
        super.setUp();
        topUp(maker, 100 ether);
    }

    function test_RevertWhen_UnauthorizedExecutorCreatesOrFills() public {
        uint256 amountIn = 5 ether;
        uint256 amountOutMin = 4.5 ether;
        AsyncOrder memory makerOrder = AsyncOrder({
            key: key,
            owner: maker,
            zeroForOne: true,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            priorityFee: 0,
            sqrtPrice: 2 ** 96,
            salt: bytes32(0)
        });

        vm.startPrank(maker);
        token0.approve(address(router), amountIn);
        router.swap(
            makerOrder,
            abi.encode(
                AsyncSwap.UserParams({
                    user: maker, executor: address(router), amountOutMin: amountOutMin, priorityFee: 0
                })
            )
        );
        vm.stopPrank();

        // Patch the salt so the executeOrder call references the live orderId.
        makerOrder.salt = _expectedSalt(maker, amountIn, amountOutMin);

        UnauthorizedExecutor executor = new UnauthorizedExecutor(manager, hook);
        topUp(address(executor), amountOutMin + 1);

        vm.expectRevert();
        executor.run(maker, key, makerOrder);
    }
}
