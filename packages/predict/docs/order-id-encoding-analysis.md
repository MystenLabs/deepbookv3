# Predict `order_id` Encoding Analysis — Are These the Right Packed Values?

**Status:** Analysis / design only. No code changes proposed here.
**Decision context:** We are **keeping** the packed `u256 order_id` (it is the order's compression
format, the `PredictManager` position key, the canonical term store, and the liquidation sort key, with
zero per-order storage — see the sibling note `order-id-refactor-analysis.md`, which evaluates the
*remove-packing* path separately, and `order-move-boundary-analysis.md`, which moves mint-admission
policy out of `order.move`). This note answers a different question: **given that we keep packing, are
the *values* currently packed the right ones, or should the ID encode derived values
(`user_contribution`, `floor_seed_amount`, `floor_shares`) instead of the atomic inputs it packs
today?**
**Authoritative files:** the live `*.move` sources/tests on `strike-exposure-rewrite-state`. The paused
`strike_exposure_rewrite.move` / `strike_exposure_cofig_rewrite.move` and `*_ledger.md` files are
**not** treated as ground truth. All line numbers are from HEAD.

---

## 1. Executive summary

The packed ID does **two jobs with the same bits**: (1) it is the *canonical, self-authenticating
store* of the contract terms (nothing else stores them on chain — redemption and the liquidation scan
recover terms by decoding the ID via `order::from_order_id`), and (2) its high-bit field ordering *is*
the liquidation priority (`liquidation_book` sorts the raw `u256` ascending and never decodes a field).

The central finding: **`entry_probability` is the single lossless economic root; `user_contribution`,
`floor_seed_amount`, and `entry_exposure_value` are its rounding-lossy projections.** The current
layout stores the root and derives the projections on demand (cheap: one `mul` + one
`mul_div_round_up` + one subtraction). Encoding the projections instead is a **strict regression** on
every axis that matters:

- **Self-verifiability ↓** — `entry_probability ≤ 1e9` is checkable from a *single field*
  (`order.move:254`). A stored floor/contribution has only a *cross-field* validity domain
  (`floor ≤ quantity`, leverage↔floor consistency) that cannot be checked from the ID alone, forcing a
  new consistency assert that does not exist today.
- **Losslessness ↓** — `user_contribution` rounds **up** (`order.move:265`), so `entry_probability` is
  **not uniquely recoverable** from `floor_seed + leverage + quantity`. Storing the projection
  destroys the exact quoted entry price that `OrderMinted.entry_probability` (`order_events.move:114`)
  reports and that the mint-time gate `gross_value = entry_probability * quantity`
  (`strike_exposure_config.move:235`) consumes.
- **Replacement correctness ↓** — partial-close `replacement` (`order.move:156-167`) re-derives the
  *smaller-quantity* floor proportionally from the inherited `entry_probability`. A stored *absolute*
  floor of the old quantity cannot be rescaled without re-introducing a per-unit rate.
- **Bit cost ↑** — a money amount needs **46 bits** (max `quantity = (2³²−1)·10_000 ≈ 4.29e13`), not
  the 32 bits `entry_probability` occupies. It fits (24 free bits + an over-wide `leverage_rank`), but
  it is not free.
- **Compute saved ≈ 0** — every floor/contribution consumer already calls a getter on a typed `Order`
  (`strike_exposure.move:408,535,571`; `expiry_market.move:762`; `order_events.move:116,121`); direct
  encoding saves at most one `mul`/`mul_div` per access.

**Recommendation: keep the current layout (Option 1).** Limit work to helper/boundary hygiene. Do
**not** encode `user_contribution`/`floor_seed_amount`. The one defensible space tweak — shrinking the
32-bit `leverage_rank` to its true ~3-bit domain — is unnecessary today (24 free bits) and not worth
the migration/parity churn.

**The one genuinely open question is orthogonal to encoding *shape*: liquidation *priority policy*.**
The offline tool `simulations/tools/analyze_liquidation_priority_encodings.py` is A/B-testing
derived risk metrics (`floor_seed_probability`, `ltv_headroom_probability`, `floor_lots`, …) as the
*primary sort key* against today's `quantity↓ → leverage↓`. If a derived metric wins, that argues for
packing it in the **high bits** as the sort key — a risk-policy decision to ratify on its own, distinct
from the term-storage question this note answers (§8, Q5).

---

## 2. Current packed layout

`Order` is a transient typed view over the `u256`, no storage (`order.move:49-51`):

```move
public struct Order has copy, drop { id: u256 }
```

