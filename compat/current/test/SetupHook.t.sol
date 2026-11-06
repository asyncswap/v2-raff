// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {CurrentHuffDeploy} from "compat/current/support/CurrentHuffDeploy.sol";

import {ISignatureTransfer} from "@async-swap/interfaces/ISignatureTransfer.sol";
import {Permit2Bytecode} from "./utils/Permit2Bytecode.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {Router} from "@async-swap/Router.sol";
import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {Currency, IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Shared deployment scaffold for protocol tests: PoolManager + AsyncSwap hook + Router +
///         a single `currency0/currency1` MockERC20 pair, with the maker pre-funded.
contract SetupHook is Test {
    using PoolIdLibrary for PoolKey;

    address owner = makeAddr("deployer");
    /// @dev Constructor parameters for `_deployHook`: a suite sets them before `super.setUp()`.
    uint256 hookMinOrderUsd;
    /// @dev Decimals the mock numeraire reports to the hook constructor: 6, like USDC, so the derived $0.10 bid
    ///      cap is 100_000 base units.
    uint8 numeraireDecimals = 6;
    uint8 hookAssetPrecision = type(uint8).max; // no asset floor beyond 1 unit
    /// @dev The Router's MEV tax gas, as deployed. Foundry's default transaction has no priority fee, so no tax.
    uint256 routerMevTaxGas = 20_000_000;
    IPoolManager manager;
    AsyncSwap hook;
    Router router;
    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;
    PoolKey key;
    PoolId poolId;

    function setUp() public virtual {
        _deployManager();
        _deployTokens();
        _deployRouter();
        _deployHook();
        _createKey();
        _initializePool();
        _mintToOwner();
    }

    modifier ownerAction() {
        vm.startPrank(owner);
        _;
        vm.stopPrank();
    }

    function _deployManager() internal {
        manager = new PoolManager(owner);
    }

    function _deployTokens() internal {
        vm.startPrank(owner);
        address tokenA = address(new MockERC20("Token A", "TKA", 18));
        address tokenB = address(new MockERC20("Token B", "TKB", 18));
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        currency0 = Currency.wrap(t0);
        currency1 = Currency.wrap(t1);
        token0 = MockERC20(t0);
        token1 = MockERC20(t1);
        vm.stopPrank();
        vm.label(t0, "token0");
        vm.label(t1, "token1");
        _mockNumeraireDecimals();
    }

    /// @dev The hook's address: its permission flags.
    function _hookAddress() internal pure returns (address) {
        return address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            )
        );
    }

    /// @dev The hook derives its bid cap and minimum from the numeraire's decimals. The 18-decimal mock tokens
    ///      stand in for USDC, so currency1 reports `numeraireDecimals` (6 by default) to the constructor.
    function _mockNumeraireDecimals() internal {
        vm.mockCall(Currency.unwrap(currency1), abi.encodeWithSignature("decimals()"), abi.encode(numeraireDecimals));
    }

    /// @dev Deploys the hook with `router` as its one trusted swap caller: `_deployRouter` runs first.
    function _deployHook() internal virtual {
        _mockNumeraireDecimals();
        CurrentHuffDeploy.hookTo(
            abi.encode(manager, currency1, address(this), address(router), hookMinOrderUsd, hookAssetPrecision),
            _hookAddress()
        );
        hook = AsyncSwap(payable(_hookAddress()));
    }

    /// @dev The revert a swap from any caller but the hook's trusted Router ends in.
    function _notTrustedRouter() internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(AsyncSwap.NotTrustedRouter.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @dev The Router, built with the hook's address before the hook is deployed there (as the deploy script does).
    function _deployRouter() internal {
        router = Router(
            payable(CurrentHuffDeploy.deploy(
                    "src/current/Router.huff",
                    abi.encode(
                        manager,
                        AsyncSwap(payable(_hookAddress())),
                        ISignatureTransfer(Permit2Bytecode.PERMIT2),
                        routerMevTaxGas
                    )
                ))
        );
    }

    function _createKey() internal {
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(1),
            hooks: hook
        });
        poolId = key.toId();
    }

    function _initializePool() internal {
        manager.initialize(key, 2 ** 96);
    }

    function _mintToOwner() internal {
        token0.mint(owner, 2 ** 128 - 1);
        token1.mint(owner, 2 ** 128 - 1);
    }

    function topUp(address user, uint256 amount) public ownerAction {
        token0.transfer(user, amount);
        token1.transfer(user, amount);
        vm.stopPrank();
        vm.prank(user);
        token1.approve(address(router), type(uint256).max);
        vm.prank(user);
        hook.setExecutor(poolId, address(router), true);
        vm.startPrank(owner);
    }

    /// @dev Predict the salt the hook assigns on a fresh `_createOrder`. Mirrors
    ///      `keccak256(abi.encode(block.timestamp, block.number, msg.sender, user, amountIn, amountOutMin, priorityFee))`
    ///      where `msg.sender` at the hook is the PoolManager (since `_beforeSwap` is invoked by PM).
    ///      Only valid when the (user, amountIn, amountOutMin) tuple is fresh in the current block —
    ///      a colliding tuple would trigger the in-contract salt-walk.
    function _expectedSalt(address user, uint256 amountIn, uint256 amountOutMin) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(block.timestamp, block.number, address(manager), user, amountIn, amountOutMin, 100_000)
            );
    }

    /// @dev Compute the orderId the hook will store under, for an order with the given assigned salt.
    function _orderIdFor(address user, bool zeroForOne, bytes32 salt) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, poolId, user, zeroForOne, salt));
    }
}
