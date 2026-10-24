# v2-raff

Native Huff implementation of the Async Swap hook, Router, fee vault, and claim redeemers.
The current synchronization targets the local Solidity protocol, including priority-only bid escrow,
exact-price selection within coarse tick buckets, FeeVault bid routing, claim-based matching proceeds,
minimum-order checks, proportional residual limits, and shared signature nonces.

Validation compares native Huff and Solidity executions with independently calculated Python results.
See [gas optimization and validation](docs/huff-gas-2026-10-24.md) for current measurements and
[baseline synchronization](docs/huff-sync-2026-10-24.md) for the earlier port coverage.
Storage layouts differ; matching public behavior is the comparison target. The historical storage-specific
fixtures under `test/formal/` are retained separately and are not current refinement proofs.

## Layout

| Path | What it is |
| --- | --- |
| `src/AsyncSwap.huff` | The hook, with `AsyncMatching` inlined (no linked library) |
| `src/Router.huff` | `swap`, `swapWithSig` (Permit2 witness), `fillOrder`, `cancelOrder`, `cancelWithSig`, `matchBook`, `fillFromPoolLiquidity`, the unlock callback |
| `src/FeeVault.huff` | Fee claims; the hook's constructor deploys it (`src/generated/` holds its creation code) |
| `src/NativeClaims.huff` | Redeems native-ETH claims |
| `src/TokenClaims.huff` | Redeems ERC-6909 currency claims |
| `src/MatchingEngine.huff` | The standalone matching benchmark |
| `src/lib/` | Order book (`AsyncFiller`), radix price tree, 512-bit `mulDiv` and match amounts, EIP-712 and `SignatureChecker`, PoolManager calls |
| `src/interface/` | The Solidity ABI: `IAsyncSwap`, `IRouter`, `IFeeVault`, `INativeClaims`, `IMatchingEngine`, `IAsyncFiller` (order-book types, events, errors), `ISignatureTransfer`, the `AsyncOrder` struct |
| `test/` | `asyncswap/contracts`' tests. They import the interfaces under the contracts' names and deploy through `test/utils/HuffDeploy.sol`; `test/utils/OrderSignatures.sol` and `CurrencySettler.sol` are the two Solidity helpers they call |
| `docs/`, `MAINNET_READINESS.md` | Copied from `asyncswap/contracts` |

`src/` is the Huff and, in `src/interface/`, its Solidity interfaces.

Constructor arguments are ABI-encoded after the creation code, as in Solidity. The hook takes `(poolManager,
numeraire, owner)` and must sit at an address whose low 14 bits are exactly `0x2888`; the Router takes
`(poolManager, hook, permit2)`, NativeClaims `(poolManager)`.

## Build and test

Requires Foundry, `hnc`, and the checked-out dependencies. Huff is compiled through Foundry FFI.

```sh
forge test --no-match-path 'test/formal/**' --fuzz-seed 0x20261024
forge test --match-contract CodeSizeTest -vv
forge test --match-contract EligibleGasTest -vv
```

From the Python `uv4` checkout, regenerate the shared expectations and test both implementations:

```sh
uv run python examples/validate_three_way.py --solidity /path/to/contracts --huff /path/to/v2-raff
```

The three-way command runs Python model tests, 100 arithmetic/matching vectors, hash vectors,
eight stateful campaigns on both implementations, and 174 native Huff tick-key vectors.
It checks the covered behavior; it does not establish equivalence for arbitrary bytecode or every input.
The normal current-suite command above explicitly excludes historical storage-layout fixtures.
An unfiltered `forge test` still includes those fixtures and is not the current compatibility check.

The hook inlines matching and exact-price indexing. Its price trees and per-bucket priority trees retain
allocator state across empty levels and fully initialize recycled nodes. Native and generic claim redeemers
use transient reentrancy flags. The fee-test and unbound-constructor builds use compile-time constants.