Packed high→low (offsets `order.move:29-34`, packer `order.move:218-227`). **The bit order *is* the
liquidation priority** — each field dominates every lower field in the ascending `u256` sort:

| Pri | Field | Bits | Width | Stored as | Sort effect |
|----|---|---|---|---|---|
| 1 | `inverse_quantity_lots` | 200–231 | u32 | `U32_MASK − quantity_lots` (`:219`) | **larger quantity → smaller → first** |
| 2 | `leverage_rank` | 168–199 | u32 | `3x=0…1x=4` (`:283-297`) | **higher leverage → smaller → first** |
| 3 | `opened_at_ms` | 120–167 | u48 | as-is | older first |
| 4 | `lower_boundary_index` | 96–119 | u24 | as-is | smaller first |
| 5 | `higher_boundary_index` | 72–95 | u24 | as-is | smaller first |
| 6 | `entry_probability` | 40–71 | u32 | as-is, ≤ `1e9` | smaller first |
| 7 | `sequence` | 0–39 | u40 | as-is | smaller first — **unique tail** |

`32+32+48+24+24+32+40 = 232 = ORDER_ID_BITS` (`:35`), checked `id >> 232 == 0` in `assert_valid`
(`:253`). **Free headroom: bits 232–255 = 24 bits.** Two fields are inverted purely so ascending sort
== priority; `quantity` and `leverage` are the real values, `inverse_quantity_lots` and `leverage_rank`
carry no independent meaning.

Constructors/validators: `new` (`:201-230`, sole packer, owns all per-field width asserts);
`new_from_boundary_indices` (`:135-153`, sole package constructor); `replacement` (`:156-167`,
strictly-smaller quantity, inherits all other terms); `from_order_id` (`:81-85`) → `assert_valid`
(`:251-261`, **sole** untrusted-`u256`→`Order` boundary); `assert_valid_order_shape` (`:315-331`,
shared by encode + decode). `assert_mint_leverage_tier` (`:192-199`) is mint-admission policy, called
**only** at mint (`strike_exposure.move:212`), never in construction/decoding — satisfying the
AGENTS.md rule that policy must not retroactively invalidate stored IDs.

---

## 3. Usage inventory

Counts are by **semantic value** (e.g. `quantity()` used many times; `inverse_quantity_lots` decoded
once inside it). "Direct" = the value/field is used as itself; "Derived-input" = consumed only to
compute another value. Citations are representative, not exhaustive.

| Packed field | Direct | Derived-input | Feeds (derived values) | Needed for | Mainly for sort? |
|---|---|---|---|---|---|
| **quantity** (via `inverse_quantity_lots`) | 9 | 7 | `entry_exposure_value`→`user_contribution`/`floor_seed`; gross/fee/NAV/payout bases | identity, **sort (inverse only)**, pricing, floor, events, validation, replacement | value: **no**; *inversion*: **yes** |
| **leverage** (via `leverage_rank`) | 2 | 14 | `is_leveraged`, `user_contribution`, `floor_seed`, floor-shares, tier policy | **sort**, event term, replacement, mint-tier policy | rank ordering: **yes**; field: **no** |
| **opened_at_ms** | 3 | 4 | `open_floor_index` → `floor_shares` (only) | floor-math (sole), storage | **no** (incidental tie) |
| **boundaries** (lower/higher idx) | 8 | 10 | resolved strikes → pricing, NAV/payout, settlement payoff, floor | identity, pricing, floor, validation, replacement | **no** |
| **entry_probability** | 3 | 5 | `entry_exposure_value` (hub) → `user_contribution`, `floor_seed` | event term, replacement, mint LTV gate, self-verify | **no** (lowest real bits) |
| **sequence** | 2 | 3 | — (uniqueness/tiebreak) | **identity uniqueness**, sort tail | identity-primary, sort-secondary |

Consumer-side facts that drive the analysis:

- **`predict_manager` treats `order_id` as fully opaque** — `PositionKey{expiry_market_id, order_id}`
  membership only; never decodes (`predict_manager.move:57,155,433,559`).
- **`liquidation_book` never decodes a field** — it stores raw `u256` IDs in ascending paged vectors
  and binary-searches with plain numeric `<` (`liquidation_book.move:359-385`); it calls only
  `order.id()` (identity) and `order.is_leveraged()` to gate membership (`:90,98`). The high-bit layout
  *is* the comparator.
- **Events consume derived getters, not raw fields.** `OrderMinted` reports `leverage`,
  `entry_probability`, `quantity`, `contribution` (`user_contribution`), `floor_seed_amount`, plus
  **resolved** `lower_strike`/`higher_strike` (passed in, *not* the packed indices)
  (`order_events.move:96-123`). `opened_at_ms`, boundary indices, `sequence`, and `quantity_lots` are
  **never** emitted directly.
