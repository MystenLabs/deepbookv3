# strike_exposure2 — Simplification Ledger (Phase A)

**Purpose.** While maximally inlining + resequencing the mint/redeem flows in
`strike_exposure2.move`, the code stays **faithful** to `strike_exposure.move`'s
exact arithmetic — including its double-rounding round-trips through floor shares.
Every simplification we notice is **recorded here but NOT applied**. Phase B
(rebuild helpers/config) consumes this list.

**Conventions.** `FS` = `constants::float_scaling!()`. `window` =
`constants::leverage_floor_window_ms!()`. `max_premium` =
`config.max_expiry_floor_premium()`. `seed` = `order.floor_seed_amount()`.

**Status legend.** `LOGGED` = spotted, not applied. `APPLIED` = realized in Phase B.

---

## Mint flow — `allocate_mint_order`

### L1 — `floor_at_open` collapses to the seed — LOGGED
- **Where:** floor-economics block.
- **Faithful (original):** `floor_at_open = floor_amount_at_ms(expiry, floor_shares, opened_at) = ceil(floor_shares * open_index / FS)`, where `floor_shares = ceil(seed * FS / open_index)`. Double round-up; `floor_at_open >= seed`.
- **Simplification:** `floor_at_open == seed` exactly (in real arithmetic `shares * open_index = seed`; the round-trip only inflates by rounding).
- **Effect if applied:** `live_backing_payout = quantity - seed` and `liquidation_threshold_at_open` is computed from `seed`.

### L2 — `terminal_floor` single vs double rounding — LOGGED
- **Where:** floor-economics block (mint); current-floor block (redeem).
- **Faithful (original):** `terminal_floor = ceil(floor_shares * (FS + max_premium) / FS)` with `floor_shares` itself a round-up of `seed`. Double round-up.
- **Simplification:** compute directly from the seed: `ceil(seed * (FS + max_premium) / open_index)`. Single round-up; result `<= original`.
- **Effect if applied:** slightly larger `terminal_payout`; slightly more permissive `terminal_floor < max_terminal_floor` admission check.

---

<!-- Agents append new entries below, continuing the L-numbering. -->

### L3 — terminal floor index is a constant — LOGGED
- **Where:** floor-economics block (mint); current-floor / terminal-floor blocks (redeem).
- **Faithful (original):** `terminal_floor = floor_amount_at_ms(expiry, floor_shares, expiry)` calls `floor_index_at_ms(expiry, expiry)` to get the terminal index.
- **Simplification:** `floor_index_at_ms(expiry, expiry)` collapses to `FS + max_premium` for every order in the book — the window math is tautological at `timestamp == expiry` (`remaining = 0`, `elapsed = window`, `phase = FS`, `phase^2 = FS`, `premium = max_premium`).
- **Effect if applied:** the terminal index need not be recomputed per order; it is a per-exposure constant `FS + max_premium` (i.e. `FS + config.max_expiry_floor_premium()`).

### L4 — all floor terms vanish for non-leveraged orders — LOGGED
- **Where:** floor-economics block + mint-admission block (mint).
- **Faithful (original):** `floor_shares`, `terminal_floor`, `floor_at_open` all default to `0` when `!is_leveraged` (the original forces `floor_shares = 0`, and the two `floor_amount_at_ms` calls then round `0` to `0`).
- **Simplification:** for a non-leveraged order the mint-admission checks degenerate to constants: `terminal_floor < max_terminal_floor` is `0 < mul_div_round_down(quantity, ltv, FS)` (always true for positive quantity/ltv), and `liquidation_threshold_at_open = ceil(0 * FS / ltv) = 0`, so the second check reduces to `entry_probability * quantity > 0`. Both admission checks are no-ops for 1x orders and only bind for leveraged orders.
- **Effect if applied:** the two mint-admission asserts can be skipped (or scoped inside the leveraged branch) for non-leveraged orders without changing behavior.

---

## Redeem flow — `close_and_quote_live_order`

### L5 — current-floor deduction: net closed shares vs per-order subtraction — LOGGED
- **Where:** redeem current-floor deduction.
- **Faithful (original):** the deduction is the current floor on the NET closed shares — `closed_floor_amount = floor_amount_at_ms(expiry, closed_floor_shares, now)` where `closed_floor_shares = old_floor_shares - remaining_floor_shares`. One `floor_index_at_ms(now)`, one round-up over the share difference.
- **Draft variant (reverted):** computed two per-order current floors from the seeds — `old_current_floor = ceil(old_seed * current_index / open_index)` and `remaining_current_floor = ceil(remaining_seed * current_index / open_index)` — and deducted `old_current_floor - remaining_current_floor`.
- **Effect:** the two forms differ in structure AND rounding (two ceils on gross seeds vs one ceil on the net share delta). Faithful uses the net-shares form.

