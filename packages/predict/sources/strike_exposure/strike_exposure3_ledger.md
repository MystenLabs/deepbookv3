# strike_exposure3 — Simplification + Sequencing Ledger (Phase B)

**Purpose.** `strike_exposure3.move` is the **collapsed / simplified** twin of the
faithful enumeration in `strike_exposure2.move`. Where `strike_exposure2` kept a
strict faithful baseline and only *logged* simplifications, this phase **applies**
them — exact (behavior-preserving) simplifications freely, and the one
behavior-touching class (a provably-dead abort) only with a written proof. Every
flow stays a **single fully-inlined function**: no helper extraction, no config-helper
calls, no struct/API changes. The behavior reference is `strike_exposure.move`
(helper-based original) + `config/strike_exposure_config.move` (original floor math).

**Status legend.** `APPLIED` = realized in this file. `LOGGED` = identified, deliberately
**not** applied (left faithful), recorded for a later phase.

**Conventions.** `FS` = `constants::float_scaling!()`. `window` =
`constants::leverage_floor_window_ms!()`. `max_premium` =
`config.max_expiry_floor_premium()`. `ltv` = `config.liquidation_ltv()`. `seed` =
`order.floor_seed_amount()` (== 0 for a 1x order). `ceil(a*b/c)` =
`predict_math::mul_div_round_up(a,b,c)`; `a*b/c` = `predict_math::mul_div_round_down(a,b,c)`.

**Tag index** (tags appear verbatim in code comments):
- **C1** — pricing/oracle validation gate must precede the index mutation.
- **S1** — provably-dead terminal-floor LTV re-assert removed.
- The remaining tags (S2–S4, D1–D2, N*, R*) are ledger-only.

---

## 1. The floor pipeline (shared shape, inlined everywhere)

Every flow that touches the floor inlines `config::floor_index_at_ms(expiry, t)` as the
saturating pipeline:

```
remaining = if (t >= expiry) 0 else expiry - t
elapsed   = if (remaining >= window) 0 else window - remaining
phase     = elapsed * FS / window           // mul_div_round_down
phase^2   = phase * phase / FS              // mul_div_round_down
premium   = max_premium * phase^2 / FS      // mul_div_round_down
index     = FS + premium
```

and `config::floor_amount_at_ms` as `ceil(shares * index / FS)`. Two exact
simplifications are **inherited from `strike_exposure2`** (already applied at the
start of this phase) and kept:

- **terminal index is the constant `FS + max_premium`** — `floor_index_at_ms(expiry, expiry)`
  is tautological (`remaining=0, elapsed=window, phase=FS, phase^2=FS, premium=max_premium`).
  So `terminal_floor_index = FS + max_premium` rather than a recomputed pipeline.
- **unconditional floor math (no `if (is_leveraged)` value-gating)** — `floor_seed_amount()`
  is `0` for a 1x order (`user_contribution = ceil(ev*FS/FS) = ev`, so `seed = ev - ev = 0`),
  so `floor_shares = ceil(0*FS/index) = 0` and all floor amounts collapse to 0 with no
  leverage guard. The reference's `floor_shares = if (is_leveraged) … else 0` cascade is
  reproduced by full enumeration with no new abort.

---

## 2. Domain maps (per flow, in file order)

Notation: each domain lists what it produces → which later domain consumes it.
`[PIN]` marks a constraint-pinned domain (see §4).

### `valuation_liability` (read-only; faithful)
1. **Empty-book guard** → `minted_min_strike`, `minted_max_strike`; early-returns 0 on the
   `min > max` sentinel (inlines `minted_strike_range`).
2. **Live inputs + curve** `[PIN: live_inputs validates oracle freshness/active before the
   curve build; read-only, so no mutation to sequence around]` → `forward`, `svi`, `curve`.
3. **Current floor index** → `current_floor_index`.
4. **NAV value** → `nav.live_value(grid, curve, min, max, current_floor_index)` (return).

### `close_settled_order` (mutating; simplified — S1, S3)
1. **Open floor index** → `open_floor_index`.
2. **Terminal floor index + floor amounts** → `terminal_floor_index`, `floor_seed_amount`,
   `floor_shares`, `terminal_floor`. (`floor_at_open`/`live_backing` omitted — unused by
   settled payout.)
3. **In-range determination + payout** → `grid`, `lower`, `higher`, `in_range`, `quantity`,
   `user_payout = if (in_range) quantity - terminal_floor else 0`. *Sequenced **after** the
   floor pipeline (S3).*
4. **Settled-liability decrement** `[PIN: validation asserts before the mutation]` →
   asserts materialized + no underflow, then `settled_payout_liability -= user_payout`.
