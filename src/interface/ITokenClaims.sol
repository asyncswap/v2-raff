// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";

interface ITokenClaims {
    error OnlyPoolManager();
    error InvalidRedemption();
    error ReentrantRedemption();
    event ClaimsRedeemed(address indexed owner, address indexed recipient, Currency indexed currency, uint256 amount);
    function poolManager() external view returns (IPoolManager);
    function redeem(Currency currency, address recipient, uint256 amount) external;
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}
