# Async Swap v2 protocol map

Async Swap v2 is a Uniswap v4 hook that turns exact-input swaps into resting limit orders. This page
describes the whole protocol in diagrams: which contracts exist, where funds sit, how an order is
created, matched, filled, repriced and cancelled, and who is allowed to do what. Every box names a
contract, library or function in `src/`, so the diagrams can be checked against the code. The formal
model of the same machine lives in [`asyncswap/v2-proofs`](https://github.com/asyncswap/v2-proofs).

## 1. Components

```mermaid
flowchart LR
    subgraph Actors
        Maker["Maker<br/>(places, reprices, cancels)"]
        Filler["Filler<br/>(fills a resting order)"]
        Relayer["Relayer<br/>(submits signed orders)"]
        Keeper["Anyone<br/>(matchBook, fillFromPoolLiquidity)"]
        LP["v4 LP<br/>(adds range liquidity)"]
        Owner["Protocol owner<br/>(FeeVault.collect, sweep, ordering mode)"]
    end

    subgraph Periphery
        Router["Router.sol<br/>swap · swapWithSig · fillOrder<br/>cancelOrder · cancelWithSig<br/>matchBook · fillFromPoolLiquidity"]
        Permit2["Permit2<br/>permitWitnessTransferFrom"]
        NativeClaims["NativeClaims.sol<br/>redeem native claims (ID 0)"]
    end

    subgraph Core
        PM["Uniswap v4 PoolManager<br/>unlock · swap · donate<br/>ERC-6909 claims"]
        Hook["AsyncSwap.sol (hook)<br/>beforeInitialize · beforeSwap<br/>beforeAddLiquidity<br/>matchNewOrder · executeOrder<br/>updatePrice · cancelOrder<br/>setExecutor(WithSig)"]
        Matching["AsyncMatching.sol<br/>external library, delegatecall<br/>addOrder · match · fill · cancel<br/>updatePrice · fillFromPool"]
        Filler_["AsyncFiller.sol<br/>State: orders, isExecutor<br/>Book: bids, asks, levels"]
        Radix["RadixPriceTree.sol<br/>best bid / best ask<br/>priority tree per level"]
        Sigs["OrderSignatures.sol<br/>EIP-712 types · Permit2 witness"]
        Vault["FeeVault.sol<br/>owns protocol fee claims in PoolManager<br/>collect(currency, recipient)"]
    end

    Maker -->|swap, cancelOrder| Router
    Maker -->|setExecutor, updatePrice| Hook
    Relayer -->|swapWithSig, cancelWithSig| Router
    Filler -->|fillOrder maxPrice| Router
    Keeper -->|matchBook, fillFromPoolLiquidity| Router
    LP -->|modifyLiquidity| PM
    Owner -->|collect| Vault
    Owner -->|sweep, setOrderingMode| Hook

    Router -->|unlock → unlockCallback| PM
    Router -->|signed input| Permit2
    Permit2 -->|transfer input| PM
    PM -->|beforeSwap hookData| Hook
    Router -->|matchNewOrder, executeOrder,<br/>cancelOrder, matchBook,<br/>tryFillOrderFromPoolLiquidity| Hook
    Hook -.->|delegatecall| Matching
    Matching --> Filler_
    Filler_ --> Radix
    Hook --> Sigs
    Router --> Sigs
    Hook -->|mint / take / burn / settle / donate| PM
    PM -.->|accounting credit, not a contract call| Vault
    Vault -->|burn + take| PM
    Maker -->|redeem| NativeClaims
    NativeClaims -->|burn ID 0, send ETH| PM
```

Every pool that uses the hook must contain the chain's USDC (`numeraire`) and use the dynamic-fee flag
(`beforeInitialize`). `beforeAddLiquidity` is a pass-through: anyone may add ordinary v4 range
positions, and they are the inventory for the LP-fill path. No swap ever reaches the AMM curve
directly, because `beforeSwap` consumes the whole input as an order; the only AMM swaps are the ones
the hook itself performs when it fills a resting order from pool liquidity. The standalone
`MatchingEngine.sol` is a benchmark harness and is not deployed.

FeeVault owns claims recorded in PoolManager. Crediting those claims does not call FeeVault.

## 2. Where funds live

```mermaid
flowchart TB
    subgraph PoolManager["PoolManager (custody)"]
        Escrow["ERC-6909 claims owned by the hook<br/>one balance per currency<br/>= Σ open orders' remaining input<br/>+ escrowed priority bids"]
        Fees["ERC-6909 claims owned by FeeVault<br/>= accrued 30 bps fill fees<br/>+ forfeited priority bids"]
        User["ERC-6909 claims owned by makers / fillers<br/>native proceeds (claim ID 0)"]
        Reserves["Pool reserves<br/>v4 LP positions + donations"]
    end
    MakerW["Maker wallet"] -->|input on swap| Escrow
    Escrow -->|cancel: full remainder| MakerW
    Escrow -->|match or fill: input| CounterW["Counterparty wallet"]
    CounterW -->|output| MakerW
    FillerW["Filler wallet"] -->|protocol fee from gross output payment| Fees
    Escrow -->|priority bid share| Reserves
    Escrow -->|bid with no active LP| Fees
    Fees -->|collect| OwnerW["Owner-chosen recipient"]
    User -->|NativeClaims.redeem| MakerW
```

Fees, by path: an order-to-order match charges nothing; a filler fill (`Router.fillOrder`) pays
the maker's live minimum plus 30 bps of gross output, and that fee lands in the FeeVault as claims;
an LP fill charges the 30 bps dynamic LP fee to the active v4 positions. `calculateHookFee` is zero.
Priority bids are escrowed as hook claims when the order is created (`recordPriorityFee`), donated
proportionally to active LPs as input fills, and forfeited to the FeeVault only when the pool has no
active liquidity at that moment. A bid counts only once it is escrowed: an order whose bid was never
paid (placed straight through the PoolManager, not the Router) queues as if its bid were 0, and
fills, matches and cancels settle only the paid bid, so an unpaid bid can never block the book
(`test/UnpaidBidInvariant.t.sol`).

Invariant proved in `v2-proofs` and fuzzed by `MatchingInvariantTest` and `UnpaidBidInvariantTest`: the hook's claim balance for
each currency equals the sum of remaining inputs of open orders plus escrowed bids, and nothing is
created or destroyed by a match. The hook's own token balance is zero between transactions, so
`sweep` can only move stranded ETH or donations, never escrow.

## 3. Placing an order

```mermaid
sequenceDiagram
    autonumber
    participant M as Maker
    participant R as Router
    participant PM as PoolManager
    participant H as AsyncSwap hook
    participant AM as AsyncMatching (delegatecall)

    M->>H: setExecutor(poolId, Router, true) — once per pool
    M->>R: swap(order, UserParams)
    Note over R: checks owner == msg.sender, executor == Router,<br/>amountOutMin and priorityFee match the order
    R->>PM: unlock(Swap)
    PM->>R: unlockCallback
    R->>PM: swap(key, exactInput = -amountIn, hookData)
    PM->>H: beforeSwap(sender = Router, params, hookData)
    H->>PM: take(input, hook, amountIn, claims = true)
    H->>AM: addOrder(id, owner, amountIn, amountOutMin, isBuy, priorityFee)
    Note over AM: salt assigned by the hook, priceKey = WAD ratio,<br/>order linked into the bid or ask level
    H-->>PM: BeforeSwapDelta consumes the whole input
    R->>PM: settle input from maker (ERC-20 transferFrom or forwarded ETH)
    opt priorityFee > 0
        R->>PM: settleFor(hook) with USDC bid
        R->>H: recordPriorityFee(key, maker, bid)
    end
    R->>H: matchNewOrder(order)
    H->>AM: match up to 8 crossing resting orders
    opt Incoming order still open
        H->>H: guarded self-call for LP fill
        H->>AM: try full remainder against active LP liquidity
        AM-->>H: Fill succeeds or LP attempt rolls back
    end
    H-->>R: Matched pair count
    R-->>PM: Callback complete
    PM-->>R: Unlock complete with settled deltas
    R-->>M: Transaction succeeds
    Note over H: emits AsyncOrderCreated, AsyncOrdersMatched / AsyncOrderLiquidityFilled
```

Signed orders follow the same path through `swapWithSig`. The maker signs one Permit2
`PermitWitnessTransferFrom` whose witness is `OrderSignatures.hashOrder(order)`, so the signature
both moves the input and commits to the order. A relayer can also attach a signed `SetExecutor` grant
for the maker's first order on a pool.

## 4. Everything after placement

Filler fills, book continuation, LP retries, repricing, cancellation, pool setup, native-claim
redemption and fee collection are drawn step by step in
[`contract-call-sequences.md`](contract-call-sequences.md); the lifecycle and priority-bid flowcharts
are in [`order-lifecycle.md`](order-lifecycle.md). Three facts to keep in mind while reading them:

- An order-to-order match charges no fee. The 30 bps protocol fee is paid by the filler on top of the
  maker's live minimum and is credited to the FeeVault as ERC-6909 claims inside the PoolManager; the
  LP-fill path instead charges the 30 bps dynamic LP fee to active v4 positions. `calculateHookFee`
  is zero.
- `updatePrice` only re-ranks the order in the book. It needs no PoolManager unlock and triggers no
  matching; a later crossing order, `matchBook`, a filler or an LP retry has to execute it.
- `matchNewOrder` and `recordPriorityFee` are gated by a transient slot that `beforeSwap` writes for
  the current transaction. `executeOrder`, `cancelOrder` and `tryFillOrderFromPoolLiquidity` check
  `isExecutor[maker][caller]` instead.

An order's identity is `keccak(chainId, poolId, owner, zeroForOne, salt)`. The hook assigns the
salt at creation and emits it in `AsyncOrderCreated`; later calls recompute the id from the maker's
struct, so a maker needs the event or an indexer to cancel or reprice.

## 5. Authorization

```mermaid
flowchart LR
    subgraph MakerRights["Maker (order.owner)"]
        m1["swap / cancelOrder via Router<br/>(msg.sender must be owner)"]
        m2["updatePrice (msg.sender must be owner)"]
        m3["setExecutor / revoke"]
        m4["sign: Permit2 order witness,<br/>SetExecutor, UpdatePrice, CancelOrder (EIP-712)"]
    end
    subgraph ExecutorRights["Registered executor (the Router)"]
        e1["beforeSwap sender must equal hookData.executor<br/>and be authorised by the maker"]
        e2["executeOrder, cancelOrder, tryFillOrderFromPoolLiquidity<br/>require isExecutor[maker][caller], inside the unlock"]
        e3["matchNewOrder, recordPriorityFee: only the executor<br/>recorded by beforeSwap in the same tx (transient slot)"]
    end
    subgraph OwnerRights["Protocol owner (two-step transfer)"]
        o1["FeeVault.collect(currency, recipient)"]
        o2["sweep(currency, to) — hook's raw balance only"]
        o3["setOrderingMode(key, FIFO | PriorityFee)<br/>only while the book is empty"]
        o4["no pause, no upgrade, no access to escrow"]
    end
    subgraph Public["Anyone"]
        p1["matchBook(key, 1..8)"]
        p2["fillFromPoolLiquidity(order)"]
        p3["fillOrder(order, maxPrice) — pays the maker"]
        p4["submit a maker's signed order or cancel"]
    end
```

Signed maker actions use unordered nonces: `AsyncSwap.nonceUsed` for `SetExecutor` and
`UpdatePrice`, `Router.cancelNonceUsed` for `CancelOrder`, and Permit2's own nonces for order
witnesses. The Permit2 witness binds maker, both tokens, amounts, bid and pool; it leaves out
`sqrtPrice` (never read, the hook consumes the whole swap) and `salt` (assigned by the hook).

## 6. Deployment shape

```mermaid
flowchart LR
    D["CREATE2 deployer<br/>0x4e59…956C"] -->|fixed salt| Lib["AsyncMatching library<br/>same address on every chain"]
    D -->|mined salt: flags + 0x91 prefix| Hook["AsyncSwap hook<br/>constructor(PoolManager, USDC, owner)"]
    Hook -->|constructor| Vault["FeeVault"]
    Owner["Deployer / owner"] -->|CREATE| Router["Router(PoolManager, hook, Permit2)"]
    Lib -.->|linked into bytecode| Hook
    Owner -->|CREATE, separate script| NC["NativeClaims(PoolManager)"]
    Hook -->|initialize| Pool["Pool: USDC × asset<br/>dynamic fee flag, hook address"]
```

`script/deploy.sh <chain-key> [dry-run|broadcast|verify]` runs this sequence against
`script/config/chains.json`. On chains whose gas token has an ERC-20 twin (Arc: native USDC and
`0x3600…0000` are one balance) never initialize a native-currency pool; pair the ERC-20 USDC with a
normal ERC-20 asset.

See also [`price-key-crossing.md`](price-key-crossing.md) for how truncated price keys decide
whether two orders cross, and [mainnet readiness](../MAINNET_READINESS.md) for the release gate.
