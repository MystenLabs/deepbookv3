# Quote calibration table — build plan (DBU-733)

> **Status:** plan, implementation in flight (DBU-733). This document describes
> the target design and the build sequence. As pieces land, the durable parts
> move into [architecture](./architecture.md), [configuration](./configuration.md),
> [decisions](./decisions.md), and the module docs, and this file tracks what
> remains; it is deleted when the work ships.

## Motivation

Predict quotes a binary market by pushing the vendor's implied-variance surface
through a fixed formula: the quoted UP probability is the skew-adjusted digital
`N(d2) - n(d2) * w'(k) / (2 * sqrt(w))`, evaluated in
`sources/pricing/pricing.move` (see
[pricing-and-oracles](../concepts/pricing-and-oracles.md)).

A quoted probability is a model output; the protocol separately observes what
happened. Every expiry settles against an exact Propbook Pyth print, so for any
strike the realized outcome — settled above it or not — is known after the
fact. Across many settled markets the realized frequency of settling above a
strike can be compared with the probability that was quoted for that strike,
bucketed by how much time remained when it was quoted. Where those two disagree
in a way that persists across markets, the disagreement is a property of the
quoting rule rather than noise, and it is measurable without any model of why it
is there.

Nothing in the pricing path can close such a gap today. A quote is a pure
function of the vendor's surface parameters and the market's remaining time, so
the only ways to move it are for the vendor to publish different parameters or
for the package to be upgraded. Neither is a control the protocol can exercise
on the timescale over which the gap drifts.

This plan adds one: a small correction table, measured from settled outcomes by
a permissioned off-chain keeper and applied on-chain after the pricing formula.
It is deliberately a remap of a number rather than a second model. It carries no
view of its own, cannot express a shape the raw quote did not already have, and
is bounded at push time, so a wrong table is a bounded error rather than a
repricing.

## What it corrects

The correction applies to the **UP digital probability at a single strike** —
the atom every other quoted quantity is built from. A range probability is
`P(lower) - P(higher)`, so it inherits the correction through its two
boundaries and needs no machinery of its own.

Deliberately unchanged:

- **The SVI surface, `d2`, the roll-down, and the skew correction.** The
  correction consumes the formula's output and returns a probability; it does
  not reach inside `compute_nd2`. It also composes with any later change to the
  distribution that formula pushes the surface through, because it is measured
  against whatever the pricing path actually quotes.
- **Settlement and payout.** Terminal payout is a tick comparison against the
  settled price (`strike_exposure::settled_order_payout`) and settlement reads
  `pricing::load_exact_spot`. Neither takes a `Pricer`, so the correction is
  structurally unable to reach either.
- **Every consumer of a price.** Mint admission, live close, per-order value,
  and the NAV walk all read the same corrected atom through the same two
  functions; nothing is corrected in one flow and raw in another.

## The table

One table per Propbook underlying, on two fixed grids:

```
9 time-to-expiry keys    1, 2, 5, 10, 20, 45, 90, 180, 300 seconds
19 probability knots     5%, 10%, ..., 95%
                         = 171 u64 at 1e9, row-major, plus updated_at_ms
                           and the pushing transaction's digest
```

Each stored value is the corrected probability at that grid point, so the table
is the map itself rather than a set of offsets, and validation is a direct
comparison. The endpoints `m(0) = 0` and `m(1) = 1` are implicit and never
stored. Both grids are upgrade-required constants: a different cadence set or
knot count is a package upgrade, not an admin transaction, so the shape the
keeper fits against cannot drift underneath it.

Tables are held in a `Table` keyed by underlying, so supporting another
underlying costs one dynamic field rather than growing the shared config object
that every flow already loads. The read is one dynamic-field load per `Pricer`,
which the flush-cost measurement below accounts for.

## Resolving a row: one interpolation law

A quote needs the row for its own remaining time, which almost never lands on a
key. The whole schedule is one rule — **linear interpolation in inverse time,
with a virtual identity row at infinite time to expiry**:

```
u        = 1 / tte
row(u)   = weighted average of the two bracketing key rows in u
identity = a virtual row at u = 0, whose knots are the grid probabilities
```

