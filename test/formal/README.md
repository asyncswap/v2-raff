# test/formal/: Formal Mind's Lean theorems, checked on the bytecode

> **In v2-raff:** copied from `asyncswap/contracts` `main` @ `a554878` and run against the Huff. The edits are the
> suite's usual ones (interfaces from `src/interface/`, deploys through `test/utils/HuffDeploy.sol`) plus a layout
> adapter in `FormalBase.sol`: the tests still name the Solidity's slots and 8-word order record, and `FormalBase`
> maps them to the Huff's (`src/lib/Book.huff`, `src/lib/RadixPriceTree.huff`). `NativeClaims`' `_redeeming` is
> transient here, so `NativeClaimsRedeem.t.sol` sets and reads it with `tstore`/`tload` probes inside one transaction.
>
> Not copied: the 26 files that test Solidity or OpenZeppelin library code through Solidity harnesses (the
> `RadixPriceTree`, `AsyncFiller` and `AsyncMatching` internals, OZ `Math`/`Address`/`SafeERC20`/`ShortStrings`,
> and the EIP-712 immutables read from solc artifacts). They compile the Solidity into the test and never reach
> the Huff.
>
> Failing on the Huff (9): `FeeVault` and `NativeClaims` `unlockCallback` read their arguments from fixed calldata
> offsets instead of `abi.decode`, so malformed data is not rejected with empty revert data (8 tests); and
> `orderingMode` returns a stored mode byte outside {0, 1} instead of panicking 0x21 (1 test). Only the
> PoolManager can call either callback, with data the contract itself encoded, and the mode byte is only ever
> 0 or 1, so neither is reachable on chain.


The Lean proofs in [`formal/`](../../formal/README.md) are about the model that formal-ast generates
from solc's AST (`formal/Generated/`), not about the compiled contracts. Each test here takes one
theorem from `formal/Refinement/` whose statement is about a single call's outcome, and states the same
property on the real compiled contracts: the call reverts with the named error, returns the given value,
or writes only the storage the theorem names. A failing test is a counterexample, which means either
the translation is wrong or the code breaks the property. Don't weaken a test to make it pass.

```sh
forge test --match-path 'test/formal/*'   # every test except the findings
FOUNDRY_PROFILE=findings forge test       # only the findings: these fail
```

