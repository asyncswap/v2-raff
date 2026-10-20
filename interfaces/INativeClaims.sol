// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/// @notice Redeems the caller's PoolManager native ETH claims (`src/NativeClaims.huff`). Approve it for native
///         claim ID 0 on the PoolManager first.
interface INativeClaims {
    error OnlyPoolManager();
    error InvalidRedemption();
    error ReentrantRedemption();

    event NativeRedeemed(address indexed owner, address indexed recipient, uint256 amount);

    function poolManager() external view returns (IPoolManager);
    function redeem(address recipient, uint256 amount) external;
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}
