"""Explicit fixture adaptations; no test assertions or expected values are rewritten."""

import re
from pathlib import Path
from current_reference_only import REFERENCE_ONLY_TESTS

FORMAL_SUPPORT = {
    "FormalBase.sol",
    "AsyncFillerBookHarness.sol",
    "FormalOzE.sol",
    "FormalImmutablesC.sol",
    "LibHelpersB.sol",
    "HookHelpersB.sol",
    "FormalSlotsB.sol",
    "HookUnlockBase.sol",
    "FormalProbesA.sol",
    "FormalHarnessesA.sol",
    "FormalMatchD.sol",
}
FORMAL_TESTS = set(
    """AsyncSwapAddOrder SpecEip712 AsyncSwapConstructor RouterConstructor SpecCore AsyncSwapBeforeInitialize AsyncSwapAsyncOrder AsyncSwapSettleOrderPriorityFee AsyncSwapHelpers AsyncSwapLibHelpers RouterHelpers RouterLibHelpers Eip712Domain AsyncSwapRevert AsyncSwapBubbleUpAndRevertWith AsyncSwapCallOptionalReturn AsyncSwapFunctionCall AsyncSwapFunctionCallWithValue AsyncSwapSafeTransferFrom AsyncSwapVerifyCallResultFromTarget AsyncSwapCrosses AsyncSwapPriorityKey SpecSig AsyncSwapBestOrder AsyncSwapOrderBookLevel RoutingPoolImpact AsyncSwapMulDiv AsyncSwapBitSet AsyncSwapFreeNode AsyncSwapInsert AsyncSwapMostSignificantBit AsyncSwapNewNode AsyncSwapRemove AsyncSwapMatchAmounts AsyncSwapMatchPair AsyncSwapReduceAfterMatch AsyncSwapReduceMatchedOrders AsyncSwapSettleMatchedPriorityFee AsyncSwapSettleTransfers AsyncSwapTransferEscrow AsyncSwapOnlyOwner AsyncSwapUpdatePriceWithSig AsyncSwapSweep AsyncSwapMatchBook
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
    if path.startswith("test/fizz/"):
        return True
    if path in {
        "test/Numeraire.t.sol",
        "test/BaseHookDefaults.t.sol",
        "test/EligiblePrice.t.sol",
        "test/security/FeeClaims.t.sol",
        "test/security/ClaimTransfers.t.sol",
        "test/security/EligibleGas.t.sol",
        "test/security/EligiblePythonVectors.t.sol",
        "test/security/EligibleRemainder.t.sol",
        "test/security/PriorityPythonVectors.t.sol",
        "test/security/PriorityPythonHashes.t.sol",
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


def replace_contract(text, name, replacement):
    start = text.index("contract " + name + " ")
    opening = text.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[:start] + replacement + text[end:]


def deploy_import(text):
    if "import {CurrentHuffDeploy}" in text:
        return text
    pos = text.index(";", text.index("pragma ")) + 1
    return (
        text[:pos]
        + '\nimport {CurrentHuffDeploy} from "compat/current/support/CurrentHuffDeploy.sol";\n'
        + text[pos:]
    )


def adapt_formal(path, text):
    changes = []
    if not supported(path):
        return text, changes
    name = Path(path).name
    if path == "test/fizz/utils/MockERC20.sol":
        text = text.replace("\t", "    ")
        changes += ["Normalize comment indentation; no executable changes."]
    if name == "BaseHookDefaults.t.sol":
        text = deploy_import(text).replace(
            'deployCodeTo("test/BaseHookDefaults.t.sol:DefaultHook", abi.encode(manager), at);',
            'address runtime = CurrentHuffDeploy.deploy("test/harness/DefaultHookHarness.huff", ""); vm.etch(at, runtime.code); vm.store(at, bytes32(0), bytes32(uint256(uint160(address(manager)))));',
        )
        changes += [
            "Expose the production manager guard and default-callback revert with the upstream fixture's manager."
        ]
    if name == "EligiblePrice.t.sol":
        text = deploy_import(text).replace(
            'import {EligiblePrice} from "@async-swap/libraries/EligiblePrice.sol";',
            'import {HuffEligiblePrice as EligiblePrice} from "compat/current/support/HuffEligiblePrice.sol";',
        )
        text = text.replace(
            "contract EligiblePriceTest is FormalRefA {",
            """contract EligiblePriceTest is FormalRefA {
            function setUp() public {
                address probe = CurrentHuffDeploy.deploy("test/harness/BookHarness.huff", "");
                vm.etch(address(0x48554646524154494f), probe.code);
            }
        """,
        ).replace("public pure", "public view")
        changes += [
            "Run full-width ratio assertions against production Huff; retain physical tree assertions as references."
        ]
    if name == "AsyncFillerBookHarness.sol":
        text = runtime_constructor(
            text, "AsyncFillerBookHarness", "test/harness/AddOrderHarness.huff"
        )
        changes += [
            "Install the production Huff book-add routine with ABI-only setters and record decoding."
        ]
    if name == "PriorityPythonHashes.t.sol":
        text = deploy_import(text).replace(
            'import {OrderSignatures} from "@async-swap/libraries/OrderSignatures.sol";',
            "",
        )
        text = text.replace(
            "contract PriorityPythonHashesTest is Test {",
            """interface IOrderHashProbe {
            function hashPoolKey(PoolKey calldata) external view returns(bytes32);
            function hashOrder(AsyncOrder calldata) external view returns(bytes32);
            function hashSetExecutor(PoolKey calldata,address,address,bool,uint256,uint256) external view returns(bytes32);
            function hashUpdatePrice(AsyncOrder calldata,bytes32,uint256,uint256,uint64,uint32,uint256,uint256) external view returns(bytes32);
            function hashCancel(AsyncOrder calldata,bytes32,uint64,uint256,uint256) external view returns(bytes32);
        }
        contract PriorityPythonHashesTest is Test {
            IOrderHashProbe OrderSignatures;
            function setUp() public { OrderSignatures = IOrderHashProbe(CurrentHuffDeploy.deploy("test/harness/SignatureHarness.huff", "")); }
        """,
        ).replace("public pure", "public view")
        changes += [
            "Execute the shared production signature preimages against the fixed Python vectors."
        ]
    if name == "SpecEip712.t.sol":
        text = runtime_constructor(
            text, "ShortStringsHarnessC", "test/harness/ShortStringsHarness.huff"
        )
        text = text.replace("OWNER_SLOT = 4", "OWNER_SLOT = 0")
        changes += [
            "Run packed strings and fallback storage through the Huff codecs; retain cached Solidity immutable assertions as references."
        ]
    if path == "test/fizz/Base.sol":
        text = deploy_import(text)
        start = text.index(
            "    constructor(IPoolManager manager, Currency numeraire, address owner) {"
        )
        end = text.index("    function _create2Address", start)
        text = (
            text[:start]
            + """    constructor(IPoolManager manager, Currency numeraire, address owner) {
            // Fixture address placement preserves the hook permission bits without Solidity CREATE2 bytecode.
            address deployed = address((uint160(address(this)) & ~MASK) | FLAGS);
            hook = AsyncSwap(payable(deployed));
            router = Router(payable(CurrentHuffDeploy.deploy("src/current/Router.huff",
                abi.encode(manager, hook, ISignatureTransfer(address(0)), uint256(0)))));
            CurrentHuffDeploy.hookTo(abi.encode(manager, numeraire, owner, address(router), uint256(0), type(uint8).max), deployed);
        }

"""
            + text[end:]
        )
        changes += [
            "Deploy real Huff hook, Router and claim modules in the shared handler fixture."
        ]
    if name == "AsyncSwapConstructor.t.sol":
        text = deploy_import(text)
        text = replace_contract(
            text,
            "CtorHarness",
            """contract CtorHarness {
            constructor(IPoolManager manager, Currency quote, address owner_, address router_) {
                CurrentHuffDeploy.constructorTo(abi.encode(manager, quote, owner_, router_, uint256(0), type(uint8).max), address(this));
                bytes memory runtime = address(this).code;
                assembly ("memory-safe") { return(add(runtime, 32), mload(runtime)) }
            }
            function poolManager() external view returns(IPoolManager) { revert(); }
            function numeraire() external view returns(Currency) { revert(); }
            function owner() external view returns(address) { revert(); }
            function pendingOwner() external view returns(address) { revert(); }
            function router() external view returns(address) { revert(); }
            function minOrder() external view returns(uint256) { revert(); }
            function priorityFeeCap() external view returns(uint256) { revert(); }
            function feeVault() external view returns(address) { revert(); }
            function domainSeparatorV4() external view returns(bytes32) { revert(); }
            function DOMAIN_SEPARATOR() external view returns(bytes32) { revert(); }
            receive() external payable {}
        }""",
        )
        text = text.replace("OWNER_SLOT = 4", "OWNER_SLOT = 0").replace(
            "PENDING_OWNER_SLOT = 5", "PENDING_OWNER_SLOT = 1"
        )
        text = text.replace(
            "bytes32 sep = CtorHarness(payable(self)).domainSeparatorV4();",
            "bytes32 sep = CtorHarness(payable(self)).DOMAIN_SEPARATOR();",
        )
        changes += [
            "Execute the Huff constructor at the fixture address; probe the same domain helper through its public endpoint and map named ownership slots."
        ]
    if name == "RouterConstructor.t.sol":
        text = deploy_import(text)
        text = replace_contract(
            text,
            "RouterCtorHarness",
            """contract RouterCtorHarness {
            constructor(IPoolManager manager, AsyncSwap hook_, ISignatureTransfer permit2) {
                CurrentHuffDeploy.routerConstructorTo(abi.encode(manager, hook_, permit2, uint256(0)), address(this));
                bytes memory runtime = address(this).code;
                assembly ("memory-safe") { return(add(runtime, 32), mload(runtime)) }
            }
            function domainSeparatorV4() external view returns(bytes32) { revert(); }
            function DOMAIN_SEPARATOR() external view returns(bytes32) { revert(); }
            receive() external payable {}
        }""",
        )
        text = text.replace(
            "bytes32 sep = RouterCtorHarness(payable(a)).domainSeparatorV4();",
            "bytes32 sep = RouterCtorHarness(payable(a)).DOMAIN_SEPARATOR();",
        )
        changes += [
            "Execute the actual Huff Router constructor; use the public domain endpoint for the private-helper probe."
        ]
    if name == "SpecCore.t.sol":
        text = runtime_constructor(
            text, "SpecCoreLibHarness", "test/harness/CoreHarness.huff"
        )
        changes += [
            "Expose production Huff currency transfers and PoolManager state reads."
        ]
    if name == "AsyncSwapSettleOrderPriorityFee.t.sol":
        pos = text.index(";", text.index("pragma ")) + 1
        text = (
            text[:pos]
            + '\nimport {CurrentHuffDeploy} from "compat/current/support/CurrentHuffDeploy.sol";\n'
            + text[pos:]
        )
        text = text.replace(
            "state.feeVault = feeVault;",
            """state.feeVault = feeVault;
            address deployed = CurrentHuffDeploy.deploy("test/harness/PriorityFeesHarness.huff", "");
            bytes memory runtime = deployed.code;
            assembly ("memory-safe") { return(add(runtime, 32), mload(runtime)) }""",
        )
        changes += [
            "Expose the production Huff bid settlement and order-field decoders with the original constructor fixture state."
        ]
    if name == "ClaimTransfers.t.sol":
        text = text.replace(
            'import {ClaimTransfers} from "@async-swap/libraries/ClaimTransfers.sol";',
            'import {HuffClaimTransfers as ClaimTransfers} from "compat/current/support/HuffClaimTransfers.sol";',
        )
        changes += [
            "Serialize batches through a delegatecall fixture so production Huff performs every credit and flush."
        ]
    if name == "LibHelpersB.sol":
        text = runtime_constructor(
            text, "OzLibHarnessB", "test/harness/ExternalCallsHarness.huff"
        )
        text = runtime_constructor(
            text, "RadixTreeHarnessB", "test/harness/FormalRadix.huff"
        )
        start = text.index("contract Eip712HarnessB is EIP712")
        end = text.index("/// @notice The real `RadixPriceTree`", start)
        text = (
            text[:start]
            + """contract Eip712HarnessB {
            string internal nameValue;
            string internal versionValue;
            constructor(string memory name, string memory version) {
                nameValue = name;
                versionValue = version;
                address deployed = CurrentHuffDeploy.deploy("test/harness/GenericDomainHarness.huff", "");
                bytes memory runtime = deployed.code;
                assembly ("memory-safe") { return(add(runtime, 32), mload(runtime)) }
            }
            function eip712Name() external view returns(string memory) { return nameValue; }
            function eip712Version() external view returns(string memory) { return versionValue; }
        }

"""
            + text[end:]
        )
        changes += [
            "Install Huff call/math/radix/ShortString helpers and Huff reads of fixture-provided arbitrary domain strings."
        ]
    if name == "HookHelpersB.sol":
        text = replace_function(
            text,
            "_priorityKeyOf",
            "        return uint128(uint256(_loadHook(bytes32(_orderSlot(poolId, id) + 1))) >> 128);",
        )
        changes += ["Read the priority key from its actual Huff packed field."]
    if name == "Eip712Domain.t.sol":
        for contract, args, source in (
            (
                "DomainHarness",
                "IPoolManager, Currency, address, address",
                "HookDomainHarness",
            ),
            (
                "RouterDomainHarness",
                "IPoolManager, AsyncSwap, ISignatureTransfer",
                "RouterDomainHarness",
            ),
        ):
            start = text.index("contract " + contract + " is ")
            opening = text.index("{", start)
            depth, end = 1, opening + 1
            while depth:
                depth += (text[end] == "{") - (text[end] == "}")
                end += 1
            replacement = f"""contract {contract} {{
                constructor({args}) {{
                    address deployed = CurrentHuffDeploy.deploy("test/harness/{source}.huff", "");
                    bytes memory runtime = deployed.code;
                    assembly ("memory-safe") {{ return(add(runtime, 32), mload(runtime)) }}
                }}
            }}"""
            text = text[:start] + replacement + text[end:]
        pos = text.index(";", text.index("pragma ")) + 1
        text = (
            text[:pos]
            + '\nimport {CurrentHuffDeploy} from "compat/current/support/CurrentHuffDeploy.sol";\n'
            + text[pos:]
        )
        changes += [
            "Expose production Huff domain encoding and separator routines through metadata-only harness ABIs."
        ]
    if name == "FormalOzE.sol":
        for contract in ("AddressHarness", "SafeERC20Harness", "CustomRevertHarness"):
            text = runtime_constructor(
                text, contract, "test/harness/ExternalCallsHarness.huff"
            )
        changes += [
            "Deploy Huff wrappers around production external-call, token-return and wrapped-revert routines."
        ]
    if name == "FeeClaims.t.sol":
        start = text.index("contract FeeTestHook")
        end = text.index("contract FeeClaimsTest", start)
        text = text[:start] + text[end:]
        text = text.replace(
            'deployCodeTo("FeeTestHook", abi.encode(manager, currency1, address(this), address(router)), _hookAddress());',
            "CurrentHuffDeploy.feeHookTo(abi.encode(manager, currency1, address(this), address(router), uint256(0), type(uint8).max), _hookAddress());",
        )
        # SetupHook's custom deployment uses the same production Huff fee-mode switch as the legacy suite.
        pos = text.index(";", text.index("pragma ")) + 1
        text = (
            text[:pos]
            + '\nimport {CurrentHuffDeploy} from "compat/current/support/CurrentHuffDeploy.sol";\n'
            + text[pos:]
        )
        changes += [
            "Run the production Huff hook with the upstream fixture's 1% surcharge override."
        ]
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
        text = runtime_constructor(
            text, "SigLibHarness", "test/harness/SignatureHarness.huff"
        )
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
    for test, reason in REFERENCE_ONLY_TESTS.get(path, {}).items():
        # Preserve the function body and every assertion, but do not register a Solidity-layout test as Huff coverage.
        old = "function " + test + "("
        assert old in text, (path, test)
        text = text.replace(old, "function referenceOnly_" + test + "(")
        changes += [f"Reference-only {test}: {reason}"]
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
