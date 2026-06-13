# Tick range encoding

> **Status:** proposed pre-deploy design. This document records the intended
> replacement for the current centered `StrikeGrid` / boundary-index encoding.
> Until implemented, the concept docs still describe the current grid-relative
> code path.

Predict positions are range digitals: each order pays if the settlement price
lands in `(lower, higher]`. The current implementation accepts raw strikes at
the public API, validates them against a market-local centered grid, and stores
grid-relative boundary indices in the packed `order_id`. That centered grid was
introduced for dense NAV storage. After the NAV matrix was removed, the centered
origin no longer carries protocol meaning; it mainly forces every order decode to
recover raw strikes through `min_strike + index * tick_size`.

The target design keeps the packed `order_id`, but changes the strike component
to a global tick-range encoding. The protocol's canonical strike representation
becomes absolute ticks from zero, and raw strikes become an SDK, event, and
pricing boundary concern.

## Goals

- Keep `order_id` as the single durable on-chain term store. Do not add an order
  table or per-order object.
- Remove the market-local centered strike grid: no `min_strike`, `max_strike`,
  or grid construction from creation spot.
- Use the same strike representation in public entrypoints, order IDs, and
  internal exposure indexes.
- Keep user-friendly raw strike conversion in SDKs and off-chain tools, where
  rounding policy is visible.
- Keep the existing packed-order liquidation priority: ascending `order_id`
  still sorts larger leveraged positions first through the complemented quantity
  field.

## Canonical representation

Each market still snapshots a feed-specific `tick_size`. A finite strike is
represented as an absolute tick from zero:

```text
finite_strike = tick * tick_size
```

The protocol uses a 24-bit tick domain inside a packed range key:

```text
TICK_BITS = 24
TICK_MASK = (1 << 24) - 1
POS_INF_TICK = TICK_MASK

range_key: u64
bits 0..23    lower_tick
bits 24..47   higher_tick
bits 48..63   reserved, must be zero
```

Finite ticks occupy `1..POS_INF_TICK - 1`. The zero lower tick is the
negative-infinity sentinel. `POS_INF_TICK` is the positive-infinity sentinel when
used as the higher tick. Finite tick zero is deliberately not a strike; Predict
prices positive strikes only, and a lower bound open to zero is represented by
the `-inf` sentinel.

Valid range shapes:

| Shape | Encoding |
| --- | --- |
| Down range `(-inf, strike]` | `lower_tick = 0`, `higher_tick = strike_tick` |
| Up range `(strike, +inf]` | `lower_tick = strike_tick`, `higher_tick = POS_INF_TICK` |
| Finite range `(low, high]` | `0 < lower_tick < higher_tick < POS_INF_TICK` |

Invalid shapes:

- `range_key >> 48 != 0`.
- `lower_tick >= higher_tick`.
- `lower_tick == 0 && higher_tick == POS_INF_TICK` (full outcome space).
- `higher_tick == 0`.
- `lower_tick == POS_INF_TICK`.
- Leveraged orders that are not one-sided. The current leverage invariant remains:
  a leveraged order must have either `lower_tick == 0` or
  `higher_tick == POS_INF_TICK`.

## Public API shape

Public Move entrypoints should accept a packed `range_key` instead of raw
`lower_strike` / `higher_strike` arguments. The SDK should expose higher-level
helpers:

```text
range(lowStrike, highStrike)
up(strike)
down(strike)
rangeFromTicks(lowerTick, higherTick)
```

The default SDK raw-strike conversion should require exact tick alignment. A
silent floor or ceiling changes the economics of `(lower, higher]`, so explicit
helpers should be used when a caller intentionally wants rounding.

On chain, unpacking is simple bit math:

```text
lower_tick = range_key & TICK_MASK
higher_tick = (range_key >> TICK_BITS) & TICK_MASK
assert(range_key >> (2 * TICK_BITS) == 0)
```

Raw strike conversion remains deterministic:

```text
lower_strike = if lower_tick == 0 then neg_inf else lower_tick * tick_size
higher_strike = if higher_tick == POS_INF_TICK then pos_inf else higher_tick * tick_size
```

This conversion is needed only at pricing, settlement comparison, and event
display boundaries. The public API no longer needs to divide raw strikes by
`tick_size`, and mint validation no longer needs grid-origin arithmetic.

## Packed order ID

The order ID keeps the same high-level term set:

```text
quantity_lots | floor_shares | opened_at_ms | range_key | sequence
```

The existing two `u24` boundary-index fields become the two `u24` tick fields.
The surrounding fields and their ordering remain unchanged, so liquidation
priority is preserved:

1. complemented quantity lots (larger quantity sorts earlier),
2. complemented floor shares,
3. opened-at timestamp,
4. tick range,
5. expiry-local sequence.

`Order` should expose tick-range accessors rather than boundary-index accessors.
Callers that need raw strikes must go through the owning market's `tick_size`.
Mint-admission policy stays out of the order ID; the ID remains structural
contract terms only.

