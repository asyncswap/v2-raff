// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ISignatureTransfer} from "@async-swap/interfaces/ISignatureTransfer.sol";
import {Permit2Bytecode} from "./utils/Permit2Bytecode.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {Router} from "@async-swap/Router.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {Currency, IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Coverage for orders where one side of the pair is native ETH (address(0)).
///         Native pools always have currency0 = address(0) (since address(0) sorts first),
///         so:
///           • zeroForOne = true   → maker SELLS ETH        for ERC20 (native input)
///           • zeroForOne = false  → maker BUYS  ETH (sells ERC20 for ETH; native output)
///
/// These are intentionally separate from AsyncSwapTest, which uses a 2-ERC20 pool and
/// can't exercise the `Currency.isAddressZero()` / msg.value paths.
contract NativeAsyncSwapTest is Test {
    using PoolIdLibrary for PoolKey;

    address owner = makeAddr("deployer");
    address alice = makeAddr("alice"); // maker
    address bob = makeAddr("bob"); // filler
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

        // Fund participants with ETH and ERC20 so the swaps and fills can settle.
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        erc20.mint(alice, 100 ether);
        erc20.mint(bob, 100 ether);
        vm.prank(alice);
        erc20.approve(address(router), type(uint256).max);
        vm.prank(bob);
        erc20.approve(address(router), type(uint256).max);
        vm.prank(alice);
        hook.setExecutor(poolId, address(router), true);
    }

    /// @dev Predict the contract-assigned salt; mirrors `_createOrder`.
    /// @dev The 0.02% trade fee, rounded up.
    function _fee(uint256 x) internal pure returns (uint256) {
        return Math.mulDiv(x, 2, 10_000, Math.Rounding.Ceil);
    }

    function _expectedSalt(address user, uint256 amountIn, uint256 amountOutMin) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(block.timestamp, block.number, address(manager), user, amountIn, amountOutMin, 100_000)
            );
    }

    function _orderIdFor(address maker, bool zeroForOne, bytes32 salt) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, poolId, maker, zeroForOne, salt));
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

    function _withAssignedSalt(AsyncOrder memory order) internal view returns (AsyncOrder memory) {
        order.salt = _expectedSalt(order.owner, order.amountIn, order.amountOutMin);
        return order;
    }

    /* --------------------------- maker submit native input --------------------------- */

    /// Maker sells 1 ETH for ≥ 0.95 TST. Router.swap must be payable; msg.value
    /// equals amountIn so the router can settle the maker's input to PM.
    function test_swap_nativeInput_create() public {
        AsyncOrder memory order = _order(alice, true, 1 ether, 0.95 ether);

        vm.startPrank(alice);
        // No ERC20 approve needed for native input — caller forwards ETH via msg.value.
        router.swap{value: 1 ether}(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: alice, executor: address(router), amountOutMin: 0.95 ether, priorityFee: 100_000
                })
            )
        );
        vm.stopPrank();

        bytes32 id = _orderIdFor(alice, true, _expectedSalt(alice, 1 ether, 0.95 ether));
        (uint256 storedIn, uint256 storedOutMin) = hook.asyncOrderInfo(poolId, id);
        assertEq(storedIn, 1 ether, "amountIn stored");
        assertEq(storedOutMin, 0.95 ether, "amountOutMin stored");
    }

    /* ------------------------------- fill native output ------------------------------ */

    /// Maker has an order selling 1 ETH for 0.95 TST. Bob fills it: pays 0.95 TST, receives 1 ETH.
    function test_fill_nativeOutput_fillerSendsErc20_receivesEth() public {
        AsyncOrder memory order = _order(alice, true, 1 ether, 0.95 ether);

        vm.startPrank(alice);
        router.swap{value: 1 ether}(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: alice, executor: address(router), amountOutMin: 0.95 ether, priorityFee: 100_000
                })
            )
        );
        vm.stopPrank();

        order = _withAssignedSalt(order);

        uint256 bobEthBefore = bob.balance;
        uint256 bobErc20Before = erc20.balanceOf(bob);
        uint256 aliceErc20Before = erc20.balanceOf(alice);

        // Bob fills: ERC20 output side, so he approves the Router to pull TST.
        vm.startPrank(bob);
        erc20.approve(address(router), type(uint256).max);
        router.fillOrder(order, type(uint256).max, "");
        vm.stopPrank();

        // Bob: -0.95 TST, +1 ETH. Alice: +0.95 TST, -1 ETH (already paid).
        assertEq(
            bobErc20Before - erc20.balanceOf(bob),
            0.95 ether + hook.calculatePoolFee(order.key.fee, 0.95 ether),
            "filler paid TST"
        );
        assertEq(bob.balance, bobEthBefore, "no native callback during fill");
        assertEq(manager.balanceOf(bob, 0), 1 ether - _fee(1 ether), "filler received ETH claims");
        assertEq(erc20.balanceOf(alice) - aliceErc20Before, 0.95 ether - _fee(0.95 ether), "maker received real TST");
        assertEq(manager.balanceOf(address(hook.feeVault()), 0), _fee(1 ether), "vault received the ETH trade fee");
    }

    /// If the hook refuses the filler's ETH, the Router reverts before any settlement.
    function test_RevertWhen_NativeOutputForwardFails() public {
        AsyncOrder memory order = _order(alice, false, 1 ether, 0.9 ether);
        vm.prank(alice);
        router.swap(order, abi.encode(AsyncSwap.UserParams(alice, address(router), 0.9 ether, 100_000)));
        order = _withAssignedSalt(order);

        uint256 gross = 0.9 ether + hook.calculatePoolFee(order.key.fee, 0.9 ether);
        // Only the Router's value-carrying forward matches: the hook's view calls carry no value.
        vm.mockCallRevert(address(hook), gross, bytes(""), bytes("refused"));
        vm.prank(bob);
        vm.expectRevert("Native output transfer to hook failed");
        router.fillOrder{value: gross}(order, type(uint256).max, "");
        vm.clearMockedCalls();

        assertEq(hook.asyncOrder(poolId, _orderIdFor(alice, false, order.salt)), 1 ether, "order untouched");
    }

    /* --------------------------- maker submit native output --------------------------- */

    /// Maker sells 1 TST for ≥ 0.9 ETH (zeroForOne=false; input=currency1, output=currency0=ETH).
    function test_swap_nativeOutput_create() public {
        AsyncOrder memory order = _order(alice, false, 1 ether, 0.9 ether);

        vm.startPrank(alice);
        erc20.approve(address(router), type(uint256).max);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: alice, executor: address(router), amountOutMin: 0.9 ether, priorityFee: 100_000
                })
            )
        );
        vm.stopPrank();

        bytes32 id = _orderIdFor(alice, false, _expectedSalt(alice, 1 ether, 0.9 ether));
        (uint256 storedIn, uint256 storedOutMin) = hook.asyncOrderInfo(poolId, id);
        assertEq(storedIn, 1 ether, "amountIn stored");
        assertEq(storedOutMin, 0.9 ether, "amountOutMin stored");
    }

    /* -------------------------------- fill native input ------------------------------- */

    /// Inverse of test_fill_nativeOutput_*: filler pays ETH, receives ERC20.
    function test_fill_nativeInput_fillerSendsEth_receivesErc20() public {
        AsyncOrder memory order = _order(alice, false, 1 ether, 0.9 ether);

        vm.startPrank(alice);
        erc20.approve(address(router), type(uint256).max);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: alice, executor: address(router), amountOutMin: 0.9 ether, priorityFee: 100_000
                })
            )
        );
        vm.stopPrank();

        order = _withAssignedSalt(order);

        uint256 bobEthBefore = bob.balance;
        uint256 bobErc20Before = erc20.balanceOf(bob);
        uint256 aliceEthBefore = alice.balance;

        // Bob fills with native ETH output side — pays 0.9 ETH, receives 1 TST.
        // Router.fillOrder must accept msg.value here.
        vm.startPrank(bob);
        router.fillOrder{value: 0.9 ether + hook.calculatePoolFee(order.key.fee, 0.9 ether)}(
            order, type(uint256).max, ""
        );
        vm.stopPrank();

        assertEq(
            bobEthBefore - bob.balance, 0.9 ether + hook.calculatePoolFee(order.key.fee, 0.9 ether), "filler paid ETH"
        );
        assertEq(erc20.balanceOf(bob) - bobErc20Before, 1 ether - _fee(1 ether), "filler received TST");
        assertEq(alice.balance, aliceEthBefore, "no native callback during fill");
        assertEq(manager.balanceOf(alice, 0), 0.9 ether - _fee(0.9 ether), "maker received ETH claims");
        assertEq(manager.balanceOf(address(hook.feeVault()), 0), _fee(0.9 ether), "vault received the ETH trade fee");
    }

    /* ------------------------------- cancel native input ------------------------------ */

    /// Maker submits a native-input order then cancels it; should reclaim the full ETH balance.
    function test_cancel_nativeInput_makerReclaimsEth() public {
        AsyncOrder memory order = _order(alice, true, 1 ether, 0.95 ether);

        uint256 aliceEthBefore = alice.balance;

        vm.startPrank(alice);
        router.swap{value: 1 ether}(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: alice, executor: address(router), amountOutMin: 0.95 ether, priorityFee: 100_000
                })
            )
        );
        order = _withAssignedSalt(order);
        router.cancelOrder(order);
        vm.stopPrank();

        bytes32 id = _orderIdFor(alice, true, order.salt);
        (uint256 leftIn,) = hook.asyncOrderInfo(poolId, id);
        assertEq(leftIn, 0, "order deleted");
        // Submit + cancel preserves wallet ETH plus withdrawable claims.
        assertEq(alice.balance, aliceEthBefore - 1 ether, "native refund remains in PoolManager");
        assertEq(manager.balanceOf(alice, 0), 1 ether, "maker reclaimed ETH claims");
    }
}
