// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AsyncSwap} from "src/AsyncSwap.sol";
import {Router} from "src/Router.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {ISignatureTransfer} from "@async-swap/interfaces/ISignatureTransfer.sol";
import {FormalImmutablesC} from "./FormalImmutablesC.sol";

/// @dev The real Router, exposing the internal `_domainSeparatorV4`.
contract RouterCtorHarness is Router {
    constructor(IPoolManager manager, AsyncSwap hook_, ISignatureTransfer permit2) Router(manager, hook_, permit2, 0) {}

    function domainSeparatorV4() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}

/// @notice Bytecode checks of `formal/Refinement/Swarm/RouterConstructor.lean`, which also discharge its named
///         assumption `Router.Swarm.Constructor.CtorSpec`: no guards, no storage writes, `POOLMANAGER` /
///         `HOOK` / `PERMIT2` as passed, and OpenZeppelin `EIP712("AsyncSwap Router", "1")`'s immutables.
///         `POOLMANAGER` and `HOOK` have no getters, so every immutable is read back from the deployed code
///         (`FormalImmutablesC`).
contract RouterConstructorFormalTest is FormalImmutablesC {
    bytes32 constant TYPE_HASH = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;
    bytes32 constant HASH_ASYNCSWAP_ROUTER = 0x08476627fc511b8f0bf0674a96c4492f05a5c5df2795822dac01ecd5bdbd9167;
    bytes32 constant HASH_ONE = 0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6;
    bytes32 constant SHORT_ASYNCSWAP_ROUTER = 0x4173796e635377617020526f7574657200000000000000000000000000000010;
    bytes32 constant SHORT_ONE = 0x3100000000000000000000000000000000000000000000000000000000000001;
    string constant ARTIFACT = "RouterConstructor.t.sol:RouterCtorHarness";

    function _deploy(address pm, address hk, address p2) internal returns (bool ok, address a) {
        try new RouterCtorHarness(IPoolManager(pm), AsyncSwap(payable(hk)), ISignatureTransfer(p2)) returns (
            RouterCtorHarness r
        ) {
            return (true, address(r));
        } catch {
            return (false, address(0));
        }
    }

    function _sep(uint256 chainId, address self) internal pure returns (bytes32) {
        return keccak256(abi.encode(TYPE_HASH, HASH_ASYNCSWAP_ROUTER, HASH_ONE, chainId, self));
    }

    function _word(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /// @dev Deploys at a fuzzed chain id and checks the storage half: success and no storage writes.
    function _deployed(address pm, address hk, address p2, uint64 chainId) internal returns (address a) {
        vm.chainId(chainId);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.record();
        bool ok;
        (ok, a) = _deploy(pm, hk, p2);
        assertTrue(ok, "never reverts");
        assertEq(a, predicted);
        (, bytes32[] memory writes) = vm.accesses(a);
        assertEq(writes.length, 0, "no storage writes");
        for (uint256 s; s < 3; s++) {
            assertEq(vm.load(a, bytes32(s)), bytes32(0), "storage untouched");
        }
    }

    function _env(address a, address at, bool moved, uint64 chainId) internal returns (address) {
        vm.chainId(chainId);
        if (!moved) return a;
        vm.assume(at.code.length == 0 && uint160(at) > 0x11 && at != address(vm));
        vm.assume(at != 0x000000000000000000636F6e736F6c652e6c6f67);
        vm.etch(at, a.code);
        return at;
    }

    /// @notice formal/Refinement/Swarm/RouterConstructor.lean:51 `CtorSpec` — every field: no guards and no
    ///         storage writes (`storage`), `POOLMANAGER = pm`, `HOOK = hk`, `PERMIT2 = p2`, and `EIP712Ctor`
    ///         (`_name` / `_version` short strings, `_hashedName = keccak256("AsyncSwap Router")`,
    ///         `_hashedVersion = keccak256("1")`, `_cachedChainId = block.chainid`, `_cachedThis = address(this)`,
    ///         the separator built at deployment). The deployed code's immutables are exactly these.
    function testFuzz_CtorSpec(address pm, address hk, address p2, uint64 chainId) public {
        address a = _deployed(pm, hk, p2, chainId);
        assertEq(address(Router(payable(a)).PERMIT2()), p2, "PERMIT2");
        bytes32[] memory expected = new bytes32[](10);
        expected[0] = _word(pm);
        expected[1] = _word(hk);
        expected[2] = _word(p2);
        expected[3] = SHORT_ASYNCSWAP_ROUTER;
        expected[4] = SHORT_ONE;
        expected[5] = HASH_ASYNCSWAP_ROUTER;
        expected[6] = HASH_ONE;
        expected[7] = bytes32(uint256(chainId));
        expected[8] = _word(a);
        expected[9] = _sep(chainId, a);
        _assertImmutables(_immutables(ARTIFACT, a), expected);
        assertEq(RouterCtorHarness(payable(a)).domainSeparatorV4(), _sep(chainId, a), "cached separator");
    }

    /// @notice formal/Refinement/Swarm/RouterConstructor.lean:66 — `TYPE_HASH` is the EIP-712 domain type hash.
    function test_typeHash_eq() public pure {
        assertEq(
            TYPE_HASH, keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
        );
    }

    /// @notice formal/Refinement/Swarm/RouterConstructor.lean:69 — the deployed `_name` is
    ///         `0x4173796e635377617020526f75746572…10`.
    function testFuzz_CtorSpec_name_word(address pm, address hk, address p2, uint64 chainId) public {
        address a = _deployed(pm, hk, p2, chainId);
        assertTrue(_contains(_immutables(ARTIFACT, a), SHORT_ASYNCSWAP_ROUTER));
    }

    /// @notice formal/Refinement/Swarm/RouterConstructor.lean:74 — the deployed `_version` is `0x31…01`.
    function testFuzz_CtorSpec_version_word(address pm, address hk, address p2, uint64 chainId) public {
        address a = _deployed(pm, hk, p2, chainId);
        assertTrue(_contains(_immutables(ARTIFACT, a), SHORT_ONE));
    }

    /// @notice formal/Refinement/Swarm/RouterConstructor.lean:79 — the constructor never reverts, whatever
    ///         the arguments.
    function testFuzz_ctor_never_reverts(address pm, address hk, address p2) public {
        (bool ok,) = _deploy(pm, hk, p2);
        assertTrue(ok);
    }

    /// @notice formal/Refinement/Swarm/RouterConstructor.lean:85 — a successful constructor writes no storage.
    function testFuzz_ctor_ok(address pm, address hk, address p2, uint64 chainId) public {
        _deployed(pm, hk, p2, chainId);
    }

    /// @notice formal/Refinement/Swarm/RouterConstructor.lean:91 — the deployment fixes `POOLMANAGER`,
    ///         `HOOK`, `PERMIT2`, `_cachedThis = address(this)` and `_cachedChainId = block.chainid`.
    function testFuzz_ctor_deployed(address pm, address hk, address p2, uint64 chainId) public {
        address a = _deployed(pm, hk, p2, chainId);
        bytes32[] memory imm = _immutables(ARTIFACT, a);
        if (pm != address(0)) assertTrue(_contains(imm, _word(pm)), "POOLMANAGER");
        if (hk != address(0)) assertTrue(_contains(imm, _word(hk)), "HOOK");
        assertEq(address(Router(payable(a)).PERMIT2()), p2, "PERMIT2");
        assertTrue(_contains(imm, _word(a)), "_cachedThis");
        if (chainId != 0) assertTrue(_contains(imm, bytes32(uint256(chainId))), "_cachedChainId");
    }

    /// @notice formal/Refinement/Swarm/RouterConstructor.lean:98 — `_domainSeparatorV4` writes nothing
    ///         and returns the separator built from the current `block.chainid` and `address(this)`.
    function testFuzz_domainSeparatorV4_eq_built(uint64 chainId0, uint64 chainId, address at, bool moved) public {
        address a = _env(_deployed(address(1), address(2), address(3), chainId0), at, moved, chainId);
        vm.record();
        bytes32 sep = RouterCtorHarness(payable(a)).domainSeparatorV4();
        (, bytes32[] memory writes) = vm.accesses(a);
        assertEq(writes.length, 0, "no writes");
        assertEq(sep, _sep(chainId, a));
    }

    /// @notice formal/Refinement/Swarm/RouterConstructor.lean:112 — `DOMAIN_SEPARATOR()` is the separator
    ///         rebuilt from the current chain id and address, in every environment.
    function testFuzz_DOMAIN_SEPARATOR_eq_built(uint64 chainId0, uint64 chainId, address at, bool moved) public {
        address a = _env(_deployed(address(1), address(2), address(3), chainId0), at, moved, chainId);
        vm.record();
        bytes32 sep = Router(payable(a)).DOMAIN_SEPARATOR();
        (, bytes32[] memory writes) = vm.accesses(a);
        assertEq(writes.length, 0, "no writes");
        assertEq(sep, _sep(chainId, a));
    }

    /// @notice formal/Refinement/Swarm/RouterConstructor.lean:126 — with the deployed hashes,
    ///         `DOMAIN_SEPARATOR()` is the separator over `keccak256("AsyncSwap Router")`, `keccak256("1")`.
    function testFuzz_DOMAIN_SEPARATOR_deployed(uint64 chainId0, uint64 chainId, address at, bool moved) public {
        address a = _env(_deployed(address(1), address(2), address(3), chainId0), at, moved, chainId);
        assertEq(HASH_ASYNCSWAP_ROUTER, keccak256("AsyncSwap Router"));
        assertEq(HASH_ONE, keccak256("1"));
        assertEq(
            Router(payable(a)).DOMAIN_SEPARATOR(),
            keccak256(abi.encode(TYPE_HASH, keccak256("AsyncSwap Router"), keccak256("1"), chainId, a))
        );
    }
}
