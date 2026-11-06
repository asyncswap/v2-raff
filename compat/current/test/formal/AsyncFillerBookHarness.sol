// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;
import {CurrentHuffDeploy} from "compat/current/support/CurrentHuffDeploy.sol";

import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {IncomingMatching} from "@async-swap/libraries/IncomingMatching.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @notice Runs the real `AsyncFiller.addOrder` / `_append` / `_remove` and `IncomingMatching.addOrder`
///         (linked, reached by DELEGATECALL as from the hook) on its own `pid → State` / `pid → Book`
///         mappings, which mirror AsyncSwap's `asyncOrders` / `priceBooks`. Used by the bytecode checks
///         of `formal/Refinement/Swarm/AsyncSwapAddOrder.lean` and `AsyncFillerRemoveQueue.lean`.
contract BookMintEndpoint {
    function mint(address, uint256, uint256) external {}
}

contract AsyncFillerBookHarness {
    constructor() {
        address deployed = CurrentHuffDeploy.deploy("test/harness/AddOrderHarness.huff", "");
        bytes memory runtime = deployed.code;
        // The constructor installs Huff runtime; subsequent test calls never execute Solidity helpers.
        assembly ("memory-safe") { return(add(runtime, 32), mload(runtime)) }
    }

    IPoolManager internal constant mintEndpoint = IPoolManager(address(0xB00C));
    mapping(bytes32 pid => AsyncFiller.State) internal pools;
    mapping(bytes32 pid => AsyncFiller.Book) internal books;

    // ------------------------------------------------------------ the functions under test

    function addOrder(bytes32 pid, AsyncFiller.NewOrder memory o) external {
        AsyncFiller.addOrder(
            pools[pid], books[pid], o.id, o.owner, o.amountIn, o.amountOutMin, o.isBuy, o.zeroForOne, o.priorityFee
        );
    }

    function matchingAddOrder(bytes32 pid, AsyncFiller.NewOrder memory o) external {
        IncomingMatching.addOrder(pools[pid], books[pid], o);
    }

    function remove(bytes32 pid, bytes32 id) external {
        AsyncFiller._remove(pools[pid], books[pid], id);
    }

    /// @dev The theorem's `addWrite` (book `nextSequence := seq`, then `orders[id] := o`) followed by the
    ///      real `_append(id)`: the final state `addOrder_ok` says `addOrder` produces.
    function writeThenAppend(bytes32 pid, bytes32 id, AsyncFiller.OrderInfo memory o, uint64 seq) external {
        books[pid].nextSequence = seq;
        pools[pid].orders[id] = o;
        AsyncFiller._append(pools[pid], books[pid], id);
    }

    /// @dev Evaluate the actual price helper for the theorem's opaque pricing precondition.
    ///      Tick pricing depends on swap direction as well as the numeraire side.
    function priceKey(bool isBuy, bool zeroForOne, uint256 amountIn, uint256 amountOut)
        external
        pure
        returns (uint128)
    {
        return AsyncFiller._priceKey(isBuy, zeroForOne, amountIn, amountOut);
    }

    // ------------------------------------------------------------ state setup

    function setOrder(bytes32 pid, bytes32 id, AsyncFiller.OrderInfo memory o) external {
        pools[pid].orders[id] = o;
    }

    function setLevel(bytes32 pid, bool isBuy, uint128 price, bytes32, bytes32, uint32 count) external {
        AsyncFiller.PriceLevel storage l = isBuy ? books[pid].bidLevels[price] : books[pid].askLevels[price];
        l.orderCount = count;
    }

    function setPriorityOrderId(bytes32 pid, bool isBuy, uint128 price, uint128 k, bytes32 id) external {
        AsyncFiller.PriceLevel storage l = isBuy ? books[pid].bidLevels[price] : books[pid].askLevels[price];
        l.priorityOrderIds[k] = id;
    }

    function setNextSequence(bytes32 pid, uint64 seq) external {
        books[pid].nextSequence = seq;
    }

    function setOpenOrderCount(bytes32 pid, uint64 n) external {
        books[pid].openOrderCount = n;
    }

    function setPoolFields(bytes32 pid, address, address numeraire, address feeVault) external {
        pools[pid].poolManager = mintEndpoint;
        pools[pid].numeraire = Currency.wrap(numeraire);
        pools[pid].feeVault = feeVault;
    }

    function setExecutor(bytes32 pid, address owner, address executor, bool allow) external {
        pools[pid].isExecutor[owner][executor] = allow;
    }

    // ------------------------------------------------------------ views

    function order(bytes32 pid, bytes32 id) external view returns (AsyncFiller.OrderInfo memory) {
        return pools[pid].orders[id];
    }

    function level(bytes32 pid, bool isBuy, uint128 price)
        external
        view
        returns (bytes32 head, bytes32 tail, uint32 count)
    {
        return AsyncFiller.level(books[pid], isBuy, price);
    }

    function priorityOrderId(bytes32 pid, bool isBuy, uint128 price, uint128 k) external view returns (bytes32) {
        AsyncFiller.PriceLevel storage l = isBuy ? books[pid].bidLevels[price] : books[pid].askLevels[price];
        return l.priorityOrderIds[k];
    }

    function poolFields(bytes32 pid) external view returns (address, address, address) {
        AsyncFiller.State storage s = pools[pid];
        return (address(s.poolManager), Currency.unwrap(s.numeraire), s.feeVault);
    }

    function isExecutor(bytes32 pid, address owner, address executor) external view returns (bool) {
        return pools[pid].isExecutor[owner][executor];
    }

    function bookSlot(bytes32 pid) external view returns (bytes32 s) {
        AsyncFiller.Book storage b = books[pid];
        assembly ("memory-safe") {
            s := b.slot
        }
    }

    function orderSlot(bytes32 pid, bytes32 id) external view returns (bytes32 s) {
        AsyncFiller.OrderInfo storage o = pools[pid].orders[id];
        assembly ("memory-safe") {
            s := o.slot
        }
    }

    function levelSlot(bytes32 pid, bool isBuy, uint128 price) external view returns (bytes32 s) {
        AsyncFiller.PriceLevel storage l = isBuy ? books[pid].bidLevels[price] : books[pid].askLevels[price];
        assembly ("memory-safe") {
            s := l.slot
        }
    }
}
