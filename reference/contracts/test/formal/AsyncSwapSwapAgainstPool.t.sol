// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {HookUnlockBase} from "./HookUnlockBase.sol";
import {AsyncMatching} from "@async-swap/libraries/AsyncMatching.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {IPoolManager, SwapParams} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {MockERC20} from "../utils/MockERC20.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapSwapAgainstPool.lean`. `_swapAgainstPool` is
///         private; `fillFromPoolLiquidity` calls it first, reached through `AsyncSwap.fillOrderFromPoolLiquidity`
///         pranked as the hook itself inside a PoolManager unlock (the real self-call path catches the
///         revert, so the reason would be lost). The external calls it makes are checked with
///         `vm.expectCall` on their exact calldata; `swapAgainstPool_spec` replaces the PoolManager's
///         `burn` / `swap` / `take` with mocks so the swap delta can be any value.
contract AsyncSwapSwapAgainstPoolFormalTest is HookUnlockBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function _selfFill(AsyncOrder memory o, bytes32 id) internal view returns (Call[] memory) {
        return _one(_cAs(address(hook), address(hook), abi.encodeCall(hook.fillOrderFromPoolLiquidity, (o, id, 0))));
    }

    function selfFillExt(AsyncOrder memory o, bytes32 id) external {
        _run(_selfFill(o, id));
    }

    function _lpFee() internal view returns (uint24 fee) {
        (,,, fee) = manager.getSlot0(poolId);
    }

    function _setLpFee(uint24 fee) internal {
        vm.prank(address(hook));
        manager.updateDynamicLPFee(key, fee);
    }

    /// @dev The protocol's 0.01% of the order's input (rounded up), moved to the FeeVault before the swap.
    function _protocolFee(uint256 amountIn) internal pure returns (uint256) {
        return (amountIn + 9_999) / 10_000;
    }

    function _limit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _order(uint256 amountIn, uint256 amountOutMin, bool zeroForOne)
        internal
        returns (AsyncOrder memory o, bytes32 id)
    {
        topUp(alice, amountIn);
        (o, id) = _placeOrder(alice, zeroForOne, amountIn, amountOutMin);
        assertEq(hook.asyncOrder(poolId, id), amountIn, "order rests (no pool liquidity at placement)");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSwapAgainstPool.lean:33 — zero active liquidity: reverts NoActiveLiquidity before any external call (no burn).
    function testFuzz_swapAgainstPool_noLiquidity(uint256 amountIn, uint256 amountOutMin, bool zeroForOne) public {
        amountIn = bound(amountIn, 1, 1e30);
        amountOutMin = bound(amountOutMin, 1, 1e30);
        (AsyncOrder memory o, bytes32 id) = _order(amountIn, amountOutMin, zeroForOne);
        assertEq(manager.getLiquidity(poolId), 0);
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManager.burn.selector), 0);
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManager.swap.selector), 0);
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManager.updateDynamicLPFee.selector), 0);
        vm.expectRevert(AsyncMatching.NoActiveLiquidity.selector);
        _run(_selfFill(o, id));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSwapAgainstPool.lean:45 — success: liquidity != 0; burn(hook, input, swapIn); LP fee 200 (was 3000); one exact-input swap(key, (zfo, -swapIn, MIN+1 | MAX-1), ""); fee restored to the slot0 fee; amountIn < 2^127, full input, out = uint128(outputDelta) > 0 and >= amountOutMin. swapIn = amountIn - ceil(amountIn / 10_000), the rest going to the FeeVault. (semantics changed by the 0.02% trade fee; Lean statement needs updating)
    function testFuzz_swapAgainstPool_success(uint256 amountIn, bool zeroForOne, uint24 prevFee) public {
        amountIn = bound(amountIn, 1e6, 10 ether);
        prevFee = uint24(bound(prevFee, 0, 1_000_000));
        (AsyncOrder memory o, bytes32 id) = _order(amountIn, 1, zeroForOne);
        _addPoolLiquidity(1e24);
        _setLpFee(prevFee);
        Currency input = zeroForOne ? currency0 : currency1;
        MockERC20 out = zeroForOne ? token1 : token0;
        uint256 swapIn = amountIn - _protocolFee(amountIn);
        vm.expectCall(address(manager), abi.encodeCall(IPoolManager.burn, (address(hook), input.toId(), swapIn)));
        vm.expectCall(address(manager), abi.encodeCall(IPoolManager.updateDynamicLPFee, (key, uint24(200))));
        vm.expectCall(
            address(manager),
            abi.encodeCall(
                IPoolManager.swap, (key, SwapParams(zeroForOne, -int256(swapIn), _limit(zeroForOne)), bytes(""))
            ),
            1
        );
        vm.expectCall(address(manager), abi.encodeCall(IPoolManager.updateDynamicLPFee, (key, prevFee)));
        uint256 claimsBefore = _claims(address(hook), input);
        uint256 vaultBefore = _claims(address(hook.feeVault()), input);
        uint256 makerBefore = out.balanceOf(alice);
        _run(_selfFill(o, id));
        assertEq(
            _claims(address(hook.feeVault()), input) - vaultBefore,
            _protocolFee(amountIn) + (zeroForOne ? 0 : 100_000),
            "protocol fee (and bid) to the FeeVault"
        );
        uint256 got = out.balanceOf(alice) - makerBefore;
        assertGt(manager.getLiquidity(poolId), 0, "liquidity != 0");
        assertEq(
            claimsBefore - _claims(address(hook), input),
            amountIn + (zeroForOne ? 0 : 100_000),
            "input (swapped or to the vault) and bid claims leave the hook"
        );
        assertGt(got, 0, "outputDelta > 0");
        assertGe(got, 1, "out >= amountOutMin");
        assertEq(_lpFee(), prevFee, "fee restored to the slot0 fee");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSwapAgainstPool.lean:68 — every successful run had non-zero liquidity and produced out >= amountOutMin.
    function testFuzz_swapAgainstPool_ok_liquidity_min(
        uint256 amountIn,
        uint256 amountOutMin,
        bool zeroForOne,
        bool withLiquidity
    ) public {
        amountIn = bound(amountIn, 1, 1e24);
        amountOutMin = bound(amountOutMin, 1, 2 * amountIn);
        (AsyncOrder memory o, bytes32 id) = _order(amountIn, amountOutMin, zeroForOne);
        if (withLiquidity) _addPoolLiquidity(1e24);
        MockERC20 out = zeroForOne ? token1 : token0;
        uint256 makerBefore = out.balanceOf(alice);
        try this.selfFillExt(o, id) {
            assertGt(manager.getLiquidity(poolId), 0, "liquidity != 0");
            assertGe(out.balanceOf(alice) - makerBefore, amountOutMin, "out >= amountOutMin");
        } catch {}
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSwapAgainstPool.lean:79 — amountIn >= 2^127 never succeeds (SafeCast.toInt128); the stored amountIn is written with vm.store.
    function testFuzz_swapAgainstPool_amountIn_lt(uint256 amountIn, bool zeroForOne, bool withLiquidity) public {
        (AsyncOrder memory o, bytes32 id) = _order(1 ether, 1, zeroForOne);
        if (withLiquidity) _addPoolLiquidity(1e24);
        amountIn = bound(amountIn, 2 ** 127, type(uint256).max);
        vm.store(address(hook), bytes32(_orderSlot(poolId, id) + 1), bytes32(amountIn));
        vm.expectRevert();
        _run(_selfFill(o, id));
    }

    function _mockPool(BalanceDelta delta) internal {
        vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.burn.selector), "");
        // The bid is burned from hook claims (mocked) and minted to the FeeVault; mock both legs.
        vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.mint.selector), "");
        vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.take.selector), "");
        vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.swap.selector), abi.encode(delta));
    }

    function _expectOkCalls(bool zeroForOne, uint256 swapIn, uint24 prevFee, uint256 out) internal {
        SwapParams memory p = SwapParams(zeroForOne, -int256(swapIn), _limit(zeroForOne));
        vm.expectCall(address(manager), abi.encodeCall(IPoolManager.swap, (key, p, bytes(""))), 1);
        vm.expectCall(address(manager), abi.encodeCall(IPoolManager.updateDynamicLPFee, (key, uint24(200))));
        vm.expectCall(address(manager), abi.encodeCall(IPoolManager.updateDynamicLPFee, (key, prevFee)));
        // the returned out = uint128(outputDelta) is what fillFromPoolLiquidity pays the maker
        Currency output = zeroForOne ? currency1 : currency0;
        vm.expectCall(address(manager), abi.encodeCall(IPoolManager.take, (output, alice, out)));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSwapAgainstPool.lean:92 — after the external calls succeed (amountIn < 2^127): PartialLiquidityFill unless inputDelta = -swapIn (swapIn = amountIn less the 0.01% protocol fee (semantics changed by the 0.02% trade fee; Lean statement needs updating)), then LimitPriceNotMet unless 0 < outputDelta and uint128(outputDelta) >= amountOutMin, else returns uint128(outputDelta). burn/swap/take are mocked; the swap returns a fuzzed delta.
    function testFuzz_swapAgainstPool_spec(
        uint256 amountIn,
        uint256 amountOutMin,
        bool zeroForOne,
        int128 inDelta,
        int128 outDelta,
        uint8 sel,
        uint24 prevFee
    ) public {
        amountIn = bound(amountIn, 1, 1e30);
        amountOutMin = bound(amountOutMin, 1, 2 ** 130);
        prevFee = uint24(bound(prevFee, 0, 1_000_000));
        (AsyncOrder memory o, bytes32 id) = _order(amountIn, amountOutMin, zeroForOne);
        _addPoolLiquidity(1e24);
        _setLpFee(prevFee);
        uint256 swapIn = amountIn - _protocolFee(amountIn);
        if (sel % 3 != 0) inDelta = -int128(int256(swapIn)); // full fill
        if (sel % 3 == 2 && amountOutMin < uint128(type(int128).max)) {
            outDelta = int128(int256(bound(uint256(uint128(outDelta)), amountOutMin, uint128(type(int128).max))));
        }
        _mockPool(zeroForOne ? toBalanceDelta(inDelta, outDelta) : toBalanceDelta(outDelta, inDelta));
        if (inDelta != -int128(int256(swapIn))) {
            vm.expectRevert(AsyncMatching.PartialLiquidityFill.selector);
            _run(_selfFill(o, id));
        } else if (outDelta <= 0 || uint256(uint128(outDelta)) < amountOutMin) {
            vm.expectRevert(AsyncMatching.LimitPriceNotMet.selector);
            _run(_selfFill(o, id));
        } else {
            _expectOkCalls(zeroForOne, swapIn, prevFee, uint256(uint128(outDelta)));
            _run(_selfFill(o, id));
            assertEq(hook.asyncOrder(poolId, id), 0, "filled");
            assertEq(_lpFee(), prevFee, "fee restored");
        }
    }
}
