// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../../SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {MockERC20} from "../../utils/MockERC20.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/// @notice Regression for M-02 (audit/lsp_security_review_2026-11-01.md). A pool-first attempt used to be all-or-nothing
///         and capped at the best resting level: an ask placed just inside the buy's pool path made it revert, so the
///         buy matched the ask at a price worse than the pool's average fill. The pool now fills up to the ask's level
///         and only the rest matches the ask, so the front-run neither costs the maker nor pays the attacker.
contract PoolFirstFrontRunPoc is SetupHook {
    using StateLibrary for IPoolManager;

    address alice = makeAddr("alice"); // maker (buyer)
    address attacker = makeAddr("attacker");

    uint256 constant BUY_IN = 1000 ether; // token1 (numeraire)
    uint256 constant BUY_MIN = 990 ether; // token0
    uint256 constant ASK_IN = 1100 ether; // attacker sells token0
    uint256 constant ASK_PRICE_BPS = 10_018; // 1.0018 token1 per token0

    function setUp() public override {
        super.setUp();
        topUp(alice, 10_000 ether);
        topUp(attacker, 10_000 ether);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);
        token0.approve(address(lp), type(uint256).max);
        token1.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e24, salt: 0}), ""
        );
    }

    function _order(address who, bool zeroForOne, uint256 amountIn, uint256 amountOutMin)
        internal
        view
        returns (AsyncOrder memory)
    {
        return AsyncOrder({
            key: key,
            owner: who,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            priorityFee: 0,
            sqrtPrice: 2 ** 96,
            salt: keccak256(abi.encode(block.timestamp, block.number, address(manager), who, amountIn, amountOutMin, 0))
        });
    }

    function _submit(AsyncOrder memory o) internal {
        MockERC20 input = o.zeroForOne ? token0 : token1;
        vm.startPrank(o.owner);
        input.approve(address(router), type(uint256).max);
        router.swap(o, abi.encode(AsyncSwap.UserParams(o.owner, address(router), o.amountOutMin, 0)));
        vm.stopPrank();
    }

    function _bal0(address who) internal view returns (uint256) {
        return token0.balanceOf(who) + manager.balanceOf(who, currency0.toId());
    }

    function _bal1(address who) internal view returns (uint256) {
        return token1.balanceOf(who) + manager.balanceOf(who, currency1.toId());
    }

    function _aliceBuy() internal returns (uint256 got) {
        uint256 before = _bal0(alice);
        _submit(_order(alice, false, BUY_IN, BUY_MIN));
        got = _bal0(alice) - before;
    }

    /// Control: no resting ask. The buy fills entirely from the pool.
    function test_control_buyFillsFromPool() public {
        uint256 got = _aliceBuy();
        (, int24 tick,,) = manager.getSlot0(poolId);
        emit log_named_uint("pool-only: alice token0 received", got);
        emit log_named_int("pool tick after fill", tick);
        assertGt(got, BUY_MIN);
    }

    function test_frontRunAskNoLongerForcesWorseBookMatch() public {
        // Reference: what the pool alone would have given (snapshot/revert).
        uint256 snap = vm.snapshotState();
        uint256 poolOnly = _aliceBuy();
        vm.revertToState(snap);

        // Attacker front-runs with an ask at 1.0018, inside the buy's pool path (pool would end ~1.002).
        AsyncOrder memory ask = _order(attacker, true, ASK_IN, ASK_IN * ASK_PRICE_BPS / 10_000);
        uint256 atk0Before = _bal0(attacker);
        uint256 atk1Before = _bal1(attacker);
        _submit(ask);
        assertEq(hook.asyncOrder(poolId, _orderIdFor(attacker, true, ask.salt)), ASK_IN, "ask rests (pool below it)");

        uint256 got = _aliceBuy();
        emit log_named_uint("pool-only: alice token0 received", poolOnly);
        emit log_named_uint("attacked: alice token0 received", got);
        assertGe(got, poolOnly, "the maker does at least as well as the pool alone");

        // Attacker closes: cancel the ask remainder, then buy back token0 through the pool with the token1 earned.
        vm.prank(attacker);
        router.cancelOrder(_order(attacker, true, ASK_IN, ASK_IN * ASK_PRICE_BPS / 10_000));
        uint256 earned1 = _bal1(attacker) - atk1Before;
        uint256 sold0 = atk0Before - _bal0(attacker);
        emit log_named_uint("attacker token0 sold", sold0);
        emit log_named_uint("attacker token1 earned", earned1);
        _submit(_order(attacker, false, earned1, 1));
        int256 pnl0 = int256(_bal0(attacker)) - int256(atk0Before);
        int256 pnl1 = int256(_bal1(attacker)) - int256(atk1Before);
        emit log_named_int("attacker net token0 after buyback", pnl0);
        emit log_named_int("attacker net token1 after buyback", pnl1);
        assertEq(pnl1, 0, "every token1 earned was spent buying back");
        assertLt(pnl0, 0, "the round trip loses the attacker token0");
    }
}
