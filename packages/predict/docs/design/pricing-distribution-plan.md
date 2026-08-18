# Pricing distribution family — build plan (DBU-721)

> **Status:** plan, implementation in flight (DBU-721). This document describes
> the target design and the build sequence. As pieces land, the durable parts
> move into [architecture](./architecture.md), [configuration](./configuration.md),
> [decisions](./decisions.md), and the module docs, and this file tracks what
> remains; it is deleted when the work ships.

## Motivation

Predict quotes a binary market by pushing the SVI implied-variance surface
through the standard normal distribution: the quoted UP probability is
`N(d2) - n(d2) * w'(k) / (2 * sqrt(w))`, the skew-adjusted digital
(see [pricing-and-oracles](../concepts/pricing-and-oracles.md)).

Replay of archived markets against realized outcomes shows short-horizon
returns are not normal: the center is sharper and the tails fatter. Repricing
the same surfaces through a **unit-variance generalized normal** — density
proportional to `exp(-(|x|/alpha)^B)`, with `alpha(B)` fixed so the variance is
exactly 1 — scores better on realized outcomes for shape `B < 2`, and the
improvement grows as expiry approaches: the best-fitting `B` falls as
time-to-expiry shrinks. At `B = 2` the family is exactly the standard normal,
so it strictly contains today's pricing.

The research locked the schedule as a formula with one tunable level:

```
B(tte) = clip(a0 + 0.183 * ln(tte_seconds), 0.4, 2.0)
```

with slope and clip bounds frozen and `a0` the only tunable (research default
0.314; fitted level varies roughly 0.18–0.46 by regime). This plan implements
that formula on-chain: a generated grid of 100 `B` values on `[0.4, 2.0]`
carries the per-shape constants, the formula resolves remaining time-to-expiry
to the nearest grid row at quote time, and `a0` is the admin-tunable
configuration value.

## What changes and what does not

The formula keeps its exact shape; only the distribution changes:

```
price = G_B(d2) - g_B(d2) * w'(k) / (2 * sqrt(w))
```

Deliberately unchanged:

- **The SVI surface and the `d2` definition.** `d2 = -(k + w/2) / sqrt(w)` and
  the roll-down are untouched. The validated change is a quoting rule — push
  the same surface through a different distribution — not a re-derivation of
  the lognormal drift correction (whose defining expectation does not even
  converge for `B <= 1`). Do not "fix" the `-w/2` term to match the new
  distribution.
- **Everything around the two distribution calls** in
  `sources/pricing/pricing.move` (`compute_nd2`): variance assembly, skew
  correction, clamps, the `PriceMemo` monotonicity contract.
- **`B = 2.0` delegates to the existing Cody `normal_cdf` / `normal_pdf`** in
  `packages/fixed_math/sources/math.move`, so the default is bit-identical to
  today's prices and the proven fast path stays in use.

## Where the swap happens

Every price in the protocol flows through one choke point, and the `Pricer` is
rebuilt per transaction, so threading one value through it covers every flow
(quotes, NAV flush, payout-tree walk, liquidation corrections) with
whole-transaction consistency for free:

```
ProtocolConfig.pricing_config        a0 lives here (admin-settable)
        |
pricing::load_live_pricer            resolves B(tte) from the locked formula,
        |                            snaps to the nearest grid row, stamps the
        |                            row into the transaction-local Pricer
Pricer.up_price / range_price
        |
compute_nd2                          two call sites swap:
        |-- normal_cdf(d2)  ->  gen_normal::cdf(row, d2)
        |-- normal_pdf(d2)  ->  gen_normal::pdf(row, d2)
```

Resolution at `load_live_pricer` is one `ln` call plus a clip and a rounded
division:

```
tte_s = max(remaining_ms, 1) scaled to seconds     (1e9 fixed point)
b_raw = a0 + 0.183 * ln(tte_s)                     (ln of sub-second tte is
b     = clip(b_raw, 0.4, 2.0)                       negative; the clip floor
row   = round((b - 0.4) * 99 / 1.6)                 absorbs it)
```

One additional touch point: `variance_sqrt_and_d2` caps `|d2|` at 8, which
encodes a fact about the *normal's* tail (beyond 8 the normal CDF is within one
raw 1e9 unit of 0/1). Fatter-tailed members need larger caps (see the table
below), so the cap becomes per-`B` data owned by the math layer, and the
pricing-side check keeps only a wide universal bound guarding the `u128 -> u64`
narrowing.

## Configuration: one tunable level, `a0`

The formula's slope (0.183) and clip bounds (0.4, 2.0) are frozen constants,
matching the research lock; changing them is deliberately a package upgrade.
The only configuration is the level:

- **Field:** `distribution_a0: Option<u64>` on `PricingConfig`, 1e9-scaled.
  `None` disables the schedule entirely — `B = 2.0` at every TTE, today's
  pricing bit-for-bit — and is both the publish default and the kill switch.
- **Bounds:** `Some(a0)` is validated to `[0.10, 0.80]` at 1e9 scale — the
  fitted regime range (0.18–0.46) with headroom on both sides. `a0` enters the
  formula linearly, so no per-`a0` constants exist and the value is genuinely
  continuous; vetting of candidate levels is replay evidence before the admin
  transaction, not an on-chain enumeration.
