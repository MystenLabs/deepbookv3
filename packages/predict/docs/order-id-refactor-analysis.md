# Predict `Order` / `order_id` Refactor — Analysis & Design Note

**Status:** Analysis / design only. No code changes proposed here.
**Scope:** `packages/predict` only. The Rust indexer (`crates/`) does **not** index Predict,
and `scripts/` contains no Predict order-id construction, so both are out of scope (verified below).
**Authoritative source files** are the live ones (`order.move`, `strike_exposure.move`,
`liquidation_book.move`, …), **not** the paused `*_rewrite.move` files. All line numbers below are from
the live files on `strike-exposure-rewrite-state`.

---

## 1. Executive summary

Predict's `order_id: u256` is doing **three jobs at once**:

1. **Reference key** — what `PredictManager` positions and all events key on.
2. **Canonical storage of order terms** — the only place the 7 contract fields live; there is **no
   per-order record anywhere on chain**. Redemption and the liquidation scan recover terms by
   *decoding the id* (`order::from_order_id`).
3. **Liquidation sort key** — the packed high bits *are* the priority order; the liquidation book
   sorts the raw `u256` ascending and binary-searches it.

The single most important finding: **because the id *is* the terms, the packed id is
self-authenticating** (terms can't be forged — they're decoded from the id, and the manager
position-set + aggregate-index underflow bind it). The moment you split the id from the terms, you
**must** introduce an authoritative on-chain term store, and that store **must survive compaction**.
Removing packing is therefore not "shrink a u256 to a u64" — it is "stop storing terms for free, and
make the implicit comparator explicit."

**Recommendation in one line:** make `Order` a plain struct, make `order_id` a `u64` expiry-local
sequence, **store the canonical `Order` in a new `Table<u64, Order>` owned by `StrikeExposure`**
(Option 1/5), and move the implicit packed-bit ordering into an **explicit liquidation priority key**
held by the `LiquidationBook`. It can be staged into ~4 required phases + 1 optional behavior phase.

---

## 2. Current architecture (grounded)

### 2.1 `order.move` — the packed id

`Order` is a transient view, no storage:

```move
public struct Order has copy, drop { id: u256 }   // order.move:49-51
```

Bit layout (`order.move:29-35`, packing at `:218-227`), **high bits → low bits** (this order *is* the
liquidation priority — each field strictly dominates every lower field):

| Priority | Field | Offset | Width | Stored value | Direction effect |
|---|---|---|---|---|---|
| 1 | `inverse_quantity_lots` | 200 | u32 | `U32_MASK - quantity_lots` (`:219`) | **larger quantity → smaller → first** |
| 2 | `leverage_rank` | 168 | u32 | `3x=0,2.5x=1,2x=2,1.5x=3,1x=4` (`:283-297`) | **higher leverage → smaller → first** |
| 3 | `opened_at_ms` | 120 | u48 | as-is | older (smaller ms) first |
| 4 | `lower_boundary_index` | 96 | u24 | as-is | smaller first |
| 5 | `higher_boundary_index` | 72 | u24 | as-is | smaller first |
| 6 | `entry_probability` | 40 | u32 | as-is, ≤ `float_scaling` (1e9) | smaller first |
| 7 | `sequence` | 0 | u40 | as-is | smaller first — **uniqueness tail** |

`32+32+48+24+24+32+40 = 232 = ORDER_ID_BITS` (`:35`, checked in `assert_valid` `:253`).

Two fields are stored **inverted purely so ascending numeric sort == liquidation priority.**
`quantity` and `leverage` are the real values; `inverse_quantity_lots` and `leverage_rank` exist only
as a sort hack and have **no** independent meaning.

Constructors / decoders / validations:
- `new` (`:201-230`) is the sole packer; `from_order_id` (`:81-85`) the sole decoder (wraps + `assert_valid`).
- `replacement(old, quantity, sequence)` (`:156-167`) builds a strictly-smaller-quantity order
  inheriting all other terms (used by partial close).
- **Structural / economic validations** (keep): `assert_valid_order_shape` (`:315-331` — `lower<higher`,
  no full-range `[0,max]`, leveraged orders must touch an extreme boundary), `assert_valid_leverage`
  whitelist (`:272-281`), `assert_valid_quantity` lot-alignment (`:170-174`, lot size 10_000),
  `entry_probability ≤ float_scaling` (`:213`).
