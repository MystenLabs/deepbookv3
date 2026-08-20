# Inventory-Charge Calibration - 2026-08-20

**Item:** RP-29 (rate and window calibration; DBU-732) · **Instrument:** replay over Block Scholes v2composite BTC, Feb 1 - Jun 30 2026 (12.96M seconds of 1s spot, SVI params at 20s) · **Date:** 2026-08-20

Resolves: what rates should `inventory_skew_rate`, `inventory_impact_max_rate` and `skew_window_fraction` start at, given both mechanisms run together.

Status: measured finding. Supersedes the synthetic-simulation figures the mechanism was designed against.

## Result

Recommended `r_occ = 0.10%`, `r_skew = 0.25%`, `f = 0.15`. At 50% peak utilisation under two-sided flow, against a realised ordinary fee of 76-83 bps:

| Component | mean | p95 |
| --- | --- | --- |
| occupancy charge | 1.9 bps | 4.6 bps |
| skew charge | 7.3 bps | 12.2 bps |
| skew rebate | 6.9 bps | 12.5 bps (bound) |
| total inventory, gross | 11.8% of the ordinary fee | |
| total inventory, net of rebates | 4.5% of the ordinary fee | |

Steering, measured as the cost spread between an up-digital and a down-digital of equal probability (so the ordinary fee is identical and only shape differs):

| `r_skew` | spread | as % of ordinary fee | probes above 2 bps |
| --- | --- | --- | --- |
| 0.13% | 7.6-11.7 bps | 5.4-11.7% | 80-100% |
| 0.25% | 10.5-22.5 bps | 10.5-22.5% | 90-100% |
| 0.40% | 16.7-35.9 bps | 16.8-35.9% | 93-100% |

Occupancy discriminates only about 2 bps at `r_occ = 0.10%`, and that residual is a level effect rather than a shape effect.

## The window is nearly free as a fee lever

Raising `f` from 0.10 to 0.20 moves the mean skew charge by 1.03-1.10x for digital flow and 0.84x for bounded-range flow - not the `1/sqrt(N)` the design assumed. A one-sided digital extends to the ladder's end, so the fraction of the window it covers does not change when the window widens; only bounded ranges of fixed price width shrink relative to it. `f` should therefore be chosen on the escape criterion, not the fee level.

Frozen-window escape - spot leaving the reference-centred window during a market's life, after which the statistic decays with no way to re-centre:

| cadence | f=0.10 all / Feb | f=0.15 all / Feb | f=0.20 all / Feb |
| --- | --- | --- | --- |
| 5m | 1.67% / 4.25% | 0.44% / 1.33% | 0.16% / 0.50% |
| 1h | 1.70% / 4.17% | 0.36% / 1.19% | 0.11% / 0.30% |
| 1d | 1.34% / 7.14% | 0.00% / 0.00% | 0.00% / 0.00% |

## What the charge cannot do

Pool P&L over the period is statistically indistinguishable from zero (|t| <= 3.2 across 18 configurations), so fee revenue is the entire expected return. In the worst 5% of markets the whole fee stack covers 2-15% of the loss and the inventory component covers 0.2%. Tail losses are funded by wins on other markets. The charge is defensible as a steering signal, not as an actuarial premium - though markets in the top quintile of terminal deviation do carry 1.3-2.9x the P&L standard deviation of the bottom quintile, so the statistic does track the risk it prices.

Net inventory revenue is `r_occ * g(L_final) + r_skew * sigma_final`, path-independent and verified to 3.6e-15 relative. Turnover therefore generates ordinary fee but no inventory revenue: a 2x-turnover regime collects 1.2% of its fee stack from inventory where a quarter-turnover regime collects 8.7%.

## Bounds

The maximum rebate `r_skew * quantity / 2` is attained, not merely approached - the observed minimum of `delta_sigma / quantity` is exactly -0.5. At `r_skew = 0.25%` that is 12.5 bps against the 50 bps fee floor, a 4.0x margin, so the pool keeps at least 37.5 bps on any trade however perfectly it flattens the book.

## Tick size gates the mechanism

`half_width = mul_down(f * sqrt(P/day), reference_tick)`, so a coarse grid floors it to zero. At `f = 0.10` on a 5-minute cadence the window is 471 ticks at a $1 tick size, 47 at $10, 4 at $100, and inert above roughly $470; on a 1-minute cadence the collapse threshold is about $210. BTC wants `tick_size` at or below $10 on every enabled cadence.

## Occupancy is not tenor-scaled

`Phi` is a per-market charge that does not scale with the market's life, so the implied capital rental rate is about 288x higher at a 5-minute cadence than at a daily one - roughly 6.7% per day against 9% per year. `inventory_impact_max_rate` is global, so the per-cadence lever is `max_expiry_allocation`.

## Method and caveats

Flow is exogenous - traders do not re-route in response to the charge - which is what makes the charges linear in rate. Six flow regimes were run (balanced, moderate, directional, range-heavy, sparse, churn) across 5m/1h/1d cadences, 592k trades over 17k markets, contracts priced off the SVI surface to within 7.5e-8 of the on-chain pricer. Charge levels are flat to within 5% across all five months despite a 16x swing in window-escape rate, because the window scales with `sqrt(P/day)` and the deviation is homogeneous in payout.

The most flow-sensitive result is the `(f, r_skew)` interaction, which ranges 0.84x-1.10x depending entirely on the digital-versus-bounded-range mix; range-dominated flow would want `r_skew = 0.28%` at `f = 0.15` to hold the same level. Mean skew charge at `r_skew = 0.25%` brackets 3.5-8.5 bps across the regimes.
