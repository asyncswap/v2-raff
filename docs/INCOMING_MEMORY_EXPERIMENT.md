# Current matching arithmetic experiment

This branch adds an isolated Huff arithmetic kernel aligned with `asyncswap/contracts` commit `94400ce97b3260140d5449cbd26a3e7cdd832821`. The existing full Huff hook remains the older implementation at `v2-raff` commit `be294742cf76ab60f2c5c82ec46b7a96508c987b`. It is **not equivalent to the current Solidity protocol**, and passing the legacy suite does not establish current matching-reference compatibility.

## Compatibility gaps in the full hook

| Mechanism | Existing full Huff port | Current Solidity protocol |
| --- | --- | --- |
| Incoming matching | Incoming order versus best opposite | Global best pair, including crossed backlog |
| Price index | WAD price keys and outer radix tree | Tick bitmap with exact rational bounds within levels |
| Priority | Selectable FIFO/paid-priority mode | Exact price, funded bid, then queue sequence |
| Maker age | Same sequence as queue age | Immutable created sequence separate from queue age |
| Partial minimum | Subtract realized output from minimum | Preserve original limit: ceil(minimum × remaining input / old input) |
| Fee top-ups | No endpoint | Authenticated funded top-ups with queue updates |
| LP routing | Book first, then full-order LP fallback | Better venue first; bounded LP partial fills and dynamic fee ordering |
| Order constraints | Earlier amount/fee rules | Pool minimum, asset precision and chain-specific numeraire rules |
| Order storage | Seven slots, including linked FIFO IDs | Current packed record and different index structures |
| ABI and events | Older getters, constructors and fee events | Updated getter meanings, trusted Router constructor parameters and events |

The old `orderBookOrder` ABI has the same function selector but different return meanings: its trailing values are linked-list IDs, while the current getter exposes sequence and funded fee. Adapting only imports or casting interfaces is insufficient. The current reference suite also exercises top-ups, dust, original maker age and queue semantics that this old hook does not implement.

## Scope of the new kernel

- `src/experimental/IncomingMath.huff` exposes current maker-price match sizing and proportional remainder/bid arithmetic.
- `test/huff/IncomingMath.t.sol` supplies a Solidity arithmetic specification and differential tests. It also uses a bounded integer oracle independent of the full-precision helper.
- This kernel has no order storage, queue selection, dust closure, token settlement, events or authorization. The returned remainder arithmetic is an input to those mechanisms; it does not implement the whole reducer or incoming-order memory path.
- Amounts and minima must be nonzero; reductions require used input within escrow and a fee fitting uint64. The raw mulDiv test entry point intentionally accepts invalid divisors so division-by-zero and overflow behavior can be compared.

Two techniques are made explicit in source comments:

1. Check whether the taker can afford the entire maker order **before** multiplying. The old Huff helper multiplies then caps, which can revert on an overflowing intermediate quotient even though the capped result fits. Current Solidity already has this safe shortcut.
2. Compute the remaining minimum from the original input ratio with ceiling division. Price improvement on the completed portion must not weaken the remaining order's limit.

## Validation

Tools: huff-neo `hnc 1.6.2` (`8278e5c9`), Foundry 1.9.0, solc 0.8.26. The Solidity kernel comparator uses 10,000 optimizer runs, matching the current contracts setting.

Legacy baseline before changes: **166 passed, 0 failed, 1 skipped**, with 64 invariant runs × depth 64. The skipped suite needs the Unichain fork RPC. This is a fresh measured result; the older README's 182-test count is historical.

Combined legacy and new suite after changes: **176 passed, 0 failed, 1 skipped**, with the same invariant campaign and 10,000 Solidity optimizer runs.

Kernel suite: **10 passed, 0 failed**. Four fuzz tests run 2,048 cases each (8,192 total): full uint256 matching, bounded independent matching, full uint256 remainder arithmetic and raw mulDiv. A deterministic grid adds 1,024 matching comparisons plus 192 reductions. Explicit checks cover full affordability despite an overflowing uncapped quotient, invalid domains, division by zero, 512-bit products, floor overflow and ceiling overflow. Success/failure and exact return or revert bytes are compared.

```sh
FOUNDRY_OPTIMIZER_RUNS=10000 FOUNDRY_FUZZ_RUNS=2048 \
  forge test --match-contract IncomingMathTest -vv

FOUNDRY_INVARIANT_RUNS=64 FOUNDRY_INVARIANT_DEPTH=64 \
FOUNDRY_FUZZ_RUNS=2048 FOUNDRY_OPTIMIZER_RUNS=10000 forge test -vv
```

## Kernel gas, not transaction gas

The test records callee execution gas using Foundry's `lastCallGas`; compilation and deployment occur in setup and are excluded. Both callees expose the same three functions and enforce the same valid input domains. The Solidity side is the standalone specification, not the production inlined library.

| Operation | Huff | Solidity specification | Difference |
| --- | ---: | ---: | ---: |
| Small match | 1,545 | 2,048 | 503 |
| Wide-product match | 2,430 | 2,960 | 530 |
| Small reduction | 1,000 | 1,370 | 370 |
| Wide-product reduction | 1,590 | 2,054 | 464 |

Runtime size is 1,183 bytes for Huff and 1,560 bytes for the Solidity specification. The source maps both maker directions onto one calculation, reducing duplicated arithmetic logic. These measurements establish only a small isolated kernel improvement; subtracting them directly from full swap receipts would be invalid because production dispatch, inlining, storage and allocation differ.

The main opportunity remains avoiding temporary persistent order admission and repeated priority-index writes. Updating the full Huff protocol to current semantics, integrating the kernel, and passing the complete current matching reference model remain separate work. No deployed contract or old full-hook implementation is changed by this experiment.

## Direct current-Solidity parity

The isolated `contracts` incoming-memory worktree also runs `HuffProductionParityTest` against the actual `AsyncMatching._matchAmounts` helper, rather than this repository's standalone specification. It passes 2,048 full-width fuzz cases and 1,250 boundary comparisons with exact return/revert-byte parity. Its fixture and reproducible kernel build live under `benchmarks/incoming-memory/` in that worktree. This remains arithmetic-only validation; the old full Huff hook has not passed the current matching reference model.
