// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalBase} from "./FormalBase.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {ImmutableState} from "@async-swap/ImmutableState.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {MockERC20} from "../utils/MockERC20.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapBeforeInitialize.lean`.
contract AsyncSwapBeforeInitializeFormalTest is FormalBase {
    using PoolIdLibrary for PoolKey;

    struct In {
        address caller;
        bool fromManager;
        address sender;
        address c0;
        address c1;
        bool num0;
        bool num1;
        uint24 fee;
        bool dyn;
        int24 ts;
        address hooks;
        uint160 sp;
    }

    uint24 constant DYN = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    bytes4 constant SEL = 0xdc98354e;

    function _key(address c0, address c1, uint24 fee, int24 ts, address hooks) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(c0), currency1: Currency.wrap(c1), fee: fee, tickSpacing: ts, hooks: IHooks(hooks)
        });
    }

    function _num() internal view returns (address) {
        return Currency.unwrap(hook.numeraire());
    }

    /// @dev Build a key from raw fuzz inputs; the bools let the fuzzer reach the guarded branches
    ///      without excluding any raw value.
    function _steeredKey(address c0, address c1, bool num0, bool num1, uint24 fee, bool dyn, int24 ts, address hooks)
        internal
        view
        returns (PoolKey memory)
    {
        return _key(num0 ? _num() : c0, num1 ? _num() : c1, dyn ? DYN : fee, ts, hooks);
    }

    /// @dev The asset leg (the non-numeraire currency) must be native or have code (L-02 fix).
    function _assetOk(PoolKey memory k) internal view returns (bool) {
        address asset =
            Currency.unwrap(k.currency0) == _num() ? Currency.unwrap(k.currency1) : Currency.unwrap(k.currency0);
        return asset == address(0) || asset.code.length != 0;
    }

    /// @dev Give a fuzzed asset address code, so success-path checks exercise a deployed token.
    function _deployed(address asset) internal returns (address) {
        // Precompiles cannot be etched; they have no code, so the hook rejects them as assets anyway.
        vm.assume(asset != address(vm) && (asset == address(0) || uint160(asset) > 0x100));
        if (asset != address(0) && asset.code.length == 0) vm.etch(asset, hex"00");
        return asset;
    }

    function _guards(address caller, PoolKey memory k) internal view returns (bool) {
        return caller == address(manager)
            && (Currency.unwrap(k.currency0) == _num() || Currency.unwrap(k.currency1) == _num()) && k.fee == DYN
            && _assetOk(k);
    }

    function _base(PoolKey memory k) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(PoolId.unwrap(k.toId()), uint256(2))));
    }

    function _call(address caller, address sender, PoolKey memory k, uint160 sp)
        internal
        returns (bool ok, bytes memory ret)
    {
        vm.prank(caller);
        (ok, ret) = address(hook).call(abi.encodeCall(hook.beforeInitialize, (sender, k, sp)));
    }

    /// @dev `priceBooks[key.toId()].minOrder`: `priceBooks` is slot 3, `minOrder` word 9 of a bitmap `Book`.
    function _minOrderSlot(PoolKey memory k) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(PoolId.unwrap(k.toId()), uint256(3)))) + 9;
    }

    function _priorityCapSlot(PoolKey memory k) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(PoolId.unwrap(k.toId()), uint256(3))));
    }

    /// @dev Assert the post-state the theorem names: the three fields of `asyncOrders[key.toId()]`
    ///      hold (poolManager, numeraire, feeVault), the pool's minimum order is the hook's
    ///      `minOrder`, its asset floor is `minAssetAmount`, and these slots are the only hook writes.
    function _assertWrites(PoolKey memory k) internal {
        (, bytes32[] memory writes) = vm.accesses(address(hook));
        uint256 b = _base(k);
        uint256 m = _minOrderSlot(k);
        uint256 p = _priorityCapSlot(k);
        uint256 a = m + 1; // Book.minAssetAmount follows minOrder
        for (uint256 i; i < writes.length; ++i) {
            uint256 s = uint256(writes[i]);
            assertTrue(
                s == b || s == b + 1 || s == b + 2 || s == m || s == p || s == a,
                "write outside asyncOrders[id].{pm,num,vault}, minOrder, priority cap, asset floor"
            );
        }
        assertEq(uint256(_loadHook(bytes32(a))), hook.minAssetAmount(k.toId()), "asset floor");
        assertEq(uint256(_loadHook(bytes32(m))), hook.minOrder(), "minOrder := hook.minOrder");
        assertEq(uint64(uint256(_loadHook(bytes32(p))) >> 128), hook.priorityFeeCap(), "priority cap");
        assertEq(address(uint160(uint256(_loadHook(bytes32(b))))), address(manager), "poolManager");
        assertEq(address(uint160(uint256(_loadHook(bytes32(b + 1))))), _num(), "numeraire");
        assertEq(address(uint160(uint256(_loadHook(bytes32(b + 2))))), address(hook.feeVault()), "feeVault");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeInitialize.lean:52 — a non-PoolManager caller reverts `NotPoolManager`.
    function testFuzz_beforeInitialize_notPoolManager(
        address caller,
        address sender,
        address c0,
        address c1,
        uint24 fee,
        int24 ts,
        address hooks,
        uint160 sp
    ) public {
        vm.assume(caller != address(manager));
        PoolKey memory k = _key(c0, c1, fee, ts, hooks);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        vm.prank(caller);
        hook.beforeInitialize(sender, k, sp);
    }

    /// @notice Pool creation is permissionless: from the PoolManager, any sender opens a valid key.
    function testFuzz_beforeInitialize_anySender(
        address sender,
        address other,
        bool numIs0,
        int24 ts,
        address hooks,
        uint160 sp
    ) public {
        vm.assume(sender != hook.owner());
        other = _deployed(other);
        PoolKey memory k = _key(numIs0 ? _num() : other, numIs0 ? other : _num(), DYN, ts, hooks);
        (bool ok,) = _call(address(manager), sender, k, sp);
        assertTrue(ok, "a non-owner opens the pool");
    }

    /// @notice L-02 fix: a pool whose asset has no code yet cannot be opened, so nobody can squat a token's pool
    ///         before it is deployed and pin its asset floor at 1 unit.
    function testFuzz_beforeInitialize_rejectsCodelessAsset(
        address sender,
        address other,
        bool numIs0,
        int24 ts,
        uint160 sp
    ) public {
        vm.assume(other != address(0) && other.code.length == 0 && other != _num());
        PoolKey memory k = _key(numIs0 ? _num() : other, numIs0 ? other : _num(), DYN, ts, address(hook));
        vm.prank(address(manager));
        vm.expectRevert(AsyncSwap.AssetHasNoCode.selector);
        hook.beforeInitialize(sender, k, sp);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeInitialize.lean:58 — from the PoolManager, a key with no numeraire leg reverts `NumeraireRequired`.
    function testFuzz_beforeInitialize_numeraireRequired(
        address sender,
        address c0,
        address c1,
        uint24 fee,
        int24 ts,
        address hooks,
        uint160 sp
    ) public {
        vm.assume(c0 != _num() && c1 != _num());
        PoolKey memory k = _key(c0, c1, fee, ts, hooks);
        vm.expectRevert(AsyncSwap.NumeraireRequired.selector);
        vm.prank(address(manager));
        hook.beforeInitialize(sender, k, sp);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeInitialize.lean:67 — from the PoolManager, with a numeraire leg but a static fee, reverts `DynamicFeeRequired`.
    function testFuzz_beforeInitialize_dynamicFeeRequired(
        address sender,
        address other,
        bool numIs0,
        bool bothNum,
        uint24 fee,
        int24 ts,
        address hooks,
        uint160 sp
    ) public {
        vm.assume(fee != DYN);
        address c0 = numIs0 || bothNum ? _num() : other;
        address c1 = !numIs0 || bothNum ? _num() : other;
        PoolKey memory k = _key(c0, c1, fee, ts, hooks);
        vm.expectRevert(AsyncSwap.DynamicFeeRequired.selector);
        vm.prank(address(manager));
        hook.beforeInitialize(sender, k, sp);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeInitialize.lean:78 — under the guards, returns exactly `0xdc98354e` and the world is the three writes of `asyncOrders[key.toId()]`.
    function testFuzz_beforeInitialize_run_ok(
        address sender,
        address other,
        bool numIs0,
        int24 ts,
        address hooks,
        uint160 sp
    ) public {
        other = _deployed(other);
        PoolKey memory k = _key(numIs0 ? _num() : other, numIs0 ? other : _num(), DYN, ts, hooks);
        vm.record();
        (bool ok, bytes memory ret) = _call(address(manager), sender, k, sp);
        assertTrue(ok, "guards hold but call reverted");
        assertEq(abi.decode(ret, (bytes4)), SEL);
        _assertWrites(k);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeInitialize.lean:97 — under the guards, returns the selector and the hook's storage becomes `beforeInit_state`.
    function testFuzz_beforeInitialize_ok(
        address sender,
        address other,
        bool numIs0,
        int24 ts,
        address hooks,
        uint160 sp,
        bool withOrder
    ) public {
        if (withOrder) _placeOrder(alice, true, 1 ether, 1 ether);
        other = _deployed(other);
        PoolKey memory k = _key(numIs0 ? _num() : other, numIs0 ? other : _num(), DYN, ts, hooks);
        vm.record();
        (bool ok, bytes memory ret) = _call(address(manager), sender, k, sp);
        assertTrue(ok);
        assertEq(abi.decode(ret, (bytes4)), SEL);
        _assertWrites(k);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeInitialize.lean:105 — every success satisfies the guards, returns the selector and writes `beforeInit_state`.
    function testFuzz_beforeInitialize_ok_inv(In memory x) public {
        address caller = x.fromManager ? address(manager) : x.caller;
        PoolKey memory k = _steeredKey(x.c0, x.c1, x.num0, x.num1, x.fee, x.dyn, x.ts, x.hooks);
        vm.record();
        (bool ok, bytes memory ret) = _call(caller, x.sender, k, x.sp);
        if (ok) {
            assertTrue(_guards(caller, k), "success without guards");
            assertEq(abi.decode(ret, (bytes4)), SEL);
            _assertWrites(k);
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeInitialize.lean:124 — succeeds iff sender is the PoolManager, a leg is the numeraire, and fee is the dynamic flag; extended by the L-02 fix: the asset leg is native or has code (Lean statement needs updating).
    function testFuzz_beforeInitialize_succeeds_iff(In memory x) public {
        address caller = x.fromManager ? address(manager) : x.caller;
        PoolKey memory k = _steeredKey(x.c0, x.c1, x.num0, x.num1, x.fee, x.dyn, x.ts, x.hooks);
        (bool ok,) = _call(caller, x.sender, k, x.sp);
        assertEq(ok, _guards(caller, k));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeInitialize.lean:145 — footprint: a success changes only `asyncOrders[key.toId()].{poolManager,numeraire,feeVault}`; every other pool and state variable is unchanged.
    function testFuzz_beforeInitialize_frame(
        address sender,
        address other,
        bool numIs0,
        int24 ts,
        address hooks,
        uint160 sp,
        bool withOrder
    ) public {
        if (withOrder) _placeOrder(alice, true, 1 ether, 1 ether);
        other = _deployed(other);
        PoolKey memory k = _key(numIs0 ? _num() : other, numIs0 ? other : _num(), DYN, ts, hooks);
        // Fields of the fixture pool and the plain state variables, before.
        uint256 fb = _base(key);
        bytes32[5] memory before = [
            _loadHook(bytes32(fb)),
            _loadHook(bytes32(fb + 1)),
            _loadHook(bytes32(fb + 2)),
            _loadHook(bytes32(OWNER_SLOT)),
            _loadHook(bytes32(PENDING_OWNER_SLOT))
        ];
        vm.record();
        (bool ok,) = _call(address(manager), sender, k, sp);
        assertTrue(ok);
        _assertWrites(k);
        assertEq(_loadHook(bytes32(OWNER_SLOT)), before[3]);
        assertEq(_loadHook(bytes32(PENDING_OWNER_SLOT)), before[4]);
        if (PoolId.unwrap(k.toId()) != PoolId.unwrap(key.toId())) {
            assertEq(_loadHook(bytes32(fb)), before[0]);
            assertEq(_loadHook(bytes32(fb + 1)), before[1]);
            assertEq(_loadHook(bytes32(fb + 2)), before[2]);
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeInitialize.lean:78 — real flow: `manager.initialize` of a fresh numeraire/dynamic-fee pool succeeds and records the three fields.
    function test_beforeInitialize_run_ok_viaPoolManager() public {
        MockERC20 t = new MockERC20("Other", "OTH", 18);
        (address a, address b) = address(t) < _num() ? (address(t), _num()) : (_num(), address(t));
        PoolKey memory k = _key(a, b, DYN, 10, address(hook));
        vm.record();
        manager.initialize(k, 2 ** 96);
        _assertWrites(k);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapBeforeInitialize.lean:67 — real flow: `manager.initialize` of a static-fee numeraire pool reverts with the hook's `DynamicFeeRequired` (wrapped by the PoolManager).
    function test_beforeInitialize_dynamicFeeRequired_viaPoolManager() public {
        MockERC20 t = new MockERC20("Other", "OTH", 18);
        (address a, address b) = address(t) < _num() ? (address(t), _num()) : (_num(), address(t));
        PoolKey memory k = _key(a, b, 3000, 60, address(hook));
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(AsyncSwap.DynamicFeeRequired.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(k, 2 ** 96);
    }
}
