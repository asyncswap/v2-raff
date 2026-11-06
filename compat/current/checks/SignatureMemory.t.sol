// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SetupHook} from "../test/SetupHook.t.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

contract AcceptingContractSigner {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }
}

contract CurrentSignatureMemoryTest is SetupHook {
    function test_longContractSignatureCannotActivateIncomingCandidate() public {
        address maker = address(new AcceptingContractSigner());
        topUp(maker, 10 ether);
        vm.prank(maker);
        token0.approve(address(router), type(uint256).max);
        AsyncOrder memory order = AsyncOrder({
            key: key,
            owner: maker,
            zeroForOne: true,
            amountIn: 1 ether,
            amountOutMin: 0.95 ether,
            priorityFee: 100_000,
            sqrtPrice: 2 ** 96,
            salt: bytes32(0)
        });
        vm.prank(maker);
        router.swap(order, abi.encode(maker, address(router), order.amountOutMin, order.priorityFee));
        order.salt = _expectedSalt(maker, order.amountIn, order.amountOutMin);
        bytes32 id = _orderIdFor(maker, true, order.salt);
        uint256 poolSlot = uint256(keccak256(abi.encode(PoolId.unwrap(poolId), uint256(3))));
        bytes32 orderSlot = keccak256(abi.encode(id, poolSlot + 3));

        // ERC-1271's variable buffer starts at 0x1264. A long signature can overlap
        // the candidate flag/slot at 0x2000/0x2020; successful verification must reset the flag.
        bytes memory signature = new bytes(4096);
        assembly ("memory-safe") {
            mstore(add(add(signature, 32), sub(0x2000, 0x1264)), 1)
            mstore(add(add(signature, 32), sub(0x2020, 0x1264)), orderSlot)
        }
        hook.updatePriceWithSig(order, 1 ether, 0.99 ether, 7, block.timestamp + 1 hours, signature);
        (uint256 storedIn, uint256 storedMin) = hook.asyncOrderInfo(poolId, id);
        assertEq(storedIn, 1 ether, "signature buffer must not replace stored input");
        assertEq(storedMin, 0.99 ether, "signed reprice must update persistent order");
        assertTrue(hook.nonceUsed(maker, 7), "signature nonce consumed");
    }
}
