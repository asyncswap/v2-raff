# Audit scope: Async Swap v2 (Huff)

- **Repository:** <https://github.com/asyncswap/v2-raff>
- **Measured revision:** `023b90015f7c772e523ae43a43e4c536d3df2ef0`. This identifies the counted code; the final audit freeze must be agreed with the auditor.
- **Compiler:** Huff Neo `hnc` v1.6.2, pinned in `.github/workflows/test.yml`. Solidity interfaces and the Foundry harness use solc 0.8.26 with `optimizer_runs = 1_000`.
- **Target for this application:** Arbitrum. Existing fork tests target Unichain; they do not establish Arbitrum deployment readiness.
- **Builds on:** Uniswap v4 PoolManager, Permit2 for signed orders, and PoolManager ERC-6909 claims.

## What it is

Async Swap is a Uniswap v4 hook that turns swaps into limit orders for assets paired with USDC. Orders can execute against other orders, permissionless fillers, or available pool liquidity. Unfilled amounts remain available for later execution, repricing, or cancellation. Execution depends on counterparties and liquidity.

This repository implements Async Swap v2 in Huff. Its README identifies `asyncswap/contracts` at `6fa977a` as the Solidity reference. The matching logic is inlined into the hook rather than deployed as a linked Solidity library. The port has its own storage layout and uses transient reentrancy flags in NativeClaims and MatchingEngine. Behavioral equivalence is an audit objective, not an assurance established by this scope.

## In scope: 3,174 source nSLOC

All first-party project components are in scope except tests. The source total covers every file under `src/`, including the standalone matching engine, interfaces, and generated FeeVault creation code. Build tooling, configuration, documentation, and dependency integration are also covered, with their counting treatment described below.

### Huff (`src/`): 2,836 nSLOC, 12 files

| File | nSLOC | Notes |
|---|---:|---|
| `src/AsyncSwap.huff` | 1,091 | Hook entry points, order lifecycle, integrated matching, pool-liquidity fills, ownership and fees |
| `src/Router.huff` | 483 | Submission, Permit2 signed orders, fills, cancellations, matching and unlock callback |
| `src/MatchingEngine.huff` | 315 | Standalone matching engine; included even though the README describes its benchmark role |
| `src/lib/RadixPriceTree.huff` | 218 | Price index and best-price traversal |
| `src/lib/Book.huff` | 214 | Order storage, price levels, queue links and priority accounting |
| `src/lib/PoolManager.huff` | 139 | PoolManager calls and settlement helpers |
| `src/lib/Math.huff` | 117 | Full-precision arithmetic, rounding and match amounts |
| `src/lib/Common.huff` | 82 | Memory layout, checked arithmetic, return and revert helpers |
| `src/FeeVault.huff` | 64 | Fee claims, collection and permissions |
| `src/lib/Signatures.huff` | 59 | EIP-712 encoding and signature verification |
| `src/NativeClaims.huff` | 51 | Native ETH claim redemption and callback authentication |
| `src/generated/FeeVaultCreation.huff` | 3 | Generated FeeVault creation code embedded in the hook |

### Solidity interfaces and types (`src/interface/`): 338 nSLOC, 8 files

| File | nSLOC | Notes |
|---|---:|---|
| `src/interface/IAsyncSwap.sol` | 143 | Hook ABI |
| `src/interface/IMatchingEngine.sol` | 45 | Standalone matching engine ABI |
| `src/interface/IRouter.sol` | 43 | Router ABI |
| `src/interface/IAsyncFiller.sol` | 38 | Order-book types, events and errors |
| `src/interface/ISignatureTransfer.sol` | 24 | Permit2 interface |
| `src/interface/types/AsyncOrder.sol` | 22 | Order representation and helpers |
| `src/interface/IFeeVault.sol` | 12 | FeeVault ABI |
| `src/interface/INativeClaims.sol` | 11 | NativeClaims ABI |

### Build tooling, configuration and supporting material

