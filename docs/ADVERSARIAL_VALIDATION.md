# Shared-USDC adversarial validation

Historical first pass: the results below predate the production balance checks and changing-LP tests in [LP accounting and token delivery validation](LP_ACCOUNTING_AND_TOKEN_TRANSFERS.md).

This pass tests accounting and authorization assumptions around Async Swap v1.3.1. It adds tests only; production contracts and existing assertions are unchanged. ERC-777 is unsupported and excluded from this acceptance scope.

## Results

| Check | Solidity | Huff |
| --- | --- | --- |
| New adversarial tests, solc 0.8.26 | 11 passed | 11 passed |
| Stateful fuzzing | 512 cases × 64 actions | 512 cases × 64 actions |
| Short-payment rejection fuzzing | 512 cases | 512 cases |
| Deterministic state comparison | 64 checkpoints | All 64 match Solidity |
| Existing related regressions | 68 passed | 68 passed |
| New suite with Solar | 11 passed; 64 fuzz cases | 11 passed; 64 fuzz cases |

Each solc campaign checks accounting after **32,768 randomized actions**, plus 64 deterministic actions. The randomized campaigns are independent runs with the same seed; only the deterministic 64-step trace is compared directly between implementations. Repeated smoke runs are not added to these counts. No protocol defect was reproduced by this pass.

Baseline: Solidity `34b05bdcfb642727d1d6856f1ba91957dcf5d3b7`; Huff `1ce69b17dd040f59a323929bf8ca863e2169a6a3`. Canonical toolchain: Forge 1.8.6, solc 0.8.26, Huff Neo 1.6.2. Solar checks use Forge 1.9.0 and the installed Solar `0.3.0-dev+commit.a2b44354`. The pinned Huff acceptance manifest remains unchanged; these are supplemental tests, not a new claim about its ported-test count.

## Assumptions challenged

| Area | What the tests establish within the fixture |
| --- | --- |
| Shared USDC custody | Aggregate hook claims equal all live order inputs plus remaining USDC bids across three pools. A payment shortfall cannot consume another pool's backing. |
| Different decimals and orientation | Asset-18/USDC-6, USDC-6/asset-8, and native ETH/USDC-6 use actual decimals and quantity-to-USDC conversions. |
| Pool isolation | Identical salts do not alias order IDs; a pool-specific executor cannot cancel another pool's order. |
| Signature domains | Wrong-pool and wrong-chain signatures fail without consuming a nonce. A valid nonce is maker-global and cannot be reused in another pool. |
| Partial-fill fee top-ups | A bid reduced to 50,000 units rejects a 49,999-unit addition when the minimum total is 100,000; the exact 50,000-unit addition succeeds. Rejection restores payment, order terms and queue metadata. |
| Withdrawal rollback | A failed ERC-20 transfer after an ETH withdrawal restores both balances, claims and allowances. Retrying after restoring transfers succeeds. |
| Frozen asset isolation | A failed asset payout preserves its order while another asset/USDC pool can settle. This does not promise recovery of frozen assets. |
| Tax and transient state | Zero/nonzero priority gas prices, failed taxed calls, untaxed calls and a pre-existing router ETH balance do not replay or subsidize the tax. |
| Administration | Owner rotation changes fee-collection authority; collecting fees and sweeping donated tokens preserve escrow obligations. |

The stateful observer independently sums obligations and custody after every successful action. It requires PoolManager to be locked with zero unsettled deltas. ERC-20 balances across all fixture wallets and custody must sum to total supply. Calls are not wrapped in blanket `try/catch`; unexpected reverts fail the campaign.

The deterministic trace covers all eight actions: submit **13**, cancel **4**, reprice **6**, top up **8**, match book **6**, manual fill **7**, collect fees **14**, withdraw claims **6**. Submissions mix zero and paid bids. State hashes include live order records, original sequence/reprice counters, best orders and their levels, wallet balances, claims and router claim allowances. Contract balances are normalized by role to accommodate different deployment addresses.

Existing regressions cover matching reference models, incoming-memory matching, top-ups, router claims, native settlement reentrancy and MEV tax. Those tests retain their original assertions.

## Fixture corrections

The first generator assumed any positive top-up was valid after a partial fill. The protocol requires the resulting bid to meet the current minimum. A separate boundary regression now checks both rejection and acceptance; successful random top-ups add at least the 100,000-unit cap.

Solar exposed another fixture assumption: reading `block.chainid` into a local variable does not reliably preserve the old value across `vm.chainId`. The trace restored 31338 instead of 31337. The fixture now uses `vm.getChainId()`, as documented in the installed forge-std `Vm.sol`. Signature assertions are unchanged. This was a test portability issue, not evidence of a protocol signature bypass or a Solar defect.

## Reproduce

From the Solidity checkout, using Forge 1.8.6:

```sh
forge test --offline --match-contract '^AdversarialAssumptionsTest$' \
  --fuzz-runs 512 --fuzz-seed 0xa55e72026 -j 2 -vvv

forge test --offline --match-contract '^AdversarialAssumptionsTest$' \
  --match-test test_deterministicCampaignExercisesEveryAction -vvvv \
  > /tmp/adversarial-solidity-checkpoints.log
```

From the Huff checkout:

```sh
FOUNDRY_PROFILE=adversarial forge test --offline \
  --match-contract '^AdversarialAssumptionsTest$' \
  --fuzz-runs 512 --fuzz-seed 0xa55e72026 -j 2 -vvv

FOUNDRY_PROFILE=adversarial forge test --offline \
  --match-contract '^AdversarialAssumptionsTest$' \
  --match-test test_deterministicCampaignExercisesEveryAction -vvvv \
  > /tmp/adversarial-huff-checkpoints.log

python3 script/check-adversarial-state.py \
  /tmp/adversarial-solidity-checkpoints.log /tmp/adversarial-huff-checkpoints.log

python3 script/sync-adversarial-tests.py /path/to/solidity-checkout --check
```

The copy checker permits only fixture import/artifact path substitutions and formatting; it preserves every test token and string. Huff deploys through the existing `SetupHook` adapter, which compiles the Huff sources. It does not deploy the Solidity protocol as a substitute.

Solar, using a Forge installation with Solar available, in either checkout (set `FOUNDRY_PROFILE=adversarial` for Huff):

```sh
forge test --use solar --offline --out out-solar-adversarial \
  --cache-path cache-solar-adversarial \
  --match-contract '^AdversarialAssumptionsTest$' \
  --fuzz-runs 64 --fuzz-seed 0xa55e72026 -j 2 -vvv
```

## Boundaries

- The new multi-pool campaign has **no LP liquidity**. Exact physical custody equals claims only under that fixture assumption. Combining shared custody with LP fee growth and liquidity changes remains a separate validation task.
- It uses test tokens, no live RPCs, production accounts or deployed-token integration. Short-payment and false-return tokens are rejection/rollback probes, not a promise to support fee-on-transfer, rebasing or ERC-777 tokens.
- Minimum order size is disabled and asset precision is unrestricted in this fixture. Production token admission rules and nonzero minimums need their own integration matrix.
- The oracle checks accounting and selected observable state, not every storage slot, event or economic property. The deterministic trace is not exhaustive differential fuzzing.
- The campaign advances block number/time inside a test transaction. It stresses repeated transient-state use but does not simulate sequencer ordering, reorgs, censorship or competing transactions.
- These are behavioral validation results, not a gas benchmark, a proof of safety or an independent audit. The full historical suite was not rerun in this pass; the 68 related regressions were.
