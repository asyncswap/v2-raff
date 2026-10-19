// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {IAsyncSwap} from "./utils/IAsyncSwap.sol";
import {IRouter} from "./utils/IRouter.sol";
import {AsyncOrder, AsyncOrderLibrary} from "./reference/AsyncOrder.sol";
import {AsyncFiller} from "./utils/IAsyncSwap.sol";
import {ProtocolFee} from "./reference/ProtocolFee.sol";

/// @notice Drives one pool through random creates, fills, cancels, reprices, book matches and liquidity fills,
///         remembering every order it placed.
contract Handler is Test {
    using AsyncOrderLibrary for AsyncOrder;

    IAsyncSwap immutable hook;
    IRouter immutable router;
    PoolKey key;
    bool immutable priorityMode;
    address[] makers;

    AsyncOrder[] public placed;
    uint256 public calls;
    /// @dev Successful fills, cancels, reprices, book matches and liquidity fills: the handler swallows reverts,
    ///      so `afterInvariant` checks the run actually exercised the protocol.
    uint256 public succeeded;

    constructor(IAsyncSwap _hook, IRouter _router, PoolKey memory _key, bool _priorityMode, address[] memory _makers) {
        hook = _hook;
        router = _router;
        key = _key;
        priorityMode = _priorityMode;
        makers = _makers;
    }

    function placedCount() external view returns (uint256) {
        return placed.length;
    }

    function place(uint256 who, bool zeroForOne, uint256 amountIn, uint256 amountOutMin, uint256 fee, bytes32 salt)
        external
    {
        calls++;
        address owner = makers[who % makers.length];
        amountIn = bound(amountIn, 1e6, 1e21);
        amountOutMin = bound(amountOutMin, 1e6, 1e21);
        fee = priorityMode ? bound(fee, AsyncFiller.MIN_PRIORITY_FEE, 1e9) : 0;
        AsyncOrder memory o = AsyncOrder(key, owner, zeroForOne, amountIn, amountOutMin, fee, 0, salt);
        vm.prank(owner);
        try router.swap(o) returns (bytes32 id) {
            // the hook may have walked the salt; recover it from the event-free path: ids are deterministic
            // in (owner, zeroForOne, salt), so walk the same way.
            while (o.orderId() != id) o.salt = keccak256(abi.encode(o.salt));
            placed.push(o);
        } catch {}
    }

    function fill(uint256 idx, uint256 who) external {
        calls++;
        if (placed.length == 0) return;
        AsyncOrder memory o = placed[idx % placed.length];
        address f = makers[who % makers.length];
        vm.prank(f);
        try router.fillOrder(o, type(uint256).max) {
            succeeded++;
        } catch {}
    }

    function cancel(uint256 idx) external {
        calls++;
        if (placed.length == 0) return;
        AsyncOrder memory o = placed[idx % placed.length];
        vm.prank(o.owner);
        try router.cancelOrder(o) {
            succeeded++;
        } catch {}
    }

    function reprice(uint256 idx, uint256 newMin) external {
        calls++;
        if (placed.length == 0) return;
        AsyncOrder memory o = placed[idx % placed.length];
        newMin = bound(newMin, 1e6, 1e21);
        vm.prank(o.owner);
        try hook.updatePrice(key, o.orderId(), newMin) {
            succeeded++;
        } catch {}
    }

    function matchBook(uint256 n) external {
        calls++;
        try router.matchBook(key, bound(n, 1, 8)) returns (uint256 m) {
            if (m != 0) succeeded++;
        } catch {}
    }

    function liquidityFill(uint256 idx) external {
        calls++;
        if (placed.length == 0) return;
        AsyncOrder memory o = placed[idx % placed.length];
        try router.fillFromPoolLiquidity(o) {
            succeeded++;
        } catch {}
    }
}

