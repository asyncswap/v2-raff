# v1.3.1 acceptance tests for the Huff port

The target is Solidity commit **34b05bdcfb642727d1d6856f1ba91957dcf5d3b7**, including incoming-memory matching, fee top-ups and LP routing. Huff passes **1,017 upstream behavioral tests and invariant predicates**, up from 804. Assertions, expected values and fuzz assumptions remain unchanged.

| Coverage | Count |
| --- | ---: |
| Source-discovered tests and templates | 1,089 |
| Passing Huff behavioral tests and invariant predicates | **1,017** |
| Forge result entries (invariants grouped) | 1,007 |
| Behavioral tests still unported | **0** |
| Solidity architecture/diagnostic checks retained as reference-only | 59 |
| Abstract test templates with no deployable bytecode | 12 |
| Upstream finding excluded from normal runs | 1 |
| Verbatim source/test files retained | 221 |
| Generated Huff test/support adapters | 193 |
| Entirely reference-only test/support files | 4 |

The [per-test inventory](results/coverage.json) records every identity and classification. The 59 reference-only checks cover physical storage/write footprints, cached Solidity immutables, linked-library deployment and one diagnostic logger. Their original assertions remain in the pinned source; mixed-file reference functions keep their bodies and are named `referenceOnly_…` in adapters. These checks are not counted as Huff passes. Passing the behavioral suite is regression evidence, not a proof of complete equivalence.

**Counting correction:** the earlier “283 remaining” comprised 212 newly ported behavioral tests, 59 reference-only checks and 12 abstract templates. `forge --list` lists inherited abstract test templates even though they cannot execute. The report now verifies empty creation bytecode in the pinned Solidity artifacts. Ten additional invariant predicates are grouped into four Forge result entries; each predicate's result is checked separately.

## Completing behavioral coverage

The additional 212 tests cover constructor guards, domains and ShortStrings, exact-ratio arithmetic, order-admission and priority guards, external calls and token return decoding, wrapped reverts, claim batching, fee settlement, signature vectors, the surcharge fixture, callback defaults and handler sequences.

Production call, domain, signature, transfer and fee routines are shared with thin Huff ABI fixtures. Generic dependency APIs (including arbitrary-length domain strings) are ported as Huff helper fixtures; they do not imply the production hook uses dynamic strings. Solidity bridges only marshal ABI values, install Huff bytecode or seed its actual storage. No passing behavioral test is routed to a Solidity protocol implementation.

The Router keeps its direct token-transfer path. The general call helper is available to the Address API fixture without adding overhead to that path. The final 1,000-transaction benchmark reproduces the previous total receipt gas and first-block packing **exactly in all ten workloads**.

## Follow-up after merged PR #6

The 42 additional unchanged upstream tests cover signature hashing/ERC-1271 (22), direct crossing (6), priority keys (3), bitmap mutations (3), and pool-versus-book price selection (8). Thin ABI fixtures call the same Huff routines used by the production hook.

Direct crossing now preserves `mulDiv`'s division-by-zero and overflow reverts for arbitrary stored records. Bitmap insert/remove reject out-of-domain keys, duplicate inserts return false, and missing removals revert. Book indexing and incoming-order storage access were separated from funding so direct tests can exercise production routines without replacement implementations.

An additional differential check found a pre-existing reversed sell-side saturation comparison: the fee window could zero a still-positive pool key and choose the book incorrectly. The fix passes 4,096 cases against the pinned Solidity library, plus a regression for both quote orientations. These two new checks are separate from the upstream tests.

## Findings covered by merged PR #6

The earlier expansion of 379 tests exposed and now cover these fixes:

- Match reductions and claim credits follow Solidity order: bids, both net proceeds, both trade fees, then refunds; per-order fee events follow settlement.
- Tick keys decide unequal price levels; equal keys use full-width ratio arithmetic. Zero maker minimums preserve the expected division failure.
- Freed radix nodes retain their word until reuse, matching the free-list behavior; corrupt bitmap paths reject empty occupied children.
- Uninitialized pool admission and empty pending orders reject invalid calls. LP partial-fill errors precede invalid-output errors.
- FeeVault and NativeClaims decode dynamic callback arguments and malformed address words with Solidity-compatible authorization/revert ordering.

The hook is **24,321 bytes**, including immutables, leaving **255 bytes** below EIP-170. The Router is **10,952 bytes**. Both initcode checks pass. The [receipt benchmark](../../benchmarks/crossing/README.md) retains the gas savings; gas is unchanged from the previous 804-test port.

## Fixtures and unchanged assertions

`reference/contracts/` is copied verbatim using `git show` at the pinned commit. `manifest.json` records source, adapter and assertion hashes. The generator rejects changes to `assert*`, `expectRevert`, `expectEmit`, `expectCall` and `assume` expressions.

