# PR #81 acceptance tests for the Huff port

The target is Solidity commit **3f4a5f106f55cc4b90b11d0ce0f0143f5e64ed89**, including incoming-memory matching, fee top-ups and LP routing. Actual Huff bytecode now passes **804 upstream tests and invariant predicates**, up from 762. Assertions, expected values and fuzz assumptions remain unchanged.

| Coverage | Count |
| --- | ---: |
| Pinned upstream tests, including one finding | 1,088 |
| Passing Huff tests and invariant predicates | **804** |
| Forge result entries (invariants grouped) | 794 |
| Runnable upstream tests still unported | **283** |
| Upstream finding excluded from normal runs | 1 |
| Verbatim source/test files retained | 221 |
| Generated Huff test/support adapters | 137 |
| Reference-only test/support files | 60 |

The [per-test inventory](results/coverage.json) lists every upstream test by file, contract and name. This is partial coverage, not complete behavioral equivalence. Remaining work includes Solidity internal-library harnesses, raw storage/write-footprint checks, inherited constructor/domain helpers, and specialized book/fuzz harnesses. Copying those files or running their Solidity implementations would not establish Huff coverage.

**Counting correction:** older reports described the difference between 373 Forge entries and 383 discovered tests as ten excluded findings. It was ten additional invariant predicates grouped into four suite results. All passed. The pinned upstream source has one excluded finding, in an unported ShortString specification test.

## Follow-up after merged PR #6

The 42 additional unchanged upstream tests cover signature hashing/ERC-1271 (22), direct crossing (6), priority keys (3), bitmap mutations (3), and pool-versus-book price selection (8). Thin ABI fixtures call the same Huff routines used by the production hook.

Direct crossing now preserves `mulDiv`'s division-by-zero and overflow reverts for arbitrary stored records. Bitmap insert/remove reject out-of-domain keys, duplicate inserts return false, and missing removals revert. Book indexing and incoming-order storage access were separated from funding so direct tests can exercise production routines without replacement implementations.

An additional differential check found a pre-existing reversed sell-side saturation comparison: the fee window could zero a still-positive pool key and choose the book incorrectly. The fix passes 4,096 cases against the pinned Solidity library, plus a regression for both quote orientations. These two new checks are separate from the 804 upstream tests.

## Findings covered by merged PR #6

The earlier expansion of 379 tests exposed and now cover these fixes:

- Match reductions and claim credits follow Solidity order: bids, both net proceeds, both trade fees, then refunds; per-order fee events follow settlement.
- Tick keys decide unequal price levels; equal keys use full-width ratio arithmetic. Zero maker minimums preserve the expected division failure.
- Freed radix nodes retain their word until reuse, matching the free-list behavior; corrupt bitmap paths reject empty occupied children.
- Uninitialized pool admission and empty pending orders reject invalid calls. LP partial-fill errors precede invalid-output errors.
- FeeVault and NativeClaims decode dynamic callback arguments and malformed address words with Solidity-compatible authorization/revert ordering.

The hook is **24,248 bytes**, including immutables, leaving **328 bytes** below EIP-170. The Router is **10,637 bytes**. Both initcode checks pass. Compared with merged PR #6, the hook grew 175 bytes and the Router 14 bytes. The [receipt benchmark](../../benchmarks/crossing/README.md) retains the gas savings; changes versus merged Huff range from −0.072% to +0.047%.

## Fixtures and unchanged assertions

`reference/contracts/` is copied verbatim using `git show` at the pinned commit. `manifest.json` records source, adapter and assertion hashes. The generator rejects changes to `assert*`, `expectRevert`, `expectEmit`, `expectCall` and `assume` expressions.

Protocol deployments compile `.huff` sources through `CurrentHuffDeploy`. Explicit fixture adapters translate order/bitmap/radix storage locations, read actual immutable bytes, and inspect actual transient reentrancy storage. They do not substitute expected results for observations. Math, radix and price-key harnesses execute the production Huff routines. Constructor fixtures bypass only hook-address mining, as their upstream subclasses did. The nonce replay fixture includes the previously accepted trusted-Router grant fix from contracts commit `c8d12dd`.

Solidity imports remain for ABI types, mocks and independent reference calculations. Such helpers are not counted as Huff implementations. Generated files must be changed through `script/current_adapters.py` or the sync script, never by weakening a failing test.

## Validation

| Campaign | Passing tests/predicates | Configuration |
| --- | ---: | --- |
| Current acceptance | 804 | 256 cases per fuzz test; invariants 64 × 64; three Unichain fork tests at block 61709000 |
| Extended matching/reference/formal | 127 | 2,048 cases per fuzz test; saved counterexample seed |
| Legacy and differential | 208 | 195 grouped entries; includes three pinned fork tests |
| Size, signature-memory and pool-priority checks | 5 | Runtime/immutable tails, initcode, long ERC-1271 signature; 4,096 differential fuzz cases |

Campaigns overlap and must not be added together. Validation uses Forge 1.8.6, hnc 1.6.2 and solc 0.8.26. [Follow-up results and source hashes](results/remaining-tests-validation.json) record the campaigns. Earlier records preserve previous port stages. CI checks generated copies, runs acceptance/legacy tests, repeats the extended campaign and enforces size/memory checks.

```sh
python3 script/sync-current-tests.py /path/to/pinned/contracts --check
FOUNDRY_PROFILE=current UNICHAIN_FORK_RPC_URL=https://mainnet.unichain.org \
  UNICHAIN_FORK_BLOCK=61709000 forge test
FOUNDRY_PROFILE=current FOUNDRY_TEST=compat/current/checks forge test --fuzz-runs 4096
```

To regenerate the inventory, save `forge test --no-match-test '^$' --list --json` from each repository and the current profile's `forge test --json` result. Pass them to `script/report-current-coverage.py --source-list … --huff-list … --results …`. It requires a passing execution result for every adapted test, including each grouped invariant predicate.

See the [Router receipt benchmark](../../benchmarks/crossing/README.md) and [optimizer sweep](../../benchmarks/optimizer-runs/README.md). This port has not been independently audited or deployed publicly.
