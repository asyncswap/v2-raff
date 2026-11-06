// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HuffNeoDeployer} from "foundry-huff-neo/HuffNeoDeployer.sol";

/// @notice Arithmetic specification for contracts@94400ce, not the old Huff hook's rules.
contract IncomingMathSpec {
    error InvalidInput();

    function matchAmounts(uint256 sellIn, uint256 sellMin, uint256 buyIn, uint256 buyMin, bool makerBuy)
        external
        pure
        returns (uint256 asset, uint256 quote)
    {
        if (sellIn == 0 || sellMin == 0 || buyIn == 0 || buyMin == 0) revert InvalidInput();
        // The maker provides `used`, and receives `paid`; both are bounded by escrow.
        uint256 makerIn = makerBuy ? buyIn : sellIn;
        uint256 makerMin = makerBuy ? buyMin : sellMin;
        uint256 takerIn = makerBuy ? sellIn : buyIn;
        uint256 takerMin = makerBuy ? sellMin : buyMin;
        uint256 used = takerIn >= makerMin ? makerIn : Math.mulDiv(takerIn, makerIn, makerMin);
        if (used == 0) return (0, 0);
        uint256 paid = Math.mulDiv(used, makerMin, makerIn, Math.Rounding.Ceil);
        if (paid > takerIn || used < Math.mulDiv(paid, takerMin, takerIn, Math.Rounding.Ceil)) return (0, 0);
        return makerBuy ? (paid, used) : (used, paid);
    }

    /// @dev Exposed only to verify the shared full-precision primitive, including revert data.
    function mulDiv(uint256 x, uint256 y, uint256 denominator, bool roundUp) external pure returns (uint256) {
        return Math.mulDiv(x, y, denominator, roundUp ? Math.Rounding.Ceil : Math.Rounding.Floor);
    }

    function reduce(uint256 input, uint256 minimum, uint256 fee, uint256 used)
        external
        pure
        returns (uint256 remaining, uint256 remainingMinimum, uint256 spentFee, uint256 remainingFee)
    {
        if (input == 0 || minimum == 0 || fee > type(uint64).max || used > input) revert InvalidInput();
        remaining = input - used;
        remainingMinimum = Math.mulDiv(minimum, remaining, input, Math.Rounding.Ceil);
        spentFee = Math.mulDiv(fee, used, input);
        remainingFee = fee - spentFee;
    }
}

