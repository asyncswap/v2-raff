// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @notice Regression for exact eligibility with real Router, hook and PoolManager.
contract CoarsePriceBlockingTest is SetupHook {
    address blocker = makeAddr("blocker");
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");

    function setUp() public override {
        _deployManager();
        vm.startPrank(owner);
        deployCodeTo("test/utils/MockERC20.sol:MockERC20", abi.encode("Asset", "ASSET", uint8(18)), address(0x100000));
        deployCodeTo(
            "test/utils/MockERC20.sol:MockERC20", abi.encode("USD Coin fixture", "USDC", uint8(6)), address(0x200000)
        );
        vm.stopPrank();
        token0 = MockERC20(address(0x100000));
        token1 = MockERC20(address(0x200000));
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));
        _deployRouter();
        hookMinOrderUsd = 1;
        _deployHook();
        _createKey();
        // 1,000 USDC per 18-decimal asset: raw token1/token0 ratio = 1e-9.
        manager.initialize(key, 2505414483750479311864138);
        _mintToOwner();
        topUp(blocker, 100 ether);
        topUp(seller, 100 ether);
        topUp(buyer, 100 ether);
    }

    /// @dev The 0.02% trade fee, rounded up.
    function _fee(uint256 x) internal pure returns (uint256) {
        return Math.mulDiv(x, 2, 10_000, Math.Rounding.Ceil);
    }

    function submit(address maker, bool zfo, uint256 amount, uint256 minimum, uint256 bid)
        internal
        returns (AsyncOrder memory order)
    {
        bytes32 salt =
            keccak256(abi.encode(block.timestamp, block.number, address(manager), maker, amount, minimum, bid));
        while (hook.asyncOrder(poolId, _orderIdFor(maker, zfo, salt)) != 0) {
            salt = keccak256(abi.encode(salt));
        }
        order = AsyncOrder(key, maker, zfo, amount, minimum, bid, 2 ** 96, salt);
        vm.startPrank(maker);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        router.swap(order, abi.encode(AsyncSwap.UserParams(maker, address(router), minimum, bid)));
        vm.stopPrank();
    }

    function test_twoDollarBlockerCannotStallTwentyThousandDollars() public {
        AsyncOrder memory bad = submit(blocker, true, 2e15 - 1, 2_000_000, 100_001);
        for (uint256 i; i < 20; ++i) {
            submit(seller, true, 1e18, 1_000_000_000, 100_000);
        }
        uint256 before = manager.balanceOf(seller, currency1.toId());
        for (uint256 i; i < 20; ++i) {
            submit(buyer, false, 1_000_000_000, 1e18, 100_000);
        }
        // Match proceeds, less the 0.02% trade fee, are credited as PoolManager claims.
        assertEq(manager.balanceOf(seller, currency1.toId()) - before, 20 * (1_000_000_000 - _fee(1_000_000_000)));
        // The vault holds the 20 quote fees and the 40 matched orders' bids.
        assertEq(manager.balanceOf(address(hook.feeVault()), currency1.toId()), 20 * _fee(1_000_000_000) + 40 * 100_000);
        assertEq(hook.asyncOrder(poolId, _orderIdFor(blocker, true, bad.salt)), 2e15 - 1);
        (bool hasAsk, uint128 price, bytes32 head,) = hook.bestOrder(poolId, false);
        assertTrue(hasAsk);
        // The blocker's ask is 0.00005% above the honest asks: the same tick.
        assertEq(price, AsyncFiller._priceKey(false, true, 1e18, 1_000_000_000));
        assertEq(head, _orderIdFor(blocker, true, bad.salt));
        (bool hasBid,,,) = hook.bestOrder(poolId, true);
        assertFalse(hasBid);
        vm.prank(blocker);
        router.cancelOrder(bad);
        (hasAsk,,,) = hook.bestOrder(poolId, false);
        assertFalse(hasAsk);
    }

    function test_incomingSellSkipsHigherFeeNoncrossingBuy() public {
        // Both bids have key 1e9; the higher-fee buyer wants too much asset.
        AsyncOrder memory bad = submit(blocker, false, 1_000_000_001, 1e18 + 1, 100_001);
        AsyncOrder memory good = submit(buyer, false, 1_000_000_001, 1e18, 100_000);
        submit(seller, true, 1e18, 1_000_000_001, 100_000);
        assertEq(hook.asyncOrder(poolId, _orderIdFor(buyer, false, good.salt)), 0);
        assertEq(hook.asyncOrder(poolId, _orderIdFor(blocker, false, bad.salt)), 1_000_000_001);
    }

    function test_higherBidOnCrossingOrderCanBypassBlocker() public {
        submit(blocker, true, 2e15 - 1, 2_000_000, 100_001);
        AsyncOrder memory good = submit(seller, true, 1e18, 1_000_000_000, 100_002);
        submit(buyer, false, 1_000_000_000, 1e18, 100_000);
        assertEq(hook.asyncOrder(poolId, _orderIdFor(seller, true, good.salt)), 0);
    }

    /// Audit 2026-10-23 finding 1: asks of 10,100 and 10,800 USDC for 1e27 asset units shared WAD key
    /// 10, so the worse, older, higher-bid ask filled first. Their ticks differ, so price comes first.
    function test_worsePriceCannotJumpAheadWithBidOrAge() public {
        topUp(blocker, 1e27);
        topUp(seller, 1e27);
        topUp(buyer, 1e27);
        AsyncOrder memory worse = submit(blocker, true, 1e27, 10_800e6, 110_000);
        AsyncOrder memory better = submit(seller, true, 1e27, 10_100e6, 100_000);
        assertLt(
            AsyncFiller._priceKey(false, true, 1e27, 10_100e6),
            AsyncFiller._priceKey(false, true, 1e27, 10_800e6),
            "distinct levels"
        );
        (,, bytes32 head,) = hook.bestOrder(poolId, false);
        assertEq(head, _orderIdFor(seller, true, better.salt), "the cheaper ask is first");

        AsyncOrder memory bid = submit(buyer, false, 10_800e6, 1e27, 100_000);
        assertEq(hook.asyncOrder(poolId, _orderIdFor(seller, true, better.salt)), 0, "cheaper ask filled");
        assertEq(hook.asyncOrder(poolId, _orderIdFor(blocker, true, worse.salt)), 1e27, "worse ask untouched");
        assertEq(manager.balanceOf(buyer, currency0.toId()), 1e27 - _fee(1e27), "buyer received the asset");
        assertEq(manager.balanceOf(address(hook.feeVault()), currency0.toId()), _fee(1e27), "vault got the asset fee");
        assertEq(hook.asyncOrder(poolId, _orderIdFor(buyer, false, bid.salt)), 700e6, "700 USDC unspent");
    }

    function test_sameTickExactPriceBeatsHigherFeeAndEarlierAge() public {
        AsyncOrder memory worse = submit(blocker, true, 1e18, 1_000_000_001, 110_000);
        AsyncOrder memory better = submit(seller, true, 1e18, 1_000_000_000, 100_000);
        assertEq(
            AsyncFiller._priceKey(false, true, 1e18, 1_000_000_001),
            AsyncFiller._priceKey(false, true, 1e18, 1_000_000_000)
        );
        submit(buyer, false, 1_000_000_001, 1e18, 100_000);
        assertEq(hook.asyncOrder(poolId, _orderIdFor(seller, true, better.salt)), 0);
        assertEq(hook.asyncOrder(poolId, _orderIdFor(blocker, true, worse.salt)), 1e18);
        assertEq(manager.balanceOf(seller, currency1.toId()), 1_000_000_000 - _fee(1_000_000_000));
        assertEq(manager.balanceOf(address(hook.feeVault()), currency1.toId()), _fee(1_000_000_000) + 2 * 100_000);
    }

    function test_sameTickBestBidBeatsHigherFeeAndEarlierAge() public {
        AsyncOrder memory worse = submit(blocker, false, 1_000_000_000, 1e18, 110_000);
        AsyncOrder memory better = submit(buyer, false, 1_000_000_001, 1e18, 100_000);
        submit(seller, true, 1e18, 1_000_000_000, 100_000);
        assertEq(hook.asyncOrder(poolId, _orderIdFor(buyer, false, better.salt)), 0);
        assertEq(hook.asyncOrder(poolId, _orderIdFor(blocker, false, worse.salt)), 1_000_000_000);
        assertEq(manager.balanceOf(seller, currency1.toId()), 1_000_000_001 - _fee(1_000_000_001));
        assertEq(manager.balanceOf(address(hook.feeVault()), currency1.toId()), _fee(1_000_000_001) + 2 * 100_000);
    }
}
