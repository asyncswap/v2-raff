// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "./SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice Every fee the hook moves to the FeeVault or to LPs is visible in the logs: indexers must not
///         have to recompute fees from gross amounts.
contract FeeEventsTest is SetupHook {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    bytes32 constant FEE_ACCRUED = keccak256("OrderFeeAccrued(bytes32,bytes32,address,uint256)");
    bytes32 constant MATCHED = keccak256("AsyncOrdersMatched(bytes32,bytes32,bytes32,uint256,uint256)");
    bytes32 constant DYNAMIC_FEE = keccak256("DynamicFeeCharged(bytes32,bytes32,address,uint256,uint256,int24)");
    bytes32 constant PRICE_OBSERVED = keccak256("PoolPriceObserved(bytes32,bytes32,int24,int24,int24,uint64)");

    function setUp() public override {
        super.setUp();
        topUp(alice, 10_000 ether);
        topUp(bob, 10_000 ether);
    }

    function _submit(address maker, bool zeroForOne, uint256 amountIn, uint256 amountOutMin) internal {
        AsyncOrder memory order =
            AsyncOrder(key, maker, zeroForOne, amountIn, amountOutMin, 100_000, 2 ** 96, bytes32(0));
        MockERC20 input = zeroForOne ? token0 : token1;
        vm.startPrank(maker);
        input.approve(address(router), amountIn + 100_000);
        router.swap(order, abi.encode(AsyncSwap.UserParams(maker, address(router), amountOutMin, 100_000)));
        vm.stopPrank();
    }

    /// A book match takes 0.02% from each side's proceeds; both fees are logged against their orders.
    function test_bookMatchLogsBothTradeFees() public {
        _submit(alice, true, 10 ether, 10 ether); // ask: 10 asset for 10 USDC
        vm.recordLogs();
        _submit(bob, false, 10 ether, 10 ether); // crossing bid
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sellId;
        bytes32 buyId;
        uint256 assetAmount;
        uint256 quoteAmount;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == MATCHED) {
                (sellId, buyId) = (logs[i].topics[2], logs[i].topics[3]);
                (assetAmount, quoteAmount) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        assertGt(assetAmount, 0, "the orders matched");
        // The buyer's fee is in the asset (currency0), the seller's in USDC (currency1).
        assertTrue(
            _feeLogged(logs, buyId, address(token0), AsyncFiller.tradeFee(assetAmount)), "buyer's asset fee logged"
        );
        assertTrue(
            _feeLogged(logs, sellId, address(token1), AsyncFiller.tradeFee(quoteAmount)), "seller's USDC fee logged"
        );
    }

    /// A pool fill that moves the price back pays the dynamic fee; its split is logged.
    function test_dynamicFeeIsLogged() public {
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);
        token0.approve(address(lp), type(uint256).max);
        token1.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(key, ModifyLiquidityParams(-60, 60, 1e24, 0), "");

        _submit(alice, true, 2_000 ether, 1_900 ether); // moves the price down, sets the reference
        address vault = address(hook.feeVault());
        uint256 vaultBefore = manager.balanceOf(vault, currency0.toId());
        vm.recordLogs();
        _submit(bob, false, 1_000 ether, 1); // moves it back
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool found;
        bool priceObserved;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == DYNAMIC_FEE) {
                found = true;
                assertEq(address(uint160(uint256(logs[i].topics[3]))), address(token0), "fee currency is the output");
                (uint256 toLps, uint256 toVault, int24 refTick) = abi.decode(logs[i].data, (uint256, uint256, int24));
                assertGt(toLps, 0, "LP share logged");
                assertEq(toVault, manager.balanceOf(vault, currency0.toId()) - vaultBefore, "vault share matches");
                assertEq(refTick, 0, "reference is the tick before Alice's sell");
            }
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == PRICE_OBSERVED) {
                priceObserved = true;
                (int24 tickBefore, int24 tickAfter, int24 refTick, uint64 observedBlock) =
                    abi.decode(logs[i].data, (int24, int24, int24, uint64));
                assertLt(tickBefore, refTick, "backrun starts below the reference tick");
                assertGt(tickAfter, tickBefore, "backrun moves the tick toward the reference");
                assertEq(refTick, 0, "price log includes the reference tick");
                assertEq(observedBlock, uint64(block.number), "price log includes its block");
            }
        }
        assertTrue(found, "DynamicFeeCharged emitted");
        assertTrue(priceObserved, "PoolPriceObserved emitted");
    }

    function _feeLogged(Vm.Log[] memory logs, bytes32 id, address currency, uint256 amount)
        internal
        view
        returns (bool)
    {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (
                l.emitter == address(hook) && l.topics[0] == FEE_ACCRUED && l.topics[1] == PoolId.unwrap(poolId)
                    && l.topics[2] == id && address(uint160(uint256(l.topics[3]))) == currency
                    && abi.decode(l.data, (uint256)) == amount
            ) return true;
        }
        return false;
    }

    /// A filler fill logs both trade fees, and a pool fill its 0.01% protocol fee, each with the pool id.
    function test_fillerAndPoolFillFeesCarryThePoolId() public {
        vm.recordLogs();
        _submit(alice, true, 10 ether, 10 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 id = logs[_find(
                logs, keccak256("AsyncOrderCreated(bytes32,bytes32,address,bool,uint256,uint256,bytes32)")
            )].topics[2];
        AsyncOrder memory order = AsyncOrder(
            key, alice, true, 10 ether, 10 ether, 100_000, 2 ** 96, _expectedSalt(alice, 10 ether, 10 ether)
        );
        address filler = makeAddr("filler");
        topUp(filler, 100 ether);
        vm.startPrank(filler);
        token1.approve(address(router), type(uint256).max);
        vm.recordLogs();
        router.fillOrder(order, type(uint256).max, "");
        vm.stopPrank();
        logs = vm.getRecordedLogs();
        assertTrue(_feeLogged(logs, id, address(token1), AsyncFiller.tradeFee(10 ether)), "maker's fee logged");
        assertTrue(_feeLogged(logs, id, address(token0), AsyncFiller.tradeFee(10 ether)), "filler's fee logged");
    }

    function _find(Vm.Log[] memory logs, bytes32 topic) internal view returns (uint256) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == topic) return i;
        }
        revert("event not found");
    }
}
