// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ShortStrings, ShortString} from "@openzeppelin/contracts/utils/ShortStrings.sol";

contract Eip712ConstantsLog is Test {
    function test_log() public pure {
        console2.logBytes32(keccak256("AsyncSwap"));
        console2.logBytes32(keccak256("1"));
        console2.logBytes32(keccak256("AsyncSwap Router"));
        console2.logBytes32(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
        );
        console2.logBytes32(ShortString.unwrap(ShortStrings.toShortString("AsyncSwap")));
        console2.logBytes32(ShortString.unwrap(ShortStrings.toShortString("1")));
        console2.logBytes32(ShortString.unwrap(ShortStrings.toShortString("AsyncSwap Router")));
    }
}
