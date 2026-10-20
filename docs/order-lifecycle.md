# Order lifecycle and priority bids

Current V2 behavior, checked against the contract source. See also [contract call sequences](contract-call-sequences.md) and the [V2 README](../README.md).

## Order lifecycle

These diagrams describe the current V2 source, not a deployment or mainnet-readiness guarantee. Book matching ranks the best opposing price first; the pool's ordering mode breaks ties at that price. Private fills and explicit LP retries target a specific order and do not enforce the book's global priority queue.

```mermaid
flowchart TD
    A["Submit order: input amount, minimum output, USDC bid"] --> B{"Pool ordering mode"}
    B -- "FIFO" --> C["Require zero bid"]
    B -- "Priority bid" --> D["Require at least 0.10 USDC"]
    C --> E["Validate order and executor; escrow input and bid"]
    D --> E
    E --> F["Match best opposing prices first; up to 8 pairs"]
    F --> G["Same-price ties: FIFO or highest remaining bid; equal bids use FIFO"]
    G --> H["Settle executable crossing pairs; reduce orders and settle bid shares"]
    H --> I{"Incoming order still open?"}
    I -- "No" --> Z["Order closed; return unused input if any"]
    I -- "Yes" --> J["Try remaining input against pool liquidity"]
    J --> K{"Full remaining input consumed and minimum output met?"}
    K -- "Yes" --> L["Settle pool fill; 30 bps LP fee; settle remaining bid"]
    L --> Z
    K -- "No / attempt reverts" --> M["Roll back LP attempt only; keep remaining order open"]
    M -- "New crossing order or Router.matchBook" --> N["Bounded book matching; partial fills can remain open"]
    N -- "Remainder" --> M
    N -- "Input exhausted or minimum satisfied" --> Z
    M -- "Router.fillFromPoolLiquidity" --> J
    M -- "Private filler chooses order" --> O["Check live minimum plus protocol fee against filler maxPrice"]
    O --> P["Filler funds output; settle full remainder and bid; close order"]
    P --> Z
    M -- "Maker reprices" --> Q["Update minimum; re-enter book with fresh time priority"]
    Q --> M
    M -- "Authorized cancellation" --> R["Return remaining input; settle remaining bid; close order"]
    R --> Z
```

If no executable crossing pair exists, the initial matching pass leaves the order unchanged before the LP attempt. `Router.matchBook` accepts a bound of 1–8 pairs and does not itself retry LP liquidity. An LP retry does not require the order to be first in the book. Private fills require a maker-authorized executor (normally the Router); the filler supplies the live minimum plus the protocol fee in the same transaction. That protocol fee is separate from the LP fee on pool-liquidity fills. Native proceeds and refunds are redeemable claims rather than direct ETH transfers.

Sources: [Router](../src/Router.sol), [AsyncSwap](../src/AsyncSwap.sol), [AsyncMatching](../src/libraries/AsyncMatching.sol), and [AsyncFiller](../src/libraries/AsyncFiller.sol).

## Priority-bid settlement

Priority bids are escrowed in USDC and are **non-refundable**. They rank same-price orders within the book; they do not purchase block inclusion or transaction ordering from the chain.

```mermaid
flowchart TD
    A["Escrow USDC bid as PoolManager claims"] --> B{"Order event"}
    B -- "Book match" --> C["Settle proportional bid share for each order's consumed input"]
    C --> D{"Order has remaining input and minimum output?"}
    D -- "Yes" --> E["Keep unspent bid escrowed; update remaining order and rank"]
    E --> B
    D -- "No" --> F["Settle all remaining bid; return unused input; close order"]
    B -- "Successful LP or private fill" --> F
    B -- "Authorized cancellation" --> F
    B -- "Reprice" --> E
    C --> G{"Bid amount to settle is nonzero?"}
    F --> G
    G -- "No" --> H["No bid transfer"]
    G -- "Yes" --> I{"Active liquidity at current tick?"}
    I -- "Yes" --> J["PoolManager.donate to currently in-range LPs"]
    I -- "No" --> K["Transfer bid claims to protocol FeeVault"]
    J --> L["Commit with the order operation in the same unlock"]
    K --> L
    H --> L
    L -. "Any later revert" .-> M["Roll back operation and bid settlement together"]
```

For each book match, the settled share is `floor(remainingBid * inputUsed / remainingInputBeforeFill)`. If the order terminates, any residual bid is settled too; it is never returned to the maker. A partial fill can leave a bid below the creation minimum. Its remaining bid determines its new same-price rank. If the remaining price key changes, it also receives a fresh sequence number. Maker repricing always assigns fresh time priority without refunding the bid.

Donations go to LPs active at the tick when `donate` executes, which need not be every position traversed during a pool swap. A failed LP self-call rolls back that attempt, including its fee and bid changes, while preserving prior successful book matches in the surrounding transaction. A revert of the surrounding transaction rolls everything back.

Sources: [`_reduceAfterMatch` and `_settleMatchedPriorityFee`](../src/libraries/AsyncMatching.sol), [`settlePriorityFee`, `fill`, and `cancel`](../src/libraries/AsyncFiller.sol). The [original chat diagrams](historical-matching-diagrams.md) are retained as historical references.