contract IncomingMathTest is Test {
    address internal kernel;
    IncomingMathSpec internal spec;

    function setUp() public {
        bytes memory code = HuffNeoDeployer.config().creation_code("src/experimental/IncomingMath.huff");
        address deployed;
        assembly ("memory-safe") { deployed := create(0, add(code, 0x20), mload(code)) }
        require(deployed != address(0));
        kernel = deployed;
        spec = new IncomingMathSpec();
    }

    function _compare(bytes memory data) internal view returns (bytes memory result) {
        (bool okH, bytes memory h) = kernel.staticcall(data);
        (bool okS, bytes memory s) = address(spec).staticcall(data);
        assertEq(okH, okS, "success/revert parity");
        assertEq(h, s, "return data or exact revert parity");
        return h;
    }

    function _match(uint256 si, uint256 sm, uint256 bi, uint256 bm, bool makerBuy) internal view {
        _compare(abi.encodeCall(spec.matchAmounts, (si, sm, bi, bm, makerBuy)));
    }

    function testFuzz_matchFullUint256(uint256 si, uint256 sm, uint256 bi, uint256 bm, bool makerBuy) public view {
        _match(si, sm, bi, bm, makerBuy);
    }

    function testFuzz_matchBoundedIndependent(uint128 si, uint128 sm, uint128 bi, uint128 bm, bool makerBuy)
        public
        view
    {
        if (si == 0 || sm == 0 || bi == 0 || bm == 0) return;
        bytes memory result = _compare(abi.encodeCall(spec.matchAmounts, (si, sm, bi, bm, makerBuy)));
        (uint256 asset, uint256 quote) = abi.decode(result, (uint256, uint256));
        // Bounded products give a second oracle without the full-precision mulDiv helper.
        uint256 mi = makerBuy ? bi : si;
        uint256 mm = makerBuy ? bm : sm;
        uint256 ti = makerBuy ? si : bi;
        uint256 tm = makerBuy ? sm : bm;
        uint256 used = ti * mi / mm;
        if (used > mi) used = mi;
        uint256 paid = used * mm / mi + (used * mm % mi == 0 ? 0 : 1);
        if (used == 0 || paid > ti || used * ti < paid * tm) {
            assertEq(asset, 0);
            assertEq(quote, 0);
        } else {
            assertEq(asset, makerBuy ? paid : used);
            assertEq(quote, makerBuy ? used : paid);
        }
    }

    function testFuzz_reduceFullUint256(uint256 input, uint256 minimum, uint64 fee, uint256 used) public view {
        // Keep used inside escrow so arbitrary large fuzz inputs exercise arithmetic, not only admission.
        if (input != type(uint256).max) used %= input + 1;
        _compare(abi.encodeCall(spec.reduce, (input, minimum, fee, used)));
    }

    function testFuzz_mulDivPrimitive(uint256 x, uint256 y, uint256 denominator, bool up) public view {
        _compare(abi.encodeCall(spec.mulDiv, (x, y, denominator, up)));
    }

    function test_mulDivExpectedReverts() public view {
        uint256 m = type(uint256).max;
        bytes memory data = abi.encodeCall(spec.mulDiv, (m, m, 1, false));
        _compare(data);
        (bool ok, bytes memory result) = kernel.staticcall(data);
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(Math.MathOverflowedMulDiv.selector));
        // Floor fits exactly at uint256 max, but ceil overflows by one.
        data = abi.encodeCall(spec.mulDiv, (m - 1, m - 1, m - 2, true));
        _compare(data);
        (ok, result) = kernel.staticcall(data);
        assertFalse(ok);
        assertEq(result, abi.encodeWithSignature("Panic(uint256)", 0x11));
        _compare(abi.encodeCall(spec.mulDiv, (1, 1, 0, false)));
        _compare(abi.encodeCall(spec.mulDiv, (m, m, 0, true)));
    }

    function test_fullAffordabilityAvoidsIntermediateOverflow() public view {
        uint256 m = type(uint256).max;
        _match(m, 1, m, 1, false);
        _match(m, 1, m, 1, true);
        (bool ok, bytes memory result) = kernel.staticcall(abi.encodeCall(spec.matchAmounts, (m, 1, m, 1, false)));
        assertTrue(ok);
        (uint256 asset, uint256 quote) = abi.decode(result, (uint256, uint256));
        assertEq(asset, m);
        assertEq(quote, 1);
    }

    function test_uint256BoundaryGrid() public view {
        uint256[8] memory values = [uint256(1), 2, 3, 1 << 127, (1 << 128) - 1, 1 << 128, 1 << 255, type(uint256).max];
        for (uint256 i; i < values.length; ++i) {
            for (uint256 j; j < values.length; ++j) {
                for (uint256 k; k < values.length; ++k) {
                    _match(values[i], values[j], values[k], values[(i + j + k) % values.length], false);
                    _match(values[i], values[j], values[k], values[(i + j + k) % values.length], true);
                }
                _compare(abi.encodeCall(spec.reduce, (values[i], values[j], type(uint64).max, values[i] / 2)));
                _compare(abi.encodeCall(spec.reduce, (values[i], values[j], type(uint64).max, values[i])));
                _compare(abi.encodeCall(spec.reduce, (values[i], values[j], 0, 0)));
            }
        }
    }

    function test_remainderPreservesOriginalLimit() public view {
        bytes memory result = _compare(abi.encodeCall(spec.reduce, (100, 200, 100_000, 25)));
        (uint256 remaining, uint256 minimum, uint256 spentFee, uint256 remainingFee) =
            abi.decode(result, (uint256, uint256, uint256, uint256));
        assertEq(remaining, 75);
        assertEq(minimum, 150);
        assertEq(spentFee, 25_000);
        assertEq(remainingFee, 75_000);
        // A better realized fill price does not enter this calculation.
        _compare(abi.encodeCall(spec.reduce, (3, 2, 5, 1)));
    }

    function test_invalidDomainsRevert() public view {
        _match(0, 1, 1, 1, false);
        _match(1, 0, 1, 1, false);
        _match(1, 1, 0, 1, true);
        _match(1, 1, 1, 0, true);
        _compare(abi.encodeCall(spec.reduce, (0, 1, 0, 0)));
        _compare(abi.encodeCall(spec.reduce, (1, 0, 0, 0)));
        _compare(abi.encodeCall(spec.reduce, (1, 1, uint256(type(uint64).max) + 1, 0)));
        _compare(abi.encodeCall(spec.reduce, (1, 1, 0, 2)));
    }

    function test_gasKernelCalls() public view {
        _gas("match-small", abi.encodeCall(spec.matchAmounts, (1 ether, 2_000e6, 1_000e6, 0.5 ether, false)));
        _gas("match-wide", abi.encodeCall(spec.matchAmounts, (1 << 255, 1 << 200, 1 << 199, 1 << 253, false)));
        _gas("reduce-small", abi.encodeCall(spec.reduce, (2 ether, 4_000e6, 100_000, 1 ether)));
        _gas("reduce-wide", abi.encodeCall(spec.reduce, (type(uint256).max, 1 << 255, type(uint64).max, 1 << 254)));
        console2.log("Huff runtime bytes", kernel.code.length);
        console2.log("Solidity runtime bytes", address(spec).code.length);
    }

    function _gas(string memory name, bytes memory data) private view {
        (bool okH, bytes memory h) = kernel.staticcall(data);
        uint256 huffGas = vm.lastCallGas().gasTotalUsed;
        (bool okS, bytes memory s) = address(spec).staticcall(data);
        uint256 solidityGas = vm.lastCallGas().gasTotalUsed;
        assertTrue(okH);
        assertTrue(okS);
        assertEq(h, s);
        console2.log(name);
        console2.log("Huff callee gas", huffGas);
        console2.log("Solidity callee gas", solidityGas);
    }
}
