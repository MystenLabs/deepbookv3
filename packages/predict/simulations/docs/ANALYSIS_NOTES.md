# Predict Simulation Analysis Notes

This document captures **economic** observations from local simulation runs. It is
not a runner manual; operational details live in `README.md`. For
**gas/performance** experiments (contract changes measured for gas, run-to-run
comparisons, perf hypotheses), see `GAS_EXPERIMENTS.md`.

## Directional Accumulation

The current random-flow generator can create a directionally imbalanced live
book even though each mint attempt samples `UP` or `DN` randomly. In the
`may29-1738` Python-only run, the book accumulated more DN quantity before the
large BTC move down near hour 19-20:

```text
Active open DN / UP quantity ratio:

hour 16: 1.35x
hour 17: 1.41x
hour 18: 1.42x
hour 19: 1.47x
hour 20: 1.64x
```

Hourly accepted mint flow was already DN-heavy before the move:

```text
Accepted mint DN / UP quantity ratio:

hour 15: 2.24x
hour 16: 2.07x
hour 17: 1.55x
hour 18: 2.00x
hour 19: 2.32x
```

This matters because the vault is short the contracts it sells. When BTC fell,
the DN contracts became more valuable and the vault's live liability increased
faster than accumulated fees.

## Why Random Direction Did Not Produce A Paired Book

Random direction count is not the same as balanced economic exposure.

-   Accepted mints are filtered. The generator retries failed rows, and failed
    rows can depend on side, strike, fee bounds, leverage tier, liquidation entry
    guard, terminal LTV guard, and available manager cash.
-   Spend-based sizing amplifies probability differences. For the same target
    spend, cheaper contracts receive more quantity.
-   Redeems and liquidations are path-dependent. The final open book is the
    surviving book, not the original minted book.

In `may29-1738`, accepted DN mints were cheaper on average:

```text
Minted average entry probability:
UP: 43.99c
DN: 35.50c

Minted cost per quantity:
UP: 0.0566 DUSDC
DN: 0.0447 DUSDC
```

So a similar cash budget bought more DN quantity. The largest quantity bucket
was very cheap contracts:

```text
0-10c accepted mint bucket:
UP quantity: 1,522,145
DN quantity: 2,177,942
```

That cheap-contract bucket dominated total quantity, so small accepted-flow
skews became large exposure skews.

## PnL Interpretation

`chart_market_overview.png` uses live pre-terminal vault PnL:

```text
active expiry value - pending protocol profit exclusion - expiry funding basis
```

Fees and realized cash movements are included, but the chart is still a live
mark. It can fall sharply when liability reprices faster than fees accumulate.

In the old split-balance `may29-1738` run, the hour 19-20 drop was mostly
liability repricing:

```text
hour 19:
spot: 74177.91
position liability: 65031.68 DUSDC
expiry value above funding basis: 75859.11 DUSDC
LP MTM PnL: 10827.42 DUSDC

hour 20:
spot: 73147.74
position liability: 158460.90 DUSDC
expiry value above funding basis: 79396.73 DUSDC
LP MTM PnL: -79064.17 DUSDC
```

The vault collected more fees, but live liability increased by roughly 93k DUSDC
over that hour.

## What This Does And Does Not Prove

This is an important discovery, but it is not enough to conclude that a trader
can mechanically win against the vault.

What this run does show:

-   Independent random mint flow can leave the vault with material directional
    exposure.
-   Spend-sized orders can make cheap contracts dominate quantity exposure.
-   A realized market move can turn that accumulated directional exposure into a
    large live MTM loss even while fees increase.

What this run does not prove:

-   That DN contracts are systematically underpriced.
-   That a directional buyer has positive expected value after fees.
-   That this behavior survives across many independent market paths, expiries,
    volatility regimes, and flow models.

The right interpretation is path-dependent risk: the vault may earn fees on
average, but it can accumulate one-sided exposure before a market move.

## Liquidation Priority Encoding

