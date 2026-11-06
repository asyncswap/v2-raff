// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AsyncSwap} from "src/AsyncSwap.sol";
import {BaseHook} from "src/BaseHook.sol";
import {Router} from "src/Router.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ISignatureTransfer} from "@async-swap/interfaces/ISignatureTransfer.sol";

interface IEip712Probe {
    function eip712Domain()
        external
        view
        returns (bytes1, string memory, string memory, uint256, address, bytes32, uint256[] memory);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function eip712Name() external view returns (string memory);
    function eip712Version() external view returns (string memory);
}

/// @dev AsyncSwap with hook-address mining bypassed, exposing the internal `_EIP712Name` / `_EIP712Version`.
contract DomainHarness is AsyncSwap {
    constructor(IPoolManager manager, Currency quote, address owner_, address router_)
        AsyncSwap(manager, quote, owner_, router_, 0, type(uint8).max)
    {}

    function validateHookAddress(BaseHook) internal pure override {}

    function eip712Name() external view returns (string memory) {
        return _EIP712Name();
    }

    function eip712Version() external view returns (string memory) {
        return _EIP712Version();
    }
}

/// @dev Router exposing the internal `_EIP712Name` / `_EIP712Version`.
contract RouterDomainHarness is Router {
    constructor(IPoolManager manager, AsyncSwap hook_, ISignatureTransfer permit2) Router(manager, hook_, permit2, 0) {}

    function eip712Name() external view returns (string memory) {
        return _EIP712Name();
    }

    function eip712Version() external view returns (string memory) {
        return _EIP712Version();
    }
}