### L6 — `floor_index_at_ms` is replicated per timestamp — LOGGED (replicated helper)
- **Where:** mint open-index; redeem open-index AND current-index.
- **Observation:** the `elapsed → phase → phase² → premium → FS + premium` computation is inlined once per (expiry, timestamp). Mint inlines it once (open). Redeem inlines it twice (open at `opened_at_ms`, current at `now_ms`). After locality the current-index copy sits at the redeem-deduction site, far from the open-index copy — surfacing that they are the same function at two timestamps.
- **Phase B:** one `floor_index_at_ms(expiry, timestamp)` helper. The terminal index (timestamp == expiry) is the constant `FS + max_premium` (see L3) and need not call it.

### L7 — `floor_shares_for_seed` is replicated per order — LOGGED (replicated helper)
- **Where:** mint; redeem old order; redeem remaining order.
- **Observation:** `floor_shares = ceil(seed * FS / open_index)` appears 3× (once mint, twice redeem). Same computation, different seed input.
- **Phase B:** one `floor_shares_for_seed(seed, open_index)` helper.

### L8 — `floor_amount` (shares → amount) is replicated per index point — LOGGED (replicated helper)
- **Where:** terminal floor (mint + redeem old/remaining), floor-at-open (mint + redeem old/remaining), current floor (redeem).
- **Observation:** `ceil(shares * index / FS)` is inlined for every (shares, index) pair: terminal (index = FS+max_premium), at-open (index = open_index), current (index = current_index).
- **Phase B:** one `floor_amount(shares, index)` helper (the original `floor_amount_at_ms` after resolving the index).

### L9 — per-order index terms = one derivation applied to two orders — LOGGED (replicated helper)
- **Where:** redeem old order vs remaining (replacement) order.
- **Observation:** `seed → floor_shares → {terminal_floor, floor_at_open} → {terminal_payout = qty - terminal_floor, live_backing_payout = qty - floor_at_open}` is computed identically for the old order (qty = old_quantity) and the replacement (qty = replacement_quantity) at the SAME open index. This is the original `order_index_update_terms` applied twice.
- **Phase B:** one helper `(seed, quantity, open_index, terminal_index) → (floor_shares, terminal_payout, live_backing_payout)`; redeem calls it for old and remaining and subtracts.

### L1/L2 recur in redeem — LOGGED
- The seed-shortcut family (L1: `floor_at_open == seed`; L2: single-round terminal/current floor direct from seed) appeared in the redeem draft on the `old_*` and `remaining_*` terms and on the current-floor deduction. All reverted to the faithful double-round-through-shares form. Same Phase-B decision as L1/L2.

### L10 — fidelity fix: restored dropped `ETerminalFloorExceedsLiquidationLtv` assert in redeem — FIXED
- **Where:** redeem floor-economics block (`close_and_quote_live_order`).
- **Bug:** the redeem flow inlined `strike_exposure_config::order_index_update_terms` (`strike_exposure_config.move:128-134`) but DROPPED its terminal-floor LTV assert `assert!(terminal_floor < mul_div_round_down(quantity, liquidation_ltv, FS), ETerminalFloorExceedsLiquidationLtv)`. The reference runs this on the OLD order (`remove_closed_live_order`) and, on a PARTIAL close (`resulting_order.id() != order.id()`), also on the REPLACEMENT order.
- **Fix:** read `liquidation_ltv = exposure.config.liquidation_ltv()` once. Added the old-order assert between `old_terminal_floor` and `old_floor_at_open` (mirrors the reference position of the assert between `terminal_floor` and `floor_at_open`). Added the replacement-order assert between `remaining_terminal_floor` and `remaining_floor_at_open`, guarded by `!has_replacement ||` so a full close (`replacement_quantity == 0` ⇒ both sides 0) does not spuriously abort on `0 < 0` — the reference only runs this assert on the partial-close branch, which the short-circuit reproduces exactly.
- **Sub-note (LOGGED simplification candidate, NOT applied):** the OLD-order LTV re-assert is provably always-pass. The order already satisfied `terminal_floor < floor(quantity·ltv/FS)` at mint under the snapshotted config, and seed/opened_at/quantity/leverage/config are all unchanged at redeem, so it can never fire on the old order. Phase B may drop the old-order re-assert. The replacement-order assert is the one that can actually fire — a rounding-edge partial close, since `terminal_floor` ceils (round-up through shares) while `max_terminal_floor` floors (`mul_div_round_down`).

