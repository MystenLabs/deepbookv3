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

## Events and SDKs

Events should expose the canonical tick range directly where a position is first
created. `OrderMinted` should emit `range_key` alongside any raw
`lower_strike`/`higher_strike` fields retained for indexer and UI convenience.
Later order events can continue to rely on `order_id`: the range key is embedded
in the order ID, and replacement order IDs preserve the same range key.

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

Removing grid bounds expands the set of encodable strikes. That is intentional,
but pricing must handle tails deliberately. Today deep low strikes can make
`strike / forward` round to zero before `ln`, which aborts. The implementation
should choose one policy:

- Reject such ranges at mint with a clear strike-range error; or
- Saturate deep tails in pricing, returning the appropriate near-0 or near-1
  probability without aborting.

Saturation is the cleaner long-term behavior for a sparse, unbounded-by-grid
range model, but it must be tested against the SVI math and settlement paths.

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
