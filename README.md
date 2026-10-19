# v2-raff

Async Swap v2 in [Huff](https://www.huff-neo.rs), compiled with [huff-neo](https://github.com/cakevm/huff-neo)
(`hnc`). A port of the Solidity v2 in
[`asyncswap/v2-from-proofs`](https://github.com/asyncswap/v2-from-proofs), which was rebuilt from the Lean
proofs in [`asyncswap/v2-proofs`](https://github.com/asyncswap/v2-proofs). Same ABI, events, errors and
behaviour; it passes v2's own test suite. Created from the [`asyncswap/raff`](https://github.com/asyncswap/raff)
template.

Async Swap is an order book and matching engine built as a Uniswap v4 hook: an exact-input swap becomes an
escrowed limit order (the hook's ERC-6909 claims in the PoolManager), which other orders, fillers or the pool's
liquidity can fill.

## Contracts

| File | What it is | Solidity v2 |
| --- | --- | --- |
| `src/AsyncSwap.huff` | The hook: create in `beforeSwap`, match, fill, cancel, reprice, liquidity fill, signed actions, admin, views | `AsyncSwap`, `HookSettlement`, `Owned2Step` |
| `src/Router.huff` | User entry points and the unlock callback: `swap`, `swapWithSig` (Permit2 witness), `fillOrder`, `cancelOrder`, `cancelWithSig`, `matchBook`, `fillFromPoolLiquidity` | `Router` |
| `src/FeeVault.huff` | Holds fees and forfeited bids as ERC-6909 claims; owner `collect` | `FeeVault` |
| `src/NativeClaims.huff` | Redeems native-ETH claims for ETH | `NativeClaims` |
| `src/lib/Book.huff` | Order storage, price levels, FIFO / priority-bid ordering, partial-fill reduction | `AsyncFiller` |
| `src/lib/RadixPriceTree.huff` | Patricia trie over `uint128` price keys, with id recycling | `RadixPriceTree` |
| `src/lib/Math.huff` | 512-bit `mulDiv` (OpenZeppelin 5.0.2 semantics), fee, price and priority keys, match amounts | `AsyncMatching`, `ProtocolFee`, OZ `Math` |
| `src/lib/Signatures.huff` | EIP-712 domain and typed data, `SignatureChecker` (ECDSA low-s, then ERC-1271) | `OrderSignatures`, OZ `EIP712`, `SignatureChecker` |
| `src/lib/PoolManager.huff` | PoolManager calls: take, mint, burn, settle, sync, donate, swap, unlock, extsload | v4 `CurrencySettler`, `StateLibrary` |
| `src/lib/Owned2Step.huff`, `src/lib/Common.huff` | Two-step ownership; memory map, reverts, checked arithmetic | `Owned2Step` |

Constructor arguments are ABI-encoded after the creation code, as in Solidity: the hook takes `(manager,
feeVault, numeraire, owner)` and must sit at an address whose low 14 bits are exactly `0x2088`
(beforeInitialize, beforeSwap, beforeSwapReturnDelta); the Router `(manager, hook, permit2)`, the FeeVault
`(manager, owner)`, NativeClaims `(manager)`. Immutables are appended to the runtime code and copied to memory
once per call.

Where the Huff differs from the Solidity (behaviour is the same):

- Storage layout. Each pool's state hangs off `keccak(poolId, 3)`; an order is six slots; a level's priority
  key is derived from the order's bid and sequence instead of stored. See the header of `src/lib/Book.huff`.
- The Router's unlock payload is a fixed word layout instead of nested `abi.encode`; only the Router reads it.
- Calldata is not validated as strictly as Solidity's ABI decoder: addresses and bools that are read are
  checked, but other dirty high bits in a `PoolKey` are not rejected.

## Tests

`test/` is v2's suite — lifecycle, matching, numeraire on either side, signatures, invariants — run against
the Huff bytecode, plus `RadixPriceTree`, `AsyncMatching`, `ProtocolFee` and `Math` tests that drive the
library routines through Huff harnesses (`test/harness/`) and fuzz them against the Solidity originals
(`test/reference/`). 106 tests.

```sh
forge test                                # Huff hook, Router, FeeVault, NativeClaims
REFERENCE_PERIPHERY=true forge test       # Huff hook with the Solidity Router / FeeVault / NativeClaims
```

The invariant handler swallows reverts, so `afterInvariant` asserts each run placed orders and that later
actions succeeded; a broken Router fails the run instead of passing vacuously.

## Gas

Per-test gas over the 64 lifecycle, matching, numeraire and signature tests, against the same tests on the
Solidity v2 (via-IR, 200 runs): 5.5% less in total, 10–14% less on fills, cancels and matching. These are whole
tests, so they include PoolManager and token work the port does not change, and the two repos pin different
v4-core commits.

| Test | Solidity | Huff | |
| --- | ---: | ---: | ---: |
| `test_create_escrowsInputAsClaims` | 419,964 | 396,626 | −5.6% |
| `test_fill_settlement` | 468,972 | 422,054 | −10.0% |
| `test_cancel_settlement` | 542,325 | 464,125 | −14.4% |
| `test_match_fullFill` | 719,561 | 646,288 | −10.2% |
| `test_match_partialFills_makerLimitHonored` | 1,038,815 | 926,241 | −10.8% |
| `test_fillFromPoolLiquidity` | 443,534 | 400,888 | −9.6% |
| `test_priority_bidFirstThenFifo` | 2,377,935 | 2,083,384 | −12.4% |

Creation code: AsyncSwap 22,894 bytes (under EIP-170), Router 6,743, FeeVault 1,117, NativeClaims 607.

## Setup

```sh
curl -L https://foundry.paradigm.xyz | bash && foundryup
curl -L https://raw.githubusercontent.com/cakevm/huff-neo/main/hnc-up/install | bash && hnc-up
git clone --recurse-submodules https://github.com/asyncswap/v2-raff
```

```sh
hnc src/AsyncSwap.huff -b     # creation bytecode (append the ABI-encoded constructor arguments)
forge test                    # needs hnc on PATH; ffi is on in foundry.toml
forge fmt --check
```

CI (`.github/workflows/test.yml`) runs these against the huff-neo release pinned in `HNC_VERSION`.
