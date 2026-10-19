// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Constants} from "v4-core-test/utils/Constants.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {Huff} from "./utils/Huff.sol";
import {IAsyncSwap} from "./utils/IAsyncSwap.sol";
import {AsyncOrder, AsyncOrderLibrary} from "./reference/AsyncOrder.sol";
import {AsyncFiller} from "./utils/IAsyncSwap.sol";
import {ProtocolFee} from "./reference/ProtocolFee.sol";

/// @dev The numeraire on either side of a pool. The Lean model fixes it as currency1; these tests run the same
///      flows on `flipKey` / `flipPrioKey`, where it is currency0, so a buy is `zeroForOne` and bids are
///      escrowed, donated and forfeited in currency0.
contract NumeraireTest is BaseTest {
    using AsyncOrderLibrary for AsyncOrder;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function _wrappedInitError(bytes4 hookError) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeInitialize.selector,
            abi.encodeWithSelector(hookError),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// Buy: spend `amountIn` of the numeraire (currency0 here) for at least `amountOutMin` of `other`.
    function _flipBuy(PoolKey memory k, address owner, uint256 amountIn, uint256 amountOutMin, uint256 fee)
        internal
        view
        returns (AsyncOrder memory)
    {
        return _order(k, owner, true, amountIn, amountOutMin, fee, bytes32(uint256(vm.getNonce(owner) + 1)));
    }

    /// Sell: spend `amountIn` of `other` (currency1 here) for at least `amountOutMin` of the numeraire.
    function _flipSell(PoolKey memory k, address owner, uint256 amountIn, uint256 amountOutMin, uint256 fee)
        internal
        view
        returns (AsyncOrder memory)
    {
        return _order(k, owner, false, amountIn, amountOutMin, fee, bytes32(uint256(vm.getNonce(owner) + 1)));
    }

    function test_numeraireIsConfigured() public view {
        assertEq(Currency.unwrap(hook.numeraire()), Currency.unwrap(usdc));
        assertEq(Currency.unwrap(flipKey.currency0), Currency.unwrap(usdc));
        assertEq(Currency.unwrap(key.currency1), Currency.unwrap(usdc));
    }

    function test_init_requiresNumeraire() public {
        vm.expectRevert(_wrappedInitError(IAsyncSwap.NumeraireRequired.selector));
        initPool(currency0, other, IHooks(hook), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, Constants.SQRT_PRICE_1_1);
    }

    /// A static fee tier would let one pair open a separate book per tier; only the dynamic-fee flag is admitted.
    function test_init_requiresDynamicFee() public {
        uint24[3] memory tiers = [uint24(500), 3000, 10000];
        for (uint256 i = 0; i < tiers.length; i++) {
            vm.expectRevert(_wrappedInitError(IAsyncSwap.DynamicFeeRequired.selector));
            initPool(usdc, other, IHooks(hook), tiers[i], 60, Constants.SQRT_PRICE_1_1);
        }
    }

    /// A dynamic-fee pool starts with a zero LP fee; a liquidity fill charges LPs 0.30%.
    function test_liquidityFill_setsLpFee() public {
        (,,, uint24 lpFee) = manager.getSlot0(flipKey.toId());
        assertEq(lpFee, 0);
        AsyncOrder memory o = _flipSell(flipKey, maker, 1e15, 1, 0);
        _place(o);
        router.fillFromPoolLiquidity(o);
        assertFalse(_open(flipKey, o.orderId()));
        (,,, lpFee) = manager.getSlot0(flipKey.toId());
        assertEq(lpFee, hook.POOL_LIQUIDITY_FILL_FEE());
    }

    function test_constructor_rejectsNativeNumeraire() public {
        bytes memory code = Huff.creationCode(
            "src/AsyncSwap.huff", abi.encode(manager, address(vault), Currency.wrap(address(0)), protocolOwner)
        );
        vm.expectRevert(IAsyncSwap.InvalidNumeraire.selector);
        this.create(code);
    }

    function create(bytes memory code) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(code, 0x20), mload(code))
            if iszero(deployed) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    /// The side follows the numeraire, not the swap direction: a `zeroForOne` order that spends it is a bid.
    function test_flip_sidesAndPriceKeys() public {
        bytes32 buyId = _place(_flipBuy(flipKey, maker, 2e18, 1e18, 0)); // bid 2
        bytes32 sellId = _place(_flipSell(flipKey, maker2, 1e18, 3e18, 0)); // ask 3

        AsyncFiller.OrderInfo memory b = hook.getOrder(flipKey, buyId);
        AsyncFiller.OrderInfo memory s = hook.getOrder(flipKey, sellId);
        assertTrue(b.zeroForOne && b.buy);
        assertTrue(!s.zeroForOne && !s.buy);
        assertEq(b.priceKey, 2e18);
        assertEq(s.priceKey, 3e18);

        (bytes32 bestBid, uint128 bidKey) = hook.bestOrder(flipKey, true);
        (bytes32 bestAsk, uint128 askKey) = hook.bestOrder(flipKey, false);
        assertEq(bestBid, buyId);
        assertEq(bestAsk, sellId);
        assertEq(bidKey, 2e18);
        assertEq(askKey, 3e18);
        assertEq(_claims(usdc, address(hook)), 2e18);
        assertEq(_claims(other, address(hook)), 1e18);
    }

    function test_flip_match() public {
        bytes32 sellId = _place(_flipSell(flipKey, maker, 1e18, 2e18, 0)); // ask 2
        uint256 makerUsdc = _bal(usdc, maker);
        uint256 maker2Other = _bal(other, maker2);
        bytes32 buyId = _place(_flipBuy(flipKey, maker2, 2e18, 1e18, 0)); // bid 2: crosses

        assertFalse(_open(flipKey, sellId));
        assertFalse(_open(flipKey, buyId));
        assertEq(_bal(usdc, maker), makerUsdc + 2e18, "seller paid in the numeraire");
        assertEq(_bal(other, maker2), maker2Other + 1e18, "buyer paid in the asset");
        assertEq(_claims(usdc, address(hook)), 0);
        assertEq(_claims(other, address(hook)), 0);
    }

    function test_flip_fill() public {
        AsyncOrder memory o = _flipSell(flipKey, maker, 1e18, 2e18, 0);
        _place(o);
        uint256 fee = ProtocolFee.poolFee(2e18);
        uint256 makerUsdc = _bal(usdc, maker);
        uint256 fillerUsdc = _bal(usdc, filler);
        uint256 fillerOther = _bal(other, filler);

        _fill(o, filler);

        assertEq(_bal(usdc, maker), makerUsdc + 2e18);
        assertEq(_bal(usdc, filler), fillerUsdc - 2e18 - fee);
        assertEq(_bal(other, filler), fillerOther + 1e18);
        assertEq(_claims(usdc, address(vault)), fee);
        assertEq(_claims(other, address(hook)), 0);
    }

    /// The bid is pulled, escrowed and donated in the numeraire (currency0), never in the order's input.
    function test_flip_bidInNumeraire() public {
        AsyncOrder memory o = _flipSell(flipPrioKey, maker, 1e18, 2e18, 5e6);
        uint256 makerUsdc = _bal(usdc, maker);
        uint256 makerOther = _bal(other, maker);
        _place(o);
        assertEq(_bal(usdc, maker), makerUsdc - 5e6, "bid paid in the numeraire");
        assertEq(_bal(other, maker), makerOther - 1e18, "only the input leaves in the asset");
        assertEq(_claims(usdc, address(hook)), 5e6);
        assertEq(_claims(other, address(hook)), 1e18);

        _fill(o, filler);
        assertEq(_claims(usdc, address(hook)), 0, "bid left the hook");
        assertEq(_claims(usdc, address(vault)), ProtocolFee.poolFee(2e18), "donated, not forfeited");
    }

    /// A partial match donates the matched share of a currency0 bid and keeps the rest escrowed.
    function test_flip_partialMatchDonatesProRata() public {
        bytes32 sellId = _place(_flipSell(flipPrioKey, maker, 2e18, 4e18, 4e6)); // ask 2, bid 4e6
        _place(_flipBuy(flipPrioKey, maker2, 2e18, 1e18, 2e6)); // bid 2: takes half the ask

        AsyncFiller.OrderInfo memory s = hook.getOrder(flipPrioKey, sellId);
        assertEq(s.amountIn, 1e18);
        assertEq(s.priorityFee, 2e6, "half the seller's bid donated");
        assertEq(_claims(usdc, address(hook)), 2e6, "the seller's remaining bid is the only numeraire claim");
        assertEq(_claims(other, address(hook)), 1e18);
    }
}
