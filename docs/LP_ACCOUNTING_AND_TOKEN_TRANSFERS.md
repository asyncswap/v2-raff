# LP accounting and token delivery validation

This prototype adds balance checks to Solidity and Huff and tests shared-USDC accounting while LP liquidity changes. It is not deployed or released. It builds on the [earlier accounting campaign](ADVERSARIAL_VALIDATION.md).

## Token delivery policy

A successful ERC-20 return value does not prove payment. The new checks use balances before and after each transfer:

- Deposits must not reduce the sender's balance by more than the authorized amount. PoolManager verifies incoming custody credit; short deposits retain the existing `CurrencyNotSettled` revert.
- Physical payouts must increase the recipient's balance by at least the amount owed and must not reduce custody by more than that amount. Violations revert with `TokenNotSupported(address token)` and roll back the transaction.
- The amount owed is the protocol's settlement amount after its fees. Matching that credits ERC-6909 claims checks token delivery when those claims are redeemed.
- LP routing propagates `TokenNotSupported` instead of treating it as an ordinary liquidity miss and leaving the incoming order resting.
- Native transfers and the owner-only rescue of stranded hook funds retain their existing behavior. The rescue path is outside these settlement checks.

These are net balance bounds. A callback can add unrelated funds, so requiring exact equality would reject otherwise valid funding. Callback execution alone is not rejected; this is not ERC-777 registration detection or a claim of ERC-777 support. The checks assume honest `balanceOf` results. They cannot certify a token against future blacklisting, upgrades, rebases, or deceptive balance reporting, nor guarantee that an outstanding claim will remain withdrawable.

## Results

| Check | Solidity | Huff |
| --- | ---: | ---: |
| Complete offline default / current acceptance suites | 1,085 passed | 1,004 passed |
| Focused accounting, token and size suites; 512 fuzz cases | 22 passed | 22 passed |
| Deterministic LP state comparison | 65 checkpoints | All 65 match |
| Focused suites with Solar; 64 fuzz cases | 22 passed | 22 passed |
| Additional default Huff suite | — | 192 passed |
| Additional Huff size/signature/pool-price checks; 4,096 fuzz cases | — | 5 passed |

All listed final runs had zero failures. The Solidity total includes the focused tests; Huff's profiles also overlap, so these rows must not be summed as unique tests. Offline totals exclude the RPC-dependent Unichain fork suite and retain the configured exclusion of intentional formal `_finding_` tests. No public-network test or deployment was performed in this pass.

## Validation scope

The canonical 512-case campaign passes all 22 focused tests in each implementation. The changing-LP property exercises **32,768 randomized actions per implementation**, plus setup and cleanup. The campaigns are independent runs with the same seed; they are not 32,768 paired differential comparisons. A separate deterministic run compares all **65 checkpoints** (64 actions plus final withdrawals) and matches in full. All 11 action types execute.

Measured deployed runtimes, including immutable data:

| Module | Solidity bytes | Huff bytes |
| --- | ---: | ---: |
| Hook | 24,312 | 24,058 |
| Router | 24,139 | 11,160 |
| Fee vault | 3,525 | 1,359 |

All are below 24,576 bytes, with limited remaining headroom in the hooks and Solidity router. Solidity's linked matching modules also fit: `AsyncMatching` 23,950 bytes and `IncomingMatching` 22,350 bytes.

## Coverage

Three markets share custody: asset-18/USDC-6, USDC-6/asset-8, and native ETH/USDC-6. Each has broad, narrow, and initially out-of-range LP positions. The campaign adds/removes liquidity, collects LP fees, places/cancels/reprices orders, tops up bids, retries LP fills, fills manually, collects protocol fees and withdraws claims.

After each action, an independent ledger checks:

- Hook claims equal all outstanding order inputs and remaining USDC bids across pools.
- Physical custody equals claims plus LP reserves. The ledger includes liquidity deltas, successful swaps and dynamic-fee donations.
- All fixture wallet/custody balances conserve assets, including native ETH.
- Actual position and active liquidity agree with the model; LP edits leave other pools unchanged.
- Fee growth is monotone, temporary LP fees are restored, and PoolManager is locked with no unsettled deltas.

Every campaign starts with real LP fills in all three pools and ends by removing all positions, cancelling remaining orders and withdrawing claims. Rounding dust remains explicitly accounted for. A separate scenario removes all active liquidity, tests an out-of-range retry, restores liquidity and fills the resting order.

Seven token tests cover short cancellation payouts, excess custody debits, excess depositor charges, short manual-fill payouts, short claim withdrawals, unsupported LP output, and callbacks with full delivery. The five initial fuzz properties failed against the unguarded implementation; the new checks make them pass. A deployed-code test checks the hook, router and fee vault against the 24,576-byte runtime limit, including appended Huff immutables.

## Compatibility and fixture corrections

