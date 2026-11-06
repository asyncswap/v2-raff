// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {HookUnlockBase} from "./HookUnlockBase.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean`.
contract AsyncSwapExecuteOrderFormalTest is HookUnlockBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address filler = makeAddr("filler");

    function setUp() public override {
        super.setUp();
        vm.prank(alice);
        hook.setExecutor(poolId, address(this), true); // the test contract is alice's executor
        token0.mint(address(this), 1e40);
        token1.mint(address(this), 1e40);
        vm.deal(address(this), 1e33);
    }

    /// @dev The Lean model's pool fee was `a / 997 * 3 + a % 997 * 3 / 997`; the filler surcharge is now 0.
    function _pf(uint256) internal pure returns (uint256) {
        return 0;
    }

    /// @dev The 0.02% trade fee each side of a fill pays out of what it receives.
    function _fee(uint256 x) internal pure returns (uint256) {
        return Math.mulDiv(x, 2, 10_000, Math.Rounding.Ceil);
    }

    function _output(AsyncOrder memory o) internal pure returns (Currency) {
        return o.zeroForOne ? o.key.currency1 : o.key.currency0;
    }

    function _inputC(AsyncOrder memory o) internal pure returns (Currency) {
        return o.zeroForOne ? o.key.currency0 : o.key.currency1;
    }

    /// @dev Pre-pay `gross` ERC20 output to the hook's credit (Router.fillOrder), then executeOrder as `caller`.
    function _fillCalls(AsyncOrder memory o, address caller, bytes memory data, uint256 gross)
        internal
        view
        returns (Call[] memory)
    {
        return _push(
            _payToHookCalls(_output(o), gross),
            _cAs(caller, address(hook), abi.encodeCall(hook.executeOrder, (o, data)))
        );
    }

    function _execNativeCalls(AsyncOrder memory o, address caller, address to) internal view returns (Call[] memory) {
        return _one(_cAs(caller, address(hook), abi.encodeCall(hook.executeOrder, (o, abi.encode(to)))));
    }

    function _deposit(uint256 amount) internal {
        (bool ok,) = payable(address(hook)).call{value: amount}("");
        require(ok, "deposit");
    }

    /// @dev Native pool (currency0 = ETH) with alice's ERC20-input / native-output order (zeroForOne = false).
    function _nativeOrder(uint256 amountIn, uint256 amountOutMin) internal returns (AsyncOrder memory o, bytes32 id) {
        PoolKey memory nk = PoolKey({
            currency0: Currency.wrap(address(0)), currency1: currency1, fee: key.fee, tickSpacing: 1, hooks: hook
        });
        (uint160 sqrtP,,,) = manager.getSlot0(nk.toId());
        if (sqrtP == 0) manager.initialize(nk, 2 ** 96);
        (o, id) = _placeOrderOn(nk, alice, false, amountIn, amountOutMin);
        vm.prank(alice);
        hook.setExecutor(nk.toId(), address(this), true);
    }

    /* ----------------------------- calculatePoolFee ----------------------------- */

    /// @notice formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean:122 — the pool fee never exceeds the amount: calculatePoolFee(f, a) <= a.
    function testFuzz_pf_le(uint24 f, uint256 a) public view {
        assertLe(hook.calculatePoolFee(f, a), a);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean:124 — calculatePoolFee(f, a) returns exactly 0 (was a/997*3 + (a%997)*3/997) and never panics. (semantics changed by the 0.02% trade fee; Lean statement needs updating)
    function testFuzz_calculatePoolFee_run(uint24 f, uint256 a) public view {
        assertEq(hook.calculatePoolFee(f, a), _pf(a));
    }

    /* ------------------------------------ fill ------------------------------------ */

    /// @notice formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean:137 — AsyncFiller.fill (as executeOrder calls it): NotAuthorizedExecutor unless isExecutor[owner][executor]; else OrderNotFound if stored amountIn = 0; else the fill tail; the maker now receives amountOutMin less the trade fee. (semantics changed by the 0.02% trade fee; Lean statement needs updating)
    function testFuzz_fill_run(bool authorised, bool exists, bool zeroForOne, uint256 amountIn, uint256 amountOutMin)
        public
    {
        amountIn = bound(amountIn, 1, 50 ether);
        amountOutMin = bound(amountOutMin, 1, 1e30);
        (AsyncOrder memory o, bytes32 id) = _placeOrder(alice, zeroForOne, amountIn, amountOutMin);
        if (!exists) o.salt = keccak256(abi.encode(o.salt));
        address caller = authorised ? address(this) : bob;
        uint256 gross = amountOutMin + _pf(amountOutMin);
        Call[] memory cs = _fillCalls(o, caller, abi.encode(filler), gross);
        if (!authorised) {
            vm.expectRevert(AsyncFiller.NotAuthorizedExecutor.selector);
            _run(cs);
        } else if (!exists) {
            vm.expectRevert(AsyncFiller.OrderNotFound.selector);
            _run(cs);
        } else {
            MockERC20 out = MockERC20(Currency.unwrap(_output(o)));
            uint256 before = out.balanceOf(alice);
            _run(cs);
            assertEq(
                out.balanceOf(alice) - before, amountOutMin - _fee(amountOutMin), "maker paid stored amountOutMin net"
            );
            assertEq(hook.asyncOrder(poolId, id), 0, "order cleared");
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean:162 — after the native step, the fee is pf(stored amountOutMin) (not the calldata amount), then fill with hook = this, executor = msg.sender, the decoded filler and feeVault; both trade fees go to the vault. (semantics changed by the 0.02% trade fee; Lean statement needs updating)
    function testFuzz_afterNative_run(uint256 amountIn, uint256 newOut, uint256 fakeOut, uint256 fakeIn) public {
        amountIn = bound(amountIn, 1, 50 ether);
        newOut = bound(newOut, 1, 1e30);
        (AsyncOrder memory o, bytes32 id) = _placeOrder(alice, true, amountIn, 1 ether);
        vm.prank(alice);
        hook.updatePrice(o, newOut); // stored amountOutMin now differs from the struct field
        o.amountOutMin = fakeOut;
        o.amountIn = fakeIn;
        address vault = address(hook.feeVault());
        uint256 vaultBefore = _claims(vault, currency1);
        uint256 makerBefore = token1.balanceOf(alice);
        uint256 fillerBefore = token0.balanceOf(filler);
        uint256 vaultInBefore = _claims(vault, currency0);
        _run(_fillCalls(o, address(this), abi.encode(filler), newOut + _pf(newOut)));
        assertEq(
            _claims(vault, currency1) - vaultBefore,
            _pf(newOut) + _fee(newOut) + 100_000,
            "fee and bid = pf + tradeFee(stored amountOutMin) to feeVault"
        );
        assertEq(_claims(vault, currency0) - vaultInBefore, _fee(amountIn), "input trade fee to feeVault");
        assertEq(token1.balanceOf(alice) - makerBefore, newOut - _fee(newOut), "maker paid stored amountOutMin net");
        assertEq(
            token0.balanceOf(filler) - fillerBefore,
            amountIn - _fee(amountIn),
            "decoded filler paid stored amountIn net"
        );
        assertEq(hook.asyncOrder(poolId, id), 0);
    }

    /* -------------------------------- executeOrder -------------------------------- */

    /// @notice formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean:188 — executeOrder (ERC20 output): decode guard first, then NotAuthorizedExecutor, then OrderNotFound, then the fill.
    function testFuzz_executeOrder_run(uint8 dataKind, bool authorised, bool exists, uint256 dirty) public {
        (AsyncOrder memory o, bytes32 id) = _placeOrder(alice, true, 1 ether, 1 ether);
        if (!exists) o.salt = bytes32(uint256(o.salt) ^ 1);
        bytes memory data;
        bool decodeFails = true;
        if (dataKind % 3 == 0) {
            data = hex"00112233"; // shorter than a word
        } else if (dataKind % 3 == 1) {
            data = abi.encode(bound(dirty, 2 ** 160, type(uint256).max)); // not an address
        } else {
            data = abi.encode(filler, dirty); // longer than a word is fine
            decodeFails = false;
        }
        Call[] memory cs = _fillCalls(o, authorised ? address(this) : bob, data, 1 ether + _pf(1 ether));
        if (decodeFails) {
            vm.expectRevert(bytes(""));
            _run(cs);
        } else if (!authorised) {
            vm.expectRevert(AsyncFiller.NotAuthorizedExecutor.selector);
            _run(cs);
        } else if (!exists) {
            vm.expectRevert(AsyncFiller.OrderNotFound.selector);
            _run(cs);
        } else {
            _run(cs);
            assertEq(hook.asyncOrder(poolId, id), 0, "filled");
            assertEq(token0.balanceOf(filler), 1 ether - _fee(1 ether), "filler = first word of data");
        }
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean:237 — data shorter than a word, or whose first word is not an address, reverts (abi.decode), before any other check.
    function testFuzz_executeOrder_decode(bytes memory raw, uint256 dirty, bool short, address caller, bool native)
        public
    {
        AsyncOrder memory o;
        if (native) (o,) = _nativeOrder(1 ether, 1 ether);
        else (o,) = _placeOrder(alice, true, 1 ether, 1 ether);
        bytes memory data;
        if (short) {
            uint256 n = raw.length % 32;
            data = new bytes(n);
            for (uint256 i; i < n; ++i) {
                data[i] = raw[i];
            }
        } else {
            data = bytes.concat(abi.encode(bound(dirty, 2 ** 160, type(uint256).max)), raw);
        }
        vm.prank(caller);
        vm.expectRevert(bytes(""));
        hook.executeOrder(o, data);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean:245 — native output: a same-tx deposit ledger below m + pf(m) (m = stored amountOutMin) reverts UnaccountedNativeOutput.
    function testFuzz_executeOrder_unaccountedNative(uint256 m, uint256 deposit, address caller) public {
        m = bound(m, 1, 1e30);
        (AsyncOrder memory o,) = _nativeOrder(1 ether, m);
        deposit = bound(deposit, 0, m + _pf(m) - 1);
        if (deposit != 0) _deposit(deposit);
        vm.prank(caller);
        vm.expectRevert(AsyncSwap.UnaccountedNativeOutput.selector);
        hook.executeOrder(o, abi.encode(filler));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean:256 — native output: m + pf(m) overflowing uint256 panics 0x11.
    ///         With pf = 0 the sum can no longer overflow, so a huge m now reaches the ledger check and reverts
    ///         UnaccountedNativeOutput instead of panicking.
    ///         (semantics changed by the 0.02% trade fee; Lean statement needs updating)
    function testFuzz_executeOrder_nativeOverflow(uint256 m, address caller) public {
        m = bound(m, type(uint256).max - type(uint256).max / 400, type(uint256).max);
        assertLe(m, type(uint256).max - _pf(m), "m + pf(m) fits");
        (AsyncOrder memory o,) = _nativeOrder(1 ether, m);
        vm.prank(caller);
        vm.expectRevert(AsyncSwap.UnaccountedNativeOutput.selector);
        hook.executeOrder(o, abi.encode(filler));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean:275 — ERC20 output: a caller the owner has not authorised as executor reverts NotAuthorizedExecutor.
    function testFuzz_executeOrder_unauthorized(address caller, bool exists, bytes32 salt, address to) public {
        (AsyncOrder memory o,) = _placeOrder(alice, true, 1 ether, 1 ether);
        if (!exists) o.salt = salt;
        vm.assume(!hook.isExecutor(poolId, alice, caller));
        vm.prank(caller);
        vm.expectRevert(AsyncFiller.NotAuthorizedExecutor.selector);
        hook.executeOrder(o, abi.encode(to));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean:290 — ERC20 output, authorised caller, no stored order: OrderNotFound.
    function testFuzz_executeOrder_notFound(bytes32 salt, bool zeroForOne, address to, bool viaRouter) public {
        AsyncOrder memory o = _orderFromMaker(alice, zeroForOne, 1 ether, 1 ether);
        o.salt = salt;
        vm.assume(hook.asyncOrder(poolId, _idOf(o)) == 0);
        vm.prank(viaRouter ? address(router) : address(this));
        vm.expectRevert(AsyncFiller.OrderNotFound.selector);
        hook.executeOrder(o, abi.encode(to));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean:323 — success (ERC20 output): authorised, stored amountIn != 0; maker gets stored amountOutMin less tradeFee, feeVault gets pf + tradeFee(amountOutMin) claims and tradeFee(amountIn) input claims, the decoded filler gets stored amountIn less tradeFee, the hook's input claims burn amountIn, order cleared. (semantics changed by the 0.02% trade fee; Lean statement needs updating)
    function testFuzz_executeOrder_ok(bool zeroForOne, uint256 amountIn, uint256 amountOutMin, uint160 toSeed) public {
        amountIn = bound(amountIn, 1, 50 ether);
        amountOutMin = bound(amountOutMin, 1, 1e30);
        address to = address(uint160(bound(toSeed, 1, type(uint160).max)));
        vm.assume(to != alice && to != address(manager) && to != address(hook) && to != address(this));
        vm.assume(to != address(hook.feeVault()) && to != address(router));
        (AsyncOrder memory o, bytes32 id) = _placeOrder(alice, zeroForOne, amountIn, amountOutMin);
        uint256[5] memory b = _okSnapshot(o, to);
        _run(_fillCalls(o, address(this), abi.encode(to), amountOutMin + _pf(amountOutMin)));
        uint256[5] memory a = _okSnapshot(o, to);
        assertEq(a[0] - b[0], amountOutMin - _fee(amountOutMin), "maker net");
        assertEq(a[1] - b[1], _pf(amountOutMin) + _fee(amountOutMin) + (zeroForOne ? 100_000 : 0), "fee and bid claims");
        assertEq(a[2] - b[2], amountIn - _fee(amountIn), "filler input");
        assertEq(a[4] - b[4], _fee(amountIn) + (zeroForOne ? 0 : 100_000), "input trade fee and bid claims");
        assertEq(b[3] - a[3], amountIn + (zeroForOne ? 0 : 100_000), "input and bid claims burned");
        assertEq(hook.asyncOrder(poolId, id), 0, "cleared");
    }

    function _okSnapshot(AsyncOrder memory o, address to) internal view returns (uint256[5] memory r) {
        r[0] = MockERC20(Currency.unwrap(_output(o))).balanceOf(alice);
        r[1] = _claims(address(hook.feeVault()), _output(o));
        r[2] = MockERC20(Currency.unwrap(_inputC(o))).balanceOf(to);
        r[3] = _claims(address(hook), _inputC(o));
        r[4] = _claims(address(hook.feeVault()), _inputC(o));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean:323 — success (native output): the ledger is decremented by exactly m + pf(m); maker gets m less tradeFee and feeVault pf(m) + tradeFee(m) as native claims; the filler gets the ERC20 input less tradeFee. (semantics changed by the 0.02% trade fee; Lean statement needs updating)
    function testFuzz_executeOrder_ok_native(uint256 m1, uint256 m2, bool short) public oneTx {
        m1 = bound(m1, 1, 100 ether);
        m2 = bound(m2, 1, 100 ether);
        (AsyncOrder memory o1, bytes32 id1) = _nativeOrder(1 ether, m1);
        (AsyncOrder memory o2,) = _nativeOrder(2 ether, m2);
        uint256 need1 = m1 + _pf(m1);
        uint256 need2 = m2 + _pf(m2);
        _deposit(need1 + need2 - (short ? 1 : 0));
        Currency eth = Currency.wrap(address(0));
        address vault = address(hook.feeVault());
        uint256 fillerBefore = token1.balanceOf(filler);
        _run(_execNativeCalls(o1, address(this), filler));
        assertEq(_claims(alice, eth), m1 - _fee(m1), "maker native claims");
        assertEq(_claims(vault, eth), _pf(m1) + _fee(m1), "fee native claims");
        assertEq(_claims(vault, currency1), _fee(1 ether) + 100_000, "input trade fee and bid claims");
        assertEq(token1.balanceOf(filler) - fillerBefore, 1 ether - _fee(1 ether), "filler input");
        assertEq(hook.asyncOrder(o1.key.toId(), id1), 0);
        // The ledger now holds exactly need2 - (short ? 1 : 0).
        if (short) {
            vm.expectRevert(AsyncSwap.UnaccountedNativeOutput.selector);
            _run(_execNativeCalls(o2, address(this), filler));
        } else {
            _run(_execNativeCalls(o2, address(this), filler));
            assertEq(_claims(alice, eth), m1 - _fee(m1) + m2 - _fee(m2));
        }
    }
}
