# UP price inverts on valid surfaces — Move measurement, 2026-09-04

**Item:** RP-15 · **Instrument:** Move unit probe over the committed reference surfaces (`pricing_reference_data`) · **Date:** 2026-09-04

Status: reproduced, deterministic, no provider defect involved. The pricer's own
fixed point makes `up_price` rise across ascending strikes on surfaces that are valid
and butterfly-free, which the pre-existing strict guard in `strike_payout_tree`
treated as a surface defect and aborted on.

## Where it comes from

`compute_up_price` returns `floor(N(d2))` minus the floored skew correction
`floor(phi(d2) * w' / (2 * sqrt(w)))`. Deep in the tail `N(d2)` sits on a plateau
while the correction still steps, so the difference of the two floored terms rises by
raw units across adjacent strikes. Nothing about the surface is inverted; only the
evaluation is.

## Measurement

A probe walked ascending strike grids on each committed scenario and counted adjacent
pairs whose UP price rises. Every inversion sits at the upper edge of the deep-ITM
plateau, where the price is about `1 - 5e-9`.

| Scenario | Grid | Window | Inverting pairs |
| --- | --- | --- | --- |
| 0 | $10 | $50,000-$60,000 | 24 (first $55,240 -> $55,250, 999,999,995 -> 999,999,996) |
| 0 | $100 | $55,200-$69,000 | 1 ($55,200 -> $55,300) |
| 0 | $1 | $55,200-$56,200 | 7 |
| 0 | $500 | $55,200-$69,000 | 0 |
| 1 | $10 | $62,800-$71,000 | 10 |
| 1 | $100 | $62,800-$71,000 | 0 |
| 2 | $10 | $66,100-$71,300 | 7 |
| 3 | $10 / $1 | $73,100-$73,400 | 0 |

Grid coarseness is the only attenuator measured: the same surface that gives 24 pairs
on a $10 grid gives one on a $100 grid and none on a $500 grid. Scenario 3 is the
near-degenerate low-variance surface, whose plateau edge is only ~$200 wide.

## Reachability

The strike whose UP price inverts is deep in the money — 11% to 27% below spot on
these surfaces — so the ORDER that puts a boundary there is a wide range priced near
0.5, not an exotic one. `assert_admitted_mint_ticks` constrains the boundary to the
admission grid and nothing else, and `max_probability` bounds the range price rather
than the boundary. Two mints of a couple of dollars each are enough.

`pool_valuation_flow_tests::a_fixed_point_dust_inversion_does_not_stall_the_flush`
carries the end-to-end path: two grid-admitted mints quoted between 0.4 and 0.6 on
scenario 0, then `start_pool_valuation` -> snapshot -> seal -> `value_expiry`. Against
the strict guard that sequence aborts `ENonMonotonePrice`, and `current_nav` aborts on
the same book; under `price_monotonicity_tolerance` both proceed and the walk equals
the independent per-order sum.

## What it does not measure

The probe fixes each surface at the reference fixture's expiry, so it does not sweep
time to expiry, and it says nothing about how the plateau edge moves as a market ages.
It also does not measure the external half of RP-15: no sampled Block Scholes surface
has violated butterfly freedom, and that half remains unobserved.
