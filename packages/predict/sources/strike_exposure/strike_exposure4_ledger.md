# strike_exposure4 — Maximal-Simplification Ledger (Phase C)

**Purpose.** `strike_exposure4.move` is the **maximally-simplified** twin of the
sequenced enumeration in `strike_exposure3.move`. Where `strike_exposure3` stayed
exactly faithful to `strike_exposure.move`'s arithmetic (only behavior-preserving
reorders + the one provably-dead assert removed), this phase **applies the
behavior-touching collapses** that v2/v3 only logged (the floor round-trips, D1/D2
in `strike_exposure3_ledger.md` §5). v4 is therefore **no longer byte-faithful** to
`strike_exposure.move`. It preserves the **semantic contract**:

- same set of aborts + the same error codes,
- same validate-before-mutate ordering (pricing/oracle/grid gates before any index
  or liquidation mutation; events after the state transition),
- payouts/thresholds **identical modulo the documented ≤2-ulp rounding** below.

Every divergence is recorded here with before/after and magnitude.

**Two new things vs v3:** (0) the trading fee is extracted to a separate `trading_fee`
read function (relay extraction); (1) the seed→shares→amount round-trips are collapsed.

**Conventions.** `FS` = `constants::float_scaling!()`. `window` =
`constants::leverage_floor_window_ms!()`. `mp` = `config.max_expiry_floor_premium()`.
`ltv` = `config.liquidation_ltv()`. `seed` = `order.floor_seed_amount()` (== 0 for a
1x order). `oi` = open floor index `floor_index_at_ms(expiry, opened_at)`. `ci` =
current floor index `floor_index_at_ms(expiry, now)`. `tfi` = terminal floor index =
`FS + mp` (constant, see v3 §1). `ceil(a*b/c)` = `predict_math::mul_div_round_up(a,b,c)`;
`a*b/c` = `predict_math::mul_div_round_down(a,b,c)`.

---

## 0. Relay extraction — fee → `trading_fee` — APPLIED

**Relay test.** A value belongs inside a flow iff computing it needs strike_exposure's
own model (floor schedule / NAV / payout / positions / liquidation) OR it feeds a
mutation. `fee_amount` (mint and redeem) is pure relay: it is `fee_rate(price) *
quantity`, needs none of the exposure model, and no index/field consumes it.
(Contrast: `redeem_amount` needs the floor deduction → stays; `user_payout` feeds the
settled-liability decrement → stays.)

**`trading_fee` (new read fn).**
```
public(package) fun trading_fee(
    exposure: &StrikeExposure,
    config: &PricingConfig,
    market: &MarketOracle,
    price: u64,
    quantity: u64,
    clock: &Clock,
): u64 = math::mul(
    pricing::fee_rate(config, market, exposure.expiry_fee_window_ms,
                      exposure.expiry_fee_max_multiplier, price, clock),
    quantity)
```
Reads `expiry_fee_window_ms` / `expiry_fee_max_multiplier` off the struct (they stay
on the struct). Takes `price` as a parameter (the per-trade probability) — no `pyth`,
because `fee_rate` does not consult the oracle, only config + `market.expiry()` +
clock + the probability. Returns the **uncapped raw fee**.

**Mint gate retained.** `assert_mint_fee_rate` does two things: (a) asserts the all-in
ask price is in bounds (`EAskPriceOutOfBounds`) and (b) yields the rate. The gate (a)
is a mint precondition that must run **before** the index mutation, so it stays inside
`allocate_mint_order` — called for its assert side-effect, return value discarded.
Only the fee *value* leaves. Mint stops returning `fee_amount`: `(Order, u64)` →
`(Order)`.

**Redeem recovery decision — redeem RETURNS THE LIVE PRICE.**
- Asymmetry: mint's price is stamped on the returned `Order`
  (`order.entry_probability()` is a lossless u32 decode of the exact `entry_probability`
  passed at mint — verified in `order.move`), so a caller recomputes the mint fee with
  `trading_fee(exposure, config, market, order.entry_probability(), order.quantity(),
  clock)` — **no oracle re-pricing**, exact.
- Redeem's live `range_probability` is **not** on any order (`resulting_order` carries
  the order's original *mint* probability, not the current redeem price). So the caller
  cannot recover it from the return.
- **Decision: redeem returns `range_probability`** as its 3rd value, replacing
  `fee_amount`: `(Order, u64 redeem_amount, u64 fee_amount)` →
  `(Order, u64 redeem_amount, u64 range_probability)`. The caller then computes the fee
  with `trading_fee(...).min(redeem_amount)` (the `.min(redeem_amount)` cap — which mixes
  the relay fee with the domain `redeem_amount` — moves to the caller, who has both
  returned values).
- **Justification.** `range_probability` is the product of an expensive SVI pricing pass
  (`live_inputs` → oracle/pyth resolution + `compute_range_price` → 2× `compute_nd2`),
  which the redeem flow already computes once (load-bearing for `redeem_amount`). The
  repo convention (move.md "Keep Return Tuples Small and Semantic") explicitly allows
  returning "values that must be sampled once because the calculation is expensive or
  must remain identical across multiple operations in the same local flow" — the fee
  must be priced at the *same* `range_probability` used for `redeem_amount` (so the cap
  is self-consistent). The alternative (`trading_fee` re-prices) repeats the whole
  oracle+SVI pass for no gain. Return arity is unchanged (was already a 3-tuple), so this
  is strictly a win: a relay computation leaves the flow and the caller still gets an
  exact fee.

---

