# Predict Close-Flow Simplification Analysis

Analysis of `close_and_quote_live_order` and the surrounding live-close flow, aimed at
reduced surface area and simpler reasoning. **No source files were modified.** Findings are
grounded in the files below and the design ledgers under
`packages/predict/sources/strike_exposure/strike_exposure{2,3,4}_ledger.md`.

Files read end-to-end: `strike_exposure_rewrite.move`, `strike_exposure.move`,
`config/strike_exposure_config.move`, `order.move`,
`index/strike_payout_tree.move`, `index/strike_nav_matrix.move`,
`index/liquidation_book.move`, the three ledgers, and the index/flow tests.

> Naming note: the payout index is `strike_payout_tree.move` (a treap), **not**
> `strike_payout_matrix.move`; config lives at `config/strike_exposure_config.move`;
> `liquidation_book.move` lives under `index/`. The rewrite imports the *rewrite* config
> twin `strike_exposure_cofig_rewrite` (sic).

---

## Executive recommendation

1. **Exact old-minus-remaining rounded deltas are REQUIRED — keep them.** This is not a
   tunable dust budget; it is a hard equality invariant. After a partial close the index
   slot must hold *exactly* `ceil(remaining_seed·FS/oi)`, because the replacement order's
   later full close / liquidation re-derives its removal amount from its **stored seed**,
   never from the slot. The exact delta `old_term − remaining_term` is the unique value
   that leaves the slot at that target. (Confirmed independently four ways — see
   Rounding/dust findings.)

2. **Reject the "direct `closed_seed`" simplification.** `ceil(x) − ceil(y) ≤ ceil(x − y)`
   (ceil is superadditive), so deriving `closed_floor_shares = ceil(closed_seed·FS/oi)`
   over-removes by exactly **+1 in ~50% of leveraged cases**. For NAV `floor_shares` that
   over-removal aborts the replacement's later close with `EInsufficientQuantity`
   (`strike_nav_matrix.move:358`); for the payout terminal term it *under*-removes, leaving
   a residual that permanently overstates `settled_payout_liability`
   (`strike_payout_tree.move:65-73`). The drift **accumulates** across sequential partial
   closes (it is not self-correcting, because each replacement re-derives from its stored
   seed). The ledger already tried and **reverted** this exact variant
   (`strike_exposure2_ledger.md:51-55`, L5).

3. **The complexity the prompt describes is a *rewrite-inlining artifact*, not an
   algorithmic necessity.** The shipping source `strike_exposure.move` already expresses
   the whole thing cleanly as
   `closed = order_index_update_terms(old) − order_index_update_terms(remaining)`
   (`strike_exposure.move:495-509`, helper at `strike_exposure_config.move:200-225`). The
   ugly `ceil(...)` chains the prompt quotes only exist because the *rewrite*
   (`strike_exposure_rewrite.move:436-545`) inlines those two helper calls into two fully
   expanded branches. The right move when porting back to source is to **keep the source's
   difference-of-terms shape**, not to inline it.

4. **Hide-at-the-boundary question (Q8): it is already hidden, and it cannot be pushed
   further into the index.** `order_index_update_terms` *is* the boundary that hides the
   rounding; the close flow just differences two calls. Do **not** push `seed → terms`
   conversion into `remove_range`: the indexes are aggregates that do not (and cannot)
   retain the per-order `open_floor_index` that links a seed to its share count, so they
   physically cannot reproduce the per-order rounding. Keep the caller passing pre-rounded
   terms.

5. **Do not switch the value indexes to remove-old / insert-new.** Old and replacement
   share the same `(lower, higher)` and the same `open_floor_index`, so the delta is exact
   in one traversal; remove-old-then-insert-new would do two full traversals over identical
   boundaries for zero correctness gain. Remove-old/insert-new is correct only for the
   **id-keyed** `liquidation_book` (the order id changes), where it is already used
   (`strike_exposure.move:455-458`).

