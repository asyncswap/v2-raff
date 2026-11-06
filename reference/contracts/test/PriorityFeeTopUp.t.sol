// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TopUpCallbackToken, TopUpPaymentProbe} from "./utils/TopUpCallbackToken.sol";
import {SetupHook} from "./SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {Router} from "@async-swap/Router.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

contract PriorityFeeTopUpTest is SetupHook {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    event AsyncOrderPriorityFeeUpdated(
        PoolId indexed poolId, bytes32 indexed orderId, uint256 addedFee, uint256 newPriorityFee
    );

    function setUp() public override {
        super.setUp();
        _fund(alice);
        _fund(bob);
        _fund(carol);
    }

    function _fund(address actor) internal {
        topUp(actor, 1e30);
        vm.prank(actor);
        token0.approve(address(router), type(uint256).max);
    }

    function _place(address maker, bool sell, uint256 input, uint256 minimum, uint256 fee)
        internal
        returns (AsyncOrder memory o)
    {
        vm.roll(block.number + 1);
        o = AsyncOrder(key, maker, sell, input, minimum, fee, 2 ** 96, bytes32(0));
        vm.prank(maker);
        router.swap(o, abi.encode(AsyncSwap.UserParams(maker, address(router), minimum, fee)));
        o.salt = keccak256(abi.encode(block.timestamp, block.number, address(manager), maker, input, minimum, fee));
    }

    function _id(AsyncOrder memory o) internal view returns (bytes32) {
        return _orderIdFor(o.owner, o.zeroForOne, o.salt);
    }

    function _add(AsyncOrder memory o, uint256 amount) internal {
        vm.prank(o.owner);
        router.topUpPriorityFee(o, amount);
    }

    function _best(bool buy) internal view returns (bytes32 id) {
        (,, id,) = hook.bestOrder(poolId, buy);
    }

    function _state(bytes32 id) internal view returns (bytes32) {
        (, bytes memory record) = address(hook).staticcall(abi.encodeCall(hook.orderBookOrder, (poolId, id)));
        return keccak256(
            abi.encode(
                record,
                hook.orderCreatedSequence(poolId, id),
                hook.orderReprices(poolId, id),
                manager.balanceOf(address(hook), currency1.toId()),
                token1.balanceOf(alice),
                _best(false)
            )
        );
    }

    function test_fundedTopUpPreservesOrderAndEmitsEvent() public {
        AsyncOrder memory o = _place(alice, true, 1 ether, 2_000e6, 100_000);
        bytes32 id = _id(o);
        uint256 beforeTokens = token1.balanceOf(alice);
        uint256 beforeClaims = manager.balanceOf(address(hook), currency1.toId());
        uint64 created = hook.orderCreatedSequence(poolId, id);
        vm.expectEmit(true, true, false, true, address(hook));
        emit AsyncOrderPriorityFeeUpdated(poolId, id, 200_000, 300_000);
        _add(o, 200_000);
        {
            (address maker, uint256 input, uint256 minimum,, bool buy, uint64 newSequence, uint64 fee) =
                hook.orderBookOrder(poolId, id);
            assertEq(maker, alice);
            assertEq(input, 1 ether);
            assertEq(minimum, 2_000e6);
            assertFalse(buy);
            assertGt(newSequence, created);
            assertEq(fee, 300_000);
        }
        assertEq(hook.orderCreatedSequence(poolId, id), created);
        assertEq(hook.orderReprices(poolId, id), 0);
        assertEq(token1.balanceOf(alice), beforeTokens - 200_000);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), beforeClaims + 200_000);
        assertEq(token1.balanceOf(address(router)), 0);
        assertEq(manager.balanceOf(address(hook.feeVault()), currency1.toId()), 0);
    }

    function test_rekeyGoesBehindExistingEqualFeeThenWinsWithHigherFee() public {
        AsyncOrder memory a = _place(alice, true, 1 ether, 2_000e6, 100_000);
        AsyncOrder memory b = _place(bob, true, 1 ether, 2_000e6, 200_000);
        _add(a, 100_000);
        assertEq(_best(false), _id(b));
        _add(a, 1);
        assertEq(_best(false), _id(a));
        vm.prank(alice);
        router.cancelOrder(a);
        assertEq(_best(false), _id(b), "other entry and level survive rekey");
        vm.prank(bob);
        router.cancelOrder(b);
        assertEq(_best(false), bytes32(0), "last entry removes level");
    }

    function test_exactPriceStillPrecedesFeeWithinOneTick() public {
        AsyncOrder memory better = _place(alice, true, 1 ether, 2_000e6, 100_000);
        AsyncOrder memory worse = _place(bob, true, 1 ether, 2_000e6 + 1, 100_000);
        (,,, uint128 p1,,,) = hook.orderBookOrder(poolId, _id(better));
        (,,, uint128 p2,,,) = hook.orderBookOrder(poolId, _id(worse));
        assertEq(p1, p2, "test exercises exact bounds within one tick");
        _add(worse, 1e6);
        assertEq(_best(false), _id(better));
        _place(carol, false, 2_000e6, 1 ether, 0);
        assertEq(hook.asyncOrder(poolId, _id(better)), 0);
        assertEq(hook.asyncOrder(poolId, _id(worse)), 1 ether);
    }

    function test_buyQueueAndInputEscrowStaySeparate() public {
        AsyncOrder memory a = _place(alice, false, 2_000e6, 1 ether, 100_000);
        _place(bob, false, 2_000e6, 1 ether, 200_000);
        _add(a, 200_000);
        assertEq(_best(true), _id(a));
        assertEq(hook.asyncOrder(poolId, _id(a)), 2_000e6);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 4_000e6 + 500_000);
    }

    function test_zeroBidAdmissionAndSmallOrderFloor() public {
        AsyncOrder memory o = _place(alice, true, 1 ether, 10e6, 0);
        vm.expectRevert(AsyncFiller.PriorityFeeTooSmall.selector);
        _add(o, 9_999);
        _add(o, 10_000);
        assertEq(hook.asyncOrderPriorityFee(poolId, _id(o)), 10_000);
    }

    function test_partialFillUsesRemainingBidAndRestoresCurrentFloor() public {
        AsyncOrder memory o = _place(alice, true, 1 ether, 2_000e6, 100_000);
        _place(bob, false, 500e6, 0.25 ether, 0);
        assertEq(hook.asyncOrderPriorityFee(poolId, _id(o)), 75_000);
        vm.expectRevert(AsyncFiller.PriorityFeeTooSmall.selector);
        _add(o, 1);
        // The submitted struct still contains the original amounts and fee; storage is authoritative.
        _add(o, 25_000);
        (uint256 input, uint256 minimum) = hook.asyncOrderInfo(poolId, _id(o));
        assertEq(input, 0.75 ether);
        assertEq(minimum, 1_500e6);
        assertEq(hook.asyncOrderPriorityFee(poolId, _id(o)), 100_000);
        uint256 beforeVault = manager.balanceOf(address(hook.feeVault()), currency1.toId());
        vm.prank(alice);
        router.cancelOrder(o);
        assertEq(manager.balanceOf(address(hook.feeVault()), currency1.toId()), beforeVault + 100_000);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0);
    }

    function test_topUpDoesNotMatchButMulticallCan() public {
        AsyncOrder memory a = _place(alice, true, 1 ether, 2_000e6, 100_000);
        AsyncOrder memory b = _place(bob, false, 2_000e6, 2 ether, 0);
        vm.prank(bob);
        hook.updatePrice(b, 1 ether);
        _add(a, 100_000);
        assertEq(hook.asyncOrder(poolId, _id(a)), 1 ether, "top-up does not clear crossed orders");
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(router.topUpPriorityFee, (a, 100_000));
        calls[1] = abi.encodeCall(router.matchBook, (key, 1));
        vm.prank(alice);
        router.multicall(calls);
        assertEq(hook.asyncOrder(poolId, _id(a)), 0);
        assertEq(hook.asyncOrder(poolId, _id(b)), 0);
        assertEq(manager.balanceOf(address(hook.feeVault()), currency1.toId()), 300_000 + 400_000);
    }

    function test_failedMulticallRollsBackFundingAndQueue() public {
        AsyncOrder memory o = _place(alice, true, 1 ether, 2_000e6, 100_000);
        bytes32 beforeState = _state(_id(o));
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(router.topUpPriorityFee, (o, 100_000));
        calls[1] = abi.encodeCall(router.matchBook, (key, 0));
        vm.prank(alice);
        vm.expectRevert();
        router.multicall(calls);
        assertEq(_state(_id(o)), beforeState);
    }

    function test_ownerOnlyEvenForRegisteredExecutorWithAllowance() public {
        AsyncOrder memory o = _place(alice, true, 1 ether, 2_000e6, 0);
        vm.prank(alice);
        hook.setExecutor(poolId, bob, true);
        vm.prank(bob);
        vm.expectRevert("Only owner can top up");
        router.topUpPriorityFee(o, 100_000);
        vm.prank(alice);
        vm.expectRevert(AsyncSwap.NotTrustedRouter.selector);
        hook.topUpPriorityFee(o, 100_000);
        vm.prank(bob);
        vm.expectRevert(AsyncSwap.NotTrustedRouter.selector);
        hook.topUpPriorityFee(o, 100_000);
        vm.expectRevert("Caller is not PoolManager");
        router.unlockCallback(abi.encode(Router.ActionType.TopUpPriorityFee, o, uint256(100_000)));
    }

    function test_unknownWrongOwnerDirectionAndClosedOrderRejected() public {
        AsyncOrder memory o = _place(alice, true, 1 ether, 2_000e6, 0);
        bytes32 salt = o.salt;
        o.salt = bytes32(uint256(123));
        vm.expectRevert(AsyncFiller.OrderNotFound.selector);
        _add(o, 100_000);
        o.salt = salt;
        o.owner = bob;
        vm.expectRevert(AsyncFiller.OrderNotFound.selector);
        _add(o, 100_000);
        o.owner = alice;
        o.zeroForOne = false;
        vm.expectRevert(AsyncFiller.OrderNotFound.selector);
        _add(o, 100_000);
        o.zeroForOne = true;
        vm.prank(alice);
        router.cancelOrder(o);
        vm.expectRevert(AsyncFiller.OrderNotFound.selector);
        _add(o, 100_000);
    }

    function test_zeroOverflowAndMaximumBid() public {
        AsyncOrder memory o = _place(alice, true, 1 ether, 2_000e6, 100_000);
        vm.expectRevert(AsyncFiller.ZeroAmount.selector);
        _add(o, 0);
        vm.expectRevert(AsyncFiller.PriorityFeeTooLarge.selector);
        _add(o, type(uint256).max);
        _add(o, type(uint64).max - 100_000);
        assertEq(hook.asyncOrderPriorityFee(poolId, _id(o)), type(uint64).max);
        vm.expectRevert(AsyncFiller.PriorityFeeTooLarge.selector);
        _add(o, 1);
    }

    function test_missingAllowanceRollsBackQueueAndEscrow() public {
        AsyncOrder memory o = _place(alice, true, 1 ether, 2_000e6, 100_000);
        bytes32 beforeState = _state(_id(o));
        vm.prank(alice);
        token1.approve(address(router), 0);
        vm.expectRevert();
        _add(o, 100_000);
        assertEq(_state(_id(o)), beforeState);
    }

    function test_shortPaymentCannotLeaveUnfundedPriority() public {
        AsyncOrder memory o = _place(alice, true, 1 ether, 2_000e6, 100_000);
        bytes32 beforeState = _state(_id(o));
        vm.mockCall(
            address(token1), abi.encodeCall(IERC20.transferFrom, (alice, address(manager), 100_000)), abi.encode(true)
        );
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        _add(o, 100_000);
        assertEq(_state(_id(o)), beforeState);
    }

    function test_paymentCallbackCannotSeeUnfundedBidAndUsesLiveRemainder() public {
        AsyncOrder memory o = _place(alice, true, 1 ether, 2_000e6, 100_000);
        AsyncOrder memory b = _place(bob, false, 1_000e6, 1 ether, 0);
        vm.prank(bob);
        hook.updatePrice(b, 0.5 ether);
        TopUpPaymentProbe probe = new TopUpPaymentProbe(hook, key, _id(o), 100_000);
        TopUpCallbackToken callbackToken = new TopUpCallbackToken(probe);
        vm.etch(address(token1), address(callbackToken).code);
        _add(o, 100_000);
        assertTrue(probe.called());
        assertEq(hook.asyncOrder(poolId, _id(o)), 0.5 ether);
        assertEq(hook.asyncOrderPriorityFee(poolId, _id(o)), 150_000);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 150_000);
    }

    function test_orderClosedDuringPaymentRollsBackEntireTopUp() public {
        AsyncOrder memory o = _place(alice, true, 1 ether, 2_000e6, 100_000);
        AsyncOrder memory b = _place(bob, false, 2_000e6, 2 ether, 0);
        vm.prank(bob);
        hook.updatePrice(b, 1 ether);
        bytes32 beforeState = _state(_id(o));
        TopUpPaymentProbe probe = new TopUpPaymentProbe(hook, key, _id(o), 100_000);
        TopUpCallbackToken callbackToken = new TopUpCallbackToken(probe);
        vm.etch(address(token1), address(callbackToken).code);
        vm.expectRevert(AsyncFiller.OrderNotFound.selector);
        _add(o, 100_000);
        assertEq(_state(_id(o)), beforeState);
        assertFalse(probe.called(), "callback effects rolled back too");
    }

    function test_noNativeMevTaxForFeeOnlyUpdate() public {
        AsyncOrder memory o = _place(alice, true, 1 ether, 2_000e6, 100_000);
        vm.fee(1 gwei);
        vm.txGasPrice(3 gwei);
        _add(o, 100_000);
        assertEq(hook.asyncOrderPriorityFee(poolId, _id(o)), 200_000);
        assertEq(manager.balanceOf(address(hook.feeVault()), 0), 0);
    }

    function test_missingBalanceRollsBackFundingAndQueue() public {
        AsyncOrder memory o = _place(alice, true, 1 ether, 2_000e6, 100_000);
        uint256 balance = token1.balanceOf(alice);
        vm.prank(alice);
        token1.transfer(bob, balance);
        bytes32 beforeState = _state(_id(o));
        vm.expectRevert();
        _add(o, 100_000);
        assertEq(_state(_id(o)), beforeState);
    }

    function testFuzz_additiveFundingAndQueue(uint64 first, uint64 second) public {
        first = uint64(bound(first, 100_000, type(uint64).max / 2));
        second = uint64(bound(second, 1, type(uint64).max / 2));
        AsyncOrder memory o = _place(alice, true, 1 ether, 2_000e6, 0);
        uint256 beforeTokens = token1.balanceOf(alice);
        _add(o, first);
        _add(o, second);
        assertEq(hook.asyncOrderPriorityFee(poolId, _id(o)), uint256(first) + second);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), uint256(first) + second);
        assertEq(token1.balanceOf(alice), beforeTokens - first - second);
        assertEq(_best(false), _id(o));
    }
}