/// @dev Spec: `AsyncSwapProtocol/V2/Invariants.lean` (`Escrow`), `AsyncSwapSpec/RadixTree.lean`
///      (`PriceIndex.best_spec` = `invariant_bestPricesAgreeWithLinearScan`), `V2/Settlement.lean`
///      (hook balances untouched), `Priority.lean`.
contract InvariantTest is BaseTest {
    using AsyncOrderLibrary for AsyncOrder;

    Handler handler;
    bool constant PRIORITY = false;

    function setUp() public virtual override {
        super.setUp();
        address[] memory ms = new address[](3);
        ms[0] = maker;
        ms[1] = maker2;
        ms[2] = maker3;
        handler = new Handler(hook, router, _handlerKey(), _priority(), ms);
        targetContract(address(handler));
    }

    function _handlerKey() internal view virtual returns (PoolKey memory) {
        return key;
    }

    function _priority() internal pure virtual returns (bool) {
        return false;
    }

    /// @dev Distinct ids: a closed order frees its id, so a later order with the same (owner, direction, salt)
    ///      reuses it and `placed` can list it twice.
    function _ids() internal view returns (bytes32[] memory ids) {
        uint256 n = handler.placedCount();
        ids = new bytes32[](n);
        uint256 m;
        for (uint256 i = 0; i < n; i++) {
            (PoolKey memory k, address owner, bool zfo,,,,, bytes32 salt) = handler.placed(i);
            bytes32 id = AsyncOrderLibrary.orderId(AsyncOrder(k, owner, zfo, 0, 0, 0, 0, salt));
            bool seen;
            for (uint256 j = 0; j < m; j++) {
                if (ids[j] == id) seen = true;
            }
            if (!seen) ids[m++] = id;
        }
        assembly ("memory-safe") {
            mstore(ids, m)
        }
    }

    /// `Escrow.claims`: for each currency the hook's claims equal the open orders' remaining input plus bids.
    /// @dev Liveness: every run placed orders and some later action on them went through.
    function afterInvariant() public view {
        assertGt(handler.calls(), 0, "handler never called");
        assertGt(handler.placedCount(), 0, "no order was placed");
        assertGt(handler.succeeded(), 0, "no fill, cancel, reprice, match or liquidity fill succeeded");
    }

    function invariant_escrowEqualsOutstandingObligations() public view {
        PoolKey memory k = _handlerKey();
        bytes32[] memory ids = _ids();
        assertEq(_claims(k.currency0, address(hook)), _owed(k, ids, k.currency0), "currency0 escrow");
        assertEq(_claims(k.currency1, address(hook)), _owed(k, ids, k.currency1), "currency1 escrow");
    }

    /// `Escrow.wf`: open orders have positive input and positive outstanding minimum.
    function invariant_openOrdersWellFormed() public view {
        PoolKey memory k = _handlerKey();
        bytes32[] memory ids = _ids();
        uint256 open;
        for (uint256 i = 0; i < ids.length; i++) {
            AsyncFiller.OrderInfo memory info = hook.getOrder(k, ids[i]);
            if (info.amountIn == 0) continue;
            open++;
            assertGt(info.amountOutMin, 0);
            Currency input = info.zeroForOne ? k.currency0 : k.currency1;
            assertEq(info.buy, input == usdc, "a buy spends the numeraire");
            assertEq(info.priceKey, AsyncFiller.priceKey(info.buy, info.amountIn, info.amountOutMin));
        }
        assertEq(open, hook.openOrders(k));
    }

    /// `PriceIndex.best_spec`: the index returns the exact best price on each side, and the order it names is
    /// at that price and out-ranked by no other order there (bid first, then FIFO).
    function invariant_bestPricesAgreeWithLinearScan() public view {
        PoolKey memory k = _handlerKey();
        bytes32[] memory ids = _ids();
        _checkSide(k, ids, true);
        _checkSide(k, ids, false);
    }

    function _checkSide(PoolKey memory k, bytes32[] memory ids, bool buySide) internal view {
        (bytes32 bestId, uint128 bestKey) = hook.bestOrder(k, buySide);
        uint128 scan = buySide ? 0 : type(uint128).max;
        bool any;
        for (uint256 i = 0; i < ids.length; i++) {
            AsyncFiller.OrderInfo memory info = hook.getOrder(k, ids[i]);
            if (info.amountIn == 0 || info.buy != buySide) continue;
            any = true;
            if (buySide ? info.priceKey > scan : info.priceKey < scan) scan = info.priceKey;
        }
        if (!any) {
            assertEq(bestId, bytes32(0));
            return;
        }
        assertEq(bestKey, scan, "best price");
        AsyncFiller.OrderInfo memory best = hook.getOrder(k, bestId);
        assertEq(best.priceKey, scan, "best order sits at the best price");
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == bestId) continue;
            AsyncFiller.OrderInfo memory info = hook.getOrder(k, ids[i]);
            if (info.amountIn == 0 || info.buy != buySide || info.priceKey != scan) continue;
            bool ranksBefore = best.priorityFee > info.priorityFee
                || (best.priorityFee == info.priorityFee && best.sequence < info.sequence);
            assertTrue(ranksBefore, "bid first, then FIFO");
        }
    }

    /// The handler must actually be exercising the book, or the invariants above are vacuous.
    /// The hook never holds tokens of its own: every leg is settled through the PoolManager.
    function invariant_hookHoldsNoTokens() public view {
        assertEq(_bal(currency0, address(hook)), 0);
        assertEq(_bal(currency1, address(hook)), 0);
        assertEq(_bal(other, address(hook)), 0);
        assertEq(address(hook).balance, 0);
    }

    /// Backing: the PoolManager's balance covers every claim it issued (the full `Backing` equation needs the
    /// pool's reserves, which are not observable; the inequality is the observable half).
    function invariant_claimsBacked() public view {
        uint256 claims = _claims(currency0, address(hook)) + _claims(currency0, address(vault));
        assertGe(_bal(currency0, address(manager)), claims);
        claims = _claims(currency1, address(hook)) + _claims(currency1, address(vault));
        assertGe(_bal(currency1, address(manager)), claims);
        claims = _claims(other, address(hook)) + _claims(other, address(vault));
        assertGe(_bal(other, address(manager)), claims);
    }
}

contract InvariantPriorityTest is InvariantTest {
    function _handlerKey() internal view override returns (PoolKey memory) {
        return prioKey;
    }

    function _priority() internal pure override returns (bool) {
        return true;
    }
}

/// @dev The numeraire as currency0: a buy is `zeroForOne`, bids are paid and donated in currency0.
contract InvariantFlipTest is InvariantTest {
    function _handlerKey() internal view override returns (PoolKey memory) {
        return flipKey;
    }
}

contract InvariantFlipPriorityTest is InvariantTest {
    function _handlerKey() internal view override returns (PoolKey memory) {
        return flipPrioKey;
    }

    function _priority() internal pure override returns (bool) {
        return true;
    }
}
