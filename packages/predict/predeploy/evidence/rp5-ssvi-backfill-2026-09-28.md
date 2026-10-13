# Block Scholes SSVI Backfill Against Predict's SVI Envelope

**Item:** RP-5 (sigma floor and `a` cap), P-33, P-35, P-36, and P-37 · **Instrument:** DuckDB over the provider's SSVI and current-style SVI backfills, plus a Python integer emulation of `pricing.move` · **Date:** 2026-09-28

## What Was Measured

Block Scholes shared an SSVI params backfill ahead of moving the live feed to SSVI:
`v2composite_svi_params_SSVI_B_BTC_20260201_20260630.parquet`, BTC, one row per
20-second publication from 2026-02-01 to 2026-06-30, each row a JSON array of one
raw-SVI tuple (`svi_a`, `svi_b`, `svi_rho`, `svi_m`, `svi_sigma`) plus spot and
forward per listed expiry. The file is provider-shared and not in the repository.
The questions were how many slices the pricing-safe envelope rejects, whether
lowering the sigma floor alone is safe for the fixed-point smile root, and how
much Predict's 1e9 input scale moves the short-end digitals.

## Method

- Flatten with DuckDB: `unnest(json_transform(params, ...))`, one row per slice,
  `tte_s` = expiry minus publication time in seconds.
- Convert each float to Predict's 1e9 fixed point with round-to-nearest.
- Emulate the load gate exactly as `pricing.move` computes it:
  `mul_down(b, mul_down(sigma, sqrt_down(1e9 - mul_down(rho, rho))))` against `a`.
- Emulate the former smile root (`sqrt_down(floor(x^2/1e9) + floor(sigma^2/1e9))`)
  and the exact one (`isqrt(x^2 + sigma^2)`) through total variance and `w'`, then
  compare each against the true digital from Python `math`; `ln`, `normal_cdf`,
  and `normal_pdf` are evaluated in float so only the root path differs.
- Quantization: the true digital on the float parameters against the true digital
  on the same parameters rounded to 1e9, at `k = +-sqrt(w_min)`.
- Samples are drawn after filtering to the stated tenor range (`select * from
  (... where ...) using sample N rows`).

## Results