- **`entry_probability` is mint-time + record only.** Live redeem and the liquidation scan **re-quote**
  `range_probability` (`strike_exposure.move:261-268,369-374`); the stored `entry_probability` is read
  post-mint only by the mint LTV gate at insert (`strike_exposure_config.move:235`) and the event.
- **`opened_at_ms` feeds exactly one thing:** `floor_index_at_open` →
  `floor_shares_for_seed = ceil(floor_seed · 1e9 / open_index)` (`strike_exposure_config.move:195-207`),
  recomputed on **every** index touch (mint/close/liquidation-check).

---

## 4. Derived-value dependency graph

```
packed atomic fields                    derived (computed on demand, never stored)
────────────────────                    ──────────────────────────────────────────
entry_probability ─┐
                   ├─► entry_exposure_value = mul(entry_probability, quantity)        [round DOWN]  order.move:268-270
quantity ──────────┘            │
                                ├─► user_contribution = ceil(exposure · 1e9 / leverage) [round UP]  order.move:263-266
leverage ───────────────────────┘            │
                                              └─► floor_seed_amount = exposure − user_contribution    order.move:186-189

opened_at_ms ─┐
              ├─► open_floor_index = floor_index_at_ms(expiry, opened_at)          strike_exposure_config.move:38-67
floor_seed ───┤            │
              └────────────┴─► floor_shares = ceil(floor_seed · 1e9 / open_index)  strike_exposure_config.move:195-207
                                       │
                                       ├─► terminal_floor / floor_at_open / floor_amount_at(now)      :70-78,128-136
                                       └─► terminal_payout = quantity − terminal_floor;
                                           live_backing_payout = quantity − floor_at_open             :136

boundaries (idx) ─► grid.boundary_at_index ─► (lower, higher) strikes ─► pricing / NAV / payout / settlement payoff
```

Three facts this graph makes load-bearing:

1. **The economic subtree has a single root: `entry_probability`** (plus `quantity`, `leverage`).
   Storing any node below the root (`user_contribution`, `floor_seed`, `floor_shares`) is *redundant*
   with the root and *lossy* in reverse (rounding at `:265`, `:202`).
2. **`floor_shares` and the money projections are quantity-dependent.** That is why `replacement` can
   rescale them from the inherited per-unit root but **cannot** from a stored absolute amount.
3. **`floor_shares` additionally depends on per-expiry snapshotted config** (`max_expiry_floor_premium`,
   `expiry_ms`). Baking it into the ID would couple the market-agnostic ID to per-market lifecycle
   state — the exact thing AGENTS.md forbids ("do not encode market-lifecycle facts in the order ID").

---

## 5. Candidate layouts

Money-amount width is the gating number: max `quantity = (2³²−1) · position_lot_size(10_000) ≈
4.29e13`, so `user_contribution` needs **46 bits**, `floor_seed_amount` **45 bits** — neither fits the
32-bit `entry_probability` slot without truncation.

| Candidate | Shape | Bits used (of 256) | Fits? | Sortable? | Self-auth |
|---|---|---|---|---|---|
| **A — keep current** | atomic inputs; derive projections | 232 | ✅ (24 spare) | ✅ unchanged | **full** (single-field check) |
| **B — encode derived** | replace `entry_probability` (u32) with a money amount (u46) | 246 | ✅ (10 spare) | ✅ *if* placed monotone in high bits — **policy change** | **degraded** (cross-field only) |
| **C1 — additive hybrid** | shrink `leverage_rank` 32→3; **add** self-checked `floor_seed` (u45), keep `entry_probability` | 248 | ✅ | ✅ unchanged | full + verifiable redundancy |
| **C2 — lean hybrid** | shrink `leverage_rank` 32→3; replace `entry_probability` with money (u46) | 217 | ✅ (39 spare) | policy change | degraded (== B) |

All four fit `u256`. **Bit budget is not the deciding factor** — self-verifiability is.

### Pros / cons

**A — keep current (recommended)**
- ➕ `entry_probability ≤ 1e9` is self-checkable from one field (`order.move:254`); the ID proves its
  own economic validity at `from_order_id`.
- ➕ Lossless root: event entry-price, mint LTV gate, and proportional replacement all keep their source.
- ➕ Liquidation sort untouched (`inverse_quantity_lots`@200, `leverage_rank`@168); zero risk;
  3 sort tests stay valid.
