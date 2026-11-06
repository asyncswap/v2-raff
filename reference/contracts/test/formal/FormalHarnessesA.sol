// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {AsyncMatching} from "@async-swap/libraries/AsyncMatching.sol";
import {RadixPriceTree} from "@async-swap/libraries/RadixPriceTree.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Calls OpenZeppelin's real `Math.mulDiv` (the copy AsyncSwap compiles against).
contract MathMulDivHarness {
    function mulDiv(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return Math.mulDiv(x, y, d);
    }
}

/// @notice Runs the real `RadixPriceTree.insert` / `remove` on its own tree. The setters only write
///         the tree's fields, so a test can start from any tree state (the Lean theorems quantify over
///         every state). The private `_newNode`, `_freeNode`, `_bitSet` and `_mostSignificantBit` are
///         reached through `insert` and `remove`.
contract RadixPriceTreeHarness {
    using RadixPriceTree for RadixPriceTree.Tree;

    /// @dev Slot 0, outside the tree: no tree operation may change it.
    uint256 public sentinel = 0x5e17;
    RadixPriceTree.Tree internal tree;

    function insert(uint128 price) external returns (bool) {
        return tree.insert(price);
    }

    function remove(uint128 price) external {
        tree.remove(price);
    }

    function root() external view returns (uint32) {
        return tree.root;
    }

    function nextNodeId() external view returns (uint32) {
        return tree.nextNodeId;
    }

    function freeIds() external view returns (uint32[] memory) {
        return tree.freeIds;
    }

    function node(uint32 id) external view returns (RadixPriceTree.Node memory) {
        return tree.nodes[id];
    }

    function leaf(uint128 price) external view returns (uint32) {
        return tree.leaves[price];
    }

    function setRoot(uint32 id) external {
        tree.root = id;
    }

    function setNextNodeId(uint32 id) external {
        tree.nextNodeId = id;
    }

    function setFreeIds(uint32[] calldata ids) external {
        tree.freeIds = ids;
    }

    function setNode(uint32 id, RadixPriceTree.Node calldata n) external {
        tree.nodes[id] = n;
    }

    function setLeaf(uint128 price, uint32 id) external {
        tree.leaves[price] = id;
    }
}

/// @notice An `AsyncFiller.State` / `Book` of its own, driven through the real library code:
///         `AsyncFiller._append` (internal, compiled in) and the linked `AsyncMatching.matchBook`
///         (public, reached by DELEGATECALL as the hook reaches it). This reaches the private
///         `AsyncFiller._priorityKey` and `AsyncMatching._crosses`.
contract AsyncBookHarness {
    AsyncFiller.State internal st;
    AsyncFiller.Book internal book;

    function setOrder(bytes32 id, AsyncFiller.OrderInfo calldata o) external {
        st.orders[id] = o;
    }

    function setIsBuy(bytes32 id, bool isBuy) external {
        st.orders[id].isBuy = isBuy;
    }

    function order(bytes32 id) external view returns (AsyncFiller.OrderInfo memory) {
        return st.orders[id];
    }

    function orderSlot(bytes32 id) external view returns (bytes32 s) {
        AsyncFiller.OrderInfo storage o = st.orders[id];
        assembly {
            s := o.slot
        }
    }

    function append(bytes32 id) external {
        AsyncFiller._append(st, book, id);
    }

    function matchBook(PoolKey calldata key, uint8 maxMatches) external returns (uint8) {
        return AsyncMatching.matchBook(st, book, key, maxMatches);
    }

    function crosses(bytes32 bid, bytes32 ask) external view returns (bool) {
        return AsyncMatching._crosses(st.orders[bid].price, st.orders[ask].price, st.orders[bid], st.orders[ask]);
    }
}

/// @notice Independent reference arithmetic for the tests (schoolbook, not OpenZeppelin's algorithm).
abstract contract FormalRefA is Test {
    /// @dev The 512-bit product `a * b` as `(hi, lo)`, from 128-bit limbs.
    function _mul512(uint256 a, uint256 b) internal pure returns (uint256 hi, uint256 lo) {
        uint256 a0 = uint128(a);
        uint256 a1 = a >> 128;
        uint256 b0 = uint128(b);
        uint256 b1 = b >> 128;
        uint256 p00 = a0 * b0;
        uint256 p01 = a0 * b1;
        uint256 p10 = a1 * b0;
        uint256 p11 = a1 * b1;
        uint256 mid = (p00 >> 128) + uint128(p01) + uint128(p10);
        unchecked {
            lo = uint256(uint128(p00)) | (mid << 128);
        }
        hi = p11 + (p01 >> 128) + (p10 >> 128) + (mid >> 128);
    }

    /// @dev `x * y / d < 2^256` (with `d != 0`) iff the high word of `x * y` is below `d`.
    function _quotientFits(uint256 x, uint256 y, uint256 d) internal pure returns (bool) {
        (uint256 hi,) = _mul512(x, y);
        return hi < d;
    }

    /// @dev `r == floor(x * y / d)`: `r * d + (x * y mod d) == x * y` as 512-bit numbers.
    function _isFloorQuotient(uint256 r, uint256 x, uint256 y, uint256 d) internal pure returns (bool) {
        (uint256 phi, uint256 plo) = _mul512(x, y);
        (uint256 qhi, uint256 qlo) = _mul512(r, d);
        uint256 rem = mulmod(x, y, d);
        uint256 lo;
        uint256 carry;
        unchecked {
            lo = qlo + rem;
            carry = lo < qlo ? 1 : 0;
        }
        return lo == plo && qhi + carry == phi;
    }

    /// @dev `Nat.log2 v` (0 for 0), by a downward bit scan.
    function _log2(uint256 v) internal pure returns (uint8) {
        for (uint256 i = 255; i > 0; --i) {
            if ((v >> i) & 1 == 1) return uint8(i);
        }
        return 0;
    }

    function _panic(uint256 code) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Panic(uint256)", code);
    }
}