## Internal indexes

The sparse exposure indexes should use ticks internally.

### StrikePayoutTree

`StrikePayoutTree` should key finite boundary nodes by tick, not raw strike. This
aligns tree keys with the order ID and public range key. It also avoids repeated
raw-strike arithmetic when inserting and removing ranges.

Pricing still needs raw strikes. The tree should convert a tick to raw strike
only when calling the pricer:

```text
price_at_tick(tick) = pricer.up_price(tick * tick_size)
```

For bounded interpolation, subtree summaries should track min/max ticks instead
of min/max raw strikes; the walk converts only the extreme ticks it prices.

### Settlement liability

Settlement prices are raw oracle prices and may not be tick-aligned. A boundary
at tick `t` is active in the prefix walk only when:

```text
t * tick_size < settlement_price
```

Equivalently, compute a threshold tick:

```text
prefix_limit_tick = ceil(settlement_price / tick_size)
```

and include finite boundaries with `tick < prefix_limit_tick`. This preserves
the half-open payoff `(lower, higher]`: settlement exactly equal to a higher
boundary does not apply the end boundary, so the order still wins at `higher`.

### LiquidationBook

`LiquidationBook` can continue to store only packed order IDs. It decodes the
order's tick range and converts to raw strikes only for live pricing. The book
does not need to store decoded orders or raw strike boundaries.

## Market creation and config

Removing the centered grid means market creation no longer needs a fresh spot
just to build strike geometry. `create_expiry_market` should still validate the
Pyth source binding and snapshot the feed's registered `tick_size`, but fresh
spot can move to the flows that actually price risk: mint, live redeem,
liquidation, and NAV reads. This also removes the current creation-time coupling
between `Registry`, `ExpiryMarket`, and `StrikeExposure` where `pyth.spot()` is
threaded through only so `StrikeGrid::new_centered` can derive `min_strike`.

Market creation should keep taking the `PythSource` reference for source-object
binding and for `MarketOracle` ownership, but it should not require that the
source has a fresh spot or any initialized price state. A new market can be
created with no live quote; it simply cannot admit risk until the normal live
pricing freshness gates pass.

This also removes a boundary smell in `pricing.move`. Today
`pricing::assert_pyth_spot_fresh` is called by `registry::create_expiry_market`,
but live pricing does not treat fresh Pyth as a mandatory invariant: the live
pricer uses Pyth spot when it is fresh and otherwise falls back to a fresh Block
Scholes forward. The standalone "Pyth must be fresh" assertion exists only
because centered grid construction needs a creation-time spot. It is therefore a
grid-construction precondition living in the pricing module, not a pricing
precondition.

The concrete creation changes are:

- Drop `pricing::assert_pyth_spot_fresh` from `registry::create_expiry_market`.
- Drop the `spot` argument from `expiry_market::create_and_share` and
  `strike_exposure::new`.
- Store the snapped `tick_size` directly on the exposure book or on a small
  tick-range codec object; do not store `min_strike` or `max_strike`.
- Keep `MarketOracle::create_and_share` as an oracle-binding constructor. It
  already starts Block Scholes live price state at zero, so removing grid
  construction does not require seeding oracle prices at creation.

`Registry` remains the owner of per-feed `tick_size`. A tick-size update affects
future expiry markets only; already-created markets keep the tick size they
snapshotted. The tick size now controls both precision and maximum finite price:

```text
max_finite_strike = (POS_INF_TICK - 1) * tick_size
```

Feed configuration must choose a tick size that gives enough price precision
while keeping expected market strikes inside the 24-bit tick domain.
Validation should also prevent raw-strike multiplication overflow:

```text
tick_size <= u64::MAX / (POS_INF_TICK - 1)
```

This is a pure config bound; normal market tick sizes should be far below it.

There is deliberately **no** on-chain check that `tick_size` matches the asset's
price scale: such a check would require a creation-time spot read, which is exactly
the coupling this change removes. A mismatched `tick_size` fails loud at first mint
— a too-small tick pushes ATM strikes outside the 24-bit domain, so range-key
construction rejects them; a too-large tick only coarsens granularity. Sizing
`tick_size` to the feed's price scale is an operational/config responsibility, not
a creation-time invariant. (If an oracle-free guard is ever wanted, the only clean
form is an admin-supplied reference price at feed-config time, validated against
`tick_size` — not a spot read.)

## Pricing boundary cleanup

After creation no longer needs `pyth.spot()`, `pricing.move` can become a pure
pricing leaf:

```text
Pricer { forward, svi }
up_price(pricer, strike)
range_price(pricer, lower, higher)
```

It should not import or validate `PythSource`, `MarketOracle`, `Clock`, or
`PricingConfig`. Those objects belong to a live-input resolver or flow loader
whose job is to prove and snapshot the oracle inputs before pure pricing runs.