Interpolating in `1 / tte` rather than in `tte` is what makes the far end fall
out of the same rule instead of needing its own. Beyond the 300-second key the
interpolation runs between that row and the identity row, which works out to
`p + (300s / tte) * (m_300(p) - p)`: a correction that decays smoothly toward
none as the market gets further out, with no clamp, no second constant, and no
kink. Interpolating linearly in `tte` cannot express this — with the identity
anchor at infinity it never decays at all, and pulling the anchor to a finite
time would invent a constant and a corner.

Below the 1-second key the 1-second row applies unchanged; there is nothing
further in to interpolate toward, and it is the coordinate where the correction
matters most.

The weight never forms a reciprocal. Between keys `k_lo` and `k_hi` at
remaining time `t`, the weight on the low row is
`k_lo * (k_hi - t) / (t * (k_hi - k_lo))`, exact integer arithmetic in `u128`;
beyond the top key the same expression with `k_hi` taken to infinity collapses
to `k_max / t`. Every case is a weighted average of two rows, one of which may
be the constant identity row, so no signed-offset arithmetic appears
anywhere — which is what keeps the properties below provable by inspection.

## Where the correction is applied

```
ProtocolConfig.quote_calibration      tables, switch, staleness, deviation cap
        |
registry::push_quote_calibration      keeper pushes one underlying's table;
        |                             capability-gated, validated, and refused
        |                             while a valuation is in flight
pricing::load_live_pricer             resolves the row for this market's
        |                             remaining time and stamps it into the
        |                             transaction-local Pricer
Pricer.up_price / range_price
        |
compute_up_price                      infinity sentinels return 1 and 0 ahead
        |                             of the branch, unchanged
        `-- compute_nd2(...)   ->   correct(row, q_raw)
