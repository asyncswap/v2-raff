// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;
import {HookUnlockBase} from "../formal/HookUnlockBase.sol";
import {AsyncOrder} from "src/interface/types/AsyncOrder.sol";
import {IAsyncSwap} from "src/interface/IAsyncSwap.sol";
import {SwapParams} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {Vm} from "forge-std/Vm.sol";

struct CurrentOrderInfo {
    uint256 amountIn;
    uint256 amountOutMin;
    uint64 priorityFee;
    uint64 sequence;
    uint128 price;
}

abstract contract CurrentHuffHarness is HookUnlockBase {
    using PoolIdLibrary for PoolKey;
    uint8 constant OP_MATCHED = 6;

    struct Op {
        uint8 kind;
        bytes32 tag;
        bytes32 tag2;
        uint256 amount;
        uint256 amount2;
    }

    function _info(PoolId p, bytes32 id) internal view returns (CurrentOrderInfo memory x) {
        (, x.amountIn, x.amountOutMin, x.price,, x.sequence, x.priorityFee) = hook.orderBookOrder(p, id);
    }

    function _rest(PoolKey memory k, address maker, bool z, uint256 a, uint256 q, uint256 f)
        internal
        returns (bytes32 id)
    {
        id = keccak256(abi.encode(block.chainid, k.toId(), maker, z, _saltOf(maker, a, q, f)));
        if (hook.asyncOrder(k.toId(), id) != 0) {
            vm.roll(block.number + 1);
            return _rest(k, maker, z, a, q, f);
        }
        if (!hook.isExecutor(k.toId(), maker, address(this))) {
            vm.prank(maker);
            hook.setExecutor(k.toId(), address(this), true);
        }
        Call[] memory cs = _one(
            _c(
                address(manager),
                abi.encodeCall(
                    manager.swap,
                    (
                        k,
                        SwapParams(z, -int256(a), uint160(2 ** 96)),
                        abi.encode(IAsyncSwap.UserParams(maker, address(this), q, f))
                    )
                )
            )
        );
        Currency input = z ? k.currency0 : k.currency1;
        MockERC20(Currency.unwrap(input)).mint(address(this), a);
        cs = _push(cs, _c(address(manager), abi.encodeCall(manager.sync, (input))));
        cs = _push(cs, _c(Currency.unwrap(input), abi.encodeCall(MockERC20.transfer, (address(manager), a))));
        cs = _push(cs, _c(address(manager), abi.encodeWithSignature("settle()")));
        if (f != 0) {
            token1.mint(address(this), f);
            cs = _cat(cs, _payToHookCalls(currency1, f));
        }
        _run(cs);
        assertEq(hook.asyncOrder(k.toId(), id), a, "resting input");
    }

    function _ops(Vm.Log[] memory logs) internal view returns (Op[] memory ops) {
        uint256 n;
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].emitter == address(hook)
                    && logs[i].topics[0] == keccak256("AsyncOrdersMatched(bytes32,bytes32,bytes32,uint256,uint256)")
            ) n++;
        }
        ops = new Op[](n);
        n = 0;
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].emitter == address(hook)
                    && logs[i].topics[0] == keccak256("AsyncOrdersMatched(bytes32,bytes32,bytes32,uint256,uint256)")
            ) {
                (uint256 a, uint256 q) = abi.decode(logs[i].data, (uint256, uint256));
                ops[n++] = Op(OP_MATCHED, logs[i].topics[2], logs[i].topics[3], a, q);
            }
        }
    }
}