The live resolver owns the protocol-specific read policy:

- market-oracle binding;
- Pyth/feed binding;
- active-market status;
- Block Scholes price freshness;
- Block Scholes SVI freshness;
- Pyth freshness as a branch condition, not a hard requirement;
- forward selection: `pyth_spot * block_scholes_basis` when Pyth is fresh,
  otherwise the fresh Block Scholes forward;
- construction of `pricing::Pricer`.

This split becomes more important once the oracle objects move into their own
package. Predict should validate that the supplied external feeds match the
market and satisfy Predict's freshness policy, then pass value data into the
pure pricer. Predict should not make the pure pricing math depend on external
oracle object types.

## Events and SDKs

Events should expose the canonical tick range directly where a position is first
created. `OrderMinted` carries `range_key` **permanently as the canonical strike
field**, not as a transition aid. Its value is decoupling: the indexer reads the
range without depending on the packed-`order_id` bit layout (today it must decode
boundary indices out of the u256), which is exactly the decode-struct drift the
indexer rules keep flagging. Raw `lower_strike`/`higher_strike` are derivable
(`tick * tick_size`) and so are optional, display-only convenience; if retained,
mark them as derived so they are never treated as an independent representation —
carrying two competing strike representations in one event is the smell this whole
change exists to remove. Later order events continue to rely on `order_id`: the
range key is embedded in the order ID, and replacement order IDs preserve it.

`MarketCreated` should no longer emit `min_strike` or `max_strike`. Those values
are artifacts of centered grid geometry. It should keep emitting `tick_size`, so
indexers and SDKs can derive raw strikes from tick ranges.

SDKs become the right place for user-facing routing:

- Load the market or feed tick size.
- Convert raw strike inputs to finite ticks, rejecting unaligned values by
  default.
- Build `up`, `down`, or finite `range_key` values.
- Submit the packed range to Move entrypoints.

On-chain helpers should still exist for PTB builders and composability, so
integrators do not have to hand-roll bit shifts in Move.

## Code cleanup surface

Eliminating `StrikeGrid` should remove the remaining grid-relative code rather
than wrapping it in a differently named object.

Source cleanup:

- Remove `strike_exposure/strike_grid.move`.
- Replace `constants::oracle_strike_grid_ticks` and
  `constants::max_boundary_index` with tick-domain constants or helpers in the
  new range/tick codec. Keep `oracle_tick_size_unit`, `neg_inf`, and `pos_inf`
  only if they remain useful as raw price sentinels.
- Rename `Order` constructors and accessors from boundary-index language to
  range/tick language. `new_from_boundary_indices`,
  `lower_boundary_index`, and `higher_boundary_index` should become
  range-key or lower/higher-tick helpers.
- Remove `StrikeExposure.grid`, `StrikeExposure.min_strike`, and
  `StrikeExposure.max_strike`. `StrikeExposure.tick_size` can remain as the
  market's raw-price conversion parameter.
- Replace `StrikeExposure.boundary_indices` and `order_boundaries` with
  tick-range validation and raw conversion helpers.
- Remove `StrikePayoutTree`'s dependency on `StrikeGrid`; insertion and removal
  should take ticks or a validated range key. Rename subtree summary fields from
  `min_strike`/`max_strike` to `min_tick`/`max_tick`.
- Remove `LiquidationBook`'s dependency on `StrikeGrid`; it should decode ticks
  from the order ID and receive `tick_size` only when it must price raw strikes.
- Remove `ExpiryMarket.min_strike` and `ExpiryMarket.max_strike`. Keep
  `tick_size` if public readers need it for SDK/indexer derivation.
- Split `pricing.move` into pure `Pricer` construction from value inputs plus
  pure pricing functions, and a separate live-input resolver/flow loader that
  owns oracle binding, freshness, active-market status, and Pyth-vs-Block
  Scholes forward fallback.
- Remove `pricing::assert_pyth_spot_fresh` as a standalone package API unless a
  future flow has a true Pyth-only precondition. The current caller is a centered
  grid artifact.
- Update `config_events::MarketCreated` to emit `tick_size` without centered
  grid bounds.

Test and tooling cleanup:

- Delete `strike_grid_tests` and replace them with range-key codec tests.
- Update order tests from boundary-index bounds to tick-domain/range-key bounds.
- Remove fixture constraints that require `spot / tick_size` to fall inside the
  `new_centered` window.
- Update pricing reference generation to snap strikes by absolute ticks from
  zero rather than by `min_strike`/`max_strike`.
- Rename helper constants like `min_strike()` where they now mean "default ATM
  finite boundary" rather than "grid minimum".
- Update stale docs that still mention dense NAV storage, grid preallocation,
  compaction, or market-local strike bounds.

## Pricing tail behavior

Removing grid bounds expands the set of encodable strikes, so there are two
distinct "limits" to keep separate. Only the first is a real product bound.