- **Pure bit-width validations** (would disappear): `opened_at ≤ u48` (`:210`), boundary `≤ u24`
  (`:211-212`), `sequence ≤ u40` (`:215`), `quantity_lots ≤ u32` (`:214`), `id >> 232 == 0`
  (`EInvalidOrderId`, `:253`).
- **Mint-admission policy** (stays on the mint path, never in decode): `assert_mint_leverage_tier`
  (`:192-199`) — already separated, consistent with CLAUDE.md.

### 2.2 `predict_manager.move` — opaque reference key (the easy part)

```move
public struct PositionKey { expiry_market_id: ID, order_id: u256 }   // :53-58
positions: Table<PositionKey, bool>                                   // :82  — a SET, value bool
```

The manager **never decodes** `order_id`. It only does membership (`has_position` `:155`,
`add_position` `:433`, `remove_position` `:443`) and a per-expiry `open_position_count`. Sui `Table`
is **not iterable** — there is no loop over `positions` anywhere — so the manager **cannot** scan all
orders for an expiry. Changing `u256 → u64` here is purely mechanical.

### 2.3 `strike_exposure.move` — owns the id source + aggregate indexes, stores **no** per-order record

```move
public struct StrikeExposure {
    …, next_order_sequence: u64, …,        // :50  — THE expiry-local id source
    settled_payout_liability: u64, settled_liability_materialized: bool,  // survive compaction
    liquidation: LiquidationBook,          // survives compaction
    live: Option<LiveExposure>,            // nav + payout aggregates; destroyed by compaction
}
```

- `allocate_mint_order` reads/increments `next_order_sequence` (`:223,:237`) and inserts **aggregate**
  exposure (`insert_live_order` `:564-582`) plus the id into the liquidation book (`:581`).
- The aggregate indexes (`StrikeNavMatrix`, `StrikePayoutTree`) are **strike-keyed sums** — they hold
  **zero** `order_id`. Removal recomputes per-order deltas **from the order's decoded terms**
  (`order_index_update_terms` `:402-412`).
- The liquidation scan reconstructs each candidate from its id:
  `order::from_order_id(candidates[i])` (`:367`).
- Partial close: `resulting_order_after_close` (`:464-476`) mints a **new** sequence/id for the
  residual; identity change is detected by `resulting_order.id() != order.id()` (`:458,:493`).
- Compaction `destroy_live_indexes` (`:344-355`) destroys nav+payout but **keeps** the liquidation
  book + tombstones + `settled_payout_liability`.

### 2.4 `liquidation_book.move` — sorted by the raw packed `u256`

```move
public struct LiquidationBook {
    pages: Table<u64, OrderIdPage>, page_ids: vector<u64>,
    max_order_ids: vector<u256>,            // :30 per-page routing key
    next_page_id, active_order_count,
    passive_watermark: Option<u256>,        // :34 round-robin resume point (same domain as keys)
    liquidated_orders: Table<u256, bool>,   // :36 tombstones — presence only, NO terms
}
public struct OrderIdPage { order_ids: vector<u256> }   // :41 sorted ascending
```

- Paged sorted vector, ascending. **Front = smallest id = highest liquidation priority.** The bounded
  scan (`select_liquidation_candidates` `:69-87`) returns a head batch (`collect_head_candidates`
  from `ScanCursor{page:0,offset:0}`) + a round-robin passive batch.
- `lower_bound`/`upper_bound` (`:359-385`) are **plain numeric `u256` comparisons** — the comparator
  is the packed value itself.
- Only **leveraged** orders enter: `insert_order`/`remove_order` early-return for 1x (`:90,:98`).
  Note `mark_liquidated` (`:103-108`) has **no** `is_leveraged` guard — latent contract: only
  leveraged orders are ever liquidated (1x would underflow `active_order_count`).
- Uniqueness is load-bearing: insert asserts no duplicate (`EActiveOrderAlreadyExists` `:135-138`),
  guaranteed today by the 40-bit `sequence` tail.

### 2.5 `order_events.move` — id is just a join key

Five events, each `order_id: u256`: **`OrderMinted`** (`:16`), **`LiveOrderRedeemed`** (`:39`, with
`replacement_order_id: Option<u256>` `:48`), **`SettledOrderRedeemed`** (`:59`),
**`LiquidatedOrderRedeemed`** (`:70`), **`OrderLiquidated`** (`:82`). Crucially, events already emit
**decoded semantic fields** (leverage, entry_probability, quantity, contribution, floor_seed_amount,
strikes). Consumers do **not** decode the id — `order_id` is only a join key (module doc `:5-9`). So
`u256 → u64` in events is a pure join-key type change; the payload is unaffected.

