// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Vm} from "forge-std/Vm.sol";
import {CurrentHuffDeploy} from "./CurrentHuffDeploy.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// Fixture serialization only: aggregation and external transfers execute production Huff under DELEGATECALL.
library HuffClaimTransfers {
    struct Credit {
        Currency currency;
        address recipient;
        uint256 amount;
    }

    struct Batch {
        Credit[34] credits;
        uint256 count;
    }
    address private constant HARNESS = address(0x48554646434c41494d53);
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function _run(
        uint256 action,
        Batch memory batch,
        IPoolManager manager,
        Currency currency,
        address to,
        uint256 amount
    ) private returns (Batch memory) {
        if (HARNESS.code.length == 0) {
            address deployed = CurrentHuffDeploy.deploy("test/harness/ClaimTransfersHarness.huff", "");
            vm.etch(HARNESS, deployed.code);
        }
        (bool ok, bytes memory ret) = HARNESS.delegatecall(abi.encode(action, manager, currency, to, amount, batch));
        if (!ok) {
            assembly ("memory-safe") { revert(add(ret, 32), mload(ret)) }
        }
        return abi.decode(ret, (Batch));
    }

    function credit(Batch memory batch, IPoolManager manager, Currency currency, address recipient, uint256 amount)
        internal
    {
        Batch memory next = _run(1, batch, manager, currency, recipient, amount);
        batch.count = next.count;
        for (uint256 i; i < 34; ++i) {
            batch.credits[i] = next.credits[i];
        }
    }

    function flush(Batch memory batch, IPoolManager manager) internal {
        _run(2, batch, manager, Currency.wrap(address(0)), address(0), 0);
    }
}