contract NumeraireZeroTopUpTest is SetupHook {
    function setUp() public override {
        _deployManager();
        _deployTokens();
        _deployRouter();
        vm.mockCall(address(token0), abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        deployCodeTo(
            "AsyncSwap.sol",
            abi.encode(manager, currency0, address(this), address(router), uint256(0), type(uint8).max),
            _hookAddress()
        );
        hook = AsyncSwap(payable(_hookAddress()));
        _createKey();
        _initializePool();
        _mintToOwner();
    }

    function _place(bool zeroForOne, uint256 input, uint256 minimum) internal returns (AsyncOrder memory o) {
        o = AsyncOrder(key, owner, zeroForOne, input, minimum, 100_000, 2 ** 96, bytes32(0));
        router.swap(o, abi.encode(AsyncSwap.UserParams(owner, address(router), minimum, 100_000)));
        o.salt = _expectedSalt(owner, input, minimum);
    }

    function test_topUpsFundCurrencyZeroForBothDirections() public ownerAction {
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        hook.setExecutor(poolId, address(router), true);
        AsyncOrder memory buy = _place(true, 2_000e6, 1 ether);
        AsyncOrder memory sell = _place(false, 1 ether, 3_000e6);
        uint256 beforeTokens = token0.balanceOf(owner);
        router.topUpPriorityFee(buy, 100_000);
        router.topUpPriorityFee(sell, 200_000);
        assertEq(token0.balanceOf(owner), beforeTokens - 300_000);
        assertEq(hook.asyncOrderPriorityFee(poolId, _orderIdFor(owner, true, buy.salt)), 200_000);
        assertEq(hook.asyncOrderPriorityFee(poolId, _orderIdFor(owner, false, sell.salt)), 300_000);
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 2_000e6 + 500_000);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 1 ether);
    }
}

contract TopUpNumeraireDecimalsTest is SetupHook {
    function setUp() public override {
        numeraireDecimals = 18;
        super.setUp();
    }

    function test_topUpUsesConfiguredNumeraireDecimals() public ownerAction {
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        hook.setExecutor(poolId, address(router), true);
        AsyncOrder memory o = AsyncOrder(key, owner, true, 1 ether, 2_000 ether, 0, 2 ** 96, bytes32(0));
        router.swap(o, abi.encode(AsyncSwap.UserParams(owner, address(router), 2_000 ether, 0)));
        o.salt = keccak256(
            abi.encode(block.timestamp, block.number, address(manager), owner, 1 ether, 2_000 ether, uint256(0))
        );
        vm.expectRevert(AsyncFiller.PriorityFeeTooSmall.selector);
        router.topUpPriorityFee(o, 0.1 ether - 1);
        router.topUpPriorityFee(o, 0.1 ether);
        assertEq(hook.asyncOrderPriorityFee(poolId, _orderIdFor(owner, true, o.salt)), 0.1 ether);
    }
}
