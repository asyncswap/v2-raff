// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {AsyncBookHarness, FormalRefA} from "./FormalHarnessesA.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Direct bytecode checks of the real internal AsyncMatching._crosses helper.
///         Isolated arithmetic tests include deliberately invalid orders (zero minimums,
///         overflowing quotients). They do not construct or claim a valid indexed book.
contract AsyncSwapCrossesFormalTest is FormalRefA {
    bytes32 constant BID = keccak256("bid");
    bytes32 constant ASK = keccak256("ask");

    AsyncBookHarness h;
    PoolKey key;

    struct Amounts {
        uint256 bIn;
        uint256 bOut;
        uint256 sIn;
        uint256 sOut;
    }

    function setUp() public {
        h = new AsyncBookHarness();
        key = PoolKey(Currency.wrap(address(1)), Currency.wrap(address(2)), 0x800000, 60, IHooks(address(0)));
    }

    function _order(bool isBuy, uint128 price, uint256 amountIn, uint256 amountOutMin, uint64 seq)
        internal
        pure
        returns (AsyncFiller.OrderInfo memory o)
    {
        o.owner = address(0xA11CE);
        o.amountIn = amountIn;
        o.amountOutMin = amountOutMin;
        o.price = price;
        o.isBuy = isBuy;
        o.sequence = seq;
    }

    function _book(uint128 bk, uint128 sk, Amounts memory a) internal {
        h.setOrder(BID, _order(true, bk, a.bIn, a.bOut, 1));
        h.setOrder(ASK, _order(false, sk, a.sIn, a.sOut, 2));
    }

    /// @dev Runs matchBook once. Returns (reverted, revert data, crosses-was-true).
    function _run() internal returns (bool reverted, bytes memory ret, bool crossed) {
        vm.record();
        bool ok;
        (ok, ret) = address(h).staticcall(abi.encodeCall(h.crosses, (BID, ASK)));
        (, bytes32[] memory writes) = vm.accesses(address(h));
        reverted = !ok;
        assertEq(writes.length, 0, "_crosses writes nothing");
        if (ok) crossed = abi.decode(ret, (bool));
    }

    function _observable(Amounts memory a) internal pure returns (bool) {
        return a.bIn != 0 && a.sIn != 0;
    }

    /// @dev `x * y < 2^256`: the 512-bit product's high word is zero.
    function _productFits(uint256 x, uint256 y) internal pure returns (bool) {
        (uint256 hi,) = _mul512(x, y);
        return hi == 0;
    }

    /// @dev The revert data of `mulDiv(x, y, 0)` (OpenZeppelin 5.0.2): panic 0x12 when the product fits
    ///      one word, `MathOverflowedMulDiv` otherwise (`denominator <= prod1` is checked first).
    function _div0Error(uint256 x, uint256 y) internal pure returns (bytes memory) {
        return _productFits(x, y) ? _panic(0x12) : abi.encodeWithSelector(Math.MathOverflowedMulDiv.selector);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapCrosses.lean:23 — full run: distinct keys return bk > sk; equal
    ///         keys with sell.amountOutMin = 0 revert with panic 0x12 when buy.in * sell.in < 2^256 and with
    ///         MathOverflowedMulDiv otherwise; else return mulDiv(buy.in, sell.in, sell.out) >= buy.out when the
    ///         quotient fits, else revert MathOverflowedMulDiv.
    function testFuzz_crosses_run(uint128 bk, uint128 sk, Amounts memory a, bool sameKey, bool zeroDen) public {
        if (sameKey) sk = bk;
        if (zeroDen) a.sOut = 0;
        _book(bk, sk, a);
        (bool reverted, bytes memory ret, bool crossed) = _run();
        if (bk != sk) {
            assertFalse(reverted, "distinct keys never revert");
            if (_observable(a)) assertEq(crossed, bk > sk);
        } else if (a.sOut == 0) {
            assertTrue(reverted);
            assertEq(ret, _div0Error(a.bIn, a.sIn), "d = 0: panic 0x12 iff the product fits");
        } else if (_quotientFits(a.bIn, a.sIn, a.sOut)) {
            assertFalse(reverted);
            if (_observable(a)) assertEq(crossed, FullMath.mulDiv(a.bIn, a.sIn, a.sOut) >= a.bOut);
        } else {
            assertTrue(reverted);
            assertEq(ret, abi.encodeWithSelector(Math.MathOverflowedMulDiv.selector));
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapCrosses.lean:48 — distinct keys: never reverts, returns
    ///         buyKey > sellKey, whatever the orders hold (zero denominators included).
    function testFuzz_crosses_ne_any(uint128 bk, uint128 sk, Amounts memory a) public {
        vm.assume(bk != sk);
        _book(bk, sk, a);
        (bool reverted,, bool crossed) = _run();
        assertFalse(reverted);
        if (_observable(a)) assertEq(crossed, bk > sk);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapCrosses.lean:57 — equal keys and sell.amountOutMin = 0: reverts
    ///         with panic 0x12 when buy.amountIn * sell.amountIn < 2^256 and with MathOverflowedMulDiv otherwise.
    ///         With `small`, both amounts are below 2^128 so the product fits one word.
    function testFuzz_crosses_reverts_div0(uint128 k, uint256 bIn, uint256 bOut, uint256 sIn, bool small) public {
        if (small) {
            bIn %= 2 ** 128;
            sIn %= 2 ** 128;
        }
        _book(k, k, Amounts(bIn, bOut, sIn, 0));
        (bool reverted, bytes memory ret,) = _run();
        assertTrue(reverted);
        assertEq(ret, _div0Error(bIn, sIn), "d = 0: panic 0x12 iff the product fits");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapCrosses.lean:57 — the former counterexample to crosses_reverts_div0:
    ///         equal keys, sell.amountOutMin = 0 and buy.amountIn * sell.amountIn = 2^256. The product doesn't fit
    ///         one word, so the theorem (and OpenZeppelin 5.0.2's mulDiv, which checks `denominator <= prod1`
    ///         before dividing) says MathOverflowedMulDiv, not panic 0x12.
    function test_crosses_reverts_div0_counterexample() public {
        _book(1, 1, Amounts(2 ** 128, 1, 2 ** 128, 0));
        (bool reverted, bytes memory ret,) = _run();
        assertTrue(reverted);
        assertEq(ret, abi.encodeWithSelector(Math.MathOverflowedMulDiv.selector), "MathOverflowedMulDiv");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapCrosses.lean:66 — equal keys, sell.amountOutMin != 0 and
    ///         buy.amountIn * sell.amountIn / sell.amountOutMin >= 2^256: reverts MathOverflowedMulDiv.
    function testFuzz_crosses_reverts_overflow(uint128 k, Amounts memory a) public {
        vm.assume(a.sOut != 0 && !_quotientFits(a.bIn, a.sIn, a.sOut));
        _book(k, k, a);
        (bool reverted, bytes memory ret,) = _run();
        assertTrue(reverted);
        assertEq(ret, abi.encodeWithSelector(Math.MathOverflowedMulDiv.selector));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapCrosses.lean:78 — with storage-reading getters, a successful
    ///         _crosses leaves the state unchanged.
    function testFuzz_crosses_frame(uint128 bk, uint128 sk, Amounts memory a, bool sameKey) public {
        if (sameKey) sk = bk;
        _book(bk, sk, a);
        _run(); // asserts no SSTORE whenever the call succeeds
    }
}
