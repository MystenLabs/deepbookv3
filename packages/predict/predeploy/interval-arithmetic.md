# Interval (envelope) arithmetic — definitions and doctrine

DRAFT — lands with the envelope-arithmetic rework (DBU-628); becomes settled
surface when that work is accepted. Companion to the rounding policy (R1–R3 in
`response-policies.md`), which it generalizes: instead of choosing one rounding
direction per expression and proving each subtraction safe individually, every
derived value carries both directed bounds, and direction choices happen only
at explicit collapse sites.

## The type and its contract

`fixed_math::interval::Interval { lo: u64, hi: u64 }` — a sound envelope on a
derived non-negative 1e9-scaled quantity.

**Soundness contract.** If every input's true value lies inside its interval,
the output's true value lies inside the output interval. All combinators
maintain this with directed rounding (`mul`/`mul_up`, `div`/`div_up`); each
side absorbs its own rounding ulp, so there is no separate error tracking and
no cross-expression rounding proof. The library is verified once (directed-
rounding and truth-containment property tests); call sites never re-argue
correctness.

**Transaction-local by construction.** `Interval` has no `store` ability.
Envelopes cannot reach persistent state; storage holds exact scalars only.

**Abort semantics.** An interval operation aborts only when its high side
cannot be represented (u64 overflow) or a difference is definitely negative —
for the quantities modeled here, that means broken inputs (an oracle surface
violating its monotonicity guarantee beyond the evaluation envelope), never
rounding dust. Low-side underflow clamps to zero, which is sound because every
modeled quantity is non-negative.

## Where width comes from

1. Fixed-point operation rounding: one ulp per multiply/divide.
2. Transcendental approximation: the documented per-primitive error constants
   (`fixed_math::math` module doc), folded in as a certified `e(w)` widen keyed
   on the evaluation's total variance `w` (`evaluation_error_for_variance`).
   `w`, `sqrt(w)`, and `d2` are computed at u128/1e18 precision — flooring the
   `b * inner` product to 1e9 was the entire low-variance error — so the bands
   are ~3× the high-precision pricing error measured over representative Block
   Scholes SVI surfaces (down to `w ~ 1e-8`, the 5-minute regime) under the
   `beta^2 <= 9 * min_tv` admission gate. Interval-B&B verification of the bands
   is planned hardening.
3. Oracle observation error: currently zero-width (feeds publish no confidence
   figure); a deliberate open decision.

The pricer admission gate (`assert_inputs_pricing_safe`) bounds the surface to
the certified domain: total variance stays positive and `beta^2 <= 9 * min_tv`
(`beta = b*(1+|rho|)`), which holds the skew correction clear of the `[0,1]`
clamp so every admitted evaluation lands inside an `e(w)` band. A surface
outside the gate aborts pricer construction — the flush's only value-domain
abort, recoverable on the next vendor post; real vendor surfaces clear it ~2×.

Exact protocol atoms — quantities, floor shares, balances, tick strikes,
committed contract terms, settled liabilities — enter as zero-width intervals.

## Stored values

Three classes, and only the first ever needed auditing:

- **Atoms and sums of atoms** (order terms, tree aggregates, balances,
  supplies, settled liabilities): exact integers; addition does not round.
- **Realized commitments** (a premium charged, a payout split, shares minted):
  a scalar was chosen at a collapse site and that exact amount moved; the
  stored value records what happened. The rounding dust was realized to a
  documented side at that moment; nothing remains to track.
- **Recurrences** (the EWMA gas state): the protocol quantity is defined as
  the integer recurrence, rounding included — exact by definition.

## Collapse sites

An envelope becomes a scalar only at explicit, greppable sites (`.hi()` /
`.lo()` reads), of three kinds:

- **Forced** — external discrete types (`Balance` splits).
- **Semantic** — bilateral contract terms. A site committing several related
  scalars commits one jointly consistent corner so integer identities hold
  exactly (the mint tuple: `entry_value = mul_up(P.hi, Q)`,
  `net_premium = div_up(entry_value, leverage)`, `floor_shares` by identity —
  the tuple's one free dust unit lands on the unconditional inflow; at 1x
  `div_up(E, F) = E`, so the zero floor is structural).
- **Free** — events and reads may carry width when the width is information
  (the flush event publishes the pool-value envelope; its width is the
  flush's bid/ask spread).

Every branch or assert over a derived value is also a collapse and states its
side: admission gates pass only when definitely in-band; the liquidation
knock-out test reads the gross envelope's low side (an order that might be at
or below its threshold is never counted above it) — one predicate across the
close classifier, the ambient sweep, and the flush scan; backing asserts and
surplus releases compare the definite (high) side of every hold.

## Side doctrine

Judged by USDC flow, biased to the pool: protocol inflows collapse at `hi`
(premiums, fees), protocol outflows at `lo` (redeems, rebates, withdrawals).
Distortions that move share counts but no USDC are dust-scale transfers among
LPs and acceptable. The pool mark protects suppliers: the supply queue
executes at the pool-value envelope's high bound, the withdraw queue at its
low bound, each with its own executability test; a degenerate low bound makes
withdrawals non-executable (existing retry/cancel machinery) without stalling
supplies.

## Public API criterion

A return that answers "what happens if I transact" is a scalar — the committed
corner, the number that will actually move. A return that answers "what is
this state worth" exposes both bounds as primitive `(u64, u64)` — any single
scalar would embed a side choice the consumer cannot undo. The `Interval` type
itself never appears in a `public` signature.

## Valuation pipeline facts

- The pool flush walks each market's payout tree once per boundary with
  envelope prices; the memo's monotonicity guard aborts only on definite
  inversion (a low bound above the previous high bound) — inversions inside
  overlapping envelopes are honest width.
- Market NAV is the defined quantity `max(0, free_cash − liability)` bounded
  per corner; the floor is semantic, and the mandatory flush has no
  value-dependent abort.
- Pool value is evaluated corner-wise: `lp_pool_value` is monotone
  non-decreasing in the summed market NAV (slope 1 or 1 − share; the integer
  floor only absorbs steps), so running the scalar pipeline at each corner
  yields the exact envelope with no correlated-width inflation between its
  gross and exclusion terms.
- Every abort reachable in the interval flush lane is a definite violation of
  the oracle vendor's monotone-surface guarantee; none is reachable through
  rounding or any admissible book. The liability-versus-correction subtraction
  is proven unreachable-negative: a scan survivor's true gross strictly
  exceeds its floor, so true linear strictly exceeds the survivor correction.

## Open (tracked, not yet settled)

- Sibling fee collapses: the core trading fee rounds up (protocol inflow);
  the builder fee and EWMA congestion penalty still round down — sides to be
  ratified.
- Scalar read lane (`current_nav`, `payout_liability`, `required_cash`,
  `up_price`/`range_price`) and the superseded scalar flush lane: convert to
  bounds reads or delete; pending with the test re-pin.
- Interval-B&B verification of the `e(w)` bands (they are ~3× the measured HP
  error, not yet a proof over the full admissible box); oracle confidence as an
  input width; a width sanity breaker at the drain (threat: a width-computation
  bug enabling supplier over-mint). The oracle-surface tolerated domain is
  settled: `beta^2 <= 9 * min_tv` at pricer construction.
