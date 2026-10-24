// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../SetupHook.t.sol";
import {IAsyncSwap as AsyncSwap} from "src/interface/IAsyncSwap.sol";
import {IAsyncFiller as AsyncFiller} from "src/interface/IAsyncFiller.sol";
import {AsyncOrder} from "src/interface/types/AsyncOrder.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Every order is worth at least the pool's minimum, in numeraire (token1) base units: a buy's
///         input, a sell's minimum output, and a sell's input at the pool's current price. A partial
///         match that leaves less than the minimum refunds the remainder. In PriorityFee mode the
///         least bid is min($0.10, 0.1% of the order).
contract MinimumOrderTest is SetupHook {
    using PoolIdLibrary for PoolKey;

    uint256 constant MIN = 10 ether; // "$10" for this 18-decimal numeraire

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        topUp(alice, 1_000 ether);
        topUp(bob, 1_000 ether);
    }

    function _order(address maker, bool zeroForOne, uint256 amountIn, uint256 amountOutMin, uint256 fee)
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
            priorityFee: fee,
            sqrtPrice: 2 ** 96,
            salt: keccak256(
                abi.encode(block.timestamp, block.number, address(manager), maker, amountIn, amountOutMin, fee)
            )
        });
    }

    /// @dev Asks sell token0 (zeroForOne); bids spend token1, the numeraire.
    function _submit(AsyncOrder memory order) internal {
        MockERC20 input = order.zeroForOne ? token0 : token1;
        vm.startPrank(order.owner);
        input.approve(address(router), order.amountIn);
        token1.approve(address(router), order.amountIn + order.priorityFee);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: order.owner,
                    executor: address(router),
                    amountOutMin: order.amountOutMin,
                    priorityFee: order.priorityFee
                })
            )
        );
        vm.stopPrank();
    }

    function _id(AsyncOrder memory order) internal view returns (bytes32) {
        return _orderIdFor(order.owner, order.zeroForOne, order.salt);
    }

    /* ------------------------------------------------------------------ admission */

    function test_RevertWhen_BuyBelowMinimum() public {
        hook.setMinOrder(key, MIN);
        AsyncOrder memory bid = _order(bob, false, MIN - 1, MIN, 100_000);
        vm.expectRevert(); // the hook's revert is wrapped by the PoolManager
        this.submitExternal(bid);
    }

    function test_buyAtMinimum_rests() public {
        hook.setMinOrder(key, MIN);
        AsyncOrder memory bid = _order(bob, false, MIN, MIN, 100_000);
        _submit(bid);
        assertEq(hook.asyncOrder(poolId, _id(bid)), MIN);
    }

    function test_RevertWhen_SellAsksBelowMinimum() public {
        hook.setMinOrder(key, MIN);
        AsyncOrder memory ask = _order(alice, true, 100 ether, MIN - 1, 100_000);
        vm.expectRevert();
        this.submitExternal(ask);
    }

    /// A sell asking for plenty but offering almost nothing, at the pool's 1:1 price, is below the minimum.
    function test_RevertWhen_SellInputWorthLessThanMinimum() public {
        hook.setMinOrder(key, MIN);
        AsyncOrder memory ask = _order(alice, true, 1, 100 ether, 100_000);
        vm.expectRevert();
        this.submitExternal(ask);
    }

    function test_sellAtMinimum_rests() public {
        hook.setMinOrder(key, MIN);
        AsyncOrder memory ask = _order(alice, true, MIN, MIN, 100_000);
        _submit(ask);
        assertEq(hook.asyncOrder(poolId, _id(ask)), MIN);
    }

    function test_RevertWhen_UpdatePriceBelowMinimum() public {
        hook.setMinOrder(key, MIN);
        AsyncOrder memory ask = _order(alice, true, 20 ether, 20 ether, 100_000);
        _submit(ask);
        vm.prank(alice);
        vm.expectRevert(AsyncFiller.BelowMinimumOrder.selector);
        hook.updatePrice(ask, MIN - 1);
    }

    /* ------------------------------------------------------------------ remainders */

    /// The ask is matched down to 5, below the minimum of 10: the order closes and the 5 return to alice.
    function test_partialMatchRemainderBelowMinimum_refunded() public {
        hook.setMinOrder(key, MIN);
        AsyncOrder memory ask = _order(alice, true, 15 ether, 15 ether, 100_000);
        uint256 aliceToken0Before = token0.balanceOf(alice);
        _submit(ask);
        _submit(_order(bob, false, MIN, MIN, 100_000));

        assertEq(hook.asyncOrder(poolId, _id(ask)), 0, "remainder below the minimum closes the order");
        assertEq(token0.balanceOf(alice), aliceToken0Before - 15 ether, "the full input was escrowed");
        assertEq(manager.balanceOf(alice, currency0.toId()), 5 ether, "the unmatched 5 are refunded as claims");
    }

    /// The resting bid is matched down to 5 of numeraire, below the minimum: it closes and the 5 return to bob.
    function test_partialMatchBuyRemainderBelowMinimum_refunded() public {
        hook.setMinOrder(key, MIN);
        AsyncOrder memory bid = _order(bob, false, 15 ether, 15 ether, 100_000);
        uint256 bobToken1Before = token1.balanceOf(bob);
        _submit(bid);
        _submit(_order(alice, true, MIN, MIN, 100_000));

        assertEq(hook.asyncOrder(poolId, _id(bid)), 0, "remainder below the minimum closes the order");
        assertEq(bobToken1Before - token1.balanceOf(bob), 15 ether + 100_000, "full input and bid were paid");
        assertEq(manager.balanceOf(bob, currency1.toId()), 5 ether, "the unmatched 5 are refunded as claims");
        assertEq(manager.balanceOf(bob, currency0.toId()), MIN, "the matched 10 asset arrive as claims");
    }

    /* --------------------------------------------- numeraire as currency0 */

    /// @dev A pool whose numeraire (token1 here) sorts first: selling the asset is `zeroForOne = false`,
    ///      so the sell's value is its input divided by the price.
    function _numeraireFirstPool() internal returns (PoolKey memory k, MockERC20 asset) {
        address high = address(type(uint160).max - 0xff);
        deployCodeTo("test/utils/MockERC20.sol:MockERC20", abi.encode("High", "HI", uint8(18)), high);
        asset = MockERC20(high);
        k = PoolKey({
            currency0: currency1,
            currency1: Currency.wrap(high),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 1,
            hooks: hook
        });
        manager.initialize(k, 2 ** 96);
        hook.setMinOrder(k, MIN);
        asset.mint(alice, 100 ether);
        vm.startPrank(alice);
        hook.setExecutor(k.toId(), address(router), true);
        asset.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function submitSellExternal(PoolKey memory k, uint256 amountIn, uint256 amountOutMin) external {
        _submitSell(k, amountIn, amountOutMin);
    }

    function _submitSell(PoolKey memory k, uint256 amountIn, uint256 amountOutMin) internal {
        AsyncOrder memory order = AsyncOrder(k, alice, false, amountIn, amountOutMin, 100_000, 2 ** 96, 0);
        vm.prank(alice);
        router.swap(order, abi.encode(AsyncSwap.UserParams(alice, address(router), amountOutMin, 100_000)));
    }

    function test_RevertWhen_SellInputWorthLessThanMinimum_numeraireIsCurrency0() public {
        (PoolKey memory k,) = _numeraireFirstPool();
        vm.expectRevert();
        this.submitSellExternal(k, 1, 100 ether);
    }

    function test_sellAtMinimum_rests_numeraireIsCurrency0() public {
        (PoolKey memory k, MockERC20 asset) = _numeraireFirstPool();
        uint256 before = asset.balanceOf(alice);
        _submitSell(k, MIN, MIN);
        assertEq(before - asset.balanceOf(alice), MIN, "the asset is escrowed: the order rests");
        assertEq(manager.balanceOf(address(hook), k.currency1.toId()), MIN);
    }

    /* ------------------------------------------------------------------ configuration */

    function test_newPoolsTakeTheDefaultMinimum() public {
        hook.setDefaultMinOrder(MIN);
        PoolKey memory key2 = PoolKey({
            currency0: currency0, currency1: currency1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 2, hooks: hook
        });
        manager.initialize(key2, 2 ** 96);
        vm.prank(bob);
        hook.setExecutor(key2.toId(), address(router), true);

        AsyncOrder memory bid = _order(bob, false, MIN - 1, MIN, 100_000);
        bid.key = key2;
        vm.expectRevert();
        this.submitExternal(bid);
    }

    function test_RevertWhen_NonOwnerSetsMinimum() public {
        vm.startPrank(alice);
        vm.expectRevert(AsyncSwap.NotOwner.selector);
        hook.setMinOrder(key, MIN);
        vm.expectRevert(AsyncSwap.NotOwner.selector);
        hook.setDefaultMinOrder(MIN);
        vm.stopPrank();
    }

    /* ------------------------------------------------------------------ tiered bid */

    /// A $50 order (6-decimal amounts) needs a bid of 0.1%, $0.05, not the full $0.10.
    function test_priorityFee_smallOrderPaysTenBps() public {
        AsyncOrder memory bid = _order(bob, false, 50e6, 50e6, 50_000);
        _submit(bid);
        assertEq(hook.asyncOrder(poolId, _id(bid)), 50e6);
    }

    function test_RevertWhen_priorityFee_smallOrderBelowTenBps() public {
        AsyncOrder memory bid = _order(bob, false, 50e6, 50e6, 49_999);
        vm.expectRevert();
        this.submitExternal(bid);
    }

    /// A sell admitted with a bid that rounds to zero cannot be repriced to terms that need a bid.
    function test_RevertWhen_updatePrice_raisesSellBidFloor() public {
        AsyncOrder memory ask = _order(alice, true, 100e6, 999, 0);
        _submit(ask);
        vm.prank(alice);
        vm.expectRevert(AsyncFiller.PriorityFeeTooSmall.selector);
        hook.updatePrice(ask, 100e6);
    }

    /// A $10 sell holds a $0.01 bid; repricing it to $1,000 needs the full $0.10.
    function test_RevertWhen_updatePrice_raisesSellBidFloor_withMinimum() public {
        hook.setMinOrder(key, 10e6);
        AsyncOrder memory ask = _order(alice, true, 1_000e6, 10e6, 10_000);
        _submit(ask);
        vm.prank(alice);
        vm.expectRevert(AsyncFiller.PriorityFeeTooSmall.selector);
        hook.updatePrice(ask, 1_000e6);
    }

    function test_updatePrice_withinSellBidFloor() public {
        AsyncOrder memory ask = _order(alice, true, 100e6, 50e6, 50_000);
        _submit(ask);
        vm.startPrank(alice);
        hook.updatePrice(ask, 40e6);
        hook.updatePrice(ask, 50e6);
        vm.stopPrank();
        (, uint256 out) = hook.asyncOrderInfo(poolId, _id(ask));
        assertEq(out, 50e6);
    }

    /// Half a $1,000 sell fills, leaving a pro-rated $0.05 bid under the $0.10 cap; it can still reprice.
    function test_updatePrice_partiallyFilledSellKeepsProRatedBid() public {
        AsyncOrder memory ask = _order(alice, true, 1_000e6, 1_000e6, 100_000);
        _submit(ask);
        _submit(_order(bob, false, 500e6, 500e6, 100_000));
        bytes32 id = _id(ask);
        assertEq(hook.asyncOrderPriorityFee(poolId, id), 50_000);
        vm.prank(alice);
        hook.updatePrice(ask, 400e6);
        vm.prank(alice);
        vm.expectRevert(AsyncFiller.PriorityFeeTooSmall.selector);
        hook.updatePrice(ask, 600e6);
        (, uint256 out) = hook.asyncOrderInfo(poolId, id);
        assertEq(out, 400e6);
    }

    /// Buys' bid floor follows their input, which a reprice never changes.
    function test_updatePrice_buyUnaffectedBySellBidFloor() public {
        AsyncOrder memory bid = _order(bob, false, 50e6, 1, 50_000);
        _submit(bid);
        vm.prank(bob);
        hook.updatePrice(bid, 1_000e6);
        (, uint256 out) = hook.asyncOrderInfo(poolId, _id(bid));
        assertEq(out, 1_000e6);
    }

    /// @dev External hop so `vm.expectRevert` sees the Router call as one call.
    function submitExternal(AsyncOrder memory order) external {
        _submit(order);
    }
}