Existing assertions are unchanged. The formal pool-swap fixture previously mocked `take` as an empty successful call. It now supplies sequential `balanceOf` responses for a full payout. Its original swap/take expectations, order-closure assertion and fee-restoration assertion remain intact. The Huff adapter records this fixture change while retaining the pinned Solidity source snapshot.

The new LP observer initially omitted dynamic-fee donations and reported a custody mismatch. Including those actual flows corrected the model without changing its conservation assertions. No LP accounting defect was reproduced by this campaign.

Huff keeps snapshot values on the stack across external calls and Permit2 calldata construction. Shared arithmetic, order cleanup and LP-call routines reduce repeated bytecode enough to accommodate the checks. Comments identify these techniques. The checks add external balance reads; this report makes no claim of unchanged gas costs. An intermediate acceptance run overlapped fee-vault regeneration and caught an empty generated table. The generator now publishes by atomic replacement; final acceptance results come from a fresh run with fixed generated files.

## Reproduce

Use Forge 1.8.6, solc 0.8.26 and Huff Neo 1.6.2. Commands below use a `forge` executable pointing to that version. Full runs retain the repository's default exclusion of formal `_finding_` tests, which intentionally encode unresolved model findings. RPC-dependent Unichain fork tests are excluded from the offline runs.

Solidity:

```sh
forge test --offline --out out-lp-validation --cache-path cache-lp-validation \
  --match-contract '^(MultiPoolLiquidityAccountingTest|TokenBalanceDeltaTest|AdversarialAssumptionsTest|ProtocolDeploymentSizeTest)$' \
  --fuzz-runs 512 --fuzz-seed 0x1a11c0ffee -j 2 -vvv

forge test --offline --no-match-path '**/UnichainFork.t.sol' \
  --fuzz-seed 0x1a11c0ffee -j 2 -vvv

forge test --offline --out out-lp-validation --cache-path cache-lp-validation \
  --match-contract '^MultiPoolLiquidityAccountingTest$' \
  --match-test test_LP_deterministicChangingLiquidity -vvvv \
  > /tmp/lp-solidity-checkpoints.log
```

Huff:

```sh
FOUNDRY_PROFILE=adversarial forge test --offline \
  --fuzz-runs 512 --fuzz-seed 0x1a11c0ffee -j 2 -vvv

FOUNDRY_PROFILE=current forge test --offline \
  --no-match-path '**/UnichainFork.t.sol' \
  --fuzz-seed 0x1a11c0ffee -j 2 -vvv

FOUNDRY_PROFILE=adversarial forge test --offline \
  --match-contract '^MultiPoolLiquidityAccountingTest$' \
  --match-test test_LP_deterministicChangingLiquidity -vvvv \
  > /tmp/lp-huff-checkpoints.log

python3 script/check-adversarial-state.py --lp \
  /tmp/lp-solidity-checkpoints.log /tmp/lp-huff-checkpoints.log
python3 script/sync-adversarial-tests.py /path/to/solidity-checkout --check
python3 script/sync-current-tests.py /path/to/solidity-checkout --check
```

The supplemental copy checker preserves all test tokens and strings except three fixture path substitutions. The current-suite generator separately checks existing behavioral assertion equality. Human-readable Forge output is sufficient; no JSON result file is required.

Additional Huff regression checks:

```sh
FOUNDRY_INVARIANT_RUNS=64 FOUNDRY_INVARIANT_DEPTH=64 forge test --offline \
  --no-match-path '**/UnichainFork.t.sol' --fuzz-seed 0x1a11c0ffee -j 2 -vvv

FOUNDRY_PROFILE=current FOUNDRY_TEST=compat/current/checks forge test --offline \
  --fuzz-runs 4096 --fuzz-seed 0x1a11c0ffee -j 2 -vvv
```

Solar cross-check, using Forge 1.9.0 and Solar `0.3.0-dev+commit.a2b44354` (set `FOUNDRY_PROFILE=adversarial` in Huff):

```sh
forge test --offline --use solar \
  --out out-solar-adversarial --cache-path cache-solar-adversarial \
  --match-contract '^(MultiPoolLiquidityAccountingTest|TokenBalanceDeltaTest|AdversarialAssumptionsTest|ProtocolDeploymentSizeTest)$' \
  --fuzz-runs 64 --fuzz-seed 0x1a11c0ffee -j 2 -vvv
```

Baseline revisions: Solidity `34b05bdcfb642727d1d6856f1ba91957dcf5d3b7`, Huff `1ce69b17dd040f59a323929bf8ca863e2169a6a3`. The changes in this report are untagged follow-up work; they do not change the published v1.3.1 release. Supplemental tests are separate from the pinned acceptance manifest's ported-test count.

## Coverage interpretation

Forge source coverage measures the Solidity sources it compiles. It does not establish Huff source coverage for protocol bytecode loaded through FFI. Huff validation here uses behavioral tests, state comparisons and runtime-size checks. For Solidity coverage with Solar, the Solidity repository provides `script/coverage-solar.sh` to prebuild matching immutable metadata before running coverage; see its `docs/SOLAR_VALIDATION.md`.
