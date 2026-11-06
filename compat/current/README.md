# PR #81 acceptance tests for the Huff port

The target is Solidity commit **3f4a5f106f55cc4b90b11d0ce0f0143f5e64ed89**, including incoming-memory matching, fee top-ups and LP routing. Actual Huff bytecode now passes **762 upstream tests and invariant predicates**, up from 383. Assertions, expected values and fuzz assumptions remain unchanged.

| Coverage | Count |
| --- | ---: |
| Pinned upstream tests, including one finding | 1,088 |
| Passing Huff tests and invariant predicates | **762** |
| Forge result entries (invariants grouped) | 752 |
| Runnable upstream tests still unported | **325** |
| Upstream finding excluded from normal runs | 1 |
| Verbatim source/test files retained | 221 |
| Generated Huff test/support adapters | 132 |
| Reference-only test/support files | 65 |

The [per-test inventory](results/coverage.json) lists every upstream test by file, contract and name. This is partial coverage, not complete behavioral equivalence. Remaining work includes Solidity internal-library harnesses, raw storage/write-footprint checks, inherited constructor/domain helpers, and specialized book/fuzz harnesses. Copying those files or running their Solidity implementations would not establish Huff coverage.

**Counting correction:** older reports described the difference between 373 Forge entries and 383 discovered tests as ten excluded findings. It was ten additional invariant predicates grouped into four suite results. All passed. The pinned upstream source has one excluded finding, in an unported ShortString specification test.

## What the expansion found

The additional 379 tests exposed and now cover these fixes:

- Match reductions and claim credits follow Solidity order: bids, both net proceeds, both trade fees, then refunds; per-order fee events follow settlement.
- Tick keys decide unequal price levels; equal keys use full-width ratio arithmetic. Zero maker minimums preserve the expected division failure.
- Freed radix nodes retain their word until reuse, matching the free-list behavior; corrupt bitmap paths reject empty occupied children.
- Uninitialized pool admission and empty pending orders reject invalid calls. LP partial-fill errors precede invalid-output errors.
- FeeVault and NativeClaims decode dynamic callback arguments and malformed address words with Solidity-compatible authorization/revert ordering.

Shared authorization, order-ID hashing and bitmap scans reduce runtime duplication. The hook is **24,073 bytes**, 385 bytes smaller than the previous 24,458-byte port and 503 bytes below EIP-170. The Router remains **10,623 bytes**, including immutables. Initcode checks also pass.

## Fixtures and unchanged assertions

`reference/contracts/` is copied verbatim using `git show` at the pinned commit. `manifest.json` records source, adapter and assertion hashes. The generator rejects changes to `assert*`, `expectRevert`, `expectEmit`, `expectCall` and `assume` expressions.

Protocol deployments compile `.huff` sources through `CurrentHuffDeploy`. Explicit fixture adapters translate order/bitmap/radix storage locations, read actual immutable bytes, and inspect actual transient reentrancy storage. They do not substitute expected results for observations. Math, radix and price-key harnesses execute the production Huff routines. Constructor fixtures bypass only hook-address mining, as their upstream subclasses did. The nonce replay fixture includes the previously accepted trusted-Router grant fix from contracts commit `c8d12dd`.

Solidity imports remain for ABI types, mocks and independent reference calculations. Such helpers are not counted as Huff implementations. Generated files must be changed through `script/current_adapters.py` or the sync script, never by weakening a failing test.

## Validation

| Campaign | Passing tests/predicates | Configuration |
| --- | ---: | --- |
| Current acceptance | 762 | 256 cases per fuzz test; invariants 64 × 64; three Unichain fork tests at block 61709000 |
| Extended matching/reference/formal | 85 | 2,048 cases per fuzz test; saved counterexample seed |
| Legacy and differential | 208 | 195 grouped entries; includes three pinned fork tests |
| Size and signature-memory checks | 3 | Runtime/immutable tails, initcode, long ERC-1271 signature |

Campaigns overlap and must not be added together. Validation uses Forge 1.8.6, hnc 1.6.2 and solc 0.8.26. [Expanded results and source hashes](results/expanded-validation.json) record the campaigns. Earlier records preserve previous port stages. CI checks generated copies, runs acceptance/legacy tests, repeats the extended campaign and enforces size/memory checks.

```sh
python3 script/sync-current-tests.py /path/to/pinned/contracts --check
FOUNDRY_PROFILE=current UNICHAIN_FORK_RPC_URL=https://mainnet.unichain.org \
  UNICHAIN_FORK_BLOCK=61709000 forge test
FOUNDRY_PROFILE=current FOUNDRY_TEST=compat/current/checks forge test
```

To regenerate the inventory, save `forge test --no-match-test '^$' --list --json` from each repository and the current profile's `forge test --json` result. Pass them to `script/report-current-coverage.py --source-list … --huff-list … --results …`. It requires a passing execution result for every adapted test, including each grouped invariant predicate.

See the [Router receipt benchmark](../../benchmarks/crossing/README.md) and [optimizer sweep](../../benchmarks/optimizer-runs/README.md). This port has not been independently audited or deployed publicly.