- **Setter:** `AdminCap`-gated, version-gated, and guarded by
  `assert_not_valuation_in_progress` like the other pricing setters — a
  distribution change may not land inside a valuation window.
- **Event:** `a0` updates emit a config event carrying the new value, so
  indexers and off-chain mirrors can track the active distribution (pricing
  setters are silent today; this one is not, because it moves every quoted
  price).
- **Scope:** protocol-global. Markets differ only through their remaining TTE.

Tuning semantics worth knowing: `a0` is a pure time-rescaling of the schedule —
raising it by `d` multiplies every grid-row boundary's TTE by `exp(-d / 0.183)`
(a +0.01 nudge slides all boundaries ~5.3% toward shorter TTE). At any fixed
TTE, a nudge of `da0` moves the snapped row by at most
`ceil(da0 / 0.016162)` steps, so a sub-step nudge moves some TTEs by one row
and others not at all, bounded by one grid step of price movement — the same
lumpiness the spread already absorbs (below). Large retunes (many steps)
re-mark every market at the admin transaction and follow the same gating
discipline as enabling the schedule.

## New `fixed_math` atoms, and what is reused

The generalized normal decomposes into machinery the module already has plus
**one** new transcendental:

```
y        = (|x| / alpha)^B  =  exp( B * (ln|x| - ln_alpha) )     existing ln, exp
g_B(x)   = pdf_norm * exp(-y)                                    existing exp
G_B(x)   = 0.5 +/- P(1/B, y) / 2                                 NEW: gammainc
P(s, y) assembly:  series_or_cf(s, y) * exp(-y + s*ln(y) - ln_gamma_s)
```

New atoms:

- **`gammainc_lower_reg(s, y)`** — the regularized lower incomplete gamma, the
  one genuinely new numeric engine. Series branch for `y < s + 1` and a Lentz
  continued fraction otherwise, both at fixed iteration counts, `u128`
  internals — structurally a sibling of the existing `exp` Taylor loop and the
  Cody small/medium split. `s = 1/B` spans 0.5 to 2.5 across the grid (the
  formula's 0.4 clip floor is what keeps the engine domain this small).
- **`gen_normal` module** — a generated constants table of 100 rows, `B`
  uniform on `[0.4, 2.0]` (step `1.6/99 ≈ 0.01616`), each row
  `(s, ln_alpha, ln_gamma_s, pdf_norm, saturation_cap)`, plus the assembly
  functions `cdf`, `pdf`, and `saturation_cap` keyed by row index. Row 99
  (`B = 2.0` exactly) delegates to `normal_cdf` / `normal_pdf`. The table, the
  golden test vectors, and the off-chain replay mirror are all emitted by one
  checked-in Python generator (the `pricing_reference_data` pattern); the five
  hundred constants are never hand-typed.

Reused as-is: `i64` as the signed carrier, `ln`/`exp` as the workhorses (2–4
calls per evaluation), the symmetry fold (compute on `|x|`, reflect by sign),
the tail-saturation slot (the cap becomes data), the internal-`u128` idiom, and
the entire Cody normal as the `B = 2.0` member.

Storing `ln_alpha` rather than `alpha` is what makes the whole grid
representable: at `B = 0.1`, `alpha ~ 2e-13` is zero at 1e9 scale, but
`ln_alpha ~ -29.23` is a perfectly precise `I64`.

## Precision: which parts run at 1e18

The low-`B` members are extremely spiky at the money (see the table), so input
quantization matters more than function accuracy. The plan splits the pipeline
by scale:

- **Already 1e18:** the variance assembly. `PricingSVI` carries rolled `a` and
  `b` at 1e18 and `variance_sqrt_and_d2` works in `u128` precisely because 1e9
  discards short-dated variance.
- **Moves to 1e18:** the `d2` handoff and the `gen_normal` internals. `d2` is
  today narrowed to a 1e9 `I64` at the `normal_cdf` boundary; the new functions
  take it at 1e18 (`u128` magnitude + sign) and evaluate internally at 1e18,
  removing `d2`'s own quantization as an error source at low `B`.
- **Stays 1e9, measured before deciding more:** `k = ln(strike/forward)` and
  `sqrt(w)`. A one-raw-unit error in `k` becomes a `1e-9 / sqrt(w)` error in
  `d2`, which the tall low-`B` densities amplify near the money at short TTE —
  exactly the regime the schedule points low `B` at. Whether the existing 1e9
  `ln` budget is acceptable there is an empirical question the fixed-point
  replay (phase 4) answers per grid value; if it dominates, the contingent atom
  is a 1e18-output `ln` (and if needed `sqrt`) variant, which slots into
  `compute_nd2` without changing the design above.

## The low-`B` landscape (computed, unit variance)

The grid floor of 0.4 keeps the family's numerics tame; the in-domain schedule
stays at `B >= 0.6` and the floor is reached only below ~1.6s of remaining TTE.

| B | pdf(0) | tail mass beyond x = 8 | cap for < 1e-9 truncation |
|-----|--------|------------------------|---------------------------|
| 0.4 | 5.64 | 7.5e-4 | ~86 |
| 0.5 | 2.74 | 4.5e-4 | ~52 |
| 0.6 | 1.71 | 2.4e-4 | ~36 |
| 1.0 | 0.71 | 6.1e-6 | ~15 |
| 1.6 | 0.45 | 2.1e-10 | ~8 |
| 2.0 | 0.40 | 6.2e-16 | ~6 |

Consequences the design carries:

- **Per-`B` saturation caps** (table column), because a fixed cap of 8 silently
  zeroes real probability for `B <= ~1.5`.
- **Documented per-`B` accuracy budgets**, in the `fixed_math` doc style
  (today: CDF within 20 raw units, PDF within 50). Budgets at low `B` include
  the input-sensitivity term above; reference-fixture tolerances are derived
  per grid value and will honestly be wide at the money for spiky members.
- **Valuation liveness is the real risk, not accuracy.** The skew correction is
  `g_B(d2) * w'/(2*sqrt(w))`; with densities in the hundreds, corrections at
  low `B` can exceed the CDF term, clamp prices to 0/1, and produce
  non-monotone price memos — which abort the NAV flush by design
  (`ENonMonotonePriceMemo`). Low-`B` members must prove themselves in
  fixed-point replay before the schedule points at them.

## Grid-step movement (settled: absorbed by the spread)

`B` snaps to the grid, so a market's quotes step when its remaining TTE crosses
a row boundary. Measured on the 100-row grid: the worst single-step price jump
over all strikes is ~0.42c near `B = 0.6` (the 5s operating point), ~0.18c at
`B ≈ 1.06` (60s), and ~0.08c by `B = 1.6`; boundaries are crossed roughly every
`0.088 * tte` (5.3s of wall clock at 60s TTE, 27s at 5 minutes). The grid does
not add movement — it lumps the continuous drift the schedule itself demands
(~0.03c/s at 60s TTE) into one-step quanta. These bounds sit well below the
model error the schedule removes (raw miscalibration up to ~12c at 5–10s;
residual after the fix under ~3c), so the movement is absorbed by spread
sizing: budget roughly half a step of lumpiness — ~0.2c below 15s TTE, ~0.1c
at 60s, negligible above 5 minutes. Sizing lives with the fee/spread
configuration, not in this change.

## Open question: behavior below the 5s validity floor

The research validates 5 seconds to 2 hours; live markets trade through the
final seconds regardless, where the formula rides the 0.4 clip floor. Two
candidate policies differ only below ~5s: follow the formula down to the floor
(current plan), or freeze `B` at its 5s value for smaller TTEs. An empirical
pass over the archive at sub-5s coordinates decides this — pending; if the
archive's spot cadence cannot resolve sub-5s outcomes cleanly, the policy is
chosen on robustness grounds and the replay gates cover the regime reachable
by data.

## Test and evidence plan

- **One generator, three outputs:** Move constants, Move golden-test vectors
  (CDF/PDF grids per `B` against high-precision reference), and the constants
  for the off-chain fixed-point replay mirror — a single source of truth.
- **`fixed_math` tests:** golden sweeps per grid value, symmetry, CDF
  monotonicity, saturation-boundary behavior, `gammainc` engine accuracy over
  the `(s, y)` domain, and bit-equality of the `B = 2.0` member with
  `normal_cdf` / `normal_pdf`.
- **Predict tests:** `a0` bounds validation, formula resolution and grid snap
  (clip edges, sub-second TTE, rounding), config default = current behavior,
  distribution
  actually changing the price, and regenerated `pricing_reference_data`
  fixtures with per-`B` tolerance derivations.
- **Fixed-point replay gates (per grid value, before live enablement):**
  realized-score change, clamp rates, and price-memo monotonicity rates over
  the market archive — the float-domain evidence that motivated this work must
  survive the fixed-point implementation, member by member. The TTE schedule
  itself is backtested the same way.

## Rollout

Testnet deployments are fresh publishes, so the config ships in the package
layout with no migration; `Pricer` is transaction-local and never stored.
Publish defaults to disabled (`a0 = None`, current behavior); a vetted `a0` is
applied by admin transaction after the replay gates pass for the grid rows the
schedule reaches at that level. Landing the field in the config layout before
any mainnet publish exists is deliberate: Sui upgrades freeze struct layouts,
and this avoids ever needing a config-migration path for it.

## Phases

1. **Generator + constants** — the Python generator and the `gen_normal`
   constants module it emits.
2. **`fixed_math` engine** — `gammainc_lower_reg`, the `gen_normal` assembly,
   1e18 input path, tests, per-`B` budgets. The long pole.
3. **Predict plumbing** — `a0` config + setter + event, formula resolution and
   grid snap in `load_live_pricer`, `Pricer` stamping, `compute_nd2` branch,
   per-`B` caps, tests, regenerated fixtures.
4. **Replay gates** — fixed-point mirror runs per reachable grid row and for
   candidate `a0` levels, including the sub-5s regime; recorded verdicts.
5. **Review and publish** — behavior-preserving publish, then admin-set `a0`.
