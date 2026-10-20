// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HuffDeploy} from "./utils/HuffDeploy.sol";

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IAsyncSwap as AsyncSwap} from "interfaces/IAsyncSwap.sol";
import {INativeClaims as NativeClaims} from "interfaces/INativeClaims.sol";
import {IRouter as Router} from "interfaces/IRouter.sol";
import {AsyncOrder} from "interfaces/types/AsyncOrder.sol";
import {IAsyncFiller as AsyncFiller} from "interfaces/IAsyncFiller.sol";
import {ISignatureTransfer} from "interfaces/ISignatureTransfer.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

contract MatchingHandler is Test {
    using PoolIdLibrary for PoolKey;
    AsyncSwap public hook;
    Router public router;
    NativeClaims public claims;
    MockERC20 public usdc;
    PoolKey public key;
    address[4] public actors;
    AsyncOrder[] internal orders;
    bool public priority;
    uint256 public submissions;
    uint256 public cancellations;
    uint256 public updates;
    uint256 public lpFills;

    constructor(AsyncSwap h, Router r, MockERC20 u, PoolKey memory k, bool p) {
        hook = h;
        router = r;
        claims = HuffDeploy.nativeClaims(h.poolManager());
        usdc = u;
        key = k;
        priority = p;
        for (uint256 i; i < 4; ++i) {
            address actor = address(uint160(0xC000 + i));
            actors[i] = actor;
            vm.deal(actor, 1_000 ether);
            u.mint(actor, 10_000_000e6);
            vm.startPrank(actor);
            u.approve(address(r), type(uint256).max);
            h.setExecutor(k.toId(), address(r), true);
            vm.stopPrank();
        }
    }

    function submit(uint256 who, bool sell, uint256 size, uint256 price, uint256 fee) external {
        address actor = actors[who % 4];
        uint256 quantity = bound(size, 1e12, 1 ether);
        uint256 quote = quantity * bound(price, 1_000e6, 4_000e6) / 1 ether;
        uint256 bid = priority ? bound(fee, 100_000, 10e6) : 0;
        uint256 amount = sell ? quantity : quote;
        uint256 minimum = sell ? quote : quantity;
        vm.roll(block.number + 1); // unique salt, including repeated actor/amount combinations
        AsyncOrder memory order = AsyncOrder(key, actor, sell, amount, minimum, bid, 2 ** 96, bytes32(0));
        vm.prank(actor);
        router.swap{value: sell ? amount : 0}(
            order, abi.encode(AsyncSwap.UserParams(actor, address(router), minimum, bid))
        );
        order.salt = keccak256(
            abi.encode(block.timestamp, block.number, address(hook.poolManager()), actor, amount, minimum, bid)
        );
        orders.push(order);
        ++submissions;
    }

    function cancel(uint256 index) external {
        if (orders.length == 0) return;
        AsyncOrder memory order = orders[index % orders.length];
        if (hook.asyncOrder(key.toId(), id(order)) == 0) return;
        vm.prank(order.owner);
        router.cancelOrder(order);
        ++cancellations;
    }

    function reprice(uint256 index, uint256 price) external {
        if (orders.length == 0) return;
        AsyncOrder memory order = orders[index % orders.length];
        uint256 remaining = hook.asyncOrder(key.toId(), id(order));
        if (remaining == 0) return;
        uint256 p = bound(price, 1_000e6, 4_000e6);
        uint256 minimum = order.zeroForOne ? remaining * p / 1 ether : remaining * 1 ether / p;
        if (minimum == 0) return;
        vm.prank(order.owner);
        hook.updatePrice(order, minimum);
        ++updates;
    }

    function redeem(uint256 who, uint256 size) external {
        address actor = actors[who % 4];
        uint256 balance = hook.poolManager().balanceOf(actor, 0);
        if (balance == 0) return;
        uint256 amount = bound(size, 1, balance);
        vm.startPrank(actor);
        hook.poolManager().approve(address(claims), 0, amount);
        claims.redeem(actor, amount);
        vm.stopPrank();
    }

    function clear(uint8 count) external {
        router.matchBook(key, uint8(bound(count, 1, 8)));
    }

    /// @dev Permissionless retry of a resting order against pool LPs. Counts only real fills.
    function lpFill(uint256 index) external {
        if (orders.length == 0) return;
        AsyncOrder memory order = orders[index % orders.length];
        bytes32 orderId = id(order);
        if (hook.asyncOrder(key.toId(), orderId) == 0) return;
        router.fillFromPoolLiquidity(order);
        if (hook.asyncOrder(key.toId(), orderId) == 0) ++lpFills;
    }

    function id(AsyncOrder memory order) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, key.toId(), order.owner, order.zeroForOne, order.salt));
    }

    function orderCount() external view returns (uint256) {
        return orders.length;
    }

    function orderAt(uint256 index) external view returns (AsyncOrder memory) {
        return orders[index];
    }
}