### 2.6 The end-to-end flows (`expiry_market.move`)

- `mint(...) -> u256` (`:155-185`).
- `redeem(...) -> (u256, Option<u256>)` (`:193-216`), `redeem_settled(...) -> (u256, Option<u256>)`
  (`:223-245`). Both go through `redeem_internal` (`:511-563`), which **reconstructs the order from
  the caller-supplied id**: `order::from_order_id(order_id)` (`:526`).
- Live partial close (`redeem_live_internal` `:659-722`): `remove_position(old)` (`:675`),
  `close_and_quote_live_order`, then if a residual exists `add_position(new)` (`:696`); emits
  `LiveOrderRedeemed` with both ids.
- Settled redeem (`redeem_settled_internal` `:724-745`): full close only (`:533`), payout from
  `close_settled_order`.
- Liquidated redeem (`redeem_liquidated_order` `:565-575`): full close only, **no payout**, asserts
  `close_quantity == order.quantity()` (`:571`) — i.e. **needs the decoded quantity** — clears the
  tombstone, emits `LiquidatedOrderRedeemed` (which reads `order.quantity()`).
- `compact_storage` (`:269-282`): materialize settled liability → `destroy_live_indexes` → assert
  cash backing.

### 2.7 The self-authentication property (why this is the crux)

Today nothing stores order terms. Redemption trusts the caller-supplied id because:
1. `from_order_id` proves the id is **structurally** valid, and
2. `remove_position` proves the manager actually **holds** that exact id (`EInsufficientPosition`), and
3. the aggregate-index removal (`remove_range`) would **underflow** if those exact terms were never
   inserted.

The id *being* the terms is what ties (1)–(3) together: a forged id either fails structural validation
or fails the position/underflow checks. **Once `order_id` is a bare `u64`, the position key no longer
binds the terms** — a user could present a `u64` they own with fabricated terms. Therefore the terms
**must** come from an authoritative on-chain store written only by mint, and that store must remain
available wherever redemption is still possible (i.e. **past compaction**). This is the load-bearing
reason the refactor has a real, unavoidable storage cost.

---

## 3. Proposed architecture

### 3.1 `Order` struct shape (Q1, Q2)

Drop the `u256 id` and both inversion hacks; store the 7 real terms:

```move
/// Validated, immutable contract terms for one Predict position.
public struct Order has store, copy, drop {
    /// Expiry-local reference id (== the sequence that minted it). Unique within one expiry.
    order_id: u64,
    /// ms the position was originally opened; feeds floor-index & liquidation math.
    opened_at_ms: u64,
    /// Strike-grid boundary indices (sentinel-shifted; domain <= oracle_strike_grid_ticks + 2).
    lower_boundary_index: u64,
    higher_boundary_index: u64,
    /// 1e9-scaled leverage multiplier (1x,1.5x,2x,2.5x,3x) — NOT a rank.
    leverage: u64,
    /// 1e9-scaled entry range probability (<= float_scaling).
    entry_probability: u64,
    /// Position quantity in user units (multiple of position_lot_size = 10_000).
    quantity: u64,
}
```

- **Abilities (Q2): add `store`** (it now lives in a `Table` value) and keep `copy, drop` (it is read
  by-getter and cloned cheaply, e.g. `*order` at `strike_exposure.move:470`; the module controls all
  access so `drop` on a removed row is fine). It does **not** need `key` — it is never a standalone
  object. *(Option to drop `copy` later for stricter handling; not required.)*
- Store **`leverage` as the 1e9 multiplier**, not the u32 rank — robust (3x = 3_000_000_000 is near
  the u32 cap and fragile), and it deletes the `leverage_rank`/`leverage_from_rank` mirror pair.
- Store **`quantity` in user units**, not lots and not inverted — the inversion was sort-only.

### 3.2 `order_id` semantics (Q3)

- **`u64`, expiry-local sequence**, sourced from the existing `StrikeExposure.next_order_sequence`
  (`strike_exposure.move:50`), which already covers both mint (`:223,:237`) and partial-close residuals
  (`:472-474`) and is the only per-book identity counter. The `PositionKey` already scopes by
  `expiry_market_id`, so the id only needs to be unique **within** an expiry — `u64` is ample (the
  old 40-bit cap can relax).
