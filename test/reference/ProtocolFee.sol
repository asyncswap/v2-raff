// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ProtocolFee
/// @notice The 30 bps protocol fee on full fills.
/// @dev Spec: `AsyncSwapSpec/Fee.lean`. `poolFee(net) = net * 3 / 997`, written in split form so it cannot
///      overflow; it equals `⌊3 · gross / 1000⌋` with `gross = net + fee` (`poolFee_eq_30bps_of_gross`), never
///      exceeds `net` (`poolFee_le_net`), is monotone, and is zero exactly below 333 units.
library ProtocolFee {
    function poolFee(uint256 net) internal pure returns (uint256) {
        return (net / 997) * 3 + ((net % 997) * 3) / 997;
    }

    /// @dev What the filler delivers: the maker's net minimum plus the vault's fee.
    function gross(uint256 net) internal pure returns (uint256) {
        return net + poolFee(net);
    }
}