The bounded liquidation scan sorts active leveraged orders by packed `order_id`.
An offline priority search over the `may29-1738` long-run backlog samples found
that a quantity-first packed layout captured more liquidatable value than the
previous leverage-first layout. The current protocol layout is
`quantity_lots desc > floor_shares desc > opened_at_ms asc >
lower_boundary_index asc > higher_boundary_index asc > sequence asc`.

The useful interpretation is that order size was the strongest immutable proxy
for value-at-risk in that run. Higher leverage still matters, but using it as the
primary field spent scan budget on smaller orders too often. Live liquidatable
value remains the upper-bound oracle ordering, so the static `order_id` layout is
only a gas-cheap proxy, not an exact liquidation-risk ranking.

## Liquidatable Backlog: Coverage vs Severity

"Standing liquidatable value we have not caught yet" is one quantity
(`liquidation.liquidatable_value`, the summed floor/debt of leveraged orders that
currently breach the LTV trigger), but it answers two different questions, so it
lives in two charts with two different denominators. Do not collapse them back
into one ratio.

-   **Coverage / is the engine keeping pace?** `chart_liquidation_coverage.py`,
    "Backlog Pressure" panel. Numerator `liquidatable_value` over denominator
    `liquidation.leveraged_floor_value` (summed floor of **all** leveraged orders,
    breaching or not). Reads as "X% of the leveraged debt book is liquidatable but
    uncaught." Both sides are floor/debt and leveraged-only, so the ratio is a true
    bounded subset (numerator is always a subset of the denominator) and is not
    diluted by 1x volume.

-   **Severity / can the vault absorb it?** `chart_vault_risk_profile.py`,
    "Liquidatable Backlog On Capital" panel. Same numerator over
    `risk.allocated_capital` (emitted as `risk.liquidatable_value_over_allocated`).
    Reads as "uncaught liquidatable exposure is Y% of the capital backstopping it,"
    matching the other capital-normalized panels in that file.

The earlier version divided both panels by `valuation.position_liability` (notional
of all positions, leveraged plus 1x). That mixed a debt numerator with a notional
denominator and diluted with un-liquidatable 1x volume, so neither panel cleanly
answered its own question. `risk.liquidatable_value_over_liability` is still
emitted for any consumer that wants the liability-normalized view, but no chart
uses it.

## Charts To Add

The next useful local charts should focus on exposure formation, not only final
PnL:

1. **BTC Price With Open Directional Quantity**
   Plot BTC spot with active UP and DN quantity over time. This shows whether
   the vault entered a move with directional imbalance.

2. **Hourly Accepted Mint Flow By Direction**
   Plot accepted UP/DN quantity per hour plus DN/UP accepted quantity ratio. This
   shows whether the generated order flow is accumulating one side before market
   stress.

3. **Open Book Cost Basis By Direction**
   Plot active UP/DN contribution and floor amount over time. This separates
   cheap high-quantity exposure from actual cash paid by traders.

4. **Directional Liability Attribution**
   If added later, split live position liability by UP and DN. This requires
   extra chart-time recomputation or additional derived fields, but it would
   directly show which side is driving live MTM loss.

## Larger-Scale Work

The local simulation framework is useful for protocol parity, data-shape checks,
and single-window economic diagnostics. It should not be the only tool used to
tune vault risk policy.

For risk-policy decisions, we need larger-scale simulations outside the localnet
harness:

-   many expiry windows
-   many realized BTC paths
-   different volatility and skew regimes
-   different trader flow assumptions
-   separate market-maker, retail directional, and adversarial flow models
-   repeated runs with controlled random seeds
-   directional exposure limits and pricing/fee variants

Key questions for the larger framework:

-   Does independent flow create persistent directional imbalance in expectation?
-   How often does spend-sized random flow generate one-sided open exposure before
    large market moves?
-   Are fees sufficient relative to tail drawdown on expiry funding?
-   Should the protocol charge direction/skew-sensitive fees?
-   Should the vault enforce directional exposure limits, not just aggregate risk
    limits?
-   Should order generation and risk charts track delta-like exposure rather than
    only quantity, contribution, and liability?
