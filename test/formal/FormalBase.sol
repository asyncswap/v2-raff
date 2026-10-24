// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {OrderInfo} from "./OrderInfo.sol";
import {SetupHook} from "../SetupHook.t.sol";
import {IAsyncSwap as AsyncSwap} from "src/interface/IAsyncSwap.sol";
import {AsyncOrder} from "src/interface/types/AsyncOrder.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice Shared scaffold for the bytecode checks of Formal Mind's Lean theorems (`formal/Refinement`).
///         Each test in `test/formal/` states one theorem's single-call outcome on the compiled
///         contracts; see `test/formal/README.md` for the theorem → test map.
contract FormalBase is SetupHook {
    address alice = makeAddr("alice"); // maker
    address bob = makeAddr("bob"); // filler

    /// @dev The Huff hook's storage layout (`src/AsyncSwap.huff`, `src/lib/Book.huff`), under the names of
    ///      `asyncswap/contracts`' Solidity layout: `owner` 0, `pendingOwner` 1, `nonceUsed[maker][nonce]` off
    ///      seed 2, and each pool's state at `P = keccak(poolId, 3)`. The Solidity keeps a pool's `asyncOrders`
    ///      and `priceBooks` entries in two mappings; the Huff keeps both at `P`, with the members the tests
    ///      reach at the same offsets (book header at `P`, orders at `P + 3`, executors at `P + 4`).
    uint256 constant ASYNC_ORDERS_SLOT = 3;
    uint256 constant PRICE_BOOKS_SLOT = 3;
    uint256 constant OWNER_SLOT = 0;
    uint256 constant PENDING_OWNER_SLOT = 1;
    uint256 constant NONCE_USED_SLOT = 2;

    bool private _inOneTx;

    /// @dev Run the test body as one nested call, so it is a single transaction for transient storage.
    ///      With `isolate` (Foundry's default since 1.8) each top-level call a test makes is its own
    ///      transaction, which clears transient storage between, say, a `receive` deposit and the
    ///      `executeOrder` that spends it. On chain those happen inside one transaction. The test is
    ///      re-entered once through `msg.data`; a revert, failed assertion or `vm.assume` comes back up
    ///      unchanged.
    modifier oneTx() {
        if (_inOneTx) {
            _;
        } else {
            _inOneTx = true;
            (bool ok, bytes memory ret) = address(this).call(msg.data);
            _inOneTx = false;
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }

    /// @dev `SetupHook.setUp`, except that the hook is deployed by `_deployHookLinked`.
    function setUp() public virtual override {
        _deployManager();
        _deployTokens();
        _deployHookLinked();
        _deployRouter();
        _createKey();
        _initializePool();
        _mintToOwner();
        topUp(alice, 100 ether);
        topUp(bob, 100 ether);
        vm.prank(alice);
        token0.approve(address(router), type(uint256).max);
        vm.prank(alice);
        token1.approve(address(router), type(uint256).max);
        vm.prank(bob);
        token0.approve(address(router), type(uint256).max);
        vm.prank(bob);
        token1.approve(address(router), type(uint256).max);
    }

    /// @dev `SetupHook.setUp`, under the name the Solidity suite gives its linked-hook deploy.
    function _deployHookLinked() internal {
        _deployHook();
    }

    /// @dev The fixture's hook owner (`SetupHook` deploys the hook with `address(this)` as owner).
    function _hookOwner() internal view returns (address) {
        return hook.owner();
    }

    function _orderFromMaker(address maker, bool zeroForOne, uint256 amountIn, uint256 amountOutMin)
        internal
        view
        returns (AsyncOrder memory)
    {
        return AsyncOrder({
            key: key,
            owner: maker,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            priorityFee: 0,
            sqrtPrice: 2 ** 96,
            salt: bytes32(0)
        });
    }

    /// @dev Submit an order through the Router and return it with the hook-assigned salt, plus its id.
    function _placeOrder(address maker, bool zeroForOne, uint256 amountIn, uint256 amountOutMin)
        internal
        returns (AsyncOrder memory order, bytes32 id)
    {
        order = _orderFromMaker(maker, zeroForOne, amountIn, amountOutMin);
        vm.prank(maker);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: maker, executor: address(router), amountOutMin: amountOutMin, priorityFee: 0
                })
            )
        );
        order.salt = _expectedSalt(maker, amountIn, amountOutMin);
        id = _orderIdFor(maker, zeroForOne, order.salt);
    }

    function _addPoolLiquidity(int128 liquidity) internal returns (PoolModifyLiquidityTest lp) {
        lp = new PoolModifyLiquidityTest(manager);
        token0.mint(address(this), 10_000 ether);
        token1.mint(address(this), 10_000 ether);
        token0.approve(address(lp), type(uint256).max);
        token1.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: liquidity, salt: bytes32(0)}), ""
        );
    }

    /// @dev Snapshot of the hook's whole account storage is not available; tests compare the slots
    ///      a theorem names (`vm.load`) or the public getters before and after a call.
    function _loadHook(bytes32 slot) internal view returns (bytes32) {
        return vm.load(address(hook), slot);
    }

    /* ------------------------- the Huff layout, in the Solidity's terms ------------------------- */

    /// @dev The tests name order-record words by the Solidity `OrderInfo` layout (8 words: owner,
    ///      amountIn, amountOutMin, price, previous, next, {isBuy, zeroForOne, sequence, priorityFee},
    ///      {priorityKey, priorityFeeEscrowed}). The Huff record is 7 words (`src/lib/Book.huff`); these
    ///      translate between the two, so a test reads and writes the same fields it does on the Solidity.
    function _hookOrderBase(PoolId pid, bytes32 id) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(id, uint256(keccak256(abi.encode(pid, ASYNC_ORDERS_SLOT))) + 3)));
    }

    function _orderWordsAt(uint256 o) internal view returns (bytes32[8] memory w) {
        uint256 h0 = uint256(_loadHook(bytes32(o)));
        uint256 h1 = uint256(_loadHook(bytes32(o + 1)));
        w[0] = bytes32(uint256(uint160(h0)));
        w[1] = _loadHook(bytes32(o + 2));
        w[2] = _loadHook(bytes32(o + 3));
        w[3] = bytes32(uint256(uint128(h1)));
        w[4] = _loadHook(bytes32(o + 4));
        w[5] = _loadHook(bytes32(o + 5));
        uint256 seq = uint64(uint256(_loadHook(bytes32(o + 6))));
        w[6] = bytes32(((h0 >> 160) & 1) | (((h0 >> 168) & 1) << 8) | (seq << 16) | (uint256(uint64(h0 >> 184)) << 80));
        w[7] = bytes32((h1 >> 128) | (((h0 >> 176) & 1) << 128));
    }

    function _storeOrderWordsAt(uint256 o, bytes32[8] memory w) internal {
        uint256 w6 = uint256(w[6]);
        uint256 w7 = uint256(w[7]);
        uint256 h0 = uint256(uint160(uint256(w[0]))) | ((w6 & 0xff != 0 ? uint256(1) : 0) << 160)
            | (((w6 >> 8) & 0xff != 0 ? uint256(1) : 0) << 168) | (((w7 >> 128) & 0xff != 0 ? uint256(1) : 0) << 176)
            | (uint256(uint64(w6 >> 80)) << 184);
        vm.store(address(hook), bytes32(o), bytes32(h0));
        vm.store(
            address(hook), bytes32(o + 1), bytes32(uint256(uint128(uint256(w[3]))) | (uint256(uint128(w7)) << 128))
        );
        vm.store(address(hook), bytes32(o + 2), w[1]);
        vm.store(address(hook), bytes32(o + 3), w[2]);
        vm.store(address(hook), bytes32(o + 4), w[4]);
        vm.store(address(hook), bytes32(o + 5), w[5]);
        vm.store(address(hook), bytes32(o + 6), bytes32(uint256(uint64(w6 >> 16))));
    }

    /// @dev Word `i` of the Solidity-shaped record of `id`.
    function _orderWord(PoolId pid, bytes32 id, uint256 i) internal view returns (bytes32) {
        return _orderWordsAt(_hookOrderBase(pid, id))[i];
    }

    /// @dev Set word `i` of the Solidity-shaped record of `id`, leaving the other fields as they are.
    function _storeOrderWord(PoolId pid, bytes32 id, uint256 i, bytes32 v) internal {
        uint256 o = _hookOrderBase(pid, id);
        bytes32[8] memory w = _orderWordsAt(o);
        w[i] = v;
        _storeOrderWordsAt(o, w);
    }

    /// @dev The Huff slot of the record's `amountIn` (Solidity word 1).
    function _amountInSlot(PoolId pid, bytes32 id) internal pure returns (bytes32) {
        return bytes32(_hookOrderBase(pid, id) + 2);
    }

    /// @dev The Huff slots that hold the record of `id` (all of them: one Solidity field can span two).
    function _orderHookSlots(PoolId pid, bytes32 id) internal pure returns (bytes32[] memory s) {
        uint256 o = _hookOrderBase(pid, id);
        s = new bytes32[](7);
        for (uint256 i; i < 7; ++i) {
            s[i] = bytes32(o + i);
        }
    }
}
