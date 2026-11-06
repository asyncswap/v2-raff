// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {HookHelpersCasesB} from "./HookHelpersB.sol";
import {RadixTreeHarnessB} from "./LibHelpersB.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {RadixPriceTree} from "@async-swap/libraries/RadixPriceTree.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapHelpers.lean`. Library internals run on the
///         real library code in a harness (`LibHelpersB.sol`); the private `AsyncFiller._priorityKey`,
///         `AsyncMatching._crosses` / `AsyncFiller._priceKey` are observed on the real hook (stored keys, and whether
///         `matchBook` matches two resting orders), and `RadixPriceTree._bitSet` / `_freeNode` through
///         the library's `insert` / `remove` on a harness tree.
contract AsyncSwapHelpersFormalTest is HookHelpersCasesB {
    // ------------------------------------------------------------ CustomRevert / Address / SafeERC20

    /// @notice formal/Refinement/Swarm/AsyncSwapHelpers.lean:26 — `CustomRevert.bubbleUpAndRevertWith` always reverts, touching no state.
    function testFuzz_bubbleUpAndRevertWith_reverts(bool callOk, bytes memory rd, bytes4 selector, bytes4 context)
        public
    {
        _checkBubble(callOk, rd, selector, context);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapHelpers.lean:33 — `Address._revert` reverts with the return data, or `FailedInnerCall` when it is empty.
    function testFuzz_address_revert_run(bytes memory rd) public {
        _checkRevert(rd);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapHelpers.lean:40 — `verifyCallResultFromTarget` on a failed call reverts exactly like `_revert`.
    function testFuzz_verifyCallResult_fail(bytes memory rd, bool hasCode, uint256 seed) public {
        _checkVerify(false, rd, hasCode, seed);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapHelpers.lean:48 — on a successful call it returns the data unchanged, unless the data is empty and the target has no code (`AddressEmptyCode`).
    function testFuzz_verifyCallResult_ok(bytes memory rd, bool hasCode, uint256 seed) public {
        _checkVerify(true, rd, hasCode, seed);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapHelpers.lean:56 — `functionCallWithValue` reverts `AddressInsufficientBalance` when the balance is below `value`.
    function testFuzz_functionCallWithValue_insufficient(uint256 balance, uint256 value, bool callOk, bytes memory rd)
        public
    {
        balance = bound(balance, 0, type(uint256).max - 1);
        value = bound(value, balance + 1, type(uint256).max);
        _checkFunctionCallWithValue(balance, value, callOk, rd, true, 0, false);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapHelpers.lean:62 — with enough balance, `functionCallWithValue` is the low-level call followed by `verifyCallResultFromTarget`.
    function testFuzz_functionCallWithValue_eq(
        uint256 balance,
        uint256 value,
        bool callOk,
        bytes memory rd,
        bool hasCode,
        uint256 seed
    ) public {
        value = bound(value, 0, balance);
        _checkFunctionCallWithValue(balance, value, callOk, rd, hasCode, seed, false);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapHelpers.lean:69 — `functionCall` is the value-0 low-level call followed by `verifyCallResultFromTarget` (the balance check never fires).
    function testFuzz_functionCall_eq(uint256 balance, bool callOk, bytes memory rd, bool hasCode, uint256 seed)
        public
    {
        _checkFunctionCallWithValue(balance, 0, callOk, rd, hasCode, seed, true);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapHelpers.lean:81 — after the call returns `rd`, `_callOptionalReturn` (via `safeTransferFrom`) succeeds iff `rd` is empty or its first word decodes to true; false reverts `SafeERC20FailedOperation`.
    function testFuzz_callOptionalReturn_after(
        address from,
        address to,
        uint256 value,
        uint8 kind,
        bool b,
        bytes memory rd
    ) public {
        _checkSafeTransferFrom(from, to, value, uint8(bound(kind, 1, 3)), b, rd); // the call returned
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapHelpers.lean:106 — when the inner `functionCall` reverts, `_callOptionalReturn` reverts with the same error.
    function testFuzz_callOptionalReturn_call_reverts(
        address from,
        address to,
        uint256 value,
        bool codeless,
        bytes memory rd
    ) public {
        _checkSafeTransferFrom(from, to, value, codeless ? 4 : 0, false, rd); // token reverts / AddressEmptyCode
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapHelpers.lean:114 — `safeTransferFrom` is `_callOptionalReturn` on the `transferFrom(from, to, value)` calldata (selector 0x23b872dd).
    function testFuzz_safeTransferFrom_eq(address from, address to, uint256 value, uint8 kind, bool b, bytes memory rd)
        public
    {
        _checkSafeTransferFrom(from, to, value, kind, b, rd);
    }

    // ------------------------------------------------------------ ShortStrings / EIP712

    /// @notice formal/Refinement/Swarm/AsyncSwapHelpers.lean:128 — `byteLength` returns the low byte when it is at most 31, otherwise reverts `InvalidShortString`; it never writes.
    function testFuzz_byteLength_run(bytes32 s) public {
        _checkByteLength(s);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapHelpers.lean:134 — a successful `byteLength` returns at most 31 and leaves the state unchanged.
    function testFuzz_byteLength_le(bytes32 s) public {
        _checkByteLength(s);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapHelpers.lean:143 — `_EIP712Name` is `toStringWithFallback(_name, _nameFallback)`: it returns the name and writes nothing.
    function testFuzz_eip712Name_eq(string memory name, string memory version) public {
        _checkEip712(name, version, true);
        _checkDeployedEip712(address(hook), "AsyncSwap", "1");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapHelpers.lean:152 — `_EIP712Version` is `toStringWithFallback(_version, _versionFallback)`: it returns the version and writes nothing.
    function testFuzz_eip712Version_eq(string memory name, string memory version) public {
        _checkEip712(name, version, false);
        _checkDeployedEip712(address(hook), "AsyncSwap", "1");
    }

    // ------------------------------------------------------------ Math

    /// @notice formal/Refinement/Swarm/AsyncSwapHelpers.lean:163 — `Math.unsignedRoundsUp(r)` is `r % 2 == 1` (Ceil and Expand) and never reverts.
    function testFuzz_unsignedRoundsUp_run(uint8 r) public {
        _checkUnsignedRoundsUp(r);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapHelpers.lean:169 — `Math.mulDiv(x, y, d, r)` agrees with `mulDivRnd`: d = 0 panics 0x12 when x * y < 2^256 and reverts `MathOverflowedMulDiv` otherwise, a floor >= 2^256 reverts `MathOverflowedMulDiv`, else the floor plus one (checked) when rounding up with a remainder.
    function testFuzz_mulDiv_rounding_eq(uint256 x, uint256 y, uint256 d, uint8 r, bool zeroD, bool small) public {
        if (small) {
            x = bound(x, 0, type(uint128).max);
            y = bound(y, 0, type(uint128).max);
        }
        if (zeroD) d = 0;
        _checkMulDivRounding(x, y, d, r);
    }

    // ------------------------------------------------------------ AsyncFiller._priorityKey

    /// @notice formal/Refinement/Swarm/AsyncSwapHelpers.lean:195 — for seq <= 2^64 - 1, `_priorityKey(f, s)` returns `(uint128(f) << 64) | (2^64 - 1 - s)` (read back from the stored key; FIFO stores f = 0, PriorityFee the paid bid).
    function testFuzz_priorityKey_run(uint64 fee, uint64 seq, bool priorityMode, bool zeroForOne) public {
        _checkPriorityKey(fee, seq, priorityMode, zeroForOne);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapHelpers.lean:217 — with 64-bit fees and sequences, key1 < key2 iff f1 < f2, or f1 = f2 and s2 < s1 (higher bid first, then FIFO), on two stored keys.
    function testFuzz_priorityKey_lt_iff(uint64 f1, uint64 f2, uint64 seq, bool sameFee, bool zeroForOne) public {
        uint256 fee1 = bound(f1, 100_000, type(uint64).max);
        uint256 fee2 = sameFee ? fee1 : bound(f2, 100_000, type(uint64).max);
        _setNextSequence(uint64(bound(seq, 1, type(uint64).max - 1)));
        bytes32 id1 = _placeWithFee(alice, zeroForOne, 1 ether, 1 ether, fee1);
        bytes32 id2 = _placeWithFee(bob, zeroForOne, 1 ether, 1 ether, fee2);
        uint64 s1 = _sequenceOf(poolId, id1);
        uint64 s2 = _sequenceOf(poolId, id2);
        uint128 k1 = _priorityKeyOf(id1);
        uint128 k2 = _priorityKeyOf(id2);
        assertEq(k1 < k2, fee1 < fee2 || (fee1 == fee2 && s2 < s1), "k1 < k2");
        assertEq(k2 < k1, fee2 < fee1 || (fee1 == fee2 && s1 < s2), "k2 < k1");
    }

    // ------------------------------------------------------------ AsyncMatching._crosses

    /// @notice formal/Refinement/Swarm/AsyncSwapHelpers.lean:242 — different price keys: the buy crosses the sell iff its key is higher (observed as `matchBook` matching the resting pair, or not).
    function testFuzz_crosses_ne(uint256 sIn, uint256 sOut, uint256 bIn, uint256 bOut) public {
        sIn = bound(sIn, 1e6, 1e24);
        sOut = bound(sOut, 1e6, 1e24);
        bIn = bound(bIn, 1e6, 1e24);
        bOut = bound(bOut, 1e6, 1e24);
        (,, uint128 sk, uint128 bk) = _restPair(sIn, sOut, bIn, bOut);
        vm.assume(bk != sk);
        uint8 matched = _matchOne();
        assertEq(matched, bk > sk ? 1 : 0, "matched iff buyKey > sellKey");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapHelpers.lean:250 — equal price keys: the buy crosses iff `b.amountIn * s.amountIn / s.amountOutMin >= b.amountOutMin`.
    function testFuzz_crosses_eq(uint256 sIn, uint256 sOut, uint256 bOut, uint256 bIn) public {
        sIn = bound(sIn, 1e6, 1e24);
        sOut = bound(sOut, sIn / WAD + 1, sIn * 1e6 < 1e24 ? sIn * 1e6 : 1e24);
        uint256 k = _expectedPriceKey(false, sIn, sOut);
        bOut = bound(bOut, 1e18, 1e24);
        // A buy within one tick of the ask's price; keep the ones that share its tick.
        uint256 mid = sOut * bOut / sIn;
        bIn = bound(bIn, mid - mid / 10_000, mid + mid / 10_000);
        vm.assume(_expectedPriceKey(true, bIn, bOut) == k);
        (,, uint128 sk, uint128 bk) = _restPair(sIn, sOut, bIn, bOut);
        assertEq(uint256(sk), k, "sell key");
        assertEq(bk, sk, "equal keys");
        bool crosses = bIn * sIn / sOut >= bOut;
        uint8 matched = _matchOne();
        assertEq(matched, crosses ? 1 : 0, "matched iff the full-precision cross holds");
    }

    // ------------------------------------------------------------ AsyncMatching._priceKey

    /// @notice formal/Refinement/Swarm/AsyncSwapHelpers.lean:279 (stale: was the clamped WAD ratio) — `_priceKey(isBuy, zfo, a, o)` is `TickPrice.key`, the v4 floor tick of the exact limit ordered by numeraire per asset (the stored key of an order a match left partly filled).
    function testFuzz_priceKey_eq(uint256 sIn, uint256 sOut, uint256 bOut, uint256 bIn) public {
        (sIn, sOut, bOut, bIn) = _crossingAmounts(sIn, sOut, bOut, bIn);
        _checkPriceKeyAfterMatch(sIn, sOut, bIn, bOut, false);
    }

    /// @notice A buy left with 1e30 - 1 input for a minimum of 1 saturated the WAD key at 2^128 - 1; its
    ///         ratio is inside the v4 range, so it now has its own tick.
    function test_priceKey_eq_formerHighClamp() public {
        (, bytes32 bidId,,) = _restPair(1, 1, 1e30, 1);
        assertEq(_matchOne(), 1);
        (, uint256 a, uint256 o, uint128 k, bool isBuy,,) = hook.orderBookOrder(poolId, bidId);
        assertTrue(isBuy);
        assertEq(a, 1e30 - 1);
        assertEq(o, 1, "ceil(1 * (1e30 - 1) / 1e30)");
        assertEq(k, _expectedPriceKey(true, a, o), "tick key");
        assertLt(k, MAX_PRICE_KEY, "below the top key");
    }

    /// @notice A sell left with ~6.7e29 input for a minimum of 3 floored the WAD key to 1; its ratio is
    ///         inside the v4 range, so it now has its own tick.
    function test_priceKey_eq_formerLowClamp() public {
        (bytes32 askId,,,) = _restPair(1e30, 3, 1, 1);
        assertEq(_matchOne(), 1);
        (, uint256 a, uint256 o, uint128 k, bool isBuy,,) = hook.orderBookOrder(poolId, askId);
        assertFalse(isBuy);
        assertEq(o, 3, "ceil(3 * remIn / 1e30)");
        assertGt(a, 2 * WAD);
        assertEq(k, _expectedPriceKey(false, a, o), "tick key");
        assertGt(k, 1, "above the bottom key");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapHelpers.lean:296 (stale: was [1, 2^128 - 1]) — the key is always in [1, 2 * MAX_TICK + 1].
    function testFuzz_priceKey_range(uint256 sIn, uint256 sOut, uint256 bOut, uint256 bIn) public {
        (sIn, sOut, bOut, bIn) = _crossingAmounts(sIn, sOut, bOut, bIn);
        _checkPriceKeyAfterMatch(sIn, sOut, bIn, bOut, false);
    }

    /// @dev A resting ask (sIn -> sOut) and a buy (bIn -> bOut) whose ratio is at least the ask's.
    function _crossingAmounts(uint256 sIn, uint256 sOut, uint256 bOut, uint256 bIn)
        internal
        pure
        returns (uint256, uint256, uint256, uint256)
    {
        sIn = bound(sIn, 1, 1e30);
        sOut = bound(sOut, 1, 1e30);
        bOut = bound(bOut, 1, 1e30);
        uint256 minIn = (bOut * sOut + sIn - 1) / sIn;
        if (minIn > 1e32) minIn = 1e32;
        bIn = bound(bIn, minIn, 1e32);
        return (sIn, sOut, bOut, bIn);
    }

    // ------------------------------------------------------------ RadixPriceTree

    /// @notice formal/Refinement/Swarm/AsyncSwapHelpers.lean:312 — `_bitSet(v, b)` tests bit b of v (b < 128): inserting v and v ^ (1 << b) splits at bit b, with the price that has the bit on the right.
    function testFuzz_bitSet_run(uint128 v, uint8 b) public {
        b = uint8(bound(b, 0, 127));
        uint128 u = v ^ (uint128(1) << b);
        RadixTreeHarnessB t = new RadixTreeHarnessB();
        t.insert(v);
        t.insert(u);
        RadixPriceTree.Node memory r = t.node(t.root());
        assertFalse(r.leaf);
        assertEq(r.bit, b, "split at bit b");
        bool set = (v >> b) & 1 == 1;
        assertEq(r.right, set ? t.leaf(v) : t.leaf(u), "bit set -> right");
        assertEq(r.left, set ? t.leaf(u) : t.leaf(v), "bit clear -> left");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapHelpers.lean:324 — `_freeNode(id)` retains node id and pushes id onto freeIds, nothing else (observed through `remove`, which frees the leaf and, below the root, its branch).
    function testFuzz_freeNode_run(uint128[5] memory prices, uint256 pick, bool churn) public {
        RadixTreeHarnessB t = new RadixTreeHarnessB();
        uint128[] memory live = new uint128[](5);
        uint256 n;
        for (uint256 i; i < 5; ++i) {
            if (t.insert(prices[i])) live[n++] = prices[i];
        }
        if (churn && n > 1) {
            t.remove(live[0]); // leaves ids on freeIds for the re-insert to recycle
            t.insert(live[0]);
            t.remove(live[n - 1]);
            --n;
        }
        uint128 p = live[pick % n];
        uint32 leafId = t.leaf(p);
        bool atRoot = leafId == t.root();
        uint32 branchId = t.node(leafId).parent;
        uint32[] memory before = t.freeIds();
        uint32 nextBefore = t.nextNodeId();
        bytes memory leafBefore = abi.encode(t.node(leafId));
        bytes memory branchBefore = abi.encode(t.node(branchId));

        t.remove(p);

        uint32[] memory afterIds = t.freeIds();
        assertEq(afterIds.length, before.length + (atRoot ? 1 : 2), "freeIds grows by the freed ids");
        for (uint256 i; i < before.length; ++i) {
            assertEq(afterIds[i], before[i], "existing freeIds untouched");
        }
        assertEq(afterIds[afterIds.length - 1], leafId, "leaf id pushed");
        assertEq(abi.encode(t.node(leafId)), leafBefore, "freed leaf retained");
        if (!atRoot) {
            assertEq(afterIds[afterIds.length - 2], branchId, "branch id pushed");
            assertEq(abi.encode(t.node(branchId)), branchBefore, "freed branch retained");
        }
        assertEq(t.nextNodeId(), nextBefore, "id counter untouched");
        for (uint256 i; i < n; ++i) {
            if (live[i] == p) continue;
            uint32 id = t.leaf(live[i]);
            assertTrue(id != 0);
            RadixPriceTree.Node memory l = t.node(id);
            assertTrue(l.leaf);
            assertEq(l.price, live[i], "other leaves intact");
        }
    }
}