- **`order_id` is identity only.** It is **not** a valid liquidation sort key (a bare incremental id
  would sort by insertion order). Priority moves to an explicit key (§3.4).
- `opened_at_ms` stays a **term** field (floor/liquidation math needs it). This is compliant with the
  CLAUDE.md rule "do not encode market-lifecycle facts such as expiry in the order id" — open time is
  an order term, not a market-lifecycle fact, and it is no longer *in* the id.

### 3.3 Storage owner: `StrikeExposure` (Option 1 ≡ Option 5) — **recommended**

Add an expiry-local registry to `StrikeExposure`, co-located with the sequence counter that mints ids:

```move
// new field on StrikeExposure (top level, NOT inside LiveExposure — must survive compaction)
orders: Table<u64, Order>,
```

- **Manager (Q5):** keep `positions: Table<PositionKey, bool>` as a **membership set**; only change
  `PositionKey.order_id: u256 → u64`. It does **not** need quantity or `Order` data — the manager
  never scans, reprices, or decodes. Ownership check (set membership) + term lookup (registry) are
  two separate, complementary reads: ownership from the manager, terms from `StrikeExposure.orders`.
  This restores self-authentication: the user can't forge terms because they come from the registry
  that only mint writes.
- **Liquidation book:** stops being a term source. It stores `(priority_key, order_id)` pairs sorted
  by `priority_key`; the scan returns `order_id`s and liquidation looks each up in `orders` to reprice
  (replacing `from_order_id(candidates[i])` at `strike_exposure.move:367`).
- **Tombstones / liquidated redeem (Q7):** keep tombstones in the book as `Table<u64, bool>` (ref id
  only). The terms a liquidated order still needs (quantity for the full-close assert + event) come
  from the **`orders` registry**, whose row persists until redeem. `clear_liquidated_order` removes
  both the tombstone and the `orders` row. **One** term source, no duplication.
- **Compaction:** `orders` lives at `StrikeExposure` top level (alongside `settled_payout_liability`
  and the liquidation book), so it **survives `destroy_live_indexes`**. Settled/liquidated redeem
  after compaction read terms from `orders`.

Why not the others (grounded):
- **Option 2 (book only):** structurally insufficient — the book only holds **leveraged** orders
  (`:90,:98`); 1x settled/live redeem needs terms too.
- **Option 3 (manager only):** liquidation cannot enumerate other users' managers; `Table` isn't
  iterable. Dead.
- **Option 4 (both):** duplication + consistency risk, with no benefit since the manager never needs
  terms.

### 3.4 Liquidation comparator / key (Q6)

The priority order is **fixed by today's bit layout** and locked by tests (§5): **quantity DESC →
leverage DESC → opened_at ASC → lower_boundary ASC → higher_boundary ASC → entry_probability ASC →
sequence ASC (unique tail).** "Liquidated first" = lexicographically-smallest key = front of the book
= biggest, most-levered, oldest order.

Two faithful representations:

**(A) Explicit packed scalar (lowest risk, bit-for-bit) — recommended for the index internals.**
Add `order::liquidation_priority_key(&Order): u256` that packs the **same** fields in the **same**
order (keeping the two inversions inside the *key construction*, not in `Order`). The book stores this
key in `order_ids` / `max_order_ids` / `passive_watermark` (all retyped to the key, **not** the
reference id) and keeps the existing numeric binary search verbatim. This *is* today's value minus the
requirement that it also be the identity — packing doesn't vanish, it **relocates** to an explicit,
named, separately-tested sort key.

**(B) `LiquidationKey` struct + lexicographic comparator (most readable).**
```move
public struct LiquidationKey has copy, drop, store {
    inverse_quantity_lots: u64,  // U32_MASK - quantity_lots
    leverage_rank: u8,           // 3x=0 … 1x=4
    opened_at_ms: u64, lower_boundary_index: u32, higher_boundary_index: u32,
    entry_probability: u32, sequence: u64,   // unique tail
}
```
A field-by-field `<` comparator threaded through `lower_bound`/`upper_bound`/page-routing/watermark.
Cleaner, self-documenting, but every search site needs the custom comparator and it is easier to get
*not*-bit-for-bit.