---

## Sequencing constraints (NOT simplifications — do not "optimize" away)

### C1 — pricing MUST precede index mutation (validate-before-mutate)
- `pricing::live_range_probability` and `pricing::fee_rate` are abort-capable validation gates: `live_range_probability → live_inputs → assert_live_quote_available` asserts pyth-source binding, market-active, and oracle freshness; `fee_rate` underflows unless `now < expiry`. Both run BEFORE any index `remove_range` / `liquidation` mutation, matching `strike_exposure.move`.
- Pure locality would push these down to their first value-use (`gross_redeem_amount` / `fee_amount`), which is after the mutation. Rejected: the freshness / active / now<expiry facts are mutation-independent preconditions that must gate the mutation. The earlier redeem draft mutated first; reverted.
- The "gap" (price computed early, value consumed late) is intentional. Do not move pricing below the mutation in Phase B.

### N1 — locality split surfaced the open/current index separation
- Strict locality moved the current-floor-index computation out of the monolithic floor block down to the redeem-deduction site, leaving the open-floor-index at the index-removal site. This is the intended "break down hidden scoped components" outcome: the two `floor_index_at_ms` replicas (L6) are now visibly separate, each at its point of use.

### N2 — deliberate cohesion kept (not split by locality)
- The replacement-identity trio (`replacement_quantity`, `has_replacement`, `resulting_order`) is kept together at the top of redeem even though `resulting_order` is first used inside the floor block. It is a domain object used across the function (floor math, liquidation, return), not a scalar intermediate locality is meant to surface.

### N3 — full enumeration: unconditional floor math is faithful because `floor_seed_amount() == 0` for 1x
- Both flows now compute the entire floor pipeline (open/current/terminal index, `floor_shares`, terminal/at-open floor amounts, redeem old/remaining/closed terms, `closed_floor_amount`) UNCONDITIONALLY — no `if (is_leveraged)` value-guards, no `let mut x = 0` defaults.
- Faithful because `order::floor_seed_amount()` is 0 for a 1x order: `user_contribution = ceil(exposure_value * FS / FS) = exposure_value`, so `seed = exposure_value - exposure_value = 0`. Seed 0 → `floor_shares = ceil(0*FS/index) = 0` → `terminal_floor = floor_at_open = 0`, exactly the reference's `floor_shares = if (is_leveraged) … else 0` cascade. The reference itself evaluates the floor indexes for 1x orders too (via `floor_amount_at_ms`), so unconditional index math adds no behavior and no new abort.
- The leveraged-only mint liquidation-threshold assert is preserved as a boolean short-circuit `!allocated_order.is_leveraged() || gross_value > threshold` (no scoped block), matching `assert_mint_above_liquidation_threshold`'s `if (!is_leveraged) return`.

### N4 — conditionals that REMAIN after full enumeration (intentional; not value-gating scopes)
- **Saturating-subtraction clamps** inside each floor-index computation (`if (ts >= expiry) 0 else expiry - ts`, `if (rem >= window) 0 else window - rem`) — faithful to `floor_index_at_ms`; replacing them (e.g. a `saturating_sub` helper) is a simplification, deferred.
- **`resulting_order = if (has_replacement) replacement(...) else *order`** and **`remaining_floor_seed_amount = if (has_replacement) resulting_order.floor_seed_amount() else 0`** — irreducible full-vs-partial-close value selection (for a full close `resulting_order` is the original order with a nonzero seed, but the remaining position is empty → seed 0).
- **`if (has_replacement) { liquidation.insert_order; next_order_sequence += 1 }`** — conditional STATE MUTATION (the replacement only exists for a partial close), not value computation.
- **mint boundary-cache guards `if (lower != neg_inf)` / `if (higher != pos_inf)`** — necessary: folding an `inf` sentinel into the finite min/max strike cache would corrupt it.

---

## Remaining flows — valuation / settled-close / liquidation / redeem-assert-fix (Phase A, batch 2)

