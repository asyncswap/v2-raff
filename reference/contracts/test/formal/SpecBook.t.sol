// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, stdError} from "forge-std/Test.sol";
import {AsyncFillerBookHarness, BookMintEndpoint} from "./AsyncFillerBookHarness.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {RadixPriceTree} from "@async-swap/libraries/RadixPriceTree.sol";

/// @notice `AsyncFillerBookHarness` plus the three `AsyncFiller` functions it doesn't expose:
///         `_append` on its own, and the views `bestAtPrice` / `level` (real library code, linked as in
///         the hook, on the harness's own `pid → Book`).
contract SpecBookHarness is AsyncFillerBookHarness {
    function append(bytes32 pid, bytes32 id) external {
        AsyncFiller._append(pools[pid], books[pid], id);
    }

    function bestAtPrice(bytes32 pid, bool isBuy, uint128 price) external view returns (bytes32) {
        return AsyncFiller.bestAtPrice(books[pid], isBuy, price);
    }

    function libLevel(bytes32 pid, bool isBuy, uint128 price) external view returns (bytes32, bytes32, uint32) {
        return AsyncFiller.level(books[pid], isBuy, price);
    }
}

/// @notice Bytecode checks of the named specs in `formal/Refinement/Swarm/SpecBook.lean` (`RemoveSpec`,
///         `AppendSpec`, `BestAtPriceSpec`, `LevelSpec`) and of the queue theorems proved from them.
///         Each spec field is checked on the real `AsyncFiller._remove` / `_append` / `bestAtPrice` /

