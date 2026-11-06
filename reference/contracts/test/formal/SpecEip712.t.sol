// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ShortString, ShortStrings} from "@openzeppelin/contracts/utils/ShortStrings.sol";
import {AsyncSwap} from "src/AsyncSwap.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ISignatureTransfer} from "@async-swap/interfaces/ISignatureTransfer.sol";
import {CtorHarness} from "./AsyncSwapConstructor.t.sol";
import {DomainHarness, RouterDomainHarness, IEip712Probe} from "./Eip712Domain.t.sol";
import {FormalImmutablesC} from "./FormalImmutablesC.sol";

/// @dev Runs OpenZeppelin's real `ShortStrings` library code (internal functions, compiled here with the
///      project's settings). `store` is the `string storage` handed to the fallback functions.
contract ShortStringsHarnessC {
    string store;

    function setStore(string calldata s) external {
        store = s;
    }

    function toString(bytes32 v) external pure returns (string memory) {
        return ShortStrings.toString(ShortString.wrap(v));
    }

    function byteLength(bytes32 v) external pure returns (uint256) {
        return ShortStrings.byteLength(ShortString.wrap(v));
    }

    function toStringWithFallback(bytes32 v) external view returns (string memory) {
        return ShortStrings.toStringWithFallback(ShortString.wrap(v), store);
    }

    function toShortString(string calldata s) external pure returns (bytes32) {
        return ShortString.unwrap(ShortStrings.toShortString(s));
    }

    function toShortStringWithFallback(string calldata s) external returns (bytes32) {
        return ShortString.unwrap(ShortStrings.toShortStringWithFallback(s, store));
    }
}

/// @dev Constants of `formal/Refinement/Swarm/Assumptions.lean`.
abstract contract SpecEip712Constants is Test {
    bytes32 constant TYPE_HASH = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;
    bytes32 constant HASH_ASYNCSWAP = 0x72bb025359d2292b4e59f168b9de8e3967bb96d5053211bfa4d833b6867bdb86;
    bytes32 constant HASH_ONE = 0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6;
    bytes32 constant HASH_ASYNCSWAP_ROUTER = 0x08476627fc511b8f0bf0674a96c4492f05a5c5df2795822dac01ecd5bdbd9167;
    bytes32 constant SHORT_ASYNCSWAP = 0x4173796e63537761700000000000000000000000000000000000000000000009;
    bytes32 constant SHORT_ONE = 0x3100000000000000000000000000000000000000000000000000000000000001;
    bytes32 constant SHORT_ASYNCSWAP_ROUTER = 0x4173796e635377617020526f7574657200000000000000000000000000000010;
    bytes32 constant FALLBACK_SENTINEL = bytes32(uint256(0xFF));

    ShortStringsHarnessC ss;

    function _setUpShortStrings() internal {
        ss = new ShortStringsHarnessC();
    }

    /// @dev `Assumptions.ShortStr.decodeBytes v`: the first `v & 0xFF` bytes of the word.
    function _decodeBytes(bytes32 v) internal pure returns (bytes memory b) {
        uint256 len = uint256(v) & 0xFF;
        b = new bytes(len);
        for (uint256 i; i < len; i++) {
            b[i] = v[i];
        }
    }

    /// @dev `Assumptions.ShortStr.encode s` for `bytes(s).length <= 31`, computed independently of the library.
    function _encode(bytes memory s) internal pure returns (bytes32 w) {
        require(s.length <= 31);
        for (uint256 i; i < s.length; i++) {
            w |= bytes32(s[i]) >> (8 * i);
        }
        w |= bytes32(s.length);
    }

    /// @dev A word with length byte `len` (any other bytes).
    function _withLen(bytes32 v, uint256 len) internal pure returns (bytes32) {
        return bytes32((uint256(v) & ~uint256(0xFF)) | (len & 0xFF));
    }

    function _assertNoWrites(address c) internal view {
        (, bytes32[] memory writes) = vm.accesses(c);
        assertEq(writes.length, 0, "no storage writes");
    }
}

