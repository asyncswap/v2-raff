# v2-raff

Async Swap v2 in [Huff](https://www.huff-neo.rs), compiled with [huff-neo](https://github.com/cakevm/huff-neo)
(`hnc`): a port of [`asyncswap/contracts`](https://github.com/asyncswap/contracts) (`main` @ `6fa977a`) with the
same ABI, events, errors, revert strings and behaviour. The acceptance test is `asyncswap/contracts`' own suite,
copied here with three kinds of edits: its imports take the ABI from `interfaces/`, its deploy lines deploy the
Huff, and the two Solidity subclasses it defined (a fee variant, and a constructor harness that skips the
hook-address check) are Huff builds with a compile-time flag instead:

| | passed | failed | skipped |
| --- | ---: | ---: | ---: |
| `asyncswap/contracts`, Solidity | 178 | 0 | 1 |
| this repo, Huff | 178 + 1 | 0 | 1 |

The skipped test is the Unichain fork test, which needs `UNICHAIN_FORK_RPC_URL`. The `+ 1` is
`test/huff/CodeSize.t.sol`, which keeps the Huff runtimes under EIP-170. Created from the
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
| `interfaces/` | The Solidity ABI: `IAsyncSwap`, `IRouter`, `IFeeVault`, `INativeClaims`, `IMatchingEngine`, `IAsyncFiller` (order-book types, events, errors), `ISignatureTransfer`, the `AsyncOrder` struct |
| `test/` | `asyncswap/contracts`' tests. They import the interfaces under the contracts' names and deploy through `test/utils/HuffDeploy.sol`; `test/utils/OrderSignatures.sol` and `CurrencySettler.sol` are the two Solidity helpers they call |
| `docs/`, `MAINNET_READINESS.md` | Copied from `asyncswap/contracts` |

`src/` is Huff only.

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

## Gas

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
FOUNDRY_INVARIANT_RUNS=64 FOUNDRY_INVARIANT_DEPTH=64 forge test   # the CI depth
./script/huff-codegen.sh                     # after changing src/FeeVault.huff
hnc src/AsyncSwap.huff -b                   # creation code (append the constructor arguments)
```

CI (`.github/workflows/test.yml`) runs fmt, checks that `src/generated/` is current, and runs the suite at
the invariant depth `asyncswap/contracts`' CI uses, against the huff-neo release pinned in `HNC_VERSION`.
