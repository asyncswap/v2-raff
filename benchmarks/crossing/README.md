# Current Huff versus Solidity Router benchmark

The current Huff port passes its copied PR #81 acceptance profile before this comparison. It reduces single-fill gas by **7.5–24.3%** and eight-level sweep gas by **7.9–8.9%**, but costs **21.3–22.4% more** on the other eight-fill workloads. Huff is not uniformly cheaper.

## Method

Each implementation ran 1,000 incoming Router transactions across ten workloads, settling 5,200 pairs. Both use the same fixture, workload generation and accounting assertions; only imports and deployment adapters differ. Setup is excluded. Receipt gas includes intrinsic gas and refunds. All transactions succeeded, with assertions for price/FIFO selection, exact match amounts, claims, fees and bids, empty books and zero hook escrow.

Both runs use Foundry/Anvil 1.9.0, Cancun, 30,000,000 block gas and controlled 18/6-decimal ERC-20 tokens. Solidity is pinned to PR #81 commit `3f4a5f106f55cc4b90b11d0ce0f0143f5e64ed89`, solc 0.8.26 with 10,000 optimizer runs; Huff uses hnc 1.6.2 (its Solidity fixtures use the same solc settings). Acceptance validation separately uses Foundry 1.8.6.

Each workload queues 100 transactions. A fixed gas limit is 120% of the first estimate, rounded up to 1,000. Block admission requires room for that gas limit, so packing is policy-specific. These are local Anvil measurements, not public-chain TPS or a universal maximum. LP routing and native-token flows are outside this benchmark.

`same` means all makers share a price. `distinct` gives each incoming group a different price, with the eight makers within each group sharing it. `levels` assigns each maker a distinct price, so each incoming transaction crosses eight levels. Buy/sell names describe the incoming order.

## Results

Positive gas change means Huff costs more. Block columns count incoming transactions in the first 30M-gas block.

| Workload | Solidity mean gas | Huff mean gas | Huff change | Solidity/block | Huff/block |
| --- | ---: | ---: | ---: | ---: | ---: |
| `buy_eight_distinct` | 1,081,974.16 | 1,319,993.63 | +22.0% | 27 | 22 |
| `buy_eight_levels` | 1,304,861.28 | 1,189,125.16 | -8.9% | 22 | 24 |
| `buy_eight_same` | 1,157,832.02 | 1,409,877.34 | +21.8% | 24 | 20 |
| `buy_one_distinct` | 385,321.06 | 291,807.46 | -24.3% | 77 | 100 |
| `buy_one_same` | 399,597.78 | 355,149.39 | -11.1% | 73 | 83 |
| `sell_eight_distinct` | 1,108,755.62 | 1,344,757.20 | +21.3% | 26 | 21 |
| `sell_eight_levels` | 1,317,668.10 | 1,213,563.56 | -7.9% | 22 | 24 |
| `sell_eight_same` | 1,171,613.91 | 1,434,425.07 | +22.4% | 24 | 20 |
| `sell_one_distinct` | 397,455.17 | 316,789.51 | -20.3% | 74 | 93 |
| `sell_one_same` | 411,633.16 | 380,592.12 | -7.5% | 71 | 77 |

## What to investigate next

Solidity batches claim transfers across its bounded matching loop; this Huff port transfers claims per matched pair. That is a plausible contributor to repeated-fill regressions, not an attribution established by these receipts. Profile transfer calls and exact-price tree maintenance before porting an optimization back to Solidity. The single-fill improvement alone does not justify replacing the Solidity implementation.

## Reproduce and inspect

```sh
# This repository, with hnc 1.6.2 and Foundry/Anvil 1.9.0 on PATH.
python3 benchmarks/crossing/run.py

# asyncswap/contracts checked out at the pinned PR #81 commit.
python3 benchmarks/crossing/run.py --output-dir .local/huff-comparison-solidity
```

[Huff summary and receipts](results/summary.json), [Solidity summary and receipts](solidity-results/summary.json), and [comparison/provenance](comparison.json) retain every workload. Both summaries include source hashes and fixture hashes. The Huff run used uncommitted port sources above the recorded base commit; `sourceDirty: true` and its hashes identify those sources. Subsequent comment corrections produce identical creation bytecode, verified in the comparison file. Runtime sizes including immutables are 24,204 bytes for the hook and 10,623 for the Router.