/// @notice The checks shared by `formal/Refinement/Swarm/AsyncSwapEip712Domain.lean` and
///         `formal/Refinement/Swarm/RouterEip712Domain.lean` (OpenZeppelin `EIP712.eip712Domain` and
///         `_EIP712Name` / `_EIP712Version`). They also discharge the files' assumptions `DomainSpec`
///         and `ShortStringSpec`. Each test runs in a fuzzed state: arbitrary words in the two
///         fallback-string slots (the name and version are short strings, so they are never read), a
///         fuzzed chain id, and optionally the code moved to another address (`vm.etch`, immutables
///         included).
abstract contract Eip712DomainChecks is Test {
    bytes32 constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    IPoolManager manager;
    MockERC20 usdc;
    DomainHarness hook;
    RouterDomainHarness router;

    function setUp() public {
        manager = new PoolManager(address(this));
        usdc = new MockERC20("USD Coin", "USDC", 6);
        hook = new DomainHarness(manager, Currency.wrap(address(usdc)), address(this), address(0xCAFE));
        router =
            new RouterDomainHarness(manager, AsyncSwap(payable(address(hook))), ISignatureTransfer(address(0xBEEF)));
    }

    function _contract() internal view virtual returns (address);
    function _expName() internal pure virtual returns (string memory);

    /// @dev The state `w` and environment `env`: fallback slots, chain id, address.
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

    function _assertNoWrites(address c) internal view {
        (, bytes32[] memory writes) = vm.accesses(c);
        assertEq(writes.length, 0, "no storage writes");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapEip712Domain.lean:72 (AsyncSwap), RouterEip712Domain.lean:47
    ///         (Router), `EIP712Name_spec` — `_EIP712Name` returns the decoded short-string name and writes nothing.
    function testFuzz_EIP712Name_spec(bytes32 fb0, bytes32 fb1, uint64 chainId, address at, bool moved) public {
        address c = _env(fb0, fb1, chainId, at, moved);
        vm.record();
        assertEq(IEip712Probe(c).eip712Name(), _expName());
        _assertNoWrites(c);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapEip712Domain.lean:80 (AsyncSwap), RouterEip712Domain.lean:55
    ///         (Router), `EIP712Version_spec` — `_EIP712Version` returns the decoded short-string version, writes nothing.
    function testFuzz_EIP712Version_spec(bytes32 fb0, bytes32 fb1, uint64 chainId, address at, bool moved) public {
        address c = _env(fb0, fb1, chainId, at, moved);
        vm.record();
        assertEq(IEip712Probe(c).eip712Version(), "1");
        _assertNoWrites(c);
    }

    function _checkDomain(address c) internal {
        vm.record();
        (
            bytes1 f,
            string memory n,
            string memory v,
            uint256 chainId,
            address verifying,
            bytes32 salt,
            uint256[] memory ex
        ) = IEip712Probe(c).eip712Domain();
        _assertNoWrites(c);
        assertEq(f, bytes1(0x0f), "fields");
        assertEq(n, _expName(), "name");
        assertEq(v, "1", "version");
        assertEq(chainId, block.chainid, "chainId");
        assertEq(verifying, c, "verifyingContract");
        assertEq(salt, bytes32(0), "salt");
        assertEq(ex.length, 0, "extensions");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapEip712Domain.lean:90 (AsyncSwap), RouterEip712Domain.lean:63
    ///         (Router), `eip712Domain_spec` — never reverts, state unchanged, returns
    ///         `(0x0f, name, version, block.chainid, address(this), 0, [])`.
    function testFuzz_eip712Domain_spec(bytes32 fb0, bytes32 fb1, uint64 chainId, address at, bool moved) public {
        _checkDomain(_env(fb0, fb1, chainId, at, moved));
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapEip712Domain.lean:98 (AsyncSwap), RouterEip712Domain.lean:70
    ///         (Router), `eip712Domain_never_reverts` — no guards.
    function testFuzz_eip712Domain_never_reverts(bytes32 fb0, bytes32 fb1, uint64 chainId, address at, bool moved)
        public
    {
        address c = _env(fb0, fb1, chainId, at, moved);
        (bool ok,) = c.staticcall(abi.encodeCall(IEip712Probe.eip712Domain, ()));
        assertTrue(ok);
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapEip712Domain.lean:106 (AsyncSwap), RouterEip712Domain.lean:75
    ///         (Router), `eip712Domain_ok` — on success: state unchanged, fields 0x0f, chainId, verifyingContract, salt 0,
    ///         no extensions, name/version as `nameStr` / `versionStr`.
    function testFuzz_eip712Domain_ok(bytes32 fb0, bytes32 fb1, uint64 chainId, address at, bool moved) public {
        address c = _env(fb0, fb1, chainId, at, moved);
        _checkDomain(c);
        assertEq(vm.load(c, bytes32(uint256(0))), fb0, "state unchanged");
        assertEq(vm.load(c, bytes32(uint256(1))), fb1, "state unchanged");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapEip712Domain.lean:119 (AsyncSwap), RouterEip712Domain.lean:85
    ///         (Router), `eip712Domain_short` — with short-string name and version the result is the decoded immutables,
    ///         independent of storage (the fallback slots hold arbitrary words here).
    function testFuzz_eip712Domain_short(bytes32 fb0, bytes32 fb1, uint64 chainId, address at, bool moved) public {
        address c = _env(fb0, fb1, chainId, at, moved);
        (, string memory n, string memory v,,,,) = IEip712Probe(c).eip712Domain();
        vm.store(c, bytes32(uint256(0)), bytes32(0));
        vm.store(c, bytes32(uint256(1)), bytes32(0));
        (, string memory n0, string memory v0,,,,) = IEip712Probe(c).eip712Domain();
        assertEq(n, n0, "name independent of storage");
        assertEq(v, v0, "version independent of storage");
        assertEq(n, _expName());
        assertEq(v, "1");
    }

    /// @notice formal/Refinement/Swarm/AsyncSwapEip712Domain.lean:132 (AsyncSwap), RouterEip712Domain.lean:93
    ///         (Router), `eip712Domain_matches_DOMAIN_SEPARATOR` — the separator rebuilt from the returned fields (ERC-5267)
    ///         is `DOMAIN_SEPARATOR()`, in every environment.
    function testFuzz_eip712Domain_matches_DOMAIN_SEPARATOR(
        bytes32 fb0,
        bytes32 fb1,
        uint64 chainId,
        address at,
        bool moved
    ) public {
        address c = _env(fb0, fb1, chainId, at, moved);
        (, string memory n, string memory v, uint256 cid, address verifying,,) = IEip712Probe(c).eip712Domain();
        bytes32 rebuilt = keccak256(abi.encode(TYPE_HASH, keccak256(bytes(n)), keccak256(bytes(v)), cid, verifying));
        assertEq(IEip712Probe(c).DOMAIN_SEPARATOR(), rebuilt, "ERC-5267 rebuild = DOMAIN_SEPARATOR");
    }
}

/// @notice Bytecode checks of `formal/Refinement/Swarm/AsyncSwapEip712Domain.lean` (lines: `EIP712Name_spec` 72,
///         `EIP712Version_spec` 80, `eip712Domain_spec` 90, `_never_reverts` 98, `_ok` 106, `_short` 119,
///         `_matches_DOMAIN_SEPARATOR` 132).
contract AsyncSwapEip712DomainFormalTest is Eip712DomainChecks {
    function _contract() internal view override returns (address) {
        return address(hook);
    }

    function _expName() internal pure override returns (string memory) {
        return "AsyncSwap";
    }
}

/// @notice Bytecode checks of `formal/Refinement/Swarm/RouterEip712Domain.lean` (lines: `EIP712Name_spec` 47,
///         `EIP712Version_spec` 55, `eip712Domain_spec` 63, `_never_reverts` 70, `_ok` 75, `_short` 85,
///         `_matches_DOMAIN_SEPARATOR` 93).
contract RouterEip712DomainFormalTest is Eip712DomainChecks {
    function _contract() internal view override returns (address) {
        return address(router);
    }

    function _expName() internal pure override returns (string memory) {
        return "AsyncSwap Router";
    }
}
