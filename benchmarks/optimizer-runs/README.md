# Solidity optimizer run-count sweep

Keep **10,000 runs** for the pinned Solidity implementation. It has the lowest receipt gas among the six tested settings that keep every protocol module below EIP-170. A larger run count is a compiler cost-model input, not a guarantee of better code.

| Optimizer runs | Mean receipt gas | Change vs 10,000 | Hook bytes | Router bytes | Matching library bytes | All modules fit EIP-170 |
| ---: | ---: | ---: | ---: | ---: | ---: | :---: |
| 1 | 889,774.46 | +1.843% | 20,182 | 20,700 | 20,018 | Yes |
| 200 | 879,611.67 | +0.680% | 20,348 | 20,784 | 19,911 | Yes |
| 1,000 | 876,790.96 | +0.357% | 21,464 | 21,989 | 21,073 | Yes |
| 1,337 | 876,512.23 | +0.325% | 21,464 | 21,989 | 21,188 | Yes |
| 10,000 | 873,671.23 | baseline | 23,044 | 23,061 | 23,033 | Yes |
| 100,000 | 865,254.65 | -0.963% | 24,539 | 25,661 | 25,382 | **No** |

Each setting runs the same ten crossing workloads: 1,000 Router transactions, 5,200 matched pairs, local Cancun Anvil, 30M block gas. All receipt/accounting assertions and 11 matching-reference tests pass at every setting, with 256 cases per fuzz test. Fixtures can install oversized code, so passing receipt tests does not establish deployability; the runtime-size check independently rejects 100,000 runs. Means weight each workload equally because each contains 100 transactions.

The source is Solidity PR #81 commit `3f4a5f106f55cc4b90b11d0ce0f0143f5e64ed89`, solc 0.8.26. Benchmark Foundry/Anvil is 1.9.0; reference validation is Foundry 1.8.6. Compilation metadata verifies the actual optimizer setting before results are labeled. The 10,000-run receipts reproduce the saved Solidity baseline exactly. These results include changes to Solidity dependencies, such as PoolManager, compiled under the same setting.

The sweep does not establish a global optimum or test every integer run count. It also does not change Huff: `hnc` compiles the hand-written opcode paths independently of solc optimizer settings. Applying a Huff technique to Solidity requires a separate measured implementation.

[Summary and module sizes](results/summary.json) · [10,000-run receipts](results/10000/summary.json) · [100,000-run receipts](results/100000/summary.json). Each setting's directory contains compressed full receipts and reference-test results.

```sh
python3 benchmarks/optimizer-runs/run.py /path/to/pinned/contracts \
  --forge /path/to/forge-v1.8.6
```

No Solidity optimizer setting or deployed contract was changed by this sweep.
