# UP price inverts on valid surfaces — Move measurement, 2026-09-04

**Item:** RP-15 · **Instrument:** Move unit probe over the committed reference surfaces (`pricing_reference_data`) · **Date:** 2026-09-04; re-run and reachability re-derived 2026-09-29

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
pairs whose UP price rises. Inside these windows every inversion sits at the upper
edge of the deep-ITM plateau, where the price is about `1 - 5e-9`.

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

The 2026-09-29 re-run on `main` at `84cf16d3` reproduced every row exactly. It also
recorded the largest rise: one raw unit in every window, and the same measured
against the running minimum the walk compares with. Wider $10 sweeps found the mirror
plateau in the OTM tail inverting the same way: scenario 1 inverts 15 times between
$55,000 and $90,000 (10 in its table window; the first above the forward is $81,990,
20 -> 21), and scenario 2 inverts 10 times between $60,000 and $90,000 (7 in its
window; above the forward at $79,680, $79,720 and $79,960, UP 5 to 15 raw units).

## Reachability

The strike whose UP price inverts sits on a tail plateau, 11% to 27% below spot on the
deep-ITM side of these surfaces, where the boundary's own UP price lies outside the
1%-99% entry band. Mint admission applies that band to each finite boundary as well as
to the range (#1304, DBU-811), so no mint can place a boundary there directly: on
scenario 0 the range `($55,240, $76,000]` prices at 0.553, inside the band, and is
still rejected on its 0.999999995 lower leg
(`pool_valuation_flow_tests::the_entry_band_keeps_a_plateau_boundary_out_of_a_mint`).
When this record was first taken the band bounded only the range price, and two mints
at the plateau were enough; #1304 closed that path before this change merged.

The market carries admitted boundaries onto the plateau instead. A boundary's UP price
moves with spot and with the variance left to expiry, so a boundary admitted inside the
band sweeps through the plateau as the market ages.
`pool_valuation_flow_tests::a_fixed_point_dust_inversion_does_not_stall_the_flush`
carries the end-to-end path. Two ranges `($66,170, $76,000]` and `($66,180, $76,000]`
are admitted on the $10 grid against scenario 0's smile at 16x its remaining variance,
with lower legs at 0.931, the upper leg at 0.523, and both ranges at 0.409. The market
then reprices to committed scenario 2, the same market 18 hours after scenario 0 with
spot 2% lower, where the two lower boundaries price at 999,999,994 -> 999,999,995. On
that book the strict guard aborts `current_nav` and `value_expiry` with
`ENonMonotonePrice`. Under `price_monotonicity_tolerance` both proceed, and the live NAV
equals free cash less the independent per-order sum. No adversary is needed: any book
whose boundaries end up deep in the money near expiry can reach an inverting pair.

## What it does not measure

The probe fixes each surface at the reference fixture's expiry, so it does not sweep
time to expiry, and it says nothing about how the plateau edge moves as a market ages.
The aging regression above is one path, not a sweep: it does not measure how often a
real book lands on an inverting pair.
It also does not measure the external half of RP-15: no sampled Block Scholes surface
has violated butterfly freedom, and that half remains unobserved.
