// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {OrderInfo} from "./OrderInfo.sol";
import {HookUnlockBase} from "./HookUnlockBase.sol";
import {IAsyncSwap as AsyncSwap} from "src/interface/IAsyncSwap.sol";
import {IAsyncFiller as AsyncFiller} from "src/interface/IAsyncFiller.sol";
import {IPoolManager, SwapParams} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "../utils/MockERC20.sol";

/// @notice Group-D scaffold for the private steps of `AsyncMatching`'s matching pipeline
///         (`_matchPair` → `_matchAmounts`, `_settleTransfers` → `_transferEscrow`,
///         `_reduceMatchedOrders` → `_reduceAfterMatch` → `_settleMatchedPriorityFee`). They are
///         private, so they are observed through one `AsyncSwap.matchBook(key, 1)` call: exactly one
///         `_matchPair(bidId, askId)` on a book holding one resting sell (alice, `zeroForOne`) and one
///         resting buy (bob, `!zeroForOne`). The two orders are created inside an unlock without the
///         Router's `matchNewOrder`, so they rest crossed; the test contract is their executor and
///         pays their input. The PoolManager / ERC-20 / hook events of the match are decoded into an
///         ordered trace of `burn` / `mint` / `take` / priority-fee settlements / the match event,
///         which the tests compare with what the theorems say happens, in order.
abstract contract FormalMatchD is HookUnlockBase {
    using PoolIdLibrary for PoolKey;

    uint8 constant OP_BURN = 1; // PoolManager.burn(from = who, id = cur, amount)
    uint8 constant OP_MINT = 2; // PoolManager.mint(to = who, id = cur, amount)
    uint8 constant OP_TAKE = 3; // PoolManager.take(token = cur, to = who, amount) (ERC-20 leaves the PM)
    uint8 constant OP_FEE_DONATED = 4; // PriorityFeeDonated(orderId = tag, maker = who, amount)
    uint8 constant OP_FEE_FORFEITED = 5; // PriorityFeeForfeited(orderId = tag, maker = who, amount)
    uint8 constant OP_MATCHED = 6; // AsyncOrdersMatched(sell = tag, buy = tag2, asset = amount, quote = amount2)

    bytes32 constant T6909 = keccak256("Transfer(address,address,address,uint256,uint256)");
    bytes32 constant T20 = keccak256("Transfer(address,address,uint256)");

    struct Op {
        uint8 kind;
        address who;
        uint256 cur;
        uint256 amount;
        uint256 amount2;
        bytes32 tag;
        bytes32 tag2;
    }

    /// @dev One crossed pair: sell = alice (input currency0, the asset), buy = bob (input currency1,
    ///      the numeraire). `a`/`q` are the sell's amountIn/amountOutMin, `Q`/`A` the buy's.
    struct Case {
        PoolKey k;
        PoolId pid;
        bool native; // currency0 is native ETH
        bool pf; // PriorityFee ordering mode
        bool liq; // active LP liquidity (fee settlements donate instead of forfeiting)
        bool restingBuy; // the buy is the older order
        uint256 a;
        uint256 q;
        uint256 Q;
        uint256 A;
        uint256 sellBid;
        uint256 buyBid;
        bool sellPaid;
        bool buyPaid;
        bytes32 sellId;
        bytes32 buyId;
    }

    /// @dev Everything one `matchBook(key, 1)` run shows.
    struct Run {
        bool crosses; // `_crosses(bidKey, askKey, buy, sell)` holds, so `_matchPair` runs
        uint256 asset; // spec `AsyncSwap.matchAmounts` on the stored orders
        uint256 quote;
        uint8 matched;
        Op[] ops;
        OrderInfo sell0;
        OrderInfo buy0;
        OrderInfo sell1;
        OrderInfo buy1;
        uint64 nextSeq0;
        uint64 nextSeq1;
    }

    bool private _nativeInit;
    PoolKey internal nativeKey;

    // ------------------------------------------------------------------ amounts

    /// @dev Log-uniform amount in [1, 2^bits), bits in [1, 120]: below the PoolManager's int128 limit.
    function _amt(uint256 s) internal pure returns (uint256) {
        uint256 bits = 1 + (s % 120);
        uint256 v = uint256(keccak256(abi.encode(s)));
        return 1 + (v % ((uint256(1) << bits) - 1));
    }

    function _min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x < y ? x : y;
    }

    // ------------------------------------------------------------------ spec

    function _ceilDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y) % d == 0 ? (x * y) / d : (x * y) / d + 1;
    }

    /// @dev `AsyncSwap.matchAmounts` (formal/AsyncSwapSpec/Match.lean:27) on (sell, buy). Plain
    ///      arithmetic is exact here: every amount is below 2^127.
    function _spec(uint256 a, uint256 q, uint256 Q, uint256 A, bool rb)
        internal
        pure
        returns (uint256 asset, uint256 quote)
    {
        if (rb) {
            uint256 qt = _min((a * Q) / A, Q);
            if (qt == 0) return (0, 0);
            uint256 at = _ceilDiv(qt, A, Q);
            if (a < at) return (0, 0);
            if (qt < _ceilDiv(at, q, a)) return (0, 0);
            return (at, qt);
        } else {
            uint256 at = _min((Q * a) / q, a);
            if (at == 0) return (0, 0);
            uint256 qt = _ceilDiv(at, q, a);
            if (Q < qt) return (0, 0);
            if (at < _ceilDiv(qt, A, Q)) return (0, 0);
            return (at, qt);
        }
    }

    // ------------------------------------------------------------------ orders

    function _info(PoolId pid, bytes32 id) internal view returns (OrderInfo memory o) {
        bytes32[8] memory w = _orderWords(pid, id);
        o.owner = address(uint160(uint256(w[0])));
        o.amountIn = uint256(w[1]);
        o.amountOutMin = uint256(w[2]);
        o.price = uint128(uint256(w[3]));
        o.previous = w[4];
        o.next = w[5];
        uint256 w6 = uint256(w[6]);
        o.isBuy = w6 & 0xff != 0;
        o.zeroForOne = (w6 >> 8) & 0xff != 0;
        o.sequence = uint64(w6 >> 16);
        o.priorityFee = uint64(w6 >> 80);
        uint256 w7 = uint256(w[7]);
        o.priorityKey = uint128(w7);
        o.priorityFeeEscrowed = (w7 >> 128) & 0xff != 0;
    }

    function _storeWord(PoolId pid, bytes32 id, uint256 i, uint256 v) internal {
        _storeOrderWord(pid, id, i, bytes32(v));
    }

    function _isEmpty(OrderInfo memory o) internal pure returns (bool) {
        return o.owner == address(0) && o.amountIn == 0 && o.amountOutMin == 0 && o.price == 0
            && o.previous == bytes32(0) && o.next == bytes32(0) && !o.isBuy && !o.zeroForOne && o.sequence == 0
            && o.priorityFee == 0 && o.priorityKey == 0 && !o.priorityFeeEscrowed;
    }

    function _paid(OrderInfo memory o) internal pure returns (uint256) {
        return o.priorityFeeEscrowed ? o.priorityFee : 0;
    }

    function _nativePool() internal returns (PoolKey memory) {
        if (!_nativeInit) {
            nativeKey = _initNativePool();
            _nativeInit = true;
        }
        return nativeKey;
    }

    function _swapCall(
        PoolKey memory k,
        address maker,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 bid
    ) internal view returns (Call memory) {
        AsyncSwap.UserParams memory up = AsyncSwap.UserParams({
            user: maker, executor: address(this), amountOutMin: amountOutMin, priorityFee: bid
        });
        return _c(
            address(manager),
            abi.encodeCall(
                manager.swap, (k, SwapParams(zeroForOne, -int256(amountIn), uint160(2 ** 96)), abi.encode(up))
            )
        );
    }

    /// @dev Create a resting order for `maker` with this contract as executor and payer, inside one
    ///      unlock, without `matchNewOrder`. `bid` is recorded (escrowed) only when `paid`.
    function _rest(
        PoolKey memory k,
        address maker,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 bid,
        bool paid
    ) internal returns (bytes32 id) {
        id = keccak256(
            abi.encode(block.chainid, k.toId(), maker, zeroForOne, _saltOf(maker, amountIn, amountOutMin, bid))
        );
        if (hook.asyncOrder(k.toId(), id) != 0) {
            vm.roll(block.number + 1);
            return _rest(k, maker, zeroForOne, amountIn, amountOutMin, bid, paid);
        }
        if (!hook.isExecutor(k.toId(), maker, address(this))) {
            vm.prank(maker);
            hook.setExecutor(k.toId(), address(this), true);
        }
        Currency input = zeroForOne ? k.currency0 : k.currency1;
        Call[] memory cs = _one(_swapCall(k, maker, zeroForOne, amountIn, amountOutMin, bid));
        if (input.isAddressZero()) {
            vm.deal(address(this), address(this).balance + amountIn);
            cs = _push(
                cs,
                Call({
                    caller: address(this),
                    target: address(manager),
                    value: amountIn,
                    data: abi.encodeWithSignature("settle()")
                })
            );
        } else {
            MockERC20(Currency.unwrap(input)).mint(address(this), amountIn);
            cs = _push(cs, _c(address(manager), abi.encodeCall(manager.sync, (input))));
            cs = _push(cs, _c(Currency.unwrap(input), abi.encodeCall(MockERC20.transfer, (address(manager), amountIn))));
            cs = _push(cs, _c(address(manager), abi.encodeWithSignature("settle()")));
        }
        if (paid && bid != 0) {
            token1.mint(address(this), bid);
            cs = _cat(cs, _payToHookCalls(currency1, bid));
            cs = _push(cs, _c(address(hook), abi.encodeCall(hook.recordPriorityFee, (k, maker, bid))));
        }
        _run(cs);
        require(hook.asyncOrder(k.toId(), id) == amountIn, "order not created at the predicted id");
    }

    /// @dev Build the pair. `s` seeds: [0..3] amounts, [4] sell bid, [5] buy bid. `flags` bits:
    ///      0 restingBuy, 1 native, 2 PriorityFee mode, 3 pool liquidity, 4 sell bid paid, 5 buy bid paid,
    ///      6 tiny amounts (1..12), 7 rewrite the stored amounts after creation.
    ///      The buy limit `A` is drawn below `Q·a/q` so that most pairs cross.
    function _mkCase(uint256[6] memory s, uint256 flags) internal returns (Case memory c) {
        c.restingBuy = flags & 1 != 0;
        c.native = flags & 2 != 0;
        c.pf = flags & 4 != 0;
        c.liq = !c.native && flags & 8 != 0;
        c.sellPaid = flags & 16 != 0;
        c.buyPaid = flags & 32 != 0;
        if (flags & 64 != 0) {
            // tiny amounts: rounding decides, so zero-amount results occur
            c.a = 1 + (s[0] % 12);
            c.q = 1 + (s[1] % 12);
            c.Q = 1 + (s[2] % 12);
        } else {
            c.a = _amt(s[0]);
            c.q = _amt(s[1]);
            c.Q = _amt(s[2]);
        }
        uint256 maxA = (c.Q * c.a) / c.q;
        c.A = 1 + (uint256(keccak256(abi.encode(s[3]))) % _min(maxA == 0 ? 1 : maxA, 2 ** 120));
        if (c.pf) {
            c.sellBid = 100_000 + (s[4] % (uint256(type(uint64).max) - 100_000));
            c.buyBid = 100_000 + (s[5] % (uint256(type(uint64).max) - 100_000));
        }
        c.k = c.native ? _nativePool() : key;
        c.pid = c.k.toId();
        if (c.pf) hook.setOrderingMode(c.k, AsyncFiller.OrderingMode.PriorityFee);
        if (c.liq) _addPoolLiquidity(1e24);
        if (c.restingBuy) {
            c.buyId = _rest(c.k, bob, false, c.Q, c.A, c.buyBid, c.buyPaid);
            c.sellId = _rest(c.k, alice, true, c.a, c.q, c.sellBid, c.sellPaid);
        } else {
            c.sellId = _rest(c.k, alice, true, c.a, c.q, c.sellBid, c.sellPaid);
            c.buyId = _rest(c.k, bob, false, c.Q, c.A, c.buyBid, c.buyPaid);
        }
        if (flags & 128 != 0) {
            // Arbitrary stored state: keep the book (crossed keys) and the escrow, rewrite the
            // amounts (amountIn within the escrow, any positive amountOutMin).
            uint256 h = uint256(keccak256(abi.encode(s, "rewrite")));
            _storeWord(c.pid, c.sellId, 1, 1 + (h % c.a));
            _storeWord(c.pid, c.sellId, 2, _amt(h >> 1));
            _storeWord(c.pid, c.buyId, 1, 1 + ((h >> 2) % c.Q));
            _storeWord(c.pid, c.buyId, 2, _amt(h >> 3));
        }
    }

    /// @dev `_crosses(bidKey, askKey, buy, sell)` as documented in `AsyncMatching`: strictly ordered keys
    ///      decide; equal keys use the exact cross-multiply `buyIn·sellIn ≥ sellOut·buyOut`.
    function _crossesSpec(OrderInfo memory buy, OrderInfo memory sell)
        internal
        pure
        returns (bool)
    {
        if (buy.price != sell.price) return buy.price > sell.price;
        return buy.amountIn * sell.amountIn >= sell.amountOutMin * buy.amountOutMin;
    }

    function _matchCalls(PoolKey memory k) internal view returns (Call[] memory) {
        return _one(_c(address(hook), abi.encodeCall(hook.matchBook, (k, 1))));
    }

    /// @dev `_matchPair(bidId, askId)`: the older order's side rests.
    function _makerBuy(OrderInfo memory buy, OrderInfo memory sell)
        internal
        pure
        returns (bool)
    {
        return buy.sequence < sell.sequence;
    }

    /// @dev One `matchBook(k, 1)` with the orders' state before and after and the decoded trace.
    function _exec(Case memory c) internal returns (Run memory r) {
        r.sell0 = _info(c.pid, c.sellId);
        r.buy0 = _info(c.pid, c.buyId);
        r.nextSeq0 = _nextSequence(c.pid);
        r.crosses = _crossesSpec(r.buy0, r.sell0);
        (r.asset, r.quote) = _spec(
            r.sell0.amountIn, r.sell0.amountOutMin, r.buy0.amountIn, r.buy0.amountOutMin, _makerBuy(r.buy0, r.sell0)
        );
        vm.recordLogs();
        bytes[] memory res = _runR(_matchCalls(c.k));
        r.ops = _ops(vm.getRecordedLogs());
        r.matched = abi.decode(res[0], (uint8));
        r.sell1 = _info(c.pid, c.sellId);
        r.buy1 = _info(c.pid, c.buyId);
        r.nextSeq1 = _nextSequence(c.pid);
    }

    // ------------------------------------------------------------------ traces

    function _ops(Vm.Log[] memory logs) internal view returns (Op[] memory ops) {
        ops = new Op[](logs.length);
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.topics.length == 0) continue;
            bytes32 t0 = l.topics[0];
            if (l.emitter == address(manager) && t0 == T6909) {
                address from = address(uint160(uint256(l.topics[1])));
                address to = address(uint160(uint256(l.topics[2])));
                (, uint256 amount) = abi.decode(l.data, (address, uint256));
                if (to == address(0)) {
                    ops[n++] = Op(OP_BURN, from, uint256(l.topics[3]), amount, 0, 0, 0);
                } else if (from == address(0)) {
                    ops[n++] = Op(OP_MINT, to, uint256(l.topics[3]), amount, 0, 0, 0);
                }
            } else if (
                t0 == T20 && (l.emitter == address(token0) || l.emitter == address(token1))
                    && address(uint160(uint256(l.topics[1]))) == address(manager)
            ) {
                ops[n++] = Op(
                    OP_TAKE,
                    address(uint160(uint256(l.topics[2]))),
                    uint256(uint160(l.emitter)),
                    abi.decode(l.data, (uint256)),
                    0,
                    0,
                    0
                );
            } else if (l.emitter == address(hook) && t0 == AsyncSwap.AsyncOrdersMatched.selector) {
                (uint256 asset, uint256 quote) = abi.decode(l.data, (uint256, uint256));
                ops[n++] = Op(OP_MATCHED, address(0), 0, asset, quote, l.topics[2], l.topics[3]);
            } else if (
                l.emitter == address(hook)
                    && (t0 == AsyncFiller.PriorityFeeDonated.selector
                        || t0 == AsyncFiller.PriorityFeeForfeited.selector)
            ) {
                ops[n++] = Op(
                    t0 == AsyncFiller.PriorityFeeDonated.selector ? OP_FEE_DONATED : OP_FEE_FORFEITED,
                    address(uint160(uint256(l.topics[3]))),
                    0,
                    abi.decode(l.data, (uint256)),
                    0,
                    l.topics[2],
                    0
                );
            }
        }
        assembly ("memory-safe") {
            mstore(ops, n)
        }
    }

    /// @dev Growable op list.
    struct Trace {
        Op[] ops;
        uint256 n;
    }

    function _newTrace() internal pure returns (Trace memory t) {
        t.ops = new Op[](32);
    }

    function _add(Trace memory t, Op memory o) internal pure {
        t.ops[t.n++] = o;
    }

    function _done(Trace memory t) internal pure returns (Op[] memory ops) {
        ops = t.ops;
        uint256 n = t.n;
        assembly ("memory-safe") {
            mstore(ops, n)
        }
    }

    /// @dev `TransferEscrow.payout`: native → `mint(recipient, 0, amount)`, ERC-20 → `take`.
    function _payout(Trace memory t, Currency c, address to, uint256 amount) internal pure {
        if (c.isAddressZero()) _add(t, Op(OP_MINT, to, 0, amount, 0, 0, 0));
        else _add(t, Op(OP_TAKE, to, uint256(uint160(Currency.unwrap(c))), amount, 0, 0, 0));
    }

    /// @dev `_transferEscrow`: burn `amount` of `c` from the hook, then the payout.
    function _escrowLeg(Trace memory t, Currency c, address to, uint256 amount) internal view {
        _add(t, Op(OP_BURN, address(hook), c.toId(), amount, 0, 0, 0));
        _payout(t, c, to, amount);
    }

    /// @dev `AsyncFiller.settlePriorityFee(amount)` (nothing when `amount == 0`).
    function _feeOps(Trace memory t, Case memory c, bytes32 id, address maker, uint256 amount) internal view {
        if (amount == 0) return;
        _add(t, Op(OP_BURN, address(hook), currency1.toId(), amount, 0, 0, 0));
        if (c.liq) {
            _add(t, Op(OP_FEE_DONATED, maker, 0, amount, 0, id, 0));
        } else {
            _add(t, Op(OP_MINT, address(hook.feeVault()), currency1.toId(), amount, 0, 0, 0));
            _add(t, Op(OP_FEE_FORFEITED, maker, 0, amount, 0, id, 0));
        }
    }

    /// @dev Matched share `fee·used/oldIn` of the paid bid (0 when nothing is paid).
    function _filled(OrderInfo memory o, uint256 used) internal pure returns (uint256) {
        uint256 fee = _paid(o);
        return fee == 0 ? 0 : (fee * used) / o.amountIn;
    }

    function _remMin(OrderInfo memory o, uint256 received) internal pure returns (uint256) {
        return received >= o.amountOutMin ? 0 : o.amountOutMin - received;
    }

    function _closes(OrderInfo memory o, uint256 used, uint256 received) internal pure returns (bool) {
        return o.amountIn - used == 0 || _remMin(o, received) == 0;
    }

    /// @dev `_reduceAfterMatch` on one side: matched fee share, then (closed) the unfilled share and the
    ///      refund of the remaining input to the owner.
    function _reduceOps(
        Trace memory t,
        Case memory c,
        bytes32 id,
        OrderInfo memory o,
        uint256 used,
        uint256 received,
        Currency input
    ) internal view {
        uint256 filled = _filled(o, used);
        _feeOps(t, c, id, o.owner, filled);
        if (_closes(o, used, received)) {
            _feeOps(t, c, id, o.owner, _paid(o) - filled);
            uint256 remIn = o.amountIn - used;
            if (remIn != 0) _escrowLeg(t, input, o.owner, remIn);
        }
    }

    /// @dev The whole `_matchPair` trace for a `true` result (`matchPair_true`): asset leg, quote leg,
    ///      sell reduction, buy reduction, then `AsyncOrdersMatched`.
    function _expected(Case memory c, Run memory r) internal view returns (Op[] memory) {
        Trace memory t = _newTrace();
        _escrowLeg(t, c.k.currency0, r.buy0.owner, r.asset);
        _escrowLeg(t, c.k.currency1, r.sell0.owner, r.quote);
        _reduceOps(t, c, c.sellId, r.sell0, r.asset, r.quote, c.k.currency0);
        _reduceOps(t, c, c.buyId, r.buy0, r.quote, r.asset, c.k.currency1);
        _add(t, Op(OP_MATCHED, address(0), 0, r.asset, r.quote, c.sellId, c.buyId));
        return _done(t);
    }

    function _assertOp(Op memory x, Op memory y, string memory m) internal pure {
        assertEq(x.kind, y.kind, string.concat(m, ": kind"));
        assertEq(x.who, y.who, string.concat(m, ": party"));
        assertEq(x.cur, y.cur, string.concat(m, ": currency"));
        assertEq(x.amount, y.amount, string.concat(m, ": amount"));
        assertEq(x.amount2, y.amount2, string.concat(m, ": amount2"));
        assertEq(x.tag, y.tag, string.concat(m, ": tag"));
        assertEq(x.tag2, y.tag2, string.concat(m, ": tag2"));
    }

    function _assertOps(Op[] memory got, Op[] memory want) internal pure {
        assertEq(got.length, want.length, "trace length");
        for (uint256 i; i < got.length; ++i) {
            _assertOp(got[i], want[i], string.concat("op ", vm.toString(i)));
        }
    }

    /// @dev The first `n` ops of `ops`.
    function _prefix(Op[] memory ops, uint256 n) internal pure returns (Op[] memory p) {
        p = new Op[](n);
        for (uint256 i; i < n; ++i) {
            p[i] = ops[i];
        }
    }

    /// @dev `_reduceAfterMatch`'s partial branch, checked against the state before/after one side's
    ///      reduction; `seq` is `book.nextSequence` before that side's reduction, returned updated.
    function _assertPartial(
        Case memory c,
        bytes32 id,
        OrderInfo memory o0,
        OrderInfo memory o1,
        uint256 used,
        uint256 received,
        uint64 seq
    ) internal view returns (uint64) {
        uint256 u = _paid(o0) - _filled(o0, used);
        assertEq(o1.amountIn, o0.amountIn - used, "amountIn := remIn");
        assertEq(o1.amountOutMin, _remMin(o0, received), "amountOutMin := remainingMinimum");
        assertEq(o1.priorityFee, uint64(u), "priorityFee := uint64(unfilled)");
        assertGe(o1.price, 1, "price key >= 1");
        bool moved = o1.price != o0.price;
        bool rekey = moved || (c.pf && u != o0.priorityFee);
        if (moved) {
            ++seq;
            assertEq(o1.sequence, seq, "fresh sequence = nextSequence + 1");
        } else {
            assertEq(o1.sequence, o0.sequence, "sequence kept");
        }
        if (!rekey) {
            assertEq(o1.priorityKey, o0.priorityKey, "not re-keyed: priorityKey kept");
            assertEq(o1.previous, o0.previous, "not re-keyed: previous kept");
            assertEq(o1.next, o0.next, "not re-keyed: next kept");
        } else if (c.pf) {
            assertEq(
                o1.priorityKey,
                (uint128(u) << 64) | uint128(type(uint64).max - o1.sequence),
                "re-appended with the earned priority key"
            );
        } else {
            (, bytes32 tail, uint32 count) = hook.orderBookLevel(c.pid, o1.isBuy, o1.price);
            assertEq(tail, id, "re-appended as the level's tail");
            assertGe(count, 1, "level holds the order");
        }
        return seq;
    }

    /// @dev One side of `_reduceMatchedOrders`: closed → `orders[id]` deleted and its (single-order)
    ///      level emptied; otherwise the partial-branch writes.
    function _assertSide(
        Case memory c,
        bytes32 id,
        OrderInfo memory o0,
        OrderInfo memory o1,
        uint256 used,
        uint256 received,
        uint64 seq
    ) internal view returns (uint64) {
        if (_closes(o0, used, received)) {
            assertTrue(_isEmpty(o1), "closed: orders[id] deleted");
            (,, uint32 count) = hook.orderBookLevel(c.pid, o0.isBuy, o0.price);
            assertEq(count, 0, "closed: removed from its level");
            return seq;
        }
        return _assertPartial(c, id, o0, o1, used, received, seq);
    }

    /// @dev The sell order reduced by (asset in, quote out), then the buy order by (quote in, asset out).
    function _assertReductions(Case memory c, Run memory r) internal view {
        uint64 seq = _assertSide(c, c.sellId, r.sell0, r.sell1, r.asset, r.quote, r.nextSeq0);
        seq = _assertSide(c, c.buyId, r.buy0, r.buy1, r.quote, r.asset, seq);
        assertEq(r.nextSeq1, seq, "book.nextSequence: one increment per moved price");
    }

    /// @dev `orders[id].isBuy` (bit 0 of word 6) overwritten.
    function _storeIsBuy(PoolId pid, bytes32 id, bool isBuy) internal {
        uint256 w6 = uint256(_orderWord(pid, id, 6));
        _storeWord(pid, id, 6, (w6 & ~uint256(0xff)) | (isBuy ? 1 : 0));
    }

    /// @dev Make the pair a `_matchPair` skip: 0 buy empty, 1 sell empty, 2 sell marked as a buy,
    ///      3 buy marked as a sell.
    function _makeSkip(Case memory c, uint256 mode) internal {
        mode %= 4;
        if (mode == 0) _storeWord(c.pid, c.buyId, 1, 0);
        else if (mode == 1) _storeWord(c.pid, c.sellId, 1, 0);
        else if (mode == 2) _storeIsBuy(c.pid, c.sellId, true);
        else _storeIsBuy(c.pid, c.buyId, false);
    }

    /// @dev Strictly ordered keys (bid > ask): `_crosses` returns without reading the amounts, so
    ///      `matchBook` reaches `_matchPair` whatever the stored amounts are.
    function _strictCross(Case memory c) internal view returns (bool) {
        return _info(c.pid, c.buyId).price > _info(c.pid, c.sellId).price;
    }

    /// @dev Will `matchBook(key, 1)` match the pair, and with which (spec) amounts.
    function _pre(Case memory c) internal view returns (bool matches, uint256 asset, uint256 quote) {
        OrderInfo memory b = _info(c.pid, c.buyId);
        OrderInfo memory sl = _info(c.pid, c.sellId);
        (asset, quote) = _spec(sl.amountIn, sl.amountOutMin, b.amountIn, b.amountOutMin, _makerBuy(b, sl));
        matches = _crossesSpec(b, sl) && asset != 0 && quote != 0;
    }

    function _mockPayoutRevert(Currency cur, address to, uint256 amount, bytes memory reason) internal {
        if (cur.isAddressZero()) {
            vm.mockCallRevert(address(manager), abi.encodeCall(IPoolManager.mint, (to, 0, amount)), reason);
        } else {
            vm.mockCallRevert(address(manager), abi.encodeCall(IPoolManager.take, (cur, to, amount)), reason);
        }
    }

    /// @dev Make one PoolManager call of `_settleTransfers` revert with `reason` (exact calldata):
    ///      1 the asset leg's burn, 2 its payout to the buyer, 3 the quote leg's burn, 4 its payout to the
    ///      seller; 0 nothing.
    function _mockLeg(Case memory c, uint256 asset, uint256 quote, uint256 mode, bytes memory reason) internal {
        if (mode == 1) {
            vm.mockCallRevert(
                address(manager),
                abi.encodeCall(IPoolManager.burn, (address(hook), c.k.currency0.toId(), asset)),
                reason
            );
        } else if (mode == 2) {
            _mockPayoutRevert(c.k.currency0, bob, asset, reason);
        } else if (mode == 3) {
            vm.mockCallRevert(
                address(manager),
                abi.encodeCall(IPoolManager.burn, (address(hook), c.k.currency1.toId(), quote)),
                reason
            );
        } else if (mode == 4) {
            _mockPayoutRevert(c.k.currency1, alice, quote, reason);
        }
    }

    /// @dev The priority-fee settlements of order `id` in `ops`, in order.
    function _feesOf(Op[] memory ops, bytes32 id) internal pure returns (Op[] memory out) {
        out = new Op[](ops.length);
        uint256 n;
        for (uint256 i; i < ops.length; ++i) {
            if ((ops[i].kind == OP_FEE_DONATED || ops[i].kind == OP_FEE_FORFEITED) && ops[i].tag == id) {
                out[n++] = ops[i];
            }
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    /// @dev Mock the PoolManager call behind trace op `o` to revert with `reason`.
    function _mockOpRevert(Op memory o, bytes memory reason) internal {
        bytes memory cd;
        if (o.kind == OP_BURN) cd = abi.encodeCall(IPoolManager.burn, (o.who, o.cur, o.amount));
        else if (o.kind == OP_MINT) cd = abi.encodeCall(IPoolManager.mint, (o.who, o.cur, o.amount));
        else cd = abi.encodeCall(IPoolManager.take, (Currency.wrap(address(uint160(o.cur))), o.who, o.amount));
        vm.mockCallRevert(address(manager), cd, reason);
    }
}