These flows were inlined into `strike_exposure2.move` the same way as mint/redeem. New replicated-helper occurrences and a forced merge decision are logged below (continuing the L-numbering).

### L10 — merged-module abort codes share values (forced, faithful) — LOGGED
- **Where:** module error constants.
- **Faithful (original):** `strike_exposure_config` owns `ETerminalFloorExceedsLiquidationLtv = 0` / `EOrderBelowLiquidationThreshold = 1`; `strike_exposure` (a different module) owns `ESettledLiabilityNotMaterialized = 0` / `ESettledLiabilityUnderflow = 1`. Same numeric codes, distinguished by module.
- **Merge reality:** inlining both modules into one `strike_exposure2` collapses the two namespaces, so codes 0 and 1 each have two meanings. Move PERMITS duplicate constant values, so all four constants are declared with their original source values (`0,1,0,1`). This preserves byte-faithfulness — every inlined abort fires the exact code it fired in its source module — rather than renumbering the settled-liability codes.
- **Phase B:** once helpers are rebuilt as separate modules/functions, the duplication disappears naturally; no action needed beyond awareness that `strike_exposure2`'s 0/1 are overloaded.

### L11 — `floor_index_at_ms` recurs in every new flow (replicated helper) — LOGGED
- **Where:** valuation (current index at `now`); settled-close (open index at `opened_at`, plus the terminal-index constant); liquidation (open index at `opened_at` AND current index at `now`, plus terminal constant).
- **Observation:** the `remaining → elapsed → phase → phase² → premium → FS + premium` expansion (L6) is now inlined once per (expiry, timestamp) in five more places. Terminal index is always the constant `FS + max_premium` (L3); never expanded.
- **Phase B:** one `floor_index_at_ms(expiry, timestamp)` helper; terminal index stays the constant.

### L12 — `order_index_update_terms` recurs in settled-close, liquidation, and redeem (replicated helper) — LOGGED
- **Where:** settled-close (`settled_order_payout` → terminal payout only); liquidation (full triple); redeem (old order + remaining order).
- **Observation:** the `seed → floor_shares → {terminal_floor (+ LTV assert), floor_at_open} → {terminal_payout, live_backing_payout}` derivation is inlined per order. Settled-close needs only `terminal_payout`, so `floor_at_open`/`live_backing_payout` are omitted there (they have no abort, so omission is faithful and avoids unused-binding warnings). Liquidation and redeem need all terms.
- **Assert fidelity (IMPORTANT):** `order_index_update_terms` contains `assert!(terminal_floor < floor(quantity·ltv/FS), ETerminalFloorExceedsLiquidationLtv)`. This assert is reproduced everywhere the helper is inlined. After the scoped-block breakdown (see N5), the gated cases are expressed as boolean short-circuits, not multi-statement branches:
  - settled-close: short-circuit `!in_range || terminal_floor < max` (the reference reaches the assert only when `settlement > lower && settlement <= higher`).
  - liquidation: short-circuit `!should_liquidate || terminal_floor < max` (the reference reaches the assert only after the `should_liquidate` gate).
  - redeem old order: unconditional (always present).
  - redeem remaining order: guarded `!has_replacement || terminal_floor < max` — a full close has `replacement_quantity == 0 → max_terminal_floor == 0`, and an unguarded `0 < 0` would spuriously abort; the guard mirrors the reference not calling the helper for an absent remaining position.
  - mint: unconditional (the new order is always present).
- **Phase B:** one helper returning `(floor_shares, terminal_payout, live_backing_payout)` (or a subset) that performs the LTV assert; callers select which outputs they need.

### L13 — `order_boundaries` recurs in settled-close and liquidation (replicated helper) — LOGGED
- **Where:** settled-close; liquidation loop body.
- **Observation:** `(grid.boundary_at_index(order.lower_boundary_index()), grid.boundary_at_index(order.higher_boundary_index()))` inlined as two `let`s (tuple literal → individual lets).
- **Phase B:** one `order_boundaries(grid, order)` helper.

