// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FormalProbesA} from "./FormalProbesA.sol";
import {IAsyncSwap as AsyncSwap} from "src/interface/IAsyncSwap.sol";
import {IRouter as Router} from "src/interface/IRouter.sol";
import {OrderSignatures} from "test/utils/OrderSignatures.sol";
import {AsyncOrder} from "src/interface/types/AsyncOrder.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice The real OpenZeppelin `SignatureChecker` / `MessageHashUtils` and the project's
///         `OrderSignatures`, compiled with the project's settings. Every function is `external` and
///         only forwards to the internal library function.
contract SigLibHarness {
    function isValidERC1271SignatureNow(address signer, bytes32 hash, bytes memory sig) external view returns (bool) {
        return SignatureChecker.isValidERC1271SignatureNow(signer, hash, sig);
    }

    function toTypedDataHash(bytes32 d, bytes32 s) external pure returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(d, s);
    }

    function hashPoolKey(PoolKey memory k) external pure returns (bytes32) {
        return OrderSignatures.hashPoolKey(k);
    }

    function hashSetExecutor(PoolKey memory k, address m, address e, bool a, uint256 n, uint256 d)
        external
        pure
        returns (bytes32)
    {
        return OrderSignatures.hashSetExecutor(k, m, e, a, n, d);
    }

    function poolKeyTypehash() external pure returns (bytes32) {
        return OrderSignatures.POOL_KEY_TYPEHASH;
    }

    function setExecutorTypehash() external pure returns (bytes32) {
        return OrderSignatures.SET_EXECUTOR_TYPEHASH;
    }
}

/// @notice A scripted ERC-1271 signer. `configure` sets its answer; every other call lands in the
///         fallback, which only reads storage: it reverts or returns `ret` as configured. With
///         `gate != 0` it answers only when `keccak256(msg.data) == gate`, and otherwise reverts, so a
///         `true` verdict proves the exact calldata. With `tryWrite` it first writes a slot, which
///         fails under `staticcall`.
contract Wallet1271 {
    bool fail;
    bool tryWrite;
    bytes32 gate;
    bytes ret;
    uint256 sink;

    function configure(bool fail_, bytes memory ret_, bytes32 gate_, bool tryWrite_) external {
        fail = fail_;
        ret = ret_;
        gate = gate_;
        tryWrite = tryWrite_;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        if (gate != bytes32(0) && keccak256(data) != gate) revert("calldata");
        if (tryWrite) sink = 1;
        bytes memory r = ret;
        if (fail) {
            assembly ("memory-safe") {
                revert(add(r, 0x20), mload(r))
            }
        }
        assembly ("memory-safe") {
            return(add(r, 0x20), mload(r))
        }
    }
}

