// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HuffDeploy} from "./utils/HuffDeploy.sol";

import {Vm} from "forge-std/Vm.sol";
import {ISignatureTransfer} from "src/interface/ISignatureTransfer.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IAsyncSwap as AsyncSwap} from "src/interface/IAsyncSwap.sol";
import {IRouter as Router} from "src/interface/IRouter.sol";
import {AsyncOrder} from "src/interface/types/AsyncOrder.sol";
import {IAsyncFiller as AsyncFiller} from "src/interface/IAsyncFiller.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {IPoolManager, SwapParams} from "v4-core/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {MatchingHandler, PriorityMatchingInvariantTest} from "./MatchingInvariant.t.sol";

/// @notice A maker that bypasses the Router: it calls the PoolManager itself, claims a priority bid in
///         `hookData`, and never pays it. It authorizes the Router too, so it can cancel like anyone else.
contract UnpaidBidder {
    using PoolIdLibrary for PoolKey;

    IPoolManager immutable pm;
    AsyncSwap immutable hook;
    PoolKey key;
    uint256 pendingAmount;
    uint256 pendingMinimum;
    uint256 pendingBid;

    constructor(IPoolManager _pm, AsyncSwap _hook, PoolKey memory _key, address router) payable {
        pm = _pm;
        hook = _hook;
        key = _key;
        hook.setExecutor(_key.toId(), address(this), true);
        hook.setExecutor(_key.toId(), router, true);
    }

    receive() external payable {}

    /// @notice Sells `amount` native ETH for at least `minimum` USDC, claiming `bid` it never pays.
    function place(uint256 amount, uint256 minimum, uint256 bid) external {
        (pendingAmount, pendingMinimum, pendingBid) = (amount, minimum, bid);
        pm.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        pm.swap(
            key,
            SwapParams(true, -int256(pendingAmount), TickMath.MIN_SQRT_PRICE + 1),
            abi.encode(
                AsyncSwap.UserParams({
                    user: address(this), executor: address(this), amountOutMin: pendingMinimum, priorityFee: pendingBid
                })
            )
        );
        pm.settle{value: pendingAmount}();
        return "";
    }
}

/// @notice The matching handler, plus a maker that places orders with unpaid priority bids.
contract UnpaidBidHandler is MatchingHandler {
    UnpaidBidder public bidder;
    uint256 public unpaidPlaced;
    mapping(bytes32 => bool) public isUnpaid;

    constructor(AsyncSwap h, Router r, MockERC20 u, PoolKey memory k) MatchingHandler(h, r, u, k, true) {
        vm.deal(address(this), 1_000 ether);
        bidder = new UnpaidBidder{value: 1_000 ether}(h.poolManager(), h, k, address(r));
    }

    /// @notice An ask with a bid it never pays, up to the largest bid the hook accepts.
    function placeUnpaid(uint256 size, uint256 price, uint256 fee) external {
        // Down to 1 wei: dust orders are the cheapest way to plant an unpaid bid on a price level.
        uint256 quantity = bound(size, 1, 1 ether);
        uint256 minimum = quantity * bound(price, 1_000e6, 4_000e6) / 1 ether;
        if (minimum == 0) minimum = 1;
        uint256 bid = bound(fee, 100_000, type(uint64).max);
        vm.roll(block.number + 1);
        vm.recordLogs();
        bidder.place(quantity, minimum, bid);
        bytes32 salt;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == AsyncFiller.AsyncOrderCreated.selector) {
                (,,, salt) = abi.decode(logs[i].data, (bool, uint256, uint256, bytes32));
            }
        }
        AsyncOrder memory order = AsyncOrder(key, address(bidder), true, quantity, minimum, bid, 2 ** 96, salt);
        orders.push(order);
        isUnpaid[id(order)] = true;
        ++unpaidPlaced;
    }
}

