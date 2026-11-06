// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ISignatureTransfer} from "@async-swap/interfaces/ISignatureTransfer.sol";
import {Permit2Bytecode} from "../utils/Permit2Bytecode.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {Router} from "@async-swap/Router.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {Currency, IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice A native-input swap must send exactly `amountIn` as msg.value; any other value reverts
///         at the Router before any state changes.
contract NativeInputMsgValueTest is Test {
    using PoolIdLibrary for PoolKey;

    address owner = makeAddr("deployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    IPoolManager manager;
    AsyncSwap hook;
    Router router;
    MockERC20 erc20;
    Currency currency0; // native (address(0))
    Currency currency1; // erc20
    PoolKey key;
    PoolId poolId;

    function setUp() public {
        manager = new PoolManager(owner);
        erc20 = new MockERC20("Test Token", "TST", 18);

        currency0 = Currency.wrap(address(0));
        currency1 = Currency.wrap(address(erc20));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        router = new Router(manager, AsyncSwap(payable(address(flags))), ISignatureTransfer(Permit2Bytecode.PERMIT2), 0);
        // The 18-decimal mock stands in for 6-decimal USDC: the hook derives its $0.10 bid cap from decimals.
        vm.mockCall(Currency.unwrap(currency1), abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        deployCodeTo(
            "AsyncSwap.sol",
            abi.encode(manager, currency1, address(this), address(router), uint256(0), type(uint8).max),
            address(flags)
        );
        hook = AsyncSwap(payable(address(flags)));

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(1),
            hooks: hook
        });
        poolId = key.toId();
        manager.initialize(key, 2 ** 96);

        vm.deal(alice, 100 ether);
        vm.deal(bob, 0); // bob starts with no ETH
        vm.prank(alice);
        hook.setExecutor(poolId, address(router), true);
        vm.prank(bob);
        hook.setExecutor(poolId, address(router), true);
    }

    function _order(address maker, bool zeroForOne, uint256 amountIn, uint256 amountOutMin)
        internal
        view
        returns (AsyncOrder memory)
    {
        return AsyncOrder({
            key: key,
            owner: maker,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            priorityFee: 100_000,
            sqrtPrice: 2 ** 96,
            salt: bytes32(0)
        });
    }

    function test_RevertWhen_NativeInputMsgValueMismatch() public {
        AsyncOrder memory order = _order(bob, true, 1 ether, 1 wei);
        vm.startPrank(bob);
        vm.expectRevert();
        router.swap{value: 0}(
            order,
            abi.encode(
                AsyncSwap.UserParams({user: bob, executor: address(router), amountOutMin: 1 wei, priorityFee: 100_000})
            )
        );
        vm.stopPrank();
    }
}
