# PR #81 acceptance tests for the Huff port

The target is `asyncswap/contracts` commit **3f4a5f106f55cc4b90b11d0ce0f0143f5e64ed89** (PR #81), including incoming-memory matching, priority-fee top-ups and current LP routing.

## What was copied

`reference/contracts/` contains 221 verbatim, commit-pinned source and test files, including all 197 Solidity test/support files. `manifest.json` records their SHA-256 hashes. Files come from `git show` at the pinned commit, not an uncommitted working tree.

`compat/current/test/` contains 61 generated adapters: 55 test files and six shared fixtures/utilities, discovering **383 tests across 75 contracts**. The adapters preserve the original assertions and expected values. Changes are limited to imports, fixture artifact paths, formatting, and replacing protocol deployments with `CurrentHuffDeploy`. That helper compiles `.huff` sources; imported Solidity contracts supply ABI types and reference helpers, not replacement protocol deployments.

The 136 Solidity-specific files remain available verbatim in the reference snapshot. They are excluded from the Huff acceptance profile with per-file reasons in the manifest: internal-library harnesses, direct storage-layout manipulation, Solidity subclasses/constructor overrides, and specialized invariant harnesses need explicit Huff adapters. Their presence does not count as Huff coverage. The independent matching reference uses Solidity TickPrice only for the documented tick/queue-age rule, as in the upstream suite.

## Run

Requires the repository dependencies, huff-neo `hnc`, and Foundry (validation uses v1.8.6).

```sh
# List and run copied public-API tests against actual Huff deployments.
FOUNDRY_PROFILE=current forge test --list
FOUNDRY_PROFILE=current forge test --no-match-contract UnichainForkTest

# Matching reference, incoming funding/callback behavior, and fee top-ups.
FOUNDRY_PROFILE=current forge test --match-contract '.*(Reference|Funding|Transitions|TopUp).*' --fuzz-runs 2048

# Read-only pinned fork; no public transaction is broadcast.
FOUNDRY_PROFILE=current UNICHAIN_FORK_RPC_URL=https://mainnet.unichain.org \
  forge test --match-contract UnichainForkTest

# New standalone claims port, compared with the real pinned Solidity implementation.
FOUNDRY_OPTIMIZER_RUNS=10000 forge test --match-contract TokenClaimsParityTest --fuzz-runs 2048
```

The original `forge test` profile remains the legacy Huff suite. Passing it does not establish PR #81 compatibility. `profile.current` deploys the hook and Router from `src/current/`, has independent build/cache directories and uses the current 64 × 64 invariant configuration. The reference snapshot is outside both test roots, preventing accidental Solidity-only passes from inflating Huff results.

## Reproduce the copy and detect drift

```sh
python3 script/sync-current-tests.py /path/to/contracts
python3 script/sync-current-tests.py /path/to/contracts --check
```

Use `--forge /path/to/forge-v1.8.6` to select the pinned formatter. The check compares every original source and generated adapter byte and rejects unexpected files. Modify the adapter script rather than editing generated tests to accommodate a port failure.

## Validation results

The current handwritten Huff hook/Router pass **373 tests, zero failures**, including three Unichain fork tests at block 61709000. Fuzz tests use 256 cases and invariants run 64 × 64. The profile discovers 383 tests; ten upstream `_finding_` tests are excluded by the inherited profile rule. This is coverage of the adapted public API, not all Solidity internal harnesses or a proof of complete equivalence.

An extended matching/reference/funding campaign passes **23 tests**, with 2,048 cases per fuzz test. It overlaps the full suite. The separate legacy/kernel/claims/tick suite passes **192 tests**, excluding legacy fork tests, at 64 × 64 invariant depth. TickPrice parity also passed 2,048 cases per fuzz test. The latest campaigns and source hashes are in [batched-validation.json](results/batched-validation.json); other records in `results/` preserve the earlier port validation.

The hook implements exact-price selection, maker age, global matching, funded fee top-ups, transient staging and memory admission, LP/dynamic fee routing, claims, MEV tax, and signed endpoints. Technique comments explain bitmap lookup, full-width ratio comparison, subtree repair, integer square root, matching rounding and candidate storage redirection.

Deployed runtimes including immutable tails are **24,458 bytes** (hook) and **10,623 bytes** (Router). `checks/PortSize.t.sol` enforces EIP-170 and the 49,152-byte initcode limit; the hook has 118 bytes of headroom. Run the separate check with:

```sh
FOUNDRY_PROFILE=current FOUNDRY_TEST=compat/current/checks forge test
```

The three separate port checks pass. The long ERC-1271 signature regression covers overlap with the incoming-candidate scratch area; removing the flag reset makes it fail with `ZeroAmount()`. See `results/port-checks.json`.

The batch helper adds five differential tests against pinned Solidity `ClaimTransfers`, including 2,048 fuzz cases. Repeated credits, 34-key capacity, zero credits, first-credit ordering, self-transfers, accumulation overflow and flush rollback all pass. These tests are additional coverage; the copied adapters remain unchanged.

The [Router receipt benchmark](../../benchmarks/crossing/README.md) records both savings and regressions against the pinned Solidity implementation. This port has not been independently audited or deployed publicly.

## Historical baseline and scope

The initial smoke run passed 13 MatchingEngine tests and failed 73 suite setups with `InvalidNumeraire()`, before constructor adaptation. That baseline remains in `results/initial-compatibility.json`. A subsequent 59-pass/311-failure smoke run exposed missing current-protocol behavior; the final full campaign replaces that intermediate result in `results/current-compatibility.json`.

The standalone `src/TokenClaims.huff` also passed eight differential tests against pinned `TokenClaims.sol`, including three fuzz tests with 2,048 cases each. These cover PoolManager balances/allowances, ERC-20 and native payout, events, failed-transfer rollback, reentrancy and malformed ABI input. Only emitting-contract and PoolManager transfer-operator addresses are normalized. See `results/token-claims-parity.json`.

The 136 reference-only files still require explicit Huff-specific adapters before they count as coverage. No copied assertion or expected value was weakened to fix a port failure.