contract MatchingInvariantTest is StdInvariant, Test {
    using PoolIdLibrary for PoolKey;
    PoolManager manager;
    AsyncSwap hook;
    MockERC20 usdc;
    MatchingHandler handler;
    PoolKey key;

    function priorityMode() internal pure virtual returns (bool) {
        return false;
    }

    function initialSqrtPrice() internal pure virtual returns (uint160) {
        return 2 ** 96;
    }

    /// @dev Hook for subclasses that add Uniswap LP positions before the fuzz campaign.
    function _seedLiquidity() internal virtual {}

    function _selectors() internal pure virtual returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = MatchingHandler.submit.selector;
        selectors[1] = MatchingHandler.cancel.selector;
        selectors[2] = MatchingHandler.reprice.selector;
        selectors[3] = MatchingHandler.clear.selector;
        selectors[4] = MatchingHandler.redeem.selector;
    }

    function setUp() public virtual {
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
        manager.initialize(key, initialSqrtPrice());
        if (priorityMode()) hook.setOrderingMode(key, AsyncFiller.OrderingMode.PriorityFee);
        _seedLiquidity();
        handler = new MatchingHandler(hook, router, usdc, key, priorityMode());
        targetSelector(FuzzSelector(address(handler), _selectors()));
        targetContract(address(handler));
    }

    function invariant_escrowEqualsOutstandingObligations() public view {
        uint256 ethOwed;
        uint256 usdcOwed;
        uint256 count = handler.orderCount();
        for (uint256 i; i < count; ++i) {
            AsyncOrder memory order = handler.orderAt(i);
            bytes32 orderId = handler.id(order);
            uint256 remaining = hook.asyncOrder(key.toId(), orderId);
            if (order.zeroForOne) ethOwed += remaining;
            else usdcOwed += remaining;
            usdcOwed += hook.asyncOrderPriorityFee(key.toId(), orderId);
        }
        assertEq(manager.balanceOf(address(hook), 0), ethOwed, "native escrow obligations");
        assertEq(manager.balanceOf(address(hook), uint160(address(usdc))), usdcOwed, "USDC escrow obligations");
    }

    function invariant_assetsConserved() public view virtual {
        uint256 ethTotal = address(manager).balance;
        uint256 usdcTotal = usdc.balanceOf(address(manager));
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            ethTotal += actor.balance;
            usdcTotal += usdc.balanceOf(actor);
        }
        uint256 nativeClaims = manager.balanceOf(address(hook), 0) + manager.balanceOf(address(hook.feeVault()), 0);
        for (uint256 i; i < 4; ++i) {
            nativeClaims += manager.balanceOf(handler.actors(i), 0);
        }
        assertEq(address(manager).balance, nativeClaims, "all native claims backed exactly");
        assertEq(ethTotal, 4_000 ether);
        assertEq(usdcTotal, 40_000_000e6);
    }

    function invariant_bestPricesAgreeWithLinearScan() public view {
        uint128 bestBid;
        uint128 bestAsk = type(uint128).max;
        bool hasBid;
        bool hasAsk;
        for (uint256 i; i < handler.orderCount(); ++i) {
            AsyncOrder memory order = handler.orderAt(i);
            (, uint256 amount,, uint128 price, bool buy,,) = hook.orderBookOrder(key.toId(), handler.id(order));
            if (amount == 0) continue;
            if (buy) {
                hasBid = true;
                if (price > bestBid) bestBid = price;
            } else {
                hasAsk = true;
                if (price < bestAsk) bestAsk = price;
            }
        }
        (bool bidFound, uint128 bid,,) = hook.bestOrder(key.toId(), true);
        (bool askFound, uint128 ask,,) = hook.bestOrder(key.toId(), false);
        assertEq(bidFound, hasBid);
        assertEq(askFound, hasAsk);
        if (hasBid) assertEq(bid, bestBid);
        if (hasAsk) assertEq(ask, bestAsk);
    }
}

contract PriorityMatchingInvariantTest is MatchingInvariantTest {
    function priorityMode() internal pure override returns (bool) {
        return true;
    }
}