Protocol deployments compile `.huff` sources through `CurrentHuffDeploy`. Explicit fixture adapters translate order/bitmap/radix storage locations, read actual immutable bytes, and inspect actual transient reentrancy storage. They do not substitute expected results for observations. Math, radix and price-key harnesses execute the production Huff routines. Constructor fixtures bypass only hook-address mining, as their upstream subclasses did. The nonce replay fixture and its trusted-Router regression are copied from the v1.3.1 source at `34b05bd`.

Solidity imports remain for ABI types, mocks and independent reference calculations. Such helpers are not counted as Huff implementations. The adapted `fizz` handler fixtures use Foundry cheatcodes to deploy Huff; they are not a Medusa/Echidna deployment port. Generated files must be changed through `script/current_adapters.py` or the sync script, never by weakening a failing test.

## Stateful differential follow-up

The [differential profile](differential/README.md) compares state, ordered logs and return/revert bytes after each action in four fixtures. It caught and fixed an LP full-fill settlement-order difference without changing assertions. The v1.3.1 Solidity source `34b05bd` has the same production source tree as the pinned oracle. Final campaign results are recorded [separately](results/differential-validation.json).

## Validation

| Campaign | Passing tests/predicates | Configuration |
| --- | ---: | --- |
| Current acceptance | 1,017 | 256 cases per fuzz test; invariants 64 × 64; three Unichain fork tests at block 61709000 |
| Extended matching/reference/formal | 206 | 2,048 cases per fuzz test; saved counterexample seed |
| Extended external-call helpers | 42 | 2,048 cases per fuzz test; final direct transfer path |
| Legacy and differential | 208 | 195 grouped entries; includes three pinned fork tests |
| Size, signature-memory and pool-priority checks | 5 | Runtime/immutable tails, initcode, long ERC-1271 signature; 4,096 differential fuzz cases |

Campaigns overlap and must not be added together. Validation uses Forge 1.8.6, hnc 1.6.2 and solc 0.8.26. [Behavioral validation and source hashes](results/behavioral-validation.json) record the campaigns. Earlier records preserve previous port stages. CI checks generated copies, runs acceptance/legacy tests, repeats the extended campaign and enforces size/memory checks.

Run from the Huff repository root with Forge **1.8.6** and hnc **1.6.2** on your PATH. solc **0.8.26** is configured in `foundry.toml`. Use readable output for the full acceptance suite:

```sh
FOUNDRY_PROFILE=current \
FOUNDRY_INVARIANT_RUNS=64 \
FOUNDRY_INVARIANT_DEPTH=64 \
UNICHAIN_FORK_RPC_URL=https://mainnet.unichain.org \
UNICHAIN_FORK_BLOCK=61709000 \
forge test -j 4 -vvv
```

The v1.3.1 result combines the full 1,016-test/predicate run with the updated nine-test nonce-replay suite at 2,048 fuzz cases, including the added trusted-Router regression. The command above includes all 1,017. Assertions are unchanged; the profile excludes the documented `_finding_` test, and reference-only checks are not counted as Huff passes.

Check the generated adapters and run the additional size/memory/parity checks separately:

```sh
python3 script/sync-current-tests.py /path/to/pinned/contracts --check
FOUNDRY_PROFILE=current FOUNDRY_TEST=compat/current/checks forge test --fuzz-runs 4096 -vvv
```

### Profiles and saved invariant failures

| Profile | Suite | `fail_on_revert` |
| --- | --- | --- |
| `current` | `compat/current/test/` | `true` |
| `default` | `test/` (legacy) | `false` |

The profiles use separate compilation caches but currently share `cache/invariant` for saved invariant failures. A warning that adds `test/…:MatchingHandler`, removes `compat/current/test/…:MatchingHandler`, and changes `fail_on_revert` from `true` to `false` means the legacy run encountered a saved current-profile case.

Foundry skips that incompatible replay because the target contracts, selectors or settings differ. The warning is not a new invariant failure and does not establish that the saved failure was fixed. Keep the saved cases and use their original profile to investigate them.

### Machine-readable coverage inventory

To regenerate the inventory, build the pinned Solidity source and save `forge test --no-match-test '^$' --list --json` from each repository and the current profile's `forge test --json` result. Pass them to `script/report-current-coverage.py --source-list … --huff-list … --results … --source-artifacts /path/to/pinned/contracts/out`. It requires a passing execution result for every adapted test, including each grouped invariant predicate.

See the [Router receipt benchmark](../../benchmarks/crossing/README.md) and [optimizer sweep](../../benchmarks/optimizer-runs/README.md). This port has not been independently audited or deployed publicly.