/// @notice Bytecode checks of the theorems of `formal/Refinement/Swarm/Assumptions.lean` (OpenZeppelin
///         `ShortStrings.toShortStringWithFallback` on the deployed names, and the decoding back).
contract AssumptionsFormalTest is SpecEip712Constants {
    function setUp() public {
        _setUpShortStrings();
    }

    function _checkShort(string memory s, bytes32 word) internal {
        assertEq(ss.toShortString(s), word, "toShortString");
        vm.record();
        assertEq(ss.toShortStringWithFallback(s), word, "toShortStringWithFallback");
        _assertNoWrites(address(ss));
        assertEq(_encode(bytes(s)), word, "ShortStr.encode");
    }

    /// @notice formal/Refinement/Swarm/Assumptions.lean:88 — `toShortStringWithFallback("AsyncSwap")`
    ///         is `0x4173796e6353776170…09`.
    function test_asyncSwap_short() public {
        _checkShort("AsyncSwap", SHORT_ASYNCSWAP);
    }

    /// @notice formal/Refinement/Swarm/Assumptions.lean:91 — `toShortStringWithFallback("1")` is `0x31…01`.
    function test_one_short() public {
        _checkShort("1", SHORT_ONE);
    }

    /// @notice formal/Refinement/Swarm/Assumptions.lean:94 — `toShortStringWithFallback("AsyncSwap Router")`
    ///         is `0x4173796e635377617020526f75746572…10`.
    function test_asyncSwapRouter_short() public {
        _checkShort("AsyncSwap Router", SHORT_ASYNCSWAP_ROUTER);
    }

    /// @notice formal/Refinement/Swarm/Assumptions.lean:98 — none of the three names writes the fallback
    ///         slot; a 32-byte string does, and returns the sentinel (the `fallbackStore` model).
    function test_fallbackStore_none() public {
        string[3] memory names = ["AsyncSwap", "1", "AsyncSwap Router"];
        for (uint256 k; k < 3; k++) {
            vm.record();
            ss.toShortStringWithFallback(names[k]);
            _assertNoWrites(address(ss));
        }
        string memory long = "0123456789abcdef0123456789abcdef";
        assertEq(ss.toShortStringWithFallback(long), FALLBACK_SENTINEL, "long string: sentinel");
        assertEq(ss.toStringWithFallback(FALLBACK_SENTINEL), long, "long string: stored");
    }

    /// @notice formal/Refinement/Swarm/Assumptions.lean:103 — `decodeBytes` of the `"AsyncSwap"` word is its bytes,
    ///         and `toString` returns them.
    function test_decode_asyncSwap() public view {
        assertEq(_decodeBytes(SHORT_ASYNCSWAP), bytes("AsyncSwap"));
        assertEq(ss.toString(SHORT_ASYNCSWAP), "AsyncSwap");
    }

    /// @notice formal/Refinement/Swarm/Assumptions.lean:107 — `decodeBytes` of the `"1"` word is `"1"`.
    function test_decode_one() public view {
        assertEq(_decodeBytes(SHORT_ONE), bytes("1"));
        assertEq(ss.toString(SHORT_ONE), "1");
    }

    /// @notice formal/Refinement/Swarm/Assumptions.lean:110 — `decodeBytes` of the `"AsyncSwap Router"` word is its bytes.
    function test_decode_asyncSwapRouter() public view {
        assertEq(_decodeBytes(SHORT_ASYNCSWAP_ROUTER), bytes("AsyncSwap Router"));
        assertEq(ss.toString(SHORT_ASYNCSWAP_ROUTER), "AsyncSwap Router");
    }

    /// @notice formal/Refinement/Swarm/Assumptions.lean:116 — the three words pass `byteLength`'s guard and are not
    ///         the fallback sentinel.
    function test_deployed_short() public view {
        bytes32[3] memory words = [SHORT_ASYNCSWAP, SHORT_ONE, SHORT_ASYNCSWAP_ROUTER];
        for (uint256 k; k < 3; k++) {
            assertLe(ss.byteLength(words[k]), 31);
            assertTrue(words[k] != FALLBACK_SENTINEL);
        }
    }

    /// @notice The hash constants of Assumptions.lean are keccak256 of the strings, and `TYPE_HASH` of the
    ///         EIP-712 domain type (used by `EIP712Ctor`'s `hName` / `hVersion` and `cachedSep_eq`).
    function test_hash_constants() public pure {
        assertEq(HASH_ASYNCSWAP, keccak256("AsyncSwap"));
        assertEq(HASH_ONE, keccak256("1"));
        assertEq(HASH_ASYNCSWAP_ROUTER, keccak256("AsyncSwap Router"));
        assertEq(
            TYPE_HASH, keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
        );
    }
}

