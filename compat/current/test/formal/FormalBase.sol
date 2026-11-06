// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

/// @notice Shared scaffold for the bytecode checks of Formal Mind's Lean theorems (`formal/Refinement`).
///         Each test in `test/formal/` states one theorem's single-call outcome on the compiled
///         contracts; see `test/formal/README.md` for the theorem → test map.
contract FormalBase is SetupHook {
    address alice = makeAddr("alice"); // maker
    address bob = makeAddr("bob"); // filler

    /// @dev `AsyncSwap` storage layout (`forge inspect AsyncSwap storageLayout`): EIP712's two
    ///      fallback strings, then `asyncOrders`, `priceBooks`, `owner`, `pendingOwner`, `nonceUsed`.
    uint256 constant ASYNC_ORDERS_SLOT = 3;
    uint256 constant PRICE_BOOKS_SLOT = 3;
    uint256 constant OWNER_SLOT = 0;
    uint256 constant PENDING_OWNER_SLOT = 1;
    uint256 constant NONCE_USED_SLOT = 2;

    /// @dev Stored-book unit tests deliberately arrange crossed orders without the Router's
    /// handoff. Select the persisted LP admission branch only while arranging that fixture,
    /// then restore the exact liquidity word before the operation under test. No LP swap runs.
    /// IncomingMemoryReference/Funding exercise the actual funded memory path separately.
    function _storedAdmissionFixture(bytes32 pid) internal returns (bytes32 slot, bytes32 previous) {
        slot = bytes32(uint256(keccak256(abi.encode(pid, uint256(6)))) + 3);
        previous = vm.load(address(manager), slot);
        vm.store(address(manager), slot, bytes32(uint256(previous) | 1));
    }

    function _restoreAdmissionFixture(bytes32 slot, bytes32 previous) internal {
        vm.store(address(manager), slot, previous);
    }

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
        _deployRouter();
        _deployHookLinked();
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

    /// @dev `SetupHook._deployHook` without `vm.getCode`: run `AsyncSwap`'s creation code at the hook's
    ///      flag address, as `deployCodeTo` does. The creation code is embedded in this test contract,
    ///      so its `AsyncMatching` link is resolved by whichever runner deployed it: Forge or Halmos
    ///      (Halmos's `getCode` can't read an artifact with link placeholders).
    function _deployHookLinked() internal {
        // Fixture-only deployment adapter: execute the real Huff constructor at the permission address.
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
            priorityFee: 100_000,
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
                    user: maker, executor: address(router), amountOutMin: amountOutMin, priorityFee: 100_000
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
        if (slot == bytes32(type(uint256).max)) {
            // Symbolic fixture location for Huff's manager immutable, read from deployed bytecode.
            address target = address(hook);
            bytes32 word;
            assembly ("memory-safe") {
                extcodecopy(target, 0, sub(extcodesize(target), 224), 32)
                word := mload(0)
            }
            return word;
        }
        return vm.load(address(hook), slot);
    }
}
