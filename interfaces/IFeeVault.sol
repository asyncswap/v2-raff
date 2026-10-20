// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @notice Holds and redeems protocol fee claims (`src/FeeVault.huff`); the hook deploys it.
interface IFeeVault {
    error Unauthorized();
    error ZeroAddress();

    event FeesCollected(Currency indexed currency, address indexed recipient, uint256 amount);

    function poolManager() external view returns (IPoolManager);
    function hook() external view returns (address);
    /// @notice The hook's current owner redeems all fees of one currency.
    function collect(Currency currency, address recipient) external;
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}