/// @notice Bytecode checks of the named specs in `formal/Refinement/Swarm/SpecSigAsyncSwap.lean` and
///         `SpecSigRouter.lean`. Each spec field is checked on the library code through
///         `SigLibHarness`, and on the hook's and the Router's own compiled copies through the entry
///         points that reach them (`setExecutorWithSig`, `cancelWithSig`). Expected values come from
///         the Lean definitions restated here (`_leanCalldata`, `_leanVerdict`, `_leanPreimage`,
///         `_leanPoolKeyHash`, `_leanSetExecutorHash`), never from the code under test.
contract SpecSigFormalTest is FormalProbesA {
    using PoolIdLibrary for PoolKey;

    // The Lean words (`SpecSigAsyncSwap.lean`).
    bytes32 constant POOL_KEY_TYPEHASH = 0x90172dcd3ace21b906ae6acfb8cc73a023df1317b7cda09eeda9489ed5604ae5;
    bytes32 constant SET_EXECUTOR_TYPEHASH = 0xe4479d9c4dc3f7c35677efc85aaca516cb63a3977aae04f893f8c6b86986c965;
    bytes32 constant ERC1271_MAGIC = bytes32(uint256(0x1626ba7e) << 224);

    SigLibHarness lib;
    Wallet1271 wallet;

    function setUp() public override {
        super.setUp();
        lib = new SigLibHarness();
        wallet = new Wallet1271();
        vm.warp(1_000_000);
    }

    // ---------------------------------------------------------------- the Lean definitions, restated

    /// @dev `erc1271Calldata hash sig = SELECTOR ++ abiEncode [hash, 0x40] ++ abiBytes sig`.
    function _leanCalldata(bytes32 hash, bytes memory sig) internal pure returns (bytes memory) {
        uint256 pad = (32 - sig.length % 32) % 32;
        return bytes.concat(bytes4(0x1626ba7e), hash, bytes32(uint256(0x40)), bytes32(sig.length), sig, new bytes(pad));
    }

    /// @dev `erc1271Verdict (success, ret) = success && 32 ≤ |ret| && bytesWord (take 32 ret) == MAGIC`.
    function _leanVerdict(bool success, bytes memory ret) internal pure returns (bool) {
        if (!success || ret.length < 32) return false;
        bytes32 w;
        assembly ("memory-safe") {
            w := mload(add(ret, 0x20))
        }
        return w == ERC1271_MAGIC;
    }

    /// @dev `typedPreimage d s = [0x19, 0x01] ++ wordBytes d ++ wordBytes s`.
    function _leanPreimage(bytes32 d, bytes32 s) internal pure returns (bytes memory) {
        return bytes.concat(bytes1(0x19), bytes1(0x01), d, s);
    }

    /// @dev `poolKeyHash k = keccak [POOL_KEY_TYPEHASH, c0, c1, fee, toUnsigned 256 tickSpacing, hooks]`.
    function _leanPoolKeyHash(PoolKey memory k) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                POOL_KEY_TYPEHASH,
                uint256(uint160(Currency.unwrap(k.currency0))),
                uint256(uint160(Currency.unwrap(k.currency1))),
                uint256(k.fee),
                uint256(int256(k.tickSpacing)), // two's complement word = toUnsigned 256
                uint256(uint160(address(k.hooks)))
            )
        );
    }

    /// @dev `setExecutorHash k m e a n d = keccak [SET_EXECUTOR_TYPEHASH, m, e, ybool a, poolKeyHash k, n, d]`.
    function _leanSetExecutorHash(PoolKey memory k, address m, address e, bool a, uint256 n, uint256 d)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                SET_EXECUTOR_TYPEHASH, uint256(uint160(m)), uint256(uint160(e)), a ? 1 : 0, _leanPoolKeyHash(k), n, d
            )
        );
    }

    /// @dev `domainSep env`: the cached separator on the deployment chain, else `keccak [TYPE_HASH,
    ///      hashedName, hashedVersion, chainid, self]`.
    function _leanDomainSep(string memory name, address self) internal view returns (bytes32) {
        return keccak256(abi.encode(EIP712_TYPE_HASH, keccak256(bytes(name)), keccak256("1"), block.chainid, self));
    }

    function _fuzzKey(address c0, address c1, uint24 fee, int24 ts, address hooks)
        internal
        pure
        returns (PoolKey memory k)
    {
        k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, ts, IHooks(hooks));
    }

    /// @dev Script the wallet; `ret` is fuzzed, `magic` forces its first word to the magic value.
    function _script(bool fail, bytes memory ret, bool magic, uint8 extra, bytes32 gate, bool tryWrite)
        internal
        returns (bytes memory r)
    {
        r = ret;
        if (magic) r = bytes.concat(ERC1271_MAGIC, new bytes(extra % 64));
        wallet.configure(fail, r, gate, tryWrite);
    }

    /// @dev A signature that `ECDSA.tryRecover` rejects without recovering (length ≠ 65), so the ERC-1271
    ///      path decides.
    function _non65(bytes memory sig) internal pure returns (bytes memory) {
        if (sig.length == 65) return bytes.concat(sig, hex"00");
        return sig;
    }

    /// @dev The wallet's storage is unchanged. `vm.accesses` also lists an SSTORE that the
    ///      `staticcall` rejected, so a writing wallet is checked through its `sink` slot instead.
    function _assertWalletUnwritten(bool tryWrite) internal {
        if (tryWrite) assertEq(vm.load(address(wallet), bytes32(uint256(3))), bytes32(0), "wallet not written");
        else _assertNoWrites(address(wallet));
    }

    // ================================================================ ERC1271Spec (library code)

    /// @notice formal/Refinement/Swarm/SpecSigAsyncSwap.lean:101 — ERC1271Spec.total: the call never
    ///         reverts, whatever the signer does (returns, reverts, writes, has no code, is a precompile).
    function testFuzz_ERC1271Spec_total(
        uint8 kind,
        bool fail,
        bytes memory ret,
        bool magic,
        uint8 extra,
        bool tryWrite,
        bytes32 hash,
        bytes memory sig
    ) public {
        _script(fail, ret, magic, extra, bytes32(0), tryWrite);
        address signer = kind % 4 == 0
            ? address(wallet)
            : kind % 4 == 1 ? makeAddr("eoa") : kind % 4 == 2 ? address(4) : address(hook);
        (bool ok,) = address(lib).call(abi.encodeCall(SigLibHarness.isValidERC1271SignatureNow, (signer, hash, sig)));
        assertTrue(ok, "never reverts");
    }

    /// @notice formal/Refinement/Swarm/SpecSigAsyncSwap.lean:104 — ERC1271Spec.readOnly: no storage write,
    ///         not in the caller and not in the signer; a signer that tries to write gets a failed
    ///         `staticcall` (verdict false).
    function testFuzz_ERC1271Spec_readOnly(
        bool fail,
        bytes memory ret,
        bool magic,
        uint8 extra,
        bool tryWrite,
        bytes32 hash,
        bytes memory sig
    ) public {
        bytes memory r = _script(fail, ret, magic, extra, bytes32(0), tryWrite);
        vm.record();
        (bool ok, bytes memory out) =
            address(lib).call(abi.encodeCall(SigLibHarness.isValidERC1271SignatureNow, (address(wallet), hash, sig)));
        assertTrue(ok);
        _assertNoWrites(address(lib));
        _assertWalletUnwritten(tryWrite);
        if (tryWrite) assertFalse(abi.decode(out, (bool)), "a writing signer fails the staticcall");
        else assertEq(abi.decode(out, (bool)), _leanVerdict(!fail, r));
    }

    /// @notice formal/Refinement/Swarm/SpecSigAsyncSwap.lean:106 — ERC1271Spec.result: the result is
    ///         `erc1271Verdict(signer.staticcall(erc1271Calldata hash sig))`, with the exact calldata.
    function testFuzz_ERC1271Spec_result(
        bool fail,
        bytes memory ret,
        bool magic,
        uint8 extra,
        bytes32 hash,
        bytes memory sig
    ) public {
        bytes memory r = _script(fail, ret, magic, extra, bytes32(0), false);
        vm.expectCall(address(wallet), _leanCalldata(hash, sig), 1);
        assertEq(lib.isValidERC1271SignatureNow(address(wallet), hash, sig), _leanVerdict(!fail, r));
    }

    /// @notice formal/Refinement/Swarm/SpecSigAsyncSwap.lean:106 — ERC1271Spec.result: the calldata is
    ///         exactly `erc1271Calldata` (the wallet answers the magic value only to those bytes).
    function testFuzz_ERC1271Spec_result_calldata(bytes32 hash, bytes memory sig, bytes32 otherHash) public {
        _script(false, "", true, 0, keccak256(_leanCalldata(hash, sig)), false);
        assertTrue(lib.isValidERC1271SignatureNow(address(wallet), hash, sig), "exact calldata accepted");
        vm.assume(otherHash != hash);
        assertFalse(lib.isValidERC1271SignatureNow(address(wallet), otherHash, sig), "other calldata reverts: false");
    }

    /// @notice formal/Refinement/Swarm/SpecSigAsyncSwap.lean:106 — ERC1271Spec.result for the world's
    ///         other answers: no code is `(true, [])` (false); the identity precompile echoes the
    ///         calldata, whose first word is `selector ‖ hash[0:28]`, so the verdict is `hash < 2^32`.
    function testFuzz_ERC1271Spec_result_noCode_precompile(bytes32 hash, bytes memory sig, uint32 small) public {
        assertFalse(lib.isValidERC1271SignatureNow(makeAddr("eoa"), hash, sig), "no code: false");
        assertEq(
            lib.isValidERC1271SignatureNow(address(4), hash, sig),
            _leanVerdict(true, _leanCalldata(hash, sig)),
            "identity precompile"
        );
        assertTrue(lib.isValidERC1271SignatureNow(address(4), bytes32(uint256(small)), sig), "echo of a small hash");
    }

    // ================================================================ TypedDataHashSpec (library code)

    /// @notice formal/Refinement/Swarm/SpecSigAsyncSwap.lean:114 — TypedDataHashSpec.total: never reverts.
    function testFuzz_TypedDataHashSpec_total(bytes32 d, bytes32 s) public {
        (bool ok,) = address(lib).call(abi.encodeCall(SigLibHarness.toTypedDataHash, (d, s)));
        assertTrue(ok);
    }

    /// @notice formal/Refinement/Swarm/SpecSigAsyncSwap.lean:116 — TypedDataHashSpec.readOnly: no storage write.
    function testFuzz_TypedDataHashSpec_readOnly(bytes32 d, bytes32 s) public {
        vm.record();
        lib.toTypedDataHash(d, s);
        _assertNoWrites(address(lib));
    }

    /// @notice formal/Refinement/Swarm/SpecSigAsyncSwap.lean:119 — TypedDataHashSpec.result: the digest is
    ///         `keccak256(typedPreimage d s)`, the 66 bytes `0x19 0x01 ‖ d ‖ s`, in any environment.
    function testFuzz_TypedDataHashSpec_result(bytes32 d, bytes32 s, address sender, uint64 chainId, uint256 ts)
        public
    {
        bytes memory pre = _leanPreimage(d, s);
        assertEq(pre.length, 66);
        vm.chainId(chainId);
        vm.warp(ts);
        vm.prank(sender);
        assertEq(lib.toTypedDataHash(d, s), keccak256(pre));
    }

    // ================================================================ HashSetExecutorSpec / HashPoolKeySpec

    /// @notice formal/Refinement/Swarm/SpecSigAsyncSwap.lean:52 — the Lean words: POOL_KEY_TYPEHASH and
    ///         SET_EXECUTOR_TYPEHASH are the library's constants and the keccak of their type strings;
    ///         ERC1271_SELECTOR / ERC1271_MAGIC are `IERC1271.isValidSignature.selector`.
    function test_SpecSig_typehash_words() public view {
        assertEq(lib.poolKeyTypehash(), POOL_KEY_TYPEHASH);
        assertEq(lib.setExecutorTypehash(), SET_EXECUTOR_TYPEHASH);
        assertEq(
            POOL_KEY_TYPEHASH,
            keccak256("PoolKey(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)")
        );
        assertEq(
            SET_EXECUTOR_TYPEHASH,
            keccak256(
                "SetExecutor(address maker,address executor,bool allow,PoolKey pool,uint256 nonce,uint256 deadline)PoolKey(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)"
            )
        );
        assertEq(IERC1271.isValidSignature.selector, bytes4(0x1626ba7e), "ERC1271_SELECTOR");
        assertEq(ERC1271_MAGIC, bytes32(IERC1271.isValidSignature.selector), "ERC1271_MAGIC");
    }

    /// @notice formal/Refinement/Swarm/SpecSigAsyncSwap.lean:125 — HashSetExecutorSpec.total + readOnly:
    ///         never reverts, writes nothing.
    function testFuzz_HashSetExecutorSpec_total_readOnly(
        address c0,
        address c1,
        uint24 fee,
        int24 ts,
        address hooks,
        address m,
        address e,
        bool a,
        uint256 n,
        uint256 d
    ) public {
        PoolKey memory k = _fuzzKey(c0, c1, fee, ts, hooks);
        vm.record();
        (bool ok,) = address(lib).call(abi.encodeCall(SigLibHarness.hashSetExecutor, (k, m, e, a, n, d)));
        assertTrue(ok);
        _assertNoWrites(address(lib));
    }

    /// @notice formal/Refinement/Swarm/SpecSigAsyncSwap.lean:129 — HashSetExecutorSpec.result: equals
    ///         `setExecutorHash` (negative tick spacings included).
    function testFuzz_HashSetExecutorSpec_result(
        address c0,
        address c1,
        uint24 fee,
        int24 ts,
        address hooks,
        address m,
        address e,
        bool a,
        uint256 n,
        uint256 d
    ) public view {
        PoolKey memory k = _fuzzKey(c0, c1, fee, ts, hooks);
        assertEq(lib.hashSetExecutor(k, m, e, a, n, d), _leanSetExecutorHash(k, m, e, a, n, d));
    }

    /// @notice formal/Refinement/Swarm/SpecSigAsyncSwap.lean:135 — HashPoolKeySpec.total + readOnly:
    ///         never reverts, writes nothing.
    function testFuzz_HashPoolKeySpec_total_readOnly(address c0, address c1, uint24 fee, int24 ts, address hooks)
        public
    {
        PoolKey memory k = _fuzzKey(c0, c1, fee, ts, hooks);
        vm.record();
        (bool ok,) = address(lib).call(abi.encodeCall(SigLibHarness.hashPoolKey, (k)));
        assertTrue(ok);
        _assertNoWrites(address(lib));
    }

    /// @notice formal/Refinement/Swarm/SpecSigAsyncSwap.lean:139 — HashPoolKeySpec.result: equals `poolKeyHash`.
    function testFuzz_HashPoolKeySpec_result(address c0, address c1, uint24 fee, int24 ts, address hooks) public view {
        PoolKey memory k = _fuzzKey(c0, c1, fee, ts, hooks);
        assertEq(lib.hashPoolKey(k), _leanPoolKeyHash(k));
    }

    // ================================================================ the hook's own copies

    /// @dev `setExecutorWithSig` from `maker` with `sig`; returns whether it succeeded.
    function _hookSet(address maker, address e, bool allow, uint256 nonce, uint256 deadline, bytes memory sig)
        internal
        returns (bool ok, bytes memory err)
    {
        (ok, err) = address(hook)
            .call(abi.encodeCall(AsyncSwap.setExecutorWithSig, (key, maker, e, allow, nonce, deadline, sig)));
    }

    /// @notice formal/Refinement/Swarm/SpecSigAsyncSwap.lean:99 — ERC1271Spec (total, readOnly, result) on
    ///         the hook's `_2280`: with a contract maker, `setExecutorWithSig` succeeds iff
    ///         `erc1271Verdict` of the wallet's answer to `erc1271Calldata(digest, sig)` holds, and
    ///         otherwise reverts `InvalidSignature` (never another error); the wallet is not written.
    function testFuzz_ERC1271Spec_onHook(
        bool fail,
        bytes memory ret,
        bool magic,
        uint8 extra,
        bool tryWrite,
        address e,
        bool allow,
        uint256 nonce,
        bytes memory sig
    ) public {
        sig = _non65(sig);
        uint256 deadline = block.timestamp + 1;
        bytes memory r = _script(fail, ret, magic, extra, bytes32(0), tryWrite);
        bytes32 digest = keccak256(
            _leanPreimage(
                _leanDomainSep("AsyncSwap", address(hook)),
                _leanSetExecutorHash(key, address(wallet), e, allow, nonce, deadline)
            )
        );
        vm.expectCall(address(wallet), _leanCalldata(digest, sig), 1);
        vm.record();
        (bool ok, bytes memory err) = _hookSet(address(wallet), e, allow, nonce, deadline, sig);
        _assertWalletUnwritten(tryWrite);
        bool verdict = !tryWrite && _leanVerdict(!fail, r);
        assertEq(ok, verdict, "success iff the ERC-1271 verdict");
        if (!ok) assertEq(bytes4(err), AsyncSwap.InvalidSignature.selector);
        else assertEq(hook.isExecutor(poolId, address(wallet), e), allow);
    }

    /// @notice formal/Refinement/Swarm/SpecSigAsyncSwap.lean:129 — HashSetExecutorSpec.result and
    ///         TypedDataHashSpec.result on the hook's `_9244` / `_9732`: an EOA signature over
    ///         `keccak256(typedPreimage(domainSep, setExecutorHash ...))`, all computed from the Lean
    ///         definitions, is accepted (and any tick spacing, negative included, is bound).
    function testFuzz_HashSetExecutorSpec_onHook(
        uint256 pkSeed,
        int24 ts,
        address e,
        bool allow,
        uint256 nonce,
        uint256 deadline
    ) public {
        uint256 pk = _pk(pkSeed);
        address maker = vm.addr(pk);
        deadline = bound(deadline, block.timestamp, type(uint256).max);
        PoolKey memory k = key;
        k.tickSpacing = ts;
        bytes32 digest = keccak256(
            _leanPreimage(
                _leanDomainSep("AsyncSwap", address(hook)), _leanSetExecutorHash(k, maker, e, allow, nonce, deadline)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        hook.setExecutorWithSig(k, maker, e, allow, nonce, deadline, abi.encodePacked(r, s, v));
        assertEq(hook.isExecutor(k.toId(), maker, e), allow);
    }

    /// @notice formal/Refinement/Swarm/SpecSigAsyncSwap.lean:214 — hashTypedDataV4_run on the hook:
    ///         the digest is `keccak256(0x1901 ‖ domainSep env ‖ sh)` on both branches of `domainSep`
    ///         (the cached separator, and the rebuilt one after a chain-id change), seen in the
    ///         ERC-1271 calldata.
    function testFuzz_hashTypedDataV4_run(uint64 chainId, address e, bool allow, uint256 nonce, bytes memory sig)
        public
    {
        sig = _non65(sig);
        if (chainId % 2 == 1) vm.chainId(chainId);
        uint256 deadline = block.timestamp;
        bytes32 digest = keccak256(
            _leanPreimage(
                _leanDomainSep("AsyncSwap", address(hook)),
                _leanSetExecutorHash(key, address(wallet), e, allow, nonce, deadline)
            )
        );
        _script(false, "", true, 0, keccak256(_leanCalldata(digest, sig)), false);
        (bool ok,) = _hookSet(address(wallet), e, allow, nonce, deadline, sig);
        assertTrue(ok, "the wallet saw exactly the Lean digest");
    }

    /// @notice formal/Refinement/Swarm/SpecSigAsyncSwap.lean:223 — tryRecover_9821_ok: ECDSA recovery
    ///         never reverts and writes nothing: any signature bytes for an EOA maker end in
    ///         `InvalidSignature` (a staticcall to the code-less maker answers false), never another error.
    function testFuzz_tryRecover_9821_ok(address e, bool allow, uint256 nonce, bytes memory sig, uint256 pkSeed)
        public
    {
        address maker = vm.addr(_pk(pkSeed));
        vm.expectRevert(AsyncSwap.InvalidSignature.selector);
        hook.setExecutorWithSig(key, maker, e, allow, nonce, block.timestamp, sig);
    }

    function _hookDigest(address maker, address e, bool allow, uint256 nonce) internal view returns (bytes32) {
        return keccak256(
            _leanPreimage(
                _leanDomainSep("AsyncSwap", address(hook)),
                _leanSetExecutorHash(key, maker, e, allow, nonce, block.timestamp)
            )
        );
    }

    /// @notice formal/Refinement/Swarm/SpecSigAsyncSwap.lean:240 — isValidSignatureNow_run on the hook:
    ///         the result is `(ECDSA recovered maker) || erc1271Verdict`. A valid EOA signature succeeds
    ///         with no ERC-1271 call; an ECDSA-recoverable signature of another key, sent for the wallet,
    ///         falls through to the wallet's verdict.
    function testFuzz_isValidSignatureNow_run(
        uint256 pkSeed,
        bool fail,
        bytes memory ret,
        bool magic,
        address e,
        bool allow,
        uint256 nonce
    ) public {
        uint256 pk = _pk(pkSeed);
        address maker = vm.addr(pk);
        bytes32 dEoa = _hookDigest(maker, e, allow, nonce);
        bytes memory sig = _signSig(pk, dEoa);
        vm.expectCall(maker, _leanCalldata(dEoa, sig), 0);
        (bool ok,) = _hookSet(maker, e, allow, nonce, block.timestamp, sig);
        assertTrue(ok, "ECDSA path: true without a staticcall");

        bytes memory rr = _script(fail, ret, magic, 0, bytes32(0), false);
        sig = _signSig(pk, _hookDigest(address(wallet), e, allow, nonce)); // recovers `maker`, not the wallet
        (ok,) = _hookSet(address(wallet), e, allow, nonce, block.timestamp, sig);
        assertEq(ok, _leanVerdict(!fail, rr), "wallet: the ERC-1271 verdict decides");
    }

    // ================================================================ the Router's own copies

    function _walletOrder(AsyncOrder memory o) internal view {
        o.owner = address(wallet);
        o.key = key;
    }

    function _routerCancelDigest(AsyncOrder memory o, uint256 amountIn, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            _leanPreimage(
                _leanDomainSep("AsyncSwap Router", address(router)),
                OrderSignatures.hashCancel(o, _routerOrderId(o), amountIn, hook.orderCreatedSequence(o.key.toId(), _routerOrderId(o)), nonce, deadline)
            )
        );
    }

    function _mockInfo(AsyncOrder memory o, uint256 amountIn) internal {
        vm.mockCall(
            address(hook),
            abi.encodeCall(AsyncSwap.asyncOrderInfo, (o.key.toId(), _routerOrderId(o))),
            abi.encode(amountIn, uint256(0))
        );
    }

    /// @notice formal/Refinement/Swarm/SpecSigRouter.lean:78 — ERC1271Spec (total, readOnly, result) on
    ///         the Router's `_1883`: with a contract owner, `cancelWithSig` reaches `unlock` iff
    ///         `erc1271Verdict` of the wallet's answer to `erc1271Calldata(digest, sig)` holds, and
    ///         otherwise reverts `InvalidSignature`; the wallet is not written.
    function testFuzz_ERC1271Spec_onRouter(
        AsyncOrder memory o,
        bool fail,
        bytes memory ret,
        bool magic,
        uint8 extra,
        bool tryWrite,
        uint256 amountIn,
        uint256 nonce,
        bytes memory sig
    ) public {
        _walletOrder(o);
        sig = _non65(sig);
        uint256 deadline = block.timestamp;
        bytes memory r = _script(fail, ret, magic, extra, bytes32(0), tryWrite);
        _mockInfo(o, amountIn);
        _mockUnlockOk();
        vm.expectCall(address(wallet), _leanCalldata(_routerCancelDigest(o, amountIn, nonce, deadline), sig), 1);
        vm.record();
        (bool ok, bytes memory err) =
            address(router).call(abi.encodeCall(Router.cancelWithSig, (o, nonce, deadline, sig)));
        _assertWalletUnwritten(tryWrite);
        assertEq(ok, !tryWrite && _leanVerdict(!fail, r), "success iff the ERC-1271 verdict");
        if (!ok) assertEq(bytes4(err), Router.InvalidSignature.selector);
    }

    /// @notice formal/Refinement/Swarm/SpecSigRouter.lean:165 — hashTypedDataV4_run / TypedDataHashSpec.result
    ///         on the Router's `_5799`: the digest is `keccak256(0x1901 ‖ domainSep env ‖ hashCancel)` on
    ///         both branches of `domainSep`, seen in the ERC-1271 calldata.
    function testFuzz_hashTypedDataV4_run_router(
        AsyncOrder memory o,
        uint64 chainId,
        uint256 amountIn,
        uint256 nonce,
        bytes memory sig
    ) public {
        _walletOrder(o);
        sig = _non65(sig);
        if (chainId % 2 == 1) vm.chainId(chainId);
        uint256 deadline = block.timestamp;
        _mockInfo(o, amountIn);
        _mockUnlockOk();
        _script(
            false, "", true, 0, keccak256(_leanCalldata(_routerCancelDigest(o, amountIn, nonce, deadline), sig)), false
        );
        router.cancelWithSig(o, nonce, deadline, sig);
        assertEq(vm.load(address(router), _cancelNonceSlot(o.owner, nonce)), bytes32(uint256(1)));
    }

    /// @notice formal/Refinement/Swarm/SpecSigRouter.lean:174 — tryRecover_5888_ok: any signature bytes for
    ///         a code-less owner end in `InvalidSignature`, never another error.
    function testFuzz_tryRecover_5888_ok(
        AsyncOrder memory o,
        uint256 pkSeed,
        uint256 amountIn,
        uint256 nonce,
        bytes memory sig
    ) public {
        o.owner = vm.addr(_pk(pkSeed));
        o.key = key;
        _mockInfo(o, amountIn);
        _mockUnlockOk();
        bytes32 digest = _routerCancelDigest(o, amountIn, nonce, block.timestamp);
        vm.assume(!SignatureChecker.isValidSignatureNow(o.owner, digest, sig));
        vm.expectRevert(Router.InvalidSignature.selector);
        router.cancelWithSig(o, nonce, block.timestamp, sig);
    }

    function _signSig(uint256 pk, bytes32 d) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return abi.encodePacked(r, s, v);
    }

    function _routerEoaPass(AsyncOrder memory o, uint256 pk, uint256 amountIn, uint256 nonce) internal {
        o.owner = vm.addr(pk);
        o.key = key;
        _mockInfo(o, amountIn);
        bytes32 d = _routerCancelDigest(o, amountIn, nonce, block.timestamp);
        bytes memory sig = _signSig(pk, d);
        vm.expectCall(o.owner, _leanCalldata(d, sig), 0);
        router.cancelWithSig(o, nonce, block.timestamp, sig);
    }

    function _routerWallet(AsyncOrder memory o, uint256 pk, uint256 amountIn, uint256 nonce)
        internal
        returns (bool ok)
    {
        _walletOrder(o);
        _mockInfo(o, amountIn);
        bytes memory sig = _signSig(pk, _routerCancelDigest(o, amountIn, nonce, block.timestamp));
        (ok,) = address(router).call(abi.encodeCall(Router.cancelWithSig, (o, nonce, block.timestamp, sig)));
    }

    /// @notice formal/Refinement/Swarm/SpecSigRouter.lean:191 — isValidSignatureNow_run on the Router:
    ///         a valid EOA signature passes with no ERC-1271 call; for the wallet, a signature that
    ///         recovers another key falls through to the wallet's verdict.
    function testFuzz_isValidSignatureNow_run_router(
        AsyncOrder memory o,
        uint256 pkSeed,
        bool fail,
        bytes memory ret,
        bool magic,
        uint256 amountIn,
        uint256 nonce
    ) public {
        uint256 pk = _pk(pkSeed);
        _mockUnlockOk();
        _routerEoaPass(o, pk, amountIn, nonce);
        bytes memory rr = _script(fail, ret, magic, 0, bytes32(0), false);
        assertEq(_routerWallet(o, pk, amountIn, nonce), _leanVerdict(!fail, rr), "wallet: the ERC-1271 verdict decides");
    }
}
