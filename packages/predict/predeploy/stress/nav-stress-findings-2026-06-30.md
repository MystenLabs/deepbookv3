# NAV Stress Findings - 2026-06-30

This finding measures how large one leveraged book can get before the pool flush
OOGs while valuing NAV.

Status: measured finding. It confirms the flush joint-budget gap.

## Method

The `nav-stress` harness strategy builds one persisting one-hour market, mints
many low-leverage held orders into that market, and lets the keeper flush
periodically. Each flush values the whole active set in one PTB.

The run used a high transaction gas budget so the binding failure would be the
Sui computation cap, not an artificial gas budget.

## Headline

A single-market flush OOGed around 4,580 leveraged orders, below the current
5,000 per-market leveraged-order cap.

The last successful flush near the wall used about 98% of the 5M computation
unit cap. After OOG, settlement/flush progress stalled because the flush could
not complete valuation.

## Scaling

Observed scaling was close to linear:

```text
flush_computation ~= fixed_cost + 1,086,391 MIST * leveraged_order_count
```

R-squared was about 0.998 over the measured flush points up to the last
successful run.

The run rode the cheap branch of the pricing math. Prior fuzzing indicates a
moderate-moneyness / expensive-branch case can reduce the safe total leveraged
order budget materially.

## Interpretation

The current independent caps are not sufficient. The flush binds on the sum of
all active markets:

```text
sum_markets(value_expiry_cost(market)) + finish_flush_drain_cost
```

The safe cap is therefore a pool-total budget, not a per-market budget in
isolation.

## Required Follow-Up

- Run `nav-stress-atm` long enough to hit the expensive branch boundary.
- Run `nav-stress-multi` to confirm pool-total cost across multiple markets.
- Set caps or a resumable-flush design against a joint budget with safety margin.
