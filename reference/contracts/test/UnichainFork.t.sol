// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AsyncSwap} from "src/AsyncSwap.sol";
import {Router} from "src/Router.sol";
import {AsyncOrder} from "src/types/AsyncOrder.sol";
import {AsyncFiller} from "src/libraries/AsyncFiller.sol";
import {ISignatureTransfer} from "src/interfaces/ISignatureTransfer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Pinned-fork settlement tests against real Unichain PoolManager and USDC bytecode.
/// @dev Test-only hook installation and participant funding are cheatcodes. No broadcast occurs.
/// Defaults to the unichain RPC alias at block 61,709,000; environment variables can override both.
contract UnichainForkTest is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager constant MANAGER = IPoolManager(0x1F98400000000000000000000000000000000004);
    address constant USDC = 0x078D782b760474a361dDA0AF3839290b0EF57AD6;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint160 constant SQRT_PRICE = 3961408125713216879677197; // 2,500 USDC per ETH, raw units
    AsyncSwap hook;
    Router router;
    PoolKey key;
    address seller = makeAddr("fork seller");
    address buyer = makeAddr("fork buyer");

    function setUp() public {
        string memory rpc = vm.envOr("UNICHAIN_FORK_RPC_URL", string("unichain"));
        uint256 fork = vm.createFork(rpc, vm.envOr("UNICHAIN_FORK_BLOCK", uint256(61_709_000)));
        vm.selectFork(fork);
        assertEq(block.chainid, 130, "wrong target chain");
        assertGt(address(MANAGER).code.length, 0);
        assertGt(PERMIT2.code.length, 0);
        assertEq(IERC20Metadata(USDC).decimals(), 6);
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        address fixture = address((uint160(0xA5) << 152) | flags);
        assertEq(fixture.code.length, 0, "fixture address occupied");
        router = new Router(MANAGER, AsyncSwap(payable(address(fixture))), ISignatureTransfer(PERMIT2), 0);
        deployCodeTo(
            "AsyncSwap.sol",
            abi.encode(MANAGER, Currency.wrap(USDC), address(this), address(router), uint256(0), type(uint8).max),
            fixture
        );
        hook = AsyncSwap(payable(fixture));
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDC), LPFeeLibrary.DYNAMIC_FEE_FLAG, 1, hook);
        MANAGER.initialize(key, SQRT_PRICE);
        _fund(seller);
        _fund(buyer);
    }

    function _fund(address actor) internal {
        vm.deal(actor, 100 ether);
        deal(USDC, actor, 1_000_000e6);
        vm.startPrank(actor);
        IERC20(USDC).approve(address(router), type(uint256).max);
        hook.setExecutor(key.toId(), address(router), true);
        vm.stopPrank();
    }

    function _submit(address actor, bool sell, uint256 amount, uint256 minimum, uint256 bid)
        internal
        returns (AsyncOrder memory order)
    {
        order = AsyncOrder(key, actor, sell, amount, minimum, bid, SQRT_PRICE, bytes32(0));
        vm.prank(actor);
        router.swap{value: sell ? amount : 0}(
            order, abi.encode(AsyncSwap.UserParams(actor, address(router), minimum, bid))
        );
        order.salt = keccak256(abi.encode(block.timestamp, block.number, address(MANAGER), actor, amount, minimum, bid));
    }

    /// @dev The 0.02% trade fee, rounded up.
    function _fee(uint256 x) internal pure returns (uint256) {
        return Math.mulDiv(x, 2, 10_000, Math.Rounding.Ceil);
    }

    function _remaining(AsyncOrder memory order) internal view returns (uint256) {
        return hook.asyncOrder(
            key.toId(), keccak256(abi.encode(block.chainid, key.toId(), order.owner, order.zeroForOne, order.salt))
        );
    }

    function testFork_nativeUsdcMatchAndCancelResidual() public {
        uint256 quoteBefore = IERC20(USDC).balanceOf(seller);
        uint256 ethBefore = buyer.balance;
        AsyncOrder memory ask = _submit(seller, true, 2 ether, 5_000e6, 100_000);
        _submit(buyer, false, 2_500e6, 1 ether, 100_000);
        assertEq(IERC20(USDC).balanceOf(seller), quoteBefore - 100_000);
        assertEq(MANAGER.balanceOf(seller, uint160(USDC)), 2_500e6 - _fee(2_500e6));
        assertEq(buyer.balance, ethBefore);
        assertEq(MANAGER.balanceOf(buyer, 0), 1 ether - _fee(1 ether));
        assertEq(MANAGER.balanceOf(address(hook.feeVault()), 0), _fee(1 ether));
        assertEq(_remaining(ask), 1 ether);
        assertEq(MANAGER.balanceOf(address(hook), 0), 1 ether);
        vm.prank(seller);
        router.cancelOrder(ask);
        assertEq(_remaining(ask), 0);
        assertEq(MANAGER.balanceOf(address(hook), 0), 0);
        assertEq(MANAGER.balanceOf(address(hook), uint160(USDC)), 0);
        assertEq(seller.balance + MANAGER.balanceOf(seller, 0), 99 ether);
    }

    function testFork_priorityBidNonRefundableWithoutActiveLp() public {
        uint256 beforeBalance = IERC20(USDC).balanceOf(seller);
        AsyncOrder memory ask = _submit(seller, true, 1 ether, 2_500e6, 100_000);
        vm.prank(seller);
        router.cancelOrder(ask);
        assertEq(IERC20(USDC).balanceOf(seller), beforeBalance - 100_000);
        assertEq(seller.balance + MANAGER.balanceOf(seller, 0), 100 ether);
        assertEq(MANAGER.balanceOf(address(hook), uint160(USDC)), 0);
        assertEq(MANAGER.balanceOf(address(hook.feeVault()), uint160(USDC)), 100_000);
    }

    function testFork_permissionlessContinuationAfterEightMatches() public {
        for (uint256 i; i < 10; ++i) {
            address actor = address(uint160(0xB000 + i));
            _fund(actor);
            _submit(actor, true, 1 ether, 2_500e6, 100_000);
        }
        AsyncOrder memory bid = _submit(buyer, false, 25_000e6, 10 ether, 100_000);
        assertEq(buyer.balance + MANAGER.balanceOf(buyer, 0), 100 ether + 8 * (1 ether - _fee(1 ether)));
        assertEq(_remaining(bid), 5_000e6);
        vm.prank(makeAddr("permissionless keeper"));
        router.matchBook(key, 2);
        assertEq(buyer.balance + MANAGER.balanceOf(buyer, 0), 100 ether + 10 * (1 ether - _fee(1 ether)));
        assertEq(_remaining(bid), 0);
        assertEq(MANAGER.balanceOf(address(hook), 0), 0);
        assertEq(MANAGER.balanceOf(address(hook), uint160(USDC)), 0);
    }
}