**Encoding cap — the bound you design around.** A finite strike cannot exceed
`(POS_INF_TICK - 1) * tick_size ≈ 16.78M * tick_size`. This is a clean
fail-at-range-construction, and `tick_size` is the lever:

| tick_size | resolution | max encodable strike |
| --- | --- | --- |
| $0.00001 (min) | $0.00001 | ~$168 |
| $0.01 | $0.01 | ~$168k |
| $1 | $1 | ~$16.8M |
| $100 | $100 | ~$1.68B |

Choose `tick_size` so the cap clears any strike you would list, trading resolution
for range. A strike past the cap, or below one tick, is simply not encodable.

**Pricing-conditioning limit — effectively unreachable.** The SVI math is
well-conditioned for moneyness `strike / forward ∈ (~1e-9, ~1.8e10)` — about 19
orders of magnitude. Below `1e-9` the fixed-point `strike_ratio = strike·1e9 /
forward` floors to zero and `compute_nd2` aborts (`EInvalidStrikeRatio`); above
`1.8e10` the `u64` cast in `math::div` wraps. Reaching either requires the forward
to leave the *entire* encodable strike ladder by ~60×–1e10× — at which point the
market is economically dead (settlement is far outside every listed strike). It is
not attacker-constructible at a sane `tick_size` (the attacker picks the strike,
not the forward), and precision degrades smoothly toward the tails — no hidden
cliff inside the window.

**Policy: saturate as cheap insurance, not as a gating fix.** Because the abort is
unreachable for a sanely-sized `tick_size`, saturation hardens against a
misconfigured tick size and the dead-zone window; it is not a correctness blocker.
It is still worth doing — it is two lines and it removes a "prove the forward can
never reach the dead zone" reasoning burden:

- Treat `strike_ratio == 0` as the `neg_inf` limit (`up_price → 1.0`): `strike ≪
  forward ⇒ P(settle > strike) ≈ 1`, the correct economic value, matching the
  existing `neg_inf` branch.
- Compute the ratio in `u128` so the symmetric high tail saturates to `0` instead
  of wrapping.

A standalone reject-at-mint strike-range error is *not* a substitute: it is
redundant with the existing `[min_ask, max_ask]` admission band (a deep tail
prices outside it) and does not cover redeem / NAV / liquidation, which re-price
already-minted orders with no band. Test saturation against the SVI math and the
settlement path.

## Migration impact

This is a pre-deploy design change. No object migration is required if it lands
before deployment. The implementation should still treat it as an order-format
change:

- Rename boundary-index helpers to tick-range helpers.
- Replace `strike_grid` with a small range/tick codec module.
- Update order, exposure, payout-tree, liquidation, events, simulations, and
  docs together.
- Rerun the full Predict Move suite and simulation replay after the conversion.

## Rejected alternatives

### Keep grid-relative boundary indices

This preserves the current code shape but keeps a market-local `min_strike`
whose only remaining purpose is decoding order IDs. It also keeps public raw
strikes and internal boundary indices as two competing representations.

### Store raw strikes in the order ID

Two raw `u64` strikes do not fit in the existing 48 strike bits. Stealing bits
from other fields would weaken quantity, floor, timestamp, or sequence bounds
for little benefit.

### Store `low_tick + width`

This fits, but endpoint ticks are simpler. The payoff is defined by two
boundaries, open-ended sentinels map naturally to endpoint fields, and settlement
logic already reasons about boundary crossings.

### Make `order_id` opaque and store orders separately

This is conceptually clean but adds a per-order storage layer and removes the
main benefit of the packed ID: the ID itself is the durable term store and
liquidation sort key.

---

# Design review — feasibility, tradeoffs, blindspots

> Appended 2026-06-13 after reading the touched paths end to end: `order.move`,
> `strike_grid.move`, `strike_exposure.move`, `strike_payout_tree.move`,
> `liquidation_book.move`, the `registry`/`expiry_market` creation flow,
> `pricing.move`, the order/config event modules, `strike_exposure_config.move`,
> `constants.move`, and the Rust `crates/predict-indexer/src/order_id.rs` decoder.
> Claims below cite the code that backs them.

## Verdict

**Feasible, and the premise is sound. Recommend proceeding, with one hard
requirement and one config-side mitigation.** The hard requirement is that the
"pricing tail behavior" must be resolved by *saturation in the pricing leaf*, not
by reject-at-mint — the doc presents these as interchangeable, and they are not
(§4.1). The mitigation is to replace the sanity check that the centered grid
silently performed (tick-size vs. live spot) with an explicit one, or accept and
document its loss (§4.2). Everything else is mechanical refactor with a wide but
shallow blast radius.

