// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {HookUnlockBase} from "./HookUnlockBase.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {AsyncMatching} from "@async-swap/libraries/AsyncMatching.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {MockERC20} from "../utils/MockERC20.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean`.
///         The function only accepts `msg.sender == address(this)`; the tests reach it either through
///         the real self-call (`Router.fillFromPoolLiquidity` → `tryFillOrderFromPoolLiquidity`) or by
///         pranking the hook address inside a PoolManager unlock.
contract AsyncSwapFillOrderFromPoolLiquidityFormalTest is HookUnlockBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function _selfFill(AsyncOrder memory o, bytes32 id) internal view returns (Call[] memory) {
        return _one(_cAs(address(hook), address(hook), abi.encodeCall(hook.fillOrderFromPoolLiquidity, (o, id, 0))));
    }

    function _inputFeeGrowth(bool zeroForOne) internal view returns (uint256) {
        (uint256 g0, uint256 g1) = manager.getFeeGrowthGlobals(poolId);
        return zeroForOne ? g0 : g1;
    }

    function _lpFee() internal view returns (uint24 fee) {
        (,,, fee) = manager.getSlot0(poolId);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean:120 — any caller other than the contract itself reverts NotSelf.
    function testFuzz_fillOrderFromPoolLiquidity_notSelf(address caller, AsyncOrder memory o, bytes32 id) public {
        vm.assume(caller != address(hook));
        vm.prank(caller);
        vm.expectRevert(AsyncSwap.NotSelf.selector);
        hook.fillOrderFromPoolLiquidity(o, id, 0);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean:126 — a self-call on an id with no stored input reverts (OrderNotFound; the model renders the library error as "").
    function testFuzz_fillOrderFromPoolLiquidity_notFound(bytes32 id, address owner_, bool zeroForOne) public {
        _placeOrder(alice, true, 1 ether, 1 ether); // some unrelated live order
        _addPoolLiquidity(1e24);
        AsyncOrder memory o = _orderFromMaker(owner_, zeroForOne, 1 ether, 1);
        vm.assume(hook.asyncOrder(poolId, id) == 0);
        vm.expectRevert(AsyncFiller.OrderNotFound.selector);
        _run(_selfFill(o, id));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean:133 — a self-call on a live order in a pool with zero active liquidity reverts NoActiveLiquidity.
    function testFuzz_fillOrderFromPoolLiquidity_noLiquidity(uint256 amountIn, bool zeroForOne, uint256 amountOutMin)
        public
    {
        amountIn = bound(amountIn, 1, 50 ether);
        amountOutMin = bound(amountOutMin, 1, 1e30);
        (AsyncOrder memory o, bytes32 id) = _placeOrder(alice, zeroForOne, amountIn, amountOutMin);
        assertEq(manager.getLiquidity(poolId), 0);
        vm.expectRevert(AsyncMatching.NoActiveLiquidity.selector);
        _run(_selfFill(o, id));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean:175 — a successful pool swap: liquidity != 0, the escrowed input claims (amtIn) leave the hook (0.01% to the FeeVault, the rest burned and swapped), the swap runs at LP fee 200 (was 3000) and the previous fee is restored, the full input is consumed and out >= amtOutMin. (semantics changed by the 0.02% trade fee; Lean statement needs updating)
    function testFuzz_swapAgainstPool_ok(uint256 amountIn, uint256 limitBps, bool zeroForOne) public {
        amountIn = bound(amountIn, 1e6, 10 ether);
        uint256 amountOutMin = amountIn * bound(limitBps, 1, 9_900) / 10_000 + 1;
        (AsyncOrder memory o, bytes32 id) = _placeOrder(alice, zeroForOne, amountIn, amountOutMin);
        _addPoolLiquidity(1e24);
        Currency inC = zeroForOne ? currency0 : currency1;
        MockERC20 out = zeroForOne ? token1 : token0;
        uint24 feeBefore = _lpFee();
        uint256 gBefore = _inputFeeGrowth(zeroForOne);
        uint256 claimsBefore = _claims(address(hook), inC);
        // The FeeVault's input claims expected after the fill: + the protocol's 0.01% of the input, rounded up.
        uint256 vaultWant = _claims(address(hook.feeVault()), inC) + (amountIn + 9_999) / 10_000;
        uint256 makerBefore = out.balanceOf(alice);
        _run(_selfFill(o, id));
        assertGt(manager.getLiquidity(poolId), 0);
        assertEq(
            claimsBefore - _claims(address(hook), inC),
            amountIn + (zeroForOne ? 0 : 100_000),
            "input and bid claims leave the hook"
        );
        assertEq(
            _claims(address(hook.feeVault()), inC),
            vaultWant + (zeroForOne ? 0 : 100_000),
            "protocol 0.01% (and bid) to the FeeVault"
        );
        assertEq(_lpFee(), feeBefore, "LP fee restored");
        assertEq(feeBefore, 0, "pool fee was 0 before");
        assertGt(_inputFeeGrowth(zeroForOne) - gBefore, 0, "a non-zero (200) LP fee was charged on the input");
        assertGe(out.balanceOf(alice) - makerBefore, amountOutMin, "out >= amountOutMin");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean:261 — a success (real self-call via tryFill) was on a stored order, produced out >= stored amountOutMin, paid it to the stored maker, and cleared the order; otherwise nothing changed.
    function testFuzz_fillOrderFromPoolLiquidity_ok(uint256 amountIn, uint256 limitBps, bool zeroForOne) public {
        amountIn = bound(amountIn, 1, 5_000 ether);
        uint256 amountOutMin = amountIn * bound(limitBps, 1, 20_000) / 10_000 + 1;
        topUp(alice, 5_000 ether);
        (AsyncOrder memory o, bytes32 id) = _placeOrder(alice, zeroForOne, amountIn, amountOutMin);
        _addPoolLiquidity(1e24);
        MockERC20 out = zeroForOne ? token1 : token0;
        uint256 makerBefore = out.balanceOf(alice);
        vm.prank(bob);
        router.fillFromPoolLiquidity(o);
        if (hook.asyncOrder(poolId, id) == 0) {
            assertGe(out.balanceOf(alice) - makerBefore, amountOutMin, "out >= amountOutMin to stored maker");
        } else {
            assertEq(out.balanceOf(alice), makerBefore, "failed fill paid nothing");
            assertEq(hook.asyncOrder(poolId, id), amountIn, "order rests");
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean:293 — full fill paid to the stored maker orders[id].owner (not the calldata owner): exact stored amountIn burned, LP fee restored, out >= amountOutMin is exactly what left the PoolManager, order cleared, escrowed bid settled.
    function testFuzz_fillOrderFromPoolLiquidity_ok_full(
        uint256 amountIn,
        address fakeOwner,
        bool zeroForOne,
        bool withBid
    ) public {
        amountIn = bound(amountIn, 1e6, 10 ether);
        uint256 bid = withBid ? 1e6 : 100_000;
        AsyncOrder memory o = _orderFromMaker(alice, zeroForOne, amountIn, 1);
        if (withBid) {
            o.priorityFee = bid;
        }
        vm.prank(alice);
        router.swap(
            o,
            abi.encode(
                AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 1, priorityFee: bid})
            )
        );
        o.salt = _saltOf(alice, amountIn, 1, bid);
        bytes32 id = _idOf(o);
        _addPoolLiquidity(1e24);
        vm.assume(fakeOwner != alice);
        o.owner = fakeOwner; // the payout must follow the stored owner
        o.amountIn = 0;
        uint256[5] memory b = _fullSnap(zeroForOne, fakeOwner);
        _run(_selfFill(o, id));
        uint256[5] memory a = _fullSnap(zeroForOne, fakeOwner);
        uint256 paid = a[0] - b[0];
        assertGe(paid, 1, "out >= amountOutMin");
        assertEq(b[2] - a[2], paid, "out is what left the PoolManager");
        if (fakeOwner != address(manager)) assertEq(a[1], b[1], "calldata owner not paid");
        if (zeroForOne) assertEq(b[3] - a[3], amountIn, "stored amountIn burned");
        assertEq(b[4] - a[4] - (zeroForOne ? 0 : amountIn), bid, "paid bid settled (donated)");
        assertEq(_lpFee(), 0, "fee restored");
        assertEq(hook.asyncOrder(poolId, id), 0, "orders[id] := default");
    }

    function _fullSnap(bool zeroForOne, address fakeOwner) internal view returns (uint256[5] memory r) {
        MockERC20 out = zeroForOne ? token1 : token0;
        r[0] = out.balanceOf(alice);
        r[1] = out.balanceOf(fakeOwner);
        r[2] = out.balanceOf(address(manager));
        r[3] = _claims(address(hook), zeroForOne ? currency0 : currency1);
        r[4] = _claims(address(hook), currency1);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean:362 — once orders[id] is cleared, a self-call fill of the same id reverts.
    function testFuzz_fillOrderFromPoolLiquidity_reentry_reverts(uint256 amountIn, bool sameUnlock) public {
        amountIn = bound(amountIn, 1e6, 10 ether);
        (AsyncOrder memory o, bytes32 id) = _placeOrder(alice, true, amountIn, 1);
        _addPoolLiquidity(1e24);
        if (sameUnlock) {
            vm.expectRevert(AsyncFiller.OrderNotFound.selector);
            _run(_cat(_selfFill(o, id), _selfFill(o, id)));
        } else {
            _run(_selfFill(o, id));
            vm.expectRevert(AsyncFiller.OrderNotFound.selector);
            _run(_selfFill(o, id));
        }
    }
}