/// @notice Bytecode checks of `ShortStringsSpec` and the theorems about it in
///         `formal/Refinement/Swarm/SpecEip712AsyncSwap.lean` and `SpecEip712Router.lean` (the AsyncSwap
///         model's `ext.fn_ShortStrings_toString_9528` / `_toStringWithFallback_9627` and the Router's
///         `_5595` / `_5694` are the same OpenZeppelin library code, run here on a harness).
contract SpecEip712ShortStringsFormalTest is SpecEip712Constants {
    function setUp() public {
        _setUpShortStrings();
    }

    function _call(bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.record();
        (ok, ret) = address(ss).call(data);
        _assertNoWrites(address(ss));
    }

    /// @notice formal/Refinement/Swarm/SpecEip712AsyncSwap.lean:138 (`toString_reverts`), SpecEip712Router.lean:36 —
    ///         `toString(v)` reverts `InvalidShortString` when `v & 0xFF > 31`.
    function testFuzz_ShortStringsSpec_toString_reverts(bytes32 v, uint8 len) public {
        vm.assume(len > 31);
        v = _withLen(v, len);
        (bool ok, bytes memory ret) = _call(abi.encodeCall(ShortStringsHarnessC.toString, (v)));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(ShortStrings.InvalidShortString.selector));
    }

    /// @notice formal/Refinement/Swarm/SpecEip712AsyncSwap.lean:138 (`toString_ok`), SpecEip712Router.lean:36 —
    ///         otherwise `toString(v)` succeeds, writes nothing, and returns the first `v & 0xFF` bytes of `v`.
    function testFuzz_ShortStringsSpec_toString_ok(bytes32 v, uint8 len) public {
        v = _withLen(v, len % 32);
        (bool ok, bytes memory ret) = _call(abi.encodeCall(ShortStringsHarnessC.toString, (v)));
        assertTrue(ok);
        assertEq(bytes(abi.decode(ret, (string))), _decodeBytes(v));
    }

    /// @notice formal/Refinement/Swarm/SpecEip712AsyncSwap.lean:138 (`withFallback`), SpecEip712Router.lean:36 —
    ///         `toStringWithFallback(v, store)` is `toString(v)` (same outcome and data, reverts included) unless
    ///         `v` is the sentinel, when it returns `store`; it writes nothing.
    function testFuzz_ShortStringsSpec_withFallback(bytes32 v, bool sentinel, string memory stored) public {
        ss.setStore(stored);
        if (sentinel) v = FALLBACK_SENTINEL;
        (bool ok, bytes memory ret) = _call(abi.encodeCall(ShortStringsHarnessC.toStringWithFallback, (v)));
        if (v != FALLBACK_SENTINEL) {
            (bool ok2, bytes memory ret2) = address(ss).call(abi.encodeCall(ShortStringsHarnessC.toString, (v)));
            assertEq(ok, ok2, "same outcome as toString");
            assertEq(ret, ret2, "same data as toString");
        } else {
            assertTrue(ok);
            assertEq(abi.decode(ret, (string)), stored, "reads store");
        }
    }

    /// @notice formal/Refinement/Swarm/SpecEip712AsyncSwap.lean:165, SpecEip712Router.lean:63 — `byteLength(v)` reverts
    ///         `InvalidShortString` iff `v % 256 > 31`, else returns `v % 256`.
    function testFuzz_byteLength_eq(bytes32 v) public {
        (bool ok, bytes memory ret) = _call(abi.encodeCall(ShortStringsHarnessC.byteLength, (v)));
        uint256 len = uint256(v) % 256;
        assertEq(ok, len <= 31);
        if (ok) assertEq(abi.decode(ret, (uint256)), len);
        else assertEq(ret, abi.encodeWithSelector(ShortStrings.InvalidShortString.selector));
    }

    /// @notice formal/Refinement/Swarm/SpecEip712AsyncSwap.lean:176, SpecEip712Router.lean:74 — `toString(v)`
    ///         reverts iff `byteLength(v)` does.
    function testFuzz_toString_reverts_iff_byteLength(bytes32 v, bool short, uint8 len) public {
        if (short) v = _withLen(v, len % 32);
        (bool ok1,) = address(ss).call(abi.encodeCall(ShortStringsHarnessC.toString, (v)));
        (bool ok2,) = address(ss).call(abi.encodeCall(ShortStringsHarnessC.byteLength, (v)));
        assertEq(ok1, ok2);
    }

    /// @notice formal/Refinement/Swarm/SpecEip712AsyncSwap.lean:186, SpecEip712Router.lean:84 — `toString` of the word
    ///         encoding a string `t` (at most 31 bytes) returns `t` and writes nothing.
    function testFuzz_toString_eq(bytes memory t) public {
        vm.assume(t.length <= 31);
        bytes32 v = _encode(t);
        assertEq(_decodeBytes(v), t, "decodeBytes v = bytes t");
        (bool ok, bytes memory ret) = _call(abi.encodeCall(ShortStringsHarnessC.toString, (v)));
        assertTrue(ok);
        assertEq(bytes(abi.decode(ret, (string))), t);
    }

    /// @notice A counterexample to `ShortStringSpec.toString` of formal/Refinement/Swarm/AsyncSwapEip712Domain.lean:56
    ///         (RouterEip712Domain.lean:33), which claims `toString(v)` succeeds for every word: the bytecode
    ///         reverts `InvalidShortString` once `v & 0xFF > 31`. (The theorems there use it only at the deployed
    ///         `_name` / `_version`, where it holds; `ShortStringsSpec` states it correctly.)
    function test_finding_ShortStringSpec_toString_every_word() public {
        (bool ok,) = address(ss).call(abi.encodeCall(ShortStringsHarnessC.toString, (bytes32(uint256(0x20)))));
        assertTrue(ok, "ShortStringSpec.toString: toString(0x20) should succeed");
    }
}

