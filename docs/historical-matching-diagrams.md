# V2 matching diagrams recovered from chat

Source: **Add EIP-712 signed orders**, following the question “at what point in the lifecycle is the donate made?”
Chat ID: `01a1275e-f4f8-7cb2-ab57-0ae98261ba4b`.
Turn ID: `01a13c4b-5f5b-74b1-ae40-2431ad85c7b1`.
Recovered October 16, 2026.

These diagrams are copied verbatim from the chat. They are historical designs, not the current protocol specification. Updated diagrams matching the current source are in the [order lifecycle documentation](order-lifecycle.md).

The current [V2 README](../README.md) describes non-refundable priority bids: remaining bids are donated when an order is canceled or terminates, and amounts go to FeeVault when no active liquidity exists. Priority-bid mode also requires a minimum bid of 0.10 USDC. The refund and zero-bid paths below therefore do not describe current V2 behavior. The first diagram also contains an original cancellation-arrow placement that should be reviewed before reuse.

## Initial lifecycle blueprint

```mermaid
flowchart TD
    A["Maker submits order<br/>limit price + optional USDC bid"] --> B["Check pool ordering mode<br/>FIFO or priority-fee"]
    B --> C["Escrow input and bid atomically<br/>bid remains refundable"]
    C --> D["Select best opposing order"]
    D --> E{"Do best prices cross?"}
    E -- "No" --> F["Order rests in book"]
    E -- "Yes" --> G["Choose maker at best price"]
    G --> H{"Same price?"}
    H -- "No" --> I["Better price wins"]
    H -- "Yes, FIFO mode" --> J["Oldest order wins"]
    H -- "Yes, priority mode" --> K["Highest USDC bid wins<br/>equal bids: FIFO; zero bids: FIFO"]
    I --> L["Attempt bounded match"]
    J --> L
    K --> L
    L --> M{"Fill succeeds?"}
    M -- "No" --> N["Leave orders and bids escrowed<br/>no donation"]
    M -- "Yes" --> O["Settle token amounts"]
    O --> P["Donate the filled share of each bid<br/>to in-range LPs in the same unlock"]
    P --> Q{"Order fully filled?"}
    Q -- "No" --> R["Keep remainder and its unspent bid ranked"]
    Q -- "Yes" --> S["Close order; return any unused escrow"]
    F --> T["Only top eligible order may try pool LP liquidity"]
    T --> U{"Pool fill meets limit?"}
    U -- "No" --> N
    U -- "Yes" --> O
    R --> D
    S --> V["Maker cancels remainder?"]
    V -- "Yes" --> W["Return remaining input and bid"]
```

## Follow-up implementation diagram

```mermaid
flowchart TD
    A[Maker submits order] --> B[Escrow input and optional USDC bid]
    B --> C[Find best opposing price]
    C --> D{Prices cross?}
    D -- No --> E[Order rests in book]
    D -- Yes --> F[At that price: FIFO or highest bid]
    F --> G[Settle successful fill]
    G --> H{Active liquidity at current tick?}
    H -- Yes --> I[Donate filled share with PoolManager.donate]
    H -- No --> J[Refund filled share]
    I --> K{Order has remainder?}
    J --> K
    K -- Yes --> L[Keep remainder and its bid escrowed]
    K -- No --> M[Refund any unfilled bid]
    E --> N{Canceled?}
    N -- Yes --> O[Refund input and remaining bid]
```