- ➕ Already matches the stated discipline ("`Order` internally, packed id only at boundaries; derive
  at the leaf").
- ➖ Recomputes the cheap money projections per access; no progress if a non-probability economic root
  is ever needed.

**B — encode derived principal/floor**
- ➕ `floor_seed`/`user_contribution` directly decodable (saves one `mul`/`mul_div` per read).
- ➕ `floor_seed` is monotone in size·leverage, so it remains a valid sort primary key.
- ➖ Loses lossless entry-price reconstruction (`mul_div_round_up`, `:265`); strips
  `OrderMinted.entry_probability` and the mint `gross_value` gate source.
- ➖ Self-verifiability drops to a cross-field invariant; needs a new consistency assert in
  `new()`+`assert_valid` that does not exist today.
- ➖ Absolute stored floor breaks proportional replacement rescaling.
- ➖ Reordering high bits is a **liquidation-priority policy change**, not a transparent re-encode; high
  test + sim-parity churn.

**C1 — additive hybrid (the "if you must" option)**
- ➕ Keeps `entry_probability` (all self-auth/event/gate/replacement properties intact) **and** makes
  `floor_seed` directly decodable, with `assert_valid` able to check `floor_seed == derived(...)` — a
  *genuine* cross-field self-check rather than a weaker bound.
- ➕ Reclaims the wasteful 29 bits in `leverage_rank` (uses 3 of 32) at no semantic cost.
- ➖ Redundant state that must be kept consistent; offset/mask churn + sim-mirror updates; solves a
  problem (decode-without-recompute) that has **no on-chain consumer** today.

**C2 — lean hybrid:** same self-auth losses as B, plus the leverage-field-width migration. Smallest
budget, weakest properties. Not recommended.

---

## 6. Recommendation

**Adopt Option 1 / Candidate A: keep the current bit layout; limit work to helper/boundary hygiene.**
Do **not** encode `user_contribution`/`floor_seed_amount`/`floor_shares`/`open_floor_index`.

The current design uniquely satisfies all three must-keep properties:

1. **Self-verifiable** — `assert_valid` checks `entry_probability` against a single-field domain
   `[0, 1e9]` (`order.move:254`); impossible for the cross-field floor/contribution invariants.
2. **Liquidation-sortable** — `inverse_quantity_lots`@200 and `leverage_rank`@168 feed the raw-`u256`
   ascending sort with no change to `liquidation_book`.
3. **Mint-policy-out-of-decoding** — `assert_mint_leverage_tier` is mint-only (`strike_exposure.move:212`).

Per-field verdicts (all "keep as-is"):

- **quantity** — real contract term; the *inverse* exists only so a descending priority field lives
  inside an ascending `u256` sort. Storing `quantity_lots` directly wouldn't simplify anything: the
  book has no descending comparator, so removing the inversion just relocates it. **Keep.**
- **leverage_rank** — load-bearing on four axes (sort direction, `OrderMinted.leverage` event term,
  `replacement` re-derivation, mint-tier caps). A boolean `is_leveraged` cannot distinguish 2x/2.5x/3x.
  **Keep as a rank.** (Only defensible tweak: width 32→3 bits, unnecessary today.)
- **opened_at_ms** — sole use is the floor-index sample at open. Encoding `floor_shares` breaks
  replacement (quantity-dependent); encoding `open_floor_index` couples the ID to per-expiry config,
  is lossy through the saturating quadratic curve (`strike_exposure_config.move:54-66`), and only
  precomputes 1 of 3 curve evaluations (now/terminal still need the live clock). **Keep the raw
  timestamp.**
- **boundaries** — must stay **indices**: raw strikes don't fit u24 (`pos_inf = u64::max`,
  `constants.move:136`; finite strikes routinely in the billions), and `StrikeGrid` owns the per-expiry
  index↔strike mapping so shape validation stays grid-agnostic. Events already surface resolved
  strikes. **Keep indices.**
- **entry_probability** — the lossless economic root + genuine contract term (event, replacement, mint
  gate). **Keep; it is the field that *should* be stored.**
- **sequence** — per-expiry uniqueness counter + final sort tiebreak; the book's dedup/watermark
  invariants depend on a globally-unique low field. **Keep at bit 0.**

Option 3 (hybrid hardening) collapses into Option 1 because the codebase **already** centralizes
decode at `from_order_id` (`order.move:81-85`; callers `expiry_market.move:526`,
`strike_exposure.move:367`) and strike decode at `order_boundaries` (`strike_exposure.move:429-434`).
Any hardening is documentation/guard polish, foldable into Option 1 as low-risk follow-up.

---