/// @notice Same campaign with real Uniswap v4 liquidity in range, so book matching, pool fills
///         (automatic on submit and via permissionless retry) and cancels interleave. The pool
///         is priced at 2,000 USDC per ETH, inside the handler's 1,000-4,000 price range, so
///         roughly half of all submissions are eligible for a pool fill.
contract LpMatchingInvariantTest is MatchingInvariantTest {
    using StateLibrary for IPoolManager;
    // sqrt(2000e6 / 1e18) * 2^96 with ETH as currency0 and 6-decimal USDC as currency1.
    uint160 constant SQRT_PRICE_2000 = 3543191142285914327220224;
    int24 constant TICK_2000 = -200311;

    uint256 seededEth;
    uint256 seededUsdc;

    receive() external payable {}

    function initialSqrtPrice() internal pure override returns (uint160) {
        return SQRT_PRICE_2000;
    }

    function _seedLiquidity() internal override {
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        vm.deal(address(this), 20_000 ether);
        usdc.mint(address(this), 50_000_000e6);
        usdc.approve(address(lp), type(uint256).max);
        uint256 ethBefore = address(manager).balance;
        uint256 usdcBefore = usdc.balanceOf(address(manager));
        // ~1% band around spot; 1e20 liquidity is ~11k ETH / ~22M USDC of depth.
        lp.modifyLiquidity{value: 20_000 ether}(
            key, ModifyLiquidityParams(TICK_2000 - 100, TICK_2000 + 100, 1e20, 0), ""
        );
        seededEth = address(manager).balance - ethBefore;
        seededUsdc = usdc.balanceOf(address(manager)) - usdcBefore;
        assertGt(IPoolManager(address(manager)).getLiquidity(key.toId()), 0, "liquidity active at spot");
    }

    function _selectors() internal pure override returns (bytes4[] memory selectors) {
        bytes4[] memory base = super._selectors();
        selectors = new bytes4[](base.length + 1);
        for (uint256 i; i < base.length; ++i) {
            selectors[i] = base[i];
        }
        selectors[base.length] = MatchingHandler.lpFill.selector;
    }

    /// @dev Sanity check that the campaign's price range actually reaches the pool: a sell below
    ///      spot and a buy above spot both fill on submit, so the fuzz actions exercise the fill path.
    function test_campaignPricesReachThePool() public {
        address seller = handler.actors(0);
        uint256 usdcBefore = usdc.balanceOf(seller);
        handler.submit(0, true, 1 ether, 1_500e6, 0);
        assertEq(hook.asyncOrder(key.toId(), handler.id(handler.orderAt(0))), 0, "sell below spot fills from the pool");
        assertGe(usdc.balanceOf(seller) - usdcBefore, 1_500e6, "seller paid at least the limit in USDC");

        address buyer = handler.actors(1);
        handler.submit(1, false, 1 ether, 2_500e6, 0);
        assertEq(hook.asyncOrder(key.toId(), handler.id(handler.orderAt(1))), 0, "buy above spot fills from the pool");
        assertGe(manager.balanceOf(buyer, 0), 1 ether, "buyer receives native output as claims");

        handler.submit(2, true, 1 ether, 3_000e6, 0);
        assertEq(hook.asyncOrder(key.toId(), handler.id(handler.orderAt(2))), 1 ether, "sell above spot rests");
    }

    /// @dev With LPs in the pool the manager also holds pool reserves, so native claims are a
    ///      lower bound on its balance rather than equal to it. Totals stay exactly conserved.
    function invariant_assetsConserved() public view override {
        uint256 ethTotal = address(manager).balance;
        uint256 usdcTotal = usdc.balanceOf(address(manager));
        uint256 nativeClaims = manager.balanceOf(address(hook), 0) + manager.balanceOf(address(hook.feeVault()), 0);
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            ethTotal += actor.balance;
            usdcTotal += usdc.balanceOf(actor);
            nativeClaims += manager.balanceOf(actor, 0);
        }
        assertGe(address(manager).balance, nativeClaims, "every native claim is backed");
        assertEq(ethTotal, 4_000 ether + seededEth, "ETH conserved across book, pool and actors");
        assertEq(usdcTotal, 40_000_000e6 + seededUsdc, "USDC conserved across book, pool and actors");
    }

    /// @dev A pool fill may never leave the hook holding output claims: the maker is paid out
    ///      (ERC20 transfer, or native claims in the maker's own name).
    function invariant_hookHoldsNoUsdcBeyondEscrow() public view {
        uint256 usdcOwed;
        for (uint256 i; i < handler.orderCount(); ++i) {
            AsyncOrder memory order = handler.orderAt(i);
            bytes32 orderId = handler.id(order);
            if (!order.zeroForOne) usdcOwed += hook.asyncOrder(key.toId(), orderId);
            usdcOwed += hook.asyncOrderPriorityFee(key.toId(), orderId);
        }
        assertEq(manager.balanceOf(address(hook), uint160(address(usdc))), usdcOwed);
    }
}