- `script/huff-codegen.sh`: 8 nonblank, noncomment lines; generates the FeeVault creation code. Including this script gives **3,182 source-and-script nSLOC**. Its heredoc contains generated Huff, so this is not a count of unique logic.
- `.github/workflows/test.yml`: compiler pinning, dependency installation and generated-code freshness checks. Test implementation remains excluded.
- `foundry.toml`, `foundry.lock`, `soldeer.lock`, `remappings.txt`, `.gitmodules`, and `.gitignore`: compiler settings, dependency resolution, build inputs and artifact handling.
- `README.md`, `MAINNET_READINESS.md`, and `docs/`: specification and deployment assumptions, checked against the Huff implementation. Copied Solidity documentation must not be treated as verified Huff deployment evidence.
- `dependencies/` and `lib/`: pinned third-party dependencies and their interaction with the project. Their upstream source is not included in the first-party line total. Any full upstream audit should be separately sized with the auditor; dependency integration is included here.

The measured revision contains one tracked script, `script/huff-codegen.sh`; do not assume deployment scripts described in inherited documentation exist in this repository. Any added Arbitrum deployment scripts or contract changes require an updated scope and count.

### Counting method

Counts use tracked files at the measured revision. Source nSLOC means physical lines remaining after removing `//` and `/* ... */` comments and blank lines while preserving string literals. Declarations, braces and multiple-instruction Huff lines each count as their physical source lines. The 20 source files contain **4,080 total physical lines**, including comments and blanks.

Generated FeeVault creation code is included as three source lines, one of which contains a long bytecode literal; nSLOC therefore understates its bytecode size. Review should establish that this artifact matches FeeVault compiled with the pinned toolchain. Huff and Solidity line counts are not directly comparable measures of audit effort.

Tests under `test/`, including harnesses and test utilities, are excluded. Build outputs, caches and local untracked artifacts are not counted as authored source. Documentation, configuration, lockfiles and vendored dependency code are not included in the 3,174 source nSLOC total.

## Where to look hardest

- **Escrow conservation:** input and output accounting across matching, partial fills, manual fills, pool-liquidity fills, cancellations and fee collection; no double release or unbacked claims.
- **Order-book correctness:** price crossing, radix traversal, FIFO links, priority tie-breaking, repricing, residual amounts, dust and adversarial orders that could block execution.
- **Priority bids:** funding, eligibility for priority, donation or forfeiture, and behavior when liquidity is absent.
- **Native settlement:** ERC-6909 backing, redemption permissions, recipient behavior, failure rollback and protection against double spending.
- **Authorization:** maker and executor identity, callback caller validation, Permit2 witness binding, signature domains, nonces, expiry and replay protection.
- **Huff execution:** stack discipline, jumps, calldata bounds, ABI encoding and decoding, dirty upper bits, fixed memory-region overlap, return-data handling, storage-slot derivation and transient-storage lifecycle.
- **Arithmetic:** full-precision multiplication/division, overflow, rounding direction, price comparisons and minimum-output enforcement.
- **External calls:** reentrancy, malicious tokens, failed transfers and atomic rollback across hook, Router, FeeVault and PoolManager interactions.
- **Deployment:** constructor arguments, embedded FeeVault creation code, production compile-time flags, hook address permissions, compiler reproducibility and final runtime identity.

For Arbitrum, verify the actual PoolManager, Permit2 and approved USDC addresses, target-chain EVM compatibility, and deployment configuration. Add Arbitrum fork and deployment-rehearsal evidence before claiming chain-specific readiness.

## Trust assumptions to validate

- **Owner:** administrative and fee-collection authority must not allow withdrawal of maker escrow. Validate ownership transfer and pool-ordering configuration restrictions.
- **Executors:** authority is scoped to the maker and pool; authorization must not confer access to unrelated orders or deposits.
- **Fillers and matchers:** untrusted, permissionless participants whose calls must preserve all accounting and price constraints.
- **Tokens:** intended support is USDC, standard ERC-20s and native ETH. Confirm token assumptions against the implementation; do not infer support for rebasing or fee-on-transfer assets.
- **External infrastructure:** PoolManager and Permit2 are assumed to be the intended deployments; the audit must check configuration and correct use of their interfaces.

## Known issues and prior reviews

No finding exclusions are asserted by this scope. Known limitations or accepted risks should be agreed against the pinned Huff revision. Historical findings, fixes and audit reports for the Solidity implementation are context, not evidence that the corresponding Huff implementation has been audited or that each fix carries over correctly.

## Testing evidence (outside the audit scope)

The repository README reports 181 reference-suite tests plus one Huff code-size test passing, with three fork tests requiring the configured Unichain RPC and block. These are repository-reported results, not tests rerun while preparing this document. Test results support review but do not establish security or equivalence. Auditors may use the tests as evidence while keeping test source outside the review scope.