5. **Liquidation tombstone removal** → `liquidation.remove_order`.

### `allocate_mint_order` (mint; simplified — maximal-sorted)
1. **Grid boundary validation** `[PIN]` — `assert_range_boundaries` before pricing.
2. **Live pricing + leverage tier + fee gate** `[PIN: C1]` → `entry_probability`, `fee_amount`
   (`fee_amount`'s value is consumed only at the return, but `assert_mint_fee_rate` must gate
   the mint — intentional def→use gap).
3. **Immutable contract terms** `[PIN: principal assert]` → `opened_at_ms`, boundary indices,
   `allocated_order`.
4. **Open floor index** → `open_floor_index`.
5. **Floor amounts** → `terminal_floor_index`, `floor_seed_amount`, `floor_shares`,
   `terminal_floor`.
6. **Terminal-floor LTV admission** `[PIN]` → `liquidation_ltv`, `max_terminal_floor`, assert.
7. **Leveraged liquidation-threshold admission** `[PIN]` → `floor_at_open`,
   `liquidation_threshold_at_open`, `gross_value`, assert. *`floor_at_open` is sequenced
   here, below the terminal-floor cap that does not need it (S3).*
8. **Index mutation** → `grid`, `terminal_payout`, `live_backing_payout`, payout/nav
   `insert_range`, minted-strike cache, `liquidation.insert_order`, `next_order_sequence++`.
9. **Return** → `(allocated_order, fee_amount)`.

### `close_and_quote_live_order` (redeem; simplified — S1, S2, S3)
1. **Close-quantity validation** `[PIN]` → `old_quantity`, asserts.
2. **Order range boundaries** → `grid`, `lower`, `higher` (shared by pricing + removal).
3. **Live pricing** `[PIN: C1]` → `range_probability`, `fee_rate` (values consumed only in the
   redeem-amount domain, after the mutation — intentional gap).
4. **Open floor index** → `open_floor_index`, `terminal_floor_index`.
5. **Old-order terms** → `old_floor_shares`, `old_terminal_payout`, `old_live_backing_payout`
   (full triple; the dead old-order LTV assert is **removed**, S1).
6. **Replacement-order terms** → identity (`replacement_quantity`, `has_replacement`,
   `resulting_order`) then `remaining_floor_shares`, the **live** LTV assert (guarded
   `!has_replacement ||`), `remaining_terminal_payout`, `remaining_live_backing_payout`.
   *The identity block is sequenced here (S3), merged with the terms it feeds.*
7. **Closed deltas** → `closed_floor_shares`, `closed_terminal_payout`,
   `closed_live_backing_payout` (three subtractions; S2).
8. **Index removal + liquidation** `[mutation]` → payout/nav `remove_range`,
   `liquidation.remove_order`, conditional `insert_order` + `next_order_sequence++`.
9. **Current floor index** `[PIN: after the mutation by locality]` → `current_floor_index`.
10. **Redeem amount** → `closed_floor_amount`, `gross_redeem_amount`, `redeem_amount`,
    `fee_amount` (return).

### `liquidate_live_orders` (mutating; simplified — S1, S2)
1. **Candidate selection** `[PIN: watermark mutation runs before the live-inputs gate,
   faithful to the reference]` → `candidates`; early-return on empty.
2. **Live oracle inputs** `[PIN: validates freshness/active before any index mutation]` →
   `forward`, `svi`, `grid`.
3. **Per-candidate loop** (`while i < len`): per candidate —
   - boundaries + `compute_range_price` `[PIN: validates the range before this candidate's
     removal]`;
   - **liquidation_check_terms** (inlined): open floor index → `floor_shares`; current floor
     index → `current_floor_amount`; `liquidation_threshold`; `gross_value`;
     `should_liquidate`;
   - **order_index_update_terms** (inlined, flat): `terminal_floor`/`terminal_payout`,
     `floor_at_open`/`live_backing_payout` (the dead LTV assert is **removed**, S1; payouts
     folded, S2);
   - **gated mutation** `if (should_liquidate)` → payout/nav `remove_range`,
     `mark_liquidated`, `emit_order_liquidated`, `liquidated_count++`.

The getters, `is_liquidated_order`, `new`, `clear_liquidated_order`,
`materialize_settled_liability`, `decrease_materialized_settled_liability`, and
`destroy_live_indexes` are thin field/grid/liquidation accessors with no floor math —
copied faithfully from the reference, no simplification.

---

## 3. Simplifications APPLIED