**Recommendation:** ship **(A)** (one derivation function + zero binary-search changes) to guarantee
bit-for-bit parity at low risk; optionally migrate to **(B)** later for readability. **Either way the
key must include `sequence` as the uniqueness tail** (insert dedup at `:135-138` depends on it) and
must be the type used by `max_order_ids` and `passive_watermark`.

### 3.5 Partial close: keep mint-a-new-id (Q4)

Today a partial close mints a **new** sequence/id for the residual and removes the old id; reuse is
impossible because quantity is *in* the immutable id. After the rewrite, **reuse becomes possible** —
but **keep mint-a-new-id**:

- **Accounting is id-agnostic** either way — NAV/payout indexes store no id and compute deltas from
  `old − remaining` terms (`strike_exposure.move:478-519`). Reuse buys nothing here.
- **The liquidation key depends on quantity**, so a partial close **must re-sort** the book regardless
  of id reuse — reuse only saves the manager `remove+add` pair, not the re-sort.
- **Immutable-terms-per-id** keeps `OrderMinted` as the off-chain term-of-record; redeem/liquidation
  events join back by id and follow `replacement_order_id` for lineage — exactly what both sims
  already implement. Reuse would force `OrderMinted` to become mutable or add an `OrderResized` event
  — a larger schema change for marginal savings.

*(This is the one place grounding changed the conclusion: reuse looks tempting but pays off only if
quantity leaves the priority key, which it does not.)*

---

## 4. Files & functions likely needing changes

**`order.move`** — replace `Order { id: u256 }` with the explicit struct; delete offsets/masks/
`decode_*`, `inverse_quantity_lots`, `leverage_rank`/`leverage_from_rank`; convert `new`/
`new_from_boundary_indices`/`replacement` to build the struct; `from_order_id` disappears (replaced by
a registry lookup) or becomes a thin getter; add `liquidation_priority_key`; keep
`assert_valid_order_shape`, `assert_valid_leverage`, `assert_valid_quantity`,
`entry_probability ≤ float_scaling`, `assert_mint_leverage_tier`; delete the pure bit-width asserts +
`EInvalidOrderId`; re-home boundary bound to `max_encoded_boundary_index`.

**`strike_exposure.move`** — add `orders: Table<u64, Order>` (+ insert on mint/replacement, get,
remove on close, survive compaction); replace `from_order_id(candidates[i])` (`:367`) with a registry
lookup; keep `next_order_sequence` as the id source; thread `Order` by reference from the registry;
ensure `destroy_live_indexes` (`:344-355`) does **not** drop `orders`.

**`liquidation_book.move`** — retype `order_ids`, `max_order_ids`, `passive_watermark`,
`liquidated_orders`, and `select_liquidation_candidates` return to the **priority key** / **`u64` ref
id** as appropriate; binary search compares the priority key; store `(key, order_id)`; preserve the
leveraged-only contract and the dedup/uniqueness invariant.

**`predict_manager.move`** — `PositionKey.order_id: u256 → u64`; signatures `has_position`,
`add_position`, `remove_position`, `position_key`.

**`expiry_market.move`** — return/param types `u256 → u64` on `mint`, `redeem`, `redeem_settled`,
`redeem_internal`, and the `redeem_*_internal` helpers; `redeem_internal` resolves the `Order` via the
registry instead of `from_order_id` (`:526`); liquidated/settled redeem read terms from the registry.

**`order_events.move`** — `order_id: u256 → u64` on all five structs;
`LiveOrderRedeemed.replacement_order_id: Option<u256> → Option<u64>` (kept, since mint-new-id stays).

**Tests** (`packages/predict/tests`):
- `order_tests.move`: `from_order_id_round_trips_through_id_getter` (`:114-117`) retype;
  `from_order_id_with_bits_above_payload_aborts` (`:299-304`) **delete** (no high bits exist);
  `higher_leverage_order_id_sorts_first` (`:309-330`),
  `larger_quantity_order_id_sorts_first_before_leverage` (`:333-354`),
  `lower_open_side_sorts_before_higher_open_side_when_other_priority_matches` (`:357-377`) — **rewrite
  to assert the explicit comparator** instead of `id()` numeric comparison.
- `predict_manager_tests.move`, `expiry_market_tests.move`, `strike_exposure/*`,
  `flows/plp_rebate_flow_tests.move`: update id construction/assertions to `u64`.

