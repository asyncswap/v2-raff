"""Explicit fixture adaptations; no test assertions or expected values are rewritten."""

import re
from pathlib import Path

FORMAL_SUPPORT = {
    "FormalBase.sol",
    "FormalSlotsB.sol",
    "HookUnlockBase.sol",
    "FormalProbesA.sol",
    "FormalHarnessesA.sol",
    "FormalMatchD.sol",
}
FORMAL_TESTS = set(
    """AsyncSwapCrosses AsyncSwapPriorityKey SpecSig AsyncSwapBestOrder AsyncSwapOrderBookLevel RoutingPoolImpact AsyncSwapMulDiv AsyncSwapBitSet AsyncSwapFreeNode AsyncSwapInsert AsyncSwapMostSignificantBit AsyncSwapNewNode AsyncSwapRemove AsyncSwapMatchAmounts AsyncSwapMatchPair AsyncSwapReduceAfterMatch AsyncSwapReduceMatchedOrders AsyncSwapSettleMatchedPriorityFee AsyncSwapSettleTransfers AsyncSwapTransferEscrow AsyncSwapOnlyOwner AsyncSwapUpdatePriceWithSig AsyncSwapSweep AsyncSwapMatchBook
AsyncSwapCalculateHookFee AsyncSwapAfterDonate RouterSwapWithSig FeeVaultCollect NativeClaimsUnlockCallback
AsyncSwapBeforeSwap AsyncSwapTransferOwnership AsyncSwapFillOrderFromPoolLiquidity RefinementRouter
AsyncSwapTryFillOrderFromPoolLiquidity AsyncSwapOrderBookOrder FeeVaultUnlockCallback RefinementAsyncSwap
AsyncSwapBeforeDonate AsyncSwapReceive AsyncSwapUpdatePrice RouterCancelWithSig AsyncSwapAfterInitialize
AsyncSwapDOMAIN_SEPARATOR AsyncSwapExecuteOrder AsyncSwapMatchNewOrder AsyncSwapSwapAgainstPool
NativeClaimsRedeem RouterDOMAIN_SEPARATOR AsyncSwapAsyncOrderInfo AsyncSwapAcceptOwnership
AsyncSwapBeforeRemoveLiquidity AsyncSwapCancelOrder RouterMatchBook AsyncSwapSetExecutorWithSig
AsyncSwapBeforeAddLiquidity RouterFillFromPoolLiquidity AsyncSwapInitAccess AsyncSwapCalculatePoolFee
AsyncSwapAfterRemoveLiquidity AsyncSwapAfterAddLiquidity AsyncSwapGetHookPermissions AsyncSwapInvalidateNonce
AsyncSwapAfterSwap AsyncSwapAsyncOrderPriorityFee""".split()
)


def supported(path):
    p = Path(path)
    if path in {
        "test/Numeraire.t.sol",
        "test/TickBitmap.t.sol",
        "test/TickPricePoolBeatsLevel.t.sol",
        "test/utils/TickIndexHarness.sol",
        "test/RadixPriceTree.t.sol",
        "test/TickPriceKey.t.sol",
        "test/nethermind_auditagent/NethermindAuditAgent.t.sol",
    }:
        return True
    return p.parent.as_posix() == "test/formal" and (
        p.name in FORMAL_SUPPORT or p.name.removesuffix(".t.sol") in FORMAL_TESTS
    )


def replace_function(text, name, body):
    match = re.search(r"function\s+" + re.escape(name) + r"\s*\(", text)
    assert match, name
    start = text.index("{", match.start())
    depth = 1
    end = start + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[: start + 1] + "\n" + body + "\n    " + text[end - 1 :]