| Measurement | Value |
| --- | --- |
| Slices | 6,515,475 |
| `sigma < 1e-3`, slices at most 60 s from expiry | 83.2% |
| `sigma < 1e-3`, slices 60–300 s out | 55.3% |
| `sigma < 1e-3`, slices 300–3,600 s out | 12.1% |
| Smallest `sigma` | 4.74e-5 (a slice 20 s out) |
| Slices below 1e-5 | 0 |
| Rejected by the 1e-3 floor | 1,615,617 |
| Rejected by the 1e-5 floor or the minimum-variance gate | 0 |
| Slices with negative `a` | 25,641 in float, 25,563 after rounding to 1e9 (1,757 of 648,000 one-minute slices, 0.27%, in float) |
| Smallest gate margin (rounded minimum increment minus `abs(a)`) | 1 raw unit (2026-04-04 01:22:40, expiry 01:23:00) |
| Former root, worst at-the-forward miss, one-minute slices | 562,528 units (0.111% relative) |
| Former root, worst miss at `k = +-sqrt(w_min)`, all one-minute slices | 49.0% relative (true 0.0871, former root 0.0445) |
| Exact root, worst miss at the forward, the vertex, and `k = +-sqrt(w_min), +-2 sqrt(w_min)`, 40,000-slice samples per tenor range | 1.5e-5 relative |
| Former root on slices the 1e-3 floor admitted (`sigma >= 1e-3`), worst miss, 40,000 one-minute slices | 0.15% relative |
| 1e9 input rounding moves the digital by more than 0.1% (20,000-slice samples, two strikes each) | 39.1% of slices 20 s out, 19.2% of 20–60 s, 4.5% of 60–300 s |
| 1e9 input rounding, worst relative move, slices 20 s out | 4.8% |
| 1e9 input rounding on the negative-`a` slice above, $1 range (66,857, 66,858] | 20.10% true, 21.44% on the rounded inputs |
| Slices satisfying the SSVI identities (`a = b sigma sqrt(1 - rho^2)`, `m = -rho sigma / sqrt(1 - rho^2)`, relative tolerance 1e-6) | 4,081,858 (62.65%) |
| Non-SSVI slices | every slice over one day out; 15.5% of slices within a day: 98% of within-day slices published in the 01:00 UTC hour, and 11.9% of those published outside it (552,232 slices, none with negative `a`) |
| Negative-`a` slices outside the 01:00 UTC hour, or satisfying the SSVI identities | 0 |
| Largest wing slope `b (1 + abs(rho))` | 0.39 (Lee's bound is 2) |

Block Scholes quoted 30% at five minutes and under 1% at one hour; those are
single tenors (exactly 300 s: 29.2%; exactly 3,600 s: 0.61%), where this record
reports ranges.

## Current-Style SVI Backfill

The live feed stays on its current, non-SSVI style until after launch, so the same
checks ran over Block Scholes' current-style backfill for the same period
(`v2composite_svi_params_1m20s_BTC_20260201-20260630.parquet`, 6,515,475 slices).

| Measurement | Value |
| --- | --- |
| Smallest `sigma` | exactly 1e-3, the former floor |
| Slices with negative `a` | 0 |
| Rejected by the former envelope / by the relaxed one | 0 / 0 |
| Exact root against former root, every tenth previously admitted slice, six strikes each | worst 0.062% relative; none above 0.1% |

## Roll-Down Against the Provider's Next Slice

For one expiry, the slice published `t0` seconds out, rolled down to `t1`, is
compared with the slice the provider published at `t1`: the mean absolute
difference in `UP` over `k` in `+-3 sqrt(w_min)` (25 points), 8,000 expiries per
pair. SSVI slices only; the SSVI roll scales `a` by `lambda = t1 / t0` and `b`, `m`,
and `sigma` by `sqrt(lambda)`, which the provider's `phi = eta theta^(-1/2)` implies.

| `t0 -> t1` | Predict's roll (`a`, `b` by `lambda`), mean | SSVI roll, mean | No roll, median |
| --- | --- | --- | --- |
| 40 -> 20 s | 0.68 pp | 0.01 pp | 4.4 pp |
| 60 -> 20 s | 0.95 pp | 0.02 pp | 7.4 pp |
| 120 -> 20 s | 1.27 pp | 0.23 pp | 12.8 pp |
| 60 -> 40 s | 0.43 pp | 0.01 pp | 2.5 pp |
| 300 -> 240 s | 0.34 pp | 0.23 pp | 1.3 pp |

On the current-style backfill Predict's roll is the better one: 0.12–0.22 pp mean
against 0.13–0.23 pp for the SSVI roll.

## Tail Ripple

A bit-exact emulation of `up_price` over every whole-dollar strike, from the
forward outward until the digital reaches 0 or 1, on 160 newly admitted slices
(60 at 20 s, 60 at 20–60 s, 40 at 1–5 min): every slice has at least one strike
where the next dollar's `UP` is higher, and every such rise is exactly one raw
unit (P-35). On the current-style feed the same emulation finds it on 8 of 20
sampled slices one to five minutes out and on none of 20 one-minute slices, again
always one raw unit: the ripple predates DBU-849 and does not depend on the root.

## Conclusions

- A 1e-5 floor admits every slice in the backfill; the 1e-3 floor rejected a
  quarter of them, most within five minutes of expiry.
- Lowering the floor alone is not safe: the former 1e9 root misprices admitted
  one-minute slices by up to 49% relative off the forward. The exact 1e18 root's
  worst miss over the 40,000-slice samples is 1.5e-5 relative.
- Only the analytical minimum total variance constrains `a` in practice: every
  negative-`a` slice passes it, by as little as one raw unit.
- The feed's 1e9 scale is itself a material error source on the final 20-second
  slices, where `a` is a few raw units (P-33).
- The relaxed envelope is compatible with the current-style feed: it rejects
  nothing there, and the exact root moves its prices by at most 0.062%.
- Predict's linear roll-down fits the current-style feed and misfits SSVI by
  0.3–1.3 pp on average (P-36).
- Only 62.65% of the SSVI backfill is SSVI; the 01:00 UTC regime carries every
  negative `a` (P-37).
