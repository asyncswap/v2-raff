# Huff and Solidity Router receipt comparison

The expanded Huff port uses **7.3–24.5% less gas on single fills** and **17.2–18.3% less on eight-level sweeps** than pinned Solidity PR #81. Other eight-fill workloads remain **11.1–13.0% more expensive**. These results include the correctness fixes exposed by the expanded acceptance suite.

Compared with the previous batched Huff port, eight-level sweeps improve 1.93%. Single fills regress 1.50–1.82%; the repeated-price buy case increases 0.03%. Both savings and regressions are retained below.

| Workload | Solidity mean gas | Previous Huff | Current Huff | Change vs previous | Change vs Solidity | First-block transactions |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `buy_eight_distinct` | 1,081,974.16 | 1,217,904.01 | 1,206,920.01 | -0.90% | +11.55% | 24 |
| `buy_eight_levels` | 1,304,861.28 | 1,087,035.59 | 1,066,022.75 | -1.93% | -18.30% | 27 |
| `buy_eight_same` | 1,157,832.02 | 1,307,787.76 | 1,308,184.91 | +0.03% | +12.99% | 22 |
| `buy_one_distinct` | 385,321.06 | 286,378.90 | 290,870.10 | +1.57% | -24.51% | 100 |
| `buy_one_same` | 399,597.78 | 349,720.82 | 356,074.73 | +1.82% | -10.89% | 83 |
| `sell_eight_distinct` | 1,108,755.62 | 1,243,664.34 | 1,232,182.05 | -0.92% | +11.13% | 23 |
| `sell_eight_levels` | 1,317,668.10 | 1,112,470.69 | 1,090,959.56 | -1.93% | -17.21% | 26 |
| `sell_eight_same` | 1,171,613.91 | 1,333,332.22 | 1,320,065.69 | -0.99% | +12.67% | 21 |
| `sell_one_distinct` | 397,455.17 | 311,383.34 | 316,056.96 | +1.50% | -20.48% | 94 |
| `sell_one_same` | 411,633.16 | 375,185.96 | 381,720.78 | +1.74% | -7.27% | 77 |

Each row contains 100 incoming Router transactions. Positive changes mean more gas. `same` shares a maker price; `distinct` assigns each incoming group its own price; `levels` gives every maker a different price. Buy/sell denotes the incoming side.

## Correctness and implementation

The port batches ERC-6909 claim credits by currency and recipient. Reductions now precede proceeds; refunds follow fees, preserving Solidity first-credit order. Zero credits are skipped, self-transfers remain immediate, additions are checked, and failed flushes revert atomically. Tick-key crossing decisions, malformed ABI handling, bitmap validation and radix recycling follow the expanded tests. Shared guards, order-ID hashing and bitmap scans reduce duplicated runtime code.

**762 acceptance tests/predicates**, **85 extended tests** at 2,048 fuzz cases, **208 legacy/parity tests/predicates**, and **three size/memory checks** pass. Campaigns overlap. Assertions remain unchanged. There are **325 runnable upstream tests still unported**; see the [coverage guide](../../compat/current/README.md).

The deployed hook is **24,073 bytes**, including immutables: 503 bytes below EIP-170. The Router is **10,623 bytes**. Validation uses Foundry 1.8.6; receipt benchmarks use Foundry/Anvil 1.9.0.

## Method and evidence

The unchanged workload measures 1,000 transactions and 5,200 matched pairs per implementation on disposable local Cancun Anvil, with a 30M block gas limit. All receipt, price/FIFO, exact-match, claims, fees/bids, empty-book and escrow assertions pass. Tokens use controlled 18/6-decimal fixtures; there is no LP liquidity. Setup and approvals are excluded; receipt gas includes intrinsic gas and refunds.

Solidity is pinned to `3f4a5f106f55cc4b90b11d0ce0f0143f5e64ed89`, solc 0.8.26 with 10,000 optimizer runs. Huff uses hnc 1.6.2. The [six-setting optimizer sweep](../optimizer-runs/README.md) reproduced the saved Solidity baseline exactly at 10,000 runs. Increasing to 100,000 saves another 0.96% but makes the Router and matching library too large to deploy; no settings were changed.

The transaction gas limit is 120% of the first estimate, rounded up to 1,000; block admission requires room for that declared limit. First-block packing is specific to this workload and policy, not public-chain TPS or a universal capacity limit.

[Current receipts](expanded-results/summary.json) · [Previous batched receipts](batched-results/summary.json) · [Solidity receipts](solidity-results/summary.json) · [Comparison data](expanded-comparison.json) · [Validation/source hashes](../../compat/current/results/expanded-validation.json). Historical unbatched receipts and the original batching comparison remain in `results/` and `batching-comparison.json`.

```sh
python3 benchmarks/crossing/run.py --output-dir benchmarks/crossing/expanded-results
```

The residual repeated-fill gap still needs profiling. These results alone do not attribute it to a particular storage operation or prove a Solidity optimization ceiling.
