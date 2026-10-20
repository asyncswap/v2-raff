# Price keys and crossing

## Price keys

Every resting order is indexed on its pool's book by a `uint128` price key computed in
`AsyncFiller._priceKey`:

| Side | Key |
|---|---|
| Buy (`isBuy`, maker escrows the numeraire) | `floor(amountIn * 1e18 / amountOutMin)` |
| Sell | `floor(amountOutMin * 1e18 / amountIn)` |

A ratio that rounds to zero maps to `1`, and a ratio above `type(uint128).max` saturates at the
maximum. The key is a truncated WAD ratio, so two orders with different exact prices can share a key.
Keys order the radix tree; they do not by themselves decide whether two orders trade.

## Crossing rule

`AsyncMatching._crosses(buyKey, sellKey, buy, sell)` decides whether a buy and a sell can trade:

- `buyKey > sellKey` is a cross and `buyKey < sellKey` is not. Truncation is monotone, so a strict
  ordering of keys always reflects a strict ordering of exact prices.
- Equal keys are decided at full precision:

```
cross  <=>  buyIn / buyOut >= sellOut / sellIn
       <=>  buyIn * sellIn >= sellOut * buyOut
       <=>  floor(buyIn * sellIn / sellOut) >= buyOut      (sellOut and buyOut are nonzero)
```

implemented as `Math.mulDiv(buy.amountIn, sell.amountIn, sell.amountOutMin) >= buy.amountOutMin`.
Orders cannot be created or updated with a zero minimum, so the divisor is never zero. With equal
keys the quotient is on the order of `buyOut`, so the division cannot overflow for escrowable
amounts.

An exact tie (`buyIn * sellIn == sellOut * buyOut`) counts as a cross and executes.

## Consequences

- An equal-key pair that does not cross rests on the book. `matchIncoming` and `matchBook` stop at
  that pair only when the exact test says it does not cross, and a later order with a strictly
  better key still matches past it.
- Every genuine cross, including the tie, produces a non-zero match in `_matchAmounts` that pays
  each maker at least their signed minimum for the input consumed. This was checked exhaustively
  for small amounts and on randomized large near-tie pairs.
- Direct order-to-order matches swap the two escrowed inputs with no protocol fee, so rounding never
  moves value to or from the protocol.

Example of equal keys without a cross:

| Order | `amountIn` | `amountOutMin` | Key |
|---|---:|---:|---|
| Buy | `3e18 + 1` | `1e18` | `3000000000000000001` |
| Sell | `1e18 - 1` | `3e18 - 2` | `3000000000000000001` |

`buyIn * sellIn` is one unit below `sellOut * buyOut`, so the pair does not cross and rests.

## Tests

`test/security/PriceKeyCrossing.t.sol`:

- `test_equalKeyNonCrossingPairDoesNotBlockMatching`
- `test_matchBookMakesNoFalseMatch`
- `test_exactTieExecutes`

## Saturation

Distinct extreme ratios collapse onto the boundary keys `1` and `type(uint128).max`. The exact
equal-key test still decides crossing correctly for them, but priority among different saturated
prices follows submission order rather than price.
