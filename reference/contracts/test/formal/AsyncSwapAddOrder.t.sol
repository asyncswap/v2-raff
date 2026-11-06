// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalSlotsB} from "./FormalSlotsB.sol";
import {AsyncFillerBookHarness, BookMintEndpoint} from "./AsyncFillerBookHarness.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapAddOrder.lean`.
///
///         `AsyncFiller.addOrder` is `internal` and `IncomingMatching.addOrder` is a linked `public` library
///         function, so both run in `AsyncFillerBookHarness` on its own `pid → State` / `pid → Book`
///         storage (the same code the hook runs on `asyncOrders[pid]` / `priceBooks[pid]`). The model
///         leaves `_append` opaque: the theorems describe the storage `addOrder` hands to `_append`.
///         On the bytecode `_append` runs too, so the tests compare against a second harness that
///         writes exactly the theorem's `addState` and then runs the real `_append`
///         (`writeThenAppend`): both must end with identical storage. Fields `_append` never writes are
///         also checked directly.
contract AsyncSwapAddOrderFormalTest is FormalSlotsB {
    AsyncFillerBookHarness a; // runs the function under test
    AsyncFillerBookHarness b; // the theorem's expected state, then `_append`

    bytes32 constant PID = keccak256("formal.addOrder.pid");
    bytes32 constant OTHER = keccak256("formal.addOrder.other");
    uint256 constant MIN_FEE = 100_000; // AsyncFiller.MIN_PRIORITY_FEE
    uint256 constant MAX_FEE = type(uint64).max; // AsyncFiller.MAX_PRIORITY_FEE

    /// @dev Fuzzed inputs and pre-state. The `*Kind` fields steer the raw values towards the guards'
    ///      boundaries; every kind also leaves some runs fully raw.
    struct In {
        bytes32 id;
        address owner;
        uint256 amountIn;
        uint256 amountOutMin;
        bool isBuy;
        bool zeroForOne;
        uint256 fee;
        uint8 idKind;
        uint8 feeKind;
        uint8 amtKind;
        uint8 mode;
        uint64 seq;
        uint8 seqKind;
        uint256 seed;
        uint8 nPre;
    }

    function setUp() public override {
        vm.etch(address(0xB00C), type(BookMintEndpoint).runtimeCode);
        super.setUp();
        a = new AsyncFillerBookHarness();
        b = new AsyncFillerBookHarness();
    }

    // ================================================================ fixture helpers

    function _preId(uint256 seed, uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encode(seed, i));
    }

    function _fee(uint8 kind, uint256 raw) internal pure returns (uint256) {
        kind %= 5;
        if (kind == 0) return 0;
        if (kind == 1) return 1 + raw % (MIN_FEE - 1); // [1, MIN)
        if (kind == 2) return MIN_FEE + raw % (MAX_FEE - MIN_FEE + 1); // [MIN, MAX]
        if (kind == 3) return MAX_FEE + 1 + raw % (type(uint256).max - MAX_FEE); // > MAX
        return raw;
    }

    /// @dev `AsyncFiller.minPriorityFee` on the order's numeraire side: min($0.10, 0.1% of the order).
    function _minFee(AsyncFiller.NewOrder memory o) internal pure returns (uint256) {
        uint256 tiered = (o.isBuy ? o.amountIn : o.amountOutMin) / 1000;
        return tiered < MIN_FEE ? tiered : MIN_FEE;
    }

    function _seq(uint8 kind, uint64 raw) internal pure returns (uint64) {
        kind %= 4;
        if (kind == 0) return raw;
        if (kind == 1) return type(uint64).max - 1; // seq + 1 = 2^64 - 1 still fits
        if (kind == 2) return type(uint64).max; // seq + 1 overflows
        return raw % 1000;
    }

    /// @dev The order `addOrder` is called with. `amtKind` mixes raw amounts (zero divisors, mulDiv
    ///      overflow) with ones at the pre-placed orders' 1:1 ratio (tick zero), so levels are shared.
    function _shape(In memory x) internal pure returns (AsyncFiller.NewOrder memory o) {
        o.id = x.idKind % 4 == 3 && x.nPre % 4 != 0 ? _preId(x.seed, 0) : x.id;
        o.owner = x.owner;
        uint8 k = x.amtKind % 3;
        o.amountIn = k == 0 ? x.amountIn : k == 1 ? 1 ether : 1 + x.amountIn % 1e30;
        o.amountOutMin = k == 0 ? x.amountOutMin : k == 1 ? 1 ether : 1 + x.amountOutMin % 1e30;
        o.isBuy = x.isBuy;
        o.zeroForOne = x.zeroForOne;
        o.priorityFee = _fee(x.feeKind, x.fee);
    }

    /// @dev Same pre-state in `h`: mode, up to 3 resting orders on PID (valid fee for the mode), a pool
    ///      record, an executor grant, an order with the target id in OTHER, then `nextSequence`.
    function _prep(AsyncFillerBookHarness h, In memory x, uint8, bytes32 targetId) internal {
        h.setPoolFields(PID, address(0), address(uint160(x.seed >> 8)), address(uint160(x.seed >> 16)));
        h.setPoolFields(OTHER, address(0), address(0), address(0));
        uint256 n = x.nPre % 4;
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(x.seed, i, "r")));
            h.addOrder(
                PID,
                AsyncFiller.NewOrder({
                    id: _preId(x.seed, i),
                    owner: address(uint160(r)),
                    amountIn: r % 3 == 0 ? 2 ether : 1 ether,
                    amountOutMin: 1 ether,
                    isBuy: (r >> 8) & 1 == 1,
                    zeroForOne: (r >> 9) & 1 == 1,
                    priorityFee: MIN_FEE + (r >> 16) % 1000,
                    poolId: PoolId.wrap(bytes32(0)) // no minimum is set here, so it is not read
                })
            );
        }
        h.setPoolFields(PID, address(uint160(x.seed)), address(uint160(x.seed >> 8)), address(uint160(x.seed >> 16)));
        h.setExecutor(PID, x.owner, address(uint160(x.seed >> 24)), true);
        h.addOrder(
            OTHER,
            AsyncFiller.NewOrder({
                id: targetId,
                owner: address(0xBEEF),
                amountIn: 1 ether,
                amountOutMin: 1 ether,
                isBuy: x.isBuy,
                zeroForOne: x.zeroForOne,
                priorityFee: MIN_FEE,
                poolId: PoolId.wrap(bytes32(0)) // no minimum is set here, so it is not read
            })
        );
        h.setNextSequence(PID, _seq(x.seqKind, x.seq));
    }

    function _setup(In memory x, uint8 mode) internal returns (AsyncFiller.NewOrder memory o) {
        o = _shape(x);
        _prep(a, x, mode, o.id);
        _prep(b, x, mode, o.id);
    }

    function _bookWordOf(AsyncFillerBookHarness h) internal view returns (uint256) {
        return uint256(vm.load(address(h), h.bookSlot(PID)));
    }

    function _nextSeqOf(AsyncFillerBookHarness h) internal view returns (uint64) {
        return uint64(_bookWordOf(h));
    }

    function _panic(uint256 code) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Panic(uint256)", code);
    }

    /// @dev `addOrder_run`'s case split on the pre-state of `a`: the revert data it predicts, or
    ///      `ok = true`. The harness evaluates the current tick-price helper, including direction.
    function _predict(AsyncFiller.NewOrder memory o) internal view returns (bool ok, bytes memory err) {
        uint256 fee = o.priorityFee;
        if (fee != 0 && fee < _minFee(o)) {
            return (false, abi.encodeWithSelector(AsyncFiller.PriorityFeeTooSmall.selector));
        }
        if (fee > MAX_FEE) return (false, abi.encodeWithSelector(AsyncFiller.PriorityFeeTooLarge.selector));
        try a.priceKey(o.isBuy, o.zeroForOne, o.amountIn, o.amountOutMin) {}
        catch (bytes memory e) {
            return (false, e);
        }
        if (uint256(_nextSeqOf(a)) + 1 >= 2 ** 64) return (false, _panic(0x11));
        return (true, "");
    }

    function _call(AsyncFillerBookHarness h, bool viaMatching, AsyncFiller.NewOrder memory o)
        internal
        returns (bool s, bytes memory ret)
    {
        (s, ret) = viaMatching
            ? address(h).call(abi.encodeCall(AsyncFillerBookHarness.matchingAddOrder, (PID, o)))
            : address(h).call(abi.encodeCall(AsyncFillerBookHarness.addOrder, (PID, o)));
    }

    /// @dev The theorem's `newOrder owner aIn aOut isBuy zfo fee p seq`.
    function _newOrder(AsyncFiller.NewOrder memory o, uint128 p, uint64 seq)
        internal
        pure
        returns (AsyncFiller.OrderInfo memory)
    {
        return AsyncFiller.OrderInfo({
            owner: o.owner,
            amountIn: o.amountIn,
            amountOutMin: o.amountOutMin,
            price: p,
            isBuy: o.isBuy,
            zeroForOne: o.zeroForOne,
            sequence: seq,
            reprices: 0,
            priorityFee: uint64(o.priorityFee % 2 ** 64),
            priorityKey: uint128((o.priorityFee << 64) | (2 ** 64 - 1 - uint256(seq))),
            createdSequence: seq
        });
    }

    /// @dev Every slot either harness wrote since `vm.record()` holds the same word in both. The two
    ///      start from identical storage, so this is equality of their whole storage.
    function _assertSameStorage() internal {
        (, bytes32[] memory wa) = vm.accesses(address(a));
        (, bytes32[] memory wb) = vm.accesses(address(b));
        for (uint256 i; i < wa.length; ++i) {
            assertEq(vm.load(address(a), wa[i]), vm.load(address(b), wa[i]), "slot written by addOrder differs");
        }
        for (uint256 i; i < wb.length; ++i) {
            assertEq(vm.load(address(a), wb[i]), vm.load(address(b), wb[i]), "slot written by addState+_append differs");
        }
    }

    /// @dev After a successful call on `a` (pre-state `seq0`): the price key is in [1, 2^128), and `a`'s
    ///      storage equals `_append(addState(...))` built in `b`. Call under `vm.record()`.
    function _assertAddState(AsyncFiller.NewOrder memory o, uint64 seq0) internal returns (uint128 p, uint64 seq) {
        p = a.order(PID, o.id).price;
        assertGe(p, 1, "price key >= 1");
        seq = seq0 + 1;
        b.writeThenAppend(PID, o.id, _newOrder(o, p, seq), seq);
        _assertSameStorage();
    }

    /// @dev These are internal-library boundary cases. Public creation rejects zero amounts.
    ///      A zero numerator clamps, while a zero denominator panics, independently of isBuy.
    function test_addOrder_tickDirectionZeroBoundary() public {
        for (uint256 matching; matching < 2; ++matching) {
            for (uint256 side; side < 2; ++side) {
                In memory x;
                x.id = keccak256(abi.encode("tick-zero", matching, side));
                x.owner = address(0xBEEF);
                x.amountIn = 1 ether;
                x.isBuy = side == 1;
                x.zeroForOne = true;
                x.feeKind = 2;
                _checkRun(x, matching == 1);
                assertEq(a.order(PID, x.id).price, x.isBuy ? 1_774_545 : 1);
                x.zeroForOne = false;
                _checkRun(x, matching == 1);
                // Pricing fails before sequence increment, even at the sequence boundary.
                x.seqKind = 2;
                _checkRun(x, matching == 1);
            }
        }
    }

    /// @dev The old WAD mulDiv overflowed here; tick pricing saturates at the end key.
    function test_addOrder_tickExtremeRatioClamps() public {
        for (uint256 matching; matching < 2; ++matching) {
            In memory x;
            x.id = keccak256(abi.encode("tick-extreme", matching));
            x.owner = address(0xBEEF);
            x.amountIn = type(uint256).max;
            x.amountOutMin = 1;
            x.isBuy = true;
            x.zeroForOne = false;
            x.feeKind = 2;
            _checkRun(x, matching == 1);
            assertEq(a.order(PID, x.id).price, 1_774_545);
        }
    }

    // ================================================================ AsyncFiller.addOrder

    function testFuzz_priorityKey_bidAndSequence(In memory x) public {
        uint8 mode = x.mode % 2;
        x.feeKind = 2;
        x.amtKind = 1;
        AsyncFiller.NewOrder memory o = _setup(x, mode);
        vm.assume(_nextSeqOf(a) < type(uint64).max);
        uint64 seq = _nextSeqOf(a) + 1;
        a.addOrder(PID, o);
        AsyncFiller.OrderInfo memory s = a.order(PID, o.id);
        assertEq(s.sequence, seq);
        assertEq(uint256(s.priorityKey), (o.priorityFee << 64) | (2 ** 64 - 1 - uint256(seq)));
    }

    function _checkRun(In memory x, bool viaMatching) internal {
        AsyncFiller.NewOrder memory o = _setup(x, x.mode % 2);
        (bool ok, bytes memory err) = _predict(o);
        uint64 seq0 = _nextSeqOf(a);
        vm.record();
        (bool s, bytes memory ret) = _call(a, viaMatching, o);
        if (!ok) {
            assertFalse(s, "predicted a revert");
            assertEq(ret, err, "revert data");
            (, bytes32[] memory wa) = vm.accesses(address(a));
            assertEq(wa.length, 0);
            return;
        }
        assertTrue(s, "predicted success");
        _assertAddState(o, seq0);
    }

    function testFuzz_addOrder_run(In memory x) public {
        _checkRun(x, false);
    }

    function _checkFeeTooSmall(In memory x, bool viaMatching) internal {
        x.feeKind = 1; // [1, MIN)
        AsyncFiller.NewOrder memory o = _setup(x, 1);
        vm.assume(o.priorityFee < _minFee(o)); // below the order's tiered minimum
        (bool s, bytes memory ret) = _call(a, viaMatching, o);
        assertFalse(s);
        assertEq(ret, abi.encodeWithSelector(AsyncFiller.PriorityFeeTooSmall.selector));
    }

    /// @notice A nonzero priorityFee below min(MIN_PRIORITY_FEE, 0.1% of the order) reverts PriorityFeeTooSmall; zero is valid.
    function testFuzz_addOrder_feeTooSmall(In memory x) public {
        _checkFeeTooSmall(x, false);
    }

    function _checkFeeTooLarge(In memory x, bool viaMatching) internal {
        x.feeKind = 3;
        AsyncFiller.NewOrder memory o = _setup(x, 1);
        (bool s, bytes memory ret) = _call(a, viaMatching, o);
        assertFalse(s);
        assertEq(ret, abi.encodeWithSelector(AsyncFiller.PriorityFeeTooLarge.selector));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAddOrder.lean:133 — past guards 1-2, priorityFee > 2^64 - 1 reverts PriorityFeeTooLarge.
    function testFuzz_addOrder_feeTooLarge(In memory x) public {
        _checkFeeTooLarge(x, false);
    }

    function _checkSeqOverflow(In memory x, bool viaMatching) internal {
        uint8 mode = x.mode % 2;
        x.feeKind = 2;
        x.seqKind = 2;
        AsyncFiller.NewOrder memory o = _setup(x, mode);
        try a.priceKey(o.isBuy, o.zeroForOne, o.amountIn, o.amountOutMin) {}
        catch {
            vm.assume(false); // hypothesis: _priceKey succeeds
        }
        (bool s, bytes memory ret) = _call(a, viaMatching, o);
        assertFalse(s);
        assertEq(ret, _panic(0x11));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAddOrder.lean:144 — guards passing and _priceKey succeeding, nextSequence = 2^64 - 1 panics 0x11.
    function testFuzz_addOrder_seqOverflow(In memory x) public {
        _checkSeqOverflow(x, false);
    }

    function _checkOk(In memory x, bool viaMatching) internal {
        uint8 mode = x.mode % 2;
        AsyncFiller.NewOrder memory o = _setup(x, mode);
        uint64 seq0 = _nextSeqOf(a);
        vm.record();
        (bool s,) = _call(a, viaMatching, o);
        if (!s) return;
        uint256 fee = o.priorityFee;

        assertTrue(fee == 0 || fee >= _minFee(o), "guard 2 passed");
        assertLe(fee, MAX_FEE, "guard 3 passed");
        assertLt(uint256(seq0) + 1, 2 ** 64, "seq fits uint64");
        // _priceKey succeeded (and is pure, so it left storage alone)
        assertEq(a.order(PID, o.id).price, a.priceKey(o.isBuy, o.zeroForOne, o.amountIn, o.amountOutMin));
        _assertAddState(o, seq0);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAddOrder.lean:167 — success implies the guards passed, _priceKey gave p in [1, 2^128), seq fits uint64, and the final state is _append(addState(...newOrder(p, seq), seq)).
    function testFuzz_addOrder_ok(In memory x) public {
        _checkOk(x, false);
    }

    /// @dev A successful `addOrder` in `mode` (fee valid for it, amounts that price), run on `a` under
    ///      `vm.record()`. `b` is left in the pre-state, so it serves as the "before" snapshot.
    function _succeed(In memory x, uint8 mode) internal returns (AsyncFiller.NewOrder memory o, uint64 seq0) {
        x.feeKind = 2;
        x.amtKind = x.amtKind % 2 == 0 ? 1 : 2;
        x.seqKind = x.seqKind % 2 == 0 ? 0 : 3;
        o = _setup(x, mode);
        vm.assume(_nextSeqOf(a) < type(uint64).max);
        seq0 = _nextSeqOf(a);
        vm.record();
        a.addOrder(PID, o);
    }

    function testFuzz_addState_order(In memory x) public {
        uint8 mode = x.mode % 2;
        (AsyncFiller.NewOrder memory o, uint64 seq0) = _succeed(x, mode);
        AsyncFiller.OrderInfo memory s = a.order(PID, o.id);
        uint64 seq = seq0 + 1;
        assertEq(s.owner, o.owner);
        assertEq(s.amountIn, o.amountIn);
        assertEq(s.amountOutMin, o.amountOutMin);
        assertGe(s.price, 1);
        assertEq(s.isBuy, o.isBuy);
        assertEq(s.zeroForOne, o.zeroForOne);
        assertEq(s.sequence, seq);
        assertEq(uint256(s.priorityFee), o.priorityFee % 2 ** 64);
        assertEq(uint256(s.priorityKey), (o.priorityFee << 64) | (2 ** 64 - 1 - uint256(seq))); // _append re-keys with the paid fee, 0 here

        _assertAddState(o, seq0);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAddOrder.lean:218 — the book's nextSequence becomes seq; openOrderCount, trees and levels are as addOrder found them (until _append).
    function testFuzz_addState_book(In memory x) public {
        (AsyncFiller.NewOrder memory o, uint64 seq0) = _succeed(x, x.mode % 2);
        uint256 wordBefore = _bookWordOf(b);
        assertEq(_nextSeqOf(a), seq0 + 1, "nextSequence = seq");
        assertEq(_bookWordOf(a) >> 128, wordBefore >> 128, "unused header bits unchanged");
        // openOrderCount, bids, asks and the levels: equal to `_append` run on the unchanged book.
        _assertAddState(o, seq0);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAddOrder.lean:227 — every other order of the pool, and its poolManager, numeraire, feeVault and isExecutor, are untouched (before _append).
    function testFuzz_addState_other_order(In memory x) public {
        (AsyncFiller.NewOrder memory o, uint64 seq0) = _succeed(x, x.mode % 2);
        for (uint256 i; i < x.nPre % 4; ++i) {
            bytes32 j = _preId(x.seed, i);
            if (j == o.id) continue;
            AsyncFiller.OrderInfo memory now_ = a.order(PID, j);
            AsyncFiller.OrderInfo memory was = b.order(PID, j);

            assertEq(keccak256(abi.encode(now_)), keccak256(abi.encode(was)), "other order");
        }
        (address pm, address num, address fv) = a.poolFields(PID);
        (address pm0, address num0, address fv0) = b.poolFields(PID);
        assertEq(pm, pm0);
        assertEq(num, num0);
        assertEq(fv, fv0);
        assertTrue(a.isExecutor(PID, x.owner, address(uint160(x.seed >> 24))));
        _assertAddState(o, seq0);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAddOrder.lean:237 — every other pool (orders and book) is untouched.
    function testFuzz_addState_other_pool(In memory x) public {
        (AsyncFiller.NewOrder memory o,) = _succeed(x, x.mode % 2);
        AsyncFiller.OrderInfo memory was = b.order(OTHER, o.id);
        assertEq(keccak256(abi.encode(a.order(OTHER, o.id))), keccak256(abi.encode(was)), "other pool's order");
        assertEq(vm.load(address(a), a.bookSlot(OTHER)), vm.load(address(b), b.bookSlot(OTHER)), "other book word");
        (bytes32 h, bytes32 t, uint32 c) = a.level(OTHER, was.isBuy, was.price);
        (bytes32 h0, bytes32 t0, uint32 c0) = b.level(OTHER, was.isBuy, was.price);
        assertEq(h, h0);
        assertEq(t, t0);
        assertEq(c, c0);
        // no write lands in OTHER's order record, book word or that level
        (, bytes32[] memory wa) = vm.accesses(address(a));
        uint256 os = uint256(a.orderSlot(OTHER, o.id));
        uint256 ls = uint256(a.levelSlot(OTHER, was.isBuy, was.price));
        for (uint256 i; i < wa.length; ++i) {
            uint256 w = uint256(wa[i]);
            assertTrue(w < os || w > os + 7, "write to OTHER's order");
            assertTrue(w < ls || w > ls + 2, "write to OTHER's level");
            assertTrue(wa[i] != a.bookSlot(OTHER), "write to OTHER's book");
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAddOrder.lean:244 — owner, pendingOwner, nonceUsed and the EIP-712 name/version fallbacks are untouched (on the hook, through a real order placement).
    function testFuzz_addState_frame(
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMin,
        address maker,
        uint256 nonce
    ) public {
        bytes32 nonceSlot = _nonceSlot(maker, nonce);
        bytes32[5] memory slots =
            [bytes32(0), bytes32(uint256(1)), bytes32(OWNER_SLOT), bytes32(PENDING_OWNER_SLOT), nonceSlot];
        bytes32[5] memory was;
        for (uint256 i; i < 5; ++i) {
            was[i] = _loadHook(slots[i]);
        }
        vm.record();
        _placeOrder(alice, zeroForOne, bound(amountIn, 1, 50 ether), bound(amountOutMin, 1, 1e30));
        bytes32[] memory w = _hookWrites();
        for (uint256 i; i < 5; ++i) {
            assertEq(_loadHook(slots[i]), was[i]);
            for (uint256 j; j < w.length; ++j) {
                assertTrue(w[j] != slots[i], "frame slot written");
            }
        }
    }

    // ================================================================ IncomingMatching.addOrder

    /// @notice formal/Refinement/Swarm/AsyncSwapAddOrder.lean:255 — IncomingMatching.addOrder(order) behaves exactly as AsyncFiller.addOrder on the NewOrder's fields (same revert data, or same storage).
    function testFuzz_matching_addOrder_eq(In memory x) public {
        AsyncFiller.NewOrder memory o = _setup(x, x.mode % 2);
        vm.record();
        (bool sa, bytes memory ra) = _call(a, false, o);
        (bool sb, bytes memory rb) = _call(b, true, o);
        assertEq(sa, sb, "same outcome");
        assertEq(ra, rb, "same return / revert data");
        _assertSameStorage();
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAddOrder.lean:263 — IncomingMatching.addOrder has addOrder_run's full case split on the NewOrder's fields.
    function testFuzz_matching_addOrder_run(In memory x) public {
        _checkRun(x, true);
    }

    /// @notice IncomingMatching.addOrder rejects nonzero priority bids below the minimum; zero is valid.
    function testFuzz_matching_addOrder_feeTooSmall(In memory x) public {
        _checkFeeTooSmall(x, true);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAddOrder.lean:299 — IncomingMatching.addOrder: past guards 1-2, order.priorityFee > MAX_PRIORITY_FEE reverts PriorityFeeTooLarge.
    function testFuzz_matching_addOrder_feeTooLarge(In memory x) public {
        _checkFeeTooLarge(x, true);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAddOrder.lean:309 — IncomingMatching.addOrder: guards passing and _priceKey succeeding, nextSequence = 2^64 - 1 panics 0x11.
    function testFuzz_matching_addOrder_seqOverflow(In memory x) public {
        _checkSeqOverflow(x, true);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapAddOrder.lean:324 — IncomingMatching.addOrder success implies the guards passed, p in [1, 2^128), seq fits, final state = _append(addState(...)).
    function testFuzz_matching_addOrder_ok(In memory x) public {
        _checkOk(x, true);
    }
}
