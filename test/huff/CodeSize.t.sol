// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {ISignatureTransfer} from "@async-swap/interfaces/ISignatureTransfer.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {HuffDeploy} from "../utils/HuffDeploy.sol";

/// @notice The Huff runtimes stay under EIP-170 (24,576 bytes); the CI's `forge build --sizes` only sees the
///         Solidity in `src/`.
contract CodeSizeTest is Test {
    uint256 constant EIP170 = 24_576;

    function test_huffRuntimesFitEip170() public {
        IPoolManager manager = new PoolManager(address(this));
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        address hook = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            )
        );
        HuffDeploy.hookTo(abi.encode(manager, Currency.wrap(address(usdc)), address(this)), hook);
        address router = address(HuffDeploy.router(manager, AsyncSwap(payable(hook)), ISignatureTransfer(address(0))));
        address vault = address(AsyncSwap(payable(hook)).feeVault());
        address claims = address(HuffDeploy.nativeClaims(manager));
        address engine = address(HuffDeploy.matchingEngine());
        console.log("AsyncSwap      ", hook.code.length);
        console.log("Router         ", router.code.length);
        console.log("FeeVault       ", vault.code.length);
        console.log("NativeClaims   ", claims.code.length);
        console.log("MatchingEngine ", engine.code.length);
        assertLe(hook.code.length, EIP170, "AsyncSwap");
        assertLe(router.code.length, EIP170, "Router");
        assertLe(vault.code.length, EIP170, "FeeVault");
        assertLe(claims.code.length, EIP170, "NativeClaims");
        assertLe(engine.code.length, EIP170, "MatchingEngine");
    }
}
