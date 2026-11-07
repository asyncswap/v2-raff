# Stateful Huff/Solidity comparison

The `differential` profile executes identical calls against the real Solidity and Huff bytecode in separate snapshot worlds at identical addresses. After **every action**, it compares success, exact return/revert bytes, ordered logs and public state. The controller stays in memory across snapshot restores; neither implementation supplies the other's expected state.

Four fixtures cover ETH/USDC and USDC/asset, each with and without pool liquidity. Eighteen action kinds cover submissions, cancellations, repricing, fee top-ups, book matching, claim withdrawals, fee collection, LP/manual fills, nonces, executor permissions, signed operations and ownership transfers. Sequences include authorized calls, invalid callers, closed orders and nonce replays. Four actions share each block to exercise same-block state.

State observations include every recorded order (including closed orders), visited price levels on both sides, best orders, wallet/claim/escrow/vault balances, pool price/liquidity/fee growth, ownership, permissions, allowances and all nonces used by the generator. Each action must leave the manager locked with no outstanding currency deltas.

```sh
FOUNDRY_PROFILE=differential \
DIFF_STEPS=256 \
forge test -j 4 --fuzz-runs 128 --fuzz-seed 0xd1ff2026 -vvv
```

Use Forge 1.8.6, hnc 1.6.2 and configured solc 0.8.26. The command runs 128 random sequences plus one deterministic sequence per fixture: **132,096 paired actions**, or 264,192 protocol calls. CI runs 32 random sequences plus the deterministic sequence per fixture at 128 actions. `DIFF_STEPS` accepts 32–4,096. The profile has separate compilation and failure caches.

Each protocol call is capped at 30M gas. The test controller has a larger gas budget because it repeatedly observes all historical orders. Its reported gas is **not a protocol benchmark**; use the [transaction receipt benchmark](../../../benchmarks/crossing/README.md).

## Regression found

Seed `0xD1FF2026`, action index 8 in the LP fixtures exposed a full-fill ordering difference. Huff settled the priority bid before paying the maker; Solidity closed the order, paid the maker, then settled the bid. `src/current/lib/Liquidity.huff` now preserves the bid on the stack across deletion and maker payout, then settles it. The ordered-log assertion caught this difference and remains unchanged.

```sh
FOUNDRY_PROFILE=differential DIFF_STEPS=32 \
forge test --match-contract '.*LPStateDifferentialTest' --match-test test_actionCoverage -vvvv
```

## Compatibility and limits

The recorded long campaign used Solidity `3f4a5f106f55cc4b90b11d0ce0f0143f5e64ed89`. The copied source is now pinned to v1.3.1 at `34b05bdcfb642727d1d6856f1ba91957dcf5d3b7` to include its added trusted-Router nonce-replay test. The Solidity v1.3.1 source, `34b05bdcfb642727d1d6856f1ba91957dcf5d3b7`, has the identical `src/` tree (`e4ffc367824e2d43caec43e00c1dc26a6ad67f6b`) and includes the accepted nonce-replay fixture correction plus compiler-independent immutable reading for Solidity reference checks.

These comparisons strengthen regression coverage; they do not prove equivalence for every input or internal storage layout. They use controlled ERC20 tokens, zero MEV surcharge, one pool per fixture and bounded nonces. Permit2 submissions and hostile callback behavior remain covered by their separate acceptance tests, rather than this generator. A successful call can be a permitted no-op; action coverage counts call outcomes, not necessarily fills. Solidity architecture-specific checks remain reference-only.

The [release validation record](../results/differential-validation.json) records final results, deterministic action outcomes and source hashes. Existing copied test assertions, assumptions and expected values are unchanged.

## Solar comparison

With Forge 1.9.0 and Solar `0.3.0-dev+commit.a2b44354`, the Huff acceptance suite passes all 1,017 tests/predicates. A separate 32-case × 128-action differential campaign plus deterministic sequences passes **16,896 paired actions**. Huff bytecode still comes from hnc; Solar compiles the Solidity oracle and test harness. The release compiler settings remain unchanged.