**Simulations** (`packages/predict/simulations`):
- `python_indexes/liquidation_book.py` (offset consts `:14-29`, `encode_order_id` `:79-127`, candidate
  selection `:187-199`) and `python_replay.py` (`order_id_for_terms` ~`:944-956`, replacement mint
  ~`:1740-1758`): drop packing, mirror the new priority key + `u64` id **in lockstep** or replay
  parity breaks.
- `src/sim.ts` (`:356-420,:640,:670-677`): `order_id`/`replacement_order_id` stay JS-safe as `u64`;
  keep the replacement-aliasing lineage logic.

**Out of scope (verified):** `crates/` (no `deepbook_predict` references; all `order_id` are
deepbook-core `u128`), `scripts/` (no Predict order-id construction).

---

## 5. The 11 questions — direct answers

1. **Fields if packing removed:** the 7 in §3.1 — `order_id, opened_at_ms, lower_boundary_index,
   higher_boundary_index, leverage (1e9), entry_probability (1e9), quantity (user units)`. The two
   inverted fields collapse to plain `quantity`/`leverage`.
2. **Abilities:** `store` (now table-resident) + `copy, drop`. **No `key`.** Optionally drop `copy`.
3. **`order_id`:** `u64`, expiry-local sequence from `next_order_sequence`. Identity only; not the
   sort key.
4. **Partial close:** keep **mint-a-new-id** (reuse saves only manager churn, still re-sorts, and
   breaks immutable-terms-per-id). See §3.5.
5. **`positions`:** stays a membership **set**; only `order_id: u256 → u64`. No quantity/Order data.
6. **Liquidation ordering:** explicit priority key reproducing **qty DESC → lev DESC → opened_at ASC →
   lower ASC → higher ASC → entry_prob ASC → sequence ASC**. Prefer the explicit packed-scalar key
   (§3.4-A) for bit-for-bit parity; `LiquidationKey` struct (§3.4-B) is the readable alternative.
7. **Tombstones / post-liquidation data:** tombstones stay in the book (`Table<u64, bool>`); the
   **terms** for the liquidated full-close assert + event come from the `StrikeExposure.orders`
   registry, which survives compaction and is cleared on redeem.
8. **API/event type changes:** `mint`/`redeem`/`redeem_settled` returns & params, `PositionKey`, all 5
   events, and the liquidation book internals go `u256 → u64`. Downstream: Predict tests + python/ts
   sims only. **No** Rust-indexer or script impact.
9. **Validation re-homing:** keep economic/structural asserts (shape, leverage whitelist,
   quantity-lot-alignment, entry-prob bound) in the `Order` constructor; **delete** the pure bit-width
   asserts and `EInvalidOrderId`; the "is this a real order" check moves from bit-pattern validation
   to a **registry/position lookup** (a table miss replaces `EInvalidOrderId`). Keep
   `assert_mint_leverage_tier` on the mint path only.