### L14 — `liquidation_check_terms` inlined; `current_floor_shares` ≡ `floor_shares` unified — LOGGED (replicated helper)
- **Where:** liquidation loop body.
- **Faithful (original):** `liquidation_check_terms` computes `current_floor_shares = floor_shares_for_seed(...)` then `current_floor_amount = floor_amount_at_ms(..., now)`, and `order_index_update_terms` separately computes `floor_shares = floor_shares_for_seed(...)` — the SAME value (same seed, same open index), computed twice across the two reference helpers.
- **Inlined form:** `open_floor_index` and `floor_shares` are computed ONCE (before the `should_liquidate` gate, where `current_floor_amount` needs them) and reused after the gate for `terminal_floor`/`floor_at_open`. This is value-identical to the reference (the two `floor_shares_for_seed` calls return the same number) and matches the redeem template's compute-index-once convention. NOT a behavioral simplification — same arithmetic, same rounding.
- **Phase B:** one `floor_shares_for_seed` call feeding both the liquidation check and the index-update terms.

### L15 — `settled_order_payout` inlined (private helper) — LOGGED (replicated helper)
- **Where:** settled-close.
- **Observation:** `order_boundaries` + the `settlement > lower && settlement <= higher` in-range test + `order_index_update_terms` terminal payout, expressed as `let user_payout = if (in_range) { …; quantity - terminal_floor } else { 0 };`. The in-range block legitimately holds the LTV assert (gates an abort), so it is a block, not a value-only conditional.
- **Phase B:** one `settled_order_payout(grid, order, expiry, config, settlement)` helper.

### L16 — `minted_strike_range` inlined (private helper) — LOGGED (replicated helper)
- **Where:** valuation.
- **Observation:** `if (min > max) (0,0) else (min,max)` inlined as `is_empty_book` + two conditional `let`s + the early `return 0`. The empty-book sentinel (fresh book has `min = max_u64`, `max = 0`) is the only way both come out 0, since real finite strikes are `> 0`.
- **Phase B:** one `minted_strike_range(live)` helper (or fold the empty-book early-return into the valuation entry).

### L17 — dead-check removal candidates: `order_index_update_terms` LTV re-assert on already-minted orders — LOGGED (dead-check candidate)
- **Where:** settled-close (settled order), liquidation (candidate order), redeem (OLD order).
- **Observation:** in all three, the order was admitted at mint time, where the SAME assert `terminal_floor < floor(quantity·ltv/FS)` already passed. `terminal_floor` and `max_terminal_floor` are deterministic functions of the order's IMMUTABLE fields (seed, opened_at, quantity, leverage) and the per-exposure SNAPSHOTTED config (`max_expiry_floor_premium`, `liquidation_ltv`). None of those change after mint, so the re-assert is provably always-pass — a dead check.
- **NOT dead:** the MINT assert (new order) and the redeem REMAINING-order assert (a newly-created replacement with smaller quantity; rounding at small quantities can break the strict inequality, so it is a genuine admission check on a never-before-checked order).
- **Kept in faithful baseline** (abort fidelity); flagged here for Phase B to drop the three always-pass re-asserts while keeping mint + redeem-remaining.

### N5 — scoped value-gating blocks broken down to flat compute + short-circuit assert + gated side-effects — APPLIED (structure)
- **Where:** close_settled_order (the `if (in_range) { … }` block) and liquidate_live_orders (the `if (should_liquidate) { … }` block).
- **Problem:** the first inline of both wrapped the whole `order_index_update_terms` derivation (value computation + LTV assert) inside the conditional, mirroring the reference's *call-site* gating (the helper is only *called* in-range / post-gate). That is a scoped value-gating block — the pattern Rule 3 says to break down.
- **Breakdown (faithful):** hoist the floor pipeline to the top level (computed unconditionally — faithful because the math has no abort and `floor_seed_amount()==0` for 1x); express the LTV abort as a boolean short-circuit (`!in_range || …`, `!should_liquidate || …`); reduce the conditional value to a single expression (`let user_payout = if (in_range) quantity - terminal_floor else 0`); and keep ONLY genuine side-effects gated (liquidation's `if (should_liquidate) { remove_range×2; mark_liquidated; emit; count++ }`; settled-close has no gated side-effect — `decrease`/`remove_order` were already unconditional).
- **Why byte-identical:** on the false path the reference runs neither the floor math nor the assert; the flat form runs the floor math (pure, no abort) and short-circuits the assert (no abort) — same observable result (no abort, no mutation, value 0 / count unchanged). On the true path both are identical. Verified by re-derivation + an adversarial re-audit of both functions.
- This matches the canonical mint template, which is already flat with short-circuit asserts (`!is_leveraged || gross_value > threshold`).