The change is best understood as **collapsing three strike representations into
two.** Today the protocol carries: raw strikes at the public API and as the
payout-treap keys (`strike_payout_tree` keys nodes by raw strike, not by index —
`apply_at`/`new_leaf` at `strike_payout_tree.move:217`,`279`); grid-relative
boundary indices in the packed order ID and the liquidation book's decode
(`liquidation_book::correction_value` at `:83` calls `grid.boundary_at_index`).
The centered grid is the converter between them. The proposal makes **ticks** the
single internal representation (order ID, treap keys, liquidation decode, public
range key) and demotes raw strikes to a boundary concern (pricing, settlement
comparison, events, SDK). That is a real reduction in representational surface,
and it lands precisely because the original reason for the centered origin — the
dense NAV matrix — is already gone (confirmed: `decisions.md:46` still advertises
the "dense paged NAV matrix," which the async-NAV redesign deleted; that doc is
itself stale, exactly as this proposal's premise asserts).

## 1. The premise holds up against the code

- **The centered origin is genuinely vestigial.** The only *logic* consumer of
  `min_strike`/`max_strike` is `strike_grid::assert_finite_boundary`
  (`strike_grid.move:96`); every other reference is a getter, the `MarketCreated`
  event, or a test (grep: 140 `min/max_strike` hits, all in those three buckets).
  The pool/NAV/cash layer (`plp`, `pool_accounting`, `expiry_cash`) contains zero
  strike/grid/tick references. So removing grid geometry cannot perturb backing,
  NAV, or compaction accounting — those read treap *totals* (quantity / payout /
  floor), never strike coordinates.
- **Dropping the creation-time Pyth-spot freshness gate is consistent with how
  mint already works.** `create_expiry_market` calls
  `pricing::assert_pyth_spot_fresh` (`registry.move:299`) only so it can read
  `pyth.spot()` for `new_centered`. Mint itself does **not** require fresh Pyth:
  `live_inputs` (`pricing.move:85`) falls back to `market.block_scholes_forward()`
  when Pyth is stale and only hard-requires fresh Block-Scholes price + SVI. So a
  market created against a stale Pyth can still never *admit risk* until the
  Block-Scholes freshness gates pass — the doc's claim is exactly right, and the
  gate it removes was always a grid artifact, never a risk gate.
- **The packed-ID width is preserved with zero bit-stealing.** Boundary indices
  already occupy two `u24` fields and only used `0..=100_002`
  (`constants::max_boundary_index`); ticks use `0..=2²⁴−1`. Same fields, same
  offsets (`order.move:27-28`), so liquidation priority — complemented quantity,
  then floor, then opened-at, then range, then sequence — is structurally
  untouched. The only observable effect is that *tie-breaking among orders that
  match on quantity/floor/opened-at but differ on range* reorders, which is
  immaterial. Claim #5 in Goals is correct.

## 2. Surface-area: this is a net improvement, in four concrete ways

1. **"Parse, don't validate" for strike alignment.** Today the contract accepts
   raw strikes and rejects misaligned ones at runtime (`EInvalidStrikeGrid` via
   `assert_finite_boundary`). A `range_key` of two `u24` ticks makes misalignment
   *unrepresentable* — there is no malformed value to reject. Validation collapses
   to a bit-width/sentinel check.
2. **Feed-global strike analytics.** Boundary indices are market-local (index *i*
   means a different raw strike per market because `min_strike` differs). Absolute
   ticks are feed-global: tick *i* ⇒ `i·tick_size` for every market on that feed.
   This directly helps the indexer rules — strike-keyed analytics ("open interest
   at strike X across expiries") become a plain tick-field filter instead of a
   per-market `min_strike` join.
3. **Simpler, honester indexer derivation.** `order_id.rs` today decodes
   `lower/higher_boundary_index` (`crates/predict-indexer/src/order_id.rs:44-45`)
   and would need `min_strike + (idx−1)·tick_size` to reach raw strikes. Post-change
   it needs only `tick·tick_size`, and `MarketCreated` no longer has to carry
   `min_strike`/`max_strike` at all — only `tick_size`. Fewer fields, no per-market
   origin, less to keep in sync.
4. **One fewer creation-time object coupling.** Removes the `Registry → ExpiryMarket
   → StrikeExposure` spot-threading that exists only to feed `new_centered`
   (`registry.move:318` → `expiry_market.move:414` → `strike_exposure.move:166`).

## 3. Tradeoffs that are real (not just costs to pay down)

- **"Avoids repeated raw-strike arithmetic" is overstated.** The treap *already*
  keys by raw strike, so it does no per-node strike arithmetic today; pricing reads
  the key directly (`pricer.up_price(strike)` at `strike_payout_tree.move:401`).
  Keying by tick *adds* a `tick·tick_size` multiply at every priced boundary. The
  genuine saving is on the insert side (mint computes one representation — the tick
  — instead of both a boundary index for the ID and a raw strike for the treap),
  and that roughly offsets the new pricing-time multiply. Sell this change on
  *representational unification*, which is real, not on arithmetic reduction, which
  is roughly a wash. Recommend softening that sentence under "StrikePayoutTree."
- **API ergonomics shift off-chain.** Accepting a packed `range_key` instead of
  `lower_strike`/`higher_strike` moves the raw→tick rounding decision (and its
  failure mode) entirely into the SDK. That is the right call for the exact-tick
  property, but it is disruptive: the Move signature breaks, the TS simulation
  harness (`simulations/src/sim.ts`, the sole off-chain mint caller found) must
  pack keys, and naive PTB builders lose a clear on-chain "unaligned strike" error.
  The doc's "keep on-chain pack helpers for composability" mitigates this; it
  should be treated as required, not optional. **This is the one genuine API fork
  worth an explicit decision (§7).**

## 4. Blindspots and risks, ranked

### 4.1 Tail pricing: saturate the leaf (insurance); reject-at-mint is not a substitute

> **Revised 2026-06-13 (numbers run).** The abort is *unreachable* for a
> sanely-sized `tick_size` — it needs the forward to leave the entire encodable
> strike ladder by ~60×–1e10× (worked through in "Pricing tail behavior" above).
> So saturation is **cheap insurance against misconfiguration / the dead-zone
> window, not a gating correctness fix**, and this section's original "necessary"
> framing overstated the severity. The *mechanism* below is still exactly why
> saturation — not reject-at-mint — is the right shape if you harden it.

The doc frames the deep-tail abort as "choose one policy: reject at mint, or
saturate." Reject-at-mint alone does not cover the non-mint paths, for three
reasons grounded in the code:

1. **The abort fires inside pricing, before any admission check can decline
   gracefully.** `allocate_mint_order` prices first
   (`pricer.range_price` at `strike_exposure.move:223`) and only then runs the
   ask-band admission policy (`strike_exposure_config.move:174`). A strike deep
   enough that `strike_ratio = div(strike, forward)` floors to 0 aborts at
   `assert!(strike_ratio > 0, EInvalidStrikeRatio)` (`pricing.move:167`) — so the
   user gets a raw arithmetic abort, not the clean `EAskPriceOutOfBounds` the
   ask-band would otherwise give. The existing `[min_ask, max_ask]` band is in fact
   the *natural* tail guard (a deep-OTM range prices below `min_ask`), but it never
   gets the chance to run.
2. **Redeem, NAV, liquidation, and the keeper liquidation pass have no ask-band at
   all and re-price *already-minted* orders after spot has moved.** A range minted
   when it was near-the-money becomes a deep tail purely because the forward drifts
   — no new mint required. The grid does **not** prevent this today: it bounds
   strikes against *creation-time* spot, not the *current* forward, so the underflow
   is already reachable on a large enough move. Crucially, `walk_linear` prices
   *every* touched boundary (`strike_payout_tree.move:401`), so **one** order whose
   strike has drifted into the underflow regime aborts `current_nav` for the
   *entire market*, and `correction_value` / `close_and_quote_live_order` abort
   liquidation and live redeem for that order. Settlement is the only immune path
   (it compares ticks, never prices). Net: a single deep-tail order can brick NAV,
   redeem, and liquidation for a whole expiry until settlement. Reject-at-mint does
   nothing for this, because the order was admitted when the tail was closer.
3. **Saturation covers all of the above at once.** When `strike_ratio` floors to 0
   the economic limit is unambiguous: `strike ≪ forward` ⇒ `P(settle > strike) ≈ 1`,
   so `up_price` should saturate to `float_scaling!()` — the same value already
   returned for the `neg_inf` sentinel (`pricing.move:149`). The fix is to treat the
   underflow as the `neg_inf` limit rather than asserting. Mint then prices a clean
   ~1.0, the ask-band declines it as intended, and redeem/NAV/liquidation stay live.

**Recommendation:** make saturation the policy and delete `EInvalidStrikeRatio`'s
abort role; keep reject-at-mint, if wanted, only as a *clearer error layered on
top*, never as the mechanism. Tie the saturation explicitly to the existing ask
band in the doc, because the band is what actually keeps the protocol from
becoming counterparty to a tail it cannot price well.

*Symmetric high-tail note (lower priority, pre-existing):* `math::div`
(`math.move:129`) returns `(x·1e9 / y) as u64`; for a near-max tick with a tiny
forward the quotient can exceed `u64::MAX` and the `as u64` **wraps silently** —
mispricing rather than aborting, which is worse. With sane `tick_size` this needs
a ~10¹⁰× crash and is far off, but the widened domain inches toward it. If the
pricer is touched for saturation anyway, compute the ratio in `u128` and saturate
both tails there rather than trusting the `u64` divide.

### 4.2 The centered grid silently validated tick-size against live spot; nothing replaces it

> **Resolved 2026-06-13: no on-chain check.** Mitigation (a) below — a creation-time
> spot read — was rejected: it reintroduces the exact `pyth.spot()` coupling this
> change removes. The decision is (b): no on-chain tick-size-vs-spot validation;
> `tick_size` is sized operationally and a mismatch fails loud at first mint (see
> "Market creation and config"). The analysis below stands as the rationale for why
> the lost guard is acceptable.

`new_centered` asserts `spot_ticks ∈ (ticks/2, ticks]`
(`strike_grid.move:34-35`, `EOracleTickSizeTooLargeForSpot` /
`...TooSmall...`), i.e. it enforced that the configured `tick_size` is within a
sane factor of the asset's live price *at creation*. The proposal deletes this and
replaces it with only the pure overflow bound `tick_size ≤ u64::MAX/(POS_INF_TICK−1)`;
`assert_oracle_tick_size` (`config_constants.move:160`) otherwise checks merely
`>0` and divisibility by `10_000`. So a `tick_size` wildly mismatched to the asset
(e.g. so coarse that ATM strikes round to a handful of ticks, or so fine that spot
exceeds the 24-bit domain and *no* near-the-money strike is encodable) is no longer
caught at creation — it fails later and less legibly at mint. For a pre-deploy
admin-set, per-feed value this is *tolerable*, but it is a fail-fast regression.
**Mitigation options:** (a) keep a one-line creation-time sanity check against
`pyth.spot()` *when a fresh quote happens to be available* (bounds `spot/tick_size`
into the 24-bit domain with margin) without making fresh spot *required*; or (b)
accept the loss and add a pre-deploy operational checklist item that each feed's
`tick_size` is chosen for its price scale. (a) preserves most of the lost guard at
near-zero cost and does not reintroduce the "must have fresh spot to create"
coupling the proposal is right to remove.

### 4.3 The settlement threshold tick is a comparison bound, not a domain tick

The settlement rewrite is **arithmetically correct** — I verified
`tick < ceil(settlement/tick_size)` is exactly equivalent to `tick·tick_size <
settlement`, and that it preserves the half-open `(lower, higher]` semantics
including "settlement equal to `higher` still wins" (proof in §5). But two
implementation traps: `prefix_limit_tick = ceil(settlement/tick_size)` **can
legitimately exceed `POS_INF_TICK`** (settlement above the whole encodable strike
range), so it must live in `u64` and must *not* be run through tick-domain
validation — an implementer who reuses the range-key tick validator on it
introduces a bug. And the `ceil` must not overflow: use
`std::u64::divide_and_round_up`, not `(settlement + tick_size − 1)/tick_size`.
Put the threshold computation in the tick codec next to the half-open invariant so
this logic has exactly one home.

### 4.4 24 bits is a near-permanent commitment, and the range_key's reserved bits don't relax it

The standalone `range_key` reserves bits 48-63 ("must be zero"), which reads like
tick-widening headroom — but the **order ID** has only `u24` slots for each tick
(`order.move:27-28`), with no spare bits adjacent (quantity/floor/opened-at/sequence
consume the rest of the 232-bit layout). So widening ticks past 24 bits later would
require *repacking the order ID* (an order-format change), which the reserved
range_key bits do nothing to enable. The reserved bits are forward-compat for the
*standalone key only*. Recommend: (a) state this asymmetry explicitly so nobody
treats the reserved bits as a tick-widening path; and (b) consciously confirm 24
bits (~16.7M ticks) gives enough simultaneous resolution-and-range for the most
volatile intended feed *before* deploy, since it is effectively fixed afterward.
16.7M ticks is generous for most assets (e.g. spot at 1M ticks ⇒ 1e-6 resolution
and ~16× upside range), but a long-dated, high-vol feed that wants both fine
resolution and wide range is where 24 bits could bind.

### 4.5 The order-format change is a hard lockstep across Move, indexer, and events

`order_id.rs` decodes `lower/higher_boundary_index` and its unit tests pin the
layout against the Move reference IDs (`order_id.rs:17-18`). Renaming the fields to
ticks and changing their *meaning* (absolute, not grid-relative) must land in the
same change as: `market_created_handler` (drop `min_strike`/`max_strike` columns),
`order_minted_handler` (emit/store `range_key`; switch strike derivation to
`tick·tick_size`), the `order_state` pipeline, and `schema.rs`/`models.rs`. The
indexer rules already flag decode-struct drift as a recurring hazard; this enlarges
that obligation. None of it is hard, but it is **not** an on-chain-only change and
should be scoped as a coordinated PR (or a contracts-then-indexer pair with the
event carrying both `range_key` and raw strikes during the transition, which the
doc already proposes for `OrderMinted`).

## 5. Correctness spot-checks I ran (all pass)

- **Settlement equivalence.** For `c = ceil(settlement/tick_size)`: if settlement
  is a multiple `k·tick_size`, `c=k` and `tick<c ⇔ tick≤k−1 ⇔ tick·tick_size <
  settlement`, with `tick=k` correctly excluded (wins *at* `higher`). If
  settlement `= k·tick_size + r`, `0<r<tick_size`, `c=k+1` and `tick≤k` are exactly
  the ticks with `tick·tick_size < settlement`. The existing treap partition
  (recurse-left iff `settlement ≤ strike`) maps to `tick ≥ c`, the complement of
  active — a faithful translation. ✓
- **Encoding bijection.** Down `(−inf,h]`→`(0, h_tick)`, up `(l,+inf]`→`(l_tick,
  POS_INF_TICK)`, finite→`(0<l_tick<h_tick<POS_INF_TICK)`; the four invalid shapes
  mirror today's `assert_valid_order_shape` (`order.move:220`) one-for-one, with
  `0`/`POS_INF_TICK` playing the roles of `neg_inf`/`max_boundary_index`. ✓
- **Liquidation priority.** Range field sits below opened-at and above sequence in
  the sort key; its re-encoding only reorders exact quantity/floor/opened-at ties.
  ✓
- **Floor / leverage / NAV math is grid-independent.** `index_terms`,
  `terminal_payout`, `floor_index_at_ms`, `assert_mint_floor_terms` read quantity,
  floor_shares, and time only — no strike input — so the tick change cannot perturb
  the limited-recourse floor accounting or the round-down reserve↔payout pairing. ✓

## 6. Further improvements worth folding in

- **Give the codec the settlement threshold and both raw-conversion directions.**
  The "small range/tick codec" should own: pack/unpack `range_key`, `tick↔raw`
  both ways, the shape validator, the overflow bound, **and** `prefix_limit_tick`.
  Keeping the half-open settlement rule and the raw conversion in one module means
  the treap, liquidation book, and settlement all share one source of truth (mirrors
  the existing "single owned evaluator" discipline the package already enforces for
  `index_terms`).
- **Let the codec be the saturation owner too,** or at least the place that defines
  the smallest priceable tick, so the pricing leaf and the codec agree on where the
  tail starts.
- **`OrderMinted.range_key` is permanent and canonical (resolved 2026-06-13),** not
  a transition aid — the reason is decoupling the indexer from the packed-`order_id`
  bit layout, not round-trip convenience. Raw strikes are derivable display-only. See
  "Events and SDKs".
- **Rename with intent, per the repo's API rule.** `min_strike()` becoming "default
  ATM finite boundary" (doc §"Test and tooling cleanup") is a semantic change, not a
  rename — give it a new name rather than overloading the old one, or a reviewer will
  read stale meaning into it.

## 7. Decision points for the author

> **Resolved 2026-06-13** (specs above updated to match):
>
> 1. **API shape → `range_key`-in.** Agreed; keep an on-chain pack helper for
>    composability.
> 2. **Tail policy → saturate the pricing leaf as insurance, not a blocker.** The
>    numbers put the abort out of reach at a sane `tick_size` ("Pricing tail
>    behavior" + the §4.1 revision); saturate anyway (`strike_ratio == 0` → 1.0;
>    ratio in `u128` for the high tail). No standalone mint-reject.
> 3. **Tick-size-vs-spot sanity → retired, no spot read.** Sized operationally;
>    fails loud at mint (§4.2).
> 4. **24-bit tick domain → confirmed.** ~16.78M ticks; the `× tick_size` cap in
>    "Pricing tail behavior" is the range lever. Re-confirm it clears the
>    highest-vol feed's ladder before the deploy freeze.
> 5. **Codec ownership → confirmed.** One codec owns pack/unpack, tick↔raw both
>    ways, shape validation, the overflow bound, and `prefix_limit_tick` (§4.3, §6).
> 6. **`OrderMinted.range_key` → permanent, canonical** ("Events and SDKs").
>
> **Still open — implementation coordination, not design:**
>
> - **Scope of the "Pricing boundary cleanup" (pure-pricer / live-resolver split).**
>   It is *not* required by tick-range (which needs only the tail saturation and
>   tick↔raw at the range boundary) and it competes for `pricing.move` with the
>   versioning-and-loaders flow loaders and the oracle extraction. Keep it out of the
>   tick-range PR; let the oracle/loader work own it.
> - **Order-format lockstep** across Move / `order_id.rs` / handlers / schema / tests
>   (§4.5).
> - **Sequencing against in-flight NAV.** tick-range and the pool/supply-mark layer
>   are file-disjoint; the two real touch-points are the `pricing.move` saturation
>   edit and the tree `min/max_strike → min/max_tick` summary rename. Confirm the
>   per-expiry tree machinery is frozen before parallelizing.
> - **Codec statefulness.** Store `tick_size: u64` on `StrikeExposure` and make the
>   codec a stateless module, rather than a `TickCodec { tick_size }` value struct —
>   a single-field wrapper is the "shuttle-only wrapper" the repo's simplicity rules
>   discourage.