/// @notice Invariants for unpaid priority bids (asyncswap/v2#9), on top of every PriorityFee-mode matching
///         invariant (escrow, asset conservation, best price): an unpaid bid buys no priority and can never
///         stop the book from matching or an order from being cancelled.
contract UnpaidBidInvariantTest is PriorityMatchingInvariantTest {
    using PoolIdLibrary for PoolKey;

    UnpaidBidHandler unpaid;

    function setUp() public override {
        manager = new PoolManager(address(this));
        usdc = new MockERC20("USD Coin", "USDC", 6);
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        HuffDeploy.hookTo(abi.encode(manager, Currency.wrap(address(usdc)), address(this)), address(flags));
        hook = AsyncSwap(payable(address(flags)));
        Router router = HuffDeploy.router(manager, hook, ISignatureTransfer(address(0)));
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(usdc)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 1, hook);
        manager.initialize(key, 2 ** 96);
        hook.setOrderingMode(key, AsyncFiller.OrderingMode.PriorityFee);
        unpaid = new UnpaidBidHandler(hook, router, usdc, key);
        handler = unpaid;
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = MatchingHandler.submit.selector;
        selectors[1] = MatchingHandler.cancel.selector;
        selectors[2] = MatchingHandler.reprice.selector;
        selectors[3] = MatchingHandler.clear.selector;
        selectors[4] = MatchingHandler.redeem.selector;
        selectors[5] = UnpaidBidHandler.placeUnpaid.selector;
        targetSelector(FuzzSelector(address(unpaid), selectors));
        targetContract(address(unpaid));
    }

    /// @notice Conservation with the unpaid bidder counted too (it holds 1,000 ETH and receives USDC and claims).
    function invariant_assetsConserved() public view override {
        address bidder = address(unpaid.bidder());
        uint256 ethTotal = address(manager).balance + bidder.balance;
        uint256 usdcTotal = usdc.balanceOf(address(manager)) + usdc.balanceOf(bidder);
        uint256 nativeClaims = manager.balanceOf(address(hook), 0) + manager.balanceOf(address(hook.feeVault()), 0)
            + manager.balanceOf(bidder, 0);
        for (uint256 i; i < 4; ++i) {
            address actor = unpaid.actors(i);
            ethTotal += actor.balance;
            usdcTotal += usdc.balanceOf(actor);
            nativeClaims += manager.balanceOf(actor, 0);
        }
        assertEq(address(manager).balance, nativeClaims, "all native claims backed exactly");
        assertEq(ethTotal, 5_000 ether);
        assertEq(usdcTotal, 40_000_000e6);
    }

    /// @notice Matching the book never reverts, from any state the fuzzer reaches (it never does without unpaid bids).
    function invariant_matchingNeverBlockedByUnpaidBid() public {
        Router router = unpaid.router();
        uint256 snapshot = vm.snapshotState();
        try router.matchBook(key, 8) {}
        catch (bytes memory reason) {
            emit log_named_bytes("matchBook reverted with", reason);
            assertTrue(false, "matching the book reverted");
        }
        vm.revertToState(snapshot);
    }

    /// @notice A new taker crossing the whole ask side can always trade: no resting order can freeze a price level.
    function invariant_crossingTakerCanAlwaysTrade() public {
        Router router = unpaid.router();
        address taker = makeAddr("taker");
        uint256 snapshot = vm.snapshotState();
        usdc.mint(taker, 100_000e6);
        uint256 spend = 50_000e6;
        // Buy ETH at up to 5,000 USDC/ETH, above every ask the handler places, with a paid priority bid.
        uint256 minimum = spend * 1 ether / 5_000e6;
        AsyncOrder memory order = AsyncOrder(key, taker, false, spend, minimum, 1e6, 2 ** 96, bytes32(0));
        vm.startPrank(taker);
        usdc.approve(address(router), type(uint256).max);
        hook.setExecutor(key.toId(), address(router), true);
        try router.swap(order, abi.encode(AsyncSwap.UserParams(taker, address(router), minimum, 1e6))) {}
        catch (bytes memory reason) {
            emit log_named_bytes("taker swap reverted with", reason);
            assertTrue(false, "a crossing taker could not trade");
        }
        vm.stopPrank();
        vm.revertToState(snapshot);
    }

    /// @notice Every open order, paid or not, can be cancelled by its maker.
    function invariant_everyOpenOrderCancellable() public {
        Router router = unpaid.router();
        uint256 count = unpaid.orderCount();
        for (uint256 i; i < count; ++i) {
            AsyncOrder memory order = unpaid.orderAt(i);
            if (hook.asyncOrder(key.toId(), unpaid.id(order)) == 0) continue;
            uint256 snapshot = vm.snapshotState();
            vm.prank(order.owner);
            try router.cancelOrder(order) {}
            catch (bytes memory reason) {
                emit log_named_bytes("cancel reverted with", reason);
                emit log_named_address("maker", order.owner);
                emit log_named_string("bid", unpaid.isUnpaid(unpaid.id(order)) ? "unpaid" : "paid or none");
                assertTrue(false, "an open order could not be cancelled");
            }
            vm.revertToState(snapshot);
        }
    }

    /// @notice An unpaid bid reads as 0 and never wins a price level over an order whose bid is paid.
    function invariant_unpaidBidBuysNoPriority() public view {
        uint256 count = unpaid.orderCount();
        for (uint256 i; i < count; ++i) {
            AsyncOrder memory order = unpaid.orderAt(i);
            bytes32 orderId = unpaid.id(order);
            if (unpaid.isUnpaid(orderId)) {
                assertEq(hook.asyncOrderPriorityFee(key.toId(), orderId), 0, "unpaid bid counted");
            }
        }
        for (uint256 side; side < 2; ++side) {
            (bool found, uint128 price, bytes32 bestId,) = hook.bestOrder(key.toId(), side == 1);
            if (!found || !unpaid.isUnpaid(bestId)) continue;
            // The best order is unpaid: no paid-bid order may wait at the same price behind it.
            for (uint256 i; i < count; ++i) {
                AsyncOrder memory order = unpaid.orderAt(i);
                bytes32 orderId = unpaid.id(order);
                (, uint256 amount,, uint128 p, bool buy,,) = hook.orderBookOrder(key.toId(), orderId);
                // Same side and same price level only: a bid and an ask can share a price key without crossing.
                if (amount == 0 || p != price || buy != (side == 1) || orderId == bestId) continue;
                assertEq(hook.asyncOrderPriorityFee(key.toId(), orderId), 0, "unpaid order ahead of a paid bid");
            }
        }
    }
}