## 7. Risks & tests-to-update *if* encoding is changed anyway

These apply only if Option 2/C2 (or any field-layout change) is later chosen. **Option 1 needs no test
changes.**

**Risks**
- **Self-auth regression must be repaired explicitly.** If `entry_probability` is dropped, the
  single-field check (`:254`) must be replaced by a cross-field consistency assert in **both** `new()`
  and `assert_valid`, or untrusted IDs at `from_order_id` (`expiry_market.move:526`,
  `strike_exposure.move:367`) can decode to economically inconsistent orders.
- **Do not pull policy into decoding.** Any new floor self-check must be a pure structural bound
  (`floor ≤ quantity`), never reference `config.liquidation_ltv` / tier thresholds — those are
  snapshotted admin-tunable values; using them in `assert_valid` would retroactively invalidate stored
  IDs (AGENTS.md violation).
- **Liquidation-priority drift.** Replacing a high-bit field changes *which* orders front-load in the
  gas-bounded head scan — a behavioral/policy change, not a transparent re-encode.
- **Sim-parity drift (no automated check).** `simulations/python_indexes/liquidation_book.py:14-45,79-127`
  (offsets/masks/`leverage_rank`/`encode_order_id`), `simulations/src/sim.ts:64,242-244` (sequence
  mask), and the hand-mirror `analyze_liquidation_priority_encodings.py:87-95` must be updated in
  lockstep or replay parity silently breaks. Confirmed in sync at HEAD.
- **Mint-gate dependency.** The mint LTV gate needs `gross_value = entry_probability · quantity`
  (`strike_exposure_config.move:235`); dropping `entry_probability` forces a re-quote or removal — a
  mint-admission behavior change.

**Tests coupled to the encoding** (grouped by failure mode):
- *Total/field-width literals:* `order_tests.move:298` (`1u256 << 232` total), `:150` (`1<<48`),
  `:165` (`1<<24`), `:281` (`1<<40`).
- *Getter round-trips:* `order_tests.move:79-100`, `:102-120`, `:382-405`;
  `strike_exposure_tests.move:256-277` (asserts decoded `entry_probability == 308_537_539`, `quantity`).
- *Sort-order (most fragile — assert inter-field bit position via raw `id()`):*
  `order_tests.move:308-330` (leverage), `:332-354` (quantity outranks leverage), `:356-378`
  (lower vs higher boundary).
- *Derived-value coupled:* `expiry_market_tests.move:127-131` (`user_contribution`);
  `strike_exposure_tests.move:238-254` / `:256-277` (`entry_probability·quantity` principal gate).
- *Validation/semantic:* `order_tests.move:180-192` (`EInvalidEntryProbability`, disappears if the
  field is dropped), `:194-279`, `:407-421`.
- *Sim mirrors:* `python_indexes/liquidation_book.py:79-127`, `src/sim.ts:64,242-244`.

---

## 8. Questions to ratify before any implementation

1. **Is there a concrete on-chain/indexer requirement to decode `floor_seed`/`user_contribution`
   *without recomputation*?** Evidence: none on chain (all consumers recompute via getters); off-chain
   already receives them verbatim in `OrderMinted` (`order_events.move:116,121`), and `sim.ts` decodes
   only `sequence`. If "no" (expected), Option 1 is strictly correct.
2. **Is there measured gas pressure** behind considering derived encoding? The recompute is one `mul` +
   one `mul_div`. Quantify before trading away self-verifiability.
3. **Is `OrderMinted.entry_probability` a committed off-chain API field** integrators rely on for
   entry-price reporting? If yes, it is not losslessly reconstructible from floor/contribution and
   Option 2 is blocked on the event contract alone.
4. **Must the mint LTV gate keep `entry_probability · quantity`** (`strike_exposure_config.move:235`)?
   If yes, Option 2 is effectively blocked regardless of other factors.
5. **(Orthogonal, the real open question) Should liquidation *priority* change?** The sim tool scores
   `floor_first` / `ltv_headroom` / `floor_lots` layouts against today's `quantity↓ → leverage↓`. This
   is a **risk-policy** decision about *which orders liquidate first*, separate from the term-storage
   question above. If a derived static metric wins empirically, that — and only that — is a principled
   reason to pack a derived value, **in the high bits as the sort primary key** (keeping
   `entry_probability` as the economic root and `sequence` as the unique tail). Ratify independently.
6. **(Option 1 hardening, optional)** Should `from_order_id` be enforced as the *sole* `u256`→`Order`
   decode path (it currently is) by making the raw `Order{id}` constructor inaccessible elsewhere?