/// @notice Bytecode checks of `Eip712DomainSpec` and of the theorems that read the deployed immutables in
///         `formal/Refinement/Swarm/SpecEip712AsyncSwap.lean` / `SpecEip712Router.lean`. Each test runs in a fuzzed
///         state and environment: arbitrary words in the two fallback-string slots, a fuzzed chain id, and
///         optionally the code moved to another address (`vm.etch`, immutables included).
abstract contract SpecEip712DomainChecks is SpecEip712Constants, FormalImmutablesC {
    IPoolManager manager;
    MockERC20 usdc;
    DomainHarness hook;
    RouterDomainHarness router;

    function setUp() public {
        _setUpShortStrings();
        manager = new PoolManager(address(this));
        usdc = new MockERC20("USD Coin", "USDC", 6);
        hook = new DomainHarness(manager, Currency.wrap(address(usdc)), address(this), address(0xCAFE));
        router =
            new RouterDomainHarness(manager, AsyncSwap(payable(address(hook))), ISignatureTransfer(address(0xBEEF)));
    }

    function _contract() internal view virtual returns (address);
    function _artifact() internal pure virtual returns (string memory);
    function _expName() internal pure virtual returns (string memory);
    function _nameWord() internal pure virtual returns (bytes32);

    function _env(bytes32 fb0, bytes32 fb1, uint64 chainId, address at, bool moved) internal returns (address c) {
        c = _contract();
        if (moved) {
            vm.assume(at.code.length == 0 && uint160(at) > 0x11 && at != address(vm));
            vm.assume(at != 0x000000000000000000636F6e736F6c652e6c6f67);
            vm.etch(at, c.code);
            c = at;
        }
        vm.store(c, bytes32(uint256(0)), fb0);
        vm.store(c, bytes32(uint256(1)), fb1);
        vm.chainId(chainId);
    }

    /// @notice formal/Refinement/Swarm/SpecEip712AsyncSwap.lean:155 (AsyncSwap), SpecEip712Router.lean:53
    ///         (Router), `Eip712DomainSpec.body` — `eip712Domain()` is `(0x0f, _EIP712Name(), _EIP712Version(),
    ///         block.chainid, address(this), 0, [])`, and writes nothing.
    function testFuzz_Eip712DomainSpec_body(bytes32 fb0, bytes32 fb1, uint64 chainId, address at, bool moved) public {
        address c = _env(fb0, fb1, chainId, at, moved);
        string memory n = IEip712Probe(c).eip712Name();
        string memory v = IEip712Probe(c).eip712Version();
        vm.record();
        (
            bytes1 f,
            string memory dn,
            string memory dv,
            uint256 cid,
            address verifying,
            bytes32 salt,
            uint256[] memory ex
        ) = IEip712Probe(c).eip712Domain();
        _assertNoWrites(c);
        assertEq(f, bytes1(0x0f), "fields");
        assertEq(dn, n, "name = _EIP712Name()");
        assertEq(dv, v, "version = _EIP712Version()");
        assertEq(cid, block.chainid, "chainId");
        assertEq(verifying, c, "verifyingContract");
        assertEq(salt, bytes32(0), "salt");
        assertEq(ex.length, 0, "extensions");
    }

    /// @dev `toString_name` / `name_ne_sentinel`: the deployed code embeds the `_name` word, it is not the
    ///      sentinel, and `toString` of it is the name; `_EIP712Name()` returns it whatever the fallback slot holds.
    function _checkName(bytes32 fb0, bytes32 fb1, uint64 chainId, address at, bool moved) internal {
        bytes32[] memory imm = _immutables(_artifact(), _contract());
        assertTrue(_contains(imm, _nameWord()), "_name word deployed");
        assertTrue(_nameWord() != FALLBACK_SENTINEL);
        assertEq(ss.toString(_nameWord()), _expName());
        address c = _env(fb0, fb1, chainId, at, moved);
        assertEq(IEip712Probe(c).eip712Name(), _expName());
    }

    function _checkVersion(bytes32 fb0, bytes32 fb1, uint64 chainId, address at, bool moved) internal {
        bytes32[] memory imm = _immutables(_artifact(), _contract());
        assertTrue(_contains(imm, SHORT_ONE), "_version word deployed");
        assertTrue(SHORT_ONE != FALLBACK_SENTINEL);
        assertEq(ss.toString(SHORT_ONE), "1");
        address c = _env(fb0, fb1, chainId, at, moved);
        assertEq(IEip712Probe(c).eip712Version(), "1");
    }

    /// @notice formal/Refinement/Swarm/SpecEip712AsyncSwap.lean:197 (AsyncSwap), SpecEip712Router.lean:95
    ///         (Router), `toString_name` — `toString(_name)` is the deployed name and writes nothing.
    function testFuzz_toString_name(bytes32 fb0, bytes32 fb1, uint64 chainId, address at, bool moved) public {
        _checkName(fb0, fb1, chainId, at, moved);
    }

    /// @notice formal/Refinement/Swarm/SpecEip712AsyncSwap.lean:204 (AsyncSwap), SpecEip712Router.lean:102
    ///         (Router), `toString_version` — `toString(_version)` is `"1"` and writes nothing.
    function testFuzz_toString_version(bytes32 fb0, bytes32 fb1, uint64 chainId, address at, bool moved) public {
        _checkVersion(fb0, fb1, chainId, at, moved);
    }

    /// @notice formal/Refinement/Swarm/SpecEip712AsyncSwap.lean:210 (AsyncSwap), SpecEip712Router.lean:108
    ///         (Router), `name_ne_sentinel` — the deployed `_name` is not `FALLBACK_SENTINEL` (the fallback slot is never read).
    function testFuzz_name_ne_sentinel(bytes32 fb0, bytes32 fb1, uint64 chainId, address at, bool moved) public {
        _checkName(fb0, fb1, chainId, at, moved);
    }

    /// @notice formal/Refinement/Swarm/SpecEip712AsyncSwap.lean:214 (AsyncSwap), SpecEip712Router.lean:112
    ///         (Router), `version_ne_sentinel` — the deployed `_version` is not `FALLBACK_SENTINEL`.
    function testFuzz_version_ne_sentinel(bytes32 fb0, bytes32 fb1, uint64 chainId, address at, bool moved) public {
        _checkVersion(fb0, fb1, chainId, at, moved);
    }
}

