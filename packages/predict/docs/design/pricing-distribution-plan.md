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

This plan makes the distribution a configured choice instead of a hardcoded
one: a grid of `B` values from 0.1 to 2.0 in 0.1 steps, selected at quote time
from remaining time-to-expiry through an admin-settable schedule.

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
ProtocolConfig.pricing_config        schedule lives here (admin-settable)
        |
pricing::load_live_pricer            resolves B from remaining TTE, stamps it
        |                            into the transaction-local Pricer
Pricer.up_price / range_price
        |
compute_nd2                          two call sites swap:
        |-- normal_cdf(d2)  ->  gen_normal::cdf(b, d2)
        |-- normal_pdf(d2)  ->  gen_normal::pdf(b, d2)
```

One additional touch point: `variance_sqrt_and_d2` caps `|d2|` at 8, which
encodes a fact about the *normal's* tail (beyond 8 the normal CDF is within one
raw 1e9 unit of 0/1). Fatter-tailed members need larger caps (see the table
below), so the cap becomes per-`B` data owned by the math layer, and the
pricing-side check keeps only a wide universal bound guarding the `u128 -> u64`
narrowing.

## Configuration: the TTE schedule

`PricingConfig` gains a schedule mapping remaining time-to-expiry to `B`:

- **Shape:** ordered rows `(min_tte_ms, b)`, thresholds strictly descending,
  terminal row `min_tte_ms = 0` so every TTE resolves. Resolution walks the
  rows and takes the first whose threshold is at or below the remaining time.
- **Encoding:** `B` is stored as a 1e9-scaled `u64` (the house fixed-point
  convention), validated on set to be one of the twenty grid values
  `100_000_000 * i, i in 1..=20`.
- **Setter:** `AdminCap`-gated, version-gated, and guarded by
  `assert_not_valuation_in_progress` like the other pricing setters — a
  distribution change may not land inside a valuation window.
- **Event:** schedule updates emit a config event carrying the full new
  schedule, so indexers and off-chain mirrors can track the active
  distribution (pricing setters are silent today; this one is not, because it
  moves every quoted price).
- **Scope:** protocol-global. Markets differ only through their remaining TTE.
- **Default:** the single row `(0, B = 2.0)` — current behavior at every TTE. A
  fresh publish prices exactly as today until the schedule is deliberately set
  by admin transaction. Initial schedule values are estimates and will be
  updated by admin transaction as tuning continues; no publish is needed to
  retune.

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
  Cody small/medium split. `s = 1/B` spans 0.5 to 10 across the grid.
- **`gen_normal` module** — a generated constants table, one row per grid
  value: `(s, ln_alpha, ln_gamma_s, pdf_norm, saturation_cap)`, plus the
  assembly functions `cdf`, `pdf`, and `saturation_cap` keyed by `B`. Row
  `B = 2.0` delegates to `normal_cdf` / `normal_pdf`. The table, the golden
  test vectors, and the off-chain replay mirror are all emitted by one
  checked-in Python generator (the `pricing_reference_data` pattern); the
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

| B | pdf(0) | tail mass beyond x = 8 | cap for < 1e-9 truncation |
|-----|----------|------------------------|---------------------------|
| 0.1 | 680,132 | 4.3e-4 | ~3,250 |
| 0.2 | 251 | 1.1e-3 | ~512 |
| 0.5 | 2.74 | 4.5e-4 | ~52 |
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

## Open question: schedule-boundary jumps

`B` steps at schedule thresholds, so a market's quotes jump when its remaining
TTE crosses a boundary (order sub-cent to ~a cent between adjacent grid values,
largest in the tails). Options, deliberately not decided yet: accept the steps
(the 0.1 grid is fine-grained; thresholds can be dense), or blend the two
adjacent members' prices near a boundary (twice the evaluation cost, no new
math). Start with steps, measure on replay, revisit if product needs it.

## Test and evidence plan

- **One generator, three outputs:** Move constants, Move golden-test vectors
  (CDF/PDF grids per `B` against high-precision reference), and the constants
  for the off-chain fixed-point replay mirror — a single source of truth.
- **`fixed_math` tests:** golden sweeps per grid value, symmetry, CDF
  monotonicity, saturation-boundary behavior, `gammainc` engine accuracy over
  the `(s, y)` domain, and bit-equality of the `B = 2.0` member with
  `normal_cdf` / `normal_pdf`.
- **Predict tests:** schedule validation and resolution (thresholds, terminal
  row, grid membership), config default = current behavior, distribution
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
Publish defaults to current behavior; the estimated schedule is applied by
admin transaction after the replay gates pass for every member it references.
Landing the schedule in the config layout before any mainnet publish exists is
deliberate: Sui upgrades freeze struct layouts, and this avoids ever needing a
config-migration path for it.

## Phases

1. **Generator + constants** — the Python generator and the `gen_normal`
   constants module it emits.
2. **`fixed_math` engine** — `gammainc_lower_reg`, the `gen_normal` assembly,
   1e18 input path, tests, per-`B` budgets. The long pole.
3. **Predict plumbing** — schedule config + setter + event, `Pricer` stamping,
   `compute_nd2` branch, per-`B` caps, tests, regenerated fixtures.
4. **Replay gates** — fixed-point mirror runs per grid value and for the
   candidate schedule; recorded verdicts.
5. **Review and publish** — behavior-preserving publish, then admin-set the
   schedule.