10. **Storage/gas (Q10):** today per-order term storage is **0** (the id *is* the terms); a 1x order's
    entire footprint is one `PositionKey` row. After the refactor, add **one `Table<u64, Order>` row
    (~48–52 B payload + table overhead) per open order**. The decisive cost: **liquidated and
    post-compaction orders now need ~48 B of persisted terms where today the tombstone is 1 B
    (`bool`)**, and **compaction no longer fully reclaims per-order storage** — it still reclaims the
    big dense nav/payout aggregates, but the `orders` rows linger until each holder redeems. Prefer a
    compact priority key + a **single** term table (don't fatten every 64-entry liquidation page).
    Mild offset: a table borrow replaces repeated shift/mask + `assert_valid` on every read.
11. **Staging (Q11):** yes — see §6. It **cannot** be one step: ordering, term recovery, and id type
    are all carried by the same `u256`, so a single-shot swap breaks the comparator *and* term recovery
    *and* sim parity in the same commit.

---

## 6. Suggested implementation phases (do **not** implement here)

Each phase compiles and keeps the Move suite + python/ts replay parity green.

- **Phase 1 — thread `Order` by value/reference.** Make `order.id()` the only place that touches the
  packed representation; everything else passes `Order`. Likely mostly true already (CLAUDE.md:
  "use `Order` internally, packed id only at boundaries"). *Verify:* full suite unchanged.
- **Phase 2 — explicit comparator, still packed.** Add `order::liquidation_priority_key(&Order)` that
  reproduces today's ordering; switch the book's binary search / `max_order_ids` / `passive_watermark`
  to it while the id still equals the packed value (numerically consistent → behavioral no-op).
  Rewrite the `order_tests` priority tests as comparator tests; mirror the key in the sims.
  *Verify:* assert key-order == id-order; replay parity.
- **Phase 3 — term store keyed by the current id.** Add `StrikeExposure.orders` (still keyed by the
  packed `u256` for now); populate on mint/replacement; read it in `liquidate_candidates` and
  settled/liquidated redeem instead of `from_order_id`; clear on close. Removes the "terms == id"
  invariant while the id is unchanged. *Verify:* liquidated/settled redeem still work with dense
  indexes destroyed (`compact_storage`).
- **Phase 4 — flip id to `u64`, stop packing.** `Order` becomes the explicit struct with a `u64`
  `order_id` (reuse `next_order_sequence`); delete pack/unpack; `from_order_id` → registry lookup;
  retype events / `PositionKey` / book to `u64`; drop `encode_order_id` packing in the sims. The
  comparator (P2) and term store (P3) already exist, so this is the type swap + unpack removal.
  Delete `from_order_id_with_bits_above_payload_aborts`. *Verify:* full suite + replay parity.
- **Phase 5 (optional, behavior) — only if reuse-id on partial close is chosen.** Its own PR; not
  recommended (see §3.5).

---

## 7. Risks & gotchas

- **Comparator parity is the highest risk.** The packed encoding made the ordering impossible to get
  wrong by accident *and* impossible to read. Any divergence in the explicit key silently changes
  **who gets liquidated first**. The three `order_tests` sort tests + the python mirror are the
  guardrails — port them exactly.
- **Sequence as uniqueness tail is load-bearing.** The book's dedup (`:135-138`) and round-robin
  watermark assume globally-unique, totally-ordered keys. The priority key must keep `sequence` in the
  low position; `passive_watermark`/`max_order_ids` must hold the **key**, not the ref id.
- **`mark_liquidated` has no `is_leveraged` guard** (`:103-108`) — preserve the leveraged-only caller
  contract or 1x orders underflow `active_order_count`.
- **Compaction semantics change.** `orders` must survive `destroy_live_indexes`; per-order rows persist
  until redeem, so compaction's storage rebate shrinks. Document that registry membership is a
  **superset** of liquidation membership (1x orders have a row but never enter the book).
- **Abort-surface shift.** `EInvalidOrderId` (bit-pattern) → a table/position miss for unknown ids.
  Decide and document the intended abort for a bogus id; update callers/tests.
- **Loss of self-authentication** unless ownership (manager set) **and** terms (registry) are both
  checked on every redeem. Don't trust a bare `u64` for terms.
- **Sim lockstep.** `python_indexes/liquidation_book.py`, `python_replay.py`, `src/sim.ts` mirror the
  packing and the sort; they must change in the same PR as the contract or replay parity breaks.
- **`OrderMinted` already carries decoded terms** — keep it the term-of-record so redeem/liquidation
  events can stay lean join-only payloads.

---

## 8. Questions to answer before implementation

1. **Intended liquidation priority:** is **quantity-DESC-then-leverage-DESC** (the current bit order)
   the deliberate economic priority, or an artifact? Likewise confirm `opened_at` (oldest-first) and
   `entry_probability` (smallest-first) directions are intended, not accidental. Phase 2 should encode
   the *intended* order and update the tests deliberately if it differs.
2. **Priority-key representation:** explicit packed `u256` scalar (bit-for-bit, zero search changes)
   vs `LiquidationKey` struct + comparator (readable). Recommendation: scalar first.
3. **Liquidated-term lifecycle:** confirm "keep the `Order` row in the registry until redeem" (one
   term source) is acceptable, accepting that liquidated/uncompacted rows linger.
4. **Partial-close id policy:** ratify keep-mint-new-id (immutable `OrderMinted` term-of-record) vs
   reuse-id (+ `OrderResized` event). Recommendation: keep-new-id.
5. **Abort for unknown id** after the lookup-based validation replaces `EInvalidOrderId`.
6. **Any future need to enumerate all orders for an expiry** (admin/keeper) beyond liquidation's
   bounded scan? If yes, the registry needs its own ordered index (out of scope today).
7. **`opened_at_ms` as a term field** — sign off that it satisfies the CLAUDE.md "no market-lifecycle
   facts in the id" rule (it should: open time is an order term, and it is no longer in the id).
8. **External off-chain integrators** (outside this repo) that read/decode the 32-byte `order_id`
   would break — confirm none exist or coordinate the schema change.
