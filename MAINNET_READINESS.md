# Unichain mainnet readiness

Status: BLOCKED. No mainnet deployment was broadcast during this preparation.

## Native settlement

Native ETH proceeds and refunds mint PoolManager ERC-6909 claims (ID 0) directly to recipients. Matching, manual fills, LP fills, and cancellations make no calls to native recipients. ERC20 settlement transfers tokens directly.

A recipient that rejects ETH is covered by `test_rejectingBestBuyerReceivesClaimsWithoutBlocking`, which requires successful matching and credits the rejecting recipient with claims. NativeClaims redeems only the caller's claims after a PoolManager approval, to a chosen nonzero recipient. Failed transfers restore claims and allowance atomically. Tests cover partial redemption, unauthorized access, callback authentication, reentrant unlock attempts, and double spending.

This covers native settlement only. ERC20 callback behavior and the broader matching/settlement architecture require security review.

## Evidence collected

- Existing suite: 119 passing tests before this preparation.
- UnichainForkTest: 3 passing tests against block 61279110, using real PoolManager and USDC with test-funded accounts. Covers native/USDC fills, residual cancellation, nonrefundable priority fees without LPs, and continuation after the eight-match bound.
- MatchingInvariantTest and priority variant: 6 passing invariants, each with 64 runs and depth 64 (4096 calls), fail-on-revert enabled. Checks outstanding escrow, asset conservation, and best prices against a linear scan.
- UnpaidBidInvariantTest: 7 passing invariants (128 runs, depth 64) with orders whose priority bid was never paid (placed straight through the PoolManager, down to 1 wei, bids up to `uint64` max): matching never reverts, a crossing taker can always trade, every open order can be cancelled, an unpaid bid buys no priority, plus escrow, conservation and best-price checks. Against the code before #9, five of them fail.
- Full run: 155 tests passed, zero failed (2026-10-19, at the audit freeze). The 3 pinned Unichain fork tests are skipped unless the fork RPC variables are set; with them set they pass (re-run 2026-10-15 against block 61279110). Includes the native LP fill test and the price-key crossing tests (`docs/price-key-crossing.md`). Invariants include randomized claim redemption and exact native backing (64 runs, depth 64, fail-on-revert).
- Local CREATE2 deployment and indexed frontend: integrated contracts settle 0.4 ETH for 1000 USDC and 0.6 ETH for 1500 USDC, with recipient balances reflecting both fills.

Fork command:

```sh
UNICHAIN_FORK_RPC_URL=https://mainnet.unichain.org UNICHAIN_FORK_BLOCK=61279110 forge test --match-contract UnichainForkTest -vv
FOUNDRY_INVARIANT_RUNS=64 FOUNDRY_INVARIANT_DEPTH=64 FOUNDRY_INVARIANT_FAIL_ON_REVERT=true forge test --match-contract MatchingInvariantTest -vv
```

The fork fixture installs hook code for tests. It is not a rehearsal of the complete production deployment script. The local demo deploys a new mock-USDC market; it is not a mainnet liquidity simulation.

## Deployment constraints

- Chain: Unichain 130.
- PoolManager: 0x1F98400000000000000000000000000000000004. Source: https://developers.uniswap.org/docs/protocols/v4/deployments
- USDC configuration: 0x078D782b760474a361dDA0AF3839290b0EF57AD6. Revalidate issuer address and decimals in the final rehearsal.
- Current artifact runtime size: hook 24,428 bytes, leaving 148 bytes under EIP-170 (after #9). Recheck after any further change.
- Deployment wrapper checks library code presence, not exact runtime identity. Pin and verify the final library and hook runtime hashes.
- Owner in current script: 0xb1F0982E02f9F71E60512fd47471d76610CcB556. Confirm final owner, operational permissions, and funding before broadcast.

## Release work remaining

Complete callback safety review beyond native settlement. Stress the integrated custody path at 100 transactions per block with adversarial dust, cancellation, and priority cases. Existing standalone matching benchmarks do not establish integrated throughput. Complete a pinned deployment-script fork rehearsal, final-bytecode verification, and independent security review. Confirm the production indexer/frontend understand all v2 events and order states. The local matching lab uses a separate SQLite indexer.

`script/check-mainnet-readiness.sh` runs the native rejecting-recipient test and deliberately keeps release blocked pending independent review and the remaining deployment/stress work.

NativeClaims deployment preparation: `script/DeployNativeClaims.s.sol`. No broadcast has been made. Clients must display native proceeds as claim balances, approve claim ID 0 on PoolManager, and call `NativeClaims.redeem(recipient, amount)`. Approval is for claims, not ERC20 or hook executor permissions. Runtime sizes as of 2026-10-19 (`forge build --sizes`): hook 24,428 bytes, AsyncMatching 19,440 bytes, NativeClaims 1,666 bytes.