///         both sides, up to three price levels a side, with escrowed bids), then
///         perturbed with storage writes for the revert cases. Expected values are computed from the
///         spec's definitions (`removeState`/`removeBook`, `appendState`/`appendBook`, `bestAtPriceOf`,
///         `levelOf`) on the pre-state read back from storage; `Writes` (only the pool's own `State` /
///         `Book` is written) is checked with `vm.accesses` against the slots those definitions name.
contract SpecBookFormalTest is Test {
    SpecBookHarness h;

    bytes32 constant PID = keccak256("formal.specbook.pid");
    uint256 constant MIN_FEE = 100_000;

    // Pre-state snapshots (storage, to keep the stack small).
    bytes32[] internal ids;
    mapping(bytes32 => AsyncFiller.OrderInfo) internal pre;
    bytes32[] internal allowed;

    // The target order and its level / trees before the call.
    AsyncFiller.OrderInfo internal so;
    bytes32 internal sId;
    uint256 internal sWord0;
    bytes32 internal sHd0;
    bytes32 internal sTl0;
    uint32 internal sC0;
    uint32 internal sNext0; // the target level tree's nextNodeId before `_remove`
    uint256 internal sFree0; // ... and its freeIds length
    uint128 internal sKey;
    TreeSnap internal sLt;
    TreeSnap internal sSt;

    struct TreeSnap {
        uint32 root;
        uint32 next;
        uint256 freeLen;
        uint32 leaf; // leaves[key]
        uint32 branch; // nodes[leaf].parent
        uint32 sibling;
        uint256 leafWord;
        uint256 branchWord;
        uint32 gp;
        bool gpLeft; // nodes[gp].left == branch
    }

    function setUp() public {
        vm.etch(address(0xB00C), type(BookMintEndpoint).runtimeCode);
        h = new SpecBookHarness();
    }

    // ================================================================ storage reads

    function _bookWord() internal view returns (uint256) {
        return uint256(vm.load(address(h), h.bookSlot(PID)));
    }

    function _open() internal view returns (uint64) {
        return uint64(_bookWord() >> 64);
    }

    function _sideBase(bool isBuy) internal view returns (bytes32) {
        return bytes32(uint256(h.bookSlot(PID)) + (isBuy ? 1 : 4));
    }

    function _levelBase(bool isBuy, uint128 price) internal view returns (bytes32) {
        return h.levelSlot(PID, isBuy, price);
    }

    function _levelTree(bool isBuy, uint128 price) internal view returns (bytes32) {
        return bytes32(uint256(_levelBase(isBuy, price)) + 1);
    }

    function _idsSlot(bool isBuy, uint128 price, uint256 key) internal view returns (bytes32) {
        return keccak256(abi.encode(key, uint256(_levelBase(isBuy, price)) + 5));
    }

    function _rootOf(bytes32 t) internal view returns (uint32) {
        return uint32(uint256(vm.load(address(h), t)));
    }

    function _nextIdOf(bytes32 t) internal view returns (uint32) {
        return uint32(uint256(vm.load(address(h), t)) >> 32);
    }

    function _freeLen(bytes32 t) internal view returns (uint256) {
        return uint256(vm.load(address(h), bytes32(uint256(t) + 1)));
    }

    function _freeSlot(bytes32 t, uint256 i) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(uint256(t) + 1))) + i / 8);
    }

    function _freeAt(bytes32 t, uint256 i) internal view returns (uint32) {
        return uint32(uint256(vm.load(address(h), _freeSlot(t, i))) >> (32 * (i % 8)));
    }

    function _nodeSlot(bytes32 t, uint256 id) internal pure returns (bytes32) {
        return keccak256(abi.encode(id, uint256(t) + 2));
    }

    function _node(bytes32 t, uint256 id) internal view returns (uint256) {
        return uint256(vm.load(address(h), _nodeSlot(t, id)));
    }

    function _parent(bytes32 t, uint256 id) internal view returns (uint32) {
        return uint32(_node(t, id));
    }

    function _left(bytes32 t, uint256 id) internal view returns (uint32) {
        return uint32(_node(t, id) >> 32);
    }

    function _right(bytes32 t, uint256 id) internal view returns (uint32) {
        return uint32(_node(t, id) >> 64);
    }

    function _nodePrice(bytes32 t, uint256 id) internal view returns (uint128) {
        return uint128(_node(t, id) >> 96);
    }

    function _isLeaf(bytes32 t, uint256 id) internal view returns (bool) {
        return (_node(t, id) >> 232) & 1 == 1;
    }

    function _leafSlot(bytes32 t, uint256 key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, uint256(t) + 3));
    }

    function _leafOf(bytes32 t, uint256 key) internal view returns (uint32) {
        return uint32(uint256(vm.load(address(h), _leafSlot(t, key))));
    }

    function _count(bool isBuy, uint128 price) internal view returns (uint32 c) {
        (,, c) = h.level(PID, isBuy, price);
    }

    function _snap(bytes32 t, uint256 key) internal view returns (TreeSnap memory s) {
        s.root = _rootOf(t);
        s.next = _nextIdOf(t);
        s.freeLen = _freeLen(t);
        s.leaf = _leafOf(t, key);
        s.leafWord = _node(t, s.leaf);
        if (s.leaf != 0 && s.leaf != s.root) {
            s.branch = _parent(t, s.leaf);
            s.branchWord = _node(t, s.branch);
            s.sibling = _left(t, s.branch) == s.leaf ? _right(t, s.branch) : _left(t, s.branch);
            s.gp = _parent(t, s.branch);
            s.gpLeft = _left(t, s.gp) == s.branch;
        }
    }

    // ================================================================ books

    /// @dev Price key of `addOrder(amountIn = k ether, amountOutMin = 1 ether)`: k·1e18 for a bid,
    ///      floor(1e36 / (k·1e18)) for an ask.
    /// @dev The level of a built order with `k` ether in for 1 ether out (`_build` sets `zeroForOne = !isBuy`).
    function _priceFor(bool isBuy, uint256 k) internal pure returns (uint128) {
        return AsyncFiller._priceKey(isBuy, !isBuy, k * 1 ether, 1 ether);
    }

    /// @dev Build paid orders, optionally removing and reinserting some to exercise tree reuse.
    function _build(uint256 seed, uint8 mode, uint256 n) internal {
        h.setPoolFields(PID, address(0), address(0), address(0));
        delete ids;
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            bytes32 id = keccak256(abi.encode(seed, "id", i));
            bool isBuy = r & 1 == 1;
            h.addOrder(
                PID,
                AsyncFiller.NewOrder({
                    id: id,
                    owner: address(uint160(r >> 8)),
                    amountIn: (1 + (r >> 8) % 3) * 1 ether,
                    amountOutMin: 1 ether,
                    isBuy: isBuy,
                    zeroForOne: !isBuy,
                    priorityFee: MIN_FEE + (r >> 16) % 1000,
                    poolId: PoolId.wrap(bytes32(0)) // no minimum is set here, so it is not read
                })
            );
            if (mode == 1 && (r >> 40) & 1 == 1) {
                AsyncFiller.OrderInfo memory o = h.order(PID, id);

                h.setOrder(PID, id, o);
                h.remove(PID, id);
                h.append(PID, id);
            }
            ids.push(id);
        }
    }

    function _snapOrders(bytes32 extra1, bytes32 extra2, bytes32 extra3) internal {
        for (uint256 i; i < ids.length; ++i) {
            pre[ids[i]] = h.order(PID, ids[i]);
        }
        pre[extra1] = h.order(PID, extra1);
        pre[extra2] = h.order(PID, extra2);
        pre[extra3] = h.order(PID, extra3);
    }

    function _eqOrder(AsyncFiller.OrderInfo memory a, AsyncFiller.OrderInfo memory b, string memory m) internal pure {
        assertEq(a.owner, b.owner, m);
        assertEq(a.amountIn, b.amountIn, m);
        assertEq(a.amountOutMin, b.amountOutMin, m);
        assertEq(a.price, b.price, m);

        assertEq(a.isBuy, b.isBuy, m);
        assertEq(a.zeroForOne, b.zeroForOne, m);
        assertEq(a.sequence, b.sequence, m);
        assertEq(a.priorityFee, b.priorityFee, m);
        assertEq(a.priorityKey, b.priorityKey, m);
    }

    // ================================================================ write sets (`Writes`)

    function _allowOrder(bytes32 id) internal {
        bytes32 s = h.orderSlot(PID, id);
        for (uint256 k; k < 8; ++k) {
            allowed.push(bytes32(uint256(s) + k));
        }
    }

    /// @dev Every slot of a tree that a removal or insertion can write: the root word, the free list,
    ///      the nodes up to `nextNodeId + 2` and on the free list, and the given leaf.
    function _allowTree(bytes32 t, uint256 key) internal {
        allowed.push(t);
        allowed.push(bytes32(uint256(t) + 1));
        uint256 len = _freeLen(t);
        for (uint256 i; i < len + 2; ++i) {
            allowed.push(_freeSlot(t, i));
        }
        uint256 nxt = _nextIdOf(t);
        for (uint256 i; i <= nxt + 2; ++i) {
            allowed.push(_nodeSlot(t, i));
        }
        for (uint256 i; i < len; ++i) {
            allowed.push(_nodeSlot(t, _freeAt(t, i)));
        }
        allowed.push(_leafSlot(t, key));
    }

    function _allowLevel(bool isBuy, uint128 price, uint256 key) internal {
        bytes32 b = _levelBase(isBuy, price);
        for (uint256 k; k < 8; ++k) {
            allowed.push(bytes32(uint256(b) + k));
        }
        _allowTree(_levelTree(isBuy, price), key);
        allowed.push(_idsSlot(isBuy, price, key));
        // Exact-price summaries have two words per priority-tree node. Ancestors,
        // freed nodes, and up to two newly allocated nodes may be refreshed.
        uint256 nextId = _nextIdOf(_levelTree(isBuy, price));
        for (uint256 i; i <= nextId + 2; ++i) {
            bytes32 summary = keccak256(abi.encode(i, uint256(b) + 6));
            allowed.push(summary);
            allowed.push(bytes32(uint256(summary) + 1));
        }
    }

    function _assertWritesWithin() internal {
        (, bytes32[] memory writes) = vm.accesses(address(h));
        for (uint256 i; i < writes.length; ++i) {
            bool ok;
            for (uint256 j; j < allowed.length; ++j) {
                if (writes[i] == allowed[j]) {
                    ok = true;
                    break;
                }
            }
            assertTrue(ok, "write outside the pool's State/Book slots the spec names");
        }
        delete allowed;
    }

    function _assertNoWrites() internal {
        (, bytes32[] memory writes) = vm.accesses(address(h));
        assertEq(writes.length, 0, "view wrote storage");
    }

    // Bitmap write footprint: only the leaf word and its two ancestors can change.
    bytes32[3] internal bitmapSlots;
    uint256[3] internal bitmapBefore;
    uint256[3] internal bitmapMasks;

    function _bitmapContains(bytes32 t, uint128 price) internal view returns (bool) {
        bytes32 leaf = keccak256(abi.encode(uint256(price) >> 8, uint256(t) + 2));
        return uint256(vm.load(address(h), leaf)) & (uint256(1) << (price & 255)) != 0;
    }

    function _snapBitmap(bytes32 t, uint128 price) internal {
        uint256 word = uint256(price) >> 8;
        uint256 group = word >> 8;
        bitmapSlots[0] = keccak256(abi.encode(word, uint256(t) + 2));
        bitmapSlots[1] = keccak256(abi.encode(group, uint256(t) + 1));
        bitmapSlots[2] = t;
        bitmapMasks = [uint256(1) << (price & 255), uint256(1) << (word & 255), uint256(1) << group];
        for (uint256 i; i < 3; ++i) {
            bitmapBefore[i] = uint256(vm.load(address(h), bitmapSlots[i]));
        }
    }

    function _allowBitmap(bytes32 t, uint128 price) internal {
        allowed.push(t);
        allowed.push(keccak256(abi.encode(uint256(price) >> 16, uint256(t) + 1)));
        allowed.push(keccak256(abi.encode(uint256(price) >> 8, uint256(t) + 2)));
    }

    function _checkBitmap(bool adding, bool changed) internal view {
        bool propagate = changed;
        for (uint256 i; i < 3; ++i) {
            uint256 old = bitmapBefore[i];
            uint256 want = !propagate ? old : (adding ? old | bitmapMasks[i] : old & ~bitmapMasks[i]);
            assertEq(uint256(vm.load(address(h), bitmapSlots[i])), want, "bitmap word transition");
            propagate = propagate && (adding ? old == 0 : want == 0);
        }
    }

    // ================================================================ _remove

    struct RmIn {
        uint256 seed;
        uint8 n;
        uint8 pick;
        bool prio;
        uint8 kind;
        uint256 junk;
    }

    /// @dev Built book, the target id, then (kind != 0) one storage perturbation.
    function _rmSetup(RmIn memory x, bool perturb) internal returns (bytes32 id) {
        uint256 n = 1 + x.n % 6;
        _build(x.seed, x.prio ? 1 : 0, n);
        id = ids[x.pick % n];
        if (!perturb) return id;
        uint8 kind = x.kind % 7;
        AsyncFiller.OrderInfo memory o = h.order(PID, id);
        if (kind == 1) {} else if (kind == 2) {
            h.setOpenOrderCount(PID, 0);
        } else if (kind == 3) {
            (bytes32 hd, bytes32 tl,) = h.level(PID, o.isBuy, o.price);
            h.setLevel(PID, o.isBuy, o.price, hd, tl, 0);
        } else if (kind == 4) {
            id = keccak256(abi.encode(x.junk, "unknown"));
        } else if (kind == 5) {
            uint128 fresh = uint128(7e18 + x.junk % 1000);
            o.price = fresh;
            h.setOrder(PID, id, o);
            h.setLevel(PID, o.isBuy, fresh, id, id, 1);
        } else if (kind == 6) {
            o.priorityKey = uint128(x.junk);
            h.setOrder(PID, id, o);
        }
    }

    /// @dev `RemoveOk` / `removeErr` on the current storage.
    function _predictRemove(bytes32 id) internal view returns (bool ok, bytes memory err) {
        AsyncFiller.OrderInfo memory o = h.order(PID, id);
        uint32 count = _count(o.isBuy, o.price);
        if (_leafOf(_levelTree(o.isBuy, o.price), o.priorityKey) == 0) {
            return (false, abi.encodeWithSelector(RadixPriceTree.PriceLevelMissing.selector));
        }
        if (count == 0) return (false, stdError.arithmeticError);
        if (_open() == 0) return (false, stdError.arithmeticError);
        if (count == 1 && !_bitmapContains(_sideBase(o.isBuy), o.price)) {
            return (false, abi.encodeWithSelector(RadixPriceTree.PriceLevelMissing.selector));
        }
        return (true, "");
    }

    function testFuzz_RemoveSpec_reverts(RmIn memory x) public {
        bytes32 id = _rmSetup(x, true);
        (bool ok, bytes memory err) = _predictRemove(id);
        if (ok) {
            h.remove(PID, id);
        } else {
            vm.expectRevert(err);
            h.remove(PID, id);
        }
    }

    function testFuzz_RemoveSpec_progress(RmIn memory x) public {
        bytes32 id = _rmSetup(x, false);
        (bool ok,) = _predictRemove(id);
        assertTrue(ok, "RemoveOk on a well-formed book");
        h.remove(PID, id);
    }

    function testFuzz_RemoveSpec_post(RmIn memory x) public {
        bytes32 id = _rmSetup(x, false);
        (bool ok,) = _predictRemove(id);
        assertTrue(ok);
        _snapTarget(id);
        _snapOrders(id, bytes32(0), bytes32(0));
        sKey = so.priorityKey;
        sLt = _snap(_levelTree(so.isBuy, so.price), sKey);
        _snapBitmap(_sideBase(so.isBuy), so.price);
        _allowLevel(so.isBuy, so.price, sKey);
        _allowBitmap(_sideBase(so.isBuy), so.price);
        allowed.push(h.bookSlot(PID));

        vm.record();
        h.remove(PID, id);
        _assertWritesWithin();

        _checkRemoveOrders(id);
        assertEq(_bookWord(), sWord0 - (uint256(1) << 64), "openOrderCount - 1, rest of the word kept");
        if (sC0 == 1) _checkRemoveCleared();
        else _checkRemoveKept();
    }

    function _snapTarget(bytes32 id) internal {
        sId = id;
        so = h.order(PID, id);
        sWord0 = _bookWord();
        (sHd0, sTl0, sC0) = h.level(PID, so.isBuy, so.price);
        bytes32 t = _levelTree(so.isBuy, so.price);
        sNext0 = _nextIdOf(t);
        sFree0 = _freeLen(t);
    }

    /// @dev The emptied level: the side tree's `removeTree`; the level itself is left in place, empty
    ///      (the Lean spec's `clearLevel` still describes the old full delete).
    function _checkRemoveCleared() internal view {
        (bytes32 hd, bytes32 tl, uint32 c) = h.level(PID, so.isBuy, so.price);
        assertEq(hd, bytes32(0));
        assertEq(tl, bytes32(0));
        assertEq(c, 0);
        bytes32 t = _levelTree(so.isBuy, so.price);
        // The emptied level stays in place: its tree is empty, its id counter and free ids are kept
        // for reuse (priority mode frees the removed leaf's id).
        assertEq(_rootOf(t), 0, "level tree root cleared");
        assertEq(_nextIdOf(t), sNext0, "level tree nextNodeId kept");
        assertEq(_freeLen(t), sFree0 + 1, "level tree freeIds kept, plus the freed leaf");

        _checkRemoveTreeNodes(t, sLt, sKey);
        assertEq(h.priorityOrderId(PID, so.isBuy, so.price, sKey), bytes32(0));

        _checkBitmap(false, true);
    }

    /// @dev A level that keeps orders: `remLevel`, side tree untouched.
    function _checkRemoveKept() internal view {
        (,, uint32 c) = h.level(PID, so.isBuy, so.price);
        assertEq(c, sC0 - 1, "orderCount - 1");

        _checkRemoveTree(_levelTree(so.isBuy, so.price), sLt, sKey);
        assertEq(h.priorityOrderId(PID, so.isBuy, so.price, sKey), bytes32(0));

        _checkBitmap(false, false);
    }

    function _checkRemoveOrders(bytes32 id) internal view {
        for (uint256 i; i < ids.length + 1; ++i) {
            bytes32 x = i < ids.length ? ids[i] : id;
            AsyncFiller.OrderInfo memory want = pre[x];

            _eqOrder(h.order(PID, x), want, "removeState");
        }
    }

    /// @dev `removeTree`'s node writes (`leaves[key]` cleared, the sibling re-parented, the
    ///      grandparent's child pointer, the branch and leaf freed).
    function _checkRemoveTreeNodes(bytes32 t, TreeSnap memory s, uint256 key) internal view {
        assertEq(_leafOf(t, key), 0, "leaves[key] cleared");
        assertEq(_node(t, s.leaf), s.leafWord, "freed leaf retained");
        if (s.leaf != s.root) {
            assertEq(_node(t, s.branch), s.branchWord, "freed branch retained");
            assertEq(_parent(t, s.sibling), s.gp, "sibling re-parented");
            if (s.gp != 0) {
                assertEq(s.gpLeft ? _left(t, s.gp) : _right(t, s.gp), s.sibling, "grandparent points at sibling");
            }
        }
    }

    /// @dev `removeTree t key` in full: node writes, root, nextNodeId and the free list.
    function _checkRemoveTree(bytes32 t, TreeSnap memory s, uint256 key) internal view {
        _checkRemoveTreeNodes(t, s, key);
        assertEq(_nextIdOf(t), s.next, "nextNodeId kept");
        if (s.leaf == s.root) {
            assertEq(_rootOf(t), 0, "root removed");
            assertEq(_freeLen(t), s.freeLen + 1);
            assertEq(_freeAt(t, s.freeLen), s.leaf);
        } else {
            assertEq(_rootOf(t), s.gp == 0 ? s.sibling : s.root, "root");
            assertEq(_freeLen(t), s.freeLen + 2);
            assertEq(_freeAt(t, s.freeLen), s.branch);
            assertEq(_freeAt(t, s.freeLen + 1), s.leaf);
        }
    }

    // ================================================================ _append

    struct ApIn {
        uint256 seed;
        uint8 n;
        bool prio;
        bool isBuy;
        uint8 priceKind;
        uint64 seq;
        uint64 fee;
        bool escrowed;
        uint256 junk;
        uint8 kind;
    }

    /// @dev Built book, then a fresh order `id` written with arbitrary links, sequence, fee and key at
    ///      an existing level (priceKind 0..2) or a fresh one, then (kind != 0) one perturbation.
    function _apSetup(ApIn memory x, bool perturb) internal returns (bytes32 id) {
        _build(x.seed, x.prio ? 1 : 0, 1 + x.n % 6);
        id = keccak256(abi.encode(x.seed, "new"));
        uint8 pk = x.priceKind % 4;
        uint128 price = pk < 3 ? _priceFor(x.isBuy, pk + 1) : uint128(1_700_000 + x.junk % 1000);
        h.setOrder(
            PID,
            id,
            AsyncFiller.OrderInfo({
                owner: address(uint160(x.junk)),
                amountIn: x.junk >> 3,
                amountOutMin: x.junk >> 5,
                price: price,
                isBuy: x.isBuy,
                zeroForOne: (x.junk >> 1) & 1 == 1,
                sequence: x.seq,
                reprices: 0,
                priorityFee: x.fee,
                priorityKey: uint128(x.junk >> 11),
                createdSequence: x.seq
            })
        );
        if (!perturb) return id;
        uint8 kind = x.kind % 4;
        if (kind == 1) {} else if (kind == 2) {
            (bytes32 hd, bytes32 tl,) = h.level(PID, x.isBuy, price);
            h.setLevel(PID, x.isBuy, price, hd, tl, type(uint32).max);
        } else if (kind == 3) {
            h.setOpenOrderCount(PID, type(uint64).max);
        }
    }

    function _prioKey(AsyncFiller.OrderInfo memory o) internal pure returns (uint128) {
        uint256 fee = o.priorityFee;
        return uint128((fee % 2 ** 64) * 2 ** 64 + (2 ** 64 - 1 - uint256(o.sequence)));
    }

    function _noZeroFree(bytes32 t) internal view returns (bool) {
        uint256 len = _freeLen(t);
        for (uint256 i; i < len; ++i) {
            if (_freeAt(t, i) == 0) return false;
        }
        return true;
    }

    function testFuzz_AppendSpec_progress(ApIn memory x) public {
        x.prio = false;
        x.priceKind %= 3; // an existing level price
        bytes32 id = _apSetup(x, false);
        AsyncFiller.OrderInfo memory o = h.order(PID, id);
        vm.assume(_count(o.isBuy, o.price) != 0);
        h.append(PID, id);
    }

    function testFuzz_AppendSpec_post_guards(ApIn memory x) public {
        x.kind = 2 + x.kind % 2;
        bytes32 id = _apSetup(x, true);
        (bool s,) = address(h).call(abi.encodeCall(SpecBookHarness.append, (PID, id)));
        assertFalse(s, "succeeded with a full counter");
    }

    function testFuzz_AppendSpec_post(ApIn memory x) public {
        bytes32 id = _apSetup(x, false);
        _presentVariant(id, x.kind % 3);
        _snapTarget(id);
        sKey = _prioKey(so);
        _snapOrders(id, bytes32(0), bytes32(0));
        bytes32 lt = _levelTree(so.isBuy, so.price);
        bytes32 st = _sideBase(so.isBuy);
        sLt = _snap(lt, sKey);
        _snapBitmap(st, so.price);
        assertTrue(_noZeroFree(lt), "no 0 on the priority free list");
        _allowOrder(id);
        _allowOrder(sTl0);
        _allowLevel(so.isBuy, so.price, sKey);
        _allowBitmap(st, so.price);
        allowed.push(h.bookSlot(PID));
        // other keys / prices whose leaves must be kept (the book's orders and one arbitrary key)
        (uint256[] memory oKeys, uint32[] memory oLeaf) = _otherLeaves(lt, false, x.junk);

        vm.record();
        h.append(PID, id);
        _assertWritesWithin();

        assertEq(_bookWord(), sWord0 + (uint256(1) << 64), "openOrderCount + 1, rest of the word kept");
        _checkAppendOrders(id, sKey);
        _checkAppendLevel(id, lt, oKeys, oLeaf);
        _checkBitmap(true, sC0 == 0);
    }

    /// @dev Variants that reach `TreeInserted.present`: (1) the new order's priority key equals a
    ///      resting order's at the same level (same sequence and fee); (2) the level's
    ///      count is zeroed while its price stays in the side's tree.
    function _presentVariant(bytes32 id, uint8 v) internal {
        AsyncFiller.OrderInfo memory o = h.order(PID, id);
        if (v == 1) {
            for (uint256 i; i < ids.length; ++i) {
                AsyncFiller.OrderInfo memory r = h.order(PID, ids[i]);
                if (r.isBuy == o.isBuy && r.price == o.price) {
                    o.sequence = r.sequence;
                    o.priorityFee = r.priorityFee;

                    h.setOrder(PID, id, o);
                    return;
                }
            }
        } else if (v == 2) {
            (bytes32 hd, bytes32 tl,) = h.level(PID, o.isBuy, o.price);
            h.setLevel(PID, o.isBuy, o.price, hd, tl, 0);
        }
    }

    function _otherLeaves(bytes32 t, bool prices, uint256 junk)
        internal
        view
        returns (uint256[] memory keys, uint32[] memory leaves)
    {
        keys = new uint256[](ids.length + 1);
        leaves = new uint32[](ids.length + 1);
        for (uint256 i; i < ids.length; ++i) {
            keys[i] = prices ? pre[ids[i]].price : pre[ids[i]].priorityKey;
            leaves[i] = _leafOf(t, keys[i]);
        }
        keys[ids.length] = junk;
        leaves[ids.length] = _leafOf(t, junk);
    }

    function _checkAppendLevel(bytes32 id, bytes32 lt, uint256[] memory oKeys, uint32[] memory oLeaf) internal view {
        (,, uint32 c) = h.level(PID, so.isBuy, so.price);
        assertEq(c, sC0 + 1, "orderCount + 1");

        assertEq(h.priorityOrderId(PID, so.isBuy, so.price, sKey), id, "priorityOrderIds[k] := id");
        _checkInserted(lt, sLt, sKey, oKeys, oLeaf);
    }

    function _checkAppendOrders(bytes32 id, uint128 k) internal view {
        for (uint256 i; i < ids.length + 1; ++i) {
            bytes32 x = i < ids.length ? ids[i] : id;
            AsyncFiller.OrderInfo memory want = pre[x];

            if (x == id) want.priorityKey = k;

            _eqOrder(h.order(PID, x), want, "appendState");
        }
    }

    /// @dev `TreeInserted t t' k`, with `others` checked on the given keys.
    function _checkInserted(
        bytes32 t,
        TreeSnap memory s,
        uint256 k,
        uint256[] memory others,
        uint32[] memory othersLeaf
    ) internal view {
        if (s.leaf != 0) {
            assertEq(_rootOf(t), s.root, "present: tree kept");
            assertEq(_nextIdOf(t), s.next);
            assertEq(_freeLen(t), s.freeLen);
            assertEq(_leafOf(t, k), s.leaf);
        }
        for (uint256 i; i < others.length; ++i) {
            if (others[i] != k) assertEq(_leafOf(t, others[i]), othersLeaf[i], "other leaves kept");
        }
        assertTrue(_leafOf(t, k) != 0, "added");
    }

    // ================================================================ bestAtPrice / level

    struct RdIn {
        uint256 seed;
        uint8 n;
        bool isBuy;
        uint8 priceKind;
        uint256 junk;
    }

    function _rdSetup(RdIn memory x, uint8 mode) internal returns (uint128 price) {
        _build(x.seed, mode, x.n % 7);
        uint8 pk = x.priceKind % 4;
        price = pk < 3 ? _priceFor(x.isBuy, pk + 1) : uint128(x.junk);
    }

    /// @dev `bestOf T highest` by the walk `BestOrder.firstLeaf` does (books here are small).
    function _bestOf(bytes32 t, bool highest) internal view returns (bool found, uint128 key) {
        uint32 c = _rootOf(t);
        if (c == 0) return (false, 0);
        for (uint256 i; i < 300; ++i) {
            if (_isLeaf(t, c)) return (true, _nodePrice(t, c));
            c = highest ? _right(t, c) : _left(t, c);
        }
        revert("walk too long");
    }

    /// @notice formal/Refinement/Swarm/SpecBook.lean:213 — BestAtPriceSpec.priority: in priority mode bestAtPrice returns priorityOrderIds[key] for the key bestOf(level tree, highest) finds (key 0 on an empty tree) and writes nothing.
    function testFuzz_BestAtPriceSpec_priority(RdIn memory x) public {
        uint128 price = _rdSetup(x, 1);
        (, uint128 key) = _bestOf(_levelTree(x.isBuy, price), true);
        bytes32 want = h.priorityOrderId(PID, x.isBuy, price, key);
        vm.record();
        assertEq(h.bestAtPrice(PID, x.isBuy, price), want);
        _assertNoWrites();
    }

    /// @notice formal/Refinement/Swarm/SpecBook.lean:233 — LevelSpec.priority: in priority mode level returns levelPrio (the ids under the level tree's highest and lowest keys, 0 for an empty tree, and orderCount) and writes nothing.
    function testFuzz_LevelSpec_priority(RdIn memory x) public {
        uint128 price = _rdSetup(x, 1);
        bytes32 t = _levelTree(x.isBuy, price);
        (bool hh, uint128 hk) = _bestOf(t, true);
        (bool ht, uint128 tk) = _bestOf(t, false);
        bytes32 wantHead = hh ? h.priorityOrderId(PID, x.isBuy, price, hk) : bytes32(0);
        bytes32 wantTail = ht ? h.priorityOrderId(PID, x.isBuy, price, tk) : bytes32(0);
        uint32 c = _count(x.isBuy, price);
        vm.record();
        (bytes32 a, bytes32 b, uint32 d) = h.libLevel(PID, x.isBuy, price);
        _assertNoWrites();
        assertEq(a, wantHead);
        assertEq(b, wantTail);
        assertEq(d, c);
    }
}