## 1. Canonical collapse spec (CC1–CC3) — the SHARED contract, applied identically in every flow

`floor_shares = ceil(seed*FS/oi)` is a **real NAV sink** (`nav.insert_range`/`remove_range`
store/remove it), so it is **never collapsed** — it stays `ceil(seed*FS/oi)` in mint,
redeem, and liquidation (and is *absent* in settled-close, which has no NAV sink). Only
the **derived amounts** below collapse. Because v4 owns all flows in one file, the same
collapsed formula is used at insert (mint) and at remove (redeem/liquidation), so every
index stays **balanced** (insert value == remove value); only the comparison vs the
*original* double-rounded `strike_exposure.move` shifts, by the bounded amount noted.

### CC1 — `floor_at_open` collapses to `seed` (round-trip elimination)
- **Faithful:** `floor_at_open = ceil(floor_shares*oi/FS)` = `ceil(ceil(seed*FS/oi)*oi/FS)`
  (double round-up; `>= seed`).
- **Collapsed:** `floor_at_open = seed` (in exact arithmetic `floor_shares*oi/FS = seed`;
  the round-trip only inflates by rounding).
- **Consumers:** `live_backing_payout = quantity - seed` (was `quantity - floor_at_open`);
  mint `liquidation_threshold_at_open = ceil(seed*FS/ltv)` (was `ceil(floor_at_open*FS/ltv)`).
- **Magnitude:** `floor_at_open_faithful - seed ∈ {0,1,2}` (bound: `oi/FS ∈ [1, 2]` over the
  admissible `mp ∈ [0, FS]` — `max_expiry_floor_premium` is admin-tunable up to `FS` per
  `config_constants::max_max_expiry_floor_premium!()`; `0.2*FS` is only the default — so the two
  ceils inflate by `< oi/FS + 1 < 3`, i.e. `≤ 2`; confirmed by a 6M-sample sweep over the full
  `mp` range). So collapsed
  `live_backing_payout` is **larger by 0..2 ulp** (more conservative backing). The mint
  `liquidation_threshold_at_open = ceil(seed*FS/ltv)` is **smaller by 0..4 ulp** (admission
  slightly more permissive): the 0..2 ulp `floor_at_open` inflation is amplified by the
  threshold's own `FS/ltv ≥ 1` round-up (`ceil(FS/ltv) = 2` at `ltv ≈ 0.6*FS`), so the gap
  reaches 4 — verified by sweep (worst case seed≈9.17e11, oi≈1.229e9, ltv≈6.18e8 → gap 4).
  Direction is preserved (always more permissive). 1x orders: `seed = 0` → both forms 0,
  **zero delta**.

### CC2 — `terminal_floor` collapses to a single round-up from `seed`
- **Faithful:** `terminal_floor = ceil(floor_shares*tfi/FS)` = `ceil(ceil(seed*FS/oi)*tfi/FS)`
  (double round-up).
- **Collapsed:** `terminal_floor = ceil(seed*tfi/oi)` (single round-up; `<= faithful`).
- **Consumers:** `terminal_payout = quantity - terminal_floor`; mint + redeem-replacement
  LTV admission assert `terminal_floor < max_terminal_floor`.
- **Magnitude:** `terminal_floor_faithful - terminal_floor_collapsed ∈ {0,1,2}` (same bound
  with `tfi/FS ∈ [1, 2]` over the admissible `mp ∈ [0, FS]`). So collapsed `terminal_payout` is
  **larger by 0..2 ulp**;
  the LTV assert is **more permissive by 0..2 ulp** (collapsed `terminal_floor` is
  smaller). 1x orders: `seed = 0` → both forms 0, **zero delta**.

### CC3 — liquidation `current_floor_amount` collapses to a single round-up from `seed`
- **Faithful:** `current_floor_amount = ceil(floor_shares*ci/FS)` = `ceil(ceil(seed*FS/oi)*ci/FS)`.
- **Collapsed:** `current_floor_amount = ceil(seed*ci/oi)` (single round-up; `<= faithful`).
- **Consumers (liquidation only):** `liquidation_threshold = ceil(current_floor_amount*FS/ltv)`
  → `should_liquidate = !(gross_value > liquidation_threshold)`; and the emitted
  `emit_order_liquidated(... current_floor_amount ...)` event field.
- **Not a NAV/payout sink** — affects only the liquidation control boundary + the event,
  never index balance.
