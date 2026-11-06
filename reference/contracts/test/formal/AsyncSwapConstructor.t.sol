// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AsyncSwap} from "src/AsyncSwap.sol";
import {BaseHook} from "src/BaseHook.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @dev Bypasses hook-address mining only, so the real constructor runs at an arbitrary address, and
///      exposes the internal `_domainSeparatorV4`.
contract CtorHarness is AsyncSwap {
    constructor(IPoolManager manager, Currency quote, address owner_, address router_)
        AsyncSwap(manager, quote, owner_, router_, 0, type(uint8).max)
    {}

    function validateHookAddress(BaseHook) internal pure override {}

    function domainSeparatorV4() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapConstructor.lean`. They also discharge the
///         file's two assumptions about the opaque constructor: `CtorStorageSpec` (the guards, and
///         `owner := _owner` as the only storage write) and `Immutables` (poolManager, numeraire, cached
///         address / chain id / separator).
contract AsyncSwapConstructorFormalTest is Test {
    bytes32 constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    uint256 constant OWNER_SLOT = 4;
    uint256 constant PENDING_OWNER_SLOT = 5;

    IPoolManager manager;
    MockERC20 usdc;

    function setUp() public {
        manager = new PoolManager(address(this));
        usdc = new MockERC20("USD Coin", "USDC", 6);
        // The constructor reads the numeraire's decimals; the other code-bearing candidates report 6 like USDC,
        // so these checks keep testing the code and owner guards (Numeraire.t.sol covers the decimals guard).
        vm.mockCall(address(manager), abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        vm.mockCall(address(this), abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
    }

    function _built(address self) internal view returns (bytes32) {
        return keccak256(abi.encode(TYPE_HASH, keccak256("AsyncSwap"), keccak256("1"), block.chainid, self));
    }

    /// @dev A numeraire with code: one of the contracts deployed here.
    function _withCode(uint8 which) internal view returns (address) {
        which %= 3;
        if (which == 0) return address(usdc);
        if (which == 1) return address(manager);
        return address(this);
    }

    /// @dev The constructor's decimals guard: `decimals()` answers with a value from 1 to 20.
    function _decimalsOk(address num) internal view returns (bool) {
        (bool ok, bytes memory ret) = num.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || ret.length < 32) return false;
        uint256 d = abi.decode(ret, (uint256));
        return d >= 1 && d <= 20;
    }

    function _deploy(address pm, address num, address owner_) internal returns (bool ok, address a) {
        try new CtorHarness(IPoolManager(pm), Currency.wrap(num), owner_, address(0xCAFE)) returns (CtorHarness h) {
            return (true, address(h));
        } catch {
            return (false, address(0));
        }
    }

    function _newHook(address owner_) internal returns (CtorHarness) {
        return new CtorHarness(manager, Currency.wrap(address(usdc)), owner_, address(0xCAFE));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapConstructor.lean:76 — a numeraire without code reverts
    ///         `InvalidNumeraire` (checked first, whatever the owner and pool manager).
    function testFuzz_ctor_invalidNumeraire(address pm, address num, address owner_) public {
        vm.assume(num.code.length == 0);
        vm.expectRevert(AsyncSwap.InvalidNumeraire.selector);
        new CtorHarness(IPoolManager(pm), Currency.wrap(num), owner_, address(0xCAFE));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapConstructor.lean:82 — a numeraire with code and a zero owner
    ///         reverts `ZeroAddress`.
    function testFuzz_ctor_zeroOwner(address pm, uint8 which) public {
        vm.expectRevert(AsyncSwap.ZeroAddress.selector);
        new CtorHarness(IPoolManager(pm), Currency.wrap(_withCode(which)), address(0), address(0xCAFE));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapConstructor.lean:88 — reverts iff the numeraire has no code or
    ///         the owner is zero, extended by the decimals guard: the numeraire must report 1 to 20 decimals.
    function testFuzz_ctor_reverts_iff(
        address pm,
        address num,
        bool hasCode,
        uint8 which,
        address owner_,
        bool zeroOwner
    ) public {
        if (hasCode) num = _withCode(which);
        if (zeroOwner) owner_ = address(0);
        (bool ok,) = _deploy(pm, num, owner_);
        assertEq(!ok, num.code.length == 0 || owner_ == address(0) || !_decimalsOk(num));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapConstructor.lean:95 — succeeds iff both guards pass, and then
    ///         the only storage write is `owner := _owner`.
    function testFuzz_ctor_ok_iff(address pm, address num, bool hasCode, uint8 which, address owner_, bool zeroOwner)
        public
    {
        if (hasCode) num = _withCode(which);
        if (zeroOwner) owner_ = address(0);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.record();
        (bool ok, address a) = _deploy(pm, num, owner_);
        assertEq(ok, num.code.length != 0 && owner_ != address(0) && _decimalsOk(num), "ok iff guards pass");
        if (!ok) return;
        assertEq(a, predicted);
        (, bytes32[] memory writes) = vm.accesses(a);
        assertGt(writes.length, 0, "owner is written");
        for (uint256 i; i < writes.length; i++) {
            assertEq(writes[i], bytes32(OWNER_SLOT), "only owner is written");
        }
        assertEq(vm.load(a, bytes32(OWNER_SLOT)), bytes32(uint256(uint160(owner_))), "owner := _owner");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapConstructor.lean:104 — from fresh storage, the deployed state is
    ///         all zero except `owner = _owner != 0`; `pendingOwner = 0`; the numeraire has code.
    function testFuzz_ctor_fresh_state(address pm, uint8 which, address owner_) public {
        vm.assume(owner_ != address(0));
        address num = _withCode(which);
        (bool ok, address a) = _deploy(pm, num, owner_);
        assertTrue(ok);
        for (uint256 s; s <= 6; s++) {
            bytes32 expected = s == OWNER_SLOT ? bytes32(uint256(uint160(owner_))) : bytes32(0);
            assertEq(vm.load(a, bytes32(s)), expected, "deployed slot");
        }
        assertEq(AsyncSwap(payable(a)).owner(), owner_);
        assertEq(AsyncSwap(payable(a)).pendingOwner(), address(0));
        assertGt(num.code.length, 0);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapConstructor.lean:115 — a successful deployment fixes
    ///         `poolManager = _poolManager`, `numeraire = _numeraire` (a contract) and `owner = _owner != 0`.
    function testFuzz_ctor_deployed(address pm, uint8 which, address owner_) public {
        vm.assume(owner_ != address(0));
        address num = _withCode(which);
        (bool ok, address a) = _deploy(pm, num, owner_);
        assertTrue(ok);
        CtorHarness h = CtorHarness(payable(a));
        assertEq(address(h.poolManager()), pm, "poolManager");
        assertEq(Currency.unwrap(h.numeraire()), num, "numeraire");
        assertGt(Currency.unwrap(h.numeraire()).code.length, 0, "numeraire has code");
        assertEq(h.owner(), owner_, "owner");
        assertGt(address(h.feeVault()).code.length, 0, "FeeVault deployed");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapConstructor.lean:126 — a successful `transferOwnership` keeps
    ///         `owner != 0`.
    function testFuzz_owner_nonzero_transferOwnership(
        address owner_,
        address pending,
        address sender,
        bool asOwner,
        address newOwner
    ) public {
        vm.assume(owner_ != address(0));
        CtorHarness h = _newHook(owner_);
        vm.store(address(h), bytes32(PENDING_OWNER_SLOT), bytes32(uint256(uint160(pending))));
        if (asOwner) sender = owner_;
        vm.prank(sender);
        (bool ok,) = address(h).call(abi.encodeCall(AsyncSwap.transferOwnership, (newOwner)));
        if (ok) assertTrue(h.owner() != address(0), "owner != 0");
        assertEq(h.owner(), owner_);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapConstructor.lean:134 — a successful `acceptOwnership` by a
    ///         nonzero sender keeps `owner != 0`.
    function testFuzz_owner_nonzero_acceptOwnership(address owner_, address pending, address sender, bool asPending)
        public
    {
        vm.assume(owner_ != address(0));
        CtorHarness h = _newHook(owner_);
        vm.store(address(h), bytes32(PENDING_OWNER_SLOT), bytes32(uint256(uint160(pending))));
        if (asPending) sender = pending;
        vm.assume(sender != address(0));
        vm.prank(sender);
        (bool ok,) = address(h).call(abi.encodeCall(AsyncSwap.acceptOwnership, ()));
        if (ok) assertTrue(h.owner() != address(0), "owner != 0");
    }

    /// @dev Optionally move the deployed code (immutables included) to `at`, and change the chain id.
    function _env(CtorHarness h, address at, bool moved, uint64 chainId) internal returns (address) {
        vm.chainId(chainId);
        if (!moved) return address(h);
        vm.assume(at.code.length == 0 && uint160(at) > 0x11 && at != address(vm));
        vm.assume(at != 0x000000000000000000636F6e736F6c652e6c6f67);
        vm.etch(at, address(h).code);
        return at;
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapConstructor.lean:146 — `_domainSeparatorV4` writes nothing and
    ///         returns the separator built from the current `block.chainid` and `address(this)`.
    function testFuzz_domainSeparatorV4_eq_built(uint64 chainId, address at, bool moved) public {
        address self = _env(_newHook(address(this)), at, moved, chainId);
        vm.record();
        bytes32 sep = CtorHarness(payable(self)).domainSeparatorV4();
        (, bytes32[] memory writes) = vm.accesses(self);
        assertEq(writes.length, 0, "no writes");
        assertEq(sep, _built(self));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapConstructor.lean:159 — `DOMAIN_SEPARATOR()` returns the separator
    ///         rebuilt from the current chain id and address, in every environment (after a fork, too).
    function testFuzz_DOMAIN_SEPARATOR_eq_built(uint64 chainId, address at, bool moved) public {
        address self = _env(_newHook(address(this)), at, moved, chainId);
        vm.record();
        bytes32 sep = AsyncSwap(payable(self)).DOMAIN_SEPARATOR();
        (, bytes32[] memory writes) = vm.accesses(self);
        assertEq(writes.length, 0, "no writes");
        assertEq(sep, _built(self));
    }
}