```

The insertion point is load-bearing, not incidental. It sits on the
`compute_nd2` branch so that `P(-inf) = 1` and `P(+inf) = 0` stay structurally
exact, because the NAV walk enters open-lower orders at face value as its
`P(-inf) = 1` anchor without calling the pricer at all
(`strike_payout_tree::walk_linear`). A correction applied one level up, at
`up_price` or `range_price`, would move per-order range prices while leaving
that anchor at one — a disagreement between two ways of valuing the same book,
with nothing to abort on it. A test pins the agreement.

Resolution happens once per `Pricer`, so a transaction prices every strike in a
market under exactly one row, and a full-pool flush marks each market under the
row for that market's own remaining time.

## Configuration and authority

On `ProtocolConfig`, alongside `pricing_config`, all `AdminCap`-gated,
version-gated, refused during a valuation, and event-emitting:

- **`enabled`** — the kill switch. Off means every quote is the uncorrected
  formula output. Ships off, so publishing this changes no price.
- **`staleness_ms`** — how old a table may be and still be used. Default six
  hours, which is several missed keeper pushes rather than one.
- **`max_deviation`** — the push-time bound on how far a single knot may sit
  from its own grid probability. Default `0.10`, so the keeper may move any
  individual UP probability by at most ten percentage points. It is a bound on
  a wrong table, not a target; a healthy table sits far inside it.

Push authority is a `QuoteCalibrationCap`, allowlisted on `Registry` beside the
existing pause and lifecycle capabilities, minted and revoked by admin, with
minting version-gated and revocation not — the same shape those two already
use. The push entrypoint lives on `registry` and mutates `ProtocolConfig`
through a package-only setter, mirroring the existing capability-gated
entrypoints.

A push validates, in order: the capability is currently allowlisted; no
valuation is in flight; the payload is exactly 171 entries; every knot is at
most one; every row is non-decreasing; and every knot is within
`max_deviation` of its grid probability. It then stamps the clock and the
transaction digest and emits the whole table, so an indexer can reconstruct the
active map without reading state.

## What holds by construction

- **Bounded movement.** Push validation holds every knot within
  `max_deviation` of its own grid probability. Interpolating between knots is a
  weighted average, so the corrected value sits within `max_deviation` of the
  same weighted average of the grid probabilities — which is the input itself.
  Blending two rows, and blending toward identity beyond the top key, are
  further weighted averages of values that each satisfy the bound. So
  `|m(p) - p| <= max_deviation` at every probability and every time to expiry,
  not merely at grid points. A range quote is a difference of two corrected
  atoms and can therefore move by up to twice that; this is a consequence of
  the bound, not a second mechanism.
- **Monotonicity.** Each row is validated non-decreasing, and every blend is a
  weighted average of non-decreasing rows, so the resolved row is
  non-decreasing. `up_price` is non-increasing in strike, and a non-decreasing
  map of a non-increasing sequence is still non-increasing, so
  `strike_payout_tree::ENonMonotonePrice` continues to hold. The correction
  cannot create an inversion; it can only collapse one to equality, which
  lowers the abort rate rather than raising it.
- **Total probability.** The implicit endpoints pin `m(0) = 0` and `m(1) = 1`,
  so a partition of the strike line still sums to exactly one after correction,
  and the two sides of a market still price to one.
- **Fail-safe.** No table for the underlying, the switch off, or a table older
  than `staleness_ms`: each resolves to the uncorrected formula output. The
  protocol never quotes from a correction it cannot vouch for, and the failure
  direction is always toward today's behavior. All three are protocol-wide
  states that apply to every trader alike.
- **Publishing and pricing are never atomic.** Pricing against a table the
  current transaction published aborts, rather than falling back like the three
  states above. The publisher gains nothing legitimate from atomicity, since the
  next transaction serves just as well; but the uncorrected fallback would give
  the publisher alone a per-transaction way to quote outside the correction —
  without ever publishing a table the deviation, monotonicity, or staleness
  bounds would reject, and therefore without tripping any of them. That is the
  one keeper capability none of the other bounds would catch, so it is closed
  here rather than bounded.

## What the keeper must produce

The keeper is a separate service and is out of scope for this package, but the
on-chain grid defines its contract, and two parts of that contract are not
guessable from the table alone:

- **The target is the digital, not the range.** A row's knots map quoted
  `P(settles above K)` to corrected `P(settles above K)`. The keeper must
  therefore measure realized frequency of settling above a strike, bucketed by
  remaining time and quoted digital probability. Fitting range outcomes instead
  would produce a table that is wrong for how it is applied, because correcting
  a difference is not the same as differencing two corrections.
- **The interpolation law is part of the fit.** The keeper measures at the nine
  keys, but quotes are served at every time in between under the law above. A
  keeper that assumes a different law leaves a systematic error the table
  cannot see.

Rows are made non-decreasing before pushing; the on-chain check is a guard
against a broken push, not the mechanism that produces monotonicity.

## Test and evidence plan

- **Predict tests:** push validation for each rejection (wrong length, knot
  above one, a row that decreases, a knot outside the deviation bound,
  unallowlisted capability, push during valuation); resolution at and between
  keys, below the shortest key, and far beyond the longest; the disabled,
  absent, and stale paths each yielding the uncorrected price; pricing in the
  publishing transaction aborting; a corrected quote actually differing from
  the raw one; and the bounded-movement and monotonicity properties exercised
  over a grid of adversarial tables rather than one hand-written example.
- **The anchor agreement**, pinned directly: a market with open-lower orders
  values identically through the NAV walk and through per-order range pricing
  under a non-identity table, which is the test that fails if the correction
  ever moves to `up_price`.
- **Flush cost at capacity**, because this adds work to the per-node path
  rather than the per-transaction one: a full-pool valuation at the joint
  market and payout-tree bounds, measured against the current capacity budget,
  with the correction enabled and disabled.
- **Replay before enablement:** the correction is measured off settled markets,
  so the same archive that produced a candidate table is used to score it
  before any table is pushed to a live deployment.

## Phases

1. **Table and validation** — the `quote_calibration` config module, the grids
   as constants, push validation, row resolution, knot application, and their
   tests, with no pricing path yet reading it.
2. **Capability and entrypoint** — `QuoteCalibrationCap`, the `Registry`
   allowlist, mint and revoke, the push entrypoint, the admin setters, and the
   events.
3. **Resolution and application** — the calibration read in
   `load_live_pricer`, the `Pricer` field, the `compute_up_price` branch, the
   anchor-agreement test, and the flush-cost measurement.
4. **Enablement** — publish with the switch off, then a keeper pushing tables
   and an admin transaction turning it on once the replay score is recorded.
