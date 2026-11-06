// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {HookUnlockBase} from "./HookUnlockBase.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {MockERC20} from "../utils/MockERC20.sol";

/// @notice Runs the real `AsyncFiller.settleOrderPriorityFee` (internal) on its own `State`, with the harness
///         as the `hook` whose ERC-6909 numeraire claims pay the fee.
contract SettleOrderPriorityFeeHarness {
    AsyncFiller.State internal state;

    constructor(IPoolManager pm, Currency numeraire, address feeVault) {
        state.poolManager = pm;
        state.numeraire = numeraire;
        state.feeVault = feeVault;
    }

    function setOrder(bytes32 id, address owner, uint256 amountIn, uint64 priorityFee, bool) external {
        AsyncFiller.OrderInfo storage o = state.orders[id];
        o.owner = owner;
        o.amountIn = amountIn;
        o.priorityFee = priorityFee;
    }

    function settleOrderPriorityFee(PoolKey calldata key, bytes32 id) external {
        AsyncFiller.settleOrderPriorityFee(state, key, id, address(this));
    }
}

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapSettleOrderPriorityFee.lean` on
///         `SettleOrderPriorityFeeHarness`. With a paid fee the call runs inside an unlock in which the test
///         first gives the harness that many numeraire claims; `settlePriorityFee` then donates it to the
///         pool's LPs (active liquidity) or forfeits it to the FeeVault (none).
contract AsyncSwapSettleOrderPriorityFeeFormalTest is HookUnlockBase {
    using StateLibrary for IPoolManager;

    SettleOrderPriorityFeeHarness h;
    address vault;

    function setUp() public override {
        super.setUp();
        vault = makeAddr("vault");
        h = new SettleOrderPriorityFeeHarness(manager, currency1, vault);
    }

    /// @dev Inside one unlock: mint `fee` numeraire claims to the harness, then settle.
    function _settleCalls(bytes32 id, uint256 fee) internal returns (Call[] memory cs) {
        token1.mint(address(this), fee);
        cs = new Call[](5);
        cs[0] = _c(address(manager), abi.encodeCall(manager.sync, (currency1)));
        cs[1] = _c(address(token1), abi.encodeCall(MockERC20.transfer, (address(manager), fee)));
        cs[2] = _c(address(manager), abi.encodeWithSignature("settle()"));
        cs[3] = _c(address(manager), abi.encodeCall(IPoolManager.mint, (address(h), currency1.toId(), fee)));
        cs[4] = _c(address(h), abi.encodeCall(h.settleOrderPriorityFee, (key, id)));
    }

    /// @dev No-op check: no external call, no harness SSTORE (run outside an unlock: any PoolManager call
    ///      would also revert with ManagerLocked).
    function _assertNoop(bytes32 id) internal {
        vm.expectCall(address(manager), "", 0);
        vm.record();
        h.settleOrderPriorityFee(key, id);
        (, bytes32[] memory writes) = vm.accesses(address(h));
        assertEq(writes.length, 0, "no SSTORE");
    }

    /// @dev `settlePriorityFee(owner, amount)` observed: the donation / forfeit of exactly `amount` for `owner`.
    function _assertSettled(bytes32 id, address owner_, uint256 amount, bool liq) internal {
        uint256 vaultBefore = _claims(vault, currency1);
        Call[] memory cs = _settleCalls(id, amount);
        vm.expectEmit(address(h));
        emit AsyncFiller.PriorityFeeForfeited(poolId, id, owner_, amount);
        _run(cs);
        assertEq(_claims(address(h), currency1), 0, "harness paid exactly amount");
        assertEq(_claims(vault, currency1) - vaultBefore, amount, "priority fees always accrue to the vault");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSettleOrderPriorityFee.lean:32 — behaves exactly as `settlePriorityFee(self, key, id, orders[id].owner, paidPriorityFee(orders[id]), hook)`.
    function testFuzz_settleOrderPriorityFee_run(bytes32 id, address owner_, uint64 fee, bool escrowed, bool liq)
        public
    {
        if (liq) _addPoolLiquidity(1e24);
        h.setOrder(id, owner_, 1, fee, escrowed);
        uint256 paid = fee;
        if (paid == 0) _assertNoop(id);
        else _assertSettled(id, owner_, paid, liq);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSettleOrderPriorityFee.lean:55 — a zero bid (escrowed or not) is a no-op.
    function testFuzz_settleOrderPriorityFee_zero_fee(bytes32 id, address owner_, bool escrowed, uint256 amountIn)
        public
    {
        h.setOrder(id, owner_, amountIn, 0, escrowed);
        _assertNoop(id);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapSettleOrderPriorityFee.lean:68 — with an escrowed bid it settles exactly orders[id].priorityFee for orders[id].owner.
    function testFuzz_settleOrderPriorityFee_escrowed(bytes32 id, address owner_, uint64 fee, bool liq) public {
        fee = uint64(bound(fee, 1, type(uint64).max));
        if (liq) _addPoolLiquidity(1e24);
        h.setOrder(id, owner_, 1, fee, true);
        _assertSettled(id, owner_, fee, liq);
    }
}
