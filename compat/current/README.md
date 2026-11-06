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

## Initial results and remaining work

The first current-profile smoke run compiled successfully. **13 MatchingEngine tests passed; 73 suite setups failed with `InvalidNumeraire()`.** The old Huff hook expected three constructor arguments; PR #81 requires six. That initial baseline is preserved in `results/initial-compatibility.json`.

The current-port hook and Router now accept the six- and four-argument constructors, and the hook reads the quote decimals and binds its trusted Router. The next smoke run reaches **59 passing results and 311 failures**, recorded in `results/current-compatibility.json`. Most failures are now the legacy book's rejection of funded bids in its default FIFO mode; other failures expose missing getters, queue semantics, fee behavior and endpoints. These are real acceptance failures, not tests disabled to make the port pass. Some setup failures still prevent their test bodies from running. The 383 discovered tests are not 383 executed/passing tests.

Both compatibility smoke runs use one fuzz case and reduced invariant depth to identify blockers; full campaigns remain required after the port works. The separate legacy/kernel/claims regression passes **184 tests** at 64 × 64 invariant depth; it does not validate the current hook/router. See `results/legacy-regression.json` and `results/test-list.json`.

The new `src/TokenClaims.huff` passes eight standalone differential tests against pinned `TokenClaims.sol`, including three fuzz tests with 2,048 cases each. Tests cover real PoolManager balances/allowances, ERC-20 and native payout, events, failed-transfer rollback, reentrancy, and malformed ABI input. Implementation addresses are normalized only for the emitting contract and PoolManager's transfer-operator field. Results are recorded in `results/token-claims-parity.json`.

The hook/router port still needs complete constructor/authorization validation, exact-price indexing, maker age and global matching, fee top-ups, memory admission, current LP/dynamic fee routing, and updated claim/MEV-tax/signature endpoints. `src/current/` is unfinished and must not be deployed. The copied acceptance suite is the gate for that work; legacy passes or the isolated arithmetic kernel cannot substitute for it.