/// @notice AsyncSwap side: formal/Refinement/Swarm/SpecEip712AsyncSwap.lean — `Eip712DomainSpec` :155
///         (and its bridge `Eip712DomainSpec.domainSpec` :161), `toString_name` :197,
///         `toString_version` :204, `name_ne_sentinel` :210, `version_ne_sentinel` :214.
contract AsyncSwapSpecEip712FormalTest is SpecEip712DomainChecks {
    function _contract() internal view override returns (address) {
        return address(hook);
    }

    function _artifact() internal pure override returns (string memory) {
        return "Eip712Domain.t.sol:DomainHarness";
    }

    function _expName() internal pure override returns (string memory) {
        return "AsyncSwap";
    }

    function _nameWord() internal pure override returns (bytes32) {
        return SHORT_ASYNCSWAP;
    }
}

/// @notice Router side: formal/Refinement/Swarm/SpecEip712Router.lean — `Eip712DomainSpec` :53
///         (and `Eip712DomainSpec.domainSpec` :59), `toString_name` :95, `toString_version` :102,
///         `name_ne_sentinel` :108, `version_ne_sentinel` :112.
contract RouterSpecEip712FormalTest is SpecEip712DomainChecks {
    function _contract() internal view override returns (address) {
        return address(router);
    }

    function _artifact() internal pure override returns (string memory) {
        return "Eip712Domain.t.sol:RouterDomainHarness";
    }

    function _expName() internal pure override returns (string memory) {
        return "AsyncSwap Router";
    }

    function _nameWord() internal pure override returns (bytes32) {
        return SHORT_ASYNCSWAP_ROUTER;
    }
}