### S1 — provably-dead terminal-floor LTV re-assert removed — APPLIED
- **Where:** redeem old order (`close_and_quote_live_order`), `close_settled_order`,
  `liquidate_live_orders`.
- **Reference:** `order_index_update_terms` runs
  `assert!(terminal_floor < mul_div_round_down(quantity, ltv, FS), ETerminalFloorExceedsLiquidationLtv)`
  every time it is reached.
- **Proof of deadness.** `terminal_floor` and `max_terminal_floor` are pure functions of (a)
  the order's stored fields — `floor_seed_amount()`, `opened_at_ms()`, `quantity()`, which are
  immutable decodes of the packed `Order` `u256` (`order.move`: `Order has copy, drop { id: u256 }`,
  no setter; `floor_seed_amount` is itself a pure function of `entry_probability`/`quantity`/
  `leverage`) — and (b) the exposure's `config` snapshot, which has **no setter** in
  `extrike_exposure_config2` (immutable for the exposure's life), plus compile-time constants
  and the fixed `expiry_ms`. The terminal index is the constant `FS + max_premium`, so
  `terminal_floor` is even clock-independent. Every order is created either at mint
  (`allocate_mint_order` runs this exact assert) or as a replacement
  (`close_and_quote_live_order`'s replacement branch runs it). Therefore the pair
  `(terminal_floor, max_terminal_floor)` re-derived at redeem-old / settled-close /
  liquidation is **byte-identical** to the values asserted at creation, so the inequality
  still holds — the assert can never fire. In `close_settled_order` and `liquidate_live_orders`
  the reference even guards it (`!in_range ||`, `!should_liquidate ||`), confirming it is only
  reached on the in-range / liquidate path where the dead inequality is checked.
- **Behavioral delta vs `strike_exposure.move`:** none. A dead assert never aborts, so removing
  it (and its sole-purpose operand `max_terminal_floor`, plus `liquidation_ltv` where that was
  its only use) is exactly behavior-preserving. It is the **only** assert removed anywhere.
- **Still live:** the redeem *replacement-order* LTV assert is **kept** — the replacement is
  created in this close and has never been admitted, so it can actually fire on a rounding-edge
  partial close (`terminal_floor` ceils, `max_terminal_floor` floors). The mint admission asserts
  are kept (mint is the first admission). No other abort is touched.

### S2 — per-order payout backing folded into the per-order term domains — APPLIED
- **Where:** redeem (old + replacement orders), `liquidate_live_orders`.
- **Change:** compute `terminal_payout = quantity - terminal_floor` directly under
  `terminal_floor`, and `live_backing_payout = quantity - floor_at_open` directly under
  `floor_at_open`, so each per-order domain produces the full triple
  `(floor_shares, terminal_payout, live_backing_payout)` — exactly the shape returned by the
  reference `order_index_update_terms`. In redeem this leaves the closed-deltas domain as three
  pure subtractions.
- **Behavioral delta:** none (pure reorder of identical subtractions). It tightens locality and
  aligns the domain seams with the reference helper (the natural cut for the helper rebuild).

### S3 — maximal dependency sequencing (drop stranded blocks to just before their consumer) — APPLIED
Pure reorders, behavior-identical, no data-dependency or pin violations:
- **mint `floor_at_open`** dropped below the terminal-floor LTV admission domain, to directly
  above its first consumer `liquidation_threshold_at_open` (the terminal-floor cap does not need
  it).
- **redeem replacement-identity** (`replacement_quantity`, `has_replacement`, `resulting_order`)
  dropped from the top of the function down into the replacement-terms domain — nothing between
  close-validation and that domain (boundaries, pricing, open-index, old-terms) references it.
  (This deliberately supersedes `strike_exposure2`'s N2 "keep the domain object at the top"
  choice; the maximal-sequencing directive takes precedence here.) `resulting_order` still reads
  `next_order_sequence` before the mutation increments it, and stays above the mutation + return.
- **settled in-range/boundary block** (`grid`, `lower`, `higher`, `in_range`, `quantity`) dropped
  **below** the floor pipeline, to just above `user_payout` — the short block belongs nearest its
  consumer, which also minimizes the long floor chain's definition-to-use distance.

After S3, every binding in mint and redeem is defined immediately before its first use, except the
constraint-pinned gates in §4 whose def→use gap is intentional.

---

## 4. Constraint pins (NOT simplifications — do not "optimize" away)

### C1 — pricing/oracle gate must precede the index mutation (validate-before-mutate)
- mint: `live_range_probability` + `assert_mint_leverage_tier` + `assert_mint_fee_rate` abort on
  oracle staleness / inactive market / now≥expiry / leverage tier / invalid range. They gate the
  mint and stay above the index `insert_range` even though `fee_amount`'s value is only used at the
  return.
- redeem: `live_range_probability` + `fee_rate` are abort-capable gates above the index
  `remove_range`, even though their values feed only the post-mutation redeem-amount domain.
- valuation: `live_inputs` validates freshness/active before `build_curve` (read-only; no mutation
  to sequence around, but the abort must precede curve construction).
- liquidation: `live_inputs` (before the loop) and per-candidate `compute_range_price` validate
  before each `remove_range`.
- Pure locality would pull these down to their value-use (below the mutation); that is rejected —
  the freshness/active/range facts are mutation-independent preconditions. The def→use gap is
  intentional.

### Other pins
- **Liquidation candidate selection before `live_inputs`** — `select_liquidation_candidates`
  mutates the passive-scan watermark and runs *before* the live-inputs gate, faithful to the
  reference. Not reordered.
- **Redeem current-floor index after the mutation** — `current_floor_index` is only used by
  `closed_floor_amount` in the post-mutation redeem-amount domain, so locality places the whole
  current-index pipeline after the mutation. It is not a gate, so this is allowed.
- **Settled-liability / replacement asserts** — the `ESettledLiability*` asserts and the live
  replacement-order LTV assert stay above their respective mutations.

---

## 5. LOGGED — behavior-touching simplifications deliberately NOT applied

### D1 — double-rounding through floor shares (kept faithful)
- **Where:** every floor-amount derivation (mint, redeem old/replacement, settled, liquidation).
- **Faithful (kept):** `floor_shares = ceil(seed*FS/open_index)`, then
  `floor_at_open = ceil(floor_shares*open_index/FS)` and
  `terminal_floor = ceil(floor_shares*terminal_index/FS)`. Double round-up; `floor_at_open >= seed`.
- **Candidate (not applied):** collapse to single-rounding — `floor_at_open = seed`,
  `terminal_floor = ceil(seed*(FS+max_premium)/open_index)`, current floor direct from `seed`.
- **Why not:** it is **behavior-changing** (values differ by ≤1 ulp; it slightly loosens the
  terminal-floor LTV admission bound and the live-backing payout). The directive's default for an
  uncertain rounding change is "leave faithful and log." Left faithful across all flows.

### D2 — empty-book guard in `valuation_liability` (kept faithful)
- **Faithful (kept):** inline `minted_strike_range` as the sentinel collapse
  (`is_empty_book ? (0,0) : (min,max)`) followed by `if (min==0 && max==0) return 0`.
- **Candidate (not applied):** `if (live.minted_min_strike > live.minted_max_strike) return 0`,
  then use `min`/`max` directly.
- **Why not:** equivalent only if no finite minted strike can be `0`; the `==0 && ==0` form also
  returns 0 for a degenerate `min==max==0` book. To avoid relying on strike positivity in
  read-only valuation, kept faithful.

---

## 6. Replicated-helper catalog (seams for the eventual helper rebuild)

These are the inlined helpers the rebuild will re-extract; the domain boundaries above are the cut
lines.
- **`floor_index_at_ms(expiry, t)`** — the saturating pipeline (§1). Inlined per (expiry, timestamp):
  mint open; redeem open + current; settled open; valuation current; liquidation open + current.
  The terminal sample is the constant `FS + max_premium` and never calls it.
- **`floor_amount(shares, index) = ceil(shares*index/FS)`** — terminal floor, floor-at-open,
  current floor, `current_floor_amount`, `closed_floor_amount`.
- **`floor_shares_for_seed(seed, open_index) = ceil(seed*FS/open_index)`** — every order/timestamp.
- **`order_index_update_terms`** — the per-order triple `(floor_shares, terminal_payout,
  live_backing_payout)` with the LTV assert: live at mint and at the redeem replacement; **dead and
  removed** (S1) at redeem-old, settled, and liquidation.
- **`liquidation_check_terms`** — `(should_liquidate, gross_value, current_floor_amount)` in the
  liquidation loop.
- **`minted_strike_range`** — the empty-book sentinel in valuation.

---

## 7. Error-code note
`ESettledLiabilityNotMaterialized = 0` and `ESettledLiabilityUnderflow = 1` intentionally share
values with the config-derived `ETerminalFloorExceedsLiquidationLtv = 0` /
`EOrderBelowLiquidationThreshold = 1`. In the reference these lived in two separate modules
(`strike_exposure` vs `strike_exposure_config`); the inlined merge preserves each abort's original
source code rather than renumbering (Move permits duplicate constant values).
