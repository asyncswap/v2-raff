# Batched Huff claims versus Solidity

Batching reduces eight-fill receipt gas by **7.1–8.6%** relative to the previous Huff port. It reduces claim transfers from **48 to 11 per eight-fill transaction**, verified in all 600 eight-fill receipts. Single-fill gas also falls **1.4–1.9%**, with transfers reduced from six to four.

Against pinned Solidity PR #81, batched Huff is **15.6–16.7% cheaper** on eight-level sweeps and **8.9–25.7% cheaper** on single fills. Eight-fill workloads with makers sharing prices still cost **12.2–13.8% more** than Solidity. Batching improves those cases without eliminating the remaining gap.

## Receipt results

Each row has 100 incoming Router transactions. Positive change versus Solidity means Huff costs more. Block counts use the stated gas-limit policy below.

| Workload | Solidity mean gas | Huff before | Huff batched | Saving vs before | Change vs Solidity | First block, before → after |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `buy_eight_distinct` | 1,081,974.16 | 1,319,993.63 | 1,217,904.01 | 7.73% | +12.56% | 22 → 24 |
| `buy_eight_levels` | 1,304,861.28 | 1,189,125.16 | 1,087,035.59 | 8.59% | -16.69% | 24 → 26 |
| `buy_eight_same` | 1,157,832.02 | 1,409,877.34 | 1,307,787.76 | 7.24% | +12.95% | 20 → 22 |
| `buy_one_distinct` | 385,321.06 | 291,807.46 | 286,378.90 | 1.86% | -25.68% | 100 → 100 |
| `buy_one_same` | 399,597.78 | 355,149.39 | 349,720.82 | 1.53% | -12.48% | 83 → 84 |
| `sell_eight_distinct` | 1,108,755.62 | 1,344,757.20 | 1,243,664.34 | 7.52% | +12.17% | 21 → 23 |
| `sell_eight_levels` | 1,317,668.10 | 1,213,563.56 | 1,112,470.69 | 8.33% | -15.57% | 24 → 26 |
| `sell_eight_same` | 1,171,613.91 | 1,434,425.07 | 1,333,332.22 | 7.05% | +13.80% | 20 → 21 |
| `sell_one_distinct` | 397,455.17 | 316,789.51 | 311,383.34 | 1.71% | -21.66% | 93 → 95 |
| `sell_one_same` | 411,633.16 | 380,592.12 | 375,185.96 | 1.42% | -8.85% | 77 → 78 |

## Implementation and correctness

A memory batch combines credits by `(currency, recipient)` during each bounded matching loop, including net proceeds, trading fees, priority bids and dust refunds. It preserves first-credit transfer order and per-order protocol events. Zero credits are skipped; self-transfers execute immediately so repeated self-credits cannot overflow or require a larger balance. Accumulation is checked, and a failed flush reverts the entire transaction. The batch is inactive outside the matching loop and flushes before a subsequent LP attempt or returning from the call.

The batch occupies a separate memory region after the incoming candidate. Signature verification clears both active flags because a long ERC-1271 signature can overwrite that region. Eight pairs permit at most 34 distinct recipient/currency credits. A linear scan is bounded by that small set.

Validation passes **373 unchanged current acceptance tests**, **23 extended matching/reference tests** with 2,048 cases per fuzz test, **192 legacy/parity tests**, and **three size/signature-memory checks**. The five new batch parity tests compare with the actual pinned Solidity library, covering repeated keys, 34 distinct credits, zero amounts, first-credit ordering, self-transfers, checked overflow and failed-flush rollback; the fuzz test passed 2,048 cases. Campaigns overlap and should not be added together. Coverage exclusions remain documented in the [acceptance guide](../../compat/current/README.md).

The deployed hook is **24,458 bytes** (118 bytes below EIP-170), and the Router remains **10,623 bytes**, including immutables. Initcode also passes its size limit. Validation uses Foundry 1.8.6; benchmark receipt runs use Foundry/Anvil 1.9.0.

## Method and evidence

The unchanged benchmark runs 1,000 transactions and settles 5,200 pairs per implementation on disposable local Anvil. All receipt, price/FIFO, exact-match, claims, fees/bids, empty-book and escrow assertions pass. Mock tokens use 18/6 decimals; there is no LP liquidity. Setup and approvals are excluded; receipt gas includes intrinsic gas and refunds.

Both sides use Cancun and a 30,000,000 block gas limit. Solidity is pinned to `3f4a5f106f55cc4b90b11d0ce0f0143f5e64ed89`, solc 0.8.26 with 10,000 optimizer runs. Huff uses hnc 1.6.2. Both benchmark summaries record exact tool versions and source hashes. The new run reuses the saved Solidity baseline from the same workload/toolchain; it reruns all Huff transactions. The unbatched Huff baseline is commit `516d5443a28dfa0e9ef86899ca3607993c985cac`.

`same` shares one maker price; `distinct` assigns each incoming group a different price with its eight makers sharing that price; `levels` gives every maker a distinct price. Buy/sell denotes the incoming side. The fixed transaction gas limit is 120% of the first estimate, rounded up to 1,000; block admission needs room for that declared limit. Packing is workload/policy-specific, not public-chain TPS or a universal maximum.

[New receipts](batched-results/summary.json), [unbatched receipts](results/summary.json), [Solidity receipts](solidity-results/summary.json), [before/after comparison](batching-comparison.json), and [validation/source hashes](../../compat/current/results/batched-validation.json) preserve the evidence. The previous unbatched comparison remains in `comparison.json`.

```sh
python3 benchmarks/crossing/run.py --output-dir benchmarks/crossing/batched-results
FOUNDRY_PROFILE=current forge test
FOUNDRY_PROFILE=current FOUNDRY_TEST=compat/current/checks forge test
forge test --match-contract ClaimTransfersParityTest --fuzz-runs 2048
```

The residual repeated-fill gap remains to be profiled; these receipts alone do not attribute it to a particular tree operation or storage access.