**Status:** `formal/Refinement` has 862 theorems, none with `sorry`. 570 have a test and 292 are left
out (reasons below). The functions formal-ast leaves opaque each have a named spec that is checked on the
bytecode (see [Named specs](#named-specs-for-the-opaque-functions)).
- 634 tests in `test/formal/` pass on Forge 1.5.1 and 1.8.6.
- 1 test is a **finding**: it fails on the bytecode by design (see [Findings](#findings)). Its name
  contains `_finding_`, and `foundry.toml` leaves it out of a plain `forge test` (`no_match_test`), so
  CI stays green while it's kept.

The spec libraries (`formal/AsyncSwapSpec`, `formal/AsyncSwapProtocol`) are not mapped here. Their
theorems are about the abstract `World` / `step` models, not a generated def, and reach the code only
through `Refinement/`.

## How a theorem becomes a test

- `.error ⟨"E"⟩` means `vm.expectRevert(E.selector)`. The model's `"abi.decode"` error and the
  library errors it writes as `""` are checked against the bytecode's real revert data: empty data,
  `AsyncFiller.NotAuthorizedExecutor()` and `AsyncFiller.OrderNotFound()`.
- `.ok (v, w')` means a return-value check plus the state after the call (getters, `vm.load`).
- `ext.get w' = ext.get w` and `_frame` / `_readOnly` mean that `vm.record()` / `vm.accesses` shows no
  SSTORE to the contract, or only the slots the theorem names. Those slots are also compared with
  `vm.load`.
- `_iff` theorems are tested in both directions with fuzzed inputs. `never_reverts` / `never_ok` are
  tested by fuzzing and asserting success or a revert.
- Theorems over an arbitrary state `w` are fuzzed over the inputs and run on several states: the
  fixture, real order books built through the Router (FIFO and PriorityFee modes, both sides), and
  storage written with `vm.store`.
- Calls to other contracts that the model leaves opaque (`ext.call_*`):
  - When the theorem is conditional on what such a call does, it is tested against the real contract
    where that contract meets the condition.
  - Otherwise the call is mocked with fuzzed results (`vm.mockCall` / `vm.mockCallRevert`), and
    `vm.expectCall` checks the exact calldata that is handed on.
- Transient state:
  - Hook functions that only run inside `PoolManager.unlock` are driven from a real unlock
    ([`HookUnlockBase.sol`](HookUnlockBase.sol)).
  - The pending-match hand-off and the native-deposit ledger come from real `_beforeSwap` / `receive`
    calls in the same transaction.
  - The Router's transient slots are read back through `unlockCallback`
    ([`FormalProbesA.sol`](FormalProbesA.sol)).
  - Reading or writing the hook's transient storage directly swaps in a small `tload`/`tstore` probe
    with `vm.etch` and puts the original code back afterwards ([`FormalSlotsB.sol`](FormalSlotsB.sol)).
  - A test whose steps share transient state carries `oneTx`, which runs its body as one nested call.
    With `isolate` (Foundry's default since 1.8), each top-level call a test makes is its own
    transaction and transient storage is cleared between them; on chain those steps happen inside
    one transaction.

Shared fixtures:
- [`FormalBase.sol`](FormalBase.sol): `SetupHook` plus two funded makers, `_placeOrder`, and AsyncSwap's
  storage slots.
- [`FormalProbesA.sol`](FormalProbesA.sol): Router mocks and probes for its transient slots.
- [`FormalSlotsB.sol`](FormalSlotsB.sol): order-book slot math, write-set checks and book builders.
- [`HookUnlockBase.sol`](HookUnlockBase.sol): the unlock driver.

- Internal and private functions:
  - **Internal** library functions (`AsyncFiller`, `RadixPriceTree`, OpenZeppelin `Math` / `Address` /
    `SafeERC20`, v4-core `CustomRevert`) are called through a harness contract that runs the real
    library code: `AsyncFillerBookHarness.sol`, `FormalHarnessesA.sol`, `LibHelpersB.sol`,
    `FormalOzE.sol`, `FormalMatchD.sol`.
  - **Private** functions are reached through the entry point that calls them, with inputs chosen
    so their effect shows. For example, `_matchAmounts` and `_matchPair` are checked through one
    `matchBook(key, 1)`, and `_priorityKey` through the stored price key.
  - No test copies a function's source.

## Named specs for the opaque functions

formal-ast can't translate some functions (assembly, strings and bytes, hex literals), so the model
leaves them as opaque `ext.fn_*` fields. Each one now has a single named spec, a Lean `structure` whose
fields state its reverts, its result, and what it writes:

| Spec | Module | Functions |
|---|---|---|
| `RemoveSpec`, `AppendSpec`, `BestAtPriceSpec`, `LevelSpec` | `SpecBook.lean` | `AsyncFiller._remove`, `_append`, `bestAtPrice`, `level` |
| `CreateOrderSpec`, `TransferSpec`, `PoolStateSlotSpec` | `SpecCoreAsyncSwap.lean`, `SpecCoreRouter.lean` | `_createOrder`, `CurrencyLibrary.transfer`, `StateLibrary._getPoolStateSlot` |
| `CtorSpec`, `ShortStringsSpec`, `Eip712DomainSpec` | `AsyncSwapConstructor.lean`, `RouterConstructor.lean`, `SpecEip712*.lean`, `Assumptions.lean` | both constructors, `ShortStrings.toString` / `toStringWithFallback`, `EIP712.eip712Domain` |
| `ERC1271Spec`, `TypedDataHashSpec`, `HashSetExecutorSpec`, `HashPoolKeySpec` | `SpecSigAsyncSwap.lean`, `SpecSigRouter.lean` | `SignatureChecker.isValidERC1271SignatureNow`, `MessageHashUtils.toTypedDataHash`, `OrderSignatures.hashSetExecutor` / `hashPoolKey` |

For each spec:
- **Callers:** every theorem that used to take a one-off hypothesis about the function has a `_of_spec`
  version that takes the spec instead (in `SpecBookCallers.lean` and the `Spec*` modules). The original
  theorems are unchanged.
- **Bytecode:** every field of every spec is checked by a Foundry test. Internal functions run on the
  real library code through a harness, and private ones through the entry point that reaches them. If
  a spec field fails on the bytecode, that's a finding.

<details><summary>Spec field → test</summary>

| Spec | Lean | Test |
|---|---|---|
| RemoveSpec.reverts (field) | [SpecBook.lean:344](../../formal/Refinement/Swarm/SpecBook.lean#L344) | SpecBook.t.sol: testFuzz_RemoveSpec_reverts |
| RemoveSpec.progress (field) | [SpecBook.lean:350](../../formal/Refinement/Swarm/SpecBook.lean#L350) | SpecBook.t.sol: testFuzz_RemoveSpec_progress |
| RemoveSpec.post (field) | [SpecBook.lean:356](../../formal/Refinement/Swarm/SpecBook.lean#L356) | SpecBook.t.sol: testFuzz_RemoveSpec_post |
| AppendSpec.post (field) | [SpecBook.lean:417](../../formal/Refinement/Swarm/SpecBook.lean#L417) | SpecBook.t.sol: testFuzz_AppendSpec_post, testFuzz_AppendSpec_post_guards |
| AppendSpec.progress (field) | [SpecBook.lean:435](../../formal/Refinement/Swarm/SpecBook.lean#L435) | SpecBook.t.sol: testFuzz_AppendSpec_progress |
| BestAtPriceSpec.fifo (field) | [SpecBook.lean:208](../../formal/Refinement/Swarm/SpecBook.lean#L208) | SpecBook.t.sol: testFuzz_BestAtPriceSpec_fifo |
| BestAtPriceSpec.priority (field) | [SpecBook.lean:213](../../formal/Refinement/Swarm/SpecBook.lean#L213) | SpecBook.t.sol: testFuzz_BestAtPriceSpec_priority |
| BestAtPriceSpec.badMode (field) | [SpecBook.lean:220](../../formal/Refinement/Swarm/SpecBook.lean#L220) | SpecBook.t.sol: testFuzz_BestAtPriceSpec_badMode |
| LevelSpec.fifo (field) | [SpecBook.lean:227](../../formal/Refinement/Swarm/SpecBook.lean#L227) | SpecBook.t.sol: testFuzz_LevelSpec_fifo |
| LevelSpec.priority (field) | [SpecBook.lean:233](../../formal/Refinement/Swarm/SpecBook.lean#L233) | SpecBook.t.sol: testFuzz_LevelSpec_priority |
| LevelSpec.badMode (field) | [SpecBook.lean:238](../../formal/Refinement/Swarm/SpecBook.lean#L238) | SpecBook.t.sol: testFuzz_LevelSpec_badMode |
| CreateOrderSpec.notAuthorised (spec field) | [SpecCoreAsyncSwap.lean:111](../../formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L111) | SpecCore.t.sol: testFuzz_CreateOrderSpec_notAuthorised |
| CreateOrderSpec.zeroAmount (spec field) | [SpecCoreAsyncSwap.lean:115](../../formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L115) | SpecCore.t.sol: testFuzz_CreateOrderSpec_zeroAmount |
| CreateOrderSpec.run (spec field) | [SpecCoreAsyncSwap.lean:119](../../formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L119) | SpecCore.t.sol: testFuzz_CreateOrderSpec_run, testFuzz_CreateOrderSpec_run_repeat, testFuzz_CreateOrderSpec_run_addOrderGuards |
| TransferSpec.native (spec field) | [SpecCoreAsyncSwap.lean:331](../../formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L331) | SpecCore.t.sol: testFuzz_TransferSpec_native, testFuzz_TransferSpec_viaSweep |
| TransferSpec.erc20 (spec field) | [SpecCoreAsyncSwap.lean:342](../../formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L342) | SpecCore.t.sol: testFuzz_TransferSpec_erc20, testFuzz_TransferSpec_erc20_noCode, testFuzz_TransferSpec_viaSweep |
| PoolStateSlotSpec.pure_ok (spec field) | [SpecCoreAsyncSwap.lean:402](../../formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L402) | SpecCore.t.sol: testFuzz_PoolStateSlotSpec_pure_ok |
| PoolStateSlotSpec.value (spec field) | [SpecCoreAsyncSwap.lean:404](../../formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L404) | SpecCore.t.sol: testFuzz_PoolStateSlotSpec_value |
| TransferSpec.native, Router (spec field) | [SpecCoreRouter.lean:52](../../formal/Refinement/Swarm/SpecCoreRouter.lean#L52) | SpecCore.t.sol: testFuzz_Router_TransferSpec_native |
| TransferSpec.erc20, Router (spec field) | [SpecCoreRouter.lean:62](../../formal/Refinement/Swarm/SpecCoreRouter.lean#L62) | SpecCore.t.sol: testFuzz_Router_TransferSpec_erc20 |
| CtorSpec (AsyncSwap; all fields) | [SpecEip712AsyncSwap.lean:50](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L50) | SpecEip712.t.sol: testFuzz_CtorSpec (AsyncSwapCtorSpecFormalTest); guards also AsyncSwapConstructor.t.sol |
| ShortStringsSpec (AsyncSwap; toString_reverts) | [SpecEip712AsyncSwap.lean:138](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L138) | SpecEip712.t.sol: testFuzz_ShortStringsSpec_toString_reverts |
| ShortStringsSpec (AsyncSwap; toString_ok) | [SpecEip712AsyncSwap.lean:138](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L138) | SpecEip712.t.sol: testFuzz_ShortStringsSpec_toString_ok |
| ShortStringsSpec (AsyncSwap; withFallback) | [SpecEip712AsyncSwap.lean:138](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L138) | SpecEip712.t.sol: testFuzz_ShortStringsSpec_withFallback |
| Eip712DomainSpec (AsyncSwap; body) | [SpecEip712AsyncSwap.lean:155](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L155) | SpecEip712.t.sol: testFuzz_Eip712DomainSpec_body (AsyncSwapSpecEip712FormalTest) |
| CtorSpec (Router; all fields) | [RouterConstructor.lean:51](../../formal/Refinement/Swarm/RouterConstructor.lean#L51) | RouterConstructor.t.sol: testFuzz_CtorSpec |
| ShortStringsSpec (Router; 3 fields) | [SpecEip712Router.lean:36](../../formal/Refinement/Swarm/SpecEip712Router.lean#L36) | SpecEip712.t.sol: testFuzz_ShortStringsSpec_toString_reverts / _toString_ok / _withFallback (same library code) |
| Eip712DomainSpec (Router; body) | [SpecEip712Router.lean:53](../../formal/Refinement/Swarm/SpecEip712Router.lean#L53) | SpecEip712.t.sol: testFuzz_Eip712DomainSpec_body (RouterSpecEip712FormalTest) |
| `ERC1271Spec.total` (AsyncSwap `_2280`) | [SpecSigAsyncSwap.lean:101](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L101) | SpecSig.t.sol: testFuzz_ERC1271Spec_total, testFuzz_ERC1271Spec_onHook |
| `ERC1271Spec.readOnly` (AsyncSwap) | [SpecSigAsyncSwap.lean:104](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L104) | SpecSig.t.sol: testFuzz_ERC1271Spec_readOnly, testFuzz_ERC1271Spec_onHook |
| `ERC1271Spec.result` (AsyncSwap) | [SpecSigAsyncSwap.lean:106](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L106) | SpecSig.t.sol: testFuzz_ERC1271Spec_result, testFuzz_ERC1271Spec_result_calldata, testFuzz_ERC1271Spec_result_noCode_precompile, testFuzz_ERC1271Spec_onHook |
| `ERC1271Spec.total` / `.readOnly` / `.result` (Router `_1883`) | [SpecSigRouter.lean:80](../../formal/Refinement/Swarm/SpecSigRouter.lean#L80) | SpecSig.t.sol: testFuzz_ERC1271Spec_onRouter (plus the library tests above) |
| `TypedDataHashSpec.total` (AsyncSwap `_9732`) | [SpecSigAsyncSwap.lean:114](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L114) | SpecSig.t.sol: testFuzz_TypedDataHashSpec_total |
| `TypedDataHashSpec.readOnly` (AsyncSwap) | [SpecSigAsyncSwap.lean:116](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L116) | SpecSig.t.sol: testFuzz_TypedDataHashSpec_readOnly |
| `TypedDataHashSpec.result` (AsyncSwap) | [SpecSigAsyncSwap.lean:119](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L119) | SpecSig.t.sol: testFuzz_TypedDataHashSpec_result, testFuzz_HashSetExecutorSpec_onHook, testFuzz_hashTypedDataV4_run |
| `TypedDataHashSpec.total` / `.readOnly` / `.result` (Router `_5799`) | [SpecSigRouter.lean:93](../../formal/Refinement/Swarm/SpecSigRouter.lean#L93) | SpecSig.t.sol: testFuzz_hashTypedDataV4_run_router (plus the library tests above) |
| `HashSetExecutorSpec.total` / `.readOnly` | [SpecSigAsyncSwap.lean:125](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L125) | SpecSig.t.sol: testFuzz_HashSetExecutorSpec_total_readOnly |
| `HashSetExecutorSpec.result` | [SpecSigAsyncSwap.lean:129](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L129) | SpecSig.t.sol: testFuzz_HashSetExecutorSpec_result, testFuzz_HashSetExecutorSpec_onHook |
| `HashPoolKeySpec.total` / `.readOnly` (AsyncSwap `_9171`, Router `_4949`) | [SpecSigAsyncSwap.lean:135](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L135), [SpecSigRouter.lean:104](../../formal/Refinement/Swarm/SpecSigRouter.lean#L104) | SpecSig.t.sol: testFuzz_HashPoolKeySpec_total_readOnly |
| `HashPoolKeySpec.result` (both) | [SpecSigAsyncSwap.lean:139](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L139), [SpecSigRouter.lean:108](../../formal/Refinement/Swarm/SpecSigRouter.lean#L108) | SpecSig.t.sol: testFuzz_HashPoolKeySpec_result, testFuzz_HashSetExecutorSpec_onHook (inlined in the hook) |
| The Lean words `POOL_KEY_TYPEHASH`, `SET_EXECUTOR_TYPEHASH`, `ERC1271_SELECTOR`, `ERC1271_MAGIC` | [SpecSigAsyncSwap.lean:52](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L52), [SpecSigRouter.lean:39](../../formal/Refinement/Swarm/SpecSigRouter.lean#L39) | SpecSig.t.sol: test_SpecSig_typehash_words |

</details>

## Findings

### `ShortStringSpec.toString` is false

`AsyncSwapEip712Domain.lean` and `RouterEip712Domain.lean` assume `ShortStringSpec`, which says
`ShortStrings.toString` succeeds on every word. OpenZeppelin's `toString` reverts with
`InvalidShortString()` when the length byte is over 31. `test_finding_ShortStringSpec_toString_every_word`
(`SpecEip712.t.sol`) fails on `toString(0x20)`.
- **Contracts:** unaffected, because the deployed names ("AsyncSwap", "1", "AsyncSwap Router") are short.
- **The theorems built on it:** they rest on a hypothesis the real code doesn't satisfy.
- **The fix:** `ShortStringsSpec` (`SpecEip712*.lean`) states the behaviour correctly, and the
  `eip712Domain_*_of_spec` theorems recover the old results from it.

### Resolved: `mulDiv` with a zero denominator

The bytecode disproved 8 theorems, and a ninth was found while fixing them. All followed from one
translation error: formal-ast's prelude modelled OpenZeppelin's `Math.mulDiv` with a `mulDivFloor` that
panicked with `0x12` whenever the denominator was 0.
- **What OpenZeppelin 5.0 actually does:** it only divides when the 512-bit product fits in one word
  (`prod1 == 0`). Otherwise it checks `denominator <= prod1` first and reverts with
  `MathOverflowedMulDiv()`.
- **The counterexample:** for `d = 0` and `x·y ≥ 2^256` (for example x = y = 2^128, d = 0), the model
  predicted `Panic(0x12)` and the bytecode reverted with `MathOverflowedMulDiv()`.
- **Reachability:** none through the contracts. The hook rejects a zero `amountOutMin`, and escrowed
  amounts stay below 2^127.

**Fixed in formal-ast** ([formalmind/formalmind#12](https://github.com/formalmind/formalmind/pull/12),
CLI 0.1.1): `mulDivFloor` now panics `0x12` only when `x·y < 2^256`, and reverts `MathOverflowedMulDiv`
otherwise. For `d > 0` this is the same as before. `formal/Generated` was regenerated with it.
- **Restated to the corrected behaviour:** `floor_run`, `ceil_run`, `crosses_run`,
  `crosses_reverts_div0`, `matchAmounts_reverts_restingBuy` / `restingSell`,
  `matchPair_reverts_restingZero` and `settleMatchedPriorityFee_run`.
- **New:** `mulDiv_eq_mulDivFloor_any` drops the old `d ≠ 0` hypothesis.
- **Tests:** they're back to their normal names, and they now pass on the bytecode.

## Where the model and the bytecode differ

- **Hypotheses no real callee can meet.** These theorems still hold, but nothing on chain satisfies
  their assumptions, so they say nothing about the deployed contract. Each has an `_of_spec`
  replacement that is checked on the bytecode:
  - `beforeSwap_frame` assumes `_createOrder` leaves the hook's storage unchanged, but the real
    function stores the order (`test_note_beforeSwap_frame_hcreate_false`).
  - `orderBookLevel_view` and `orderBookLevel_congr` assume `level` never reverts, but it can: with a
    bad mode byte, or on an unbounded tree walk.

No theorem fails on the bytecode. A few statements are looser than the EVM, though none of these
differences is reachable through a well-formed call:

- **Library errors lose their names.** In the TryFill, MatchNewOrder, RecordPriorityFee,
  FillOrderFromPoolLiquidity and BeforeSwap models, `AsyncFiller.NotAuthorizedExecutor` /
  `OrderNotFound` become `.error ⟨""⟩`. The CancelOrder and ExecuteOrder models do name them, so the
  translation is inconsistent.
  - One consequence: `tryFillOrderFromPoolLiquidity_notFound` holds in the model for any caller. On
    the bytecode, a non-executor gets `NotAuthorizedExecutor` first.
- **`abi.decode` failures** are `.error ⟨"abi.decode"⟩` in the model. On the bytecode they revert
  with empty data.
- **Enums are unbounded `Nat`s.** This also covers `addOrder`: a stored mode byte ≥ 2 panics with
  `0x21` on the bytecode, where the model predicts `PriorityFeeTooLarge`, an overflow, or success
  (`testFuzz_note_addOrder_modeOutOfRange`).
  - For `mode ≥ 2`, `setOrderingMode` reverts during ABI decoding before `onlyOwner` runs, while the
    model predicts `NotOwner` or a write.
  - A stored mode byte ≥ 2 makes `orderingMode()` panic with `0x21`, while the model says it never
    reverts. That state can't be reached.
  - The `testFuzz_note_*` / `test_note_*` tests record both behaviours.
- **Loop bound vs gas.** `bestOrder_loopBound` reverts with `"loop bound"` after 2^64 steps in the
  model. The EVM runs out of gas instead, so the test checks only that the call reverts.
- **Router `unlock` return data.** The Router discards `unlock`'s result, but solc still decodes the
  returned `bytes`. Malformed return data (only possible with a mock) makes `matchBook` /
  `fillFromPoolLiquidity` revert where the model succeeds.
  - The model reads `unlockCallback`'s action as word 0 of `data`. The bytecode reads
    `calldataload(0x44)`. The two agree for the standard encoding the PoolManager uses.
- **Direct library call.** Calling `AsyncMatching.setOrderingMode` directly hits solc's guard against
  direct library calls, so `asyncMatching_setOrderingMode_direct_noPoolChange` holds only because
  every such call reverts. The test checks what can be observed: the hook's storage is unchanged.

## Halmos

`FormalBase` deploys the hook from `type(AsyncSwap).creationCode`, not `vm.getCode`, so Halmos links
the `AsyncMatching` library itself, and the same fixture runs under both Forge and Halmos:

```sh
FOUNDRY_OUT=out-halmos FOUNDRY_CACHE_PATH=cache-halmos \
  halmos --forge-build-out out-halmos --match-contract 'FormalTest$' --function test
```

A partial run with Halmos 0.3.3 (15 of the 50 suites) found no counterexamples. 40 tests passed
symbolically. The other 29 stopped on cheatcodes Halmos doesn't support (`vm.expectRevert(bytes4)`,
`vm.record` / `vm.accesses`).

The `Halmos` column predicts which tests would run as they are:
- **yes (163 theorems):** plain inputs, no setup Halmos can't handle.
- **with edits (85 theorems):** the `vm.record` / `vm.accesses` write-set check needs to become
  before/after `vm.load` comparisons, and `vm.expectRevert` needs to become a low-level call that
  checks the revert data.
- **no:** mocks, signatures, real order books, unlock flows or gas exhaustion.

## Theorem → test map

The links point to the theorem's line in `formal/Refinement/`. The reasons for leaving a theorem out:
- **model-only helper:** a lemma about Lean defs, the monad, or ABI encoding, with no observable claim
  beyond the theorems that are tested.
- **cross-call invariant:** a spec `step_*` invariant carried over a `World`.
- **untestable hypothesis:** the theorem assumes something about an opaque call that the real callee
  can't do.

### `Refinement/AsyncSwap.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `isExecutor_refines` | [AsyncSwap.lean:49](../../formal/Refinement/AsyncSwap.lean#L49) | [`RefinementAsyncSwap.t.sol`](RefinementAsyncSwap.t.sol) `testFuzz_isExecutor_refines` | with edits |
| `setExecutor_run` | [AsyncSwap.lean:57](../../formal/Refinement/AsyncSwap.lean#L57) | [`RefinementAsyncSwap.t.sol`](RefinementAsyncSwap.t.sol) `testFuzz_setExecutor_run` | with edits |
| `setExecutor_refines` | [AsyncSwap.lean:65](../../formal/Refinement/AsyncSwap.lean#L65) | [`RefinementAsyncSwap.t.sol`](RefinementAsyncSwap.t.sol) `testFuzz_setExecutor_refines` | yes |
| `setExecutor_frame` | [AsyncSwap.lean:81](../../formal/Refinement/AsyncSwap.lean#L81) | [`RefinementAsyncSwap.t.sol`](RefinementAsyncSwap.t.sol) `testFuzz_setExecutor_frame` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `setExecutor_escrow` | [AsyncSwap.lean:110](../../formal/Refinement/AsyncSwap.lean#L110) | cross-call invariant (spec `step_escrow` carried over a World) |
| `setExecutor_bal_nonneg` | [AsyncSwap.lean:117](../../formal/Refinement/AsyncSwap.lean#L117) | cross-call invariant (spec `step_bal_nonneg`) |
| `setExecutor_claims_nonneg` | [AsyncSwap.lean:124](../../formal/Refinement/AsyncSwap.lean#L124) | cross-call invariant (spec `step_claims_nonneg`) |
| `setExecutor_backing` | [AsyncSwap.lean:131](../../formal/Refinement/AsyncSwap.lean#L131) | cross-call invariant (spec `step_backing`) |
| `setExecutor_conservation` | [AsyncSwap.lean:138](../../formal/Refinement/AsyncSwap.lean#L138) | cross-call invariant / `_conservation` over a World |
| `setExecutor_reserves_nonneg` | [AsyncSwap.lean:147](../../formal/Refinement/AsyncSwap.lean#L147) | cross-call invariant (spec `step_reserves_nonneg`) |

### `Refinement/Monad.lean`


Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `run_bind` | [Monad.lean:14](../../formal/Refinement/Monad.lean#L14) | model-only helper (simp lemma about the Lean monad / ABI encoding) |
| `run_pure` | [Monad.lean:20](../../formal/Refinement/Monad.lean#L20) | model-only helper (simp lemma about the Lean monad / ABI encoding) |
| `run_read` | [Monad.lean:23](../../formal/Refinement/Monad.lean#L23) | model-only helper (simp lemma about the Lean monad / ABI encoding) |
| `run_readThe` | [Monad.lean:26](../../formal/Refinement/Monad.lean#L26) | model-only helper (simp lemma about the Lean monad / ABI encoding) |
| `run_get` | [Monad.lean:29](../../formal/Refinement/Monad.lean#L29) | model-only helper (simp lemma about the Lean monad / ABI encoding) |
| `run_modify` | [Monad.lean:32](../../formal/Refinement/Monad.lean#L32) | model-only helper (simp lemma about the Lean monad / ABI encoding) |
| `run_throw` | [Monad.lean:35](../../formal/Refinement/Monad.lean#L35) | model-only helper (simp lemma about the Lean monad / ABI encoding) |
| `run_ite` | [Monad.lean:38](../../formal/Refinement/Monad.lean#L38) | model-only helper (simp lemma about the Lean monad / ABI encoding) |
| `run_map` | [Monad.lean:47](../../formal/Refinement/Monad.lean#L47) | model-only helper (simp lemma about the Lean monad / ABI encoding) |
| `ite_ok_error_eq_ok` | [Monad.lean:58](../../formal/Refinement/Monad.lean#L58) | model-only helper (simp lemma about the Lean monad / ABI encoding) |

### `Refinement/Router.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `swap_sound` | [Router.lean:155](../../formal/Refinement/Router.lean#L155) | [`RefinementRouter.t.sol`](RefinementRouter.t.sol) `testFuzz_swap_sound` | no |
| `swap_complete` | [Router.lean:168](../../formal/Refinement/Router.lean#L168) | [`RefinementRouter.t.sol`](RefinementRouter.t.sol) `testFuzz_swap_complete` | no |
| `cancelOrder_sound` | [Router.lean:197](../../formal/Refinement/Router.lean#L197) | [`RefinementRouter.t.sol`](RefinementRouter.t.sol) `testFuzz_cancelOrder_sound` | no |
| `cancelOrder_complete` | [Router.lean:206](../../formal/Refinement/Router.lean#L206) | [`RefinementRouter.t.sol`](RefinementRouter.t.sol) `testFuzz_cancelOrder_complete` | no |
| `unlockCallback_cancel` | [Router.lean:269](../../formal/Refinement/Router.lean#L269) | [`RefinementRouter.t.sol`](RefinementRouter.t.sol) `testFuzz_unlockCallback_cancel` | no |
| `unlockCallback_fill_maxPrice` | [Router.lean:318](../../formal/Refinement/Router.lean#L318) | [`RefinementRouter.t.sol`](RefinementRouter.t.sol) `testFuzz_unlockCallback_fill_maxPrice` | no |
| `fillOrder_value_sound` | [Router.lean:380](../../formal/Refinement/Router.lean#L380) | [`RefinementRouter.t.sol`](RefinementRouter.t.sol) `testFuzz_fillOrder_value_sound` | no |
| `fillOrder_forwards` | [Router.lean:398](../../formal/Refinement/Router.lean#L398) | [`RefinementRouter.t.sol`](RefinementRouter.t.sol) `testFuzz_fillOrder_forwards` | no |
| `fillOrder_maxPrice` | [Router.lean:425](../../formal/Refinement/Router.lean#L425) | [`RefinementRouter.t.sol`](RefinementRouter.t.sol) `testFuzz_fillOrder_maxPrice` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `bytesWord_append` | [Router.lean:37](../../formal/Refinement/Router.lean#L37) | model-only helper (Lean lemma about `bytesWord`) |
| `bytesWord_bytes` | [Router.lean:40](../../formal/Refinement/Router.lean#L40) | model-only helper (`bytesWord`) |
| `bytesWord_wordBytes` | [Router.lean:60](../../formal/Refinement/Router.lean#L60) | model-only helper (`bytesWord`/`wordBytes`) |
| `length_wordBytes` | [Router.lean:64](../../formal/Refinement/Router.lean#L64) | model-only helper (simp lemma about the Lean monad / ABI encoding) |
| `abiEncode_cons` | [Router.lean:67](../../formal/Refinement/Router.lean#L67) | model-only helper (`abiEncode`) |
| `length_abiEncode` | [Router.lean:70](../../formal/Refinement/Router.lean#L70) | model-only helper (simp lemma about the Lean monad / ABI encoding) |
| `take_drop_abiEncode_cons` | [Router.lean:76](../../formal/Refinement/Router.lean#L76) | model-only helper (`abiEncode` word slicing) |
| `take_abiEncode_cons` | [Router.lean:86](../../formal/Refinement/Router.lean#L86) | model-only helper (simp lemma about the Lean monad / ABI encoding) |
| `bytesWord_wordBytes_of_lt` | [Router.lean:90](../../formal/Refinement/Router.lean#L90) | model-only helper (`bytesWord`/`wordBytes`) |
| `Binds.isNative_input` | [Router.lean:127](../../formal/Refinement/Router.lean#L127) | model-only helper (spec `Config.isNative` vs `inputCurrency` abstraction) |
| `swapGuard_router` | [Router.lean:145](../../formal/Refinement/Router.lean#L145) | spec-only lemma (about `V2.Protocol.swapGuard`, no contract call) |
| `userParamsOf_abiEncode` | [Router.lean:187](../../formal/Refinement/Router.lean#L187) | model-only helper (round trip of the model's `abiEncode`/`userParamsOf`) |
| `spec_cancelOrder_owner` | [Router.lean:214](../../formal/Refinement/Router.lean#L214) | spec-only lemma (about `V2.Protocol.cancelOrder`, no contract call) |
| `ybool_le_one` | [Router.lean:238](../../formal/Refinement/Router.lean#L238) | model-only helper (simp lemma about the Lean monad / ABI encoding) |
| `ybool_beq_one` | [Router.lean:239](../../formal/Refinement/Router.lean#L239) | model-only helper (simp lemma about the Lean monad / ABI encoding) |
| `toUnsigned_lt` | [Router.lean:241](../../formal/Refinement/Router.lean#L241) | model-only helper (`toUnsigned`) |
| `toSigned_toUnsigned` | [Router.lean:247](../../formal/Refinement/Router.lean#L247) | model-only helper (`toSigned`/`toUnsigned`) |
| `Binds.isNative_output` | [Router.lean:298](../../formal/Refinement/Router.lean#L298) | model-only helper (spec `isNative` vs `outputCurrency` abstraction) |
| `run_view` | [Router.lean:355](../../formal/Refinement/Router.lean#L355) | model-only helper (simp lemma about the Lean monad / ABI encoding) |
| `view_ok_iff` | [Router.lean:360](../../formal/Refinement/Router.lean#L360) | model-only helper (`Except` match on `view`) |

### `Refinement/Swarm/Assumptions.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `asyncSwap_short` | [Assumptions.lean:88](../../formal/Refinement/Swarm/Assumptions.lean#L88) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `test_asyncSwap_short` | yes |
| `one_short` | [Assumptions.lean:91](../../formal/Refinement/Swarm/Assumptions.lean#L91) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `test_one_short` | yes |
| `asyncSwapRouter_short` | [Assumptions.lean:94](../../formal/Refinement/Swarm/Assumptions.lean#L94) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `test_asyncSwapRouter_short` | yes |
| `fallbackStore_none` | [Assumptions.lean:98](../../formal/Refinement/Swarm/Assumptions.lean#L98) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `test_fallbackStore_none` | no |
| `decode_asyncSwap` | [Assumptions.lean:103](../../formal/Refinement/Swarm/Assumptions.lean#L103) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `test_decode_asyncSwap` | yes |
| `decode_one` | [Assumptions.lean:107](../../formal/Refinement/Swarm/Assumptions.lean#L107) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `test_decode_one` | yes |
| `decode_asyncSwapRouter` | [Assumptions.lean:110](../../formal/Refinement/Swarm/Assumptions.lean#L110) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `test_decode_asyncSwapRouter` | yes |
| `deployed_short` | [Assumptions.lean:116](../../formal/Refinement/Swarm/Assumptions.lean#L116) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `test_deployed_short` | yes |

### `Refinement/Swarm/AsyncFillerRemove.lean`


Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `seg_append` | [AsyncFillerRemove.lean:18](../../formal/Refinement/Swarm/AsyncFillerRemove.lean#L18) | model-only helper (Lean lemma about the `Seg` list predicate) |
| `seg_congr` | [AsyncFillerRemove.lean:31](../../formal/Refinement/Swarm/AsyncFillerRemove.lean#L31) | model-only helper (Lean lemma about `Seg`) |

### `Refinement/Swarm/AsyncFillerRemoveQueue.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `unlink_next` | [AsyncFillerRemoveQueue.lean:41](../../formal/Refinement/Swarm/AsyncFillerRemoveQueue.lean#L41) | [`AsyncFillerRemoveQueue.t.sol`](AsyncFillerRemoveQueue.t.sol) `testFuzz_unlink_next` | no |
| `unlink_prev` | [AsyncFillerRemoveQueue.lean:48](../../formal/Refinement/Swarm/AsyncFillerRemoveQueue.lean#L48) | [`AsyncFillerRemoveQueue.t.sol`](AsyncFillerRemoveQueue.t.sol) `testFuzz_unlink_prev` | no |
| `unlink_other` | [AsyncFillerRemoveQueue.lean:56](../../formal/Refinement/Swarm/AsyncFillerRemoveQueue.lean#L56) | [`AsyncFillerRemoveQueue.t.sol`](AsyncFillerRemoveQueue.t.sol) `testFuzz_unlink_other` | no |
| `unlink_linksOnly` | [AsyncFillerRemoveQueue.lean:78](../../formal/Refinement/Swarm/AsyncFillerRemoveQueue.lean#L78) | [`AsyncFillerRemoveQueue.t.sol`](AsyncFillerRemoveQueue.t.sol) `testFuzz_unlink_linksOnly` | no |
| `unlinkLevel_head` | [AsyncFillerRemoveQueue.lean:87](../../formal/Refinement/Swarm/AsyncFillerRemoveQueue.lean#L87) | [`AsyncFillerRemoveQueue.t.sol`](AsyncFillerRemoveQueue.t.sol) `testFuzz_unlinkLevel_head` | no |
| `unlinkLevel_tail` | [AsyncFillerRemoveQueue.lean:90](../../formal/Refinement/Swarm/AsyncFillerRemoveQueue.lean#L90) | [`AsyncFillerRemoveQueue.t.sol`](AsyncFillerRemoveQueue.t.sol) `testFuzz_unlinkLevel_tail` | no |
| `unlinkLevel_orderCount` | [AsyncFillerRemoveQueue.lean:93](../../formal/Refinement/Swarm/AsyncFillerRemoveQueue.lean#L93) | [`AsyncFillerRemoveQueue.t.sol`](AsyncFillerRemoveQueue.t.sol) `testFuzz_unlinkLevel_orderCount` | no |
| `unlinkLevel_priorityOrders` | [AsyncFillerRemoveQueue.lean:96](../../formal/Refinement/Swarm/AsyncFillerRemoveQueue.lean#L96) | [`AsyncFillerRemoveQueue.t.sol`](AsyncFillerRemoveQueue.t.sol) `testFuzz_unlinkLevel_priorityOrders` | no |
| `unlinkLevel_priorityOrderIds` | [AsyncFillerRemoveQueue.lean:99](../../formal/Refinement/Swarm/AsyncFillerRemoveQueue.lean#L99) | [`AsyncFillerRemoveQueue.t.sol`](AsyncFillerRemoveQueue.t.sol) `testFuzz_unlinkLevel_priorityOrderIds` | no |
| `queue_unlink` | [AsyncFillerRemoveQueue.lean:149](../../formal/Refinement/Swarm/AsyncFillerRemoveQueue.lean#L149) | [`AsyncFillerRemoveQueue.t.sol`](AsyncFillerRemoveQueue.t.sol) `testFuzz_queue_unlink` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `seg_head` | [AsyncFillerRemoveQueue.lean:7](../../formal/Refinement/Swarm/AsyncFillerRemoveQueue.lean#L7) | model-only helper (Lean lemma about `Seg`) |
| `seg_last` | [AsyncFillerRemoveQueue.lean:12](../../formal/Refinement/Swarm/AsyncFillerRemoveQueue.lean#L12) | model-only helper (Lean lemma about `Seg`) |
| `upd_next` | [AsyncFillerRemoveQueue.lean:33](../../formal/Refinement/Swarm/AsyncFillerRemoveQueue.lean#L33) | model-only helper (lemma about Lean `upd`) |
| `upd_previous` | [AsyncFillerRemoveQueue.lean:37](../../formal/Refinement/Swarm/AsyncFillerRemoveQueue.lean#L37) | model-only helper (lemma about Lean `upd`) |
| `linksOnly_refl` | [AsyncFillerRemoveQueue.lean:66](../../formal/Refinement/Swarm/AsyncFillerRemoveQueue.lean#L66) | model-only helper (Lean `LinksOnly` relation) |
| `linksOnly_upd` | [AsyncFillerRemoveQueue.lean:68](../../formal/Refinement/Swarm/AsyncFillerRemoveQueue.lean#L68) | model-only helper (Lean `LinksOnly` / `upd`) |
| `queue_default` | [AsyncFillerRemoveQueue.lean:115](../../formal/Refinement/Swarm/AsyncFillerRemoveQueue.lean#L115) | model-only helper (the Lean default `PriceLevel` is the empty `Queue`) |
| `dropLast_ne` | [AsyncFillerRemoveQueue.lean:118](../../formal/Refinement/Swarm/AsyncFillerRemoveQueue.lean#L118) | model-only helper (Lean `List` lemma) |
| `tail_ne` | [AsyncFillerRemoveQueue.lean:127](../../formal/Refinement/Swarm/AsyncFillerRemoveQueue.lean#L127) | model-only helper (Lean `List` lemma) |
| `getLastD_cases` | [AsyncFillerRemoveQueue.lean:137](../../formal/Refinement/Swarm/AsyncFillerRemoveQueue.lean#L137) | model-only helper (Lean `List` lemma) |
| `headD_cases` | [AsyncFillerRemoveQueue.lean:142](../../formal/Refinement/Swarm/AsyncFillerRemoveQueue.lean#L142) | model-only helper (Lean `List` lemma) |

### `Refinement/Swarm/AsyncMatchingSetOrderingModeDirect.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `asyncMatching_setOrderingMode_direct_noPoolChange` | [AsyncMatchingSetOrderingModeDirect.lean:52](../../formal/Refinement/Swarm/AsyncMatchingSetOrderingModeDirect.lean#L52) | [`AsyncMatchingSetOrderingModeDirect.t.sol`](AsyncMatchingSetOrderingModeDirect.t.sol) `testFuzz_asyncMatching_setOrderingMode_direct_noPoolChange` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `asyncMatching_setOrderingMode_frame` | [AsyncMatchingSetOrderingModeDirect.lean:28](../../formal/Refinement/Swarm/AsyncMatchingSetOrderingModeDirect.lean#L28) | model-only generic frame lemma over abstract accessors `book_get`/`book_set`; its concrete two-account instance is tested (direct_noPoolChange) |

### `Refinement/Swarm/AsyncSwapAcceptOwnership.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `acceptOwnership_run` | [AsyncSwapAcceptOwnership.lean:20](../../formal/Refinement/Swarm/AsyncSwapAcceptOwnership.lean#L20) | [`AsyncSwapAcceptOwnership.t.sol`](AsyncSwapAcceptOwnership.t.sol) `testFuzz_acceptOwnership_run` | with edits |
| `acceptOwnership_notPending` | [AsyncSwapAcceptOwnership.lean:30](../../formal/Refinement/Swarm/AsyncSwapAcceptOwnership.lean#L30) | [`AsyncSwapAcceptOwnership.t.sol`](AsyncSwapAcceptOwnership.t.sol) `testFuzz_acceptOwnership_notPending` | with edits |
| `acceptOwnership_reverts_iff` | [AsyncSwapAcceptOwnership.lean:36](../../formal/Refinement/Swarm/AsyncSwapAcceptOwnership.lean#L36) | [`AsyncSwapAcceptOwnership.t.sol`](AsyncSwapAcceptOwnership.t.sol) `testFuzz_acceptOwnership_reverts_iff` | with edits |
| `acceptOwnership_ok_iff` | [AsyncSwapAcceptOwnership.lean:45](../../formal/Refinement/Swarm/AsyncSwapAcceptOwnership.lean#L45) | [`AsyncSwapAcceptOwnership.t.sol`](AsyncSwapAcceptOwnership.t.sol) `testFuzz_acceptOwnership_ok_iff` | with edits |
| `acceptOwnership_ok_state` | [AsyncSwapAcceptOwnership.lean:56](../../formal/Refinement/Swarm/AsyncSwapAcceptOwnership.lean#L56) | [`AsyncSwapAcceptOwnership.t.sol`](AsyncSwapAcceptOwnership.t.sol) `testFuzz_acceptOwnership_ok_state` | with edits |

### `Refinement/Swarm/AsyncSwapAddOrder.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `priorityKey_zero` | [AsyncSwapAddOrder.lean:68](../../formal/Refinement/Swarm/AsyncSwapAddOrder.lean#L68) | [`AsyncSwapAddOrder.t.sol`](AsyncSwapAddOrder.t.sol) `testFuzz_priorityKey_zero (stored key of a fresh unpaid order; the `seq > 2^64-1` panic branch is unreachable because `_priorityKey` takes a `uint64`)` | no |
| `addOrder_run` | [AsyncSwapAddOrder.lean:76](../../formal/Refinement/Swarm/AsyncSwapAddOrder.lean#L76) | [`AsyncSwapAddOrder.t.sol`](AsyncSwapAddOrder.t.sol) `testFuzz_addOrder_run (+ testFuzz_note_addOrder_modeOutOfRange for mode byte >= 2)` | no |
| `addOrder_invalidMode` | [AsyncSwapAddOrder.lean:118](../../formal/Refinement/Swarm/AsyncSwapAddOrder.lean#L118) | [`AsyncSwapAddOrder.t.sol`](AsyncSwapAddOrder.t.sol) `testFuzz_addOrder_invalidMode` | no |
| `addOrder_feeTooSmall` | [AsyncSwapAddOrder.lean:125](../../formal/Refinement/Swarm/AsyncSwapAddOrder.lean#L125) | [`AsyncSwapAddOrder.t.sol`](AsyncSwapAddOrder.t.sol) `testFuzz_addOrder_feeTooSmall` | no |
| `addOrder_feeTooLarge` | [AsyncSwapAddOrder.lean:133](../../formal/Refinement/Swarm/AsyncSwapAddOrder.lean#L133) | [`AsyncSwapAddOrder.t.sol`](AsyncSwapAddOrder.t.sol) `testFuzz_addOrder_feeTooLarge (+ note test for mode >= 2)` | no |
| `addOrder_seqOverflow` | [AsyncSwapAddOrder.lean:144](../../formal/Refinement/Swarm/AsyncSwapAddOrder.lean#L144) | [`AsyncSwapAddOrder.t.sol`](AsyncSwapAddOrder.t.sol) `testFuzz_addOrder_seqOverflow (+ note test for mode >= 2)` | no |
| `addOrder_ok` | [AsyncSwapAddOrder.lean:167](../../formal/Refinement/Swarm/AsyncSwapAddOrder.lean#L167) | [`AsyncSwapAddOrder.t.sol`](AsyncSwapAddOrder.t.sol) `testFuzz_addOrder_ok` | no |
| `addState_order` | [AsyncSwapAddOrder.lean:208](../../formal/Refinement/Swarm/AsyncSwapAddOrder.lean#L208) | [`AsyncSwapAddOrder.t.sol`](AsyncSwapAddOrder.t.sol) `testFuzz_addState_order` | no |
| `addState_book` | [AsyncSwapAddOrder.lean:218](../../formal/Refinement/Swarm/AsyncSwapAddOrder.lean#L218) | [`AsyncSwapAddOrder.t.sol`](AsyncSwapAddOrder.t.sol) `testFuzz_addState_book` | no |
| `addState_other_order` | [AsyncSwapAddOrder.lean:227](../../formal/Refinement/Swarm/AsyncSwapAddOrder.lean#L227) | [`AsyncSwapAddOrder.t.sol`](AsyncSwapAddOrder.t.sol) `testFuzz_addState_other_order` | no |
| `addState_other_pool` | [AsyncSwapAddOrder.lean:237](../../formal/Refinement/Swarm/AsyncSwapAddOrder.lean#L237) | [`AsyncSwapAddOrder.t.sol`](AsyncSwapAddOrder.t.sol) `testFuzz_addState_other_pool` | no |
| `addState_frame` | [AsyncSwapAddOrder.lean:244](../../formal/Refinement/Swarm/AsyncSwapAddOrder.lean#L244) | [`AsyncSwapAddOrder.t.sol`](AsyncSwapAddOrder.t.sol) `testFuzz_addState_frame (on the hook; transient not checked, see notes)` | no |
| `matching_addOrder_eq` | [AsyncSwapAddOrder.lean:255](../../formal/Refinement/Swarm/AsyncSwapAddOrder.lean#L255) | [`AsyncSwapAddOrder.t.sol`](AsyncSwapAddOrder.t.sol) `testFuzz_matching_addOrder_eq` | no |
| `matching_addOrder_run` | [AsyncSwapAddOrder.lean:263](../../formal/Refinement/Swarm/AsyncSwapAddOrder.lean#L263) | [`AsyncSwapAddOrder.t.sol`](AsyncSwapAddOrder.t.sol) `testFuzz_matching_addOrder_run (+ note test, `viaMatching = true`)` | no |
| `matching_addOrder_invalidMode` | [AsyncSwapAddOrder.lean:284](../../formal/Refinement/Swarm/AsyncSwapAddOrder.lean#L284) | [`AsyncSwapAddOrder.t.sol`](AsyncSwapAddOrder.t.sol) `testFuzz_matching_addOrder_invalidMode` | no |
| `matching_addOrder_feeTooSmall` | [AsyncSwapAddOrder.lean:291](../../formal/Refinement/Swarm/AsyncSwapAddOrder.lean#L291) | [`AsyncSwapAddOrder.t.sol`](AsyncSwapAddOrder.t.sol) `testFuzz_matching_addOrder_feeTooSmall` | no |
| `matching_addOrder_feeTooLarge` | [AsyncSwapAddOrder.lean:299](../../formal/Refinement/Swarm/AsyncSwapAddOrder.lean#L299) | [`AsyncSwapAddOrder.t.sol`](AsyncSwapAddOrder.t.sol) `testFuzz_matching_addOrder_feeTooLarge` | no |
| `matching_addOrder_seqOverflow` | [AsyncSwapAddOrder.lean:309](../../formal/Refinement/Swarm/AsyncSwapAddOrder.lean#L309) | [`AsyncSwapAddOrder.t.sol`](AsyncSwapAddOrder.t.sol) `testFuzz_matching_addOrder_seqOverflow` | no |
| `matching_addOrder_ok` | [AsyncSwapAddOrder.lean:324](../../formal/Refinement/Swarm/AsyncSwapAddOrder.lean#L324) | [`AsyncSwapAddOrder.t.sol`](AsyncSwapAddOrder.t.sol) `testFuzz_matching_addOrder_ok` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `get_addWrite` | [AsyncSwapAddOrder.lean:158](../../formal/Refinement/Swarm/AsyncSwapAddOrder.lean#L158) | model-only helper (`ext.get ∘ ext.set` rewriting of the Lean def `addWrite`) |

### `Refinement/Swarm/AsyncSwapAfterAddLiquidity.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `afterAddLiquidity_notPoolManager` | [AsyncSwapAfterAddLiquidity.lean:20](../../formal/Refinement/Swarm/AsyncSwapAfterAddLiquidity.lean#L20) | [`AsyncSwapAfterAddLiquidity.t.sol`](AsyncSwapAfterAddLiquidity.t.sol) `testFuzz_afterAddLiquidity_notPoolManager` | yes |
| `afterAddLiquidity_poolManager` | [AsyncSwapAfterAddLiquidity.lean:28](../../formal/Refinement/Swarm/AsyncSwapAfterAddLiquidity.lean#L28) | [`AsyncSwapAfterAddLiquidity.t.sol`](AsyncSwapAfterAddLiquidity.t.sol) `testFuzz_afterAddLiquidity_poolManager` | yes |
| `afterAddLiquidity_spec` | [AsyncSwapAfterAddLiquidity.lean:37](../../formal/Refinement/Swarm/AsyncSwapAfterAddLiquidity.lean#L37) | [`AsyncSwapAfterAddLiquidity.t.sol`](AsyncSwapAfterAddLiquidity.t.sol) `testFuzz_afterAddLiquidity_spec` | yes |
| `afterAddLiquidity_never_ok` | [AsyncSwapAfterAddLiquidity.lean:49](../../formal/Refinement/Swarm/AsyncSwapAfterAddLiquidity.lean#L49) | [`AsyncSwapAfterAddLiquidity.t.sol`](AsyncSwapAfterAddLiquidity.t.sol) `testFuzz_afterAddLiquidity_never_ok` | yes |

### `Refinement/Swarm/AsyncSwapAfterDonate.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `afterDonate_notPoolManager` | [AsyncSwapAfterDonate.lean:20](../../formal/Refinement/Swarm/AsyncSwapAfterDonate.lean#L20) | [`AsyncSwapAfterDonate.t.sol`](AsyncSwapAfterDonate.t.sol) `testFuzz_afterDonate_notPoolManager` | yes |
| `afterDonate_poolManager` | [AsyncSwapAfterDonate.lean:26](../../formal/Refinement/Swarm/AsyncSwapAfterDonate.lean#L26) | [`AsyncSwapAfterDonate.t.sol`](AsyncSwapAfterDonate.t.sol) `testFuzz_afterDonate_poolManager` | yes |
| `afterDonate_spec` | [AsyncSwapAfterDonate.lean:33](../../formal/Refinement/Swarm/AsyncSwapAfterDonate.lean#L33) | [`AsyncSwapAfterDonate.t.sol`](AsyncSwapAfterDonate.t.sol) `testFuzz_afterDonate_spec` | yes |
| `afterDonate_never_ok` | [AsyncSwapAfterDonate.lean:45](../../formal/Refinement/Swarm/AsyncSwapAfterDonate.lean#L45) | [`AsyncSwapAfterDonate.t.sol`](AsyncSwapAfterDonate.t.sol) `testFuzz_afterDonate_never_ok` | yes |

### `Refinement/Swarm/AsyncSwapAfterInitialize.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `afterInitialize_notPoolManager` | [AsyncSwapAfterInitialize.lean:20](../../formal/Refinement/Swarm/AsyncSwapAfterInitialize.lean#L20) | [`AsyncSwapAfterInitialize.t.sol`](AsyncSwapAfterInitialize.t.sol) `testFuzz_afterInitialize_notPoolManager` | yes |
| `afterInitialize_hookNotImplemented` | [AsyncSwapAfterInitialize.lean:26](../../formal/Refinement/Swarm/AsyncSwapAfterInitialize.lean#L26) | [`AsyncSwapAfterInitialize.t.sol`](AsyncSwapAfterInitialize.t.sol) `testFuzz_afterInitialize_hookNotImplemented` | yes |
| `afterInitialize_spec` | [AsyncSwapAfterInitialize.lean:33](../../formal/Refinement/Swarm/AsyncSwapAfterInitialize.lean#L33) | [`AsyncSwapAfterInitialize.t.sol`](AsyncSwapAfterInitialize.t.sol) `testFuzz_afterInitialize_spec` | yes |
| `afterInitialize_never_ok` | [AsyncSwapAfterInitialize.lean:45](../../formal/Refinement/Swarm/AsyncSwapAfterInitialize.lean#L45) | [`AsyncSwapAfterInitialize.t.sol`](AsyncSwapAfterInitialize.t.sol) `testFuzz_afterInitialize_never_ok` | yes |

### `Refinement/Swarm/AsyncSwapAfterRemoveLiquidity.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `afterRemoveLiquidity_notPoolManager` | [AsyncSwapAfterRemoveLiquidity.lean:20](../../formal/Refinement/Swarm/AsyncSwapAfterRemoveLiquidity.lean#L20) | [`AsyncSwapAfterRemoveLiquidity.t.sol`](AsyncSwapAfterRemoveLiquidity.t.sol) `testFuzz_afterRemoveLiquidity_notPoolManager` | yes |
| `afterRemoveLiquidity_hookNotImplemented` | [AsyncSwapAfterRemoveLiquidity.lean:28](../../formal/Refinement/Swarm/AsyncSwapAfterRemoveLiquidity.lean#L28) | [`AsyncSwapAfterRemoveLiquidity.t.sol`](AsyncSwapAfterRemoveLiquidity.t.sol) `testFuzz_afterRemoveLiquidity_hookNotImplemented` | yes |
| `afterRemoveLiquidity_spec` | [AsyncSwapAfterRemoveLiquidity.lean:37](../../formal/Refinement/Swarm/AsyncSwapAfterRemoveLiquidity.lean#L37) | [`AsyncSwapAfterRemoveLiquidity.t.sol`](AsyncSwapAfterRemoveLiquidity.t.sol) `testFuzz_afterRemoveLiquidity_spec` | yes |
| `afterRemoveLiquidity_never_ok` | [AsyncSwapAfterRemoveLiquidity.lean:50](../../formal/Refinement/Swarm/AsyncSwapAfterRemoveLiquidity.lean#L50) | [`AsyncSwapAfterRemoveLiquidity.t.sol`](AsyncSwapAfterRemoveLiquidity.t.sol) `testFuzz_afterRemoveLiquidity_never_ok` | yes |

### `Refinement/Swarm/AsyncSwapAfterSwap.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `afterSwap_notPoolManager` | [AsyncSwapAfterSwap.lean:20](../../formal/Refinement/Swarm/AsyncSwapAfterSwap.lean#L20) | [`AsyncSwapAfterSwap.t.sol`](AsyncSwapAfterSwap.t.sol) `testFuzz_afterSwap_notPoolManager` | yes |
| `afterSwap_hookNotImplemented` | [AsyncSwapAfterSwap.lean:28](../../formal/Refinement/Swarm/AsyncSwapAfterSwap.lean#L28) | [`AsyncSwapAfterSwap.t.sol`](AsyncSwapAfterSwap.t.sol) `testFuzz_afterSwap_hookNotImplemented` | yes |
| `afterSwap_spec` | [AsyncSwapAfterSwap.lean:36](../../formal/Refinement/Swarm/AsyncSwapAfterSwap.lean#L36) | [`AsyncSwapAfterSwap.t.sol`](AsyncSwapAfterSwap.t.sol) `testFuzz_afterSwap_spec` | yes |
| `afterSwap_never_ok` | [AsyncSwapAfterSwap.lean:49](../../formal/Refinement/Swarm/AsyncSwapAfterSwap.lean#L49) | [`AsyncSwapAfterSwap.t.sol`](AsyncSwapAfterSwap.t.sol) `testFuzz_afterSwap_never_ok` | yes |

### `Refinement/Swarm/AsyncSwapAsyncOrder.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `asyncOrder_run` | [AsyncSwapAsyncOrder.lean:20](../../formal/Refinement/Swarm/AsyncSwapAsyncOrder.lean#L20) | [`AsyncSwapAsyncOrder.t.sol`](AsyncSwapAsyncOrder.t.sol) `testFuzz_asyncOrder_run` | with edits |
| `asyncOrder_never_reverts` | [AsyncSwapAsyncOrder.lean:25](../../formal/Refinement/Swarm/AsyncSwapAsyncOrder.lean#L25) | [`AsyncSwapAsyncOrder.t.sol`](AsyncSwapAsyncOrder.t.sol) `testFuzz_asyncOrder_never_reverts` | with edits |
| `asyncOrder_ok_iff` | [AsyncSwapAsyncOrder.lean:31](../../formal/Refinement/Swarm/AsyncSwapAsyncOrder.lean#L31) | [`AsyncSwapAsyncOrder.t.sol`](AsyncSwapAsyncOrder.t.sol) `testFuzz_asyncOrder_ok_iff` | no |
| `asyncOrder_reads_only_asyncOrders` | [AsyncSwapAsyncOrder.lean:41](../../formal/Refinement/Swarm/AsyncSwapAsyncOrder.lean#L41) | [`AsyncSwapAsyncOrder.t.sol`](AsyncSwapAsyncOrder.t.sol) `testFuzz_asyncOrder_reads_only_asyncOrders` | with edits |

### `Refinement/Swarm/AsyncSwapAsyncOrderInfo.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `asyncOrderInfo_run` | [AsyncSwapAsyncOrderInfo.lean:21](../../formal/Refinement/Swarm/AsyncSwapAsyncOrderInfo.lean#L21) | [`AsyncSwapAsyncOrderInfo.t.sol`](AsyncSwapAsyncOrderInfo.t.sol) `testFuzz_asyncOrderInfo_run` | with edits |
| `asyncOrderInfo_never_reverts` | [AsyncSwapAsyncOrderInfo.lean:27](../../formal/Refinement/Swarm/AsyncSwapAsyncOrderInfo.lean#L27) | [`AsyncSwapAsyncOrderInfo.t.sol`](AsyncSwapAsyncOrderInfo.t.sol) `testFuzz_asyncOrderInfo_never_reverts` | with edits |
| `asyncOrderInfo_ok_iff` | [AsyncSwapAsyncOrderInfo.lean:33](../../formal/Refinement/Swarm/AsyncSwapAsyncOrderInfo.lean#L33) | [`AsyncSwapAsyncOrderInfo.t.sol`](AsyncSwapAsyncOrderInfo.t.sol) `testFuzz_asyncOrderInfo_ok_iff` | no |
| `asyncOrderInfo_reads_only_asyncOrders` | [AsyncSwapAsyncOrderInfo.lean:44](../../formal/Refinement/Swarm/AsyncSwapAsyncOrderInfo.lean#L44) | [`AsyncSwapAsyncOrderInfo.t.sol`](AsyncSwapAsyncOrderInfo.t.sol) `testFuzz_asyncOrderInfo_reads_only_asyncOrders` | with edits |

### `Refinement/Swarm/AsyncSwapAsyncOrderPriorityFee.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `asyncOrderPriorityFee_run` | [AsyncSwapAsyncOrderPriorityFee.lean:21](../../formal/Refinement/Swarm/AsyncSwapAsyncOrderPriorityFee.lean#L21) | [`AsyncSwapAsyncOrderPriorityFee.t.sol`](AsyncSwapAsyncOrderPriorityFee.t.sol) `testFuzz_asyncOrderPriorityFee_run` | with edits |
| `asyncOrderPriorityFee_never_reverts` | [AsyncSwapAsyncOrderPriorityFee.lean:30](../../formal/Refinement/Swarm/AsyncSwapAsyncOrderPriorityFee.lean#L30) | [`AsyncSwapAsyncOrderPriorityFee.t.sol`](AsyncSwapAsyncOrderPriorityFee.t.sol) `testFuzz_asyncOrderPriorityFee_never_reverts` | with edits |
| `asyncOrderPriorityFee_ok_iff` | [AsyncSwapAsyncOrderPriorityFee.lean:36](../../formal/Refinement/Swarm/AsyncSwapAsyncOrderPriorityFee.lean#L36) | [`AsyncSwapAsyncOrderPriorityFee.t.sol`](AsyncSwapAsyncOrderPriorityFee.t.sol) `testFuzz_asyncOrderPriorityFee_ok_iff` | with edits |
| `asyncOrderPriorityFee_not_escrowed` | [AsyncSwapAsyncOrderPriorityFee.lean:46](../../formal/Refinement/Swarm/AsyncSwapAsyncOrderPriorityFee.lean#L46) | [`AsyncSwapAsyncOrderPriorityFee.t.sol`](AsyncSwapAsyncOrderPriorityFee.t.sol) `testFuzz_asyncOrderPriorityFee_not_escrowed` | no |
| `asyncOrderPriorityFee_escrowed` | [AsyncSwapAsyncOrderPriorityFee.lean:52](../../formal/Refinement/Swarm/AsyncSwapAsyncOrderPriorityFee.lean#L52) | [`AsyncSwapAsyncOrderPriorityFee.t.sol`](AsyncSwapAsyncOrderPriorityFee.t.sol) `testFuzz_asyncOrderPriorityFee_escrowed` | no |
| `asyncOrderPriorityFee_reads_only_asyncOrders` | [AsyncSwapAsyncOrderPriorityFee.lean:59](../../formal/Refinement/Swarm/AsyncSwapAsyncOrderPriorityFee.lean#L59) | [`AsyncSwapAsyncOrderPriorityFee.t.sol`](AsyncSwapAsyncOrderPriorityFee.t.sol) `testFuzz_asyncOrderPriorityFee_reads_only_asyncOrders` | with edits |

### `Refinement/Swarm/AsyncSwapBeforeAddLiquidity.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `beforeAddLiquidity_notPoolManager` | [AsyncSwapBeforeAddLiquidity.lean:19](../../formal/Refinement/Swarm/AsyncSwapBeforeAddLiquidity.lean#L19) | [`AsyncSwapBeforeAddLiquidity.t.sol`](AsyncSwapBeforeAddLiquidity.t.sol) `testFuzz_beforeAddLiquidity_notPoolManager` | yes |
| `beforeAddLiquidity_ok` | [AsyncSwapBeforeAddLiquidity.lean:26](../../formal/Refinement/Swarm/AsyncSwapBeforeAddLiquidity.lean#L26) | [`AsyncSwapBeforeAddLiquidity.t.sol`](AsyncSwapBeforeAddLiquidity.t.sol) `testFuzz_beforeAddLiquidity_ok (+ test_beforeAddLiquidity_ok_viaPoolManager)` | no |
| `beforeAddLiquidity_spec` | [AsyncSwapBeforeAddLiquidity.lean:35](../../formal/Refinement/Swarm/AsyncSwapBeforeAddLiquidity.lean#L35) | [`AsyncSwapBeforeAddLiquidity.t.sol`](AsyncSwapBeforeAddLiquidity.t.sol) `testFuzz_beforeAddLiquidity_spec` | no |
| `beforeAddLiquidity_frame` | [AsyncSwapBeforeAddLiquidity.lean:47](../../formal/Refinement/Swarm/AsyncSwapBeforeAddLiquidity.lean#L47) | [`AsyncSwapBeforeAddLiquidity.t.sol`](AsyncSwapBeforeAddLiquidity.t.sol) `testFuzz_beforeAddLiquidity_frame` | no |

### `Refinement/Swarm/AsyncSwapBeforeDonate.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `beforeDonate_notPoolManager` | [AsyncSwapBeforeDonate.lean:20](../../formal/Refinement/Swarm/AsyncSwapBeforeDonate.lean#L20) | [`AsyncSwapBeforeDonate.t.sol`](AsyncSwapBeforeDonate.t.sol) `testFuzz_beforeDonate_notPoolManager` | yes |
| `beforeDonate_poolManager` | [AsyncSwapBeforeDonate.lean:26](../../formal/Refinement/Swarm/AsyncSwapBeforeDonate.lean#L26) | [`AsyncSwapBeforeDonate.t.sol`](AsyncSwapBeforeDonate.t.sol) `testFuzz_beforeDonate_poolManager` | yes |
| `beforeDonate_spec` | [AsyncSwapBeforeDonate.lean:33](../../formal/Refinement/Swarm/AsyncSwapBeforeDonate.lean#L33) | [`AsyncSwapBeforeDonate.t.sol`](AsyncSwapBeforeDonate.t.sol) `testFuzz_beforeDonate_spec` | yes |
| `beforeDonate_never_ok` | [AsyncSwapBeforeDonate.lean:45](../../formal/Refinement/Swarm/AsyncSwapBeforeDonate.lean#L45) | [`AsyncSwapBeforeDonate.t.sol`](AsyncSwapBeforeDonate.t.sol) `testFuzz_beforeDonate_never_ok` | yes |

### `Refinement/Swarm/AsyncSwapBeforeInitialize.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `beforeInitialize_notPoolManager` | [AsyncSwapBeforeInitialize.lean:52](../../formal/Refinement/Swarm/AsyncSwapBeforeInitialize.lean#L52) | [`AsyncSwapBeforeInitialize.t.sol`](AsyncSwapBeforeInitialize.t.sol) `testFuzz_beforeInitialize_notPoolManager` | yes |
| `beforeInitialize_numeraireRequired` | [AsyncSwapBeforeInitialize.lean:58](../../formal/Refinement/Swarm/AsyncSwapBeforeInitialize.lean#L58) | [`AsyncSwapBeforeInitialize.t.sol`](AsyncSwapBeforeInitialize.t.sol) `testFuzz_beforeInitialize_numeraireRequired` | yes |
| `beforeInitialize_dynamicFeeRequired` | [AsyncSwapBeforeInitialize.lean:67](../../formal/Refinement/Swarm/AsyncSwapBeforeInitialize.lean#L67) | [`AsyncSwapBeforeInitialize.t.sol`](AsyncSwapBeforeInitialize.t.sol) `testFuzz_beforeInitialize_dynamicFeeRequired (+ test_beforeInitialize_dynamicFeeRequired_viaPoolManager)` | yes |
| `beforeInitialize_run_ok` | [AsyncSwapBeforeInitialize.lean:78](../../formal/Refinement/Swarm/AsyncSwapBeforeInitialize.lean#L78) | [`AsyncSwapBeforeInitialize.t.sol`](AsyncSwapBeforeInitialize.t.sol) `testFuzz_beforeInitialize_run_ok (+ test_beforeInitialize_run_ok_viaPoolManager)` | no |
| `beforeInitialize_ok` | [AsyncSwapBeforeInitialize.lean:97](../../formal/Refinement/Swarm/AsyncSwapBeforeInitialize.lean#L97) | [`AsyncSwapBeforeInitialize.t.sol`](AsyncSwapBeforeInitialize.t.sol) `testFuzz_beforeInitialize_ok` | no |
| `beforeInitialize_ok_inv` | [AsyncSwapBeforeInitialize.lean:105](../../formal/Refinement/Swarm/AsyncSwapBeforeInitialize.lean#L105) | [`AsyncSwapBeforeInitialize.t.sol`](AsyncSwapBeforeInitialize.t.sol) `testFuzz_beforeInitialize_ok_inv` | no |
| `beforeInitialize_succeeds_iff` | [AsyncSwapBeforeInitialize.lean:124](../../formal/Refinement/Swarm/AsyncSwapBeforeInitialize.lean#L124) | [`AsyncSwapBeforeInitialize.t.sol`](AsyncSwapBeforeInitialize.t.sol) `testFuzz_beforeInitialize_succeeds_iff` | yes |
| `beforeInitialize_frame` | [AsyncSwapBeforeInitialize.lean:145](../../formal/Refinement/Swarm/AsyncSwapBeforeInitialize.lean#L145) | [`AsyncSwapBeforeInitialize.t.sol`](AsyncSwapBeforeInitialize.t.sol) `testFuzz_beforeInitialize_frame` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `beforeInit_world_get` | [AsyncSwapBeforeInitialize.lean:88](../../formal/Refinement/Swarm/AsyncSwapBeforeInitialize.lean#L88) | model-only helper (rewrites Lean `beforeInit_world` into `beforeInit_state`; its content is covered by the `beforeInitialize_ok`/`_run_ok` tests) |

### `Refinement/Swarm/AsyncSwapBeforeRemoveLiquidity.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `beforeRemoveLiquidity_notPoolManager` | [AsyncSwapBeforeRemoveLiquidity.lean:20](../../formal/Refinement/Swarm/AsyncSwapBeforeRemoveLiquidity.lean#L20) | [`AsyncSwapBeforeRemoveLiquidity.t.sol`](AsyncSwapBeforeRemoveLiquidity.t.sol) `testFuzz_beforeRemoveLiquidity_notPoolManager` | yes |
| `beforeRemoveLiquidity_hookNotImplemented` | [AsyncSwapBeforeRemoveLiquidity.lean:28](../../formal/Refinement/Swarm/AsyncSwapBeforeRemoveLiquidity.lean#L28) | [`AsyncSwapBeforeRemoveLiquidity.t.sol`](AsyncSwapBeforeRemoveLiquidity.t.sol) `testFuzz_beforeRemoveLiquidity_hookNotImplemented` | yes |
| `beforeRemoveLiquidity_spec` | [AsyncSwapBeforeRemoveLiquidity.lean:37](../../formal/Refinement/Swarm/AsyncSwapBeforeRemoveLiquidity.lean#L37) | [`AsyncSwapBeforeRemoveLiquidity.t.sol`](AsyncSwapBeforeRemoveLiquidity.t.sol) `testFuzz_beforeRemoveLiquidity_spec` | yes |
| `beforeRemoveLiquidity_never_ok` | [AsyncSwapBeforeRemoveLiquidity.lean:49](../../formal/Refinement/Swarm/AsyncSwapBeforeRemoveLiquidity.lean#L49) | [`AsyncSwapBeforeRemoveLiquidity.t.sol`](AsyncSwapBeforeRemoveLiquidity.t.sol) `testFuzz_beforeRemoveLiquidity_never_ok` | yes |

### `Refinement/Swarm/AsyncSwapBeforeSwap.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `beforeSwap_notPoolManager` | [AsyncSwapBeforeSwap.lean:78](../../formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean#L78) | [`AsyncSwapBeforeSwap.t.sol`](AsyncSwapBeforeSwap.t.sol) `testFuzz_beforeSwap_notPoolManager` | yes |
| `beforeSwap_exactInputOnly` | [AsyncSwapBeforeSwap.lean:84](../../formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean#L84) | [`AsyncSwapBeforeSwap.t.sol`](AsyncSwapBeforeSwap.t.sol) `testFuzz_beforeSwap_exactInputOnly` | yes |
| `beforeSwap_negOverflow` | [AsyncSwapBeforeSwap.lean:91](../../formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean#L91) | [`AsyncSwapBeforeSwap.t.sol`](AsyncSwapBeforeSwap.t.sol) `testFuzz_beforeSwap_negOverflow` | yes |
| `beforeSwap_badDecode` | [AsyncSwapBeforeSwap.lean:101](../../formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean#L101) | [`AsyncSwapBeforeSwap.t.sol`](AsyncSwapBeforeSwap.t.sol) `testFuzz_beforeSwap_badDecode, testFuzz_beforeSwap_badDecode_dirtyAddress` | yes |
| `beforeSwap_notExecutor` | [AsyncSwapBeforeSwap.lean:143](../../formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean#L143) | [`AsyncSwapBeforeSwap.t.sol`](AsyncSwapBeforeSwap.t.sol) `testFuzz_beforeSwap_notExecutor` | yes |
| `beforeSwap_run_ok` | [AsyncSwapBeforeSwap.lean:161](../../formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean#L161) | [`AsyncSwapBeforeSwap.t.sol`](AsyncSwapBeforeSwap.t.sol) `testFuzz_beforeSwap_run_ok, testFuzz_beforeSwap_run_ok_tailErrors, test_beforeSwap_run_ok_viaRouter` | no |
| `beforeSwap_ok_inv` | [AsyncSwapBeforeSwap.lean:178](../../formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean#L178) | [`AsyncSwapBeforeSwap.t.sol`](AsyncSwapBeforeSwap.t.sol) `testFuzz_beforeSwap_ok_inv` | no |
| `beforeSwap_ok_returns` | [AsyncSwapBeforeSwap.lean:200](../../formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean#L200) | [`AsyncSwapBeforeSwap.t.sol`](AsyncSwapBeforeSwap.t.sol) `testFuzz_beforeSwap_ok_returns` | no |
| `beforeSwap_succeeds_iff` | [AsyncSwapBeforeSwap.lean:213](../../formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean#L213) | [`AsyncSwapBeforeSwap.t.sol`](AsyncSwapBeforeSwap.t.sol) `testFuzz_beforeSwap_succeeds_iff` | no |
| `beforeSwap_frame` | [AsyncSwapBeforeSwap.lean:227](../../formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean#L227) | [`SpecCore.t.sol`](SpecCore.t.sol) `test_note_beforeSwap_frame_hcreate_false` | no |
| `beforeSwap_ok_delta` | [AsyncSwapBeforeSwap.lean:288](../../formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean#L288) | [`AsyncSwapBeforeSwap.t.sol`](AsyncSwapBeforeSwap.t.sol) `testFuzz_beforeSwap_ok_delta` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `amountTaken_eq` | [AsyncSwapBeforeSwap.lean:247](../../formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean#L247) | model-only helper (Lean arithmetic lemma about `amountTaken`/`toUnsigned`; observable content tested via `beforeSwap_run_ok` claims-balance check) |
| `delta_eq` | [AsyncSwapBeforeSwap.lean:260](../../formal/Refinement/Swarm/AsyncSwapBeforeSwap.lean#L260) | model-only helper (Lean bit-arithmetic lemma about `delta`/`wrapI`/`yshl`; observable content tested via `beforeSwap_ok_delta`) |

### `Refinement/Swarm/AsyncSwapBestOrder.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `bestOrder_run` | [AsyncSwapBestOrder.lean:155](../../formal/Refinement/Swarm/AsyncSwapBestOrder.lean#L155) | [`AsyncSwapBestOrder.t.sol`](AsyncSwapBestOrder.t.sol) `testFuzz_bestOrder_run, AsyncSwapBestOrder.t.sol: testFuzz_bestOrder_run_synthetic` | no |
| `bestOrder_empty` | [AsyncSwapBestOrder.lean:202](../../formal/Refinement/Swarm/AsyncSwapBestOrder.lean#L202) | [`AsyncSwapBestOrder.t.sol`](AsyncSwapBestOrder.t.sol) `testFuzz_bestOrder_empty` | no |
| `bestOrder_loopBound` | [AsyncSwapBestOrder.lean:208](../../formal/Refinement/Swarm/AsyncSwapBestOrder.lean#L208) | [`AsyncSwapBestOrder.t.sol`](AsyncSwapBestOrder.t.sol) `testFuzz_bestOrder_loopBound` | no |
| `bestOrder_ok` | [AsyncSwapBestOrder.lean:218](../../formal/Refinement/Swarm/AsyncSwapBestOrder.lean#L218) | [`AsyncSwapBestOrder.t.sol`](AsyncSwapBestOrder.t.sol) `testFuzz_bestOrder_ok` | no |
| `bestOrder_readOnly` | [AsyncSwapBestOrder.lean:251](../../formal/Refinement/Swarm/AsyncSwapBestOrder.lean#L251) | [`AsyncSwapBestOrder.t.sol`](AsyncSwapBestOrder.t.sol) `testFuzz_bestOrder_readOnly` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `firstLeaf_spec` | [AsyncSwapBestOrder.lean:57](../../formal/Refinement/Swarm/AsyncSwapBestOrder.lean#L57) | model-only helper (Lean lemma about `firstLeaf`/`walkN`) |
| `body_run` | [AsyncSwapBestOrder.lean:82](../../formal/Refinement/Swarm/AsyncSwapBestOrder.lean#L82) | model-only helper (Lean lemma about one loop-body step of `RadixPriceTree.best`) |
| `loop_run` | [AsyncSwapBestOrder.lean:101](../../formal/Refinement/Swarm/AsyncSwapBestOrder.lean#L101) | model-only helper (Lean lemma about the `forIn` loop of `RadixPriceTree.best`) |
| `best_run` | [AsyncSwapBestOrder.lean:134](../../formal/Refinement/Swarm/AsyncSwapBestOrder.lean#L134) | model-only helper (internal `RadixPriceTree.best` with an abstract read-only accessor); observable content is checked through bestOrder_run/_empty/_loopBound |

### `Refinement/Swarm/AsyncSwapBitSet.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `bitSet_spec` | [AsyncSwapBitSet.lean:20](../../formal/Refinement/Swarm/AsyncSwapBitSet.lean#L20) | [`AsyncSwapBitSet.t.sol`](AsyncSwapBitSet.t.sol) `testFuzz_bitSet_spec` | yes |
| `bitSet_testBit` | [AsyncSwapBitSet.lean:25](../../formal/Refinement/Swarm/AsyncSwapBitSet.lean#L25) | [`AsyncSwapBitSet.t.sol`](AsyncSwapBitSet.t.sol) `testFuzz_bitSet_testBit` | yes |
| `bitSet_noRevert` | [AsyncSwapBitSet.lean:41](../../formal/Refinement/Swarm/AsyncSwapBitSet.lean#L41) | [`AsyncSwapBitSet.t.sol`](AsyncSwapBitSet.t.sol) `testFuzz_bitSet_noRevert` | yes |

### `Refinement/Swarm/AsyncSwapBubbleUpAndRevertWith.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `bubbleUpAndRevertWith_reverts` | [AsyncSwapBubbleUpAndRevertWith.lean:22](../../formal/Refinement/Swarm/AsyncSwapBubbleUpAndRevertWith.lean#L22) | [`AsyncSwapBubbleUpAndRevertWith.t.sol`](AsyncSwapBubbleUpAndRevertWith.t.sol) `testFuzz_bubbleUpAndRevertWith_reverts` | yes |
| `bubbleUpAndRevertWith_reverts'` | [AsyncSwapBubbleUpAndRevertWith.lean:27](../../formal/Refinement/Swarm/AsyncSwapBubbleUpAndRevertWith.lean#L27) | [`AsyncSwapBubbleUpAndRevertWith.t.sol`](AsyncSwapBubbleUpAndRevertWith.t.sol) `testFuzz_bubbleUpAndRevertWith_reverts_` | yes |
| `bubbleUpAndRevertWith_never_ok` | [AsyncSwapBubbleUpAndRevertWith.lean:32](../../formal/Refinement/Swarm/AsyncSwapBubbleUpAndRevertWith.lean#L32) | [`AsyncSwapBubbleUpAndRevertWith.t.sol`](AsyncSwapBubbleUpAndRevertWith.t.sol) `testFuzz_bubbleUpAndRevertWith_never_ok` | yes |
| `bubbleUpAndRevertWith_indep` | [AsyncSwapBubbleUpAndRevertWith.lean:38](../../formal/Refinement/Swarm/AsyncSwapBubbleUpAndRevertWith.lean#L38) | [`AsyncSwapBubbleUpAndRevertWith.t.sol`](AsyncSwapBubbleUpAndRevertWith.t.sol) `testFuzz_bubbleUpAndRevertWith_indep` | yes |

### `Refinement/Swarm/AsyncSwapCalculateHookFee.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `calculateHookFee_run` | [AsyncSwapCalculateHookFee.lean:20](../../formal/Refinement/Swarm/AsyncSwapCalculateHookFee.lean#L20) | [`AsyncSwapCalculateHookFee.t.sol`](AsyncSwapCalculateHookFee.t.sol) `testFuzz_calculateHookFee_run` | with edits |
| `calculateHookFee_never_reverts` | [AsyncSwapCalculateHookFee.lean:24](../../formal/Refinement/Swarm/AsyncSwapCalculateHookFee.lean#L24) | [`AsyncSwapCalculateHookFee.t.sol`](AsyncSwapCalculateHookFee.t.sol) `testFuzz_calculateHookFee_never_reverts` | with edits |
| `calculateHookFee_ok_iff` | [AsyncSwapCalculateHookFee.lean:30](../../formal/Refinement/Swarm/AsyncSwapCalculateHookFee.lean#L30) | [`AsyncSwapCalculateHookFee.t.sol`](AsyncSwapCalculateHookFee.t.sol) `testFuzz_calculateHookFee_ok_iff` | with edits |
| `calculateHookFee_const` | [AsyncSwapCalculateHookFee.lean:38](../../formal/Refinement/Swarm/AsyncSwapCalculateHookFee.lean#L38) | [`AsyncSwapCalculateHookFee.t.sol`](AsyncSwapCalculateHookFee.t.sol) `testFuzz_calculateHookFee_const` | with edits |

### `Refinement/Swarm/AsyncSwapCalculatePoolFee.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `calculatePoolFee_run` | [AsyncSwapCalculatePoolFee.lean:32](../../formal/Refinement/Swarm/AsyncSwapCalculatePoolFee.lean#L32) | [`AsyncSwapCalculatePoolFee.t.sol`](AsyncSwapCalculatePoolFee.t.sol) `testFuzz_calculatePoolFee_run` | with edits |
| `calculatePoolFee_ok` | [AsyncSwapCalculatePoolFee.lean:46](../../formal/Refinement/Swarm/AsyncSwapCalculatePoolFee.lean#L46) | [`AsyncSwapCalculatePoolFee.t.sol`](AsyncSwapCalculatePoolFee.t.sol) `testFuzz_calculatePoolFee_ok, AsyncSwapCalculatePoolFee.t.sol: test_calculatePoolFee_ok_edges` | with edits |
| `calculatePoolFee_le` | [AsyncSwapCalculatePoolFee.lean:53](../../formal/Refinement/Swarm/AsyncSwapCalculatePoolFee.lean#L53) | [`AsyncSwapCalculatePoolFee.t.sol`](AsyncSwapCalculatePoolFee.t.sol) `testFuzz_calculatePoolFee_le` | with edits |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `pf_eq` | [AsyncSwapCalculatePoolFee.lean:26](../../formal/Refinement/Swarm/AsyncSwapCalculatePoolFee.lean#L26) | model-only helper (Lean arithmetic on `pf`); its content is checked by calculatePoolFee_run/_ok |
| `pf_le` | [AsyncSwapCalculatePoolFee.lean:28](../../formal/Refinement/Swarm/AsyncSwapCalculatePoolFee.lean#L28) | model-only helper (Lean arithmetic on `pf`); its content is checked by calculatePoolFee_le |

### `Refinement/Swarm/AsyncSwapCallOptionalReturn.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `callOptionalReturn_call_reverts` | [AsyncSwapCallOptionalReturn.lean:23](../../formal/Refinement/Swarm/AsyncSwapCallOptionalReturn.lean#L23) | [`AsyncSwapCallOptionalReturn.t.sol`](AsyncSwapCallOptionalReturn.t.sol) `testFuzz_callOptionalReturn_call_reverts` | no |
| `callOptionalReturn_after` | [AsyncSwapCallOptionalReturn.lean:31](../../formal/Refinement/Swarm/AsyncSwapCallOptionalReturn.lean#L31) | [`AsyncSwapCallOptionalReturn.t.sol`](AsyncSwapCallOptionalReturn.t.sol) `testFuzz_callOptionalReturn_after` | no |
| `callOptionalReturn_ok` | [AsyncSwapCallOptionalReturn.lean:61](../../formal/Refinement/Swarm/AsyncSwapCallOptionalReturn.lean#L61) | [`AsyncSwapCallOptionalReturn.t.sol`](AsyncSwapCallOptionalReturn.t.sol) `testFuzz_callOptionalReturn_ok` | no |
| `callOptionalReturn_false_reverts` | [AsyncSwapCallOptionalReturn.lean:109](../../formal/Refinement/Swarm/AsyncSwapCallOptionalReturn.lean#L109) | [`AsyncSwapCallOptionalReturn.t.sol`](AsyncSwapCallOptionalReturn.t.sol) `testFuzz_callOptionalReturn_false_reverts` | no |

### `Refinement/Swarm/AsyncSwapCancelOrder.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `cancelOrder_run` | [AsyncSwapCancelOrder.lean:74](../../formal/Refinement/Swarm/AsyncSwapCancelOrder.lean#L74) | [`AsyncSwapCancelOrder.t.sol`](AsyncSwapCancelOrder.t.sol) `testFuzz_cancelOrder_run` | no |
| `cancelOrder_unauthorized` | [AsyncSwapCancelOrder.lean:101](../../formal/Refinement/Swarm/AsyncSwapCancelOrder.lean#L101) | [`AsyncSwapCancelOrder.t.sol`](AsyncSwapCancelOrder.t.sol) `testFuzz_cancelOrder_unauthorized` | no |
| `cancelOrder_notFound` | [AsyncSwapCancelOrder.lean:108](../../formal/Refinement/Swarm/AsyncSwapCancelOrder.lean#L108) | [`AsyncSwapCancelOrder.t.sol`](AsyncSwapCancelOrder.t.sol) `testFuzz_cancelOrder_notFound` | no |
| `cancelOrder_ok` | [AsyncSwapCancelOrder.lean:172](../../formal/Refinement/Swarm/AsyncSwapCancelOrder.lean#L172) | [`AsyncSwapCancelOrder.t.sol`](AsyncSwapCancelOrder.t.sol) `testFuzz_cancelOrder_ok, testFuzz_cancelOrder_ok_nativeInput, testFuzz_cancelOrder_ok_paidBid` | no |
| `cancelOrder_reentry_reverts` | [AsyncSwapCancelOrder.lean:215](../../formal/Refinement/Swarm/AsyncSwapCancelOrder.lean#L215) | [`AsyncSwapCancelOrder.t.sol`](AsyncSwapCancelOrder.t.sol) `testFuzz_cancelOrder_reentry_reverts` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `selfGet_run` | [AsyncSwapCancelOrder.lean:116](../../formal/Refinement/Swarm/AsyncSwapCancelOrder.lean#L116) | model-only helper (Lean accessor `selfGet` unfolds, `rfl`) |
| `selfSet_run` | [AsyncSwapCancelOrder.lean:119](../../formal/Refinement/Swarm/AsyncSwapCancelOrder.lean#L119) | model-only helper (Lean accessor `selfSet` unfolds, `rfl`) |
| `tail_ok` | [AsyncSwapCancelOrder.lean:130](../../formal/Refinement/Swarm/AsyncSwapCancelOrder.lean#L130) | model-only helper (step decomposition of the Lean def `tail`); its observable content is checked under cancelOrder_ok |
| `delWorld_order` | [AsyncSwapCancelOrder.lean:208](../../formal/Refinement/Swarm/AsyncSwapCancelOrder.lean#L208) | model-only helper (lemma about the Lean def `delWorld`); consequence tested in cancelOrder_reentry_reverts |

### `Refinement/Swarm/AsyncSwapConstructor.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `ctor_invalidNumeraire` | [AsyncSwapConstructor.lean:76](../../formal/Refinement/Swarm/AsyncSwapConstructor.lean#L76) | [`AsyncSwapConstructor.t.sol`](AsyncSwapConstructor.t.sol) `testFuzz_ctor_invalidNumeraire` | with edits |
| `ctor_zeroOwner` | [AsyncSwapConstructor.lean:82](../../formal/Refinement/Swarm/AsyncSwapConstructor.lean#L82) | [`AsyncSwapConstructor.t.sol`](AsyncSwapConstructor.t.sol) `testFuzz_ctor_zeroOwner` | with edits |
| `ctor_reverts_iff` | [AsyncSwapConstructor.lean:88](../../formal/Refinement/Swarm/AsyncSwapConstructor.lean#L88) | [`AsyncSwapConstructor.t.sol`](AsyncSwapConstructor.t.sol) `testFuzz_ctor_reverts_iff` | yes |
| `ctor_ok_iff` | [AsyncSwapConstructor.lean:95](../../formal/Refinement/Swarm/AsyncSwapConstructor.lean#L95) | [`AsyncSwapConstructor.t.sol`](AsyncSwapConstructor.t.sol) `testFuzz_ctor_ok_iff` | with edits |
| `ctor_fresh_state` | [AsyncSwapConstructor.lean:104](../../formal/Refinement/Swarm/AsyncSwapConstructor.lean#L104) | [`AsyncSwapConstructor.t.sol`](AsyncSwapConstructor.t.sol) `testFuzz_ctor_fresh_state` | yes |
| `ctor_deployed` | [AsyncSwapConstructor.lean:115](../../formal/Refinement/Swarm/AsyncSwapConstructor.lean#L115) | [`AsyncSwapConstructor.t.sol`](AsyncSwapConstructor.t.sol) `testFuzz_ctor_deployed` | yes |
| `owner_nonzero_transferOwnership` | [AsyncSwapConstructor.lean:126](../../formal/Refinement/Swarm/AsyncSwapConstructor.lean#L126) | [`AsyncSwapConstructor.t.sol`](AsyncSwapConstructor.t.sol) `testFuzz_owner_nonzero_transferOwnership` | yes |
| `owner_nonzero_acceptOwnership` | [AsyncSwapConstructor.lean:134](../../formal/Refinement/Swarm/AsyncSwapConstructor.lean#L134) | [`AsyncSwapConstructor.t.sol`](AsyncSwapConstructor.t.sol) `testFuzz_owner_nonzero_acceptOwnership` | yes |
| `domainSeparatorV4_eq_built` | [AsyncSwapConstructor.lean:146](../../formal/Refinement/Swarm/AsyncSwapConstructor.lean#L146) | [`AsyncSwapConstructor.t.sol`](AsyncSwapConstructor.t.sol) `testFuzz_domainSeparatorV4_eq_built` | with edits |
| `DOMAIN_SEPARATOR_eq_built` | [AsyncSwapConstructor.lean:159](../../formal/Refinement/Swarm/AsyncSwapConstructor.lean#L159) | [`AsyncSwapConstructor.t.sol`](AsyncSwapConstructor.t.sol) `testFuzz_DOMAIN_SEPARATOR_eq_built` | with edits |

### `Refinement/Swarm/AsyncSwapCrosses.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `crosses_run` | [AsyncSwapCrosses.lean:23](../../formal/Refinement/Swarm/AsyncSwapCrosses.lean#L23) | [`AsyncSwapCrosses.t.sol`](AsyncSwapCrosses.t.sol) `testFuzz_crosses_run` | no |
| `crosses_ne_any` | [AsyncSwapCrosses.lean:48](../../formal/Refinement/Swarm/AsyncSwapCrosses.lean#L48) | [`AsyncSwapCrosses.t.sol`](AsyncSwapCrosses.t.sol) `testFuzz_crosses_ne_any` | no |
| `crosses_reverts_div0` | [AsyncSwapCrosses.lean:57](../../formal/Refinement/Swarm/AsyncSwapCrosses.lean#L57) | [`AsyncSwapCrosses.t.sol`](AsyncSwapCrosses.t.sol) `testFuzz_crosses_reverts_div0, test_crosses_reverts_div0_counterexample` | no |
| `crosses_reverts_overflow` | [AsyncSwapCrosses.lean:66](../../formal/Refinement/Swarm/AsyncSwapCrosses.lean#L66) | [`AsyncSwapCrosses.t.sol`](AsyncSwapCrosses.t.sol) `testFuzz_crosses_reverts_overflow` | no |
| `crosses_frame` | [AsyncSwapCrosses.lean:78](../../formal/Refinement/Swarm/AsyncSwapCrosses.lean#L78) | [`AsyncSwapCrosses.t.sol`](AsyncSwapCrosses.t.sol) `testFuzz_crosses_frame` | no |

### `Refinement/Swarm/AsyncSwapDOMAIN_SEPARATOR.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `DOMAIN_SEPARATOR_spec` | [AsyncSwapDOMAIN_SEPARATOR.lean:29](../../formal/Refinement/Swarm/AsyncSwapDOMAIN_SEPARATOR.lean#L29) | [`AsyncSwapDOMAIN_SEPARATOR.t.sol`](AsyncSwapDOMAIN_SEPARATOR.t.sol) `testFuzz_DOMAIN_SEPARATOR_spec` | with edits |
| `DOMAIN_SEPARATOR_never_reverts` | [AsyncSwapDOMAIN_SEPARATOR.lean:40](../../formal/Refinement/Swarm/AsyncSwapDOMAIN_SEPARATOR.lean#L40) | [`AsyncSwapDOMAIN_SEPARATOR.t.sol`](AsyncSwapDOMAIN_SEPARATOR.t.sol) `testFuzz_DOMAIN_SEPARATOR_never_reverts` | with edits |
| `DOMAIN_SEPARATOR_preserves` | [AsyncSwapDOMAIN_SEPARATOR.lean:45](../../formal/Refinement/Swarm/AsyncSwapDOMAIN_SEPARATOR.lean#L45) | [`AsyncSwapDOMAIN_SEPARATOR.t.sol`](AsyncSwapDOMAIN_SEPARATOR.t.sol) `testFuzz_DOMAIN_SEPARATOR_preserves` | with edits |

### `Refinement/Swarm/AsyncSwapEip712Domain.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `EIP712Name_spec` | [AsyncSwapEip712Domain.lean:72](../../formal/Refinement/Swarm/AsyncSwapEip712Domain.lean#L72) | [`Eip712Domain.t.sol`](Eip712Domain.t.sol) `AsyncSwapEip712DomainFormalTest.testFuzz_EIP712Name_spec` | with edits |
| `EIP712Version_spec` | [AsyncSwapEip712Domain.lean:80](../../formal/Refinement/Swarm/AsyncSwapEip712Domain.lean#L80) | [`Eip712Domain.t.sol`](Eip712Domain.t.sol) `AsyncSwapEip712DomainFormalTest.testFuzz_EIP712Version_spec` | with edits |
| `eip712Domain_spec` | [AsyncSwapEip712Domain.lean:90](../../formal/Refinement/Swarm/AsyncSwapEip712Domain.lean#L90) | [`Eip712Domain.t.sol`](Eip712Domain.t.sol) `AsyncSwapEip712DomainFormalTest.testFuzz_eip712Domain_spec` | with edits |
| `eip712Domain_never_reverts` | [AsyncSwapEip712Domain.lean:98](../../formal/Refinement/Swarm/AsyncSwapEip712Domain.lean#L98) | [`Eip712Domain.t.sol`](Eip712Domain.t.sol) `AsyncSwapEip712DomainFormalTest.testFuzz_eip712Domain_never_reverts` | yes |
| `eip712Domain_ok` | [AsyncSwapEip712Domain.lean:106](../../formal/Refinement/Swarm/AsyncSwapEip712Domain.lean#L106) | [`Eip712Domain.t.sol`](Eip712Domain.t.sol) `AsyncSwapEip712DomainFormalTest.testFuzz_eip712Domain_ok` | with edits |
| `eip712Domain_short` | [AsyncSwapEip712Domain.lean:119](../../formal/Refinement/Swarm/AsyncSwapEip712Domain.lean#L119) | [`Eip712Domain.t.sol`](Eip712Domain.t.sol) `AsyncSwapEip712DomainFormalTest.testFuzz_eip712Domain_short` | yes |
| `eip712Domain_matches_DOMAIN_SEPARATOR` | [AsyncSwapEip712Domain.lean:132](../../formal/Refinement/Swarm/AsyncSwapEip712Domain.lean#L132) | [`Eip712Domain.t.sol`](Eip712Domain.t.sol) `AsyncSwapEip712DomainFormalTest.testFuzz_eip712Domain_matches_DOMAIN_SEPARATOR` | yes |

### `Refinement/Swarm/AsyncSwapExecuteOrder.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `pf_le` | [AsyncSwapExecuteOrder.lean:122](../../formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean#L122) | [`AsyncSwapExecuteOrder.t.sol`](AsyncSwapExecuteOrder.t.sol) `testFuzz_pf_le` | yes |
| `calculatePoolFee_run` | [AsyncSwapExecuteOrder.lean:124](../../formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean#L124) | [`AsyncSwapExecuteOrder.t.sol`](AsyncSwapExecuteOrder.t.sol) `testFuzz_calculatePoolFee_run` | yes |
| `fill_run` | [AsyncSwapExecuteOrder.lean:137](../../formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean#L137) | [`AsyncSwapExecuteOrder.t.sol`](AsyncSwapExecuteOrder.t.sol) `testFuzz_fill_run` | no |
| `afterNative_run` | [AsyncSwapExecuteOrder.lean:162](../../formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean#L162) | [`AsyncSwapExecuteOrder.t.sol`](AsyncSwapExecuteOrder.t.sol) `testFuzz_afterNative_run` | no |
| `executeOrder_run` | [AsyncSwapExecuteOrder.lean:188](../../formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean#L188) | [`AsyncSwapExecuteOrder.t.sol`](AsyncSwapExecuteOrder.t.sol) `testFuzz_executeOrder_run` | no |
| `executeOrder_decode` | [AsyncSwapExecuteOrder.lean:237](../../formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean#L237) | [`AsyncSwapExecuteOrder.t.sol`](AsyncSwapExecuteOrder.t.sol) `testFuzz_executeOrder_decode` | no |
| `executeOrder_unaccountedNative` | [AsyncSwapExecuteOrder.lean:245](../../formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean#L245) | [`AsyncSwapExecuteOrder.t.sol`](AsyncSwapExecuteOrder.t.sol) `testFuzz_executeOrder_unaccountedNative` | no |
| `executeOrder_nativeOverflow` | [AsyncSwapExecuteOrder.lean:256](../../formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean#L256) | [`AsyncSwapExecuteOrder.t.sol`](AsyncSwapExecuteOrder.t.sol) `testFuzz_executeOrder_nativeOverflow` | no |
| `executeOrder_unauthorized` | [AsyncSwapExecuteOrder.lean:275](../../formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean#L275) | [`AsyncSwapExecuteOrder.t.sol`](AsyncSwapExecuteOrder.t.sol) `testFuzz_executeOrder_unauthorized` | no |
| `executeOrder_notFound` | [AsyncSwapExecuteOrder.lean:290](../../formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean#L290) | [`AsyncSwapExecuteOrder.t.sol`](AsyncSwapExecuteOrder.t.sol) `testFuzz_executeOrder_notFound` | no |
| `executeOrder_ok` | [AsyncSwapExecuteOrder.lean:323](../../formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean#L323) | [`AsyncSwapExecuteOrder.t.sol`](AsyncSwapExecuteOrder.t.sol) `testFuzz_executeOrder_ok (ERC20 output), testFuzz_executeOrder_ok_native (native output; ledger decremented by exactly m + pf(m), checked by a second fill needing exactly the remainder vs. remainder + 1)` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `selfGet_run` | [AsyncSwapExecuteOrder.lean:73](../../formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean#L73) | model-only helper (Lean accessor unfolds, `rfl`) |
| `executeOrder_viewRevert` | [AsyncSwapExecuteOrder.lean:266](../../formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean#L266) | hypothesis on opaque ext call `view_AsyncSwap_asyncOrderInfo` reverting; the real `asyncOrderInfo` is a plain storage read that cannot revert (short of OOG), so it cannot be set up concretely |
| `tstoreWorld_frame` | [AsyncSwapExecuteOrder.lean:307](../../formal/Refinement/Swarm/AsyncSwapExecuteOrder.lean#L307) | model-only frame lemma about the Lean def `tstoreWorld`; the observable part (ledger decremented by exactly m + pf(m), orders untouched by that step) is checked in testFuzz_executeOrder_ok_native |

### `Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `fillOrderFromPoolLiquidity_notSelf` | [AsyncSwapFillOrderFromPoolLiquidity.lean:120](../../formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean#L120) | [`AsyncSwapFillOrderFromPoolLiquidity.t.sol`](AsyncSwapFillOrderFromPoolLiquidity.t.sol) `testFuzz_fillOrderFromPoolLiquidity_notSelf` | yes |
| `fillOrderFromPoolLiquidity_notFound` | [AsyncSwapFillOrderFromPoolLiquidity.lean:126](../../formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean#L126) | [`AsyncSwapFillOrderFromPoolLiquidity.t.sol`](AsyncSwapFillOrderFromPoolLiquidity.t.sol) `testFuzz_fillOrderFromPoolLiquidity_notFound` | no |
| `fillOrderFromPoolLiquidity_noLiquidity` | [AsyncSwapFillOrderFromPoolLiquidity.lean:133](../../formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean#L133) | [`AsyncSwapFillOrderFromPoolLiquidity.t.sol`](AsyncSwapFillOrderFromPoolLiquidity.t.sol) `testFuzz_fillOrderFromPoolLiquidity_noLiquidity` | no |
| `swapAgainstPool_ok` | [AsyncSwapFillOrderFromPoolLiquidity.lean:175](../../formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean#L175) | [`AsyncSwapFillOrderFromPoolLiquidity.t.sol`](AsyncSwapFillOrderFromPoolLiquidity.t.sol) `testFuzz_swapAgainstPool_ok` | no |
| `fillOrderFromPoolLiquidity_ok` | [AsyncSwapFillOrderFromPoolLiquidity.lean:261](../../formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean#L261) | [`AsyncSwapFillOrderFromPoolLiquidity.t.sol`](AsyncSwapFillOrderFromPoolLiquidity.t.sol) `testFuzz_fillOrderFromPoolLiquidity_ok` | no |
| `fillOrderFromPoolLiquidity_ok_full` | [AsyncSwapFillOrderFromPoolLiquidity.lean:293](../../formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean#L293) | [`AsyncSwapFillOrderFromPoolLiquidity.t.sol`](AsyncSwapFillOrderFromPoolLiquidity.t.sol) `testFuzz_fillOrderFromPoolLiquidity_ok_full` | no |
| `fillOrderFromPoolLiquidity_reentry_reverts` | [AsyncSwapFillOrderFromPoolLiquidity.lean:362](../../formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean#L362) | [`AsyncSwapFillOrderFromPoolLiquidity.t.sol`](AsyncSwapFillOrderFromPoolLiquidity.t.sol) `testFuzz_fillOrderFromPoolLiquidity_reentry_reverts` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `selfGet_run` | [AsyncSwapFillOrderFromPoolLiquidity.lean:50](../../formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean#L50) | model-only helper (`rfl`) |
| `selfSet_run` | [AsyncSwapFillOrderFromPoolLiquidity.lean:53](../../formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean#L53) | model-only helper (`rfl`) |
| `fillOrderFromPoolLiquidity_eq` | [AsyncSwapFillOrderFromPoolLiquidity.lean:76](../../formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean#L76) | `*_eq` unfolding into `AsyncMatching.fillFromPoolLiquidity`; its guard is tested as fillOrderFromPoolLiquidity_notSelf and the stored-maker payout in _ok_full |
| `fill_eq` | [AsyncSwapFillOrderFromPoolLiquidity.lean:93](../../formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean#L93) | `*_eq` unfolding into `_swapAgainstPool` + Lean `tail`; observable parts tested as _notFound / swapAgainstPool_ok / _ok_full |
| `toSigned256_small` | [AsyncSwapFillOrderFromPoolLiquidity.lean:147](../../formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean#L147) | model-only helper (Lean arithmetic lemma about `toSigned`) |
| `wrapI128_small` | [AsyncSwapFillOrderFromPoolLiquidity.lean:156](../../formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean#L156) | model-only helper (Lean arithmetic lemma about `wrapI`) |
| `ite_error_ok_eq_ok` | [AsyncSwapFillOrderFromPoolLiquidity.lean:164](../../formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean#L164) | model-only helper (Lean `ite`/`Except` lemma) |
| `tail_ok` | [AsyncSwapFillOrderFromPoolLiquidity.lean:224](../../formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean#L224) | model-only helper (step decomposition of the Lean def `tail`); content checked in _ok_full |
| `selfSet_get` | [AsyncSwapFillOrderFromPoolLiquidity.lean:337](../../formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean#L337) | model-only frame lemma (Lean setter footprint) |
| `bookSet_get` | [AsyncSwapFillOrderFromPoolLiquidity.lean:343](../../formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean#L343) | model-only frame lemma (Lean setter footprint) |
| `delWorld_get` | [AsyncSwapFillOrderFromPoolLiquidity.lean:349](../../formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean#L349) | model-only frame lemma (Lean def `delWorld`) |
| `delWorld_order` | [AsyncSwapFillOrderFromPoolLiquidity.lean:356](../../formal/Refinement/Swarm/AsyncSwapFillOrderFromPoolLiquidity.lean#L356) | model-only helper (Lean def `delWorld`); consequence tested in _reentry_reverts |

### `Refinement/Swarm/AsyncSwapFreeNode.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `freeNode_run` | [AsyncSwapFreeNode.lean:33](../../formal/Refinement/Swarm/AsyncSwapFreeNode.lean#L33) | [`AsyncSwapFreeNode.t.sol`](AsyncSwapFreeNode.t.sol) `testFuzz_freeNode_run` | no |
| `freeNode_run_wrapped` | [AsyncSwapFreeNode.lean:44](../../formal/Refinement/Swarm/AsyncSwapFreeNode.lean#L44) | [`AsyncSwapFreeNode.t.sol`](AsyncSwapFreeNode.t.sol) `testFuzz_freeNode_run_wrapped` | no |
| `freeNode_no_revert` | [AsyncSwapFreeNode.lean:55](../../formal/Refinement/Swarm/AsyncSwapFreeNode.lean#L55) | [`AsyncSwapFreeNode.t.sol`](AsyncSwapFreeNode.t.sol) `testFuzz_freeNode_no_revert` | no |
| `freeNode_footprint` | [AsyncSwapFreeNode.lean:64](../../formal/Refinement/Swarm/AsyncSwapFreeNode.lean#L64) | [`AsyncSwapFreeNode.t.sol`](AsyncSwapFreeNode.t.sol) `testFuzz_freeNode_footprint` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `freeNode_unfold` | [AsyncSwapFreeNode.lean:21](../../formal/Refinement/Swarm/AsyncSwapFreeNode.lean#L21) | model-only helper (unfolds the def into a Lean do-block over arbitrary accessors; its observable content is freeNode_run) |

### `Refinement/Swarm/AsyncSwapFunctionCall.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `functionCall_eq_withValue` | [AsyncSwapFunctionCall.lean:20](../../formal/Refinement/Swarm/AsyncSwapFunctionCall.lean#L20) | [`AsyncSwapFunctionCall.t.sol`](AsyncSwapFunctionCall.t.sol) `testFuzz_functionCall_eq_withValue` | no |
| `functionCall_run` | [AsyncSwapFunctionCall.lean:35](../../formal/Refinement/Swarm/AsyncSwapFunctionCall.lean#L35) | [`AsyncSwapFunctionCall.t.sol`](AsyncSwapFunctionCall.t.sol) `testFuzz_functionCall_run` | no |
| `functionCall_ok` | [AsyncSwapFunctionCall.lean:53](../../formal/Refinement/Swarm/AsyncSwapFunctionCall.lean#L53) | [`AsyncSwapFunctionCall.t.sol`](AsyncSwapFunctionCall.t.sol) `testFuzz_functionCall_ok` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `functionCall_call_reverts` | [AsyncSwapFunctionCall.lean:25](../../formal/Refinement/Swarm/AsyncSwapFunctionCall.lean#L25) | hypothesis on opaque `ext.lowCall` returning `.error` (as above) |

### `Refinement/Swarm/AsyncSwapFunctionCallWithValue.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `functionCallWithValue_reverts_insufficient` | [AsyncSwapFunctionCallWithValue.lean:20](../../formal/Refinement/Swarm/AsyncSwapFunctionCallWithValue.lean#L20) | [`AsyncSwapFunctionCallWithValue.t.sol`](AsyncSwapFunctionCallWithValue.t.sol) `testFuzz_functionCallWithValue_reverts_insufficient` | yes |
| `functionCallWithValue_run` | [AsyncSwapFunctionCallWithValue.lean:36](../../formal/Refinement/Swarm/AsyncSwapFunctionCallWithValue.lean#L36) | [`AsyncSwapFunctionCallWithValue.t.sol`](AsyncSwapFunctionCallWithValue.t.sol) `testFuzz_functionCallWithValue_run` | no |
| `functionCallWithValue_ok` | [AsyncSwapFunctionCallWithValue.lean:54](../../formal/Refinement/Swarm/AsyncSwapFunctionCallWithValue.lean#L54) | [`AsyncSwapFunctionCallWithValue.t.sol`](AsyncSwapFunctionCallWithValue.t.sol) `testFuzz_functionCallWithValue_ok` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `functionCallWithValue_call_reverts` | [AsyncSwapFunctionCallWithValue.lean:26](../../formal/Refinement/Swarm/AsyncSwapFunctionCallWithValue.lean#L26) | hypothesis on opaque `ext.lowCall` returning `.error` (as above) |

### `Refinement/Swarm/AsyncSwapGetHookPermissions.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `getHookPermissions_run` | [AsyncSwapGetHookPermissions.lean:29](../../formal/Refinement/Swarm/AsyncSwapGetHookPermissions.lean#L29) | [`AsyncSwapGetHookPermissions.t.sol`](AsyncSwapGetHookPermissions.t.sol) `testFuzz_getHookPermissions_run` | with edits |
| `getHookPermissions_never_reverts` | [AsyncSwapGetHookPermissions.lean:33](../../formal/Refinement/Swarm/AsyncSwapGetHookPermissions.lean#L33) | [`AsyncSwapGetHookPermissions.t.sol`](AsyncSwapGetHookPermissions.t.sol) `testFuzz_getHookPermissions_never_reverts` | with edits |
| `getHookPermissions_ok_iff` | [AsyncSwapGetHookPermissions.lean:39](../../formal/Refinement/Swarm/AsyncSwapGetHookPermissions.lean#L39) | [`AsyncSwapGetHookPermissions.t.sol`](AsyncSwapGetHookPermissions.t.sol) `test_getHookPermissions_ok_iff` | with edits |
| `getHookPermissions_fields` | [AsyncSwapGetHookPermissions.lean:47](../../formal/Refinement/Swarm/AsyncSwapGetHookPermissions.lean#L47) | [`AsyncSwapGetHookPermissions.t.sol`](AsyncSwapGetHookPermissions.t.sol) `test_getHookPermissions_fields` | with edits |

### `Refinement/Swarm/AsyncSwapHelpers.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `bubbleUpAndRevertWith_reverts` | [AsyncSwapHelpers.lean:26](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L26) | [`AsyncSwapHelpers.t.sol`](AsyncSwapHelpers.t.sol) `testFuzz_bubbleUpAndRevertWith_reverts` | yes |
| `address_revert_run` | [AsyncSwapHelpers.lean:33](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L33) | [`AsyncSwapHelpers.t.sol`](AsyncSwapHelpers.t.sol) `testFuzz_address_revert_run` | yes |
| `verifyCallResult_fail` | [AsyncSwapHelpers.lean:40](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L40) | [`AsyncSwapHelpers.t.sol`](AsyncSwapHelpers.t.sol) `testFuzz_verifyCallResult_fail` | yes |
| `verifyCallResult_ok` | [AsyncSwapHelpers.lean:48](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L48) | [`AsyncSwapHelpers.t.sol`](AsyncSwapHelpers.t.sol) `testFuzz_verifyCallResult_ok` | yes |
| `functionCallWithValue_insufficient` | [AsyncSwapHelpers.lean:56](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L56) | [`AsyncSwapHelpers.t.sol`](AsyncSwapHelpers.t.sol) `testFuzz_functionCallWithValue_insufficient` | yes |
| `functionCallWithValue_eq` | [AsyncSwapHelpers.lean:62](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L62) | [`AsyncSwapHelpers.t.sol`](AsyncSwapHelpers.t.sol) `testFuzz_functionCallWithValue_eq` | yes |
| `functionCall_eq` | [AsyncSwapHelpers.lean:69](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L69) | [`AsyncSwapHelpers.t.sol`](AsyncSwapHelpers.t.sol) `testFuzz_functionCall_eq` | yes |
| `callOptionalReturn_after` | [AsyncSwapHelpers.lean:81](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L81) | [`AsyncSwapHelpers.t.sol`](AsyncSwapHelpers.t.sol) `testFuzz_callOptionalReturn_after` | yes |
| `callOptionalReturn_call_reverts` | [AsyncSwapHelpers.lean:106](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L106) | [`AsyncSwapHelpers.t.sol`](AsyncSwapHelpers.t.sol) `testFuzz_callOptionalReturn_call_reverts` | yes |
| `safeTransferFrom_eq` | [AsyncSwapHelpers.lean:114](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L114) | [`AsyncSwapHelpers.t.sol`](AsyncSwapHelpers.t.sol) `testFuzz_safeTransferFrom_eq` | yes |
| `byteLength_run` | [AsyncSwapHelpers.lean:128](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L128) | [`AsyncSwapHelpers.t.sol`](AsyncSwapHelpers.t.sol) `testFuzz_byteLength_run` | yes |
| `byteLength_le` | [AsyncSwapHelpers.lean:134](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L134) | [`AsyncSwapHelpers.t.sol`](AsyncSwapHelpers.t.sol) `testFuzz_byteLength_le` | yes |
| `eip712Name_eq` | [AsyncSwapHelpers.lean:143](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L143) | [`AsyncSwapHelpers.t.sol`](AsyncSwapHelpers.t.sol) `testFuzz_eip712Name_eq` | no |
| `eip712Version_eq` | [AsyncSwapHelpers.lean:152](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L152) | [`AsyncSwapHelpers.t.sol`](AsyncSwapHelpers.t.sol) `testFuzz_eip712Version_eq` | no |
| `unsignedRoundsUp_run` | [AsyncSwapHelpers.lean:163](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L163) | [`AsyncSwapHelpers.t.sol`](AsyncSwapHelpers.t.sol) `testFuzz_unsignedRoundsUp_run` | yes |
| `mulDiv_rounding_eq` | [AsyncSwapHelpers.lean:169](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L169) | [`AsyncSwapHelpers.t.sol`](AsyncSwapHelpers.t.sol) `testFuzz_mulDiv_rounding_eq` | yes |
| `priorityKey_run` | [AsyncSwapHelpers.lean:195](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L195) | [`AsyncSwapHelpers.t.sol`](AsyncSwapHelpers.t.sol) `testFuzz_priorityKey_run` | no |
| `priorityKey_lt_iff` | [AsyncSwapHelpers.lean:217](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L217) | [`AsyncSwapHelpers.t.sol`](AsyncSwapHelpers.t.sol) `testFuzz_priorityKey_lt_iff` | no |
| `crosses_ne` | [AsyncSwapHelpers.lean:242](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L242) | [`AsyncSwapHelpers.t.sol`](AsyncSwapHelpers.t.sol) `testFuzz_crosses_ne` | no |
| `crosses_eq` | [AsyncSwapHelpers.lean:250](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L250) | [`AsyncSwapHelpers.t.sol`](AsyncSwapHelpers.t.sol) `testFuzz_crosses_eq` | no |
| `priceKey_eq` | [AsyncSwapHelpers.lean:279](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L279) | [`AsyncSwapHelpers.t.sol`](AsyncSwapHelpers.t.sol) `testFuzz_priceKey_eq, test_priceKey_eq_clampHigh, test_priceKey_eq_clampLow` | no |
| `priceKey_range` | [AsyncSwapHelpers.lean:296](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L296) | [`AsyncSwapHelpers.t.sol`](AsyncSwapHelpers.t.sol) `testFuzz_priceKey_range` | no |
| `bitSet_run` | [AsyncSwapHelpers.lean:312](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L312) | [`AsyncSwapHelpers.t.sol`](AsyncSwapHelpers.t.sol) `testFuzz_bitSet_run` | yes |
| `freeNode_run` | [AsyncSwapHelpers.lean:324](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L324) | [`AsyncSwapHelpers.t.sol`](AsyncSwapHelpers.t.sol) `testFuzz_freeNode_run` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `mulDivFloor_frame` | [AsyncSwapHelpers.lean:186](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L186) | model-only helper: a frame lemma about the shared Lean `mulDivFloor` def. `Math.mulDiv` is `pure`, so the compiler already rules out writes, and its value semantics are tested by `mulDiv_rounding_eq`. |
| `priorityKey_value` | [AsyncSwapHelpers.lean:205](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L205) | model-only helper: a Lean arithmetic identity (`shlw 128 f 64 |
| `priceKey_tail` | [AsyncSwapHelpers.lean:263](../../formal/Refinement/Swarm/AsyncSwapHelpers.lean#L263) | model-only helper (the clamp after `_priceKey`'s `mulDiv`); covered by the `priceKey_*` tests |

### `Refinement/Swarm/AsyncSwapInsert.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `newNode_ok` | [AsyncSwapInsert.lean:67](../../formal/Refinement/Swarm/AsyncSwapInsert.lean#L67) | [`AsyncSwapInsert.t.sol`](AsyncSwapInsert.t.sol) `testFuzz_newNode_ok` | no |
| `newNode_err` | [AsyncSwapInsert.lean:76](../../formal/Refinement/Swarm/AsyncSwapInsert.lean#L76) | [`AsyncSwapInsert.t.sol`](AsyncSwapInsert.t.sol) `testFuzz_newNode_err` | yes |
| `insert_present` | [AsyncSwapInsert.lean:92](../../formal/Refinement/Swarm/AsyncSwapInsert.lean#L92) | [`AsyncSwapInsert.t.sol`](AsyncSwapInsert.t.sol) `testFuzz_insert_present` | no |
| `insert_overflow` | [AsyncSwapInsert.lean:100](../../formal/Refinement/Swarm/AsyncSwapInsert.lean#L100) | [`AsyncSwapInsert.t.sol`](AsyncSwapInsert.t.sol) `testFuzz_insert_overflow` | yes |
| `insert_empty` | [AsyncSwapInsert.lean:114](../../formal/Refinement/Swarm/AsyncSwapInsert.lean#L114) | [`AsyncSwapInsert.t.sol`](AsyncSwapInsert.t.sol) `testFuzz_insert_empty` | no |
| `insert_reverts` | [AsyncSwapInsert.lean:139](../../formal/Refinement/Swarm/AsyncSwapInsert.lean#L139) | [`AsyncSwapInsert.t.sol`](AsyncSwapInsert.t.sol) `testFuzz_insert_reverts` | no |
| `insert_footprint` | [AsyncSwapInsert.lean:204](../../formal/Refinement/Swarm/AsyncSwapInsert.lean#L204) | [`AsyncSwapInsert.t.sol`](AsyncSwapInsert.t.sol) `testFuzz_insert_footprint` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `forIn_list_pure` | [AsyncSwapInsert.lean:32](../../formal/Refinement/Swarm/AsyncSwapInsert.lean#L32) | model-only helper (Lean `forIn` lemma) |
| `forIn_range_pure` | [AsyncSwapInsert.lean:47](../../formal/Refinement/Swarm/AsyncSwapInsert.lean#L47) | model-only helper (Lean `forIn` lemma) |
| `forIn_ok_state` | [AsyncSwapInsert.lean:53](../../formal/Refinement/Swarm/AsyncSwapInsert.lean#L53) | model-only helper (Lean `forIn` lemma) |
| `forIn_no_error` | [AsyncSwapInsert.lean:59](../../formal/Refinement/Swarm/AsyncSwapInsert.lean#L59) | model-only helper (Lean `forIn` lemma) |

### `Refinement/Swarm/AsyncSwapInvalidateNonce.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `invalidateNonce_run` | [AsyncSwapInvalidateNonce.lean:20](../../formal/Refinement/Swarm/AsyncSwapInvalidateNonce.lean#L20) | [`AsyncSwapInvalidateNonce.t.sol`](AsyncSwapInvalidateNonce.t.sol) `testFuzz_invalidateNonce_run` | with edits |
| `invalidateNonce_reverts_iff` | [AsyncSwapInvalidateNonce.lean:31](../../formal/Refinement/Swarm/AsyncSwapInvalidateNonce.lean#L31) | [`AsyncSwapInvalidateNonce.t.sol`](AsyncSwapInvalidateNonce.t.sol) `testFuzz_invalidateNonce_reverts_iff` | with edits |
| `invalidateNonce_used` | [AsyncSwapInvalidateNonce.lean:38](../../formal/Refinement/Swarm/AsyncSwapInvalidateNonce.lean#L38) | [`AsyncSwapInvalidateNonce.t.sol`](AsyncSwapInvalidateNonce.t.sol) `testFuzz_invalidateNonce_used` | with edits |
| `invalidateNonce_ok_iff` | [AsyncSwapInvalidateNonce.lean:44](../../formal/Refinement/Swarm/AsyncSwapInvalidateNonce.lean#L44) | [`AsyncSwapInvalidateNonce.t.sol`](AsyncSwapInvalidateNonce.t.sol) `testFuzz_invalidateNonce_ok_iff` | with edits |
| `invalidateNonce_ok_state` | [AsyncSwapInvalidateNonce.lean:52](../../formal/Refinement/Swarm/AsyncSwapInvalidateNonce.lean#L52) | [`AsyncSwapInvalidateNonce.t.sol`](AsyncSwapInvalidateNonce.t.sol) `testFuzz_invalidateNonce_ok_state` | with edits |
| `invalidateNonce_other_maker` | [AsyncSwapInvalidateNonce.lean:75](../../formal/Refinement/Swarm/AsyncSwapInvalidateNonce.lean#L75) | [`AsyncSwapInvalidateNonce.t.sol`](AsyncSwapInvalidateNonce.t.sol) `testFuzz_invalidateNonce_other_maker` | with edits |

### `Refinement/Swarm/AsyncSwapLibHelpers.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `revert_run` | [AsyncSwapLibHelpers.lean:20](../../formal/Refinement/Swarm/AsyncSwapLibHelpers.lean#L20) | [`AsyncSwapLibHelpers.t.sol`](AsyncSwapLibHelpers.t.sol) `testFuzz_revert_run` | yes |
| `revert_never_ok` | [AsyncSwapLibHelpers.lean:26](../../formal/Refinement/Swarm/AsyncSwapLibHelpers.lean#L26) | [`AsyncSwapLibHelpers.t.sol`](AsyncSwapLibHelpers.t.sol) `testFuzz_revert_never_ok` | yes |
| `verify_run` | [AsyncSwapLibHelpers.lean:30](../../formal/Refinement/Swarm/AsyncSwapLibHelpers.lean#L30) | [`AsyncSwapLibHelpers.t.sol`](AsyncSwapLibHelpers.t.sol) `testFuzz_verify_run` | yes |
| `verify_ok_iff` | [AsyncSwapLibHelpers.lean:40](../../formal/Refinement/Swarm/AsyncSwapLibHelpers.lean#L40) | [`AsyncSwapLibHelpers.t.sol`](AsyncSwapLibHelpers.t.sol) `testFuzz_verify_ok_iff` | yes |
| `functionCallWithValue_run` | [AsyncSwapLibHelpers.lean:47](../../formal/Refinement/Swarm/AsyncSwapLibHelpers.lean#L47) | [`AsyncSwapLibHelpers.t.sol`](AsyncSwapLibHelpers.t.sol) `testFuzz_functionCallWithValue_run` | yes |
| `functionCall_run` | [AsyncSwapLibHelpers.lean:61](../../formal/Refinement/Swarm/AsyncSwapLibHelpers.lean#L61) | [`AsyncSwapLibHelpers.t.sol`](AsyncSwapLibHelpers.t.sol) `testFuzz_functionCall_run` | yes |
| `callOptionalReturn_run` | [AsyncSwapLibHelpers.lean:78](../../formal/Refinement/Swarm/AsyncSwapLibHelpers.lean#L78) | [`AsyncSwapLibHelpers.t.sol`](AsyncSwapLibHelpers.t.sol) `testFuzz_callOptionalReturn_run` | yes |
| `safeTransferFrom_run` | [AsyncSwapLibHelpers.lean:99](../../formal/Refinement/Swarm/AsyncSwapLibHelpers.lean#L99) | [`AsyncSwapLibHelpers.t.sol`](AsyncSwapLibHelpers.t.sol) `testFuzz_safeTransferFrom_run` | yes |
| `safeTransferFrom_ok` | [AsyncSwapLibHelpers.lean:107](../../formal/Refinement/Swarm/AsyncSwapLibHelpers.lean#L107) | [`AsyncSwapLibHelpers.t.sol`](AsyncSwapLibHelpers.t.sol) `testFuzz_safeTransferFrom_ok` | yes |
| `bubbleUpAndRevertWith_run` | [AsyncSwapLibHelpers.lean:125](../../formal/Refinement/Swarm/AsyncSwapLibHelpers.lean#L125) | [`AsyncSwapLibHelpers.t.sol`](AsyncSwapLibHelpers.t.sol) `testFuzz_bubbleUpAndRevertWith_run` | yes |
| `byteLength_run` | [AsyncSwapLibHelpers.lean:129](../../formal/Refinement/Swarm/AsyncSwapLibHelpers.lean#L129) | [`AsyncSwapLibHelpers.t.sol`](AsyncSwapLibHelpers.t.sol) `testFuzz_byteLength_run` | yes |
| `byteLength_ok` | [AsyncSwapLibHelpers.lean:135](../../formal/Refinement/Swarm/AsyncSwapLibHelpers.lean#L135) | [`AsyncSwapLibHelpers.t.sol`](AsyncSwapLibHelpers.t.sol) `testFuzz_byteLength_ok` | yes |
| `EIP712Name_run` | [AsyncSwapLibHelpers.lean:148](../../formal/Refinement/Swarm/AsyncSwapLibHelpers.lean#L148) | [`AsyncSwapLibHelpers.t.sol`](AsyncSwapLibHelpers.t.sol) `testFuzz_EIP712Name_run` | no |
| `EIP712Version_run` | [AsyncSwapLibHelpers.lean:156](../../formal/Refinement/Swarm/AsyncSwapLibHelpers.lean#L156) | [`AsyncSwapLibHelpers.t.sol`](AsyncSwapLibHelpers.t.sol) `testFuzz_EIP712Version_run` | no |
| `priorityKey_run` | [AsyncSwapLibHelpers.lean:171](../../formal/Refinement/Swarm/AsyncSwapLibHelpers.lean#L171) | [`AsyncSwapLibHelpers.t.sol`](AsyncSwapLibHelpers.t.sol) `testFuzz_priorityKey_run` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `priorityKey_reverts` | [AsyncSwapLibHelpers.lean:166](../../formal/Refinement/Swarm/AsyncSwapLibHelpers.lean#L166) | unreachable hypothesis: `seq > 2^64 - 1` can't happen because `_priorityKey(uint64, uint64)` takes a `uint64` sequence. `++book.nextSequence` would already panic in `addOrder`, and any wider value is rejected by the ABI. |

### `Refinement/Swarm/AsyncSwapMatchAmounts.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `floor_run` | [AsyncSwapMatchAmounts.lean:49](../../formal/Refinement/Swarm/AsyncSwapMatchAmounts.lean#L49) | [`AsyncSwapMatchAmounts.t.sol`](AsyncSwapMatchAmounts.t.sol) `testFuzz_floor_run` | with edits |
| `ceil_run` | [AsyncSwapMatchAmounts.lean:62](../../formal/Refinement/Swarm/AsyncSwapMatchAmounts.lean#L62) | [`AsyncSwapMatchAmounts.t.sol`](AsyncSwapMatchAmounts.t.sol) `testFuzz_ceil_run` | with edits |
| `ok_restingBuy` | [AsyncSwapMatchAmounts.lean:127](../../formal/Refinement/Swarm/AsyncSwapMatchAmounts.lean#L127) | [`AsyncSwapMatchAmounts.t.sol`](AsyncSwapMatchAmounts.t.sol) `testFuzz_ok_restingBuy` | no |
| `ok_restingSell` | [AsyncSwapMatchAmounts.lean:145](../../formal/Refinement/Swarm/AsyncSwapMatchAmounts.lean#L145) | [`AsyncSwapMatchAmounts.t.sol`](AsyncSwapMatchAmounts.t.sol) `testFuzz_ok_restingSell` | no |
| `matchAmounts_ok` | [AsyncSwapMatchAmounts.lean:167](../../formal/Refinement/Swarm/AsyncSwapMatchAmounts.lean#L167) | [`AsyncSwapMatchAmounts.t.sol`](AsyncSwapMatchAmounts.t.sol) `testFuzz_matchAmounts_ok` | no |
| `matchAmounts_ok_sound` | [AsyncSwapMatchAmounts.lean:186](../../formal/Refinement/Swarm/AsyncSwapMatchAmounts.lean#L186) | [`AsyncSwapMatchAmounts.t.sol`](AsyncSwapMatchAmounts.t.sol) `testFuzz_matchAmounts_ok_sound` | no |
| `matchAmounts_reverts_restingBuy` | [AsyncSwapMatchAmounts.lean:206](../../formal/Refinement/Swarm/AsyncSwapMatchAmounts.lean#L206) | [`AsyncSwapMatchAmounts.t.sol`](AsyncSwapMatchAmounts.t.sol) `testFuzz_matchAmounts_reverts_restingBuy` | no |
| `matchAmounts_reverts_restingSell` | [AsyncSwapMatchAmounts.lean:217](../../formal/Refinement/Swarm/AsyncSwapMatchAmounts.lean#L217) | [`AsyncSwapMatchAmounts.t.sol`](AsyncSwapMatchAmounts.t.sol) `testFuzz_matchAmounts_reverts_restingSell` | no |
| `noerr_restingBuy` | [AsyncSwapMatchAmounts.lean:226](../../formal/Refinement/Swarm/AsyncSwapMatchAmounts.lean#L226) | [`AsyncSwapMatchAmounts.t.sol`](AsyncSwapMatchAmounts.t.sol) `testFuzz_noerr_restingBuy` | no |
| `noerr_restingSell` | [AsyncSwapMatchAmounts.lean:263](../../formal/Refinement/Swarm/AsyncSwapMatchAmounts.lean#L263) | [`AsyncSwapMatchAmounts.t.sol`](AsyncSwapMatchAmounts.t.sol) `testFuzz_noerr_restingSell` | no |
| `matchAmounts_succeeds` | [AsyncSwapMatchAmounts.lean:303](../../formal/Refinement/Swarm/AsyncSwapMatchAmounts.lean#L303) | [`AsyncSwapMatchAmounts.t.sol`](AsyncSwapMatchAmounts.t.sol) `testFuzz_matchAmounts_succeeds` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `floor_cases` | [AsyncSwapMatchAmounts.lean:31](../../formal/Refinement/Swarm/AsyncSwapMatchAmounts.lean#L31) | model-only arithmetic lemma (for d > 0, `d ≤ x*y/2^256` iff the quotient overflows) |
| `default_asset` | [AsyncSwapMatchAmounts.lean:73](../../formal/Refinement/Swarm/AsyncSwapMatchAmounts.lean#L73) | model-only helper (`default : MatchAmounts` field is 0, `rfl`) |
| `default_quote` | [AsyncSwapMatchAmounts.lean:74](../../formal/Refinement/Swarm/AsyncSwapMatchAmounts.lean#L74) | model-only helper (`default : MatchAmounts` field is 0, `rfl`) |
| `aux_le` | [AsyncSwapMatchAmounts.lean:77](../../formal/Refinement/Swarm/AsyncSwapMatchAmounts.lean#L77) | model-only helper (Nat arithmetic lemma for `omega`) |
| `aux_pos` | [AsyncSwapMatchAmounts.lean:86](../../formal/Refinement/Swarm/AsyncSwapMatchAmounts.lean#L86) | model-only helper (Nat arithmetic lemma) |
| `aux_mul` | [AsyncSwapMatchAmounts.lean:100](../../formal/Refinement/Swarm/AsyncSwapMatchAmounts.lean#L100) | model-only helper (Nat arithmetic lemma) |
| `aux_cancel` | [AsyncSwapMatchAmounts.lean:107](../../formal/Refinement/Swarm/AsyncSwapMatchAmounts.lean#L107) | model-only helper (Nat arithmetic lemma) |
| `aux_prod` | [AsyncSwapMatchAmounts.lean:110](../../formal/Refinement/Swarm/AsyncSwapMatchAmounts.lean#L110) | model-only helper (Nat arithmetic lemma: x,y < 2^128 ⇒ x·y < 2^256) |
| `spec_pos` | [AsyncSwapMatchAmounts.lean:177](../../formal/Refinement/Swarm/AsyncSwapMatchAmounts.lean#L177) | spec-only lemma (about `AsyncSwap.matchAmounts`, no contract call) |

### `Refinement/Swarm/AsyncSwapMatchBook.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `asyncMatching_matchBook_ok` | [AsyncSwapMatchBook.lean:96](../../formal/Refinement/Swarm/AsyncSwapMatchBook.lean#L96) | [`AsyncSwapMatchBook.t.sol`](AsyncSwapMatchBook.t.sol) `testFuzz_asyncMatching_matchBook_ok` | no |
| `matchBook_invalidBound` | [AsyncSwapMatchBook.lean:161](../../formal/Refinement/Swarm/AsyncSwapMatchBook.lean#L161) | [`AsyncSwapMatchBook.t.sol`](AsyncSwapMatchBook.t.sol) `testFuzz_matchBook_invalidBound` | yes |
| `matchBook_ok` | [AsyncSwapMatchBook.lean:173](../../formal/Refinement/Swarm/AsyncSwapMatchBook.lean#L173) | [`AsyncSwapMatchBook.t.sol`](AsyncSwapMatchBook.t.sol) `testFuzz_matchBook_ok` | no |
| `matchBook_bound_noOk` | [AsyncSwapMatchBook.lean:180](../../formal/Refinement/Swarm/AsyncSwapMatchBook.lean#L180) | [`AsyncSwapMatchBook.t.sol`](AsyncSwapMatchBook.t.sol) `testFuzz_matchBook_bound_noOk` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `returns_pure` | [AsyncSwapMatchBook.lean:39](../../formal/Refinement/Swarm/AsyncSwapMatchBook.lean#L39) | model-only helper (`Returns` calculus) |
| `returns_bind` | [AsyncSwapMatchBook.lean:44](../../formal/Refinement/Swarm/AsyncSwapMatchBook.lean#L44) | model-only helper (`Returns` calculus) |
| `returns_bind_any` | [AsyncSwapMatchBook.lean:53](../../formal/Refinement/Swarm/AsyncSwapMatchBook.lean#L53) | model-only helper (`Returns` calculus) |
| `returns_ite` | [AsyncSwapMatchBook.lean:57](../../formal/Refinement/Swarm/AsyncSwapMatchBook.lean#L57) | model-only helper (`Returns` calculus) |
| `returns_forIn_list` | [AsyncSwapMatchBook.lean:69](../../formal/Refinement/Swarm/AsyncSwapMatchBook.lean#L69) | model-only helper (loop-invariant rule) |
| `returns_forIn_range` | [AsyncSwapMatchBook.lean:85](../../formal/Refinement/Swarm/AsyncSwapMatchBook.lean#L85) | model-only helper (loop-invariant rule) |
| `matchBook_eq` | [AsyncSwapMatchBook.lean:152](../../formal/Refinement/Swarm/AsyncSwapMatchBook.lean#L152) | `*_eq` unfolding of `AsyncSwap.matchBook` into `AsyncMatching.matchBook` |
| `selfSet_run` | [AsyncSwapMatchBook.lean:189](../../formal/Refinement/Swarm/AsyncSwapMatchBook.lean#L189) | model-only helper (`rfl`) |
| `bookSet_run` | [AsyncSwapMatchBook.lean:193](../../formal/Refinement/Swarm/AsyncSwapMatchBook.lean#L193) | model-only helper (`rfl`) |
| `selfGet_run` | [AsyncSwapMatchBook.lean:198](../../formal/Refinement/Swarm/AsyncSwapMatchBook.lean#L198) | model-only helper (`rfl`) |
| `bookGet_run` | [AsyncSwapMatchBook.lean:201](../../formal/Refinement/Swarm/AsyncSwapMatchBook.lean#L201) | model-only helper (`rfl`) |
| `selfSet_frame` | [AsyncSwapMatchBook.lean:205](../../formal/Refinement/Swarm/AsyncSwapMatchBook.lean#L205) | model-only frame lemma (Lean setter footprint) |
| `bookSet_frame` | [AsyncSwapMatchBook.lean:221](../../formal/Refinement/Swarm/AsyncSwapMatchBook.lean#L221) | model-only frame lemma (Lean setter footprint) |

### `Refinement/Swarm/AsyncSwapMatchNewOrder.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `matchNewOrder_run` | [AsyncSwapMatchNewOrder.lean:74](../../formal/Refinement/Swarm/AsyncSwapMatchNewOrder.lean#L74) | [`AsyncSwapMatchNewOrder.t.sol`](AsyncSwapMatchNewOrder.t.sol) `testFuzz_matchNewOrder_run` | no |
| `matchNewOrder_unauthorized` | [AsyncSwapMatchNewOrder.lean:140](../../formal/Refinement/Swarm/AsyncSwapMatchNewOrder.lean#L140) | [`AsyncSwapMatchNewOrder.t.sol`](AsyncSwapMatchNewOrder.t.sol) `testFuzz_matchNewOrder_unauthorized` | no |
| `matchNewOrder_wrongOwner` | [AsyncSwapMatchNewOrder.lean:169](../../formal/Refinement/Swarm/AsyncSwapMatchNewOrder.lean#L169) | [`AsyncSwapMatchNewOrder.t.sol`](AsyncSwapMatchNewOrder.t.sol) `testFuzz_matchNewOrder_wrongOwner` | no |
| `matchIncoming_empty` | [AsyncSwapMatchNewOrder.lean:181](../../formal/Refinement/Swarm/AsyncSwapMatchNewOrder.lean#L181) | [`AsyncSwapMatchNewOrder.t.sol`](AsyncSwapMatchNewOrder.t.sol) `test_matchIncoming_empty` | no |
| `matchNewOrder_emptyOrder` | [AsyncSwapMatchNewOrder.lean:191](../../formal/Refinement/Swarm/AsyncSwapMatchNewOrder.lean#L191) | [`AsyncSwapMatchNewOrder.t.sol`](AsyncSwapMatchNewOrder.t.sol) `testFuzz_matchNewOrder_emptyOrder` | no |
| `matchNewOrder_reentry_reverts` | [AsyncSwapMatchNewOrder.lean:207](../../formal/Refinement/Swarm/AsyncSwapMatchNewOrder.lean#L207) | [`AsyncSwapMatchNewOrder.t.sol`](AsyncSwapMatchNewOrder.t.sol) `testFuzz_matchNewOrder_reentry_reverts` | no |
| `matchIncoming_le` | [AsyncSwapMatchNewOrder.lean:223](../../formal/Refinement/Swarm/AsyncSwapMatchNewOrder.lean#L223) | [`AsyncSwapMatchNewOrder.t.sol`](AsyncSwapMatchNewOrder.t.sol) `testFuzz_matchIncoming_le` | no |
| `matchNewOrder_ok` | [AsyncSwapMatchNewOrder.lean:252](../../formal/Refinement/Swarm/AsyncSwapMatchNewOrder.lean#L252) | [`AsyncSwapMatchNewOrder.t.sol`](AsyncSwapMatchNewOrder.t.sol) `testFuzz_matchNewOrder_ok` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `ite_pos'` | [AsyncSwapMatchNewOrder.lean:47](../../formal/Refinement/Swarm/AsyncSwapMatchNewOrder.lean#L47) | model-only helper (Lean `ite` lemma) |
| `ite_neg'` | [AsyncSwapMatchNewOrder.lean:49](../../formal/Refinement/Swarm/AsyncSwapMatchNewOrder.lean#L49) | model-only helper (Lean `ite` lemma) |
| `run_tryCatch'` | [AsyncSwapMatchNewOrder.lean:53](../../formal/Refinement/Swarm/AsyncSwapMatchNewOrder.lean#L53) | model-only helper (semantics of the model's `tryCatch`) |
| `clearWorld_frame` | [AsyncSwapMatchNewOrder.lean:147](../../formal/Refinement/Swarm/AsyncSwapMatchNewOrder.lean#L147) | model-only frame lemma about the Lean def `clearWorld` (transient slots are not readable from a test); its consequence (pending match consumed) is tested in matchNewOrder_reentry_reverts / _run |
| `returns_throw` | [AsyncSwapMatchNewOrder.lean:216](../../formal/Refinement/Swarm/AsyncSwapMatchNewOrder.lean#L216) | model-only helper (`Returns` calculus) |

### `Refinement/Swarm/AsyncSwapMatchPair.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `matchPair_skip` | [AsyncSwapMatchPair.lean:143](../../formal/Refinement/Swarm/AsyncSwapMatchPair.lean#L143) | [`AsyncSwapMatchPair.t.sol`](AsyncSwapMatchPair.t.sol) `testFuzz_matchPair_skip` | no |
| `matchPair_eq` | [AsyncSwapMatchPair.lean:164](../../formal/Refinement/Swarm/AsyncSwapMatchPair.lean#L164) | [`AsyncSwapMatchPair.t.sol`](AsyncSwapMatchPair.t.sol) `testFuzz_matchPair_eq` | no |
| `matchRun_ok` | [AsyncSwapMatchPair.lean:208](../../formal/Refinement/Swarm/AsyncSwapMatchPair.lean#L208) | [`AsyncSwapMatchPair.t.sol`](AsyncSwapMatchPair.t.sol) `testFuzz_matchRun_ok` | no |
| `matchPair_ok` | [AsyncSwapMatchPair.lean:221](../../formal/Refinement/Swarm/AsyncSwapMatchPair.lean#L221) | [`AsyncSwapMatchPair.t.sol`](AsyncSwapMatchPair.t.sol) `testFuzz_matchPair_ok` | no |
| `matchPair_true` | [AsyncSwapMatchPair.lean:273](../../formal/Refinement/Swarm/AsyncSwapMatchPair.lean#L273) | [`AsyncSwapMatchPair.t.sol`](AsyncSwapMatchPair.t.sol) `testFuzz_matchPair_true` | no |
| `matchPair_error` | [AsyncSwapMatchPair.lean:319](../../formal/Refinement/Swarm/AsyncSwapMatchPair.lean#L319) | [`AsyncSwapMatchPair.t.sol`](AsyncSwapMatchPair.t.sol) `testFuzz_matchPair_error` | no |
| `matchPair_reverts_restingZero` | [AsyncSwapMatchPair.lean:364](../../formal/Refinement/Swarm/AsyncSwapMatchPair.lean#L364) | [`AsyncSwapMatchPair.t.sol`](AsyncSwapMatchPair.t.sol) `testFuzz_matchPair_reverts_restingZero` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `matchAmounts_congr_true` | [AsyncSwapMatchPair.lean:44](../../formal/Refinement/Swarm/AsyncSwapMatchPair.lean#L44) | model-only helper (the generated `_matchAmounts` only reads its getter/setter accessors) |
| `matchAmounts_congr_false` | [AsyncSwapMatchPair.lean:62](../../formal/Refinement/Swarm/AsyncSwapMatchPair.lean#L62) | model-only helper (accessor congruence) |
| `matchAmounts_congr` | [AsyncSwapMatchPair.lean:81](../../formal/Refinement/Swarm/AsyncSwapMatchPair.lean#L81) | model-only helper (accessor congruence) |
| `params_conserve` | [AsyncSwapMatchPair.lean:118](../../formal/Refinement/Swarm/AsyncSwapMatchPair.lean#L118) | model-only helper (fields of the Lean defs `sellParams` / `buyParams`; what it says on the bytecode is covered by `matchPair_true` / `reduceMatchedOrders_eq`) |
| `params_of_orders` | [AsyncSwapMatchPair.lean:131](../../formal/Refinement/Swarm/AsyncSwapMatchPair.lean#L131) | model-only helper (the Lean `sellParams` / `buyParams` depend only on `orders`) |

### `Refinement/Swarm/AsyncSwapMostSignificantBit.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `mostSignificantBit_spec` | [AsyncSwapMostSignificantBit.lean:32](../../formal/Refinement/Swarm/AsyncSwapMostSignificantBit.lean#L32) | [`AsyncSwapMostSignificantBit.t.sol`](AsyncSwapMostSignificantBit.t.sol) `testFuzz_mostSignificantBit_spec` | yes |
| `mostSignificantBit_noRevert` | [AsyncSwapMostSignificantBit.lean:111](../../formal/Refinement/Swarm/AsyncSwapMostSignificantBit.lean#L111) | [`AsyncSwapMostSignificantBit.t.sol`](AsyncSwapMostSignificantBit.t.sol) `testFuzz_mostSignificantBit_noRevert` | yes |
| `mostSignificantBit_eq_log2` | [AsyncSwapMostSignificantBit.lean:117](../../formal/Refinement/Swarm/AsyncSwapMostSignificantBit.lean#L117) | [`AsyncSwapMostSignificantBit.t.sol`](AsyncSwapMostSignificantBit.t.sol) `testFuzz_mostSignificantBit_eq_log2` | yes |
| `mostSignificantBit_bounds` | [AsyncSwapMostSignificantBit.lean:123](../../formal/Refinement/Swarm/AsyncSwapMostSignificantBit.lean#L123) | [`AsyncSwapMostSignificantBit.t.sol`](AsyncSwapMostSignificantBit.t.sol) `testFuzz_mostSignificantBit_bounds` | yes |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `stage_snd_le` | [AsyncSwapMostSignificantBit.lean:42](../../formal/Refinement/Swarm/AsyncSwapMostSignificantBit.lean#L42) | model-only helper (Lean `stage`) |
| `msbSpec_lt` | [AsyncSwapMostSignificantBit.lean:45](../../formal/Refinement/Swarm/AsyncSwapMostSignificantBit.lean#L45) | model-only helper (Lean `msbSpec`; the observable bound is tested as mostSignificantBit_noRevert) |
| `stage_inv` | [AsyncSwapMostSignificantBit.lean:58](../../formal/Refinement/Swarm/AsyncSwapMostSignificantBit.lean#L58) | model-only helper (loop invariant of Lean `stage`) |
| `shiftRight_msbSpec` | [AsyncSwapMostSignificantBit.lean:75](../../formal/Refinement/Swarm/AsyncSwapMostSignificantBit.lean#L75) | model-only helper (Lean `msbSpec`) |
| `msbSpec_eq_log2` | [AsyncSwapMostSignificantBit.lean:96](../../formal/Refinement/Swarm/AsyncSwapMostSignificantBit.lean#L96) | model-only helper (Lean `msbSpec = Nat.log2`; used as the oracle in the _spec test) |

### `Refinement/Swarm/AsyncSwapMulDiv.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `mulDiv_ok` | [AsyncSwapMulDiv.lean:258](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L258) | [`AsyncSwapMulDiv.t.sol`](AsyncSwapMulDiv.t.sol) `testFuzz_mulDiv_ok` | yes |
| `mulDiv_overflow` | [AsyncSwapMulDiv.lean:306](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L306) | [`AsyncSwapMulDiv.t.sol`](AsyncSwapMulDiv.t.sol) `testFuzz_mulDiv_overflow` | yes |
| `mulDiv_zero` | [AsyncSwapMulDiv.lean:321](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L321) | [`AsyncSwapMulDiv.t.sol`](AsyncSwapMulDiv.t.sol) `testFuzz_mulDiv_zero` | yes |
| `mulDiv_spec` | [AsyncSwapMulDiv.lean:338](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L338) | [`AsyncSwapMulDiv.t.sol`](AsyncSwapMulDiv.t.sol) `testFuzz_mulDiv_spec` | yes |
| `mulDiv_eq_mulDivFloor` | [AsyncSwapMulDiv.lean:381](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L381) | [`AsyncSwapMulDiv.t.sol`](AsyncSwapMulDiv.t.sol) `testFuzz_mulDiv_eq_mulDivFloor` | yes |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `W_eq` | [AsyncSwapMulDiv.lean:31](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L31) | model-only helper (Lean constant `W = 2^256`) |
| `W_pos` | [AsyncSwapMulDiv.lean:32](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L32) | model-only helper (Lean arithmetic fact) |
| `ite_pos'` | [AsyncSwapMulDiv.lean:34](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L34) | model-only helper (Lean `if` rewriting) |
| `ite_neg'` | [AsyncSwapMulDiv.lean:36](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L36) | model-only helper (Lean `if` rewriting) |
| `mulw_eq` | [AsyncSwapMulDiv.lean:39](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L39) | model-only helper (Lean word op `mulw`) |
| `ysub_le` | [AsyncSwapMulDiv.lean:41](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L41) | model-only helper (Lean Yul op `ysub`) |
| `ysub_lt` | [AsyncSwapMulDiv.lean:46](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L46) | model-only helper (Lean Yul op `ysub`) |
| `ylt_eq` | [AsyncSwapMulDiv.lean:50](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L50) | model-only helper (Lean Yul op `ylt`) |
| `ygt_eq` | [AsyncSwapMulDiv.lean:53](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L53) | model-only helper (Lean Yul op `ygt`) |
| `ydiv_pos` | [AsyncSwapMulDiv.lean:56](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L56) | model-only helper (Lean Yul op `ydiv`) |
| `hi_word` | [AsyncSwapMulDiv.lean:61](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L61) | model-only helper (Nat lemma: mulmod trick gives the high word) |
| `sub_rem` | [AsyncSwapMulDiv.lean:95](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L95) | model-only helper (512-bit subtraction lemma) |
| `and_double` | [AsyncSwapMulDiv.lean:113](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L113) | model-only helper (Nat bitwise lemma) |
| `lowbit_odd` | [AsyncSwapMulDiv.lean:121](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L121) | model-only helper (Nat bitwise lemma) |
| `lowbit` | [AsyncSwapMulDiv.lean:139](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L139) | model-only helper (`d & -d` lemma) |
| `cast_modW` | [AsyncSwapMulDiv.lean:157](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L157) | model-only helper (ZMod cast lemma) |
| `cast_W` | [AsyncSwapMulDiv.lean:160](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L160) | model-only helper (ZMod cast lemma) |
| `fold_nstep` | [AsyncSwapMulDiv.lean:167](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L167) | model-only helper (folds a Lean expression into `nstep`) |
| `nstep_spec` | [AsyncSwapMulDiv.lean:170](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L170) | model-only helper (Newton step lemma) |
| `init_spec` | [AsyncSwapMulDiv.lean:199](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L199) | model-only helper (inverse seed lemma) |
| `inv_spec` | [AsyncSwapMulDiv.lean:208](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L208) | model-only helper (inverse mod 2^256 lemma) |
| `final` | [AsyncSwapMulDiv.lean:221](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L221) | model-only helper (final-stage arithmetic lemma; its content is tested by mulDiv_ok) |
| `mulDivFloor_run` | [AsyncSwapMulDiv.lean:353](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L353) | model-only helper (unfolds the prelude `mulDivFloor`); its content is checked by `testFuzz_floor_run` |
| `mulDiv_eq_mulDivFloor_any` | [AsyncSwapMulDiv.lean:388](../../formal/Refinement/Swarm/AsyncSwapMulDiv.lean#L388) | model-only (relates the generated `Math.mulDiv` to the prelude `mulDivFloor`); both sides are checked on the bytecode by `testFuzz_mulDiv_spec` and `testFuzz_floor_run` |

### `Refinement/Swarm/AsyncSwapNewNode.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `newNode_run_free` | [AsyncSwapNewNode.lean:23](../../formal/Refinement/Swarm/AsyncSwapNewNode.lean#L23) | [`AsyncSwapNewNode.t.sol`](AsyncSwapNewNode.t.sol) `testFuzz_newNode_run_free` | no |
| `newNode_run_fresh` | [AsyncSwapNewNode.lean:36](../../formal/Refinement/Swarm/AsyncSwapNewNode.lean#L36) | [`AsyncSwapNewNode.t.sol`](AsyncSwapNewNode.t.sol) `testFuzz_newNode_run_fresh` | yes |
| `newNode_reverts_iff` | [AsyncSwapNewNode.lean:46](../../formal/Refinement/Swarm/AsyncSwapNewNode.lean#L46) | [`AsyncSwapNewNode.t.sol`](AsyncSwapNewNode.t.sol) `testFuzz_newNode_reverts_iff` | no |
| `newNode_footprint` | [AsyncSwapNewNode.lean:60](../../formal/Refinement/Swarm/AsyncSwapNewNode.lean#L60) | [`AsyncSwapNewNode.t.sol`](AsyncSwapNewNode.t.sol) `testFuzz_newNode_footprint` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `newNode_run_wrapped_eq` | [AsyncSwapNewNode.lean:89](../../formal/Refinement/Swarm/AsyncSwapNewNode.lean#L89) | model-only helper (equates two Lean accessor-wrapper forms of the same def) |

### `Refinement/Swarm/AsyncSwapOnlyOwner.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `onlyOwner_notOwner` | [AsyncSwapOnlyOwner.lean:20](../../formal/Refinement/Swarm/AsyncSwapOnlyOwner.lean#L20) | [`AsyncSwapOnlyOwner.t.sol`](AsyncSwapOnlyOwner.t.sol) `testFuzz_onlyOwner_notOwner` | with edits |
| `onlyOwner_owner` | [AsyncSwapOnlyOwner.lean:25](../../formal/Refinement/Swarm/AsyncSwapOnlyOwner.lean#L25) | [`AsyncSwapOnlyOwner.t.sol`](AsyncSwapOnlyOwner.t.sol) `testFuzz_onlyOwner_owner` | with edits |
| `onlyOwner_run` | [AsyncSwapOnlyOwner.lean:32](../../formal/Refinement/Swarm/AsyncSwapOnlyOwner.lean#L32) | [`AsyncSwapOnlyOwner.t.sol`](AsyncSwapOnlyOwner.t.sol) `testFuzz_onlyOwner_run` | with edits |
| `onlyOwner_reverts_NotOwner_iff` | [AsyncSwapOnlyOwner.lean:40](../../formal/Refinement/Swarm/AsyncSwapOnlyOwner.lean#L40) | [`AsyncSwapOnlyOwner.t.sol`](AsyncSwapOnlyOwner.t.sol) `testFuzz_onlyOwner_reverts_NotOwner_iff` | with edits |
| `onlyOwner_ok` | [AsyncSwapOnlyOwner.lean:47](../../formal/Refinement/Swarm/AsyncSwapOnlyOwner.lean#L47) | [`AsyncSwapOnlyOwner.t.sol`](AsyncSwapOnlyOwner.t.sol) `testFuzz_onlyOwner_ok` | with edits |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `onlyOwner_pure_storage` | [AsyncSwapOnlyOwner.lean:56](../../formal/Refinement/Swarm/AsyncSwapOnlyOwner.lean#L56) | no contract entry point applies `onlyOwner` to a trivial body (`pure a`); a model-only instance of `onlyOwner_ok` (which is tested) |

### `Refinement/Swarm/AsyncSwapOrderBookLevel.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `orderBookLevel_readOnly` | [AsyncSwapOrderBookLevel.lean:63](../../formal/Refinement/Swarm/AsyncSwapOrderBookLevel.lean#L63) | [`AsyncSwapOrderBookLevel.t.sol`](AsyncSwapOrderBookLevel.t.sol) `testFuzz_orderBookLevel_readOnly` | no |
| `orderBookLevel_view` | [AsyncSwapOrderBookLevel.lean:73](../../formal/Refinement/Swarm/AsyncSwapOrderBookLevel.lean#L73) | [`AsyncSwapOrderBookLevel.t.sol`](AsyncSwapOrderBookLevel.t.sol) `testFuzz_orderBookLevel_view` | no |
| `orderBookLevel_congr` | [AsyncSwapOrderBookLevel.lean:86](../../formal/Refinement/Swarm/AsyncSwapOrderBookLevel.lean#L86) | [`AsyncSwapOrderBookLevel.t.sol`](AsyncSwapOrderBookLevel.t.sol) `testFuzz_orderBookLevel_congr` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `orderBookLevel_eq` | [AsyncSwapOrderBookLevel.lean:41](../../formal/Refinement/Swarm/AsyncSwapOrderBookLevel.lean#L41) | `*_eq` rewriting the generated def into the opaque `ext.fn_AsyncFiller_level_6002` (no observable claim beyond the others) |
| `orderBookLevel_run` | [AsyncSwapOrderBookLevel.lean:48](../../formal/Refinement/Swarm/AsyncSwapOrderBookLevel.lean#L48) | `*_run` that only unfolds into the opaque `ext.fn_AsyncFiller_level_6002` (no observable value) |
| `orderBookLevel_reverts_iff` | [AsyncSwapOrderBookLevel.lean:55](../../formal/Refinement/Swarm/AsyncSwapOrderBookLevel.lean#L55) | statement about the opaque `ext.fn_AsyncFiller_level_6002` (reverts iff the callee does); the callee cannot be run separately from the hook. Never-reverts on real books is checked by orderBookLevel_view |

### `Refinement/Swarm/AsyncSwapOrderBookOrder.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `orderBookOrder_run` | [AsyncSwapOrderBookOrder.lean:25](../../formal/Refinement/Swarm/AsyncSwapOrderBookOrder.lean#L25) | [`AsyncSwapOrderBookOrder.t.sol`](AsyncSwapOrderBookOrder.t.sol) `testFuzz_orderBookOrder_run` | with edits |
| `orderBookOrder_never_reverts` | [AsyncSwapOrderBookOrder.lean:32](../../formal/Refinement/Swarm/AsyncSwapOrderBookOrder.lean#L32) | [`AsyncSwapOrderBookOrder.t.sol`](AsyncSwapOrderBookOrder.t.sol) `testFuzz_orderBookOrder_never_reverts` | with edits |
| `orderBookOrder_readOnly` | [AsyncSwapOrderBookOrder.lean:37](../../formal/Refinement/Swarm/AsyncSwapOrderBookOrder.lean#L37) | [`AsyncSwapOrderBookOrder.t.sol`](AsyncSwapOrderBookOrder.t.sol) `testFuzz_orderBookOrder_readOnly` | no |
| `orderBookOrder_congr` | [AsyncSwapOrderBookOrder.lean:44](../../formal/Refinement/Swarm/AsyncSwapOrderBookOrder.lean#L44) | [`AsyncSwapOrderBookOrder.t.sol`](AsyncSwapOrderBookOrder.t.sol) `testFuzz_orderBookOrder_congr` | with edits |

### `Refinement/Swarm/AsyncSwapOrderingMode.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `orderingMode_run` | [AsyncSwapOrderingMode.lean:18](../../formal/Refinement/Swarm/AsyncSwapOrderingMode.lean#L18) | [`AsyncSwapOrderingMode.t.sol`](AsyncSwapOrderingMode.t.sol) `testFuzz_orderingMode_run` | with edits |
| `orderingMode_never_reverts` | [AsyncSwapOrderingMode.lean:24](../../formal/Refinement/Swarm/AsyncSwapOrderingMode.lean#L24) | [`AsyncSwapOrderingMode.t.sol`](AsyncSwapOrderingMode.t.sol) `testFuzz_orderingMode_never_reverts` | with edits |
| `orderingMode_frame` | [AsyncSwapOrderingMode.lean:29](../../formal/Refinement/Swarm/AsyncSwapOrderingMode.lean#L29) | [`AsyncSwapOrderingMode.t.sol`](AsyncSwapOrderingMode.t.sol) `testFuzz_orderingMode_frame` | with edits |
| `orderingMode_result` | [AsyncSwapOrderingMode.lean:34](../../formal/Refinement/Swarm/AsyncSwapOrderingMode.lean#L34) | [`AsyncSwapOrderingMode.t.sol`](AsyncSwapOrderingMode.t.sol) `testFuzz_orderingMode_result` | with edits |

### `Refinement/Swarm/AsyncSwapPriorityKey.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `priorityKey_spec` | [AsyncSwapPriorityKey.lean:25](../../formal/Refinement/Swarm/AsyncSwapPriorityKey.lean#L25) | [`AsyncSwapPriorityKey.t.sol`](AsyncSwapPriorityKey.t.sol) `testFuzz_priorityKey_spec` | yes |
| `priorityKey_ok` | [AsyncSwapPriorityKey.lean:42](../../formal/Refinement/Swarm/AsyncSwapPriorityKey.lean#L42) | [`AsyncSwapPriorityKey.t.sol`](AsyncSwapPriorityKey.t.sol) `testFuzz_priorityKey_ok` | yes |
| `priorityKey_run` | [AsyncSwapPriorityKey.lean:54](../../formal/Refinement/Swarm/AsyncSwapPriorityKey.lean#L54) | [`AsyncSwapPriorityKey.t.sol`](AsyncSwapPriorityKey.t.sol) `testFuzz_priorityKey_run` | yes |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `priorityKey_reverts` | [AsyncSwapPriorityKey.lean:36](../../formal/Refinement/Swarm/AsyncSwapPriorityKey.lean#L36) | hypothesis can't be represented: `sequence` is `uint64` in Solidity (`seq > 2^64 - 1` can't be passed or stored; the model's unbounded Nat) |

### `Refinement/Swarm/AsyncSwapReceive.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `receive_run` | [AsyncSwapReceive.lean:32](../../formal/Refinement/Swarm/AsyncSwapReceive.lean#L32) | [`AsyncSwapReceive.t.sol`](AsyncSwapReceive.t.sol) `testFuzz_receive_run` | no |
| `receive_never_reverts` | [AsyncSwapReceive.lean:37](../../formal/Refinement/Swarm/AsyncSwapReceive.lean#L37) | [`AsyncSwapReceive.t.sol`](AsyncSwapReceive.t.sol) `testFuzz_receive_never_reverts` | no |
| `receive_ok` | [AsyncSwapReceive.lean:42](../../formal/Refinement/Swarm/AsyncSwapReceive.lean#L42) | [`AsyncSwapReceive.t.sol`](AsyncSwapReceive.t.sol) `testFuzz_receive_ok` | no |
| `receive_frame` | [AsyncSwapReceive.lean:50](../../formal/Refinement/Swarm/AsyncSwapReceive.lean#L50) | [`AsyncSwapReceive.t.sol`](AsyncSwapReceive.t.sol) `testFuzz_receive_frame` | no |

### `Refinement/Swarm/AsyncSwapRecordPriorityFee.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `recordPriorityFee_run` | [AsyncSwapRecordPriorityFee.lean:87](../../formal/Refinement/Swarm/AsyncSwapRecordPriorityFee.lean#L87) | [`AsyncSwapRecordPriorityFee.t.sol`](AsyncSwapRecordPriorityFee.t.sol) `testFuzz_recordPriorityFee_run` | no |
| `recordPriorityFee_unauthorized` | [AsyncSwapRecordPriorityFee.lean:154](../../formal/Refinement/Swarm/AsyncSwapRecordPriorityFee.lean#L154) | [`AsyncSwapRecordPriorityFee.t.sol`](AsyncSwapRecordPriorityFee.t.sol) `testFuzz_recordPriorityFee_unauthorized` | no |
| `recordPriorityFee_wrong_maker` | [AsyncSwapRecordPriorityFee.lean:160](../../formal/Refinement/Swarm/AsyncSwapRecordPriorityFee.lean#L160) | [`AsyncSwapRecordPriorityFee.t.sol`](AsyncSwapRecordPriorityFee.t.sol) `testFuzz_recordPriorityFee_wrong_maker` | no |
| `recordPriorityFee_escrowed_reverts` | [AsyncSwapRecordPriorityFee.lean:169](../../formal/Refinement/Swarm/AsyncSwapRecordPriorityFee.lean#L169) | [`AsyncSwapRecordPriorityFee.t.sol`](AsyncSwapRecordPriorityFee.t.sol) `testFuzz_recordPriorityFee_escrowed_reverts` | no |
| `recordPriorityFee_amount_mismatch_reverts` | [AsyncSwapRecordPriorityFee.lean:181](../../formal/Refinement/Swarm/AsyncSwapRecordPriorityFee.lean#L181) | [`AsyncSwapRecordPriorityFee.t.sol`](AsyncSwapRecordPriorityFee.t.sol) `testFuzz_recordPriorityFee_amount_mismatch_reverts` | no |
| `recordPriorityFee_ok` | [AsyncSwapRecordPriorityFee.lean:197](../../formal/Refinement/Swarm/AsyncSwapRecordPriorityFee.lean#L197) | [`AsyncSwapRecordPriorityFee.t.sol`](AsyncSwapRecordPriorityFee.t.sol) `testFuzz_recordPriorityFee_ok` | no |
| `recordPriorityFee_twice_reverts` | [AsyncSwapRecordPriorityFee.lean:264](../../formal/Refinement/Swarm/AsyncSwapRecordPriorityFee.lean#L264) | [`AsyncSwapRecordPriorityFee.t.sol`](AsyncSwapRecordPriorityFee.t.sol) `testFuzz_recordPriorityFee_twice_reverts` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `ite_pos'` | [AsyncSwapRecordPriorityFee.lean:42](../../formal/Refinement/Swarm/AsyncSwapRecordPriorityFee.lean#L42) | model-only helper (Lean `ite` lemma) |
| `ite_neg'` | [AsyncSwapRecordPriorityFee.lean:44](../../formal/Refinement/Swarm/AsyncSwapRecordPriorityFee.lean#L44) | model-only helper (Lean `ite` lemma) |
| `flagWorld_frame` | [AsyncSwapRecordPriorityFee.lean:231](../../formal/Refinement/Swarm/AsyncSwapRecordPriorityFee.lean#L231) | model-only frame lemma about the Lean def `flagWorld` (the flag write in isolation is not observable apart from the re-queue); flag/priorityKey after a real call checked in recordPriorityFee_run |

### `Refinement/Swarm/AsyncSwapReduceAfterMatch.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `priceKey_ok` | [AsyncSwapReduceAfterMatch.lean:95](../../formal/Refinement/Swarm/AsyncSwapReduceAfterMatch.lean#L95) | [`AsyncSwapReduceAfterMatch.t.sol`](AsyncSwapReduceAfterMatch.t.sol) `testFuzz_priceKey_ok` | no |
| `reduceAfterMatch_ok_close` | [AsyncSwapReduceAfterMatch.lean:149](../../formal/Refinement/Swarm/AsyncSwapReduceAfterMatch.lean#L149) | [`AsyncSwapReduceAfterMatch.t.sol`](AsyncSwapReduceAfterMatch.t.sol) `testFuzz_reduceAfterMatch_ok_close` | no |
| `reduceAfterMatch_ok_partial` | [AsyncSwapReduceAfterMatch.lean:258](../../formal/Refinement/Swarm/AsyncSwapReduceAfterMatch.lean#L258) | [`AsyncSwapReduceAfterMatch.t.sol`](AsyncSwapReduceAfterMatch.t.sol) `testFuzz_reduceAfterMatch_ok_partial` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `upd_upd` | [AsyncSwapReduceAfterMatch.lean:74](../../formal/Refinement/Swarm/AsyncSwapReduceAfterMatch.lean#L74) | model-only helper (Lean function-update lemma) |
| `post_ok` | [AsyncSwapReduceAfterMatch.lean:78](../../formal/Refinement/Swarm/AsyncSwapReduceAfterMatch.lean#L78) | model-only helper (the saturating-cast tail of the Lean `_priceKey` def) |
| `reduceAfterMatch_overuse` | [AsyncSwapReduceAfterMatch.lean:134](../../formal/Refinement/Swarm/AsyncSwapReduceAfterMatch.lean#L134) | private function, hypothesis not reachable: `_reduceMatchedOrders` always passes `inputUsed <= amountIn` (see above) |

### `Refinement/Swarm/AsyncSwapReduceMatchedOrders.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `reduceMatchedOrders_eq` | [AsyncSwapReduceMatchedOrders.lean:68](../../formal/Refinement/Swarm/AsyncSwapReduceMatchedOrders.lean#L68) | [`AsyncSwapReduceMatchedOrders.t.sol`](AsyncSwapReduceMatchedOrders.t.sol) `testFuzz_reduceMatchedOrders_eq` | no |
| `reduceMatchedOrders_ok_iff` | [AsyncSwapReduceMatchedOrders.lean:127](../../formal/Refinement/Swarm/AsyncSwapReduceMatchedOrders.lean#L127) | [`AsyncSwapReduceMatchedOrders.t.sol`](AsyncSwapReduceMatchedOrders.t.sol) `testFuzz_reduceMatchedOrders_ok_iff` | no |
| `reduceMatchedOrders_ok_bounds` | [AsyncSwapReduceMatchedOrders.lean:148](../../formal/Refinement/Swarm/AsyncSwapReduceMatchedOrders.lean#L148) | [`AsyncSwapReduceMatchedOrders.t.sol`](AsyncSwapReduceMatchedOrders.t.sol) `testFuzz_reduceMatchedOrders_ok_bounds` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `sides_cover` | [AsyncSwapReduceMatchedOrders.lean:54](../../formal/Refinement/Swarm/AsyncSwapReduceMatchedOrders.lean#L54) | model-only helper (the Lean `sellId` / `buyId` defs are {firstId, secondId}) |
| `reduceMatchedOrders_sell_overuse` | [AsyncSwapReduceMatchedOrders.lean:102](../../formal/Refinement/Swarm/AsyncSwapReduceMatchedOrders.lean#L102) | private function, hypothesis not reachable from an entry point: its only caller `_matchPair` passes `assetAmount <= sell.amountIn` (`matchAmounts_ok_sound`, tested) |
| `reduceMatchedOrders_buy_overuse` | [AsyncSwapReduceMatchedOrders.lean:113](../../formal/Refinement/Swarm/AsyncSwapReduceMatchedOrders.lean#L113) | private function, hypothesis not reachable: `quoteAmount <= buy.amountIn`, and the sell reduction never touches the buy order |

### `Refinement/Swarm/AsyncSwapRemove.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `remove_run` | [AsyncSwapRemove.lean:48](../../formal/Refinement/Swarm/AsyncSwapRemove.lean#L48) | [`AsyncSwapRemove.t.sol`](AsyncSwapRemove.t.sol) `testFuzz_remove_run` | no |
| `remove_reverts_iff` | [AsyncSwapRemove.lean:104](../../formal/Refinement/Swarm/AsyncSwapRemove.lean#L104) | [`AsyncSwapRemove.t.sol`](AsyncSwapRemove.t.sol) `testFuzz_remove_reverts_iff` | yes |
| `remove_ok` | [AsyncSwapRemove.lean:115](../../formal/Refinement/Swarm/AsyncSwapRemove.lean#L115) | [`AsyncSwapRemove.t.sol`](AsyncSwapRemove.t.sol) `testFuzz_remove_ok, testFuzz_remove_ok_validTree` | yes |
| `remove_footprint` | [AsyncSwapRemove.lean:126](../../formal/Refinement/Swarm/AsyncSwapRemove.lean#L126) | [`AsyncSwapRemove.t.sol`](AsyncSwapRemove.t.sol) `testFuzz_remove_footprint` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `removeTree_leaves` | [AsyncSwapRemove.lean:70](../../formal/Refinement/Swarm/AsyncSwapRemove.lean#L70) | model-only helper (lemma about the Lean def `removeTree`; covered on the bytecode by remove_run / remove_footprint) |
| `removeTree_nextNodeId` | [AsyncSwapRemove.lean:78](../../formal/Refinement/Swarm/AsyncSwapRemove.lean#L78) | model-only helper (Lean `removeTree`; covered by remove_run / remove_footprint) |
| `removeTree_freeIds` | [AsyncSwapRemove.lean:86](../../formal/Refinement/Swarm/AsyncSwapRemove.lean#L86) | model-only helper (Lean `removeTree`; covered by remove_run / remove_footprint) |
| `removeTree_root_of_root` | [AsyncSwapRemove.lean:97](../../formal/Refinement/Swarm/AsyncSwapRemove.lean#L97) | model-only helper (Lean `removeTree`; covered by remove_run) |

### `Refinement/Swarm/AsyncSwapRevert.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `revert_run` | [AsyncSwapRevert.lean:19](../../formal/Refinement/Swarm/AsyncSwapRevert.lean#L19) | [`AsyncSwapRevert.t.sol`](AsyncSwapRevert.t.sol) `testFuzz_revert_run` | yes |
| `revert_nonempty` | [AsyncSwapRevert.lean:26](../../formal/Refinement/Swarm/AsyncSwapRevert.lean#L26) | [`AsyncSwapRevert.t.sol`](AsyncSwapRevert.t.sol) `testFuzz_revert_nonempty` | yes |
| `revert_empty` | [AsyncSwapRevert.lean:31](../../formal/Refinement/Swarm/AsyncSwapRevert.lean#L31) | [`AsyncSwapRevert.t.sol`](AsyncSwapRevert.t.sol) `test_revert_empty` | yes |
| `revert_never_ok` | [AsyncSwapRevert.lean:36](../../formal/Refinement/Swarm/AsyncSwapRevert.lean#L36) | [`AsyncSwapRevert.t.sol`](AsyncSwapRevert.t.sol) `testFuzz_revert_never_ok` | yes |

### `Refinement/Swarm/AsyncSwapSafeTransferFrom.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `safeTransferFrom_spec` | [AsyncSwapSafeTransferFrom.lean:39](../../formal/Refinement/Swarm/AsyncSwapSafeTransferFrom.lean#L39) | [`AsyncSwapSafeTransferFrom.t.sol`](AsyncSwapSafeTransferFrom.t.sol) `testFuzz_safeTransferFrom_spec` | no |
| `safeTransferFrom_ok_iff` | [AsyncSwapSafeTransferFrom.lean:91](../../formal/Refinement/Swarm/AsyncSwapSafeTransferFrom.lean#L91) | [`AsyncSwapSafeTransferFrom.t.sol`](AsyncSwapSafeTransferFrom.t.sol) `testFuzz_safeTransferFrom_ok_iff` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `afterCall_ok_iff` | [AsyncSwapSafeTransferFrom.lean:71](../../formal/Refinement/Swarm/AsyncSwapSafeTransferFrom.lean#L71) | model-only helper (lemma about the file's own Lean def `afterCall`; its content on the bytecode is `safeTransferFrom_spec` / `_ok_iff`) |
| `safeTransferFrom_call_reverts` | [AsyncSwapSafeTransferFrom.lean:109](../../formal/Refinement/Swarm/AsyncSwapSafeTransferFrom.lean#L109) | hypothesis on opaque `ext.lowCall` returning `.error`: the generated `Ext` says a failed low-level call returns `false` and doesn't revert, and a CALL never reverts its caller (only the caller's own out-of-gas would, which the gas-free model has no `Revert` for) |

### `Refinement/Swarm/AsyncSwapSetExecutorWithSig.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `setExecutorWithSig_expired` | [AsyncSwapSetExecutorWithSig.lean:94](../../formal/Refinement/Swarm/AsyncSwapSetExecutorWithSig.lean#L94) | [`AsyncSwapSetExecutorWithSig.t.sol`](AsyncSwapSetExecutorWithSig.t.sol) `testFuzz_setExecutorWithSig_expired` | no |
| `setExecutorWithSig_nonce_used` | [AsyncSwapSetExecutorWithSig.lean:103](../../formal/Refinement/Swarm/AsyncSwapSetExecutorWithSig.lean#L103) | [`AsyncSwapSetExecutorWithSig.t.sol`](AsyncSwapSetExecutorWithSig.t.sol) `testFuzz_setExecutorWithSig_nonce_used` | no |
| `setExecutorWithSig_invalid_sig` | [AsyncSwapSetExecutorWithSig.lean:112](../../formal/Refinement/Swarm/AsyncSwapSetExecutorWithSig.lean#L112) | [`AsyncSwapSetExecutorWithSig.t.sol`](AsyncSwapSetExecutorWithSig.t.sol) `testFuzz_setExecutorWithSig_invalid_sig` | no |
| `setExecutorWithSig_ok` | [AsyncSwapSetExecutorWithSig.lean:124](../../formal/Refinement/Swarm/AsyncSwapSetExecutorWithSig.lean#L124) | [`AsyncSwapSetExecutorWithSig.t.sol`](AsyncSwapSetExecutorWithSig.t.sol) `testFuzz_setExecutorWithSig_ok` | no |
| `setExecutorWithSig_ok_inv` | [AsyncSwapSetExecutorWithSig.lean:139](../../formal/Refinement/Swarm/AsyncSwapSetExecutorWithSig.lean#L139) | [`AsyncSwapSetExecutorWithSig.t.sol`](AsyncSwapSetExecutorWithSig.t.sol) `testFuzz_setExecutorWithSig_ok_inv (the same signature succeeds iff none of key/maker/executor/allow/nonce/deadline is altered)` | no |
| `setExecutorWithSig_ok_state` | [AsyncSwapSetExecutorWithSig.lean:187](../../formal/Refinement/Swarm/AsyncSwapSetExecutorWithSig.lean#L187) | [`AsyncSwapSetExecutorWithSig.t.sol`](AsyncSwapSetExecutorWithSig.t.sol) `testFuzz_setExecutorWithSig_ok_state` | no |
| `setExecutorWithSig_frame` | [AsyncSwapSetExecutorWithSig.lean:206](../../formal/Refinement/Swarm/AsyncSwapSetExecutorWithSig.lean#L206) | [`AsyncSwapSetExecutorWithSig.t.sol`](AsyncSwapSetExecutorWithSig.t.sol) `testFuzz_setExecutorWithSig_frame` | no |
| `setExecutorWithSig_no_replay` | [AsyncSwapSetExecutorWithSig.lean:252](../../formal/Refinement/Swarm/AsyncSwapSetExecutorWithSig.lean#L252) | [`AsyncSwapSetExecutorWithSig.t.sol`](AsyncSwapSetExecutorWithSig.t.sol) `testFuzz_setExecutorWithSig_no_replay` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `tryRecover_preserves` | [AsyncSwapSetExecutorWithSig.lean:31](../../formal/Refinement/Swarm/AsyncSwapSetExecutorWithSig.lean#L31) | model-only helper (storage neutrality of the Lean def `ECDSA.tryRecover`; an internal pure function in the bytecode) |
| `tryRecover_9821_preserves` | [AsyncSwapSetExecutorWithSig.lean:39](../../formal/Refinement/Swarm/AsyncSwapSetExecutorWithSig.lean#L39) | model-only helper (as above) |
| `isValidSignatureNow_preserves` | [AsyncSwapSetExecutorWithSig.lean:49](../../formal/Refinement/Swarm/AsyncSwapSetExecutorWithSig.lean#L49) | model-only helper (storage neutrality of a Lean def, conditional on the opaque ERC-1271 call) |
| `hashTypedDataV4_preserves` | [AsyncSwapSetExecutorWithSig.lean:64](../../formal/Refinement/Swarm/AsyncSwapSetExecutorWithSig.lean#L64) | model-only helper (storage neutrality of a Lean def, conditional on opaque `toTypedDataHash`) |

### `Refinement/Swarm/AsyncSwapSetOrderingMode.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `setOrderingMode_run` | [AsyncSwapSetOrderingMode.lean:24](../../formal/Refinement/Swarm/AsyncSwapSetOrderingMode.lean#L24) | [`AsyncSwapSetOrderingMode.t.sol`](AsyncSwapSetOrderingMode.t.sol) `testFuzz_setOrderingMode_run` | with edits |
| `setOrderingMode_notOwner` | [AsyncSwapSetOrderingMode.lean:38](../../formal/Refinement/Swarm/AsyncSwapSetOrderingMode.lean#L38) | [`AsyncSwapSetOrderingMode.t.sol`](AsyncSwapSetOrderingMode.t.sol) `testFuzz_setOrderingMode_notOwner` | with edits |
| `setOrderingMode_ok_owner` | [AsyncSwapSetOrderingMode.lean:44](../../formal/Refinement/Swarm/AsyncSwapSetOrderingMode.lean#L44) | [`AsyncSwapSetOrderingMode.t.sol`](AsyncSwapSetOrderingMode.t.sol) `testFuzz_setOrderingMode_ok_owner` | with edits |
| `setOrderingMode_ok_iff` | [AsyncSwapSetOrderingMode.lean:53](../../formal/Refinement/Swarm/AsyncSwapSetOrderingMode.lean#L53) | [`AsyncSwapSetOrderingMode.t.sol`](AsyncSwapSetOrderingMode.t.sol) `testFuzz_setOrderingMode_ok_iff` | no |
| `setOrderingMode_ok_state` | [AsyncSwapSetOrderingMode.lean:67](../../formal/Refinement/Swarm/AsyncSwapSetOrderingMode.lean#L67) | [`AsyncSwapSetOrderingMode.t.sol`](AsyncSwapSetOrderingMode.t.sol) `testFuzz_setOrderingMode_ok_state` | with edits |

### `Refinement/Swarm/AsyncSwapSettleMatchedPriorityFee.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `settleMatchedPriorityFee_run` | [AsyncSwapSettleMatchedPriorityFee.lean:37](../../formal/Refinement/Swarm/AsyncSwapSettleMatchedPriorityFee.lean#L37) | [`AsyncSwapSettleMatchedPriorityFee.t.sol`](AsyncSwapSettleMatchedPriorityFee.t.sol) `testFuzz_settleMatchedPriorityFee_run` | no |
| `settleMatchedPriorityFee_no_fee` | [AsyncSwapSettleMatchedPriorityFee.lean:81](../../formal/Refinement/Swarm/AsyncSwapSettleMatchedPriorityFee.lean#L81) | [`AsyncSwapSettleMatchedPriorityFee.t.sol`](AsyncSwapSettleMatchedPriorityFee.t.sol) `testFuzz_settleMatchedPriorityFee_no_fee` | no |
| `settleMatchedPriorityFee_matched` | [AsyncSwapSettleMatchedPriorityFee.lean:103](../../formal/Refinement/Swarm/AsyncSwapSettleMatchedPriorityFee.lean#L103) | [`AsyncSwapSettleMatchedPriorityFee.t.sol`](AsyncSwapSettleMatchedPriorityFee.t.sol) `testFuzz_settleMatchedPriorityFee_matched` | no |
| `settleMatchedPriorityFee_ok` | [AsyncSwapSettleMatchedPriorityFee.lean:125](../../formal/Refinement/Swarm/AsyncSwapSettleMatchedPriorityFee.lean#L125) | [`AsyncSwapSettleMatchedPriorityFee.t.sol`](AsyncSwapSettleMatchedPriorityFee.t.sol) `testFuzz_settleMatchedPriorityFee_ok` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `filled_le_fee` | [AsyncSwapSettleMatchedPriorityFee.lean:93](../../formal/Refinement/Swarm/AsyncSwapSettleMatchedPriorityFee.lean#L93) | model-only helper (Nat lemma `fee·u/o <= fee` for `u <= o`; on the bytecode it is checked inside `settleMatchedPriorityFee_ok`) |

### `Refinement/Swarm/AsyncSwapSettleOrderPriorityFee.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `settleOrderPriorityFee_run` | [AsyncSwapSettleOrderPriorityFee.lean:32](../../formal/Refinement/Swarm/AsyncSwapSettleOrderPriorityFee.lean#L32) | [`AsyncSwapSettleOrderPriorityFee.t.sol`](AsyncSwapSettleOrderPriorityFee.t.sol) `testFuzz_settleOrderPriorityFee_run` | no |
| `settleOrderPriorityFee_not_escrowed` | [AsyncSwapSettleOrderPriorityFee.lean:45](../../formal/Refinement/Swarm/AsyncSwapSettleOrderPriorityFee.lean#L45) | [`AsyncSwapSettleOrderPriorityFee.t.sol`](AsyncSwapSettleOrderPriorityFee.t.sol) `testFuzz_settleOrderPriorityFee_not_escrowed` | with edits |
| `settleOrderPriorityFee_zero_fee` | [AsyncSwapSettleOrderPriorityFee.lean:55](../../formal/Refinement/Swarm/AsyncSwapSettleOrderPriorityFee.lean#L55) | [`AsyncSwapSettleOrderPriorityFee.t.sol`](AsyncSwapSettleOrderPriorityFee.t.sol) `testFuzz_settleOrderPriorityFee_zero_fee` | with edits |
| `settleOrderPriorityFee_escrowed` | [AsyncSwapSettleOrderPriorityFee.lean:68](../../formal/Refinement/Swarm/AsyncSwapSettleOrderPriorityFee.lean#L68) | [`AsyncSwapSettleOrderPriorityFee.t.sol`](AsyncSwapSettleOrderPriorityFee.t.sol) `testFuzz_settleOrderPriorityFee_escrowed` | no |

### `Refinement/Swarm/AsyncSwapSettleTransfers.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `settleTransfers_run` | [AsyncSwapSettleTransfers.lean:57](../../formal/Refinement/Swarm/AsyncSwapSettleTransfers.lean#L57) | [`AsyncSwapSettleTransfers.t.sol`](AsyncSwapSettleTransfers.t.sol) `testFuzz_settleTransfers_run` | no |
| `settleTransfers_reverts_iff` | [AsyncSwapSettleTransfers.lean:79](../../formal/Refinement/Swarm/AsyncSwapSettleTransfers.lean#L79) | [`AsyncSwapSettleTransfers.t.sol`](AsyncSwapSettleTransfers.t.sol) `testFuzz_settleTransfers_reverts_iff` | no |
| `settleTransfers_ok` | [AsyncSwapSettleTransfers.lean:104](../../formal/Refinement/Swarm/AsyncSwapSettleTransfers.lean#L104) | [`AsyncSwapSettleTransfers.t.sol`](AsyncSwapSettleTransfers.t.sol) `testFuzz_settleTransfers_ok` | no |
| `settleTransfers_ok_same_manager` | [AsyncSwapSettleTransfers.lean:132](../../formal/Refinement/Swarm/AsyncSwapSettleTransfers.lean#L132) | [`AsyncSwapSettleTransfers.t.sol`](AsyncSwapSettleTransfers.t.sol) `testFuzz_settleTransfers_ok_same_manager` | no |

### `Refinement/Swarm/AsyncSwapSwapAgainstPool.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `swapAgainstPool_noLiquidity` | [AsyncSwapSwapAgainstPool.lean:33](../../formal/Refinement/Swarm/AsyncSwapSwapAgainstPool.lean#L33) | [`AsyncSwapSwapAgainstPool.t.sol`](AsyncSwapSwapAgainstPool.t.sol) `testFuzz_swapAgainstPool_noLiquidity` | no |
| `swapAgainstPool_success` | [AsyncSwapSwapAgainstPool.lean:45](../../formal/Refinement/Swarm/AsyncSwapSwapAgainstPool.lean#L45) | [`AsyncSwapSwapAgainstPool.t.sol`](AsyncSwapSwapAgainstPool.t.sol) `testFuzz_swapAgainstPool_success` | no |
| `swapAgainstPool_ok_liquidity_min` | [AsyncSwapSwapAgainstPool.lean:68](../../formal/Refinement/Swarm/AsyncSwapSwapAgainstPool.lean#L68) | [`AsyncSwapSwapAgainstPool.t.sol`](AsyncSwapSwapAgainstPool.t.sol) `testFuzz_swapAgainstPool_ok_liquidity_min` | no |
| `swapAgainstPool_amountIn_lt` | [AsyncSwapSwapAgainstPool.lean:79](../../formal/Refinement/Swarm/AsyncSwapSwapAgainstPool.lean#L79) | [`AsyncSwapSwapAgainstPool.t.sol`](AsyncSwapSwapAgainstPool.t.sol) `testFuzz_swapAgainstPool_amountIn_lt` | no |
| `swapAgainstPool_spec` | [AsyncSwapSwapAgainstPool.lean:92](../../formal/Refinement/Swarm/AsyncSwapSwapAgainstPool.lean#L92) | [`AsyncSwapSwapAgainstPool.t.sol`](AsyncSwapSwapAgainstPool.t.sol) `testFuzz_swapAgainstPool_spec` | no |

### `Refinement/Swarm/AsyncSwapSweep.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `sweep_notOwner` | [AsyncSwapSweep.lean:36](../../formal/Refinement/Swarm/AsyncSwapSweep.lean#L36) | [`AsyncSwapSweep.t.sol`](AsyncSwapSweep.t.sol) `testFuzz_sweep_notOwner` | with edits |
| `sweep_zeroTo` | [AsyncSwapSweep.lean:43](../../formal/Refinement/Swarm/AsyncSwapSweep.lean#L43) | [`AsyncSwapSweep.t.sol`](AsyncSwapSweep.t.sol) `testFuzz_sweep_zeroTo` | with edits |
| `sweep_reverts_unless` | [AsyncSwapSweep.lean:51](../../formal/Refinement/Swarm/AsyncSwapSweep.lean#L51) | [`AsyncSwapSweep.t.sol`](AsyncSwapSweep.t.sol) `testFuzz_sweep_reverts_unless` | with edits |
| `sweep_run` | [AsyncSwapSweep.lean:62](../../formal/Refinement/Swarm/AsyncSwapSweep.lean#L62) | [`AsyncSwapSweep.t.sol`](AsyncSwapSweep.t.sol) `testFuzz_sweep_run` | no |
| `sweep_ok` | [AsyncSwapSweep.lean:81](../../formal/Refinement/Swarm/AsyncSwapSweep.lean#L81) | [`AsyncSwapSweep.t.sol`](AsyncSwapSweep.t.sol) `testFuzz_sweep_ok` | with edits |
| `sweep_storage_unchanged` | [AsyncSwapSweep.lean:104](../../formal/Refinement/Swarm/AsyncSwapSweep.lean#L104) | [`AsyncSwapSweep.t.sol`](AsyncSwapSweep.t.sol) `testFuzz_sweep_storage_unchanged` | with edits |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `balanceOfSelf_noWrite` | [AsyncSwapSweep.lean:23](../../formal/Refinement/Swarm/AsyncSwapSweep.lean#L23) | model-only helper (Lean lemma about the internal `CurrencyLibrary.balanceOfSelf`, no external entry point); its consequence is covered by sweep_run/sweep_storage_unchanged |

### `Refinement/Swarm/AsyncSwapTransferEscrow.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `transferEscrow_run` | [AsyncSwapTransferEscrow.lean:49](../../formal/Refinement/Swarm/AsyncSwapTransferEscrow.lean#L49) | [`AsyncSwapTransferEscrow.t.sol`](AsyncSwapTransferEscrow.t.sol) `testFuzz_transferEscrow_run` | no |
| `transferEscrow_burn_reverts` | [AsyncSwapTransferEscrow.lean:67](../../formal/Refinement/Swarm/AsyncSwapTransferEscrow.lean#L67) | [`AsyncSwapTransferEscrow.t.sol`](AsyncSwapTransferEscrow.t.sol) `testFuzz_transferEscrow_burn_reverts` | no |
| `transferEscrow_native` | [AsyncSwapTransferEscrow.lean:75](../../formal/Refinement/Swarm/AsyncSwapTransferEscrow.lean#L75) | [`AsyncSwapTransferEscrow.t.sol`](AsyncSwapTransferEscrow.t.sol) `testFuzz_transferEscrow_native` | no |
| `transferEscrow_erc20` | [AsyncSwapTransferEscrow.lean:83](../../formal/Refinement/Swarm/AsyncSwapTransferEscrow.lean#L83) | [`AsyncSwapTransferEscrow.t.sol`](AsyncSwapTransferEscrow.t.sol) `testFuzz_transferEscrow_erc20` | no |
| `transferEscrow_ok` | [AsyncSwapTransferEscrow.lean:94](../../formal/Refinement/Swarm/AsyncSwapTransferEscrow.lean#L94) | [`AsyncSwapTransferEscrow.t.sol`](AsyncSwapTransferEscrow.t.sol) `testFuzz_transferEscrow_ok` | no |
| `transferEscrow_reverts_iff` | [AsyncSwapTransferEscrow.lean:108](../../formal/Refinement/Swarm/AsyncSwapTransferEscrow.lean#L108) | [`AsyncSwapTransferEscrow.t.sol`](AsyncSwapTransferEscrow.t.sol) `testFuzz_transferEscrow_reverts_iff` | no |

### `Refinement/Swarm/AsyncSwapTransferOwnership.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `transferOwnership_run` | [AsyncSwapTransferOwnership.lean:20](../../formal/Refinement/Swarm/AsyncSwapTransferOwnership.lean#L20) | [`AsyncSwapTransferOwnership.t.sol`](AsyncSwapTransferOwnership.t.sol) `testFuzz_transferOwnership_run` | with edits |
| `transferOwnership_notOwner` | [AsyncSwapTransferOwnership.lean:30](../../formal/Refinement/Swarm/AsyncSwapTransferOwnership.lean#L30) | [`AsyncSwapTransferOwnership.t.sol`](AsyncSwapTransferOwnership.t.sol) `testFuzz_transferOwnership_notOwner` | with edits |
| `transferOwnership_zero` | [AsyncSwapTransferOwnership.lean:36](../../formal/Refinement/Swarm/AsyncSwapTransferOwnership.lean#L36) | [`AsyncSwapTransferOwnership.t.sol`](AsyncSwapTransferOwnership.t.sol) `testFuzz_transferOwnership_zero` | with edits |
| `transferOwnership_ok_iff` | [AsyncSwapTransferOwnership.lean:43](../../formal/Refinement/Swarm/AsyncSwapTransferOwnership.lean#L43) | [`AsyncSwapTransferOwnership.t.sol`](AsyncSwapTransferOwnership.t.sol) `testFuzz_transferOwnership_ok_iff` | with edits |
| `transferOwnership_reverts_iff` | [AsyncSwapTransferOwnership.lean:52](../../formal/Refinement/Swarm/AsyncSwapTransferOwnership.lean#L52) | [`AsyncSwapTransferOwnership.t.sol`](AsyncSwapTransferOwnership.t.sol) `testFuzz_transferOwnership_reverts_iff` | with edits |
| `transferOwnership_ok_state` | [AsyncSwapTransferOwnership.lean:61](../../formal/Refinement/Swarm/AsyncSwapTransferOwnership.lean#L61) | [`AsyncSwapTransferOwnership.t.sol`](AsyncSwapTransferOwnership.t.sol) `testFuzz_transferOwnership_ok_state` | with edits |

### `Refinement/Swarm/AsyncSwapTryFillOrderFromPoolLiquidity.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `tryFillOrderFromPoolLiquidity_eq` | [AsyncSwapTryFillOrderFromPoolLiquidity.lean:46](../../formal/Refinement/Swarm/AsyncSwapTryFillOrderFromPoolLiquidity.lean#L46) | [`AsyncSwapTryFillOrderFromPoolLiquidity.t.sol`](AsyncSwapTryFillOrderFromPoolLiquidity.t.sol) `testFuzz_tryFillOrderFromPoolLiquidity_eq` | no |
| `tryFillOrderFromPoolLiquidity_notExecutor` | [AsyncSwapTryFillOrderFromPoolLiquidity.lean:72](../../formal/Refinement/Swarm/AsyncSwapTryFillOrderFromPoolLiquidity.lean#L72) | [`AsyncSwapTryFillOrderFromPoolLiquidity.t.sol`](AsyncSwapTryFillOrderFromPoolLiquidity.t.sol) `testFuzz_tryFillOrderFromPoolLiquidity_notExecutor` | no |
| `tryFillOrderFromPoolLiquidity_notFound` | [AsyncSwapTryFillOrderFromPoolLiquidity.lean:79](../../formal/Refinement/Swarm/AsyncSwapTryFillOrderFromPoolLiquidity.lean#L79) | [`AsyncSwapTryFillOrderFromPoolLiquidity.t.sol`](AsyncSwapTryFillOrderFromPoolLiquidity.t.sol) `testFuzz_tryFillOrderFromPoolLiquidity_notFound` | no |
| `tryFillOrderFromPoolLiquidity_pass` | [AsyncSwapTryFillOrderFromPoolLiquidity.lean:88](../../formal/Refinement/Swarm/AsyncSwapTryFillOrderFromPoolLiquidity.lean#L88) | [`AsyncSwapTryFillOrderFromPoolLiquidity.t.sol`](AsyncSwapTryFillOrderFromPoolLiquidity.t.sol) `testFuzz_tryFillOrderFromPoolLiquidity_pass` | no |
| `tryFillOrderFromPoolLiquidity_ok` | [AsyncSwapTryFillOrderFromPoolLiquidity.lean:103](../../formal/Refinement/Swarm/AsyncSwapTryFillOrderFromPoolLiquidity.lean#L103) | [`AsyncSwapTryFillOrderFromPoolLiquidity.t.sol`](AsyncSwapTryFillOrderFromPoolLiquidity.t.sol) `testFuzz_tryFillOrderFromPoolLiquidity_ok` | no |
| `tryFillOrderFromPoolLiquidity_reverts_iff` | [AsyncSwapTryFillOrderFromPoolLiquidity.lean:129](../../formal/Refinement/Swarm/AsyncSwapTryFillOrderFromPoolLiquidity.lean#L129) | [`AsyncSwapTryFillOrderFromPoolLiquidity.t.sol`](AsyncSwapTryFillOrderFromPoolLiquidity.t.sol) `testFuzz_tryFillOrderFromPoolLiquidity_reverts_iff` | no |
| `tryFillOrderFromPoolLiquidity_false_noop` | [AsyncSwapTryFillOrderFromPoolLiquidity.lean:151](../../formal/Refinement/Swarm/AsyncSwapTryFillOrderFromPoolLiquidity.lean#L151) | [`AsyncSwapTryFillOrderFromPoolLiquidity.t.sol`](AsyncSwapTryFillOrderFromPoolLiquidity.t.sol) `testFuzz_tryFillOrderFromPoolLiquidity_false_noop` | no |
| `tryFillOrderFromPoolLiquidity_storage` | [AsyncSwapTryFillOrderFromPoolLiquidity.lean:160](../../formal/Refinement/Swarm/AsyncSwapTryFillOrderFromPoolLiquidity.lean#L160) | [`AsyncSwapTryFillOrderFromPoolLiquidity.t.sol`](AsyncSwapTryFillOrderFromPoolLiquidity.t.sol) `testFuzz_tryFillOrderFromPoolLiquidity_storage (self-call reverts ⇒ every hook slot read or written during the call, found with `vm.record` on a snapshot pass, holds its old value)` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `run_tryCatch` | [AsyncSwapTryFillOrderFromPoolLiquidity.lean:30](../../formal/Refinement/Swarm/AsyncSwapTryFillOrderFromPoolLiquidity.lean#L30) | model-only helper (simp lemma about the Lean monad / ABI encoding) |

### `Refinement/Swarm/AsyncSwapUpdatePrice.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `updatePrice_run` | [AsyncSwapUpdatePrice.lean:72](../../formal/Refinement/Swarm/AsyncSwapUpdatePrice.lean#L72) | [`AsyncSwapUpdatePrice.t.sol`](AsyncSwapUpdatePrice.t.sol) `testFuzz_updatePrice_run` | no |
| `updatePrice_notOwner` | [AsyncSwapUpdatePrice.lean:92](../../formal/Refinement/Swarm/AsyncSwapUpdatePrice.lean#L92) | [`AsyncSwapUpdatePrice.t.sol`](AsyncSwapUpdatePrice.t.sol) `testFuzz_updatePrice_notOwner` | yes |
| `updatePrice_zero` | [AsyncSwapUpdatePrice.lean:98](../../formal/Refinement/Swarm/AsyncSwapUpdatePrice.lean#L98) | [`AsyncSwapUpdatePrice.t.sol`](AsyncSwapUpdatePrice.t.sol) `testFuzz_updatePrice_zero` | yes |
| `updatePrice_notFound` | [AsyncSwapUpdatePrice.lean:104](../../formal/Refinement/Swarm/AsyncSwapUpdatePrice.lean#L104) | [`AsyncSwapUpdatePrice.t.sol`](AsyncSwapUpdatePrice.t.sol) `testFuzz_updatePrice_notFound` | no |
| `priceKey_ok` | [AsyncSwapUpdatePrice.lean:127](../../formal/Refinement/Swarm/AsyncSwapUpdatePrice.lean#L127) | [`AsyncSwapUpdatePrice.t.sol`](AsyncSwapUpdatePrice.t.sol) `testFuzz_priceKey_ok` | no |
| `mid_ok` | [AsyncSwapUpdatePrice.lean:176](../../formal/Refinement/Swarm/AsyncSwapUpdatePrice.lean#L176) | [`AsyncSwapUpdatePrice.t.sol`](AsyncSwapUpdatePrice.t.sol) `testFuzz_mid_ok` | no |
| `midState_order` | [AsyncSwapUpdatePrice.lean:203](../../formal/Refinement/Swarm/AsyncSwapUpdatePrice.lean#L203) | [`AsyncSwapUpdatePrice.t.sol`](AsyncSwapUpdatePrice.t.sol) `testFuzz_midState_order` | no |
| `midState_other_order` | [AsyncSwapUpdatePrice.lean:213](../../formal/Refinement/Swarm/AsyncSwapUpdatePrice.lean#L213) | [`AsyncSwapUpdatePrice.t.sol`](AsyncSwapUpdatePrice.t.sol) `testFuzz_midState_other_order` | no |
| `midState_other_pool` | [AsyncSwapUpdatePrice.lean:218](../../formal/Refinement/Swarm/AsyncSwapUpdatePrice.lean#L218) | [`AsyncSwapUpdatePrice.t.sol`](AsyncSwapUpdatePrice.t.sol) `testFuzz_midState_other_pool` | no |
| `midState_frame` | [AsyncSwapUpdatePrice.lean:223](../../formal/Refinement/Swarm/AsyncSwapUpdatePrice.lean#L223) | [`AsyncSwapUpdatePrice.t.sol`](AsyncSwapUpdatePrice.t.sol) `testFuzz_updatePrice_ok` | no |
| `updatePrice_ok` | [AsyncSwapUpdatePrice.lean:236](../../formal/Refinement/Swarm/AsyncSwapUpdatePrice.lean#L236) | [`AsyncSwapUpdatePrice.t.sol`](AsyncSwapUpdatePrice.t.sol) `testFuzz_updatePrice_ok` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `post_ok` | [AsyncSwapUpdatePrice.lean:110](../../formal/Refinement/Swarm/AsyncSwapUpdatePrice.lean#L110) | model-only helper (Lean `ite`/`Except` lemma) |
| `upd_upd` | [AsyncSwapUpdatePrice.lean:159](../../formal/Refinement/Swarm/AsyncSwapUpdatePrice.lean#L159) | model-only helper (lemma about Lean `upd`) |

### `Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `verify_run` | [AsyncSwapUpdatePriceWithSig.lean:59](../../formal/Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean#L59) | [`AsyncSwapUpdatePriceWithSig.t.sol`](AsyncSwapUpdatePriceWithSig.t.sol) `testFuzz_verify_run` | no |
| `updatePriceWithSig_run` | [AsyncSwapUpdatePriceWithSig.lean:79](../../formal/Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean#L79) | [`AsyncSwapUpdatePriceWithSig.t.sol`](AsyncSwapUpdatePriceWithSig.t.sol) `testFuzz_updatePriceWithSig_run` | no |
| `updatePriceWithSig_expired` | [AsyncSwapUpdatePriceWithSig.lean:108](../../formal/Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean#L108) | [`AsyncSwapUpdatePriceWithSig.t.sol`](AsyncSwapUpdatePriceWithSig.t.sol) `testFuzz_updatePriceWithSig_expired` | yes |
| `updatePriceWithSig_nonceUsed` | [AsyncSwapUpdatePriceWithSig.lean:114](../../formal/Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean#L114) | [`AsyncSwapUpdatePriceWithSig.t.sol`](AsyncSwapUpdatePriceWithSig.t.sol) `testFuzz_updatePriceWithSig_nonceUsed` | no |
| `updatePriceWithSig_invalidSig` | [AsyncSwapUpdatePriceWithSig.lean:122](../../formal/Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean#L122) | [`AsyncSwapUpdatePriceWithSig.t.sol`](AsyncSwapUpdatePriceWithSig.t.sol) `testFuzz_updatePriceWithSig_invalidSig` | no |
| `updatePriceWithSig_zero` | [AsyncSwapUpdatePriceWithSig.lean:132](../../formal/Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean#L132) | [`AsyncSwapUpdatePriceWithSig.t.sol`](AsyncSwapUpdatePriceWithSig.t.sol) `testFuzz_updatePriceWithSig_zero` | no |
| `updatePriceWithSig_notFound` | [AsyncSwapUpdatePriceWithSig.lean:139](../../formal/Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean#L139) | [`AsyncSwapUpdatePriceWithSig.t.sol`](AsyncSwapUpdatePriceWithSig.t.sol) `testFuzz_updatePriceWithSig_notFound` | no |
| `updatePriceWithSig_noOwnerGuard` | [AsyncSwapUpdatePriceWithSig.lean:150](../../formal/Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean#L150) | [`AsyncSwapUpdatePriceWithSig.t.sol`](AsyncSwapUpdatePriceWithSig.t.sol) `testFuzz_updatePriceWithSig_noOwnerGuard` | no |
| `verify_ok_inv` | [AsyncSwapUpdatePriceWithSig.lean:183](../../formal/Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean#L183) | [`AsyncSwapUpdatePriceWithSig.t.sol`](AsyncSwapUpdatePriceWithSig.t.sol) `testFuzz_verify_ok_inv` | no |
| `updatePriceWithSig_missing_reverts` | [AsyncSwapUpdatePriceWithSig.lean:219](../../formal/Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean#L219) | [`AsyncSwapUpdatePriceWithSig.t.sol`](AsyncSwapUpdatePriceWithSig.t.sol) `testFuzz_updatePriceWithSig_missing_reverts` | no |
| `updatePriceWithSig_ok` | [AsyncSwapUpdatePriceWithSig.lean:242](../../formal/Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean#L242) | [`AsyncSwapUpdatePriceWithSig.t.sol`](AsyncSwapUpdatePriceWithSig.t.sol) `testFuzz_updatePriceWithSig_ok` | no |
| `updatePriceWithSig_burns_nonce` | [AsyncSwapUpdatePriceWithSig.lean:297](../../formal/Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean#L297) | [`AsyncSwapUpdatePriceWithSig.t.sol`](AsyncSwapUpdatePriceWithSig.t.sol) `testFuzz_updatePriceWithSig_burns_nonce` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `burn_asyncOrders` | [AsyncSwapUpdatePriceWithSig.lean:213](../../formal/Refinement/Swarm/AsyncSwapUpdatePriceWithSig.lean#L213) | model-only frame lemma about the Lean def `burn` |

### `Refinement/Swarm/AsyncSwapVerifyCallResultFromTarget.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `verify_run` | [AsyncSwapVerifyCallResultFromTarget.lean:19](../../formal/Refinement/Swarm/AsyncSwapVerifyCallResultFromTarget.lean#L19) | [`AsyncSwapVerifyCallResultFromTarget.t.sol`](AsyncSwapVerifyCallResultFromTarget.t.sol) `testFuzz_verify_run` | yes |
| `verify_ok_iff` | [AsyncSwapVerifyCallResultFromTarget.lean:32](../../formal/Refinement/Swarm/AsyncSwapVerifyCallResultFromTarget.lean#L32) | [`AsyncSwapVerifyCallResultFromTarget.t.sol`](AsyncSwapVerifyCallResultFromTarget.t.sol) `testFuzz_verify_ok_iff` | yes |
| `verify_frame` | [AsyncSwapVerifyCallResultFromTarget.lean:47](../../formal/Refinement/Swarm/AsyncSwapVerifyCallResultFromTarget.lean#L47) | [`AsyncSwapVerifyCallResultFromTarget.t.sol`](AsyncSwapVerifyCallResultFromTarget.t.sol) `testFuzz_verify_frame` | with edits |

### `Refinement/Swarm/FeeVaultCollect.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `collect_run` | [FeeVaultCollect.lean:31](../../formal/Refinement/Swarm/FeeVaultCollect.lean#L31) | [`FeeVaultCollect.t.sol`](FeeVaultCollect.t.sol) `testFuzz_collect_run` | no |
| `collect_owner_view_reverts` | [FeeVaultCollect.lean:58](../../formal/Refinement/Swarm/FeeVaultCollect.lean#L58) | [`FeeVaultCollect.t.sol`](FeeVaultCollect.t.sol) `testFuzz_collect_owner_view_reverts` | no |
| `collect_unauthorized` | [FeeVaultCollect.lean:64](../../formal/Refinement/Swarm/FeeVaultCollect.lean#L64) | [`FeeVaultCollect.t.sol`](FeeVaultCollect.t.sol) `testFuzz_collect_unauthorized` | yes |
| `collect_zero_recipient` | [FeeVaultCollect.lean:70](../../formal/Refinement/Swarm/FeeVaultCollect.lean#L70) | [`FeeVaultCollect.t.sol`](FeeVaultCollect.t.sol) `testFuzz_collect_zero_recipient` | yes |
| `collect_ok` | [FeeVaultCollect.lean:78](../../formal/Refinement/Swarm/FeeVaultCollect.lean#L78) | [`FeeVaultCollect.t.sol`](FeeVaultCollect.t.sol) `testFuzz_collect_ok` | no |
| `collect_only_owner` | [FeeVaultCollect.lean:101](../../formal/Refinement/Swarm/FeeVaultCollect.lean#L101) | [`FeeVaultCollect.t.sol`](FeeVaultCollect.t.sol) `testFuzz_collect_only_owner` | yes |
| `collect_reverts_iff` | [FeeVaultCollect.lean:108](../../formal/Refinement/Swarm/FeeVaultCollect.lean#L108) | [`FeeVaultCollect.t.sol`](FeeVaultCollect.t.sol) `testFuzz_collect_reverts_iff` | no |

### `Refinement/Swarm/FeeVaultUnlockCallback.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `unlockCallback_run` | [FeeVaultUnlockCallback.lean:59](../../formal/Refinement/Swarm/FeeVaultUnlockCallback.lean#L59) | [`FeeVaultUnlockCallback.t.sol`](FeeVaultUnlockCallback.t.sol) `testFuzz_unlockCallback_run` | no |
| `unlockCallback_unauthorized` | [FeeVaultUnlockCallback.lean:86](../../formal/Refinement/Swarm/FeeVaultUnlockCallback.lean#L86) | [`FeeVaultUnlockCallback.t.sol`](FeeVaultUnlockCallback.t.sol) `testFuzz_unlockCallback_unauthorized` | yes |
| `unlockCallback_badData` | [FeeVaultUnlockCallback.lean:92](../../formal/Refinement/Swarm/FeeVaultUnlockCallback.lean#L92) | [`FeeVaultUnlockCallback.t.sol`](FeeVaultUnlockCallback.t.sol) `testFuzz_unlockCallback_badData` | no |
| `unlockCallback_view_reverts` | [FeeVaultUnlockCallback.lean:98](../../formal/Refinement/Swarm/FeeVaultUnlockCallback.lean#L98) | [`FeeVaultUnlockCallback.t.sol`](FeeVaultUnlockCallback.t.sol) `testFuzz_unlockCallback_view_reverts` | no |
| `unlockCallback_zero` | [FeeVaultUnlockCallback.lean:105](../../formal/Refinement/Swarm/FeeVaultUnlockCallback.lean#L105) | [`FeeVaultUnlockCallback.t.sol`](FeeVaultUnlockCallback.t.sol) `testFuzz_unlockCallback_zero` | no |
| `unlockCallback_nonzero` | [FeeVaultUnlockCallback.lean:113](../../formal/Refinement/Swarm/FeeVaultUnlockCallback.lean#L113) | [`FeeVaultUnlockCallback.t.sol`](FeeVaultUnlockCallback.t.sol) `testFuzz_unlockCallback_nonzero` | no |
| `unlockCallback_ok` | [FeeVaultUnlockCallback.lean:125](../../formal/Refinement/Swarm/FeeVaultUnlockCallback.lean#L125) | [`FeeVaultUnlockCallback.t.sol`](FeeVaultUnlockCallback.t.sol) `testFuzz_unlockCallback_ok` | no |
| `unlockCallback_take_eq_own_balance` | [FeeVaultUnlockCallback.lean:165](../../formal/Refinement/Swarm/FeeVaultUnlockCallback.lean#L165) | [`FeeVaultUnlockCallback.t.sol`](FeeVaultUnlockCallback.t.sol) `testFuzz_unlockCallback_take_eq_own_balance` | no |
| `unlockCallback_burn_fails` | [FeeVaultUnlockCallback.lean:182](../../formal/Refinement/Swarm/FeeVaultUnlockCallback.lean#L182) | [`FeeVaultUnlockCallback.t.sol`](FeeVaultUnlockCallback.t.sol) `testFuzz_unlockCallback_burn_fails (ManagerLocked) + test_unlockCallback_burn_fails_overflow (SafeCastOverflow inside a real unlock)` | no |
| `unlockCallback_reverts_iff` | [FeeVaultUnlockCallback.lean:191](../../formal/Refinement/Swarm/FeeVaultUnlockCallback.lean#L191) | [`FeeVaultUnlockCallback.t.sol`](FeeVaultUnlockCallback.t.sol) `testFuzz_unlockCallback_reverts_iff` | no |

### `Refinement/Swarm/NativeClaimsRedeem.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `redeem_run` | [NativeClaimsRedeem.lean:29](../../formal/Refinement/Swarm/NativeClaimsRedeem.lean#L29) | [`NativeClaimsRedeem.t.sol`](NativeClaimsRedeem.t.sol) `testFuzz_redeem_run` | no |
| `redeem_reentrant` | [NativeClaimsRedeem.lean:53](../../formal/Refinement/Swarm/NativeClaimsRedeem.lean#L53) | [`NativeClaimsRedeem.t.sol`](NativeClaimsRedeem.t.sol) `testFuzz_redeem_reentrant` | yes |
| `redeem_invalid` | [NativeClaimsRedeem.lean:59](../../formal/Refinement/Swarm/NativeClaimsRedeem.lean#L59) | [`NativeClaimsRedeem.t.sol`](NativeClaimsRedeem.t.sol) `testFuzz_redeem_invalid` | yes |
| `redeem_ok` | [NativeClaimsRedeem.lean:67](../../formal/Refinement/Swarm/NativeClaimsRedeem.lean#L67) | [`NativeClaimsRedeem.t.sol`](NativeClaimsRedeem.t.sol) `testFuzz_redeem_ok` | no |
| `redeem_reverts_iff` | [NativeClaimsRedeem.lean:88](../../formal/Refinement/Swarm/NativeClaimsRedeem.lean#L88) | [`NativeClaimsRedeem.t.sol`](NativeClaimsRedeem.t.sol) `testFuzz_redeem_reverts_iff` | no |
| `redeem_ok_state` | [NativeClaimsRedeem.lean:109](../../formal/Refinement/Swarm/NativeClaimsRedeem.lean#L109) | [`NativeClaimsRedeem.t.sol`](NativeClaimsRedeem.t.sol) `testFuzz_redeem_ok_state` | no |
| `redeem_nested_reverts` | [NativeClaimsRedeem.lean:117](../../formal/Refinement/Swarm/NativeClaimsRedeem.lean#L117) | [`NativeClaimsRedeem.t.sol`](NativeClaimsRedeem.t.sol) `testFuzz_redeem_nested_reverts` | no |

### `Refinement/Swarm/NativeClaimsUnlockCallback.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `unlockCallback_run` | [NativeClaimsUnlockCallback.lean:46](../../formal/Refinement/Swarm/NativeClaimsUnlockCallback.lean#L46) | [`NativeClaimsUnlockCallback.t.sol`](NativeClaimsUnlockCallback.t.sol) `testFuzz_unlockCallback_run (locked) + testFuzz_unlockCallback_run_unlocked (via real unlock)` | no |
| `unlockCallback_onlyPoolManager` | [NativeClaimsUnlockCallback.lean:70](../../formal/Refinement/Swarm/NativeClaimsUnlockCallback.lean#L70) | [`NativeClaimsUnlockCallback.t.sol`](NativeClaimsUnlockCallback.t.sol) `testFuzz_unlockCallback_onlyPoolManager` | yes |
| `unlockCallback_badData` | [NativeClaimsUnlockCallback.lean:76](../../formal/Refinement/Swarm/NativeClaimsUnlockCallback.lean#L76) | [`NativeClaimsUnlockCallback.t.sol`](NativeClaimsUnlockCallback.t.sol) `testFuzz_unlockCallback_badData` | no |
| `unlockCallback_ok` | [NativeClaimsUnlockCallback.lean:85](../../formal/Refinement/Swarm/NativeClaimsUnlockCallback.lean#L85) | [`NativeClaimsUnlockCallback.t.sol`](NativeClaimsUnlockCallback.t.sol) `testFuzz_unlockCallback_ok` | no |
| `unlockCallback_burn_fails` | [NativeClaimsUnlockCallback.lean:112](../../formal/Refinement/Swarm/NativeClaimsUnlockCallback.lean#L112) | [`NativeClaimsUnlockCallback.t.sol`](NativeClaimsUnlockCallback.t.sol) `testFuzz_unlockCallback_burn_fails` | no |
| `unlockCallback_reverts_iff` | [NativeClaimsUnlockCallback.lean:119](../../formal/Refinement/Swarm/NativeClaimsUnlockCallback.lean#L119) | [`NativeClaimsUnlockCallback.t.sol`](NativeClaimsUnlockCallback.t.sol) `testFuzz_unlockCallback_reverts_iff` | no |
| `unlockCallback_ok_args` | [NativeClaimsUnlockCallback.lean:154](../../formal/Refinement/Swarm/NativeClaimsUnlockCallback.lean#L154) | [`NativeClaimsUnlockCallback.t.sol`](NativeClaimsUnlockCallback.t.sol) `testFuzz_unlockCallback_ok_args` | no |

### `Refinement/Swarm/RouterCancelWithSig.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `cancelWithSig_expired` | [RouterCancelWithSig.lean:107](../../formal/Refinement/Swarm/RouterCancelWithSig.lean#L107) | [`RouterCancelWithSig.t.sol`](RouterCancelWithSig.t.sol) `testFuzz_cancelWithSig_expired` | yes |
| `cancelWithSig_nonce_used` | [RouterCancelWithSig.lean:112](../../formal/Refinement/Swarm/RouterCancelWithSig.lean#L112) | [`RouterCancelWithSig.t.sol`](RouterCancelWithSig.t.sol) `testFuzz_cancelWithSig_nonce_used` | yes |
| `cancelWithSig_info_revert` | [RouterCancelWithSig.lean:118](../../formal/Refinement/Swarm/RouterCancelWithSig.lean#L118) | [`RouterCancelWithSig.t.sol`](RouterCancelWithSig.t.sol) `testFuzz_cancelWithSig_info_revert` | no |
| `cancelWithSig_invalid_sig` | [RouterCancelWithSig.lean:150](../../formal/Refinement/Swarm/RouterCancelWithSig.lean#L150) | [`RouterCancelWithSig.t.sol`](RouterCancelWithSig.t.sol) `testFuzz_cancelWithSig_invalid_sig` | no |
| `cancelWithSig_ok` | [RouterCancelWithSig.lean:163](../../formal/Refinement/Swarm/RouterCancelWithSig.lean#L163) | [`RouterCancelWithSig.t.sol`](RouterCancelWithSig.t.sol) `testFuzz_cancelWithSig_ok` | no |
| `cancelWithSig_ok_inv` | [RouterCancelWithSig.lean:178](../../formal/Refinement/Swarm/RouterCancelWithSig.lean#L178) | [`RouterCancelWithSig.t.sol`](RouterCancelWithSig.t.sol) `testFuzz_cancelWithSig_ok_inv` | no |
| `cancelWithSig_ok_state` | [RouterCancelWithSig.lean:224](../../formal/Refinement/Swarm/RouterCancelWithSig.lean#L224) | [`RouterCancelWithSig.t.sol`](RouterCancelWithSig.t.sol) `testFuzz_cancelWithSig_ok_state` | no |
| `cancelWithSig_reentry_reverts` | [RouterCancelWithSig.lean:254](../../formal/Refinement/Swarm/RouterCancelWithSig.lean#L254) | [`RouterCancelWithSig.t.sol`](RouterCancelWithSig.t.sol) `testFuzz_cancelWithSig_reentry_reverts` | with edits |
| `cancelWithSig_no_replay` | [RouterCancelWithSig.lean:266](../../formal/Refinement/Swarm/RouterCancelWithSig.lean#L266) | [`RouterCancelWithSig.t.sol`](RouterCancelWithSig.t.sol) `testFuzz_cancelWithSig_no_replay` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `ite_pair_fst` | [RouterCancelWithSig.lean:29](../../formal/Refinement/Swarm/RouterCancelWithSig.lean#L29) | model-only helper (simp lemma about the Lean monad / ABI encoding) |
| `ite_pair_snd` | [RouterCancelWithSig.lean:32](../../formal/Refinement/Swarm/RouterCancelWithSig.lean#L32) | model-only helper (simp lemma about the Lean monad / ABI encoding) |
| `tryRecover_preserves` | [RouterCancelWithSig.lean:38](../../formal/Refinement/Swarm/RouterCancelWithSig.lean#L38) | model-only helper (internal library `ECDSA.tryRecover` writes nothing; not externally callable; footprint covered by cancelWithSig_ok_state) |
| `tryRecover_5888_preserves` | [RouterCancelWithSig.lean:46](../../formal/Refinement/Swarm/RouterCancelWithSig.lean#L46) | model-only helper (internal `ECDSA.tryRecover` overload; covered by cancelWithSig_ok_state) |
| `isValidSignatureNow_preserves` | [RouterCancelWithSig.lean:56](../../formal/Refinement/Swarm/RouterCancelWithSig.lean#L56) | model-only helper (internal `SignatureChecker`; hypothesis on opaque `ext.fn_..._isValidERC1271SignatureNow`; covered by cancelWithSig_ok_state) |
| `hashTypedDataV4_preserves` | [RouterCancelWithSig.lean:71](../../formal/Refinement/Swarm/RouterCancelWithSig.lean#L71) | model-only helper (internal `_hashTypedDataV4`; hypothesis on opaque `ext.fn_MessageHashUtils_toTypedDataHash`) |
| `cancelWithSig_eq_prefix` | [RouterCancelWithSig.lean:127](../../formal/Refinement/Swarm/RouterCancelWithSig.lean#L127) | `*_run`-style unfolding into a Lean expression (observable content tested by _invalid_sig / _ok / _ok_inv) |
| `burn_frame` | [RouterCancelWithSig.lean:239](../../formal/Refinement/Swarm/RouterCancelWithSig.lean#L239) | model-only helper (about the Lean `burn` def; its EVM content is checked in cancelWithSig_ok_state) |

### `Refinement/Swarm/RouterConstructor.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `typeHash_eq` | [RouterConstructor.lean:66](../../formal/Refinement/Swarm/RouterConstructor.lean#L66) | [`RouterConstructor.t.sol`](RouterConstructor.t.sol) `test_typeHash_eq` | yes |
| `CtorSpec.name_word` | [RouterConstructor.lean:69](../../formal/Refinement/Swarm/RouterConstructor.lean#L69) | [`RouterConstructor.t.sol`](RouterConstructor.t.sol) `testFuzz_CtorSpec_name_word` | no |
| `CtorSpec.version_word` | [RouterConstructor.lean:74](../../formal/Refinement/Swarm/RouterConstructor.lean#L74) | [`RouterConstructor.t.sol`](RouterConstructor.t.sol) `testFuzz_CtorSpec_version_word` | no |
| `ctor_never_reverts` | [RouterConstructor.lean:79](../../formal/Refinement/Swarm/RouterConstructor.lean#L79) | [`RouterConstructor.t.sol`](RouterConstructor.t.sol) `testFuzz_ctor_never_reverts` | yes |
| `ctor_ok` | [RouterConstructor.lean:85](../../formal/Refinement/Swarm/RouterConstructor.lean#L85) | [`RouterConstructor.t.sol`](RouterConstructor.t.sol) `testFuzz_ctor_ok` | no |
| `ctor_deployed` | [RouterConstructor.lean:91](../../formal/Refinement/Swarm/RouterConstructor.lean#L91) | [`RouterConstructor.t.sol`](RouterConstructor.t.sol) `testFuzz_ctor_deployed` | no |
| `domainSeparatorV4_eq_built` | [RouterConstructor.lean:98](../../formal/Refinement/Swarm/RouterConstructor.lean#L98) | [`RouterConstructor.t.sol`](RouterConstructor.t.sol) `testFuzz_domainSeparatorV4_eq_built` | no |
| `DOMAIN_SEPARATOR_eq_built` | [RouterConstructor.lean:112](../../formal/Refinement/Swarm/RouterConstructor.lean#L112) | [`RouterConstructor.t.sol`](RouterConstructor.t.sol) `testFuzz_DOMAIN_SEPARATOR_eq_built` | no |
| `DOMAIN_SEPARATOR_deployed` | [RouterConstructor.lean:126](../../formal/Refinement/Swarm/RouterConstructor.lean#L126) | [`RouterConstructor.t.sol`](RouterConstructor.t.sol) `testFuzz_DOMAIN_SEPARATOR_deployed` | no |

### `Refinement/Swarm/RouterDOMAIN_SEPARATOR.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `DOMAIN_SEPARATOR_spec` | [RouterDOMAIN_SEPARATOR.lean:29](../../formal/Refinement/Swarm/RouterDOMAIN_SEPARATOR.lean#L29) | [`RouterDOMAIN_SEPARATOR.t.sol`](RouterDOMAIN_SEPARATOR.t.sol) `testFuzz_DOMAIN_SEPARATOR_spec` | with edits |
| `DOMAIN_SEPARATOR_never_reverts` | [RouterDOMAIN_SEPARATOR.lean:40](../../formal/Refinement/Swarm/RouterDOMAIN_SEPARATOR.lean#L40) | [`RouterDOMAIN_SEPARATOR.t.sol`](RouterDOMAIN_SEPARATOR.t.sol) `testFuzz_DOMAIN_SEPARATOR_never_reverts` | yes |
| `DOMAIN_SEPARATOR_preserves` | [RouterDOMAIN_SEPARATOR.lean:45](../../formal/Refinement/Swarm/RouterDOMAIN_SEPARATOR.lean#L45) | [`RouterDOMAIN_SEPARATOR.t.sol`](RouterDOMAIN_SEPARATOR.t.sol) `testFuzz_DOMAIN_SEPARATOR_preserves` | with edits |

### `Refinement/Swarm/RouterEip712Domain.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `EIP712Name_spec` | [RouterEip712Domain.lean:47](../../formal/Refinement/Swarm/RouterEip712Domain.lean#L47) | [`Eip712Domain.t.sol`](Eip712Domain.t.sol) `RouterEip712DomainFormalTest.testFuzz_EIP712Name_spec` | with edits |
| `EIP712Version_spec` | [RouterEip712Domain.lean:55](../../formal/Refinement/Swarm/RouterEip712Domain.lean#L55) | [`Eip712Domain.t.sol`](Eip712Domain.t.sol) `RouterEip712DomainFormalTest.testFuzz_EIP712Version_spec` | with edits |
| `eip712Domain_spec` | [RouterEip712Domain.lean:63](../../formal/Refinement/Swarm/RouterEip712Domain.lean#L63) | [`Eip712Domain.t.sol`](Eip712Domain.t.sol) `RouterEip712DomainFormalTest.testFuzz_eip712Domain_spec` | with edits |
| `eip712Domain_never_reverts` | [RouterEip712Domain.lean:70](../../formal/Refinement/Swarm/RouterEip712Domain.lean#L70) | [`Eip712Domain.t.sol`](Eip712Domain.t.sol) `RouterEip712DomainFormalTest.testFuzz_eip712Domain_never_reverts` | yes |
| `eip712Domain_ok` | [RouterEip712Domain.lean:75](../../formal/Refinement/Swarm/RouterEip712Domain.lean#L75) | [`Eip712Domain.t.sol`](Eip712Domain.t.sol) `RouterEip712DomainFormalTest.testFuzz_eip712Domain_ok` | with edits |
| `eip712Domain_short` | [RouterEip712Domain.lean:85](../../formal/Refinement/Swarm/RouterEip712Domain.lean#L85) | [`Eip712Domain.t.sol`](Eip712Domain.t.sol) `RouterEip712DomainFormalTest.testFuzz_eip712Domain_short` | yes |
| `eip712Domain_matches_DOMAIN_SEPARATOR` | [RouterEip712Domain.lean:93](../../formal/Refinement/Swarm/RouterEip712Domain.lean#L93) | [`Eip712Domain.t.sol`](Eip712Domain.t.sol) `RouterEip712DomainFormalTest.testFuzz_eip712Domain_matches_DOMAIN_SEPARATOR` | yes |

### `Refinement/Swarm/RouterFillFromPoolLiquidity.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `fillFromPoolLiquidity_eq` | [RouterFillFromPoolLiquidity.lean:28](../../formal/Refinement/Swarm/RouterFillFromPoolLiquidity.lean#L28) | [`RouterFillFromPoolLiquidity.t.sol`](RouterFillFromPoolLiquidity.t.sol) `testFuzz_fillFromPoolLiquidity_eq` | no |
| `fillFromPoolLiquidity_revert_iff` | [RouterFillFromPoolLiquidity.lean:37](../../formal/Refinement/Swarm/RouterFillFromPoolLiquidity.lean#L37) | [`RouterFillFromPoolLiquidity.t.sol`](RouterFillFromPoolLiquidity.t.sol) `testFuzz_fillFromPoolLiquidity_revert_iff` | no |
| `fillFromPoolLiquidity_ok_iff` | [RouterFillFromPoolLiquidity.lean:48](../../formal/Refinement/Swarm/RouterFillFromPoolLiquidity.lean#L48) | [`RouterFillFromPoolLiquidity.t.sol`](RouterFillFromPoolLiquidity.t.sol) `testFuzz_fillFromPoolLiquidity_ok_iff` | no |
| `fillFromPoolLiquidityPre_get` | [RouterFillFromPoolLiquidity.lean:58](../../formal/Refinement/Swarm/RouterFillFromPoolLiquidity.lean#L58) | [`RouterFillFromPoolLiquidity.t.sol`](RouterFillFromPoolLiquidity.t.sol) `testFuzz_fillFromPoolLiquidityPre_get` | no |

### `Refinement/Swarm/RouterHelpers.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `bubbleUpAndRevertWith_reverts` | [RouterHelpers.lean:21](../../formal/Refinement/Swarm/RouterHelpers.lean#L21) | [`RouterHelpers.t.sol`](RouterHelpers.t.sol) `testFuzz_bubbleUpAndRevertWith_reverts` | yes |
| `address_revert_run` | [RouterHelpers.lean:25](../../formal/Refinement/Swarm/RouterHelpers.lean#L25) | [`RouterHelpers.t.sol`](RouterHelpers.t.sol) `testFuzz_address_revert_run` | yes |
| `verifyCallResult_fail` | [RouterHelpers.lean:31](../../formal/Refinement/Swarm/RouterHelpers.lean#L31) | [`RouterHelpers.t.sol`](RouterHelpers.t.sol) `testFuzz_verifyCallResult_fail` | yes |
| `verifyCallResult_ok` | [RouterHelpers.lean:37](../../formal/Refinement/Swarm/RouterHelpers.lean#L37) | [`RouterHelpers.t.sol`](RouterHelpers.t.sol) `testFuzz_verifyCallResult_ok` | yes |
| `functionCallWithValue_insufficient` | [RouterHelpers.lean:43](../../formal/Refinement/Swarm/RouterHelpers.lean#L43) | [`RouterHelpers.t.sol`](RouterHelpers.t.sol) `testFuzz_functionCallWithValue_insufficient` | yes |
| `functionCallWithValue_eq` | [RouterHelpers.lean:48](../../formal/Refinement/Swarm/RouterHelpers.lean#L48) | [`RouterHelpers.t.sol`](RouterHelpers.t.sol) `testFuzz_functionCallWithValue_eq` | yes |
| `functionCall_eq` | [RouterHelpers.lean:54](../../formal/Refinement/Swarm/RouterHelpers.lean#L54) | [`RouterHelpers.t.sol`](RouterHelpers.t.sol) `testFuzz_functionCall_eq` | yes |
| `callOptionalReturn_after` | [RouterHelpers.lean:63](../../formal/Refinement/Swarm/RouterHelpers.lean#L63) | [`RouterHelpers.t.sol`](RouterHelpers.t.sol) `testFuzz_callOptionalReturn_after` | yes |
| `callOptionalReturn_call_reverts` | [RouterHelpers.lean:87](../../formal/Refinement/Swarm/RouterHelpers.lean#L87) | [`RouterHelpers.t.sol`](RouterHelpers.t.sol) `testFuzz_callOptionalReturn_call_reverts` | yes |
| `safeTransferFrom_eq` | [RouterHelpers.lean:94](../../formal/Refinement/Swarm/RouterHelpers.lean#L94) | [`RouterHelpers.t.sol`](RouterHelpers.t.sol) `testFuzz_safeTransferFrom_eq` | yes |
| `byteLength_run` | [RouterHelpers.lean:104](../../formal/Refinement/Swarm/RouterHelpers.lean#L104) | [`RouterHelpers.t.sol`](RouterHelpers.t.sol) `testFuzz_byteLength_run` | yes |
| `byteLength_le` | [RouterHelpers.lean:110](../../formal/Refinement/Swarm/RouterHelpers.lean#L110) | [`RouterHelpers.t.sol`](RouterHelpers.t.sol) `testFuzz_byteLength_le` | yes |
| `eip712Name_eq` | [RouterHelpers.lean:117](../../formal/Refinement/Swarm/RouterHelpers.lean#L117) | [`RouterHelpers.t.sol`](RouterHelpers.t.sol) `testFuzz_eip712Name_eq` | no |
| `eip712Version_eq` | [RouterHelpers.lean:125](../../formal/Refinement/Swarm/RouterHelpers.lean#L125) | [`RouterHelpers.t.sol`](RouterHelpers.t.sol) `testFuzz_eip712Version_eq` | no |

### `Refinement/Swarm/RouterLibHelpers.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `revert_run` | [RouterLibHelpers.lean:27](../../formal/Refinement/Swarm/RouterLibHelpers.lean#L27) | [`RouterLibHelpers.t.sol`](RouterLibHelpers.t.sol) `testFuzz_revert_run` | yes |
| `revert_never_ok` | [RouterLibHelpers.lean:33](../../formal/Refinement/Swarm/RouterLibHelpers.lean#L33) | [`RouterLibHelpers.t.sol`](RouterLibHelpers.t.sol) `testFuzz_revert_never_ok` | yes |
| `verify_run` | [RouterLibHelpers.lean:37](../../formal/Refinement/Swarm/RouterLibHelpers.lean#L37) | [`RouterLibHelpers.t.sol`](RouterLibHelpers.t.sol) `testFuzz_verify_run` | yes |
| `verify_ok_iff` | [RouterLibHelpers.lean:47](../../formal/Refinement/Swarm/RouterLibHelpers.lean#L47) | [`RouterLibHelpers.t.sol`](RouterLibHelpers.t.sol) `testFuzz_verify_ok_iff` | yes |
| `functionCallWithValue_run` | [RouterLibHelpers.lean:54](../../formal/Refinement/Swarm/RouterLibHelpers.lean#L54) | [`RouterLibHelpers.t.sol`](RouterLibHelpers.t.sol) `testFuzz_functionCallWithValue_run` | yes |
| `functionCall_run` | [RouterLibHelpers.lean:68](../../formal/Refinement/Swarm/RouterLibHelpers.lean#L68) | [`RouterLibHelpers.t.sol`](RouterLibHelpers.t.sol) `testFuzz_functionCall_run` | yes |
| `callOptionalReturn_run` | [RouterLibHelpers.lean:85](../../formal/Refinement/Swarm/RouterLibHelpers.lean#L85) | [`RouterLibHelpers.t.sol`](RouterLibHelpers.t.sol) `testFuzz_callOptionalReturn_run` | yes |
| `safeTransferFrom_run` | [RouterLibHelpers.lean:106](../../formal/Refinement/Swarm/RouterLibHelpers.lean#L106) | [`RouterLibHelpers.t.sol`](RouterLibHelpers.t.sol) `testFuzz_safeTransferFrom_run` | yes |
| `safeTransferFrom_ok` | [RouterLibHelpers.lean:116](../../formal/Refinement/Swarm/RouterLibHelpers.lean#L116) | [`RouterLibHelpers.t.sol`](RouterLibHelpers.t.sol) `testFuzz_safeTransferFrom_ok` | yes |
| `bubbleUpAndRevertWith_run` | [RouterLibHelpers.lean:134](../../formal/Refinement/Swarm/RouterLibHelpers.lean#L134) | [`RouterLibHelpers.t.sol`](RouterLibHelpers.t.sol) `testFuzz_bubbleUpAndRevertWith_run` | yes |
| `byteLength_run` | [RouterLibHelpers.lean:138](../../formal/Refinement/Swarm/RouterLibHelpers.lean#L138) | [`RouterLibHelpers.t.sol`](RouterLibHelpers.t.sol) `testFuzz_byteLength_run` | yes |
| `byteLength_ok` | [RouterLibHelpers.lean:144](../../formal/Refinement/Swarm/RouterLibHelpers.lean#L144) | [`RouterLibHelpers.t.sol`](RouterLibHelpers.t.sol) `testFuzz_byteLength_ok` | yes |
| `EIP712Name_run` | [RouterLibHelpers.lean:157](../../formal/Refinement/Swarm/RouterLibHelpers.lean#L157) | [`RouterLibHelpers.t.sol`](RouterLibHelpers.t.sol) `testFuzz_EIP712Name_run` | no |
| `EIP712Version_run` | [RouterLibHelpers.lean:165](../../formal/Refinement/Swarm/RouterLibHelpers.lean#L165) | [`RouterLibHelpers.t.sol`](RouterLibHelpers.t.sol) `testFuzz_EIP712Version_run` | no |

### `Refinement/Swarm/RouterMatchBook.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `matchBook_eq` | [RouterMatchBook.lean:27](../../formal/Refinement/Swarm/RouterMatchBook.lean#L27) | [`RouterMatchBook.t.sol`](RouterMatchBook.t.sol) `testFuzz_matchBook_eq` | no |
| `matchBook_revert_iff` | [RouterMatchBook.lean:34](../../formal/Refinement/Swarm/RouterMatchBook.lean#L34) | [`RouterMatchBook.t.sol`](RouterMatchBook.t.sol) `testFuzz_matchBook_revert_iff` | no |
| `matchBook_ok_iff` | [RouterMatchBook.lean:43](../../formal/Refinement/Swarm/RouterMatchBook.lean#L43) | [`RouterMatchBook.t.sol`](RouterMatchBook.t.sol) `testFuzz_matchBook_ok_iff` | no |

### `Refinement/Swarm/RouterSwapWithSig.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `swapWithSig_native` | [RouterSwapWithSig.lean:47](../../formal/Refinement/Swarm/RouterSwapWithSig.lean#L47) | [`RouterSwapWithSig.t.sol`](RouterSwapWithSig.t.sol) `testFuzz_swapWithSig_native` | yes |
| `swapWithSig_noGrant` | [RouterSwapWithSig.lean:55](../../formal/Refinement/Swarm/RouterSwapWithSig.lean#L55) | [`RouterSwapWithSig.t.sol`](RouterSwapWithSig.t.sol) `testFuzz_swapWithSig_noGrant` | no |
| `swapWithSig_alreadyExecutor` | [RouterSwapWithSig.lean:64](../../formal/Refinement/Swarm/RouterSwapWithSig.lean#L64) | [`RouterSwapWithSig.t.sol`](RouterSwapWithSig.t.sol) `testFuzz_swapWithSig_alreadyExecutor` | no |
| `swapWithSig_isExecutor_revert` | [RouterSwapWithSig.lean:75](../../formal/Refinement/Swarm/RouterSwapWithSig.lean#L75) | [`RouterSwapWithSig.t.sol`](RouterSwapWithSig.t.sol) `testFuzz_swapWithSig_isExecutor_revert` | no |
| `swapWithSig_grant` | [RouterSwapWithSig.lean:88](../../formal/Refinement/Swarm/RouterSwapWithSig.lean#L88) | [`RouterSwapWithSig.t.sol`](RouterSwapWithSig.t.sol) `testFuzz_swapWithSig_grant` | no |
| `swapWithSig_ok_input` | [RouterSwapWithSig.lean:107](../../formal/Refinement/Swarm/RouterSwapWithSig.lean#L107) | [`RouterSwapWithSig.t.sol`](RouterSwapWithSig.t.sol) `testFuzz_swapWithSig_ok_input` | no |
| `swapWithSigPre_get` | [RouterSwapWithSig.lean:116](../../formal/Refinement/Swarm/RouterSwapWithSig.lean#L116) | [`RouterSwapWithSig.t.sol`](RouterSwapWithSig.t.sol) `testFuzz_swapWithSigPre_get` | no |
| `swapWithSigPre_user` | [RouterSwapWithSig.lean:124](../../formal/Refinement/Swarm/RouterSwapWithSig.lean#L124) | [`RouterSwapWithSig.t.sol`](RouterSwapWithSig.t.sol) `testFuzz_swapWithSigPre_user` | no |
| `swapWithSigPre_filler` | [RouterSwapWithSig.lean:130](../../formal/Refinement/Swarm/RouterSwapWithSig.lean#L130) | [`RouterSwapWithSig.t.sol`](RouterSwapWithSig.t.sol) `testFuzz_swapWithSigPre_filler` | no |

### `Refinement/Swarm/SpecBook.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `remove_queue` | [SpecBook.lean:516](../../formal/Refinement/Swarm/SpecBook.lean#L516) | [`SpecBook.t.sol`](SpecBook.t.sol) `testFuzz_remove_queue` | no |
| `queue_append` | [SpecBook.lean:560](../../formal/Refinement/Swarm/SpecBook.lean#L560) | [`SpecBook.t.sol`](SpecBook.t.sol) `testFuzz_append_queue` | no |
| `append_queue` | [SpecBook.lean:640](../../formal/Refinement/Swarm/SpecBook.lean#L640) | [`SpecBook.t.sol`](SpecBook.t.sol) `testFuzz_append_queue` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `levels_setLevel` | [SpecBook.lean:76](../../formal/Refinement/Swarm/SpecBook.lean#L76) | model-only simp lemma about the spec's own defs |
| `levels_setSide` | [SpecBook.lean:80](../../formal/Refinement/Swarm/SpecBook.lean#L80) | model-only simp lemma |
| `levels_openOrderCount` | [SpecBook.lean:84](../../formal/Refinement/Swarm/SpecBook.lean#L84) | model-only simp lemma |
| `liftR_ok` | [SpecBook.lean:108](../../formal/Refinement/Swarm/SpecBook.lean#L108) | model-only helper (`Except` plumbing) |
| `lawful_canonical` | [SpecBook.lean:126](../../formal/Refinement/Swarm/SpecBook.lean#L126) | model-only: the canonical pointers satisfy the lens laws, given `ext.get ∘ ext.set = id` |
| `writes_frame` | [SpecBook.lean:145](../../formal/Refinement/Swarm/SpecBook.lean#L145) | model-only consequence of `Writes`; on the bytecode, the frame is the write-set check in testFuzz_RemoveSpec_post / testFuzz_AppendSpec_post |
| `BestAtPriceSpec.run` | [SpecBook.lean:248](../../formal/Refinement/Swarm/SpecBook.lean#L248) | derived from the spec's fields; its content is testFuzz_BestAtPriceSpec_{fifo,priority,badMode} |
| `BestAtPriceSpec.readOnly` | [SpecBook.lean:259](../../formal/Refinement/Swarm/SpecBook.lean#L259) | derived from the fields; the no-writes check is in testFuzz_BestAtPriceSpec_{fifo,priority} |
| `LevelSpec.run` | [SpecBook.lean:266](../../formal/Refinement/Swarm/SpecBook.lean#L266) | derived from the fields; its content is testFuzz_LevelSpec_* |
| `LevelSpec.readOnly` | [SpecBook.lean:277](../../formal/Refinement/Swarm/SpecBook.lean#L277) | derived from the fields; the no-writes check is in testFuzz_LevelSpec_{fifo,priority} |
| `RemoveSpec.ok_iff` | [SpecBook.lean:455](../../formal/Refinement/Swarm/SpecBook.lean#L455) | derived from `reverts` + `progress` (both tested) |
| `removeState_prio` | [SpecBook.lean:466](../../formal/Refinement/Swarm/SpecBook.lean#L466) | property of the spec's def; on the bytecode it is checked in testFuzz_RemoveSpec_post (every order compared) |
| `removeState_linksOnly` | [SpecBook.lean:470](../../formal/Refinement/Swarm/SpecBook.lean#L470) | property of the spec's def; covered by testFuzz_RemoveSpec_post (whole records compared) |
| `appendOrders_linksOnly` | [SpecBook.lean:481](../../formal/Refinement/Swarm/SpecBook.lean#L481) | property of the spec's def; covered by testFuzz_AppendSpec_post |
| `appendState_keeps` | [SpecBook.lean:491](../../formal/Refinement/Swarm/SpecBook.lean#L491) | property of the spec's def; covered by testFuzz_AppendSpec_post |
| `seg_upd_out` | [SpecBook.lean:544](../../formal/Refinement/Swarm/SpecBook.lean#L544) | model-only list lemma |
| `queue_upd_out` | [SpecBook.lean:554](../../formal/Refinement/Swarm/SpecBook.lean#L554) | model-only list lemma |

### `Refinement/Swarm/SpecBookCallers.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `addOrder_queue_of_spec` | [SpecBookCallers.lean:253](../../formal/Refinement/Swarm/SpecBookCallers.lean#L253) | [`SpecBook.t.sol`](SpecBook.t.sol) `testFuzz_addOrder_queue_of_spec` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `remove_canonical` | [SpecBookCallers.lean:38](../../formal/Refinement/Swarm/SpecBookCallers.lean#L38) | `RemoveSpec` at the canonical pointers; its content is the spec's tests |
| `append_canonical` | [SpecBookCallers.lean:57](../../formal/Refinement/Swarm/SpecBookCallers.lean#L57) | `AppendSpec` at the canonical pointers; its content is the spec's tests |
| `bestOrder_readOnly_of_spec` | [SpecBookCallers.lean:84](../../formal/Refinement/Swarm/SpecBookCallers.lean#L84) | wrapper; its content is the spec's test plus bestOrder_readOnly's test |
| `bestOrder_ok_of_spec` | [SpecBookCallers.lean:95](../../formal/Refinement/Swarm/SpecBookCallers.lean#L95) | wrapper (bestOrder_ok + BestAtPriceSpec.run) |
| `orderBookLevel_readOnly_of_spec` | [SpecBookCallers.lean:121](../../formal/Refinement/Swarm/SpecBookCallers.lean#L121) | wrapper |
| `orderBookLevel_run_of_spec` | [SpecBookCallers.lean:131](../../formal/Refinement/Swarm/SpecBookCallers.lean#L131) | wrapper (orderBookLevel_run + LevelSpec.run); replaces orderBookLevel_view, whose `hlevel` ("never reverts") the bytecode doesn't meet (see Notes) |
| `orderBookLevel_fifo_of_spec` | [SpecBookCallers.lean:139](../../formal/Refinement/Swarm/SpecBookCallers.lean#L139) | wrapper; orderBookLevel_view's FIFO case |
| `liftR_map_fst` | [SpecBookCallers.lean:145](../../formal/Refinement/Swarm/SpecBookCallers.lean#L145) | model-only helper |
| `orderBookLevel_congr_of_spec` | [SpecBookCallers.lean:151](../../formal/Refinement/Swarm/SpecBookCallers.lean#L151) | wrapper |
| `keepsNonces_remove` | [SpecBookCallers.lean:160](../../formal/Refinement/Swarm/SpecBookCallers.lean#L160) | bridge: the old `hrem` hypothesis derived from `RemoveSpec.post`; its content is the spec's write-set test |
| `keepsNonces_append` | [SpecBookCallers.lean:168](../../formal/Refinement/Swarm/SpecBookCallers.lean#L168) | bridge: the old `happ` hypothesis derived from `AppendSpec.post` |
| `updatePriceWithSig_burns_nonce_of_spec` | [SpecBookCallers.lean:177](../../formal/Refinement/Swarm/SpecBookCallers.lean#L177) | wrapper |
| `levels_nextSequence` | [SpecBookCallers.lean:191](../../formal/Refinement/Swarm/SpecBookCallers.lean#L191) | model-only simp lemma |
| `addOrder_ok_of_spec` | [SpecBookCallers.lean:201](../../formal/Refinement/Swarm/SpecBookCallers.lean#L201) | wrapper (addOrder_ok + AppendSpec.post) |
| `updatePrice_ok_of_spec` | [SpecBookCallers.lean:306](../../formal/Refinement/Swarm/SpecBookCallers.lean#L306) | wrapper (updatePrice_ok + both specs) |
| `cancelOrder_ok_of_spec` | [SpecBookCallers.lean:360](../../formal/Refinement/Swarm/SpecBookCallers.lean#L360) | wrapper (cancelOrder_ok + RemoveSpec) |
| `cancelOrder_queue_of_spec` | [SpecBookCallers.lean:398](../../formal/Refinement/Swarm/SpecBookCallers.lean#L398) | wrapper (cancelOrder_ok + remove_queue, which is tested) |
| `recordPriorityFee_escrowed_of_spec` | [SpecBookCallers.lean:429](../../formal/Refinement/Swarm/SpecBookCallers.lean#L429) | wrapper (recordPriorityFee_ok + both specs + recordPriorityFee_escrowed_reverts) |

### `Refinement/Swarm/SpecCoreAsyncSwap.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `createBody_frame` | [SpecCoreAsyncSwap.lean:167](../../formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L167) | [`SpecCore.t.sol`](SpecCore.t.sol) `testFuzz_createBody_frame` | no |
| `beforeSwap_frame_of_spec` | [SpecCoreAsyncSwap.lean:262](../../formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L262) | [`SpecCore.t.sol`](SpecCore.t.sol) `testFuzz_beforeSwap_frame_of_spec` | no |
| `TransferSpec.ok_iff` | [SpecCoreAsyncSwap.lean:357](../../formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L357) | [`SpecCore.t.sol`](SpecCore.t.sol) `testFuzz_TransferSpec_ok_iff` | no |
| `TransferSpec.frame` | [SpecCoreAsyncSwap.lean:376](../../formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L376) | [`SpecCore.t.sol`](SpecCore.t.sol) `testFuzz_TransferSpec_frame` | no |
| `getLiquidity_of_spec` | [SpecCoreAsyncSwap.lean:414](../../formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L414) | [`SpecCore.t.sol`](SpecCore.t.sol) `testFuzz_getLiquidity_of_spec` | no |
| `getSlot0_of_spec` | [SpecCoreAsyncSwap.lean:439](../../formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L439) | [`SpecCore.t.sol`](SpecCore.t.sol) `testFuzz_getSlot0_of_spec` | no |
| `getLiquidity_zero_of_spec` | [SpecCoreAsyncSwap.lean:453](../../formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L453) | [`SpecCore.t.sol`](SpecCore.t.sol) `testFuzz_getLiquidity_zero_of_spec` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `StopsAt.unique` | [SpecCoreAsyncSwap.lean:125](../../formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L125) | model-only helper (logic over the spec's `StopsAt`) |
| `PoolFrame.trans` | [SpecCoreAsyncSwap.lean:142](../../formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L142) | model-only helper |
| `PoolFrame.of_eq` | [SpecCoreAsyncSwap.lean:152](../../formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L152) | model-only helper |
| `beforeSwap_notAuthorised_of_spec` | [SpecCoreAsyncSwap.lean:210](../../formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L210) | wrapper; its content is the spec's test (`testFuzz_CreateOrderSpec_notAuthorised`, which runs through `beforeSwap`) + `beforeSwap_run_ok`'s test |
| `beforeSwap_zeroAmount_of_spec` | [SpecCoreAsyncSwap.lean:221](../../formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L221) | wrapper; its content is the spec's test + `beforeSwap_run_ok`'s test |
| `beforeSwap_run_of_spec` | [SpecCoreAsyncSwap.lean:236](../../formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L236) | wrapper; its content is the spec's test (`testFuzz_CreateOrderSpec_run`) + `beforeSwap_run_ok`'s test |
| `bubbleUp_error` | [SpecCoreAsyncSwap.lean:351](../../formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L351) | model-only helper (the generated `bubbleUpAndRevertWith` always throws); the bytecode revert data is checked in every failing-transfer test and in `AsyncSwapBubbleUpAndRevertWith.t.sol` |
| `sweep_storage_unchanged_of_spec` | [SpecCoreAsyncSwap.lean:386](../../formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L386) | wrapper; its content is the spec's test (`testFuzz_TransferSpec_viaSweep` asserts no hook SSTORE) + `sweep_storage_unchanged`'s test |
| `PoolStateSlotSpec.eq` | [SpecCoreAsyncSwap.lean:407](../../formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L407) | corollary of the two spec fields; its content is their tests |
| `swapAgainstPool_noLiquidity_of_spec` | [SpecCoreAsyncSwap.lean:465](../../formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L465) | wrapper; its content is `getLiquidity_zero_of_spec`'s test + `swapAgainstPool_noLiquidity`'s test |
| `fillOrderFromPoolLiquidity_noLiquidity_of_spec` | [SpecCoreAsyncSwap.lean:478](../../formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L478) | wrapper; its content is `getLiquidity_zero_of_spec`'s test + `fillOrderFromPoolLiquidity_noLiquidity`'s test |
| `swapAgainstPool_spec_of_spec` | [SpecCoreAsyncSwap.lean:494](../../formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L494) | wrapper; its content is the `getLiquidity_of_spec` / `getSlot0_of_spec` tests + `swapAgainstPool_spec`'s test |

### `Refinement/Swarm/SpecCoreRouter.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `TransferSpec.ok_iff` | [SpecCoreRouter.lean:77](../../formal/Refinement/Swarm/SpecCoreRouter.lean#L77) | [`SpecCore.t.sol`](SpecCore.t.sol) `testFuzz_Router_TransferSpec_ok_iff` | no |
| `TransferSpec.frame` | [SpecCoreRouter.lean:97](../../formal/Refinement/Swarm/SpecCoreRouter.lean#L97) | [`SpecCore.t.sol`](SpecCore.t.sol) `testFuzz_Router_TransferSpec_frame` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `bubbleUp_error` | [SpecCoreRouter.lean:71](../../formal/Refinement/Swarm/SpecCoreRouter.lean#L71) | model-only helper |
| `settle_selfPay_ok_iff_of_spec` | [SpecCoreRouter.lean:110](../../formal/Refinement/Swarm/SpecCoreRouter.lean#L110) | bridge from the spec through the generated `CurrencySettler.settle`. The Router calls `settle` only with `payer = user` (src/Router.sol), so this branch runs only if the user is the Router itself. Its content is the Router `TransferSpec` tests |

### `Refinement/Swarm/SpecEip712AsyncSwap.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `CtorSpec.name_word` | [SpecEip712AsyncSwap.lean:61](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L61) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `testFuzz_CtorSpec_name_word` | no |
| `CtorSpec.version_word` | [SpecEip712AsyncSwap.lean:66](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L66) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `testFuzz_CtorSpec_version_word` | no |
| `DOMAIN_SEPARATOR_deployed` | [SpecEip712AsyncSwap.lean:72](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L72) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `testFuzz_DOMAIN_SEPARATOR_deployed` | no |
| `Eip712DomainSpec.domainSpec` | [SpecEip712AsyncSwap.lean:161](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L161) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `testFuzz_Eip712DomainSpec_body (AsyncSwapSpecEip712FormalTest)` | no |
| `byteLength_eq` | [SpecEip712AsyncSwap.lean:165](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L165) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `testFuzz_byteLength_eq` | yes |
| `toString_reverts_iff_byteLength` | [SpecEip712AsyncSwap.lean:176](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L176) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `testFuzz_toString_reverts_iff_byteLength` | yes |
| `toString_eq` | [SpecEip712AsyncSwap.lean:186](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L186) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `testFuzz_toString_eq` | no |
| `toString_name` | [SpecEip712AsyncSwap.lean:197](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L197) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `testFuzz_toString_name (AsyncSwapSpecEip712FormalTest)` | no |
| `toString_version` | [SpecEip712AsyncSwap.lean:204](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L204) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `testFuzz_toString_version (AsyncSwapSpecEip712FormalTest)` | no |
| `name_ne_sentinel` | [SpecEip712AsyncSwap.lean:210](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L210) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `testFuzz_name_ne_sentinel (AsyncSwapSpecEip712FormalTest)` | no |
| `version_ne_sentinel` | [SpecEip712AsyncSwap.lean:214](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L214) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `testFuzz_version_ne_sentinel (AsyncSwapSpecEip712FormalTest)` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `ctor_invalidNumeraire_of_spec` | [SpecEip712AsyncSwap.lean:81](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L81) | wrapper; its content is CtorSpec's test plus AsyncSwapConstructor.t.sol: testFuzz_ctor_invalidNumeraire |
| `ctor_zeroOwner_of_spec` | [SpecEip712AsyncSwap.lean:86](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L86) | wrapper; CtorSpec's test plus testFuzz_ctor_zeroOwner |
| `ctor_reverts_iff_of_spec` | [SpecEip712AsyncSwap.lean:91](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L91) | wrapper; CtorSpec's test plus testFuzz_ctor_reverts_iff |
| `ctor_ok_iff_of_spec` | [SpecEip712AsyncSwap.lean:97](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L97) | wrapper; CtorSpec's test plus testFuzz_ctor_ok_iff |
| `ctor_fresh_state_of_spec` | [SpecEip712AsyncSwap.lean:103](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L103) | wrapper; CtorSpec's test plus testFuzz_ctor_fresh_state |
| `ctor_deployed_of_spec` | [SpecEip712AsyncSwap.lean:112](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L112) | wrapper; CtorSpec's test plus testFuzz_ctor_deployed |
| `domainSeparatorV4_eq_built_of_spec` | [SpecEip712AsyncSwap.lean:119](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L119) | wrapper; CtorSpec's test plus testFuzz_domainSeparatorV4_eq_built |
| `DOMAIN_SEPARATOR_eq_built_of_spec` | [SpecEip712AsyncSwap.lean:124](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L124) | wrapper; CtorSpec's test plus testFuzz_DOMAIN_SEPARATOR_eq_built |
| `EIP712Name_of_spec` | [SpecEip712AsyncSwap.lean:220](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L220) | wrapper of `EIP712Name_spec`, concrete name; its content is the specs' tests plus Eip712Domain.t.sol: testFuzz_EIP712Name_spec |
| `EIP712Version_of_spec` | [SpecEip712AsyncSwap.lean:225](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L225) | wrapper; specs' tests plus testFuzz_EIP712Version_spec |
| `eip712Domain_spec_of_spec` | [SpecEip712AsyncSwap.lean:230](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L230) | wrapper; specs' tests plus testFuzz_eip712Domain_spec |
| `eip712Domain_never_reverts_of_spec` | [SpecEip712AsyncSwap.lean:237](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L237) | wrapper; specs' tests plus testFuzz_eip712Domain_never_reverts |
| `eip712Domain_ok_of_spec` | [SpecEip712AsyncSwap.lean:242](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L242) | wrapper; specs' tests plus testFuzz_eip712Domain_ok |
| `eip712Domain_matches_DOMAIN_SEPARATOR_of_spec` | [SpecEip712AsyncSwap.lean:254](../../formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L254) | wrapper; specs' tests plus testFuzz_eip712Domain_matches_DOMAIN_SEPARATOR |

### `Refinement/Swarm/SpecEip712Router.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `Eip712DomainSpec.domainSpec` | [SpecEip712Router.lean:59](../../formal/Refinement/Swarm/SpecEip712Router.lean#L59) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `testFuzz_Eip712DomainSpec_body (RouterSpecEip712FormalTest)` | no |
| `byteLength_eq` | [SpecEip712Router.lean:63](../../formal/Refinement/Swarm/SpecEip712Router.lean#L63) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `testFuzz_byteLength_eq` | yes |
| `toString_reverts_iff_byteLength` | [SpecEip712Router.lean:74](../../formal/Refinement/Swarm/SpecEip712Router.lean#L74) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `testFuzz_toString_reverts_iff_byteLength` | yes |
| `toString_eq` | [SpecEip712Router.lean:84](../../formal/Refinement/Swarm/SpecEip712Router.lean#L84) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `testFuzz_toString_eq` | no |
| `toString_name` | [SpecEip712Router.lean:95](../../formal/Refinement/Swarm/SpecEip712Router.lean#L95) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `testFuzz_toString_name (RouterSpecEip712FormalTest)` | no |
| `toString_version` | [SpecEip712Router.lean:102](../../formal/Refinement/Swarm/SpecEip712Router.lean#L102) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `testFuzz_toString_version (RouterSpecEip712FormalTest)` | no |
| `name_ne_sentinel` | [SpecEip712Router.lean:108](../../formal/Refinement/Swarm/SpecEip712Router.lean#L108) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `testFuzz_name_ne_sentinel (RouterSpecEip712FormalTest)` | no |
| `version_ne_sentinel` | [SpecEip712Router.lean:112](../../formal/Refinement/Swarm/SpecEip712Router.lean#L112) | [`SpecEip712.t.sol`](SpecEip712.t.sol) `testFuzz_version_ne_sentinel (RouterSpecEip712FormalTest)` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `EIP712Name_of_spec` | [SpecEip712Router.lean:118](../../formal/Refinement/Swarm/SpecEip712Router.lean#L118) | wrapper of `EIP712Name_spec`, concrete name; its content is the specs' tests plus Eip712Domain.t.sol: testFuzz_EIP712Name_spec |
| `EIP712Version_of_spec` | [SpecEip712Router.lean:123](../../formal/Refinement/Swarm/SpecEip712Router.lean#L123) | wrapper; specs' tests plus testFuzz_EIP712Version_spec |
| `eip712Domain_spec_of_spec` | [SpecEip712Router.lean:128](../../formal/Refinement/Swarm/SpecEip712Router.lean#L128) | wrapper; specs' tests plus testFuzz_eip712Domain_spec |
| `eip712Domain_never_reverts_of_spec` | [SpecEip712Router.lean:135](../../formal/Refinement/Swarm/SpecEip712Router.lean#L135) | wrapper; specs' tests plus testFuzz_eip712Domain_never_reverts |
| `eip712Domain_ok_of_spec` | [SpecEip712Router.lean:140](../../formal/Refinement/Swarm/SpecEip712Router.lean#L140) | wrapper; specs' tests plus testFuzz_eip712Domain_ok |
| `eip712Domain_matches_DOMAIN_SEPARATOR_of_spec` | [SpecEip712Router.lean:152](../../formal/Refinement/Swarm/SpecEip712Router.lean#L152) | wrapper; specs' tests plus testFuzz_eip712Domain_matches_DOMAIN_SEPARATOR |

### `Refinement/Swarm/SpecSigAsyncSwap.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `hashTypedDataV4_run` | [SpecSigAsyncSwap.lean:214](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L214) | [`SpecSig.t.sol`](SpecSig.t.sol) `testFuzz_hashTypedDataV4_run` | no |
| `tryRecover_9821_ok` | [SpecSigAsyncSwap.lean:223](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L223) | [`SpecSig.t.sol`](SpecSig.t.sol) `testFuzz_tryRecover_9821_ok` | no |
| `isValidSignatureNow_run` | [SpecSigAsyncSwap.lean:240](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L240) | [`SpecSig.t.sol`](SpecSig.t.sol) `testFuzz_isValidSignatureNow_run` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `ERC1271Spec.run` | [SpecSigAsyncSwap.lean:146](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L146) | model-only helper: the conjunction of the spec's three fields, each tested above |
| `TypedDataHashSpec.run` | [SpecSigAsyncSwap.lean:156](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L156) | model-only helper (as above) |
| `HashSetExecutorSpec.run` | [SpecSigAsyncSwap.lean:165](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L165) | model-only helper (as above) |
| `HashPoolKeySpec.run` | [SpecSigAsyncSwap.lean:174](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L174) | model-only helper (as above) |
| `poolKeyHash_eq_hashing` | [SpecSigAsyncSwap.lean:198](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L198) | model-only helper: relates two Lean hash models under `HashingCompat`; its bytecode content is `HashPoolKeySpec.result` |
| `setExecutorHash_eq_hashing` | [SpecSigAsyncSwap.lean:202](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L202) | model-only helper: as above; its bytecode content is `HashSetExecutorSpec.result` |
| `isValidSignatureNow_preserves_of_spec` | [SpecSigAsyncSwap.lean:260](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L260) | wrapper; its content is the spec's test + the original theorem's (itself model-only) |
| `hashTypedDataV4_preserves_of_spec` | [SpecSigAsyncSwap.lean:265](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L265) | wrapper (as above) |
| `pureCallees_of_spec` | [SpecSigAsyncSwap.lean:273](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L273) | wrapper: derives the old `PureCallees` bundle from the specs (`readOnly` fields, tested) |
| `setExecutorWithSig_expired_of_spec` | [SpecSigAsyncSwap.lean:279](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L279) | wrapper; its content is the spec's test + `testFuzz_setExecutorWithSig_expired` |
| `setExecutorWithSig_nonce_used_of_spec` | [SpecSigAsyncSwap.lean:285](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L285) | wrapper; spec's test + `testFuzz_setExecutorWithSig_nonce_used` |
| `setExecutorWithSig_invalid_sig_of_spec` | [SpecSigAsyncSwap.lean:292](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L292) | wrapper; spec's test + `testFuzz_setExecutorWithSig_invalid_sig` |
| `setExecutorWithSig_ok_of_spec` | [SpecSigAsyncSwap.lean:303](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L303) | wrapper; spec's test + `testFuzz_setExecutorWithSig_ok` |
| `setExecutorWithSig_ok_state_of_spec` | [SpecSigAsyncSwap.lean:314](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L314) | wrapper; spec's test + `testFuzz_setExecutorWithSig_ok_state` |
| `setExecutorWithSig_frame_of_spec` | [SpecSigAsyncSwap.lean:323](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L323) | wrapper; spec's test + `testFuzz_setExecutorWithSig_frame` |
| `setExecutorWithSig_no_replay_of_spec` | [SpecSigAsyncSwap.lean:343](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L343) | wrapper; spec's test + `testFuzz_setExecutorWithSig_no_replay` |
| `updatePrice_pureCallees_of_spec` | [SpecSigAsyncSwap.lean:367](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L367) | wrapper (derives `UpdatePriceWithSig.PureCallees`) |
| `updatePriceWithSig_invalidSig_of_spec` | [SpecSigAsyncSwap.lean:372](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L372) | wrapper; spec's test + the original theorem's test in `AsyncSwapUpdatePriceWithSig.t.sol` |
| `verify_ok_inv_of_spec` | [SpecSigAsyncSwap.lean:383](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L383) | wrapper (as above) |
| `updatePriceWithSig_missing_reverts_of_spec` | [SpecSigAsyncSwap.lean:395](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L395) | wrapper (as above) |
| `updatePriceWithSig_ok_of_spec` | [SpecSigAsyncSwap.lean:404](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L404) | wrapper (as above) |
| `updatePriceWithSig_burns_nonce_of_spec` | [SpecSigAsyncSwap.lean:426](../../formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L426) | wrapper (as above; still takes `KeepsNonces` for `_remove`/`_append`, another group's spec) |

### `Refinement/Swarm/SpecSigRouter.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `hashTypedDataV4_run` | [SpecSigRouter.lean:165](../../formal/Refinement/Swarm/SpecSigRouter.lean#L165) | [`SpecSig.t.sol`](SpecSig.t.sol) `testFuzz_hashTypedDataV4_run_router` | no |
| `tryRecover_5888_ok` | [SpecSigRouter.lean:174](../../formal/Refinement/Swarm/SpecSigRouter.lean#L174) | [`SpecSig.t.sol`](SpecSig.t.sol) `testFuzz_tryRecover_5888_ok` | no |
| `isValidSignatureNow_run` | [SpecSigRouter.lean:191](../../formal/Refinement/Swarm/SpecSigRouter.lean#L191) | [`SpecSig.t.sol`](SpecSig.t.sol) `testFuzz_isValidSignatureNow_run_router` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `ERC1271Spec.run` | [SpecSigRouter.lean:115](../../formal/Refinement/Swarm/SpecSigRouter.lean#L115) | model-only helper: the conjunction of the spec's three fields, each tested above |
| `TypedDataHashSpec.run` | [SpecSigRouter.lean:125](../../formal/Refinement/Swarm/SpecSigRouter.lean#L125) | model-only helper (as above) |
| `HashPoolKeySpec.run` | [SpecSigRouter.lean:134](../../formal/Refinement/Swarm/SpecSigRouter.lean#L134) | model-only helper (as above) |
| `poolKeyHash_eq_hashing` | [SpecSigRouter.lean:157](../../formal/Refinement/Swarm/SpecSigRouter.lean#L157) | model-only helper: relates two Lean hash models under `HashingCompat`; its bytecode content is `HashPoolKeySpec.result` |
| `isValidSignatureNow_preserves_of_spec` | [SpecSigRouter.lean:211](../../formal/Refinement/Swarm/SpecSigRouter.lean#L211) | wrapper; its content is the spec's test + the original theorem's (itself model-only) |
| `hashTypedDataV4_preserves_of_spec` | [SpecSigRouter.lean:216](../../formal/Refinement/Swarm/SpecSigRouter.lean#L216) | wrapper (as above) |
| `pureCallees_of_spec` | [SpecSigRouter.lean:223](../../formal/Refinement/Swarm/SpecSigRouter.lean#L223) | wrapper: derives the old `PureCallees` bundle from the specs (`readOnly` fields, tested) |
| `cancelWithSig_invalid_sig_of_spec` | [SpecSigRouter.lean:227](../../formal/Refinement/Swarm/SpecSigRouter.lean#L227) | wrapper; spec's test + `testFuzz_cancelWithSig_invalid_sig` |
| `cancelWithSig_ok_of_spec` | [SpecSigRouter.lean:239](../../formal/Refinement/Swarm/SpecSigRouter.lean#L239) | wrapper; spec's test + `testFuzz_cancelWithSig_ok` |
| `cancelWithSig_ok_state_of_spec` | [SpecSigRouter.lean:251](../../formal/Refinement/Swarm/SpecSigRouter.lean#L251) | wrapper; spec's test + `testFuzz_cancelWithSig_ok_state` |
| `cancelWithSig_no_replay_of_spec` | [SpecSigRouter.lean:260](../../formal/Refinement/Swarm/SpecSigRouter.lean#L260) | wrapper; spec's test + the original theorem's test (still takes `hmono` for `unlock`) |
