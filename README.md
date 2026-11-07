# Async Swap in Huff

The current port in `src/current/` targets [Solidity v1.3.1 source](https://github.com/asyncswap/contracts/commit/34b05bdcfb642727d1d6856f1ba91957dcf5d3b7), including incoming-memory matching, fee top-ups and LP routing. Its [copied acceptance suite](compat/current/README.md) passes **1,017 upstream behavioral tests and invariant predicates**, with unchanged assertions. The [per-test inventory](compat/current/results/coverage.json) separately records **59 Solidity architecture/diagnostic references**, **12 abstract templates** and **one excluded finding**. All behavioral tests in the pinned scope are ported.

The [Router benchmark](benchmarks/crossing/README.md) measures 1,000 transactions and 5,200 pairs. Huff uses **7.3–24.5% less gas** on single fills and **17.2–18.3% less** on eight-level sweeps, but **11.1–12.9% more** on other eight-fill workloads. Hook/Router runtimes are **24,321 / 10,952 bytes**. The [optimizer sweep](benchmarks/optimizer-runs/README.md) supports retaining 10,000 runs for Solidity among the six tested settings.

The [stateful differential suite](compat/current/differential/README.md) compares Solidity and Huff after every action across four market fixtures. The v1.3.1 follow-up aligns LP full-fill payout and priority-fee settlement order with Solidity.

Run from the repository root with Forge **1.8.6** and hnc **1.6.2** on your PATH (solc **0.8.26** is configured in `foundry.toml`). This runs the current acceptance suite with readable output and the pinned fork tests:

```sh
FOUNDRY_PROFILE=current \
FOUNDRY_INVARIANT_RUNS=64 \
FOUNDRY_INVARIANT_DEPTH=64 \
UNICHAIN_FORK_RPC_URL=https://mainnet.unichain.org \
UNICHAIN_FORK_BLOCK=61709000 \
forge test -j 4 -vvv
```

```sh
FOUNDRY_PROFILE=current FOUNDRY_TEST=compat/current/checks forge test --fuzz-runs 4096 -vvv
python3 benchmarks/crossing/run.py
```

The `current` profile keeps `fail_on_revert = true`. The default profile runs the legacy suite. Both currently share saved invariant failures under `cache/invariant`; switching profiles can produce “failure was ignored because invariant test settings have changed” warnings. See the [profile and cache explanation](compat/current/README.md#profiles-and-saved-invariant-failures).

The current hook takes `(poolManager, numeraire, owner, router, minOrderUsd, assetPrecision)`; its Router takes `(poolManager, hook, permit2, mevTaxGas)`. See the acceptance guide for toolchain, fork configuration and exact coverage. The port has not been independently audited or deployed publicly.

## Legacy implementation

The remaining sections describe the historical root `src/` implementation. Its constructors, behavior and gas numbers are separate from the current port above. The [arithmetic experiment](docs/INCOMING_MEMORY_EXPERIMENT.md) is retained as historical context.

Async Swap v2 in [Huff](https://www.huff-neo.rs), compiled with [huff-neo](https://github.com/cakevm/huff-neo)
(`hnc`): a port of [`asyncswap/contracts`](https://github.com/asyncswap/contracts) (`main` @ `6fa977a`) with the
same ABI, events, errors, revert strings and behaviour. The acceptance test is `asyncswap/contracts`' own suite,
copied here with three kinds of edits: its imports take the ABI from `src/interface/`, its deploy lines deploy the
Huff, and the two Solidity subclasses it defined (a fee variant, and a constructor harness that skips the
hook-address check) are Huff builds with a compile-time flag instead:

| | passed | failed | skipped |
| --- | ---: | ---: | ---: |
| `asyncswap/contracts`, Solidity | 181 | 0 | 0 |
| this repo, Huff | 181 + 1 | 0 | 0 |

With `UNICHAIN_FORK_RPC_URL=https://mainnet.unichain.org` and `UNICHAIN_FORK_BLOCK=61709000`, as CI sets them;
the three Unichain fork tests run the Huff against live mainnet state (PoolManager, USDC, Permit2). Without the
RPC they skip. The `+ 1` is `test/huff/CodeSize.t.sol`, which keeps the Huff runtimes under EIP-170. Created from the
[`asyncswap/raff`](https://github.com/asyncswap/raff) template.

## Layout

| Path | What it is |
| --- | --- |
| `src/AsyncSwap.huff` | The hook, with `AsyncMatching` inlined (no linked library) |
| `src/Router.huff` | `swap`, `swapWithSig` (Permit2 witness), `fillOrder`, `cancelOrder`, `cancelWithSig`, `matchBook`, `fillFromPoolLiquidity`, the unlock callback |
| `src/FeeVault.huff` | Fee claims; the hook's constructor deploys it (`src/generated/` holds its creation code) |
| `src/NativeClaims.huff` | Redeems native-ETH claims |
| `src/MatchingEngine.huff` | The standalone matching benchmark |
| `src/lib/` | Order book (`AsyncFiller`), radix price tree, 512-bit `mulDiv` and match amounts, EIP-712 and `SignatureChecker`, PoolManager calls |
| `src/interface/` | The Solidity ABI: `IAsyncSwap`, `IRouter`, `IFeeVault`, `INativeClaims`, `IMatchingEngine`, `IAsyncFiller` (order-book types, events, errors), `ISignatureTransfer`, the `AsyncOrder` struct |
| `test/` | `asyncswap/contracts`' tests. They import the interfaces under the contracts' names and deploy through `test/utils/HuffDeploy.sol`; `test/utils/OrderSignatures.sol` and `CurrencySettler.sol` are the two Solidity helpers they call |
| `docs/`, `MAINNET_READINESS.md` | Copied from `asyncswap/contracts` |

`src/` is the Huff and, in `src/interface/`, its Solidity interfaces.

Constructor arguments are ABI-encoded after the creation code, as in Solidity. The hook takes `(poolManager,
numeraire, owner)` and must sit at an address whose low 14 bits are exactly `0x2888`; the Router takes
`(poolManager, hook, permit2)`, NativeClaims `(poolManager)`.

## Differences from the Solidity

Behaviour is the same; these are not observable through the ABI.

- `AsyncMatching` is inlined, so there is no library to deploy and link. The hook runtime is 17,579 bytes.
- Storage layout differs: each pool hangs off `keccak(poolId, 3)`, an order is seven slots. See
  `src/lib/Book.huff`.
- NativeClaims' and MatchingEngine's reentrancy flags are transient. They are set and cleared within one call,
  as the Solidity's storage flags are.
- Test-only builds: `-c POOL_FEE_MODE=1` (`calculatePoolFee = amount / 100`, for `test/security/FeeClaims.t.sol`)
  and `-c SKIP_HOOK_ADDRESS_CHECK=1` (for the constructor tests in `test/Numeraire.t.sol`).

## Historical gas (legacy implementation)

Same tests, Solidity (`optimizer_runs = 1000`) against Huff:

| Test | Solidity | Huff | |
| --- | ---: | ---: | ---: |
| `test_swap_createsOrderWithPrice` | 490,836 | 434,075 | −11.6% |
| `test_fill_makerReceivesPricedOutput_fillerReceivesInput` | 569,140 | 484,097 | −14.9% |
| `test_cancel_makerReclaimsInput` | 464,499 | 386,065 | −16.9% |
| `test_crossingOrdersMatchAndTransferEscrowedTokens` | 871,144 | 738,408 | −15.2% |
| `test_crossingOrdersPartiallyFillAndKeepResidualOnBook` | 1,014,108 | 849,216 | −16.3% |
| `test_matchBookContinuesAfterAutomaticMatchBound` | 4,658,125 | 3,943,843 | −15.3% |
| `test_priorityFeeBreaksEqualPriceTiesAfterPricePriority` | 1,970,410 | 1,656,665 | −15.9% |
| `test_lpLiquidityFillsOrderWhenMakerMinimumIsMet` | 1,973,636 | 1,904,251 | −3.5% |
| `testGas_OneCallMatchesEightDistinctLevels` (MatchingEngine) | 1,465,923 | 1,311,968 | −10.5% |
| `testGas_100OrdersAtDistinctPrices` (MatchingEngine) | 17,466,391 | 14,606,330 | −16.4% |

These are whole tests, so they include PoolManager and token work the port doesn't change. Tests that deploy
contracts in their bodies also count foundry-huff-neo's compile-and-deploy calls, so a suite-wide total
(−0.6%) understates the difference.

## Build and test

```sh
curl -L https://foundry.paradigm.xyz | bash && foundryup
curl -L https://raw.githubusercontent.com/cakevm/huff-neo/main/hnc-up/install | bash && hnc-up
git clone --recurse-submodules https://github.com/asyncswap/v2-raff && cd v2-raff
forge soldeer install
```

```sh
forge test                                   # needs hnc on PATH; ffi is on in foundry.toml
UNICHAIN_FORK_RPC_URL=https://mainnet.unichain.org UNICHAIN_FORK_BLOCK=61709000 \
  FOUNDRY_INVARIANT_RUNS=64 FOUNDRY_INVARIANT_DEPTH=64 forge test   # what CI runs
./script/huff-codegen.sh                     # after changing src/FeeVault.huff
hnc src/AsyncSwap.huff -b                   # creation code (append the constructor arguments)
```

CI (`.github/workflows/test.yml`) runs fmt, checks that `src/generated/` is current, and runs the suite at
the invariant depth `asyncswap/contracts`' CI uses, against the huff-neo release pinned in `HNC_VERSION`.
