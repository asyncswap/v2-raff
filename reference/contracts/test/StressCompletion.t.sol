// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "./SetupHook.t.sol";
import {RouterClaimsTest} from "./RouterClaims.t.sol";
import {AsyncOrder} from "src/types/AsyncOrder.sol";
import {AsyncSwap} from "src/AsyncSwap.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

/// @dev Stateful contract stress, not independent-transaction gas or network throughput.
contract StressCompletionTest is SetupHook {
    using CurrencyLibrary for Currency;
    uint256 constant SIZE = 1 ether;
    address[32] makers;

    function setUp() public override {
        super.setUp();
        for (uint160 i; i < 32; ++i) {
            makers[i] = address(10000 + i);
            topUp(makers[i], 10000 ether);
            vm.prank(makers[i]);
            token0.approve(address(router), type(uint256).max);
        }
    }

    function submit(address maker, bool sell, uint256 amount, uint256 minimum)
        internal
        returns (AsyncOrder memory o, bytes32 id)
    {
        o = AsyncOrder(key, maker, sell, amount, minimum, 100_000, 2 ** 96, bytes32(0));
        vm.prank(maker);
        router.swap(o, abi.encode(AsyncSwap.UserParams(maker, address(router), minimum, 100_000)));
        o.salt = _expectedSalt(maker, amount, minimum);
        id = _orderIdFor(maker, sell, o.salt);
    }

    function emptyEscrow() internal view {
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0, "asset escrow leaked");
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0, "quote/bid escrow leaked");
    }

    function withdraw(address maker) internal {
        Currency[] memory currencies = new Currency[](2);
        currencies[0] = currency0;
        currencies[1] = currency1;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = manager.balanceOf(maker, currency0.toId());
        amounts[1] = manager.balanceOf(maker, currency1.toId());
        // Withdraw only nonzero claims: the Router deliberately rejects zero amounts.
        for (uint256 i; i < 2; ++i) {
            if (amounts[i] != 0) {
                Currency[] memory one = new Currency[](1);
                one[0] = currencies[i];
                uint256[] memory value = new uint256[](1);
                value[0] = amounts[i];
                uint256 beforeBalance = i == 0 ? token0.balanceOf(maker) : token1.balanceOf(maker);
                vm.startPrank(maker);
                manager.approve(address(router), one[0].toId(), value[0]);
                router.withdrawClaims(one, value);
                vm.stopPrank();
                assertEq(manager.balanceOf(maker, one[0].toId()), 0);
                assertEq(manager.allowance(maker, address(router), one[0].toId()), 0);
                assertEq(i == 0 ? token0.balanceOf(maker) : token1.balanceOf(maker), beforeBalance + value[0]);
            }
        }
    }

    function test_stress_deepCrossingBookBoundedContinuation() public {
        bytes32[] memory asks = new bytes32[](256);
        // Different sizes avoid equal-parameter salt collisions within a simulated block.
        for (uint256 i; i < 256; ++i) {
            (, asks[i]) = submit(makers[i % 32], true, SIZE + i, SIZE + i);
        }
        uint256 total = 256 * SIZE + 255 * 256 / 2;
        (, bytes32 bid) = submit(makers[0], false, total, total);
        for (uint256 i; i < 31; ++i) {
            router.matchBook(key, 8);
        }
        for (uint256 i; i < 256; ++i) {
            assertEq(hook.asyncOrder(poolId, asks[i]), 0);
        }
        assertEq(hook.asyncOrder(poolId, bid), 0);
        emptyEscrow();
        for (uint256 i; i < 32; ++i) {
            withdraw(makers[i]);
        }
    }

    function addLiquidity() internal {
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);
        token0.approve(address(lp), type(uint256).max);
        token1.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, 1e24, 0), "");
    }

    function test_stress_liquidityRetryAndAlternatingFills() public {
        AsyncOrder[] memory waiting = new AsyncOrder[](256);
        bytes32[] memory ids = new bytes32[](256);
        for (uint256 i; i < 256; ++i) {
            (waiting[i], ids[i]) = submit(makers[i % 32], true, SIZE + i, SIZE * 9 / 10);
            assertGt(hook.asyncOrder(poolId, ids[i]), 0, "no-liquidity order must rest");
        }
        addLiquidity();
        for (uint256 i; i < 256; ++i) {
            uint256 beforeBalance = token1.balanceOf(waiting[i].owner);
            router.fillFromPoolLiquidity(waiting[i]);
            assertEq(hook.asyncOrder(poolId, ids[i]), 0, "retry failed to fill");
            assertGe(token1.balanceOf(waiting[i].owner) - beforeBalance, waiting[i].amountOutMin);
        }
        for (uint256 i; i < 512; ++i) {
            vm.roll(block.number + 1);
            bool sell = i % 2 == 0;
            address maker = makers[i % 32];
            uint256 beforeOutput = sell ? token1.balanceOf(maker) : token0.balanceOf(maker);
            (, bytes32 id) = submit(maker, sell, SIZE, SIZE * 9 / 10);
            uint256 afterOutput = sell ? token1.balanceOf(maker) : token0.balanceOf(maker);
            // A sell also pays its bid in the output token; add that known debit back.
            assertGe(afterOutput + (sell ? 100_000 : 0) - beforeOutput, SIZE * 9 / 10);
            assertEq(hook.asyncOrder(poolId, id), 0, "automatic pool fill must close");
        }
        emptyEscrow();
    }

    function test_stress_sustainedMatchingAndWithdrawals() public {
        uint256 feeBefore0 = manager.balanceOf(address(hook.feeVault()), currency0.toId());
        uint256 feeBefore1 = manager.balanceOf(address(hook.feeVault()), currency1.toId());
        // Drain claims each round to expose cumulative drift. The extended run needs a higher test gas ceiling.
        uint256 rounds = vm.envOr("STRESS_ROUNDS", uint256(32));
        require(rounds > 0 && rounds <= 1024, "Invalid stress rounds");
        for (uint256 round; round < rounds; ++round) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 2);
            for (uint256 i; i < 16; ++i) {
                (, bytes32 ask) = submit(makers[i], true, SIZE, SIZE);
                (, bytes32 bid) = submit(makers[16 + i], false, SIZE, SIZE);
                assertEq(hook.asyncOrder(poolId, ask), 0);
                assertEq(hook.asyncOrder(poolId, bid), 0);
                assertEq(manager.balanceOf(makers[i], currency1.toId()), SIZE - SIZE / 5000);
                assertEq(manager.balanceOf(makers[16 + i], currency0.toId()), SIZE - SIZE / 5000);
            }
            emptyEscrow();
            for (uint256 i; i < 32; ++i) {
                withdraw(makers[i]);
            }
        }
        uint256 matches = rounds * 16;
        assertEq(manager.balanceOf(address(hook.feeVault()), currency0.toId()) - feeBefore0, matches * SIZE / 5000);
        assertEq(
            manager.balanceOf(address(hook.feeVault()), currency1.toId()) - feeBefore1,
            matches * (SIZE / 5000 + 200_000)
        );
    }
}

contract NativeWithdrawalStressTest is RouterClaimsTest {
    function test_stress_nativePartialWithdrawalAndDoubleSpend() public {
        for (uint256 i; i < 256; ++i) {
            vm.roll(block.number + 1);
            AsyncOrder memory o = _order(alice, true, 0.1 ether, 1 ether);
            vm.prank(alice);
            router.swap{value: 0.1 ether}(o, abi.encode(AsyncSwap.UserParams(alice, address(router), 1 ether, 100_000)));
            o = _withAssignedSalt(o);
            vm.startPrank(alice);
            router.cancelOrder(o);
            Currency[] memory currencies = new Currency[](1);
            currencies[0] = currency0;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 0.05 ether;
            for (uint256 j; j < 2; ++j) {
                manager.approve(address(router), 0, amounts[0]);
                uint256 beforeETH = alice.balance;
                router.withdrawClaims(currencies, amounts);
                assertEq(alice.balance, beforeETH + amounts[0]);
                assertEq(manager.allowance(alice, address(router), 0), 0);
                vm.expectRevert();
                router.withdrawClaims(currencies, amounts);
            }
            assertEq(manager.balanceOf(alice, 0), 0);
            vm.stopPrank();
        }
    }
}