6. **Net change set for the source file is small and structural** (details in *Recommended
   implementation shape*): branch once on `close_quantity == old_quantity` instead of
   laundering full-vs-partial through `resulting_order.id() == order.id()` across two
   helpers; fold `terminal_floor_index` to the constant `FS + max_expiry_floor_premium`;
   optionally drop the provably-dead old-order LTV re-assert. The **behavior-changing**
   CC1/CC2 collapses (the rewrite's one-step floors) are a separate decision that must be
   taken jointly across all four floor-touching flows, with sign-off (see Open questions).

---

## Current rewrite close flow summary (`strike_exposure_rewrite.move:391-546`)

Fully inlined, two explicit branches, with the ledger CC1–CC3 collapses applied.

1. Validate `close_quantity` (`order::assert_valid_quantity`, `≤ old_quantity`) — lines 401-403.
2. Decode `(lower, higher)` once from the order's boundary indices — lines 406-408.
3. Sample `range_probability = pricing::live_range_probability(...)` — the live-market
   validation gate (oracle freshness / market active / now < expiry); must precede any
   mutation — lines 413-420.
4. Sample the three floor indices once: `open_floor_index`, `current_floor_index`, and
   `terminal_floor_index = FS + max_expiry_floor_premium` (constant, L3) — lines 425-431.
5. **Full close** (`close_quantity == old_quantity`, lines 436-473): compute old canonical
   terms inline (`closed_terminal_floor`, `closed_terminal_payout`,
   `closed_live_backing_payout`, `closed_floor_shares`), `remove_range` both indexes,
   `liquidation.remove_order`, compute `redeem_amount`, **return `(*order, …)`**.
6. **Partial close** (lines 475-545): `replacement_quantity = old − close`;
   `remaining_floor_seed_amount = floor(old_seed·rq/oq)` (round-down);
   `remaining_terminal_floor`; **replacement-only LTV assert** before constructing the
   replacement; build `order::replacement(...)`; compute `closed_* = old_term − remaining_term`
   for both rounded floor terms (and the raw seed delta for live backing); `remove_range`
   both indexes with the deltas; update liquidation book (remove old, insert replacement,
   bump sequence); compute `redeem_amount`; return `(replacement, …)`.

Rewrite-specific collapses vs source (behavior-changing, see CC table): `terminal_floor =
ceil(seed·tfi/oi)` (one round-up, CC2) and `live_backing = quantity − seed` (CC1, no
round-trip).

## Current source close flow summary (`strike_exposure.move:256-532`)

Same algorithm, **faithful** (double-round-through-shares) rounding, factored through
helpers instead of inlined:

- `close_and_quote_live_order` (256-288): boundaries → validate → `range_probability` →
  `close_live_exposure(...)` → finish redeem quote (`gross_redeem_amount` 285,
  `redeem_amount` 286).
- `close_live_exposure` (438-460): `resulting_order_after_close` → `remove_closed_live_order`
  → `liquidation.remove_order(order)` → if replacement id ≠ order id,
  `liquidation.insert_order(replacement)`.
- `resulting_order_after_close` (462-484): `replacement_quantity == 0` ⇒ return `*order`
  (full-close sentinel); else `remaining_floor_seed = floor(seed·rq/oq)`, build
  `order::replacement`, bump sequence.
- `remove_closed_live_order` (486-532): `old_* = order_index_update_terms(order)`;
  `remaining_* = (0,0,0)` if full close else `order_index_update_terms(resulting_order)`;
  `closed_* = old_* − remaining_*`; `closed_floor_amount = ceil(closed_floor_shares·ci/FS)`;
  `remove_range` both indexes.
- Canonical term math: `strike_exposure_config::order_index_update_terms` (200-225) returns
  `(floor_shares, terminal_payout, live_backing_payout)` from one order's
  `(seed, opened_at, quantity)`. **The same helper backs mint** (`insert_live_order`,
  578-585) **and liquidation** (`liquidate_candidate_if_under_floor`, 557-559) — one source
  of truth for insert == remove balance.

Key source-side friction (all minor / structural):
- Full-vs-partial is discriminated by `resulting_order.id() == order.id()` and re-checked in
  two helpers (`:456`, `:500-506`) rather than branched once on `close_quantity`.
- `order_index_update_terms` does the faithful **double round-trip**: `floor_at_open =
  ceil(ceil(seed·FS/oi)·oi/FS)` (`:219-223`) and `terminal_floor = ceil(floor_shares·tfi/FS)`
  with `tfi = floor_index_at_ms(expiry, expiry)` recomputed per order (`:213-218`) though it
  is the constant `FS + max_premium`.
- The replacement seed is packed into an `Order` then immediately decoded to re-derive its
  terms (works, but a round-trip).

---

## Minimal required state changes

There are exactly **three** persistent stores touched by a live close, plus the redeem
quote return. (Pricing/floor-index reads are not state.)

| Store | Full close | Partial close |
|---|---|---|
| `StrikePayoutTree` (per-boundary `terminal_payout`, `live_backing_payout`) | remove old order's terms | remove `old − remaining` terms |
| `StrikeNavMatrix` (boundary `WeightedQuantity` + aggregate `floor_shares`) | remove `old_quantity`, `old_floor_shares` | remove `close_quantity`, `old_fs − remaining_fs` |
| `LiquidationBook` (id-keyed active set) | `remove_order(order)` (no-op for 1x) | `remove_order(order)` + `insert_order(replacement)` + `next_order_sequence += 1` |
| return (not state) | `(*order, redeem_amount, range_probability)` | `(replacement, redeem_amount, range_probability)` |

Asymmetry worth noting: NAV's **quantity** removal is `close_quantity` (linear/exact),
while NAV's **floor_shares** removal is the rounded delta `old_fs − remaining_fs`. The
payout-tree's `live_backing` delta is linear (`close_quantity − (old_seed − remaining_seed)`)
while its `terminal_payout` delta carries the rounded `terminal_floor` difference. **Only
the two ceil-rounded terms (NAV `floor_shares` and payout `terminal_floor`) are sensitive to
the dust question; the quantity and live-backing terms are exact under any scheme.**

---

## Value dependency table

`oi = open_floor_index`, `ci = current_floor_index`, `tfi = terminal_floor_index = FS + max_premium`,
`FS = float_scaling`. Rewrite line refs; classification per the prompt's taxonomy.

| Value | Formula (rewrite, collapsed) | Feeds | Classification |
|---|---|---|---|
| `close_quantity` (param) | — | validation, NAV qty removal, gross redeem | index-removal + redeem input |
| `lower`, `higher` | decode boundary indices | pricing, both `remove_range` | index-removal input |
| `range_probability` | `pricing::live_range_probability` | gross redeem; **returned** for caller fee | redeem + event/return input (validation gate) |
| `open_floor_index` | `floor_index_at_ms(expiry, opened_at)` | every floor term | index-removal input |
| `current_floor_index` | `floor_index_at_ms(expiry, now)` | `closed_floor_amount` | redeem input |
| `terminal_floor_index` | `FS + max_premium` (constant, L3) | terminal floor | index-removal input |
| `old_floor_seed_amount` | `order.floor_seed_amount()` | all old terms | index-removal input |
| `gross_redeem_amount` | `mul(range_probability, close_quantity)` | `redeem_amount` | redeem input |
| `closed_floor_shares` | `ceil(old_seed·FS/oi) − ceil(rem_seed·FS/oi)` | `nav.remove_range`, `closed_floor_amount` | **index-removal input (must be exact)** |
| `closed_terminal_payout` | `close_q − (ceil(old_seed·tfi/oi) − ceil(rem_seed·tfi/oi))` | `payout.remove_range` | **index-removal input (must be exact)** |
| `closed_live_backing_payout` | `close_q − (old_seed − rem_seed)` | `payout.remove_range` | index-removal input (exact by linearity) |
| `closed_floor_amount` | `ceil(closed_floor_shares·ci/FS)` (round **up**) | `redeem_amount` | redeem input |
| `redeem_amount` | `gross − min(gross, closed_floor_amount)` | **returned** | redeem/return output |
| `replacement_quantity` | `old_q − close_q` | replacement, LTV, NAV qty | replacement-construction input |
| `remaining_floor_seed_amount` | `floor(old_seed·rq/oq)` (round **down**) | replacement, all remaining terms | replacement-construction input |
| `remaining_terminal_floor` | `ceil(rem_seed·tfi/oi)` | replacement LTV assert; closed terminal | validation + index-removal input |
| `resulting_order` / `replacement` | `order::replacement(...)` | liquidation insert; **returned** | replacement-construction + return |
| `closed_terminal_floor` (full branch only) | `ceil(old_seed·tfi/oi)` | `closed_terminal_payout` | index-removal input |
| full-vs-partial discriminator | rewrite: `close_q == old_q`; source: `resulting_order.id() == order.id()` | branch | **scaffolding** (source's id-equality form is reducible) |

Pure **scaffolding / reducible-without-behavior-change**:
- Source's `resulting_order.id() == order.id()` discriminator and the `(0,0,0)` remaining
  branch (`strike_exposure.move:456,500-506`) — replaceable by an up-front
  `close_quantity == old_quantity` branch.
- The `resulting_order_after_close` + `remove_closed_live_order` split — one of the two
  helpers can absorb the other; the replacement-seed pack/decode round-trip is avoidable.
- `floor_index_at_ms(expiry, expiry)` recomputation — fold to constant `FS + max_premium`.
- The provably-dead **old-order** `ETerminalFloorExceedsLiquidationLtv` re-assert (it held at
  mint and nothing it depends on changed — `strike_exposure2_ledger.md:84`, v3 S1). Only the
  **replacement** LTV assert can actually fire (round-up `terminal_floor` vs round-down
  `max_terminal_floor`).

---

## Rounding / dust findings

### The central result (Q5, Q6, Q7)

**Exact old-minus-remaining accounting is required** by the current index design, which is
correct and minimal at the order layer. Two distinct, equally valid arguments:

1. **Equality invariant / underflow safety.** `floor_shares = ceil(seed·FS/oi)` is the real
   NAV sink (`strike_nav_matrix.move:41`), an aggregate `u64` decremented with a hard
   `assert!(*value >= amount)` underflow guard (`:354-361`, `EInsufficientQuantity`). The
   payout terms are per-boundary, guarded by `assert_terms_available` (`strike_payout_tree.move:381-387`,
   `EInsufficientPayoutTerms`). A replacement order's later full close / liquidation
   re-derives its removal amount **from its stored `remaining_seed`** (via
   `order_index_update_terms`), not from the slot. So after a partial close the slot must
   equal **exactly** `ceil(remaining_seed·FS/oi)`. The exact delta achieves this by
   construction (`slot := old_fs − (old_fs − rem_fs) = rem_fs`) and telescopes cleanly
   across any chain of partial closes back to zero.

2. **Cross-flow balance (ledger §1).** `strike_exposure4_ledger.md:160-173` states it
   directly: insert == remove == settled-payout balance "holds **only when** mint, redeem,
   liquidation, and settled-close all use the identical CC1/CC2 formula." Any scheme where
   removal isn't `old_canonical − remaining_canonical` unbalances the tree.

### Why the "direct `closed_seed`" simplification is unsafe

`closed_seed = old_seed − remaining_seed`, then `closed_floor_shares = ceil(closed_seed·FS/oi)`.
Because `ceil(x) − ceil(y) ≤ ceil(x − y) ≤ ceil(x) − ceil(y) + 1`:

```
direct  = ceil(closed_seed·FS/oi)          ≥  exact = ceil(old_seed·FS/oi) − ceil(rem_seed·FS/oi)
gap = direct − exact ∈ {0, 1}              (3M-sample sweep over oi∈[FS,2FS]: gap is +1 ≈ 50% of the time, never −1)
```

- **NAV `floor_shares` (over-removal → abort).** Direct removes one *more* share than the
  slot can give once the replacement is also removed.
  Reproduced: `oi = 1_000_000_003`, `old_seed = 700_000_001`, `old_quantity = 1000`, close
  300 ⇒ `remaining_seed = 490_000_000`.
  `old_fs = ceil(700000001·1e9/1000000003) = 699_999_999`;
  `rem_fs = 489_999_999`.
  Exact closed = `699_999_999 − 489_999_999 = 210_000_000` ⇒ slot ends at `489_999_999` (clean).
  Direct closed = `ceil(210_000_001·1e9/1000000003) = 210_000_001` ⇒ slot ends at
  `489_999_998 = rem_fs − 1`. The replacement's later full close removes `489_999_999`
  against a slot of `489_999_998` ⇒ `EInsufficientQuantity` abort (`strike_nav_matrix.move:358`).
- **Payout `terminal_floor` (under-removal → non-clearing residual).** Direct
  `terminal_floor` is +1 larger ⇒ `closed_terminal_payout` is 1 *smaller* ⇒ the slot ends 1
  *above* the replacement's term. It never returns to zero on full unwind, permanently
  overstating `settled_payout_liability` (`strike_payout_tree.move:65-73`).
- **`live_backing_payout` (harmless).** `close_q − (old_seed − rem_seed)` uses raw integer
  seeds with no rounding, so direct and exact are identical. Dust-free either way.

### Boundedness / accumulation

Per close the divergence is `≤ 1` floor_share and `≤ 1` terminal-floor unit. But it is
**not self-correcting**: each replacement re-derives its "old" terms from its *stored seed*,
never from the (already-drifted) slot, so under the direct scheme the deficit/residual
**compounds** across sequential partial closes of the same order. A 200k-trial simulation of
partial-close chains found worst-case accumulated drift of **14 floor_shares over an 18-close
chain** — eventually a hard underflow abort (NAV) or a permanently non-clearing settled
liability (payout). This is why the prompt's framing of "dust allocation" understates it: it
is monotone divergence between stored-order terms and index contents, not cosmetic dust.

### A separate, *already-decided* dust axis: the CC1–CC3 collapses (rewrite vs source)

The rewrite and source differ on a **different** rounding question from the one above — how
the *canonical per-order term* itself is rounded. The source uses the faithful
double-round-through-shares form; the rewrite applies the ledger's CC collapses. These are
explicitly **behavior-touching** (`strike_exposure4_ledger.md:7,95-171`) and must be applied
to **all four** floor-touching flows together to preserve balance.

| Collapse | Faithful (source) | Collapsed (rewrite) | Effect | Magnitude (ledger sweep) |
|---|---|---|---|---|
| CC1 `floor_at_open` | `ceil(ceil(seed·FS/oi)·oi/FS)` | `seed` | `live_backing = q − seed` larger (more conservative backing); mint `liquidation_threshold` smaller (more permissive) | live_backing +0..2 ulp; threshold +0..4 ulp |
| CC2 `terminal_floor` | `ceil(ceil(seed·FS/oi)·tfi/FS)` | `ceil(seed·tfi/oi)` | `terminal_payout` larger (more generous); LTV assert more permissive | +0..2 ulp |
| CC3 liq `current_floor_amount` | `ceil(ceil(seed·FS/oi)·ci/FS)` | `ceil(seed·ci/oi)` | liquidation slightly less likely at the edge; event field smaller | threshold +0..4 ulp; event +0..2 ulp |
| **Not collapsed** redeem `closed_floor_amount` | `ceil(closed_floor_shares·ci/FS)` | same | — | exact removed-share delta; cannot be re-expressed from a seed |

`floor_shares = ceil(seed·FS/oi)` itself is **never** collapsed (it is the stored NAV sink).
1x orders have `seed = 0` ⇒ every floor term is 0 ⇒ **zero CC delta**.

---

## Boundary critique

1. **Payout tree storing `terminal_payout` + `live_backing_payout` — keep (optionally
   refactor internals).** The two values are not derivable from each other without per-order
   floor data, so neither is redundant. A deeper observation: the two sides use *different
   algebras* married in `combine_summaries` — `terminal_payout` only needs an additive
   settlement-prefix sum, while `live_backing` only needs a running-max
   (`max_live_backing_prefix_gain`, `strike_payout_tree.move:316-343`). Splitting them would
   simplify `settled_payout_liability` and isolate the running-max logic. This is an
   *index-internal* refactor, orthogonal to the close flow; out of scope for the close-flow
   simplification but worth a follow-up ticket.

2. **NAV storing `floor_shares` (not seed) — keep as-is.** `floor_shares` is the
   index-normalized quantity that is **additive across orders opened at different times**;
   seeds are not (each needs its own `open_floor_index` to convert). The matrix is a dense
   aggregate with no per-order storage, so it physically cannot defer seed→shares conversion
   to read time. Read-time conversion of the *share aggregate* against the current index is
   already what `floor_amount` does (`:207-211`), and that is correct.

3. **"Floor seed as the canonical value" — already true at the right layer.** Seed is the
   sole canonical floor value at the `Order` boundary (one packed field,
   `order.move:137-139`); everything derives from it. The conversion seed→shares /
   seed→payout-terms is the order's **entry cost into each aggregate index** and must happen
   per-order at `open_floor_index` *before* aggregation. It cannot be deferred to index read
   time at the aggregate level.

4. **Insert replacement by delta vs remove-old/insert-new — keep delta for value indexes.**
   Old and replacement share `(lower, higher)` and `open_floor_index`, so
   `closed = old − remaining` is exact in **one** index traversal. Remove-old/insert-new
   would walk both indexes twice over identical boundaries for no correctness gain. (For the
   id-keyed `liquidation_book`, the id changes, so remove-old/insert-new is correct and
   already used.)

5. **Organize close around "remove difference, conditionally insert into the id-keyed book"
   — recommend, and the source already does it.** The canonical operation is: compute old
   terms, compute remaining terms (`0` on full close), remove the difference from the value
   indexes, and only the `liquidation_book` gets a true remove-old + insert-new (because its
   key changed). That is exactly `strike_exposure.move:495-509,455-458`. The rewrite's two
   fully-inlined branches re-derive the same `mul_div` chains twice
   (`strike_exposure_rewrite.move:447-451` vs `:505-509`, `:438-442` vs `:517-522`,
   `:466-471` vs `:539-544`) — that duplication is the regression to avoid when porting.

---

## Recommended implementation shape for `strike_exposure.move`

Keep the source's difference-of-terms design; apply only safe structural cleanups. Behavior
of the value indexes stays **identical** to today's faithful source.

```
public(package) fun close_and_quote_live_order(
    exposure, config, market, pyth, order, close_quantity, clock,
): (Order, u64, u64) {
    let (lower, higher)   = exposure.order_boundaries(order);
    let old_quantity      = order.quantity();
    order::assert_valid_quantity(close_quantity);
    assert!(close_quantity <= old_quantity, EInvalidCloseQuantity);
    let range_probability = pricing::live_range_probability(config, market, pyth, lower, higher, clock);

    // old terms: the canonical (floor_shares, terminal_payout, live_backing_payout)
    let (old_fs, old_tp, old_lb) = exposure.order_index_update_terms(order);

    let (resulting_order, closed_fs, closed_tp, closed_lb) =
        if (close_quantity == old_quantity) {
            (*order, old_fs, old_tp, old_lb)                 // full close: remaining = 0
        } else {
            let replacement = exposure.build_replacement(order, close_quantity); // floor seed + replacement LTV assert
            let (rem_fs, rem_tp, rem_lb) = exposure.order_index_update_terms(&replacement);
            (replacement, old_fs - rem_fs, old_tp - rem_tp, old_lb - rem_lb)
        };

    exposure.remove_live_terms(lower, higher, close_quantity, closed_fs, closed_tp, closed_lb);
    exposure.liquidation.remove_order(order);
    if (resulting_order.id() != order.id()) exposure.liquidation.insert_order(&resulting_order);

    let closed_floor_amount = predict_math::mul_div_round_up(
        closed_fs, exposure.config.floor_index_at_ms(exposure.expiry_ms, clock.timestamp_ms()),
        constants::float_scaling!());
    let gross = math::mul(range_probability, close_quantity);
    (resulting_order, gross - gross.min(closed_floor_amount), range_probability)
}
```

Concrete deltas from today's source:
- **Branch once** on `close_quantity == old_quantity` (drops the `resulting_order.id() ==
  order.id()` re-discrimination in `remove_closed_live_order:500-506`).
- **Collapse the two helpers** `resulting_order_after_close` + `remove_closed_live_order`
  into the inline branch above plus a thin `remove_live_terms` (the two `remove_range` lines)
  — symmetric with the existing `insert_live_order` used by mint.
- **`order_index_update_terms` cleanups** (`strike_exposure_config.move:200-225`): bind
  `terminal_floor_index = FS + max_expiry_floor_premium` once instead of calling
  `floor_index_at_ms(expiry, expiry)` (L3, behavior-identical); drop the dead **old-order**
  LTV re-assert if it is reintroduced anywhere (only the replacement assert can fire).
- **Keep** `closed_* = old_* − remaining_*`, the exact delta removal, and the round-**up**
  `closed_floor_amount` (vs the round-**down** NAV aggregate `floor_amount` — different
  directions are intentional: redeem is conservative against the user, valuation is
  conservative against aborting).

## Helper / API changes needed (Q11)

- **No index API change.** `insert_range`/`remove_range` keep their pre-rounded-term shape.
  Explicitly **do not** add a seed-taking overload that rounds internally (unsafe per the
  dust findings; the index lacks per-order `open_floor_index`).
- Optional: merge `resulting_order_after_close` + `remove_closed_live_order` and add a small
  `remove_live_terms(lower, higher, qty, floor_shares, terminal_payout, live_backing)` leaf
  mirroring `insert_live_order` (so mint/close/liquidation share one insert leaf and one
  remove leaf). Wide-tuple caution: `order_index_update_terms` returns a 3-tuple of
  same-typed `u64`s — acceptable as a tightly-local private helper, but if it crosses more
  boundaries consider a named package-only `IndexTerms` summary struct (per `move.md`
  return-tuple guidance).
- If/when the CC1–CC3 collapses are adopted, they live entirely inside
  `order_index_update_terms` / `liquidation_check_terms` and `settled_order_payout` — the
  close flow itself does not change. They must land **together** (T1–T4 joint), not
  incrementally (an intermediate state trips `ESettledLiabilityUnderflow`, ledger:166-169).

---

## Alternatives rejected and why

- **Direct `closed_seed` derivation** — rejected. Over-removes NAV `floor_shares` (+1 ~50%
  of the time → `EInsufficientQuantity` abort) and under-removes payout `terminal_floor`
  (→ non-clearing `settled_payout_liability`); drift accumulates. Already tried and reverted
  (`strike_exposure2_ledger.md:51-55`).
- **Push seed→terms rounding into `remove_range`** — rejected/impossible. The aggregate
  indexes don't retain per-order `open_floor_index`; they cannot reproduce per-order
  rounding. Keep the caller passing pre-rounded terms.
- **Remove-old / insert-new on the value indexes** — rejected. Two full traversals over
  identical boundaries for zero correctness gain; the delta is already exact in one pass.
- **Inlining the close like the rewrite does** — rejected for the *source*. It duplicates
  the `mul_div` chains across two branches; the source's difference-of-terms helper shape is
  strictly less surface area.
- **Storing floor seed in the NAV/payout indexes** — rejected. Seeds aren't additive across
  open times; conversion must precede aggregation.

---

## Test implications (Q12 — do not write tests now)

Current coverage of the close flow is **thin and partly stale**:
- `strike_exposure_tests.move` explicitly disclaims close coverage ("need broader manager
  and valuation fixtures"); no exact close values are asserted there.
- The only end-to-end live close is the EWMA-penalty test
  (`expiry_market_tests.move:276`), a **full** close that asserts only the penalty delta
  between two identical positions — not `redeem_amount`, `floor_shares`, or
  `terminal_payout`. `plp_rebate_flow_tests.move` exercises only the settled path.
- Index **leaf** tests do pin the safety guards this analysis relies on:
  `strike_nav_matrix_tests.move:136-143` (`EInsufficientQuantity` on floor-shares
  over-removal) and `strike_payout_tree_tests.move:222-237` (`EInsufficientPayoutTerms`,
  plus insert-then-remove returns to empty). These are exactly the aborts the rejected
  direct scheme would trip.
- **The suite does not currently compile on this branch.** `order_tests.move` is out of sync
  with the committed signatures (`order::replacement` is 4-arg, `new_from_boundary_indices`
  is 6-arg with no `leverage`); the stale tests call 2-arg / 7-arg-with-leverage forms. This
  must be fixed before any close-flow test can run.

Tests to add later (after the source change, none written here):
- **Partial-close index balance:** mint a leveraged order → partial close → full-close the
  replacement → assert both indexes return to empty and `settled_payout_liability` clears to
  zero (the telescoping invariant; would fail under the direct scheme).
- **Sequential partial closes** of one order (the accumulation case) → no underflow, indexes
  clear on final unwind.
- **`redeem_amount` exactness** for full and partial closes, including the
  `gross.min(closed_floor_amount)` clamp and the round-up direction.
- **Replacement LTV assert** firing on a rounding-edge partial close (round-up
  `terminal_floor` vs round-down `max_terminal_floor`), with a distinct guard abort
  (`abort 999`) per the repo's `expected_failure` convention.
- If CC1–CC3 are adopted: a balance test proving mint/redeem/liquidation/settled-close all
  use the identical collapsed formula (insert == remove == settled payout).

---

## Open questions requiring user decision

1. **Adopt the rewrite's CC1–CC3 collapses in source, or keep the faithful double-round
   form?** This is the only behavior-changing axis. The collapses (a) move backing in the
   conservative direction and payouts in the user-favorable direction by 0..2 ulp, (b) make
   admission/liquidation thresholds up to 4 ulp more permissive, and (c) must be applied to
   all four floor-touching flows **atomically**. The ledger claims they are intended; this
   report does not independently re-derive the ledger's 6M-sample bound. **Decision needed:**
   port the collapses (matching the rewrite) or keep source faithful.
2. **Scope of the source edit:** structural-only (branch-once + helper merge + `tfi`
   constant + drop dead assert) — safe and behavior-identical — versus also folding in CC1–CC3.
3. **Payout-tree internal refactor** (split additive `terminal_payout` prefix from running-max
   `live_backing`): worth a follow-up ticket, or leave the treap as-is?
4. **`order_index_update_terms` return shape:** keep the 3-`u64` tuple, or introduce a named
   package-only `IndexTerms` summary struct if it starts crossing more call sites?

---

### Answers to the 12 questions (index)

1. **Core purpose:** quote a redeem for `close_quantity` at the live range price and bring the
   live indexes (NAV, payout, liquidation set) into the post-close state — either the order
   removed (full) or shrunk to a replacement (partial).
2. **Minimal state changes:** see *Minimal required state changes* table — payout tree, NAV
   matrix, liquidation book; full = remove old, partial = remove `old−remaining` from value
   indexes + remove-old/insert-replacement in the id-keyed book.
3. **Minimal values:** boundaries, `range_probability`, old canonical terms `(old_fs, old_tp,
   old_lb)`, `current_floor_index`; partial adds `replacement_quantity`, `remaining_seed`,
   remaining terms, the replacement `Order`, and the replacement LTV input. See the value
   table.
4. **Scaffolding:** the `id()==id()` full-vs-partial discriminator and `(0,0,0)` branch; the
   two-helper split + replacement-seed pack/decode round-trip; per-order
   `floor_index_at_ms(expiry,expiry)`; the dead old-order LTV re-assert.
5. **Reducible without behavior change:** branch-once, helper merge, `tfi` constant, drop dead
   assert, difference-of-terms (already in source).
6. **Reducible only with dust-policy change:** CC1 (`live_backing`), CC2 (`terminal_payout`),
   CC3 (liquidation floor) — 0..2 (0..4) ulp; joint across four flows.
7. **Is exact old-minus-remaining required?** Yes — hard equality invariant; proven by
   underflow + cross-flow balance.
8. **Can it be hidden at the boundary?** It already is (`order_index_update_terms`); it cannot
   be pushed further into the aggregate index.
9. **If not required, simpler policy?** N/A — it is required. The direct-`closed_seed` policy
   is unsafe.
10. **Final source shape:** see *Recommended implementation shape*.
11. **Helper/API changes:** no index API change; optional helper merge + `remove_live_terms`
    leaf; CC collapses (if adopted) stay inside the config term helpers.
12. **Tests:** see *Test implications* — partial-close balance, sequential closes, redeem
    exactness, replacement LTV edge; fix the non-compiling stale `order_tests` first.