- **Magnitude:** `current_floor_amount` **smaller by 0..2 ulp** → `liquidation_threshold =
  ceil(current_floor_amount*FS/ltv)` **smaller by 0..4 ulp** (the `FS/ltv ≥ 1` round-up
  amplifies the 0..2 ulp gap, same as CC1's threshold) → `should_liquidate = !(gross_value >
  liquidation_threshold)` boundary shifts by ≤4 ulp (a smaller threshold makes liquidation
  very slightly LESS likely at the exact edge); the emitted `current_floor_amount` event field
  is smaller by ≤2 ulp. 1x candidates do not exist (candidates are always leveraged), but
  `seed = 0` would give zero delta.

**NOT collapsed — redeem `closed_floor_amount`.** Redeem's current floor is
`ceil(closed_floor_shares*ci/FS)` where `closed_floor_shares = old_floor_shares -
remaining_floor_shares` is the **real NAV delta removed** (a difference of two stored
share counts, not a seed round-trip). It is already a single round-up over the exact
removed shares and cannot be re-expressed from a seed (share counts don't subtract
linearly through `ceil`). Left exactly as in v3.

### Cross-flow balance — CC1/CC2 must be applied to ALL four floor-touching flows together
`terminal_payout = quantity - terminal_floor` (CC2) and `live_backing_payout = quantity -
seed` (CC1) are **stored** in the payout tree at mint and **removed** at redeem/liquidation;
`materialize_settled_liability` reads the tree's aggregated `terminal_payout`, and
`close_settled_order` pays one order's `terminal_payout`. Balance (insert value == remove
value == settled payout) holds **only when mint, redeem, liquidation, and settled-close all
use the identical CC1/CC2 formula.** Therefore the four floor-touching transforms **T1–T4
are not independently landable** — any intermediate state where only some are collapsed is
unbalanced (e.g. after T1 alone, settled-close pays a CC2 `terminal_payout` 0..2 ulp larger
than the faithful value mint still stores, which could trip `ESettledLiabilityUnderflow`).
This is expected and is the whole reason CC1/CC2 are a single shared spec; **the final
whole-module audit re-verifies insert==remove balance once T1–T4 are all collapsed.** The
per-flow audits below confirm each flow's *local* correctness (canonical CC formula, aborts,
sink-minimality); cross-flow balance is a T1–T4-joint property checked at the end.

---

## 2. Per-flow restructuring + audit-fixpoint log

<!-- Each transform appends its flow's sink map, the collapses it applied (referencing
     CC1/CC2/CC3), every dead/cyclic/recreated/synthetic elimination, and the audit-panel
     fixpoint outcome (what each of the 4 lenses caught and how it was resolved). -->

### T0 — fee relay (`trading_fee`, mint, redeem)

**`trading_fee` (new read fn).** Added immediately after `valuation_liability`, before
`is_liquidated_order`. Pure relay `math::mul(pricing::fee_rate(config, market,
expiry_fee_window_ms, expiry_fee_max_multiplier, price, clock), quantity)`. Reads the
two fee fields off the struct; takes `price` (the per-trade probability) as a param (no
`pyth` — `fee_rate` does not consult the oracle). Returns the uncapped raw fee; the
`.min(redeem_amount)` cap is the redeem caller's job.

**Mint (`allocate_mint_order`).** Stopped computing/returning the fee. The
`let fee_amount = math::mul(assert_mint_fee_rate(...), quantity);` binding became a bare
`assert_mint_fee_rate(...);` call — the ask-price gate (`EAskPriceOutOfBounds`) is
**retained, assert-only**, return value discarded, kept before the index mutation. The
`assert_mint_leverage_tier` line above it is unchanged. Return shape `(Order, u64)` →
`Order`; tail `(allocated_order, fee_amount)` → `allocated_order`.

**Redeem (`close_and_quote_live_order`).** Deleted the `let fee_rate = fee_rate(...);`
binding (and dropped the fee sentence from the pricing-block comment). Tail now returns
the live price instead of the fee: `(resulting_order, redeem_amount, range_probability)`
(arity unchanged at `(Order, u64, u64)`). The caller recomputes the fee via
`trading_fee(..., range_probability, close_quantity, clock).min(redeem_amount)`.

**No abort dropped.** Removing the redeem `fee_rate` call drops no precondition:
`range_probability = pricing::live_range_probability(...)` runs first and already
enforces now < expiry + oracle freshness + market active before any mutation, so the
deleted `fee_rate` was not the gate for any of those. Build: PASS, no warnings (a bare
`assert_mint_fee_rate(...);` discarding a `u64` return is valid Move and does not warn).

### T1 — `close_settled_order`

**Sink map.** Settled-close touches NO NAV index. Two sinks only:
- `settled_payout_liability` decrement — fed by `user_payout` (the in-range terminal
  payout, else 0). Guarded by the two settled-liability asserts.
- liquidation tombstone removal (`liquidation.remove_order`) — fed by `order`.

There is no NAV/payout-index sink here, so no `floor_shares` term and no insert/remove
balance to keep symmetric.

**Collapses applied.**
- `floor_shares` **eliminated as dead-here.** `floor_shares = ceil(seed*FS/oi)` is purely
  a NAV-index term. Settled-close has no NAV sink, so it was the only consumer of
  `floor_shares` via the faithful chain `terminal_floor = ceil(floor_shares*tfi/FS)`. With
  no NAV sink the share count never reaches storage, so it is dropped entirely.
- **CC2 on `terminal_floor`** (ledger §1). The faithful double round-up
  `ceil(ceil(seed*FS/oi)*tfi/FS)` collapses to the single round-up
  `terminal_floor = ceil(seed * (FS + max_premium) / oi)` =
  `mul_div_round_up(floor_seed_amount, FS + max_premium, open_floor_index)`. Collapsed
  `<= faithful`, so in-range `user_payout = quantity - terminal_floor` is **larger by
  0..2 ulp** (more generous to the user). 1x orders: `seed = 0` → `terminal_floor = 0`,
  **zero delta**.

**Sink-first restructuring.** The whole floor pipeline (open floor-index schedule +
collapsed `terminal_floor`) is pushed INTO the `if (settlement > lower && settlement <=
higher)` branch — its only consumer. This matches the reference `settled_order_payout`
exactly (`if (in_range) { terminal_payout } else { 0 }`), where `order_index_update_terms`
is reached only in-range. The push is sound because the dead terminal-floor LTV re-assert
was already removed (v3 S1), so the floor pipeline has no abort and need not run on the
out-of-range path. An out-of-range settlement now pays 0 and runs no floor math at all.

**Validate-before-mutate preserved.** The two settled-liability asserts
(`ESettledLiabilityNotMaterialized`, `ESettledLiabilityUnderflow`) stay above the
`settled_payout_liability` write; the tombstone removal stays last. No LTV re-assert
reintroduced. Build: PASS, no warnings.

**Audit-fixpoint outcome (4 lenses).**
- *Dead/redundant:* CLEAN on core goal (floor_shares gone, no double-round, no dead
  locals). Flagged the inlined settled-liability decrement as "duplicates the standalone
  `decrease_materialized_settled_liability`" — **not actioned**: both are listed flows and
  v4's mandate is self-contained inlined flows (matches v3); the inline is intentional.
  The "seed=0 for 1x" note is kept for cross-flow symmetry.
- *Semantics/rounding:* verified the inlined `open_floor_index` exactly replicates
  `floor_index_at_ms`, CC2 collapsed ≤ faithful with gap ∈ {0,1,2} (confirmed by a 3M-sample
  sweep: max gap exactly 2), in-range condition `settlement > lower && settlement <= higher`
  matches the reference, push-into-branch is behavior-identical, aborts exactly
  `ESettledLiabilityNotMaterialized`/`ESettledLiabilityUnderflow`. Raised the cross-flow
  imbalance (T1-alone non-landable) — triaged as the expected T1–T4-joint property above.
- *Sink-minimality:* flagged the unnecessary `let grid = exposure.grid;` copy (no
  overlapping borrow — boundary reads release the grid borrow before the mutations) with a
  misleading copy-justification comment. **FIXED**: dropped the copy, read `exposure.grid`
  directly for both boundaries, corrected the comment.
- *Boundary/consistency:* confirmed settled-close mutates only its own field + the
  liquidation book (no stray index touch) and the terminal-floor formula is exactly the
  canonical CC2. Re-raised the cross-flow imbalance (same triage).

### T2 — `allocate_mint_order`

**Sink map.** Mint is the INSERT side of every floor-touching index:
- `payout.insert_range` ← `terminal_payout` (= `quantity - terminal_floor`, CC2) +
  `live_backing_payout` (= `quantity - seed`, CC1).
- `nav.insert_range` ← `floor_shares` (= `ceil(seed*FS/oi)`, the NAV share count — the only
  surviving floor-share term).
- minted-strike cache (`minted_min_strike`/`minted_max_strike`) ← `lower`/`higher` boundaries
  (untouched, below the region).
- `liquidation.insert_order` ← `allocated_order` (untouched, below the region).
- `next_order_sequence` increment (untouched); return `allocated_order` (untouched).

**Collapses applied.**
- **CC2 on `terminal_floor`** (ledger §1). Was `floor_shares = ceil(seed*FS/oi)` then
  `terminal_floor = ceil(floor_shares*(FS+mp)/FS)` (double round-up). Collapsed to the single
  round-up `terminal_floor = ceil(seed*(FS+mp)/oi)` =
  `mul_div_round_up(floor_seed_amount, FS + max_premium, open_floor_index)`. Collapsed `<=`
  faithful, so `terminal_payout = quantity - terminal_floor` is **larger by 0..2 ulp** and the
  terminal-floor LTV admission `terminal_floor < max_terminal_floor` is **more permissive by
  0..2 ulp**.
- **CC1 eliminating `floor_at_open`** (ledger §1). The `floor_at_open = ceil(floor_shares*oi/FS)`
  variable is **gone**; the faithful round-trip collapses to the seed itself. Its two consumers
  now read `floor_seed_amount` directly: `live_backing_payout = quantity - seed` (**larger by
  0..2 ulp**, more conservative backing) and `liquidation_threshold_at_open = ceil(seed*FS/ltv)`
  (**smaller by 0..4 ulp**, admission slightly more permissive — the threshold's `FS/ltv ≥ 1`
  round-up amplifies the 0..2 ulp floor-at-open gap; see §1 CC1).
- **`floor_shares` kept, pushed to its NAV sink.** It stays `ceil(seed*FS/oi)` (unchanged
  formula) because it is the real NAV term inserted into the matrix. After CC1/CC2 it no longer
  feeds `terminal_floor` or `floor_at_open`, so it is now single-use; its computation is pushed
  down to immediately before `nav.insert_range` (sink-first).

**Eliminations.**
- `floor_at_open` variable — gone (CC1 → seed).
- `terminal_floor_index` binding (`FS + max_premium`) — inlined into the CC2 `terminal_floor`
  round-up.

**Validate-before-mutate preserved.** The three mint asserts stay in order, all before any index
mutation: `EOrderPrincipalBelowMinimum` (above the region), then
`ETerminalFloorExceedsLiquidationLtv` (terminal-floor LTV cap), then
`EOrderBelowLiquidationThreshold` (leveraged-only at-open threshold). The ask-price gate
(`EAskPriceOutOfBounds`, via `assert_mint_fee_rate`) is above and untouched.

**Cross-flow balance.** Mint is the INSERT side of the payout/NAV indexes; its CC1/CC2
`terminal_payout`/`live_backing_payout` values must match the REMOVE side computed at redeem
(T3) and liquidation (T4), and the `terminal_payout` it stores must match the value
settled-close (T1) pays out. The identical CC1/CC2 formulas in all four flows keep insert ==
remove == settled payout (re-verified in the final whole-module audit). 1x orders: `seed = 0`
→ all floor terms 0 → zero delta.

**Audit-fixpoint outcome (4 lenses).**
- *Dead/redundant:* CLEAN — `floor_at_open` fully gone, `terminal_floor` single-round, no dead
  locals, `floor_seed_amount`/`open_floor_index`/`liquidation_ltv` each bound once and reused.
- *Semantics/rounding:* CLEAN on correctness (8M-sample sweeps confirmed CC2 collapsed ≤ faithful
  gap ≤2, `floor_shares` byte-identical to `floor_shares_for_seed`, all aborts in order before
  mutation, 1x trivial). One doc correction: the at-open threshold CC1 gap is **≤4 ulp**, not ≤2
  — fixed in §1 CC1 and above.
- *Sink-minimality:* flagged that pushing `floor_shares` between the two inserts forced five
  `exposure.live.borrow_mut()` calls vs the reference's single `let live` borrow. **FIXED**:
  hoisted `floor_shares` into the gather block and bound `live` once, reused for both inserts +
  the minted-strike cache (matches the reference `insert_live_order` shape; behavior-identical,
  build green).
- *Cross-flow consistency:* CLEAN — confirmed mint's three stored formulas are the exact
  canonical CC forms (`floor_shares = ceil(seed*FS/oi)`, `terminal_payout = quantity -
  ceil(seed*(FS+mp)/oi)`, `live_backing = quantity - seed`), and `open_floor_index` is from the
  order's own stamped `opened_at_ms` (reproducible at remove time). Re-flagged that the remove
  side (T3/T4) still holds the faithful double-round — the expected intermediate state, resolved
  by T3/T4.

### T3 — `close_and_quote_live_order`

**Sink map.** Redeem is the REMOVE side of every floor-touching index, plus the redeem quote:
- `payout.remove_range` ← `closed_terminal_payout` + `closed_live_backing_payout` (the
  old-order contribution minus what the replacement keeps).
- `nav.remove_range` ← `close_quantity` + `closed_floor_shares` (the NAV share count actually
  removed from the matrix).
- liquidation book: `remove_order(order)` always; on a partial close, `insert_order(resulting_order)`
  and `next_order_sequence += 1`.
- redeem quote: current floor index (`floor_index_at_ms(expiry, now)`, inlined) →
  `closed_floor_amount = ceil(closed_floor_shares * ci / FS)` → `redeem_amount =
  gross_redeem_amount - min(gross_redeem_amount, closed_floor_amount)` where
  `gross_redeem_amount = range_probability * close_quantity`.
- return `(resulting_order, redeem_amount, range_probability)` (the live price replaces the fee,
  ledger §0/T0; arity unchanged).

**Collapses applied.**
- **CC2 on `terminal_floor`** (ledger §1), applied to BOTH orders. Was `floor_shares =
  ceil(seed*FS/oi)` then `terminal_floor = ceil(floor_shares*tfi/FS)` (double round-up).
  Collapsed to the single round-up `terminal_floor = ceil(seed*tfi/oi)` =
  `mul_div_round_up(floor_seed_amount, terminal_floor_index, open_floor_index)` for the old
  order, and the same from `remaining_floor_seed_amount` for the replacement. Collapsed `<=`
  faithful, so each `terminal_payout = quantity - terminal_floor` is **larger by 0..2 ulp** and
  the replacement LTV admission is **more permissive by 0..2 ulp**.
- **CC1 eliminating `floor_at_open`** (ledger §1), applied to BOTH orders. The
  `old_floor_at_open`/`remaining_floor_at_open = ceil(floor_shares*oi/FS)` variables are **gone**;
  the faithful round-trip collapses to the seed itself. Live backing now reads the seed directly:
  `old_live_backing_payout = old_quantity - old_floor_seed_amount` and
  `remaining_live_backing_payout = replacement_quantity - remaining_floor_seed_amount`
  (**larger by 0..2 ulp**, more conservative backing). No at-open liquidation threshold exists in
  redeem (that consumer is mint-only), so no 0..4 ulp threshold gap here.
- **`floor_shares` kept unchanged** (`ceil(seed*FS/oi)`) for both orders. It is the real NAV term
  removed from the matrix, so it must match what mint inserted; it feeds `closed_floor_shares =
  old_floor_shares - remaining_floor_shares` (the NAV remove delta, also consumed by
  `closed_floor_amount` in the redeem quote). `terminal_floor_index` (`FS + max_premium`) stays a
  named binding — used by both orders' collapsed terminal floor (2 uses).

**Eliminations.**
- `old_floor_at_open` variable — gone (CC1 → seed).
- `remaining_floor_at_open` variable — gone (CC1 → seed).

**Replacement LTV assert kept (guarded, NOT dead).** The one `ETerminalFloorExceedsLiquidationLtv`
assert — `!has_replacement || remaining_terminal_floor < remaining_max_terminal_floor` — is
retained. The replacement is a newly created order that has never been admitted, so on a rounding
edge it can genuinely fire; it is not dead (unlike the old-order LTV assert, already removed in v3
S1). The `!has_replacement` disjunct guards a full close so it does not abort on `0 < 0`. No
old-order LTV assert is reintroduced.

**Closed-delta no-underflow.** The three subtractions (`old_floor_shares -
remaining_floor_shares`, `old_terminal_payout - remaining_terminal_payout`,
`old_live_backing_payout - remaining_live_backing_payout`) all stay `>= 0`. The mint LTV admission
keeps each order's per-unit terminal floor below `ltv/FS < 1`, and the seed is 1-Lipschitz in
quantity, so for each term `(old term - remaining term) <= close_quantity` and the difference does
not underflow. This is guaranteed by the admission margin (verified separately); no runtime guard
is added.

**Cross-flow balance.** Redeem's CC1/CC2 `closed_terminal_payout`/`closed_live_backing_payout`
remove exactly the value mint (T2) inserted under the identical CC1/CC2 formulas, and
`closed_floor_shares` removes exactly the `floor_shares` mint stored — so the payout and NAV
indexes stay balanced (insert == remove). 1x orders: `seed = 0` → every floor term 0 → zero delta.

**Audit-fixpoint outcome (4 lenses).**
- *Dead/redundant:* CLEAN — both `floor_at_open` variables gone, both terminal floors single-round,
  no dead locals, `has_replacement`/`if (has_replacement) … else 0` confirmed irreducible (guards
  `order::replacement`'s full-close abort). One declined nit: `max_expiry_floor_premium()` is read
  3× (the two inlined `floor_index_at_ms` pipelines + `terminal_floor_index`). **Not hoisted** —
  it's a cheap immutable getter, every flow (T2/settled/liquidation/valuation) reads it directly
  inside each inlined floor pipeline, and binding it once would begin to dedup the floor pipeline,
  which the task puts explicitly out of scope ("do not extract the repeated floor pipeline").
  Keeping the direct reads preserves cross-flow consistency and per-pipeline faithfulness.
- *Semantics/underflow:* CLEAN — a 124,645-case sweep (all leverage tiers honoring mint-tier rules,
  premia 0..1.0·FS, ltv∈{0.5,0.85,0.95}, quantities to 4e9 lots, every close fraction) found **0
  underflow violations**; worst `(old_tf-remaining_tf)/close_quantity = 0.9232 < 1`, margin 768 ≫
  the ≤2-ulp CC shift. CC1/CC2 ≤2-ulp confirmed; the old-order LTV assert is correctly absent; the
  unchanged tail (`closed_floor_amount`/`redeem_amount`/`range_probability`) verified.
- *Sink-minimality:* CLEAN — old/remaining/closed structure minimal, `terminal_floor_index` named
  (2 uses), `open_floor_index` shared (4 uses), the live-price gate's def→use gap is the intended
  validate-before-mutate pin, the current-floor pipeline correctly sits after the mutation, the
  `grid` copy is load-bearing.
- *Cross-flow consistency:* CLEAN — confirmed redeem's `old_floor_shares`/`old_terminal_payout`/
  `old_live_backing_payout` are byte-identical to mint's stored values for the same order (same
  seed, same `open_floor_index` from the stamped `opened_at_ms`, same divisors/rounding), and the
  replacement's retained `remaining_X` will match what a future flow recomputes (`order::replacement`
  inherits `opened_at_ms`/leverage/entry_probability) — so partial closes rebalance and full closes
  zero out.

### T4 — `liquidate_live_orders`

**Sink map.** Liquidation is the REMOVE side of every floor-touching index, gated on
`should_liquidate`. Inside the `if (should_liquidate)` branch only:
- `payout.remove_range` ← `terminal_payout` (= `quantity - terminal_floor`, CC2) +
  `live_backing_payout` (= `quantity - seed`, CC1).
- `nav.remove_range` ← `quantity` + `floor_shares` (= `ceil(seed*FS/oi)`, the NAV share
  count actually removed from the matrix).
- `liquidation.mark_liquidated(order)` (tombstone the candidate).
- `order_events::emit_order_liquidated(... gross_value, current_floor_amount, ltv)` —
  emitted AFTER the removals, inside the gated block.
- `liquidated_count += 1`.

The CHECK terms (`current_floor_amount`, `liquidation_threshold`, `gross_value`,
`should_liquidate`, `liquidation_ltv`) stay BEFORE the `if` — they gate it / feed the event.

**Collapses applied.**
- **CC3 on `current_floor_amount`** (ledger §1). Was `floor_shares = ceil(seed*FS/oi)` then
  `current_floor_amount = ceil(floor_shares*ci/FS)` (double round-up). Collapsed to the single
  round-up `current_floor_amount = ceil(seed*ci/oi)` =
  `mul_div_round_up(floor_seed_amount, current_floor_index, open_floor_index)`. It is NOT an
  index term — it feeds only `liquidation_threshold` (→ `should_liquidate` gate) and the
  emitted `current_floor_amount` event field — so its collapse never touches index balance.
- **CC2 on `terminal_floor`** (ledger §1). Collapsed to the single round-up
  `terminal_floor = ceil(seed*(FS+mp)/oi)` =
  `mul_div_round_up(floor_seed_amount, FS + max_premium, open_floor_index)`. `FS + mp` is
  inlined (single use here — the `terminal_floor_index` binding is dropped). `terminal_payout
  = quantity - terminal_floor` is **larger by 0..2 ulp**.
- **CC1 eliminating `floor_at_open`** (ledger §1). The `floor_at_open =
  ceil(floor_shares*oi/FS)` variable is **gone**; `live_backing_payout = quantity - seed`
  reads `floor_seed_amount` directly (**larger by 0..2 ulp**, more conservative backing).
- **`floor_shares` kept** (`ceil(seed*FS/oi)`, unchanged formula). After CC3 it no longer
  feeds `current_floor_amount`, so it is now used ONLY by `nav.remove_range` — moved inside
  the gated branch with its sole sink.

**Sink-first move.** The order-index-update terms (`terminal_floor`, `terminal_payout`,
`live_backing_payout`, `floor_shares`) are pushed INSIDE the `if (should_liquidate)` branch.
This is the **v4 reversal of v3's N5 flat-compute**: with the dead terminal-floor LTV assert
already removed (v3 S1), these terms have no abort and feed only the gated mutation, so they
match the reference's post-gate `order_index_update_terms` (reached only after the
`should_liquidate` gate in `liquidate_candidate_if_under_floor`). A non-liquidated candidate
now runs no update-term math.

**Eliminations.**
- `floor_at_open` variable — gone (CC1 → seed).
- `terminal_floor_index` binding (`FS + max_premium`) — inlined into the CC2 `terminal_floor`
  round-up (single use).
- `floor_shares` — no longer in the check block (CC3 removed its only check-side consumer);
  now computed inside the gated branch at its `nav.remove_range` sink.

**CC3 threshold magnitude.** `current_floor_amount` is **smaller by 0..2 ulp** (single vs
double round-up). This amplifies through `liquidation_threshold = ceil(current_floor_amount *
FS / ltv)` whose own `FS/ltv ≥ 1` round-up widens the gap, so `liquidation_threshold` is
**smaller by 0..4 ulp** → `should_liquidate = !(gross_value > liquidation_threshold)` boundary
shifts by ≤ a few ulp (very slightly less likely to liquidate at the exact edge); the emitted
`current_floor_amount` event field is smaller by 0..2 ulp.

**Validate-before-mutate preserved.** `compute_range_price` (range validation, above the
region) + the full `should_liquidate` computation precede the gated `remove_range`. No LTV
re-assert reintroduced (the dead old-order LTV assert was already removed in v3 S1; candidates
are admitted orders, so it is provably dead). The event is emitted AFTER the removals, inside
the gated block.

**Cross-flow balance.** Liquidation's CC1/CC2 `terminal_payout`/`live_backing_payout` remove
exactly the value mint (T2) inserted under the identical CC1/CC2 formulas, and `floor_shares`
removes exactly the `floor_shares` mint stored (same seed, same `open_floor_index` from the
stamped `opened_at_ms`, same divisors/rounding) — so the payout and NAV indexes stay balanced
(insert == remove). CC3 `current_floor_amount` is gate+event only, not an index term, so it
does not enter the balance. Candidates are leveraged so seed > 0; a hypothetical 1x would give
zero delta.

**Audit-fixpoint outcome (4 lenses).**
- *Dead/redundant:* CLEAN on the collapse (floor_at_open gone, CC3/CC2 single-round, floor_shares
  only in the gated block, no dead locals, no stale comments). Same declined nit as T3:
  `max_expiry_floor_premium()` read 3× per iteration — **not hoisted** (pre-existing module-wide
  inline-getter style, matching how `float_scaling!()`/`leverage_floor_window_ms!()` macros are
  read inline everywhere; cheap immutable getter; binding it would dedup the floor pipeline = out
  of scope).
- *Semantics/aborts:* CLEAN — 3M-sample sweep confirmed CC3 collapsed ≤ faithful gap ≤2, 0
  violations; `should_liquidate` direction matches `above_liquidation_threshold` (collapsed
  threshold ≤ faithful → liquidation strictly less likely at the edge by ≤4 ulp); no LTV assert
  reintroduced; only `compute_range_price` aborts (before the gated removal); event emitted after
  both removals; sink-first (terms inside the branch) is behavior-identical to the reference's
  post-gate `order_index_update_terms`; candidate-selection-before-live_inputs + empty early-return
  unchanged.
- *Sink-minimality + cross-flow consistency:* CLEAN — index-removal terms correctly inside the
  gated branch, check/event-shared terms (`current_floor_amount`/`gross_value`/`liquidation_ltv`)
  computed once before it and reused, single `live` borrow, loop-invariant `grid` copy hoisted
  out of the loop. Removal byte-matches mint's insert: `floor_shares`/`terminal_payout`/
  `live_backing_payout` identical (same seed, same `open_floor_index` from the order's stamped
  `opened_at_ms`, same divisors/rounding); `current_floor_amount` (CC3) appears only in the
  threshold + event, never in `remove_range`, so it cannot unbalance the index.

### T5 — `valuation_liability` + trivial flows

**`valuation_liability` (read; D2 applied — EXACT, not ≤ulp).** This read flow has no floor
round-trip (it uses `current_floor_index` directly in `nav.live_value`, not via shares), so no
CC1/CC2/CC3 applies. Its one simplification is **D2** — the empty-book guard:
- **Was (faithful triple):** `is_empty_book = min > max; minted_min = if (is_empty) 0 else min;
  minted_max = if (is_empty) 0 else max; if (minted_min == 0 && minted_max == 0) return 0`.
- **Now (D2 collapse):** `if (live.minted_min_strike > live.minted_max_strike) return 0;` then use
  `minted_min_strike`/`minted_max_strike` directly.
- **EXACT equivalence (proven, NOT a rounding divergence).** `strike_grid::new_centered` asserts
  `min_strike > 0` (`strike_grid.move:38`) and every finite strike is `min_strike + index·tick_size
  >= min_strike > 0`; mint records each finite boundary into BOTH `minted_min`/`minted_max`
  (`track_minted_boundaries`); the cache is monotonic (never shrinks on remove). So a non-empty book
  always has `0 < minted_min <= minted_max`, making `min > max` the empty sentinel (`max_u64`, `0`)
  ALONE — the faithful `==0 && ==0` branch fires only on that same sentinel. Verified edge: `pos_inf
  == max_u64` equals the empty `minted_min` sentinel value, but mint never records `pos_inf` (the
  `higher != pos_inf` guard), so `minted_min == max_u64` unambiguously means "no mint yet". v3 kept
  D2 faithful out of caution about a finite-strike-0; the `min_strike > 0` proof removes that doubt,
  so v4 applies it as an exact collapse (zero behavioral delta).
- **Eliminations:** the synthetic `is_empty_book` flag, the two `if (is_empty) 0 else …`
  conditionals, and the `==0 && ==0` re-check — three synthetic constructs collapsed to one guard.
- Rest of the flow unchanged: `live_inputs` gate before `build_curve` (validate-before-curve pin),
  the inlined `current_floor_index = floor_index_at_ms(expiry, now)`, and `nav.live_value(...)`.

**Trivial flows (getters / constructor / accessors) — no change, verified minimal.**
`payout_liability`, `max_expiry_floor_premium`, `liquidation_ltv`, `expiry_fee_window_ms`,
`expiry_fee_max_multiplier`, `min_strike`, `tick_size`, `max_strike`, `is_liquidated_order`, `new`,
`materialize_settled_liability`, `decrease_materialized_settled_liability`, `destroy_live_indexes`,
`clear_liquidated_order` are all thin field/grid/liquidation relays with no floor math — byte-identical
to the reference, already at their floor, aborts preserved. The decrement inlined in
`close_settled_order` is intentionally duplicated with the standalone
`decrease_materialized_settled_liability` (both are listed flows; v4 inlines flows to be
self-contained) and is byte-consistent (same asserts, same codes, same arithmetic).

**Audit-fixpoint outcome (4 lenses): ALL CLEAN.** Dead/redundant — D2 synthetic constructs gone, no
dead locals, comment accurate. D2-exactness — proven exactly equivalent (the `pos_inf == max_u64`
edge checked and safe). Trivial-flows sweep — all 14 functions minimal + byte-identical to reference,
aborts preserved, intentional duplication confirmed. Sink-minimality — every `live_value` input
minimally derived, the empty-book guard is the cheap first early-out before the expensive
`live_inputs`/`build_curve`, the validate-before-curve gate is the intended pin.

### Final whole-module audit

A 4-lens cross-function panel ran over the whole module after all flows reached fixpoint.

- **Cross-flow index balance: BALANCED.** The earlier "non-landable intermediate state" (only some
  flows collapsed) is **resolved** now that all four floor-touching flows use the identical canonical
  formulas. Verified byte-for-byte that mint INSERTS exactly what redeem/liquidation REMOVE and what
  settled-close PAYS:
  - `floor_shares = mul_div_round_up(seed, FS, open_floor_index)` — mint(452) / redeem old(554)+rem(584)→closed(611) / liquidation(796).
  - `terminal_floor = mul_div_round_up(seed, FS+max_premium, open_floor_index)` (CC2) →
    `terminal_payout = q − terminal_floor` — mint(415) / redeem old(559)+rem(589)→closed(612) / liquidation(789) / settled-close(298, pays at 303).
  - `live_backing_payout = q − seed` (CC1) — mint(451) / redeem old(565)+rem(605)→closed(613) / liquidation(795).
  - `materialize_settled_liability` aggregates the stored CC2 `terminal_payout`; settled-close pays the
    matching CC2 value and decrements by it — aggregate and per-order values agree.
  `seed`/`open_floor_index` are reproducible at every remove/pay site (same packed order →
  `order.floor_seed_amount()` + `floor_index_at_ms(order.opened_at_ms())`; `order::replacement` inherits
  opened_at/leverage/entry_probability). Non-index round-ups (mint LTV gate, redeem `closed_floor_amount`,
  liquidation threshold/event) correctly use their own divisors and never touch index balance.
- **Whole-module dead/cyclic/recreated/synthetic: CLEAN.** 21 functions, all minimal + single-purpose;
  build with zero warnings; `floor_at_open` 0 occurrences; `fee_amount` gone; `is_empty_book` only in a
  doc comment; all 6 error constants used; `has_replacement`/`should_liquidate` are genuine control gates;
  `terminal_floor_index` named only where 2-use (redeem), inlined where single-use (mint/settled/liquidation)
  — consistent. The `max_expiry_floor_premium()` multi-read is the accepted module-wide inline-getter style.
- **Semantic contract: CLEAN.** Same aborts + codes as the reference, modulo the documented provably-dead
  terminal-floor LTV re-assert removals (settled-close, redeem-old, liquidation) — kept in mint and the
  guarded redeem-replacement. No new abort introduced (the closed-delta subtractions are bare; the LTV
  admission margin guarantees no underflow). Validate-before-mutate holds in every flow; events emitted
  after the mutation. Fee relay correct (gate retained assert-only; redeem returns `range_probability`; no
  abort dropped — `live_range_probability` covers now<expiry + freshness + active). All rounding deltas
  match the ledger.
- **Ledger completeness: CLEAN after one fix.** The panel found the §1 magnitude *derivations* cited a stale
  `index/FS ∈ [1, 1.2]` interval (the default `mp = 0.2*FS`) instead of the admissible `[1, 2]` (`mp` tunable
  up to `FS`). The stated magnitudes (≤2 ulp payouts, ≤4 ulp thresholds) were already correct — confirmed by
  a 6M-sample sweep over the full `mp` range — so only the cited interval was stale. **FIXED** in CC1/CC2.

**Build: green (collision-aware); `prettier --plugin=@mysten/prettier-plugin-move` clean.** Definition of
done met: every function single/inlined/minimal/one-purpose; fee extracted to `trading_fee` with the mint
gate retained; no dead/cyclic/recreated/synthetic code; math collapsed (CC1/CC2/CC3) + round-trips removed;
semantic contract preserved (aborts+codes, validate-before-mutate, events-after) with payouts identical
modulo the documented ≤2/≤4-ulp rounding and the exact D2; every divergence logged.
