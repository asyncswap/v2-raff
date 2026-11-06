# test/formal/: Formal Mind's Lean theorems, checked on the bytecode

The Lean proofs these tests mirror are no longer in this repository: `formal/` is kept locally and ignored by git.
The last tracked copy is at [`5901aca`](https://github.com/asyncswap/contracts/blob/5901aca/formal/README.md); the links below point there. Those proofs
were about the model formal-ast generated from solc's AST, not the compiled contracts, and that model stopped tracking
the code after it was generated (Oct 28): it predates open pool creation and the rule that the trusted Router can't be
revoked, among others.

Each test here takes one theorem whose statement is about a single call's outcome, and states the same property on
the real compiled contracts: the call reverts with the named error, returns the given value, or writes only the storage
the theorem names. The tests run against the current code, so they stand on their own: when the code changes on
purpose, update the test to the new behavior and say so here. Otherwise a failing test is a counterexample. Don't
weaken a test to make it pass.

```sh
forge test --match-path 'test/formal/*'   # every test except the findings
FOUNDRY_PROFILE=findings forge test       # only the findings: these fail
```

**Status:** see the [map](#theorem--test-map), generated from a local `formal/Proofs/` and the tests by
`python3 script/formal-index.py` (it needs the local Lean corpus). The functions formal-ast leaves opaque each have a named spec that is checked on the
bytecode (see [Named specs](#named-specs-for-the-opaque-functions)).
- 600 tests in `test/formal/` pass on Forge 1.8.6 (`forge test --match-path 'test/formal/*'`, 90 suites).
- 1 test is a **finding**: it fails on the bytecode by design (see [Findings](#findings)). Its name
  contains `_finding_`, and `foundry.toml` leaves it out of a plain `forge test` (`no_match_test`), so
  CI stays green while it's kept.

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

The outer price index now uses a bounded tick bitmap. Representation-specific checks use its
three-word path and updated Book offsets; priority trees remain radix trees. The old outer
cyclic-pointer case is replaced by bounded lookup and missing-child rejection. Fee/sequence fuzzing
still spans uint64, while synthetic outer keys stay in 1..1,774,545. These test ports do not update or
re-prove the historical Lean model. See [the validation report](../../benchmarks/orderbook/README.md).

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

The Lean specs these rows name were retired with the earlier proofs (f243b0b); their links go to them as they were at
e04668e. The tests still check each spec on the bytecode.

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
| RemoveSpec.reverts (field) | [SpecBook.lean:344](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecBook.lean#L344) | SpecBook.t.sol: testFuzz_RemoveSpec_reverts |
| RemoveSpec.progress (field) | [SpecBook.lean:350](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecBook.lean#L350) | SpecBook.t.sol: testFuzz_RemoveSpec_progress |
| RemoveSpec.post (field) | [SpecBook.lean:356](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecBook.lean#L356) | SpecBook.t.sol: testFuzz_RemoveSpec_post |
| AppendSpec.post (field) | [SpecBook.lean:417](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecBook.lean#L417) | SpecBook.t.sol: testFuzz_AppendSpec_post, testFuzz_AppendSpec_post_guards |
| AppendSpec.progress (field) | [SpecBook.lean:435](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecBook.lean#L435) | SpecBook.t.sol: testFuzz_AppendSpec_progress |
| BestAtPriceSpec.fifo (field) | [SpecBook.lean:208](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecBook.lean#L208) | SpecBook.t.sol: testFuzz_BestAtPriceSpec_fifo |
| BestAtPriceSpec.priority (field) | [SpecBook.lean:213](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecBook.lean#L213) | SpecBook.t.sol: testFuzz_BestAtPriceSpec_priority |
| BestAtPriceSpec.badMode (field) | [SpecBook.lean:220](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecBook.lean#L220) | SpecBook.t.sol: testFuzz_BestAtPriceSpec_badMode |
| LevelSpec.fifo (field) | [SpecBook.lean:227](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecBook.lean#L227) | SpecBook.t.sol: testFuzz_LevelSpec_fifo |
| LevelSpec.priority (field) | [SpecBook.lean:233](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecBook.lean#L233) | SpecBook.t.sol: testFuzz_LevelSpec_priority |
| LevelSpec.badMode (field) | [SpecBook.lean:238](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecBook.lean#L238) | SpecBook.t.sol: testFuzz_LevelSpec_badMode |
| CreateOrderSpec.notAuthorised (spec field) | [SpecCoreAsyncSwap.lean:111](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L111) | SpecCore.t.sol: testFuzz_CreateOrderSpec_notAuthorised |
| CreateOrderSpec.zeroAmount (spec field) | [SpecCoreAsyncSwap.lean:115](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L115) | SpecCore.t.sol: testFuzz_CreateOrderSpec_zeroAmount |
| CreateOrderSpec.run (spec field) | [SpecCoreAsyncSwap.lean:119](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L119) | SpecCore.t.sol: testFuzz_CreateOrderSpec_run, testFuzz_CreateOrderSpec_run_repeat, testFuzz_CreateOrderSpec_run_addOrderGuards |
| TransferSpec.native (spec field) | [SpecCoreAsyncSwap.lean:331](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L331) | SpecCore.t.sol: testFuzz_TransferSpec_native, testFuzz_TransferSpec_viaSweep |
| TransferSpec.erc20 (spec field) | [SpecCoreAsyncSwap.lean:342](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L342) | SpecCore.t.sol: testFuzz_TransferSpec_erc20, testFuzz_TransferSpec_erc20_noCode, testFuzz_TransferSpec_viaSweep |
| PoolStateSlotSpec.pure_ok (spec field) | [SpecCoreAsyncSwap.lean:402](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L402) | SpecCore.t.sol: testFuzz_PoolStateSlotSpec_pure_ok |
| PoolStateSlotSpec.value (spec field) | [SpecCoreAsyncSwap.lean:404](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecCoreAsyncSwap.lean#L404) | SpecCore.t.sol: testFuzz_PoolStateSlotSpec_value |
| TransferSpec.native, Router (spec field) | [SpecCoreRouter.lean:52](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecCoreRouter.lean#L52) | SpecCore.t.sol: testFuzz_Router_TransferSpec_native |
| TransferSpec.erc20, Router (spec field) | [SpecCoreRouter.lean:62](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecCoreRouter.lean#L62) | SpecCore.t.sol: testFuzz_Router_TransferSpec_erc20 |
| CtorSpec (AsyncSwap; all fields) | [SpecEip712AsyncSwap.lean:50](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L50) | SpecEip712.t.sol: testFuzz_CtorSpec (AsyncSwapCtorSpecFormalTest); guards also AsyncSwapConstructor.t.sol |
| ShortStringsSpec (AsyncSwap; toString_reverts) | [SpecEip712AsyncSwap.lean:138](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L138) | SpecEip712.t.sol: testFuzz_ShortStringsSpec_toString_reverts |
| ShortStringsSpec (AsyncSwap; toString_ok) | [SpecEip712AsyncSwap.lean:138](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L138) | SpecEip712.t.sol: testFuzz_ShortStringsSpec_toString_ok |
| ShortStringsSpec (AsyncSwap; withFallback) | [SpecEip712AsyncSwap.lean:138](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L138) | SpecEip712.t.sol: testFuzz_ShortStringsSpec_withFallback |
| Eip712DomainSpec (AsyncSwap; body) | [SpecEip712AsyncSwap.lean:155](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecEip712AsyncSwap.lean#L155) | SpecEip712.t.sol: testFuzz_Eip712DomainSpec_body (AsyncSwapSpecEip712FormalTest) |
| CtorSpec (Router; all fields) | [RouterConstructor.lean:51](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/RouterConstructor.lean#L51) | RouterConstructor.t.sol: testFuzz_CtorSpec |
| ShortStringsSpec (Router; 3 fields) | [SpecEip712Router.lean:36](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecEip712Router.lean#L36) | SpecEip712.t.sol: testFuzz_ShortStringsSpec_toString_reverts / _toString_ok / _withFallback (same library code) |
| Eip712DomainSpec (Router; body) | [SpecEip712Router.lean:53](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecEip712Router.lean#L53) | SpecEip712.t.sol: testFuzz_Eip712DomainSpec_body (RouterSpecEip712FormalTest) |
| `ERC1271Spec.total` (AsyncSwap `_2280`) | [SpecSigAsyncSwap.lean:101](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L101) | SpecSig.t.sol: testFuzz_ERC1271Spec_total, testFuzz_ERC1271Spec_onHook |
| `ERC1271Spec.readOnly` (AsyncSwap) | [SpecSigAsyncSwap.lean:104](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L104) | SpecSig.t.sol: testFuzz_ERC1271Spec_readOnly, testFuzz_ERC1271Spec_onHook |
| `ERC1271Spec.result` (AsyncSwap) | [SpecSigAsyncSwap.lean:106](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L106) | SpecSig.t.sol: testFuzz_ERC1271Spec_result, testFuzz_ERC1271Spec_result_calldata, testFuzz_ERC1271Spec_result_noCode_precompile, testFuzz_ERC1271Spec_onHook |
| `ERC1271Spec.total` / `.readOnly` / `.result` (Router `_1883`) | [SpecSigRouter.lean:80](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecSigRouter.lean#L80) | SpecSig.t.sol: testFuzz_ERC1271Spec_onRouter (plus the library tests above) |
| `TypedDataHashSpec.total` (AsyncSwap `_9732`) | [SpecSigAsyncSwap.lean:114](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L114) | SpecSig.t.sol: testFuzz_TypedDataHashSpec_total |
| `TypedDataHashSpec.readOnly` (AsyncSwap) | [SpecSigAsyncSwap.lean:116](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L116) | SpecSig.t.sol: testFuzz_TypedDataHashSpec_readOnly |
| `TypedDataHashSpec.result` (AsyncSwap) | [SpecSigAsyncSwap.lean:119](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L119) | SpecSig.t.sol: testFuzz_TypedDataHashSpec_result, testFuzz_HashSetExecutorSpec_onHook, testFuzz_hashTypedDataV4_run |
| `TypedDataHashSpec.total` / `.readOnly` / `.result` (Router `_5799`) | [SpecSigRouter.lean:93](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecSigRouter.lean#L93) | SpecSig.t.sol: testFuzz_hashTypedDataV4_run_router (plus the library tests above) |
| `HashSetExecutorSpec.total` / `.readOnly` | [SpecSigAsyncSwap.lean:125](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L125) | SpecSig.t.sol: testFuzz_HashSetExecutorSpec_total_readOnly |
| `HashSetExecutorSpec.result` | [SpecSigAsyncSwap.lean:129](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L129) | SpecSig.t.sol: testFuzz_HashSetExecutorSpec_result, testFuzz_HashSetExecutorSpec_onHook |
| `HashPoolKeySpec.total` / `.readOnly` (AsyncSwap `_9171`, Router `_4949`) | [SpecSigAsyncSwap.lean:135](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L135), [SpecSigRouter.lean:104](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecSigRouter.lean#L104) | SpecSig.t.sol: testFuzz_HashPoolKeySpec_total_readOnly |
| `HashPoolKeySpec.result` (both) | [SpecSigAsyncSwap.lean:139](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L139), [SpecSigRouter.lean:108](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecSigRouter.lean#L108) | SpecSig.t.sol: testFuzz_HashPoolKeySpec_result, testFuzz_HashSetExecutorSpec_onHook (inlined in the hook) |
| The Lean words `POOL_KEY_TYPEHASH`, `SET_EXECUTOR_TYPEHASH`, `ERC1271_SELECTOR`, `ERC1271_MAGIC` | [SpecSigAsyncSwap.lean:52](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecSigAsyncSwap.lean#L52), [SpecSigRouter.lean:39](https://github.com/asyncswap/contracts/blob/e04668e/formal/Refinement/Swarm/SpecSigRouter.lean#L39) | SpecSig.t.sol: test_SpecSig_typehash_words |

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

426 theorems and lemmas in `formal/Proofs/`: 18 have a test here, 33 are left out for the reason given, and 375 aren't tested yet. 571 tests are named after theorems that were retired (listed at the end). Generated by `python3 script/formal-index.py`; run it after the proofs or the tests change.

### `Proofs/Cancellation.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `expired_cancel` | [Cancellation.lean:6](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Cancellation.lean#L6) | not tested yet |

### `Proofs/ClaimBatch.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `capacity` | [ClaimBatch.lean:4](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/ClaimBatch.lean#L4) | not tested yet |
| `combined_credit_conserves` | [ClaimBatch.lean:9](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/ClaimBatch.lean#L9) | not tested yet |
| `self_credit` | [ClaimBatch.lean:14](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/ClaimBatch.lean#L14) | not tested yet |

### `Proofs/Claims.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `callback_authorized` | [Claims.lean:6](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Claims.lean#L6) | not tested yet |

### `Proofs/Fees.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `route` | [Fees.lean:8](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Fees.lean#L8) | not tested yet |

### `Proofs/FillCap.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `fill_cap` | [FillCap.lean:3](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/FillCap.lean#L3) | not tested yet |

### `Proofs/Functions/AsyncSwapAddOrder.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `ite_bind'` | [AsyncSwapAddOrder.lean:48](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapAddOrder.lean#L48) | not tested yet |
| `throw_bind'` | [AsyncSwapAddOrder.lean:52](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapAddOrder.lean#L52) | not tested yet |
| `addOrder_split` | [AsyncSwapAddOrder.lean:91](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapAddOrder.lean#L91) | not tested yet |
| `addOrder_fee_error` | [AsyncSwapAddOrder.lean:99](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapAddOrder.lean#L99) | not tested yet |
| `addOrder_key_ok` | [AsyncSwapAddOrder.lean:107](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapAddOrder.lean#L107) | not tested yet |
| `addOrder_key_zero` | [AsyncSwapAddOrder.lean:122](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapAddOrder.lean#L122) | not tested yet |
| `addOrder_key_reverts_iff` | [AsyncSwapAddOrder.lean:134](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapAddOrder.lean#L134) | not tested yet |
| `matching_addOrder_split` | [AsyncSwapAddOrder.lean:151](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapAddOrder.lean#L151) | not tested yet |
| `matching_addOrder_zeroMin_gap` | [AsyncSwapAddOrder.lean:162](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapAddOrder.lean#L162) | not tested yet |
| `matching_addOrder_buy_ok` | [AsyncSwapAddOrder.lean:175](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapAddOrder.lean#L175) | not tested yet |
| `ceil_tail_pos` | [AsyncSwapAddOrder.lean:204](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapAddOrder.lean#L204) | not tested yet |
| `mulDivRnd_ceil_pos` | [AsyncSwapAddOrder.lean:221](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapAddOrder.lean#L221) | not tested yet |
| `rekey_den_ne_zero` | [AsyncSwapAddOrder.lean:240](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapAddOrder.lean#L240) | not tested yet |
| `rekey_priceKey_ok` | [AsyncSwapAddOrder.lean:249](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapAddOrder.lean#L249) | not tested yet |
| `rekey_den_sell` | [AsyncSwapAddOrder.lean:260](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapAddOrder.lean#L260) | not tested yet |

### `Proofs/Functions/AsyncSwapAppend.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `good_addc` | [AsyncSwapAppend.lean:37](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapAppend.lean#L37) | not tested yet |
| `good_idx` | [AsyncSwapAppend.lean:44](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapAppend.lean#L44) | not tested yet |
| `insert_good` | [AsyncSwapAppend.lean:55](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapAppend.lean#L55) | not tested yet |
| `append_good` | [AsyncSwapAppend.lean:78](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapAppend.lean#L78) | not tested yet |
| `append_reverts_only` | [AsyncSwapAppend.lean:102](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapAppend.lean#L102) | not tested yet |
| `append_frame` | [AsyncSwapAppend.lean:131](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapAppend.lean#L131) | not tested yet |

### `Proofs/Functions/AsyncSwapAsyncOrderInfo.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `asyncOrderInfo_storage` | [AsyncSwapAsyncOrderInfo.lean:10](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapAsyncOrderInfo.lean#L10) | not tested yet |
| `asyncOrderInfo_no_revert` | [AsyncSwapAsyncOrderInfo.lean:19](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapAsyncOrderInfo.lean#L19) | not tested yet |

### `Proofs/Functions/AsyncSwapBest.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `good_pure` | [AsyncSwapBest.lean:40](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapBest.lean#L40) | not tested yet |
| `good_throw` | [AsyncSwapBest.lean:43](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapBest.lean#L43) | not tested yet |
| `good_bind` | [AsyncSwapBest.lean:46](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapBest.lean#L46) | not tested yet |
| `good_ite` | [AsyncSwapBest.lean:56](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapBest.lean#L56) | not tested yet |
| `good_forIn_list` | [AsyncSwapBest.lean:60](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapBest.lean#L60) | not tested yet |
| `good_forIn_range` | [AsyncSwapBest.lean:72](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapBest.lean#L72) | not tested yet |
| `best_good` | [AsyncSwapBest.lean:93](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapBest.lean#L93) | not tested yet |
| `best_reverts_only_loop_bound` | [AsyncSwapBest.lean:106](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapBest.lean#L106) | not tested yet |
| `best_frame` | [AsyncSwapBest.lean:128](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapBest.lean#L128) | not tested yet |
| `best_setters_irrelevant` | [AsyncSwapBest.lean:162](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapBest.lean#L162) | not tested yet |
| `loop_ok` | [AsyncSwapBest.lean:174](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapBest.lean#L174) | not tested yet |
| `loop_no_err` | [AsyncSwapBest.lean:190](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapBest.lean#L190) | not tested yet |
| `best_empty` | [AsyncSwapBest.lean:212](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapBest.lean#L212) | not tested yet |
| `best_root_ineligible` | [AsyncSwapBest.lean:224](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapBest.lean#L224) | not tested yet |
| `best_result` | [AsyncSwapBest.lean:244](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapBest.lean#L244) | not tested yet |

### `Proofs/Functions/AsyncSwapBookPair.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `bookPair_good` | [AsyncSwapBookPair.lean:32](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapBookPair.lean#L32) | not tested yet |
| `bookPair_reverts` | [AsyncSwapBookPair.lean:47](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapBookPair.lean#L47) | not tested yet |
| `bookPair_self_set_irrelevant` | [AsyncSwapBookPair.lean:73](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapBookPair.lean#L73) | not tested yet |
| `bookPair_no_pair` | [AsyncSwapBookPair.lean:86](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapBookPair.lean#L86) | not tested yet |
| `bookPair_strict` | [AsyncSwapBookPair.lean:103](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapBookPair.lean#L103) | not tested yet |
| `bookPair_equal` | [AsyncSwapBookPair.lean:128](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapBookPair.lean#L128) | not tested yet |
| `bookPair_equal_div_zero` | [AsyncSwapBookPair.lean:157](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapBookPair.lean#L157) | not tested yet |

### `Proofs/Functions/AsyncSwapCalculatePoolFee.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `calculatePoolFee_success` | [AsyncSwapCalculatePoolFee.lean:10](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapCalculatePoolFee.lean#L10) | not tested yet |

### `Proofs/Functions/AsyncSwapCheckMinimum.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `checkMinimum_good` | [AsyncSwapCheckMinimum.lean:29](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapCheckMinimum.lean#L29) | not tested yet |
| `checkMinimum_reverts` | [AsyncSwapCheckMinimum.lean:43](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapCheckMinimum.lean#L43) | not tested yet |
| `checkMinimum_setters_irrelevant` | [AsyncSwapCheckMinimum.lean:65](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapCheckMinimum.lean#L65) | not tested yet |
| `checkMinimum_zero` | [AsyncSwapCheckMinimum.lean:80](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapCheckMinimum.lean#L80) | not tested yet |
| `checkMinimum_buy` | [AsyncSwapCheckMinimum.lean:92](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapCheckMinimum.lean#L92) | not tested yet |
| `checkMinimum_sell_below` | [AsyncSwapCheckMinimum.lean:105](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapCheckMinimum.lean#L105) | not tested yet |
| `checkMinimum_sell_zeroForOne` | [AsyncSwapCheckMinimum.lean:118](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapCheckMinimum.lean#L118) | not tested yet |
| `checkMinimum_sell_oneForZero` | [AsyncSwapCheckMinimum.lean:138](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapCheckMinimum.lean#L138) | not tested yet |
| `checkMinimum_sell_oneForZero_price_zero` | [AsyncSwapCheckMinimum.lean:159](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapCheckMinimum.lean#L159) | not tested yet |

### `Proofs/Functions/AsyncSwapClaimTransfersFlush.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `forIn_flush` | [AsyncSwapClaimTransfersFlush.lean:30](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapClaimTransfersFlush.lean#L30) | not tested yet |
| `flush_eq` | [AsyncSwapClaimTransfersFlush.lean:65](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapClaimTransfersFlush.lean#L65) | not tested yet |
| `flush_empty` | [AsyncSwapClaimTransfersFlush.lean:87](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapClaimTransfersFlush.lean#L87) | not tested yet |

### `Proofs/Functions/AsyncSwapCloseOrder.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `closeOrder_eq` | [AsyncSwapCloseOrder.lean:11](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapCloseOrder.lean#L11) | not tested yet |
| `closeOrder_run` | [AsyncSwapCloseOrder.lean:37](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapCloseOrder.lean#L37) | not tested yet |

### `Proofs/Functions/AsyncSwapCreditPriorityFee.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `creditPriorityFee_zero` | [AsyncSwapCreditPriorityFee.lean:18](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapCreditPriorityFee.lean#L18) | not tested yet |
| `creditPriorityFee_nonzero` | [AsyncSwapCreditPriorityFee.lean:26](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapCreditPriorityFee.lean#L26) | not tested yet |
| `creditPriorityFee_run` | [AsyncSwapCreditPriorityFee.lean:43](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapCreditPriorityFee.lean#L43) | not tested yet |

### `Proofs/Functions/AsyncSwapEligible.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `eligible_eq` | [AsyncSwapEligible.lean:18](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapEligible.lean#L18) | not tested yet |
| `eligible_reverts_iff` | [AsyncSwapEligible.lean:25](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapEligible.lean#L25) | not tested yet |
| `eligible_ok` | [AsyncSwapEligible.lean:35](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapEligible.lean#L35) | not tested yet |
| `eligible_never_reverts` | [AsyncSwapEligible.lean:44](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapEligible.lean#L44) | not tested yet |

### `Proofs/Functions/AsyncSwapExactPrice.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `exactPrice_of_read` | [AsyncSwapExactPrice.lean:25](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapExactPrice.lean#L25) | not tested yet |
| `exactPrice_buy` | [AsyncSwapExactPrice.lean:35](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapExactPrice.lean#L35) | not tested yet |
| `exactPrice_sell` | [AsyncSwapExactPrice.lean:43](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapExactPrice.lean#L43) | not tested yet |
| `exactPrice_error` | [AsyncSwapExactPrice.lean:51](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapExactPrice.lean#L51) | not tested yet |
| `exactPrice_order_set_irrelevant` | [AsyncSwapExactPrice.lean:59](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapExactPrice.lean#L59) | not tested yet |

### `Proofs/Functions/AsyncSwapFloorTick.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `run_bind_ok` | [AsyncSwapFloorTick.lean:48](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapFloorTick.lean#L48) | not tested yet |
| `mulDivFloor_ok` | [AsyncSwapFloorTick.lean:52](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapFloorTick.lean#L52) | not tested yet |
| `prod_lt` | [AsyncSwapFloorTick.lean:60](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapFloorTick.lean#L60) | not tested yet |
| `mulDiv_bounds` | [AsyncSwapFloorTick.lean:72](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapFloorTick.lean#L72) | not tested yet |
| `floorTick_eq` | [AsyncSwapFloorTick.lean:81](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapFloorTick.lean#L81) | not tested yet |
| `floorTick_den_zero` | [AsyncSwapFloorTick.lean:95](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapFloorTick.lean#L95) | not tested yet |
| `floorTick_low` | [AsyncSwapFloorTick.lean:103](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapFloorTick.lean#L103) | not tested yet |
| `floorTick_saturates` | [AsyncSwapFloorTick.lean:112](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapFloorTick.lean#L112) | not tested yet |
| `floorTick_mid` | [AsyncSwapFloorTick.lean:120](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapFloorTick.lean#L120) | not tested yet |
| `floorTick_run` | [AsyncSwapFloorTick.lean:129](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapFloorTick.lean#L129) | not tested yet |
| `tail_no_write` | [AsyncSwapFloorTick.lean:147](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapFloorTick.lean#L147) | not tested yet |
| `floorTick_no_write` | [AsyncSwapFloorTick.lean:161](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapFloorTick.lean#L161) | not tested yet |
| `sqrtPure_sq_le` | [AsyncSwapFloorTick.lean:174](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapFloorTick.lean#L174) | not tested yet |
| `sqrtPure_lt` | [AsyncSwapFloorTick.lean:185](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapFloorTick.lean#L185) | not tested yet |
| `shlw_sqrt_no_wrap` | [AsyncSwapFloorTick.lean:195](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapFloorTick.lean#L195) | not tested yet |
| `floorTick_mid_exact` | [AsyncSwapFloorTick.lean:210](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapFloorTick.lean#L210) | not tested yet |
| `floorTick_low_bound` | [AsyncSwapFloorTick.lean:220](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapFloorTick.lean#L220) | not tested yet |
| `tail_dispatch` | [AsyncSwapFloorTick.lean:226](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapFloorTick.lean#L226) | not tested yet |
| `floorTick_dispatch` | [AsyncSwapFloorTick.lean:245](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapFloorTick.lean#L245) | not tested yet |
| `floorTick_total` | [AsyncSwapFloorTick.lean:272](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapFloorTick.lean#L272) | not tested yet |
| `floorTick_error_iff` | [AsyncSwapFloorTick.lean:282](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapFloorTick.lean#L282) | not tested yet |

### `Proofs/Functions/AsyncSwapGetSqrtPriceAtTick.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `step_fold` | [AsyncSwapGetSqrtPriceAtTick.lean:75](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapGetSqrtPriceAtTick.lean#L75) | not tested yet |
| `invert_fold` | [AsyncSwapGetSqrtPriceAtTick.lean:80](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapGetSqrtPriceAtTick.lean#L80) | not tested yet |
| `maxTick_word` | [AsyncSwapGetSqrtPriceAtTick.lean:84](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapGetSqrtPriceAtTick.lean#L84) | not tested yet |
| `getSqrtPriceAtTick_eq` | [AsyncSwapGetSqrtPriceAtTick.lean:90](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapGetSqrtPriceAtTick.lean#L90) | not tested yet |
| `getSqrtPriceAtTick_run` | [AsyncSwapGetSqrtPriceAtTick.lean:151](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapGetSqrtPriceAtTick.lean#L151) | not tested yet |
| `xor_allOnes` | [AsyncSwapGetSqrtPriceAtTick.lean:159](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapGetSqrtPriceAtTick.lean#L159) | not tested yet |
| `toUnsigned_cast` | [AsyncSwapGetSqrtPriceAtTick.lean:165](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapGetSqrtPriceAtTick.lean#L165) | not tested yet |
| `sar_low` | [AsyncSwapGetSqrtPriceAtTick.lean:170](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapGetSqrtPriceAtTick.lean#L170) | not tested yet |
| `sar_high` | [AsyncSwapGetSqrtPriceAtTick.lean:179](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapGetSqrtPriceAtTick.lean#L179) | not tested yet |
| `tick24_eq` | [AsyncSwapGetSqrtPriceAtTick.lean:189](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapGetSqrtPriceAtTick.lean#L189) | not tested yet |
| `absTickOf_eq` | [AsyncSwapGetSqrtPriceAtTick.lean:201](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapGetSqrtPriceAtTick.lean#L201) | not tested yet |
| `getSqrtPriceAtTick_int24` | [AsyncSwapGetSqrtPriceAtTick.lean:220](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapGetSqrtPriceAtTick.lean#L220) | not tested yet |
| `getSqrtPriceAtTick_reverts_iff` | [AsyncSwapGetSqrtPriceAtTick.lean:227](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapGetSqrtPriceAtTick.lean#L227) | not tested yet |
| `getSqrtPriceAtTick_zero` | [AsyncSwapGetSqrtPriceAtTick.lean:240](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapGetSqrtPriceAtTick.lean#L240) | not tested yet |
| `getSqrtPriceAtTick_minTick` | [AsyncSwapGetSqrtPriceAtTick.lean:247](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapGetSqrtPriceAtTick.lean#L247) | not tested yet |
| `getSqrtPriceAtTick_maxTick` | [AsyncSwapGetSqrtPriceAtTick.lean:254](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapGetSqrtPriceAtTick.lean#L254) | not tested yet |

### `Proofs/Functions/AsyncSwapGetTickAtSqrtPrice.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `getTickAtSqrtPrice_eq` | [AsyncSwapGetTickAtSqrtPrice.lean:77](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapGetTickAtSqrtPrice.lean#L77) | not tested yet |
| `getTickAtSqrtPrice_out_of_range` | [AsyncSwapGetTickAtSqrtPrice.lean:97](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapGetTickAtSqrtPrice.lean#L97) | not tested yet |
| `guard_iff` | [AsyncSwapGetTickAtSqrtPrice.lean:104](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapGetTickAtSqrtPrice.lean#L104) | not tested yet |
| `priceOf_pos` | [AsyncSwapGetTickAtSqrtPrice.lean:111](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapGetTickAtSqrtPrice.lean#L111) | not tested yet |
| `tailR_run` | [AsyncSwapGetTickAtSqrtPrice.lean:120](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapGetTickAtSqrtPrice.lean#L120) | not tested yet |
| `getTickAtSqrtPrice_run` | [AsyncSwapGetTickAtSqrtPrice.lean:137](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapGetTickAtSqrtPrice.lean#L137) | not tested yet |
| `getTickAtSqrtPrice_result` | [AsyncSwapGetTickAtSqrtPrice.lean:152](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapGetTickAtSqrtPrice.lean#L152) | not tested yet |
| `getTickAtSqrtPrice_no_write` | [AsyncSwapGetTickAtSqrtPrice.lean:180](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapGetTickAtSqrtPrice.lean#L180) | not tested yet |

### `Proofs/Functions/AsyncSwapIsExecutor.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `isExecutor_storage` | [AsyncSwapIsExecutor.lean:11](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapIsExecutor.lean#L11) | not tested yet |
| `isExecutor_no_revert` | [AsyncSwapIsExecutor.lean:19](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapIsExecutor.lean#L19) | not tested yet |

### `Proofs/Functions/AsyncSwapKey.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `floorTick_bounded` | [AsyncSwapKey.lean:27](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapKey.lean#L27) | not tested yet |
| `key_ok` | [AsyncSwapKey.lean:56](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapKey.lean#L56) | not tested yet |
| `key_no_revert` | [AsyncSwapKey.lean:75](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapKey.lean#L75) | not tested yet |
| `key_spec` | [AsyncSwapKey.lean:85](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapKey.lean#L85) | not tested yet |
| `key_reverts_iff` | [AsyncSwapKey.lean:101](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapKey.lean#L101) | not tested yet |

### `Proofs/Functions/AsyncSwapLevel.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `good_pure` | [AsyncSwapLevel.lean:38](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapLevel.lean#L38) | not tested yet |
| `good_throw` | [AsyncSwapLevel.lean:41](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapLevel.lean#L41) | not tested yet |
| `good_bind` | [AsyncSwapLevel.lean:44](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapLevel.lean#L44) | not tested yet |
| `good_ite` | [AsyncSwapLevel.lean:54](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapLevel.lean#L54) | not tested yet |
| `good_forIn_list` | [AsyncSwapLevel.lean:58](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapLevel.lean#L58) | not tested yet |
| `good_forIn_range` | [AsyncSwapLevel.lean:70](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapLevel.lean#L70) | not tested yet |
| `loop_ok` | [AsyncSwapLevel.lean:87](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapLevel.lean#L87) | not tested yet |
| `loop_no_err` | [AsyncSwapLevel.lean:102](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapLevel.lean#L102) | not tested yet |
| `level_good` | [AsyncSwapLevel.lean:124](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapLevel.lean#L124) | not tested yet |
| `level_reverts` | [AsyncSwapLevel.lean:134](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapLevel.lean#L134) | not tested yet |
| `level_frame` | [AsyncSwapLevel.lean:148](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapLevel.lean#L148) | not tested yet |
| `level_book_set_irrelevant` | [AsyncSwapLevel.lean:165](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapLevel.lean#L165) | not tested yet |
| `radix_best_result` | [AsyncSwapLevel.lean:175](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapLevel.lean#L175) | not tested yet |
| `level_empty` | [AsyncSwapLevel.lean:215](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapLevel.lean#L215) | not tested yet |
| `level_result` | [AsyncSwapLevel.lean:229](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapLevel.lean#L229) | not tested yet |

### `Proofs/Functions/AsyncSwapLog2.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `ite_ok_pair` | [AsyncSwapLog2.lean:35](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapLog2.lean#L35) | not tested yet |
| `log2_run` | [AsyncSwapLog2.lean:41](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapLog2.lean#L41) | not tested yet |
| `log2_shift` | [AsyncSwapLog2.lean:48](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapLog2.lean#L48) | not tested yet |
| `spec_G1` | [AsyncSwapLog2.lean:74](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapLog2.lean#L74) | not tested yet |
| `spec_stage` | [AsyncSwapLog2.lean:81](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapLog2.lean#L81) | not tested yet |
| `spec_G128` | [AsyncSwapLog2.lean:110](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapLog2.lean#L110) | not tested yet |
| `log2_eq` | [AsyncSwapLog2.lean:116](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapLog2.lean#L116) | not tested yet |

### `Proofs/Functions/AsyncSwapMin.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `min_run` | [AsyncSwapMin.lean:18](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMin.lean#L18) | not tested yet |
| `min_spec` | [AsyncSwapMin.lean:27](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMin.lean#L27) | not tested yet |

### `Proofs/Functions/AsyncSwapMinPriorityFee.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `minPriorityFee_eq` | [AsyncSwapMinPriorityFee.lean:22](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMinPriorityFee.lean#L22) | not tested yet |
| `minPriorityFee_ok` | [AsyncSwapMinPriorityFee.lean:39](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMinPriorityFee.lean#L39) | not tested yet |
| `minPriorityFee_bounds` | [AsyncSwapMinPriorityFee.lean:51](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMinPriorityFee.lean#L51) | not tested yet |

### `Proofs/Functions/AsyncSwapMostPermissiveAtPrice.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `mostPermissiveAtPrice_of_read` | [AsyncSwapMostPermissiveAtPrice.lean:28](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMostPermissiveAtPrice.lean#L28) | not tested yet |
| `mostPermissiveAtPrice_error` | [AsyncSwapMostPermissiveAtPrice.lean:39](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMostPermissiveAtPrice.lean#L39) | not tested yet |
| `mostPermissiveAtPrice_no_revert` | [AsyncSwapMostPermissiveAtPrice.lean:48](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMostPermissiveAtPrice.lean#L48) | not tested yet |
| `mostPermissiveAtPrice_book_set_irrelevant` | [AsyncSwapMostPermissiveAtPrice.lean:57](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMostPermissiveAtPrice.lean#L57) | not tested yet |
| `mostPermissiveAtPrice_storage` | [AsyncSwapMostPermissiveAtPrice.lean:65](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMostPermissiveAtPrice.lean#L65) | not tested yet |

### `Proofs/Functions/AsyncSwapMostSignificantBit.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `stage_inv` | [AsyncSwapMostSignificantBit.lean:60](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMostSignificantBit.lean#L60) | model-only helper (loop invariant of Lean `stage`) |
| `mostSignificantBit_run` | [AsyncSwapMostSignificantBit.lean:38](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMostSignificantBit.lean#L38) | not tested yet |
| `lut_spec` | [AsyncSwapMostSignificantBit.lean:48](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMostSignificantBit.lean#L48) | not tested yet |
| `or_eq_add` | [AsyncSwapMostSignificantBit.lean:52](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMostSignificantBit.lean#L52) | not tested yet |
| `msbPure_spec` | [AsyncSwapMostSignificantBit.lean:98](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMostSignificantBit.lean#L98) | not tested yet |
| `mostSignificantBit_eq` | [AsyncSwapMostSignificantBit.lean:134](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMostSignificantBit.lean#L134) | not tested yet |
| `mostSignificantBit_zero` | [AsyncSwapMostSignificantBit.lean:148](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMostSignificantBit.lean#L148) | not tested yet |

### `Proofs/Functions/AsyncSwapMulDiv.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `mulDiv_ok` | [AsyncSwapMulDiv.lean:322](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L322) | [`AsyncSwapMulDiv.t.sol`](AsyncSwapMulDiv.t.sol) `testFuzz_mulDiv_ok` | yes |
| `mulDiv_overflow` | [AsyncSwapMulDiv.lean:372](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L372) | [`AsyncSwapMulDiv.t.sol`](AsyncSwapMulDiv.t.sol) `testFuzz_mulDiv_overflow` | yes |
| `mulDiv_zero` | [AsyncSwapMulDiv.lean:388](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L388) | [`AsyncSwapMulDiv.t.sol`](AsyncSwapMulDiv.t.sol) `testFuzz_mulDiv_zero` | yes |
| `mulDiv_spec` | [AsyncSwapMulDiv.lean:405](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L405) | [`AsyncSwapMulDiv.t.sol`](AsyncSwapMulDiv.t.sol) `testFuzz_mulDiv_spec` | yes |
| `mulDiv_eq_mulDivFloor` | [AsyncSwapMulDiv.lean:446](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L446) | [`AsyncSwapMulDiv.t.sol`](AsyncSwapMulDiv.t.sol) `testFuzz_mulDiv_eq_mulDivFloor` | yes |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `W_eq` | [AsyncSwapMulDiv.lean:36](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L36) | model-only helper (Lean constant `W = 2^256`) |
| `W_pos` | [AsyncSwapMulDiv.lean:37](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L37) | model-only helper (Lean arithmetic fact) |
| `ite_pos'` | [AsyncSwapMulDiv.lean:40](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L40) | model-only helper (Lean `ite` lemma) |
| `ite_neg'` | [AsyncSwapMulDiv.lean:42](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L42) | model-only helper (Lean `ite` lemma) |
| `mulw_eq` | [AsyncSwapMulDiv.lean:45](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L45) | model-only helper (Lean word op `mulw`) |
| `ysub_le` | [AsyncSwapMulDiv.lean:47](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L47) | model-only helper (Lean Yul op `ysub`) |
| `ysub_lt` | [AsyncSwapMulDiv.lean:52](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L52) | model-only helper (Lean Yul op `ysub`) |
| `ylt_eq` | [AsyncSwapMulDiv.lean:56](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L56) | model-only helper (Lean Yul op `ylt`) |
| `ygt_eq` | [AsyncSwapMulDiv.lean:59](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L59) | model-only helper (Lean Yul op `ygt`) |
| `ydiv_pos` | [AsyncSwapMulDiv.lean:62](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L62) | model-only helper (Lean Yul op `ydiv`) |
| `hi_word` | [AsyncSwapMulDiv.lean:67](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L67) | model-only helper (Nat lemma: mulmod trick gives the high word) |
| `sub_rem` | [AsyncSwapMulDiv.lean:105](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L105) | model-only helper (512-bit subtraction lemma) |
| `and_double` | [AsyncSwapMulDiv.lean:123](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L123) | model-only helper (Nat bitwise lemma) |
| `lowbit_odd` | [AsyncSwapMulDiv.lean:132](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L132) | model-only helper (Nat bitwise lemma) |
| `lowbit` | [AsyncSwapMulDiv.lean:150](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L150) | model-only helper (`d & -d` lemma) |
| `fold_nstep` | [AsyncSwapMulDiv.lean:209](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L209) | model-only helper (folds a Lean expression into `nstep`) |
| `nstep_spec` | [AsyncSwapMulDiv.lean:213](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L213) | model-only helper (Newton step lemma) |
| `init_spec` | [AsyncSwapMulDiv.lean:258](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L258) | model-only helper (inverse seed lemma) |
| `inv_spec` | [AsyncSwapMulDiv.lean:274](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L274) | model-only helper (inverse mod 2^256 lemma) |
| `final` | [AsyncSwapMulDiv.lean:287](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L287) | model-only helper (final-stage arithmetic lemma; its content is tested by mulDiv_ok) |
| `mulDivFloor_run` | [AsyncSwapMulDiv.lean:418](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L418) | model-only helper (unfolds the prelude `mulDivFloor`); its content is checked by `testFuzz_floor_run` |
| `mulDiv_eq_mulDivFloor_any` | [AsyncSwapMulDiv.lean:453](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L453) | model-only (relates the generated `Math.mulDiv` to the prelude `mulDivFloor`); both sides are checked on the bytecode by `testFuzz_mulDiv_spec` and `testFuzz_floor_run` |
| `two_pow_odd_aux` | [AsyncSwapMulDiv.lean:171](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L171) | not tested yet |
| `dvd_modW` | [AsyncSwapMulDiv.lean:184](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L184) | not tested yet |
| `ring_id` | [AsyncSwapMulDiv.lean:196](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L196) | not tested yet |
| `addc_W` | [AsyncSwapMulDiv.lean:460](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L460) | not tested yet |
| `mulDivRound_spec` | [AsyncSwapMulDiv.lean:469](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L469) | not tested yet |
| `mulDivRound_eq_mulDivRnd` | [AsyncSwapMulDiv.lean:489](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L489) | not tested yet |
| `mulDivRound_floor` | [AsyncSwapMulDiv.lean:504](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L504) | not tested yet |
| `mulDivRound_ceil` | [AsyncSwapMulDiv.lean:511](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapMulDiv.lean#L511) | not tested yet |

### `Proofs/Functions/AsyncSwapOrderCreatedSequence.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `orderCreatedSequence_run` | [AsyncSwapOrderCreatedSequence.lean:22](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapOrderCreatedSequence.lean#L22) | not tested yet |
| `orderCreatedSequence_never_reverts` | [AsyncSwapOrderCreatedSequence.lean:27](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapOrderCreatedSequence.lean#L27) | not tested yet |
| `orderCreatedSequence_ok` | [AsyncSwapOrderCreatedSequence.lean:32](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapOrderCreatedSequence.lean#L32) | not tested yet |

### `Proofs/Functions/AsyncSwapOverloads.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `revertWith_int_run` | [AsyncSwapOverloads.lean:24](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapOverloads.lean#L24) | not tested yet |
| `revertWith_int_never_succeeds` | [AsyncSwapOverloads.lean:27](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapOverloads.lean#L27) | not tested yet |
| `revertWith_sel_run` | [AsyncSwapOverloads.lean:31](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapOverloads.lean#L31) | not tested yet |
| `revertWith_sel_never_succeeds` | [AsyncSwapOverloads.lean:34](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapOverloads.lean#L34) | not tested yet |
| `tryRecoverBytes_eq` | [AsyncSwapOverloads.lean:45](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapOverloads.lean#L45) | not tested yet |
| `tryRecoverBytes_bad_length` | [AsyncSwapOverloads.lean:56](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapOverloads.lean#L56) | not tested yet |
| `tryRecoverBytes_noError` | [AsyncSwapOverloads.lean:62](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapOverloads.lean#L62) | not tested yet |

### `Proofs/Functions/AsyncSwapPayFiller.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `payFiller_setter_irrelevant` | [AsyncSwapPayFiller.lean:9](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapPayFiller.lean#L9) | not tested yet |
| `payFiller_expands` | [AsyncSwapPayFiller.lean:17](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapPayFiller.lean#L17) | not tested yet |

### `Proofs/Functions/AsyncSwapPayouts.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `payouts_run` | [AsyncSwapPayouts.lean:29](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapPayouts.lean#L29) | not tested yet |
| `payouts_error` | [AsyncSwapPayouts.lean:45](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapPayouts.lean#L45) | not tested yet |
| `payouts_no_revert` | [AsyncSwapPayouts.lean:53](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapPayouts.lean#L53) | not tested yet |
| `payouts_self_set_irrelevant` | [AsyncSwapPayouts.lean:62](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapPayouts.lean#L62) | not tested yet |

### `Proofs/Functions/AsyncSwapPoolBeatsBook.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `poolBeatsBook_def` | [AsyncSwapPoolBeatsBook.lean:12](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapPoolBeatsBook.lean#L12) | not tested yet |

### `Proofs/Functions/AsyncSwapPriceKey.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `priceKey_eq` | [AsyncSwapPriceKey.lean:22](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapPriceKey.lean#L22) | [`AsyncSwapHelpers.t.sol`](AsyncSwapHelpers.t.sol) `testFuzz_priceKey_eq` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `priceKey_spec` | [AsyncSwapPriceKey.lean:28](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapPriceKey.lean#L28) | not tested yet |
| `priceKey_reverts_iff` | [AsyncSwapPriceKey.lean:39](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapPriceKey.lean#L39) | not tested yet |
| `priceKey_ok_inv` | [AsyncSwapPriceKey.lean:46](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapPriceKey.lean#L46) | not tested yet |

### `Proofs/Functions/AsyncSwapReceive.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `receive_run` | [AsyncSwapReceive.lean:15](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapReceive.lean#L15) | [`AsyncSwapReceive.t.sol`](AsyncSwapReceive.t.sol) `testFuzz_receive_run` | no |
| `receive_never_reverts` | [AsyncSwapReceive.lean:20](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapReceive.lean#L20) | [`AsyncSwapReceive.t.sol`](AsyncSwapReceive.t.sol) `testFuzz_receive_never_reverts` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `receive_pending` | [AsyncSwapReceive.lean:25](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapReceive.lean#L25) | not tested yet |
| `receive_other_transient` | [AsyncSwapReceive.lean:34](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapReceive.lean#L34) | not tested yet |

### `Proofs/Functions/AsyncSwapRefresh.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `refresh_good` | [AsyncSwapRefresh.lean:27](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRefresh.lean#L27) | not tested yet |
| `refresh_reverts_only_loop_bound` | [AsyncSwapRefresh.lean:47](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRefresh.lean#L47) | not tested yet |
| `refresh_frame` | [AsyncSwapRefresh.lean:73](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRefresh.lean#L73) | not tested yet |
| `refresh_tree_set_irrelevant` | [AsyncSwapRefresh.lean:114](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRefresh.lean#L114) | not tested yet |
| `refresh_eq` | [AsyncSwapRefresh.lean:125](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRefresh.lean#L125) | not tested yet |

### `Proofs/Functions/AsyncSwapRefreshExactPrice.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `refreshExactPrice_good` | [AsyncSwapRefreshExactPrice.lean:38](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRefreshExactPrice.lean#L38) | not tested yet |
| `refreshExactPrice_reverts_only_loop_bound` | [AsyncSwapRefreshExactPrice.lean:56](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRefreshExactPrice.lean#L56) | not tested yet |
| `refreshExactPrice_frame` | [AsyncSwapRefreshExactPrice.lean:82](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRefreshExactPrice.lean#L82) | not tested yet |
| `refreshExactPrice_self_set_irrelevant` | [AsyncSwapRefreshExactPrice.lean:122](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRefreshExactPrice.lean#L122) | not tested yet |
| `refreshExactPrice_eq` | [AsyncSwapRefreshExactPrice.lean:147](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRefreshExactPrice.lean#L147) | not tested yet |

### `Proofs/Functions/AsyncSwapRemove.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `remove_good` | [AsyncSwapRemove.lean:31](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRemove.lean#L31) | not tested yet |
| `remove_reverts_only` | [AsyncSwapRemove.lean:48](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRemove.lean#L48) | not tested yet |
| `remove_reverts_missing` | [AsyncSwapRemove.lean:73](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRemove.lean#L73) | not tested yet |
| `remove_frame` | [AsyncSwapRemove.lean:87](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRemove.lean#L87) | not tested yet |
| `good_subc` | [AsyncSwapRemove.lean:134](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRemove.lean#L134) | not tested yet |
| `good_ite_app` | [AsyncSwapRemove.lean:143](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRemove.lean#L143) | not tested yet |
| `tree_remove_good` | [AsyncSwapRemove.lean:150](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRemove.lean#L150) | not tested yet |
| `filler_remove_good` | [AsyncSwapRemove.lean:164](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRemove.lean#L164) | not tested yet |
| `filler_remove_reverts_only` | [AsyncSwapRemove.lean:186](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRemove.lean#L186) | not tested yet |
| `filler_remove_frame` | [AsyncSwapRemove.lean:210](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRemove.lean#L210) | not tested yet |
| `filler_remove_self_set_irrelevant` | [AsyncSwapRemove.lean:248](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRemove.lean#L248) | not tested yet |
| `filler_remove_reverts_missing` | [AsyncSwapRemove.lean:258](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRemove.lean#L258) | not tested yet |

### `Proofs/Functions/AsyncSwapRepair.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `good_pure` | [AsyncSwapRepair.lean:37](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRepair.lean#L37) | not tested yet |
| `good_throw` | [AsyncSwapRepair.lean:40](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRepair.lean#L40) | not tested yet |
| `good_bind` | [AsyncSwapRepair.lean:43](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRepair.lean#L43) | not tested yet |
| `good_ite` | [AsyncSwapRepair.lean:53](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRepair.lean#L53) | not tested yet |
| `good_forIn_list` | [AsyncSwapRepair.lean:57](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRepair.lean#L57) | not tested yet |
| `good_forIn_range` | [AsyncSwapRepair.lean:69](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRepair.lean#L69) | not tested yet |
| `repair_good` | [AsyncSwapRepair.lean:91](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRepair.lean#L91) | not tested yet |
| `repair_reverts_only_loop_bound` | [AsyncSwapRepair.lean:110](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRepair.lean#L110) | not tested yet |
| `repair_frame` | [AsyncSwapRepair.lean:136](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRepair.lean#L136) | not tested yet |
| `repair_tree_set_irrelevant` | [AsyncSwapRepair.lean:175](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRepair.lean#L175) | not tested yet |
| `repair_cursor_zero` | [AsyncSwapRepair.lean:183](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRepair.lean#L183) | not tested yet |

### `Proofs/Functions/AsyncSwapRevertWith.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `revertWith_run` | [AsyncSwapRevertWith.lean:22](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRevertWith.lean#L22) | not tested yet |
| `revertWith_never_succeeds` | [AsyncSwapRevertWith.lean:28](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRevertWith.lean#L28) | not tested yet |
| `revertWith_uniform` | [AsyncSwapRevertWith.lean:34](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapRevertWith.lean#L34) | not tested yet |

### `Proofs/Functions/AsyncSwapSetDefaultMinOrder.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `setDefaultMinOrder_run` | [AsyncSwapSetDefaultMinOrder.lean:20](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSetDefaultMinOrder.lean#L20) | not tested yet |
| `setDefaultMinOrder_reverts_of_not_owner` | [AsyncSwapSetDefaultMinOrder.lean:29](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSetDefaultMinOrder.lean#L29) | not tested yet |
| `setDefaultMinOrder_ok_of_owner` | [AsyncSwapSetDefaultMinOrder.lean:35](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSetDefaultMinOrder.lean#L35) | not tested yet |
| `setDefaultMinOrder_ok_iff` | [AsyncSwapSetDefaultMinOrder.lean:42](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSetDefaultMinOrder.lean#L42) | not tested yet |
| `setDefaultMinOrder_frame` | [AsyncSwapSetDefaultMinOrder.lean:53](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSetDefaultMinOrder.lean#L53) | not tested yet |

### `Proofs/Functions/AsyncSwapSetExecutor.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `setExecutor_run` | [AsyncSwapSetExecutor.lean:15](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSetExecutor.lean#L15) | [`RefinementAsyncSwap.t.sol`](RefinementAsyncSwap.t.sol) `testFuzz_setExecutor_run` | with edits |
| `setExecutor_frame` | [AsyncSwapSetExecutor.lean:33](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSetExecutor.lean#L33) | [`RefinementAsyncSwap.t.sol`](RefinementAsyncSwap.t.sol) `testFuzz_setExecutor_frame` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `setExecutor_ok_iff` | [AsyncSwapSetExecutor.lean:21](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSetExecutor.lean#L21) | not tested yet |

### `Proofs/Functions/AsyncSwapSetMinOrder.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `filler_setMinOrder_run` | [AsyncSwapSetMinOrder.lean:31](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSetMinOrder.lean#L31) | not tested yet |
| `filler_setMinOrder_of_read` | [AsyncSwapSetMinOrder.lean:48](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSetMinOrder.lean#L48) | not tested yet |
| `filler_setMinOrder_poolId_irrelevant` | [AsyncSwapSetMinOrder.lean:56](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSetMinOrder.lean#L56) | not tested yet |
| `filler_setMinOrder_ok` | [AsyncSwapSetMinOrder.lean:63](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSetMinOrder.lean#L63) | not tested yet |
| `matching_setMinOrder_run` | [AsyncSwapSetMinOrder.lean:76](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSetMinOrder.lean#L76) | not tested yet |
| `matching_setMinOrder_eq_filler` | [AsyncSwapSetMinOrder.lean:92](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSetMinOrder.lean#L92) | not tested yet |
| `matching_setMinOrder_of_read` | [AsyncSwapSetMinOrder.lean:100](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSetMinOrder.lean#L100) | not tested yet |
| `matching_setMinOrder_get_error` | [AsyncSwapSetMinOrder.lean:108](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSetMinOrder.lean#L108) | not tested yet |
| `matching_setMinOrder_ok` | [AsyncSwapSetMinOrder.lean:116](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSetMinOrder.lean#L116) | not tested yet |
| `matching_setMinOrder_poolId_irrelevant` | [AsyncSwapSetMinOrder.lean:125](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSetMinOrder.lean#L125) | not tested yet |
| `setMinOrder_run` | [AsyncSwapSetMinOrder.lean:144](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSetMinOrder.lean#L144) | not tested yet |
| `setMinOrder_reverts_of_not_owner` | [AsyncSwapSetMinOrder.lean:154](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSetMinOrder.lean#L154) | not tested yet |
| `setMinOrder_ok_of_owner` | [AsyncSwapSetMinOrder.lean:160](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSetMinOrder.lean#L160) | not tested yet |
| `setMinOrder_ok_iff` | [AsyncSwapSetMinOrder.lean:167](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSetMinOrder.lean#L167) | not tested yet |
| `setMinOrder_frame` | [AsyncSwapSetMinOrder.lean:178](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSetMinOrder.lean#L178) | not tested yet |

### `Proofs/Functions/AsyncSwapSqrt.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `amgm_aux` | [AsyncSwapSqrt.lean:36](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSqrt.lean#L36) | not tested yet |
| `amgm` | [AsyncSwapSqrt.lean:40](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSqrt.lean#L40) | not tested yet |
| `sq_succ` | [AsyncSwapSqrt.lean:49](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSqrt.lean#L49) | not tested yet |
| `sq_two` | [AsyncSwapSqrt.lean:53](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSqrt.lean#L53) | not tested yet |
| `step_eq` | [AsyncSwapSqrt.lean:56](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSqrt.lean#L56) | not tested yet |
| `lower` | [AsyncSwapSqrt.lean:61](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSqrt.lean#L61) | not tested yet |
| `ne_of_inv` | [AsyncSwapSqrt.lean:73](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSqrt.lean#L73) | not tested yet |
| `step_inv` | [AsyncSwapSqrt.lean:77](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSqrt.lean#L77) | not tested yet |
| `R0_pos` | [AsyncSwapSqrt.lean:102](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSqrt.lean#L102) | not tested yet |
| `shlw_R0` | [AsyncSwapSqrt.lean:104](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSqrt.lean#L104) | not tested yet |
| `init_inv` | [AsyncSwapSqrt.lean:112](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSqrt.lean#L112) | not tested yet |
| `divc_run` | [AsyncSwapSqrt.lean:134](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSqrt.lean#L134) | not tested yet |
| `sqrt_run` | [AsyncSwapSqrt.lean:140](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSqrt.lean#L140) | not tested yet |
| `sqrt_le` | [AsyncSwapSqrt.lean:174](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapSqrt.lean#L174) | not tested yet |

### `Proofs/Functions/AsyncSwapTickBounds.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `wrapI256_id` | [AsyncSwapTickBounds.lean:24](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickBounds.lean#L24) | not tested yet |
| `wrapI24_id` | [AsyncSwapTickBounds.lean:28](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickBounds.lean#L28) | not tested yet |
| `ts_tu` | [AsyncSwapTickBounds.lean:32](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickBounds.lean#L32) | not tested yet |
| `tu_ts` | [AsyncSwapTickBounds.lean:39](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickBounds.lean#L39) | not tested yet |
| `rung_x` | [AsyncSwapTickBounds.lean:47](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickBounds.lean#L47) | not tested yet |
| `rung_spec` | [AsyncSwapTickBounds.lean:71](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickBounds.lean#L71) | not tested yet |
| `inv_step` | [AsyncSwapTickBounds.lean:94](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickBounds.lean#L94) | not tested yet |
| `log0_eq` | [AsyncSwapTickBounds.lean:119](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickBounds.lean#L119) | not tested yet |
| `logR_bounds` | [AsyncSwapTickBounds.lean:128](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickBounds.lean#L128) | not tested yet |
| `ticks_bounds` | [AsyncSwapTickBounds.lean:169](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickBounds.lean#L169) | not tested yet |
| `sqrt_min` | [AsyncSwapTickBounds.lean:181](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickBounds.lean#L181) | not tested yet |
| `norm_lt` | [AsyncSwapTickBounds.lean:185](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickBounds.lean#L185) | not tested yet |
| `logOf_bounds` | [AsyncSwapTickBounds.lean:205](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickBounds.lean#L205) | not tested yet |
| `getTickAtSqrtPrice_bounded` | [AsyncSwapTickBounds.lean:231](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickBounds.lean#L231) | not tested yet |

### `Proofs/Functions/AsyncSwapTickPrice.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `divc_pure` | [AsyncSwapTickPrice.lean:35](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickPrice.lean#L35) | not tested yet |
| `mulDivFloor_ok` | [AsyncSwapTickPrice.lean:38](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickPrice.lean#L38) | not tested yet |
| `scaled_bounds` | [AsyncSwapTickPrice.lean:47](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickPrice.lean#L47) | not tested yet |
| `mulDivFloor_bind` | [AsyncSwapTickPrice.lean:59](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickPrice.lean#L59) | not tested yet |
| `sqrt_bind` | [AsyncSwapTickPrice.lean:65](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickPrice.lean#L65) | not tested yet |
| `floorTick_den_zero` | [AsyncSwapTickPrice.lean:76](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickPrice.lean#L76) | not tested yet |
| `floorTick_eq_small` | [AsyncSwapTickPrice.lean:80](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickPrice.lean#L80) | not tested yet |
| `floorTick_eq_huge` | [AsyncSwapTickPrice.lean:90](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickPrice.lean#L90) | not tested yet |
| `floorTick_eq_mid` | [AsyncSwapTickPrice.lean:97](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickPrice.lean#L97) | not tested yet |
| `floorTick_run_small` | [AsyncSwapTickPrice.lean:109](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickPrice.lean#L109) | not tested yet |
| `floorTick_run_huge` | [AsyncSwapTickPrice.lean:119](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickPrice.lean#L119) | not tested yet |
| `floorTick_run_mid` | [AsyncSwapTickPrice.lean:132](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickPrice.lean#L132) | not tested yet |
| `clamp_result` | [AsyncSwapTickPrice.lean:144](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickPrice.lean#L144) | not tested yet |
| `floorTick_result` | [AsyncSwapTickPrice.lean:168](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickPrice.lean#L168) | not tested yet |
| `key_eq_true` | [AsyncSwapTickPrice.lean:210](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickPrice.lean#L210) | not tested yet |
| `key_eq_false` | [AsyncSwapTickPrice.lean:220](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickPrice.lean#L220) | not tested yet |
| `key_eq` | [AsyncSwapTickPrice.lean:231](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickPrice.lean#L231) | not tested yet |
| `toUnsigned24_of` | [AsyncSwapTickPrice.lean:240](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickPrice.lean#L240) | not tested yet |
| `fits24` | [AsyncSwapTickPrice.lean:244](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickPrice.lean#L244) | not tested yet |
| `bucket_run` | [AsyncSwapTickPrice.lean:250](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickPrice.lean#L250) | not tested yet |
| `key_run` | [AsyncSwapTickPrice.lean:277](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickPrice.lean#L277) | not tested yet |
| `key_error` | [AsyncSwapTickPrice.lean:290](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickPrice.lean#L290) | not tested yet |
| `key_zero_den` | [AsyncSwapTickPrice.lean:299](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickPrice.lean#L299) | not tested yet |
| `keyPure_range` | [AsyncSwapTickPrice.lean:306](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickPrice.lean#L306) | not tested yet |
| `keyPure_strictMono_buy` | [AsyncSwapTickPrice.lean:315](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickPrice.lean#L315) | not tested yet |
| `keyPure_strictAnti_sell` | [AsyncSwapTickPrice.lean:325](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTickPrice.lean#L325) | not tested yet |

### `Proofs/Functions/AsyncSwapTradeFee.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `tradeFee_eq` | [AsyncSwapTradeFee.lean:8](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTradeFee.lean#L8) | not tested yet |
| `tradeFee_success` | [AsyncSwapTradeFee.lean:15](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTradeFee.lean#L15) | not tested yet |
| `tradeFee_footprint` | [AsyncSwapTradeFee.lean:21](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTradeFee.lean#L21) | not tested yet |

### `Proofs/Functions/AsyncSwapTryRecover.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `tryRecover_eq` | [AsyncSwapTryRecover.lean:30](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTryRecover.lean#L30) | not tested yet |
| `tryRecover_high_s` | [AsyncSwapTryRecover.lean:40](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTryRecover.lean#L40) | not tested yet |
| `tryRecover_zero_signer` | [AsyncSwapTryRecover.lean:46](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTryRecover.lean#L46) | not tested yet |
| `tryRecover_ok` | [AsyncSwapTryRecover.lean:52](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTryRecover.lean#L52) | not tested yet |
| `tryRecover_noError_signer_ne_zero` | [AsyncSwapTryRecover.lean:60](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapTryRecover.lean#L60) | not tested yet |

### `Proofs/Functions/AsyncSwapUpdatePrice.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `updatePrice_notOwner` | [AsyncSwapUpdatePrice.lean:109](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L109) | [`AsyncSwapUpdatePrice.t.sol`](AsyncSwapUpdatePrice.t.sol) `testFuzz_updatePrice_notOwner` | yes |
| `updatePrice_zero` | [AsyncSwapUpdatePrice.lean:116](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L116) | [`AsyncSwapUpdatePrice.t.sol`](AsyncSwapUpdatePrice.t.sol) `testFuzz_updatePrice_zero` | yes |
| `updatePrice_notFound` | [AsyncSwapUpdatePrice.lean:123](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L123) | [`AsyncSwapUpdatePrice.t.sol`](AsyncSwapUpdatePrice.t.sol) `testFuzz_updatePrice_notFound` | no |
| `updatePrice_ok` | [AsyncSwapUpdatePrice.lean:180](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L180) | [`AsyncSwapUpdatePrice.t.sol`](AsyncSwapUpdatePrice.t.sol) `testFuzz_updatePrice_ok` | no |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `priceKey_ok_iff` | [AsyncSwapUpdatePrice.lean:58](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L58) | not tested yet |
| `priceKey_error` | [AsyncSwapUpdatePrice.lean:75](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L75) | not tested yet |
| `tail_fin` | [AsyncSwapUpdatePrice.lean:146](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L146) | not tested yet |
| `checkMinimum_frame` | [AsyncSwapUpdatePrice.lean:255](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L255) | not tested yet |
| `updatePrice_ok_frame` | [AsyncSwapUpdatePrice.lean:276](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L276) | not tested yet |
| `updatePrice_error` | [AsyncSwapUpdatePrice.lean:335](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L335) | not tested yet |
| `hsg` | [AsyncSwapUpdatePrice.lean:426](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L426) | not tested yet |
| `hss` | [AsyncSwapUpdatePrice.lean:427](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L427) | not tested yet |
| `hbg` | [AsyncSwapUpdatePrice.lean:428](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L428) | not tested yet |
| `hbs` | [AsyncSwapUpdatePrice.lean:429](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L429) | not tested yet |
| `l1` | [AsyncSwapUpdatePrice.lean:434](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L434) | not tested yet |
| `l2` | [AsyncSwapUpdatePrice.lean:436](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L436) | not tested yet |
| `l3` | [AsyncSwapUpdatePrice.lean:438](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L438) | not tested yet |
| `l4` | [AsyncSwapUpdatePrice.lean:440](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L440) | not tested yet |
| `updatePrice_eq` | [AsyncSwapUpdatePrice.lean:448](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L448) | not tested yet |
| `updatePriceWithSig_eq` | [AsyncSwapUpdatePrice.lean:461](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L461) | not tested yet |
| `entry_notOwner` | [AsyncSwapUpdatePrice.lean:485](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L485) | not tested yet |
| `entry_zero` | [AsyncSwapUpdatePrice.lean:492](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L492) | not tested yet |
| `entry_notFound` | [AsyncSwapUpdatePrice.lean:499](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L499) | not tested yet |
| `entry_error` | [AsyncSwapUpdatePrice.lean:512](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L512) | not tested yet |
| `entry_ok` | [AsyncSwapUpdatePrice.lean:527](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L527) | not tested yet |
| `entrySig_error` | [AsyncSwapUpdatePrice.lean:550](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L550) | not tested yet |
| `entrySig_ok` | [AsyncSwapUpdatePrice.lean:575](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePrice.lean#L575) | not tested yet |

### `Proofs/Functions/AsyncSwapUpdatePriceIte.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `ite_err_ok_eq` | [AsyncSwapUpdatePriceIte.lean:12](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePriceIte.lean#L12) | not tested yet |
| `ite_err_ok_eq_err` | [AsyncSwapUpdatePriceIte.lean:17](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePriceIte.lean#L17) | not tested yet |
| `ite_ok_err_eq_err` | [AsyncSwapUpdatePriceIte.lean:21](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUpdatePriceIte.lean#L21) | not tested yet |

### `Proofs/Functions/AsyncSwapUseNonce.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `useNonce_reverts_not_executor` | [AsyncSwapUseNonce.lean:15](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUseNonce.lean#L15) | not tested yet |
| `useNonce_reverts_used` | [AsyncSwapUseNonce.lean:22](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUseNonce.lean#L22) | not tested yet |
| `useNonce_success` | [AsyncSwapUseNonce.lean:30](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUseNonce.lean#L30) | not tested yet |
| `useNonce_ok_iff` | [AsyncSwapUseNonce.lean:41](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUseNonce.lean#L41) | not tested yet |
| `useNonce_frame` | [AsyncSwapUseNonce.lean:60](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUseNonce.lean#L60) | not tested yet |

### `Proofs/Functions/AsyncSwapUseNonceInternal.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `_useNonce_reverts_used` | [AsyncSwapUseNonceInternal.lean:20](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUseNonceInternal.lean#L20) | not tested yet |
| `_useNonce_success` | [AsyncSwapUseNonceInternal.lean:25](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUseNonceInternal.lean#L25) | not tested yet |
| `_useNonce_ok_iff` | [AsyncSwapUseNonceInternal.lean:32](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUseNonceInternal.lean#L32) | not tested yet |
| `_useNonce_frame` | [AsyncSwapUseNonceInternal.lean:43](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUseNonceInternal.lean#L43) | not tested yet |
| `_useNonce_no_replay` | [AsyncSwapUseNonceInternal.lean:70](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/AsyncSwapUseNonceInternal.lean#L70) | not tested yet |

### `Proofs/Functions/RouterCancelOrder.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `cancelOrder_run` | [RouterCancelOrder.lean:10](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/RouterCancelOrder.lean#L10) | [`AsyncSwapCancelOrder.t.sol`](AsyncSwapCancelOrder.t.sol) `testFuzz_cancelOrder_run` | no |

### `Proofs/Functions/RouterRequireUnchanged.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `requireUnchanged_run` | [RouterRequireUnchanged.lean:23](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/RouterRequireUnchanged.lean#L23) | not tested yet |
| `requireUnchanged_ok_iff` | [RouterRequireUnchanged.lean:45](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/RouterRequireUnchanged.lean#L45) | not tested yet |
| `requireUnchanged_reverts_changed` | [RouterRequireUnchanged.lean:67](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/RouterRequireUnchanged.lean#L67) | not tested yet |
| `requireUnchanged_reverts_view` | [RouterRequireUnchanged.lean:77](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/RouterRequireUnchanged.lean#L77) | not tested yet |
| `requireUnchanged_frame` | [RouterRequireUnchanged.lean:84](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/RouterRequireUnchanged.lean#L84) | not tested yet |

### `Proofs/Functions/RouterTryRecoverBytes.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `tryRecoverBytes_bad_length` | [RouterTryRecoverBytes.lean:18](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/RouterTryRecoverBytes.lean#L18) | not tested yet |
| `tryRecoverBytes_len65` | [RouterTryRecoverBytes.lean:25](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/RouterTryRecoverBytes.lean#L25) | not tested yet |

### `Proofs/Functions/TokenClaimsNonReentrant.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `nonReentrant_reverts` | [TokenClaimsNonReentrant.lean:10](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/TokenClaimsNonReentrant.lean#L10) | not tested yet |
| `nonReentrant_run` | [TokenClaimsNonReentrant.lean:19](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/TokenClaimsNonReentrant.lean#L19) | not tested yet |
| `nonReentrant_ok_iff` | [TokenClaimsNonReentrant.lean:33](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/TokenClaimsNonReentrant.lean#L33) | not tested yet |

### `Proofs/Functions/TokenClaimsRedeem.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `redeem_reentrant` | [TokenClaimsRedeem.lean:9](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/TokenClaimsRedeem.lean#L9) | [`NativeClaimsRedeem.t.sol`](NativeClaimsRedeem.t.sol) `testFuzz_redeem_reentrant` | yes |
| `redeem_invalid` | [TokenClaimsRedeem.lean:15](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/TokenClaimsRedeem.lean#L15) | [`NativeClaimsRedeem.t.sol`](NativeClaimsRedeem.t.sol) `testFuzz_redeem_invalid` | yes |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `redeem_call` | [TokenClaimsRedeem.lean:23](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/TokenClaimsRedeem.lean#L23) | not tested yet |
| `redeem_guard_reverts` | [TokenClaimsRedeem.lean:41](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/TokenClaimsRedeem.lean#L41) | not tested yet |

### `Proofs/Functions/TokenClaimsUnlockCallback.lean`

| Theorem | Lean | Test | Halmos |
|---|---|---|---|
| `unlockCallback_onlyPoolManager` | [TokenClaimsUnlockCallback.lean:9](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/TokenClaimsUnlockCallback.lean#L9) | [`NativeClaimsUnlockCallback.t.sol`](NativeClaimsUnlockCallback.t.sol) `testFuzz_unlockCallback_onlyPoolManager` | yes |

Left out:

| Theorem | Lean | Reason |
|---|---|---|
| `unlockCallback_short` | [TokenClaimsUnlockCallback.lean:15](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/TokenClaimsUnlockCallback.lean#L15) | not tested yet |
| `unlockCallback_badAddress` | [TokenClaimsUnlockCallback.lean:32](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/TokenClaimsUnlockCallback.lean#L32) | not tested yet |
| `unlockCallback_success` | [TokenClaimsUnlockCallback.lean:60](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/TokenClaimsUnlockCallback.lean#L60) | not tested yet |
| `unlockCallback_reverts_iff_guards` | [TokenClaimsUnlockCallback.lean:93](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Functions/TokenClaimsUnlockCallback.lean#L93) | not tested yet |

### `Proofs/InformalSpecs/S03/TickPriceKey.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `S03.TickPrice_key` | [TickPriceKey.lean:20](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/InformalSpecs/S03/TickPriceKey.lean#L20) | not tested yet |

### `Proofs/Monad.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `run_bind` | [Monad.lean:14](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Monad.lean#L14) | model-only helper (simp lemma about the Lean monad / ABI encoding) |
| `run_pure` | [Monad.lean:20](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Monad.lean#L20) | model-only helper (simp lemma about the Lean monad / ABI encoding) |
| `run_read` | [Monad.lean:23](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Monad.lean#L23) | model-only helper (simp lemma about the Lean monad / ABI encoding) |
| `run_readThe` | [Monad.lean:26](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Monad.lean#L26) | model-only helper (simp lemma about the Lean monad / ABI encoding) |
| `run_get` | [Monad.lean:29](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Monad.lean#L29) | model-only helper (simp lemma about the Lean monad / ABI encoding) |
| `run_modify` | [Monad.lean:32](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Monad.lean#L32) | model-only helper (simp lemma about the Lean monad / ABI encoding) |
| `run_throw` | [Monad.lean:35](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Monad.lean#L35) | model-only helper (simp lemma about the Lean monad / ABI encoding) |
| `run_ite` | [Monad.lean:38](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Monad.lean#L38) | model-only helper (simp lemma about the Lean monad / ABI encoding) |
| `run_map` | [Monad.lean:47](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Monad.lean#L47) | model-only helper (simp lemma about the Lean monad / ABI encoding) |
| `ite_ok_error_eq_ok` | [Monad.lean:58](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Monad.lean#L58) | model-only helper (simp lemma about the Lean monad / ABI encoding) |

### `Proofs/Repricing.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `hash_run` | [Repricing.lean:15](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Repricing.lean#L15) | not tested yet |
| `replacement_message_distinct` | [Repricing.lean:26](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Repricing.lean#L26) | not tested yet |

### `Proofs/Settlement.lean`

No test:

| Theorem | Lean | Reason |
|---|---|---|
| `transfer_run` | [Settlement.lean:8](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Settlement.lean#L8) | not tested yet |
| `best_exact` | [Settlement.lean:18](https://github.com/asyncswap/contracts/blob/5901aca/formal/Proofs/Settlement.lean#L18) | not tested yet |

### Tests whose theorem is gone

These tests still check the bytecode and pass, but the theorem each is named after was retired with the earlier proofs
(contracts f243b0b) and isn't in `formal/Proofs/` now. They stay as bytecode checks; map them again as the swarm
re-proves those properties.

| Test file | Tests |
|---|---|
| [`AsyncSwapAcceptOwnership.t.sol`](AsyncSwapAcceptOwnership.t.sol) | 5 |
| [`AsyncSwapAddOrder.t.sol`](AsyncSwapAddOrder.t.sol) | 19 |
| [`AsyncSwapAfterAddLiquidity.t.sol`](AsyncSwapAfterAddLiquidity.t.sol) | 4 |
| [`AsyncSwapAfterDonate.t.sol`](AsyncSwapAfterDonate.t.sol) | 4 |
| [`AsyncSwapAfterInitialize.t.sol`](AsyncSwapAfterInitialize.t.sol) | 4 |
| [`AsyncSwapAfterRemoveLiquidity.t.sol`](AsyncSwapAfterRemoveLiquidity.t.sol) | 4 |
| [`AsyncSwapAfterSwap.t.sol`](AsyncSwapAfterSwap.t.sol) | 4 |
| [`AsyncSwapAsyncOrder.t.sol`](AsyncSwapAsyncOrder.t.sol) | 4 |
| [`AsyncSwapAsyncOrderInfo.t.sol`](AsyncSwapAsyncOrderInfo.t.sol) | 4 |
| [`AsyncSwapAsyncOrderPriorityFee.t.sol`](AsyncSwapAsyncOrderPriorityFee.t.sol) | 5 |
| [`AsyncSwapBeforeAddLiquidity.t.sol`](AsyncSwapBeforeAddLiquidity.t.sol) | 5 |
| [`AsyncSwapBeforeDonate.t.sol`](AsyncSwapBeforeDonate.t.sol) | 4 |
| [`AsyncSwapBeforeInitialize.t.sol`](AsyncSwapBeforeInitialize.t.sol) | 11 |
| [`AsyncSwapBeforeRemoveLiquidity.t.sol`](AsyncSwapBeforeRemoveLiquidity.t.sol) | 4 |
| [`AsyncSwapBeforeSwap.t.sol`](AsyncSwapBeforeSwap.t.sol) | 14 |
| [`AsyncSwapBestOrder.t.sol`](AsyncSwapBestOrder.t.sol) | 6 |
| [`AsyncSwapBitSet.t.sol`](AsyncSwapBitSet.t.sol) | 3 |
| [`AsyncSwapBubbleUpAndRevertWith.t.sol`](AsyncSwapBubbleUpAndRevertWith.t.sol) | 4 |
| [`AsyncSwapCalculateHookFee.t.sol`](AsyncSwapCalculateHookFee.t.sol) | 4 |
| [`AsyncSwapCalculatePoolFee.t.sol`](AsyncSwapCalculatePoolFee.t.sol) | 4 |
| [`AsyncSwapCallOptionalReturn.t.sol`](AsyncSwapCallOptionalReturn.t.sol) | 4 |
| [`AsyncSwapCancelOrder.t.sol`](AsyncSwapCancelOrder.t.sol) | 6 |
| [`AsyncSwapConstructor.t.sol`](AsyncSwapConstructor.t.sol) | 10 |
| [`AsyncSwapCrosses.t.sol`](AsyncSwapCrosses.t.sol) | 6 |
| [`AsyncSwapDOMAIN_SEPARATOR.t.sol`](AsyncSwapDOMAIN_SEPARATOR.t.sol) | 3 |
| [`AsyncSwapExecuteOrder.t.sol`](AsyncSwapExecuteOrder.t.sol) | 12 |
| [`AsyncSwapFillOrderFromPoolLiquidity.t.sol`](AsyncSwapFillOrderFromPoolLiquidity.t.sol) | 7 |
| [`AsyncSwapFreeNode.t.sol`](AsyncSwapFreeNode.t.sol) | 4 |
| [`AsyncSwapFunctionCall.t.sol`](AsyncSwapFunctionCall.t.sol) | 3 |
| [`AsyncSwapFunctionCallWithValue.t.sol`](AsyncSwapFunctionCallWithValue.t.sol) | 3 |
| [`AsyncSwapGetHookPermissions.t.sol`](AsyncSwapGetHookPermissions.t.sol) | 4 |
| [`AsyncSwapHelpers.t.sol`](AsyncSwapHelpers.t.sol) | 25 |
| [`AsyncSwapInsert.t.sol`](AsyncSwapInsert.t.sol) | 7 |
| [`AsyncSwapInvalidateNonce.t.sol`](AsyncSwapInvalidateNonce.t.sol) | 6 |
| [`AsyncSwapLibHelpers.t.sol`](AsyncSwapLibHelpers.t.sol) | 15 |
| [`AsyncSwapMatchAmounts.t.sol`](AsyncSwapMatchAmounts.t.sol) | 11 |
| [`AsyncSwapMatchBook.t.sol`](AsyncSwapMatchBook.t.sol) | 4 |
| [`AsyncSwapMatchNewOrder.t.sol`](AsyncSwapMatchNewOrder.t.sol) | 8 |
| [`AsyncSwapMatchPair.t.sol`](AsyncSwapMatchPair.t.sol) | 7 |
| [`AsyncSwapMostSignificantBit.t.sol`](AsyncSwapMostSignificantBit.t.sol) | 4 |
| [`AsyncSwapNewNode.t.sol`](AsyncSwapNewNode.t.sol) | 4 |
| [`AsyncSwapOnlyOwner.t.sol`](AsyncSwapOnlyOwner.t.sol) | 5 |
| [`AsyncSwapOrderBookLevel.t.sol`](AsyncSwapOrderBookLevel.t.sol) | 3 |
| [`AsyncSwapOrderBookOrder.t.sol`](AsyncSwapOrderBookOrder.t.sol) | 4 |
| [`AsyncSwapPriorityKey.t.sol`](AsyncSwapPriorityKey.t.sol) | 3 |
| [`AsyncSwapReceive.t.sol`](AsyncSwapReceive.t.sol) | 3 |
| [`AsyncSwapReduceAfterMatch.t.sol`](AsyncSwapReduceAfterMatch.t.sol) | 3 |
| [`AsyncSwapReduceMatchedOrders.t.sol`](AsyncSwapReduceMatchedOrders.t.sol) | 3 |
| [`AsyncSwapRemove.t.sol`](AsyncSwapRemove.t.sol) | 5 |
| [`AsyncSwapRevert.t.sol`](AsyncSwapRevert.t.sol) | 4 |
| [`AsyncSwapSafeTransferFrom.t.sol`](AsyncSwapSafeTransferFrom.t.sol) | 2 |
| [`AsyncSwapSetExecutorWithSig.t.sol`](AsyncSwapSetExecutorWithSig.t.sol) | 8 |
| [`AsyncSwapSettleMatchedPriorityFee.t.sol`](AsyncSwapSettleMatchedPriorityFee.t.sol) | 4 |
| [`AsyncSwapSettleOrderPriorityFee.t.sol`](AsyncSwapSettleOrderPriorityFee.t.sol) | 3 |
| [`AsyncSwapSettleTransfers.t.sol`](AsyncSwapSettleTransfers.t.sol) | 4 |
| [`AsyncSwapSwapAgainstPool.t.sol`](AsyncSwapSwapAgainstPool.t.sol) | 5 |
| [`AsyncSwapSweep.t.sol`](AsyncSwapSweep.t.sol) | 6 |
| [`AsyncSwapTransferEscrow.t.sol`](AsyncSwapTransferEscrow.t.sol) | 6 |
| [`AsyncSwapTransferOwnership.t.sol`](AsyncSwapTransferOwnership.t.sol) | 6 |
| [`AsyncSwapTryFillOrderFromPoolLiquidity.t.sol`](AsyncSwapTryFillOrderFromPoolLiquidity.t.sol) | 8 |
| [`AsyncSwapUpdatePrice.t.sol`](AsyncSwapUpdatePrice.t.sol) | 7 |
| [`AsyncSwapUpdatePriceWithSig.t.sol`](AsyncSwapUpdatePriceWithSig.t.sol) | 12 |
| [`AsyncSwapVerifyCallResultFromTarget.t.sol`](AsyncSwapVerifyCallResultFromTarget.t.sol) | 3 |
| [`Eip712ConstantsLog.t.sol`](Eip712ConstantsLog.t.sol) | 1 |
| [`Eip712Domain.t.sol`](Eip712Domain.t.sol) | 7 |
| [`FeeVaultCollect.t.sol`](FeeVaultCollect.t.sol) | 7 |
| [`FeeVaultUnlockCallback.t.sol`](FeeVaultUnlockCallback.t.sol) | 11 |
| [`NativeClaimsRedeem.t.sol`](NativeClaimsRedeem.t.sol) | 5 |
| [`NativeClaimsUnlockCallback.t.sol`](NativeClaimsUnlockCallback.t.sol) | 7 |
| [`RefinementAsyncSwap.t.sol`](RefinementAsyncSwap.t.sol) | 2 |
| [`RefinementRouter.t.sol`](RefinementRouter.t.sol) | 9 |
| [`RouterCancelWithSig.t.sol`](RouterCancelWithSig.t.sol) | 9 |
| [`RouterConstructor.t.sol`](RouterConstructor.t.sol) | 10 |
| [`RouterDOMAIN_SEPARATOR.t.sol`](RouterDOMAIN_SEPARATOR.t.sol) | 3 |
| [`RouterFillFromPoolLiquidity.t.sol`](RouterFillFromPoolLiquidity.t.sol) | 4 |
| [`RouterHelpers.t.sol`](RouterHelpers.t.sol) | 14 |
| [`RouterLibHelpers.t.sol`](RouterLibHelpers.t.sol) | 14 |
| [`RouterMatchBook.t.sol`](RouterMatchBook.t.sol) | 3 |
| [`RouterSwapWithSig.t.sol`](RouterSwapWithSig.t.sol) | 9 |
| [`RoutingPoolImpact.t.sol`](RoutingPoolImpact.t.sol) | 2 |
| [`SpecBook.t.sol`](SpecBook.t.sol) | 8 |
| [`SpecCore.t.sol`](SpecCore.t.sol) | 23 |
| [`SpecEip712.t.sol`](SpecEip712.t.sol) | 25 |
| [`SpecSig.t.sol`](SpecSig.t.sol) | 22 |