def adapt_formal(path, text):
    changes = []
    if not supported(path):
        return text, changes
    name = Path(path).name
    if name == "TickIndexHarness.sol":
        # The Solidity body supplies ABI only; avoid an unused immutable relocation after the runtime return.
        text = text.replace("bool immutable useBitmap;", "bool useBitmap;")
        pos = text.index(";", text.index("pragma ")) + 1
        text = (
            text[:pos]
            + '\nimport {CurrentHuffDeploy} from "compat/current/support/CurrentHuffDeploy.sol";\n'
            + text[pos:]
        )
        text = text.replace(
            "useBitmap = use_;",
            """useBitmap = use_;
        address deployed = CurrentHuffDeploy.deploy(
            use_ ? "test/harness/BitmapHarness.huff" : "test/harness/FormalRadix.huff", "");
        bytes memory runtime = deployed.code;
        // Both comparator implementations execute their production Huff routines.
        assembly ("memory-safe") { return(add(runtime, 32), mload(runtime)) }""",
        )
        changes += [
            "Install production Huff bitmap/radix runtime for the unchanged index harness ABI."
        ]
    if name == "SpecSig.t.sol":
        text = runtime_constructor(text, "SigLibHarness", "test/harness/SignatureHarness.huff")
        changes += [
            "Install the production Huff hashing/ERC-1271 harness; hook/Router endpoint assertions remain unchanged."
        ]
    if name == "FormalBase.sol":
        for old, new in [
            ("ASYNC_ORDERS_SLOT = 2", "ASYNC_ORDERS_SLOT = 3"),
            ("OWNER_SLOT = 4", "OWNER_SLOT = 0"),
            ("PENDING_OWNER_SLOT = 5", "PENDING_OWNER_SLOT = 1"),
            ("NONCE_USED_SLOT = 6", "NONCE_USED_SLOT = 2"),
        ]:
            text = text.replace(old, new)
        text = replace_function(
            text,
            "_deployHookLinked",
            """        // Fixture-only deployment adapter: execute the real Huff constructor at the permission address.
        _deployHook();""",
        )
        changes += [
            "Deploy formal fixture through CurrentHuffDeploy; map named owner/nonce/pool storage seeds to Huff."
        ]
    if name == "RadixPriceTree.t.sol":
        text = runtime_constructor(
            text, "RadixHarness", "test/harness/FormalRadix.huff"
        )
        changes += [
            "Install production Huff radix operations behind the unchanged harness ABI."
        ]
    if name == "TickPricePoolBeatsLevel.t.sol":
        text = re.sub(
            r"import \{TickPrice\} from [^;]+;",
            'import {CurrentHuffDeploy} from "compat/current/support/CurrentHuffDeploy.sol";\ninterface IPoolPriority { function key(bool,bool,uint256,uint256) external view returns(uint128); function poolBeatsLevel(IPoolManager,PoolId,bool,bool,uint128,int24,uint64) external view returns(bool,uint160); }',
            text,
        )
        text = text.replace(
            "contract TickPricePoolBeatsLevelTest is Test {",
            "contract TickPricePoolBeatsLevelTest is Test {\n    IPoolPriority TickPrice;",
        )
        text = text.replace(
            "function setUp() public {",
            'function setUp() public {\n        TickPrice = IPoolPriority(CurrentHuffDeploy.deploy("test/harness/PoolPriorityHarness.huff", ""));',
        )
        text = text.replace(
            "function test_priceJustBelowTwoTo128IsTheEndKey() public pure",
            "function test_priceJustBelowTwoTo128IsTheEndKey() public view",
        )
        changes += [
            "Bind price selection to the shared production Huff kernel and v4 state reads; assertions unchanged."
        ]
    if name == "TickPriceKey.t.sol":
        text = re.sub(
            r"import \{TickPrice\} from [^;]+;",
            'import {CurrentHuffDeploy} from "compat/current/support/CurrentHuffDeploy.sol";\ninterface ITickPrice { function key(bool,bool,uint256,uint256) external view returns(uint128); }',
            text,
        )
        text = text.replace(
            "contract TickPriceKeyTest is Test {",
            'contract TickPriceKeyTest is Test {\n ITickPrice TickPrice;\n function setUp() public { TickPrice = ITickPrice(CurrentHuffDeploy.deploy("src/experimental/CurrentTick.huff", "")); }',
        )
        text = text.replace("pure", "view")
        changes += [
            "Bind TickPrice.key to the production Huff price-key kernel; assertions unchanged, pure tests become view."
        ]
    if name == "Numeraire.t.sol":
        start = text.index("contract NumeraireConstructorHarness")
        end = text.index("contract NumeraireTest", start)
        text = (
            text[:start]
            + """contract NumeraireConstructorHarness {
    constructor(IPoolManager manager, Currency quote, address owner_, address router_, uint256 minOrderUsd) {
        CurrentHuffDeploy.constructorTo(abi.encode(manager, quote, owner_, router_, minOrderUsd, type(uint8).max), address(this));
        bytes memory runtime = address(this).code;
        assembly ("memory-safe") { return(add(runtime, 32), mload(runtime)) }
    }
}

"""
            + text[end:]
        )
        # Preserve the original AsyncSwap ABI variable types without inheriting Solidity runtime.
        pattern = r"new NumeraireConstructorHarness\("
        # Balanced argument lists can include nested expressions.
        offset = 0
        while m := re.search(pattern, text[offset:]):
            a = offset + m.start()
            b = offset + m.end()
            depth = 1
            e = b
            while depth:
                depth += (text[e] == "(") - (text[e] == ")")
                e += 1
            text = (
                text[:a] + "AsyncSwap(payable(address(" + text[a:e] + ")))" + text[e:]
            )
            offset = e + len("AsyncSwap(payable(address(") + len(")))")
        changes += [
            "Run the Huff constructor at the fixture address, bypassing only hook-address mining like the upstream constructor subclass."
        ]
    if name == "FormalSlotsB.sol":
        text = replace_function(
            text,
            "_storeOrder",
            """        // Encode the same logical OrderInfo in the Huff seven-word layout.
        bytes32 s = _orderSlot(pid, id);
        uint256 packed = uint160(o.owner) | (o.isBuy ? 1 << 160 : 0) | (o.zeroForOne ? 1 << 168 : 0)
            | (uint256(1) << 176) | (uint256(o.priorityFee) << 184);
        vm.store(address(hook), s, bytes32(packed));
        vm.store(address(hook), _add(s, 1), bytes32(uint256(o.price) | (uint256(o.priorityKey) << 128)));
        vm.store(address(hook), _add(s, 2), bytes32(o.amountIn));
        vm.store(address(hook), _add(s, 3), bytes32(o.amountOutMin));
        vm.store(address(hook), _add(s, 4), bytes32(uint256(o.createdSequence)));
        vm.store(address(hook), _add(s, 5), bytes32(uint256(o.reprices)));
        vm.store(address(hook), _add(s, 6), bytes32(uint256(o.sequence)));""",
        )
        text = replace_function(
            text, "_treeSlot", "        return _add(_bookSlot(pid), isBuy ? 16 : 19);"
        )
        text = replace_function(
            text,
            "_levelSlot",
            "        return _add(keccak256(abi.encode(uint256(price), uint256(_bookSlot(pid)) + (isBuy ? 5 : 6))), 2);",
        )
        text = replace_function(
            text,
            "_nodeSlot",
            "        return bytes32(uint256(keccak256(abi.encode(tree))) + 0x100000000 + id);",
        )
        changes += [
            "Pack arbitrary order fixtures and bitmap/level/radix slots using the Huff storage layout; original getter assertions unchanged."
        ]
    if name == "HookUnlockBase.sol":
        text = replace_function(
            text,
            "_orderWords",
            """        // Normalize actual Huff storage into the upstream five-word observation shape.
        // No getter or expected value supplies these observations.
        uint256 s = _orderSlot(pid, id);
        uint256 packed = uint256(_loadHook(bytes32(s)));
        uint256 keys = uint256(_loadHook(bytes32(s + 1)));
        w[0] = bytes32(uint256(uint160(packed)));
        w[1] = _loadHook(bytes32(s + 2));
        w[2] = _loadHook(bytes32(s + 3));
        w[3] = bytes32(uint256(uint128(keys)) | (((packed >> 160) & 1) << 128)
            | (((packed >> 168) & 1) << 136) | (uint256(_loadHook(bytes32(s + 6))) << 144));
        w[4] = bytes32(uint256(uint64(packed >> 184)) | ((keys >> 128) << 64) | (uint256(_loadHook(bytes32(s + 4))) << 192));""",
        )
        text = replace_function(
            text,
            "_sequenceOf",
            """        return uint64(uint256(_loadHook(bytes32(_orderSlot(pid, id) + 6))));""",
        )
        changes += [
            "Normalize raw Huff order words and sequence location for upstream state-snapshot helpers."
        ]
    if name == "AsyncSwapOrderBookLevel.t.sol":
        text = replace_function(
            text,
            "_priceKey",
            """        if (!pick || ids.length == 0) return (k, sel % 2 == 0);
        bytes32 s = _orderSlot(poolId, ids[sel % ids.length]);
        return (uint128(uint256(_loadHook(_add(s, 1)))), ((uint256(_loadHook(s)) >> 160) & 1) == 1);""",
        )
        changes += ["Read packed Huff price and side fields in the observation helper."]
    if name == "AsyncSwapBestOrder.t.sol":
        text = text.replace("uint256(level) + 5", "uint256(level) + 2")
        changes += [
            "Seed the Huff priority-key mapping relative to the normalized level-count slot."
        ]
    if name == "AsyncSwapSetExecutorWithSig.t.sol":
        # Same fixture fix already accepted in contracts c8d12dd; the replay assertion is untouched.
        assert "_submit(e, !allow, nonce, deadline);" in text
        text = text.replace(
            "_submit(e, !allow, nonce, deadline);", "_submit(e, true, nonce, deadline);"
        )
        changes += [
            "Consume nonce using a valid grant, including the trusted Router (contracts c8d12dd fixture fix)."
        ]
    if name == "NativeClaimsRedeem.t.sol":
        text = text.replace(
            "import {FormalBase}",
            'import {TransientStorage} from "compat/current/support/TransientStorage.sol";\nimport {FormalBase}',
        )
        text = text.replace(
            "vm.load(address(claims),", "TransientStorage.load(address(claims),"
        )
        text = text.replace(
            "vm.store(address(claims),", "TransientStorage.store(address(claims),"
        )
        text = text.replace(
            "function _flag() internal view", "function _flag() internal"
        )
        text = re.sub(r"(function test[\s\S]*?\bpublic)(\s*\{)", r"\1 oneTx\2", text)
        changes += [
            "Observe and seed the transient reentrancy flag; run each property in one transaction."
        ]
    if name == "AsyncSwapSwapAgainstPool.t.sol":
        text = text.replace(
            "bytes32(_orderSlot(poolId, id) + 1), bytes32(amountIn)",
            "bytes32(_orderSlot(poolId, id) + 2), bytes32(amountIn)",
        )
        changes += ["Seed the input amount at Huff order slot +2."]
    if name == "AsyncSwapUpdatePrice.t.sol":
        text = text.replace(
            "uint256 st = _stateSlot(poolId);",
            "uint256 st = type(uint256).max; // adapter: observe the manager immutable",
        )
        changes += [
            "Observe the actual manager immutable instead of a Solidity-only per-pool manager slot."
        ]
    if name == "FormalBase.sol":
        text = replace_function(
            text,
            "_loadHook",
            """        if (slot == bytes32(type(uint256).max)) {
            // Symbolic fixture location for Huff's manager immutable, read from deployed bytecode.
            address target = address(hook);
            bytes32 word;
            assembly ("memory-safe") {
                extcodecopy(target, 0, sub(extcodesize(target), 224), 32)
                word := mload(0)
            }
            return word;
        }
        return vm.load(address(hook), slot);""",
        )
    if name == "FormalHarnessesA.sol":
        for contract, source in [
            ("AsyncBookHarness", "test/harness/BookHarness.huff"),
            ("MathMulDivHarness", "test/harness/MathHarness.huff"),
            ("RadixPriceTreeHarness", "test/harness/FormalRadix.huff"),
        ]:
            text = runtime_constructor(text, contract, source)
        changes += [
            "Return production Huff book/math/radix harness runtime from fixture constructors; Solidity method bodies are ABI declarations only."
        ]
    if name == "AsyncSwapMatchAmounts.t.sol":
        text = runtime_constructor(
            text, "MathMulDivHarness", "test/harness/MathHarness.huff"
        )
        changes += ["Deploy the production Huff mulDiv/ceil ABI harness."]
    if name == "FormalMatchD.sol":
        text = replace_function(
            text,
            "_storeWord",
            """        // Fixture fields 1/2 are input/minimum; Huff places them at +2/+3.
        require(i == 1 || i == 2, "unsupported logical fixture word");
        vm.store(address(hook), bytes32(_orderSlot(pid, id) + i + 1), bytes32(v));""",
        )
        text = replace_function(
            text,
            "_storeIsBuy",
            """        uint256 slot = _orderSlot(pid, id);
        uint256 word = uint256(_loadHook(bytes32(slot)));
        vm.store(address(hook), bytes32(slot), bytes32((word & ~(uint256(1) << 160)) | (isBuy ? 1 << 160 : 0)));""",
        )
        changes += [
            "Map direct matching-fixture field writes to the Huff packed record."
        ]
    if name == "AsyncSwapReduceAfterMatch.t.sol":
        text = text.replace(
            "uint256 raw = uint128(uint256(_loadHook(bytes32(_orderSlot(pid, id) + 3))));",
            "uint256 raw = uint128(uint256(_loadHook(bytes32(_orderSlot(pid, id) + 1))));",
        )
        changes += ["Observe the rekeyed price at Huff order slot +1."]
    return text, changes


def runtime_constructor(text, contract, source):
    marker = "contract " + contract + " {"
    assert marker in text, contract
    if "import {CurrentHuffDeploy}" not in text:
        pos = text.index(";", text.index("pragma ")) + 1
        text = (
            text[:pos]
            + '\nimport {CurrentHuffDeploy} from "compat/current/support/CurrentHuffDeploy.sol";\n'
            + text[pos:]
        )
    ctor = '\n    constructor() {\n        address deployed = CurrentHuffDeploy.deploy("SOURCE", "");\n        bytes memory runtime = deployed.code;\n        // The constructor installs Huff runtime; subsequent test calls never execute Solidity helpers.\n        assembly ("memory-safe") { return(add(runtime, 32), mload(runtime)) }\n    }\n'.replace(
        "SOURCE", source
    )
    return text.replace(marker, marker + ctor)