/// @notice Bytecode checks of `AsyncSwap.Swarm.Constructor.CtorSpec` and the theorems stated with it in
///         `formal/Refinement/Swarm/SpecEip712AsyncSwap.lean`. The storage half (`CtorStorageSpec`) is also
///         checked by `test/formal/AsyncSwapConstructor.t.sol`.
contract AsyncSwapCtorSpecFormalTest is SpecEip712Constants, FormalImmutablesC {
    uint256 constant OWNER_SLOT = 4;

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

    function _withCode(uint8 which) internal view returns (address) {
        which %= 3;
        if (which == 0) return address(usdc);
        if (which == 1) return address(manager);
        return address(this);
    }

    function _deploy(address pm, uint8 which, address owner_, uint64 chainId) internal returns (CtorHarness h) {
        vm.assume(owner_ != address(0));
        vm.chainId(chainId);
        address num = _withCode(which);
        vm.record();
        h = new CtorHarness(IPoolManager(pm), Currency.wrap(num), owner_, address(0xCAFE));
        (, bytes32[] memory writes) = vm.accesses(address(h));
        for (uint256 i; i < writes.length; i++) {
            assertEq(writes[i], bytes32(OWNER_SLOT), "storage: only owner is written");
        }
        assertEq(vm.load(address(h), bytes32(OWNER_SLOT)), bytes32(uint256(uint160(owner_))), "owner := _owner");
    }

    function _sep(bytes32 hn, bytes32 hv, uint256 chainId, address self) internal pure returns (bytes32) {
        return keccak256(abi.encode(TYPE_HASH, hn, hv, chainId, self));
    }

    /// @notice formal/Refinement/Swarm/SpecEip712AsyncSwap.lean:50 `CtorSpec` — every field: the storage effect
    ///         (`owner := _owner` only; the guards are `AsyncSwapConstructor.t.sol`'s tests), the immutables
    ///         (`poolManager = pm`, `numeraire = num`, `router`, cached address / chain id / separator), the EIP-712 ones
    ///         (`_name` / `_version` short strings, `_hashedName = keccak256("AsyncSwap")`, `_hashedVersion =
    ///         keccak256("1")`), and `feeVault` has code. The deployed code's immutables are exactly these.
    function testFuzz_CtorSpec(address pm, uint8 which, address owner_, uint64 chainId) public {
        CtorHarness h = _deploy(pm, which, owner_, chainId);
        address self = address(h);
        address vault = address(h.feeVault());
        assertGt(vault.code.length, 0, "feeVault_code");
        assertEq(address(h.poolManager()), pm, "poolManager");
        assertEq(Currency.unwrap(h.numeraire()), _withCode(which), "numeraire");
        assertEq(h.router(), address(0xCAFE), "router");
        bytes32 sep = _sep(HASH_ASYNCSWAP, HASH_ONE, block.chainid, self);
        assertEq(h.minOrder(), 0, "minOrder");
        assertEq(h.priorityFeeCap(), 100_000, "priorityFeeCap");
        bytes32[] memory expected = new bytes32[](13);
        expected[0] = bytes32(uint256(uint160(pm)));
        expected[1] = bytes32(uint256(uint160(_withCode(which))));
        expected[2] = bytes32(uint256(uint160(vault)));
        expected[3] = SHORT_ASYNCSWAP;
        expected[4] = SHORT_ONE;
        expected[5] = HASH_ASYNCSWAP;
        expected[6] = HASH_ONE;
        expected[7] = bytes32(uint256(block.chainid));
        expected[8] = bytes32(uint256(uint160(self)));
        expected[9] = sep;
        expected[10] = bytes32(uint256(uint160(address(0xCAFE))));
        expected[11] = bytes32(uint256(100_000)); // priorityFeeCap; the harness's zero minOrder is invisible
        expected[12] = bytes32(uint256(type(uint8).max)); // assetPrecision
        _assertImmutables(_immutables("AsyncSwapConstructor.t.sol:CtorHarness", self), expected);
        assertEq(h.domainSeparatorV4(), sep, "cached separator in the deployment environment");
    }

    /// @notice formal/Refinement/Swarm/SpecEip712AsyncSwap.lean:61 — the deployed `_name` is
    ///         `0x4173796e6353776170…09`.
    function testFuzz_CtorSpec_name_word(address pm, uint8 which, address owner_, uint64 chainId) public {
        CtorHarness h = _deploy(pm, which, owner_, chainId);
        assertTrue(_contains(_immutables("AsyncSwapConstructor.t.sol:CtorHarness", address(h)), SHORT_ASYNCSWAP));
    }

    /// @notice formal/Refinement/Swarm/SpecEip712AsyncSwap.lean:66 — the deployed `_version` is `0x31…01`.
    function testFuzz_CtorSpec_version_word(address pm, uint8 which, address owner_, uint64 chainId) public {
        CtorHarness h = _deploy(pm, which, owner_, chainId);
        assertTrue(_contains(_immutables("AsyncSwapConstructor.t.sol:CtorHarness", address(h)), SHORT_ONE));
    }

    /// @notice formal/Refinement/Swarm/SpecEip712AsyncSwap.lean:72 — `DOMAIN_SEPARATOR()` is the separator
    ///         over `keccak256("AsyncSwap")`, `keccak256("1")`, the current chain id and address, in every
    ///         environment, and writes nothing.
    function testFuzz_DOMAIN_SEPARATOR_deployed(uint64 chainId0, uint64 chainId, address at, bool moved) public {
        CtorHarness h = _deploy(address(manager), 0, address(this), chainId0);
        address self = address(h);
        if (moved) {
            vm.assume(at.code.length == 0 && uint160(at) > 0x11 && at != address(vm));
            vm.assume(at != 0x000000000000000000636F6e736F6c652e6c6f67);
            vm.etch(at, self.code);
            self = at;
        }
        vm.chainId(chainId);
        vm.record();
        bytes32 sep = AsyncSwap(payable(self)).DOMAIN_SEPARATOR();
        _assertNoWrites(self);
        assertEq(sep, _sep(HASH_ASYNCSWAP, HASH_ONE, chainId, self));
    }
}
