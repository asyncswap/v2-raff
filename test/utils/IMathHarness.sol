// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice `test/harness/MathHarness.huff`.
interface IMathHarness {
    function mulDiv(uint256 x, uint256 y, uint256 d) external pure returns (uint256);
    function mulDivUp(uint256 x, uint256 y, uint256 d) external pure returns (uint256);
    function poolFee(uint256 net) external pure returns (uint256);
    function priceKey(bool buy, uint256 amountIn, uint256 amountOut) external pure returns (uint128);
    function priorityKey(uint64 fee, uint64 sequence) external pure returns (uint128);
    function matchAmounts(uint256 sellIn, uint256 sellMin, uint256 buyIn, uint256 buyMin, bool restingBuy)
        external
        pure
        returns (uint256 asset, uint256 quote);
}
