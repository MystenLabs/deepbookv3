# Propbook Block Scholes Feed Split Design

**Date:** 2026-06-23
**Status:** Approved design

## Goal

Split Propbook's current monolithic Block Scholes feed into independent shared
objects for spot, forward, and SVI data while preserving Predict's existing
pricing behavior. The split should improve oracle coordination and shared-object
parallelism without turning Propbook source objects into canonical trust claims.

## Current State

`propbook::block_scholes_feed::BlockScholesFeed` is currently one shared object
per Block Scholes source ID. It stores a table of per-expiry oracle lanes. Each
expiry row stores one raw surface containing:

- `spot`
- `forward`
- `SVIParams`

Predict reads `normalized_surface(expiry)`, validates that the feed object is
the current canonical Block Scholes feed for the market's underlying, checks
freshness, then computes:

- fresh Pyth path: `forward = pyth_spot * (bs_forward / bs_spot)`
- fallback path: `forward = bs_forward`

Predict also applies its own pricing-safe envelope at this boundary. Propbook
stores source facts and remains Predict-unaware.

## Decisions

1. Delete the monolithic `BlockScholesFeed` entirely. No backwards compatibility
   wrapper is needed because the contracts are pre-deploy.
2. Add three independent Block Scholes feed modules and shared object types:
   `BlockScholesSpotFeed`, `BlockScholesForwardFeed`, and
   `BlockScholesSVIFeed`.
3. Key physical feed objects by source identity, not by
   `propbook_underlying_id`.
4. Keep canonical trust and consumer discovery in `registry`.
5. Keep canonical bindings insert-only.
6. Keep feed creation separate for spot, forward, and SVI. Do not add a combined
   creation helper.
7. Replace the Block Scholes verifier stub's combined update with separate spot,
   forward, and SVI update types/functions.
8. Keep `insert_at` endpoints available on all three new feed objects, even
   though forward and SVI do not currently need exact timestamp history.
9. Preserve Predict's pricing behavior, but read BS spot, BS forward, and SVI
   from separate feeds.
10. Keep BS spot and BS forward on the current Block Scholes freshness threshold.
    Add a separate SVI freshness threshold of 60 seconds.

## Propbook Feed Model

### BlockScholesSpotFeed

One shared object per `bs_source_id`.

Stored fields:

- `id: UID`
- `bs_source_id: u32`
- `version: u64`
- `lane: OracleLane<RawSpot>`

Raw payload:

- `bs_source_id: u32`
- `spot: u64`

Normalized read:

- returns `Option<OracleRead<u64>>`
- returns `none` when spot is zero

Public read/write shape should mirror `pyth_feed` where practical:

- `id`
- `bs_source_id`
- `version`
- `raw_spot`
- `normalized_spot`
- `raw_spot_at`
- `normalized_spot_at`
- raw field getters
- `update`
- `insert_at`
- `migrate`

### BlockScholesForwardFeed

One shared object per `(bs_source_id, expiry_ms)`.

Stored fields:

- `id: UID`
- `bs_source_id: u32`
- `expiry_ms: u64`
- `version: u64`
- `lane: OracleLane<RawForward>`

Raw payload:

- `bs_source_id: u32`
- `expiry_ms: u64`
- `forward: u64`

Normalized read:

- returns `Option<OracleRead<u64>>`
- returns `none` when forward is zero

Public read/write shape:

- `id`
- `bs_source_id`
- `expiry_ms`
- `version`
- `raw_forward`
- `normalized_forward`
- `raw_forward_at`
- `normalized_forward_at`
- raw field getters
- `update`
- `insert_at`
- `migrate`

Updates must assert both `source_id` and `expiry_ms` match the object.

### BlockScholesSVIFeed

One shared object per `(bs_source_id, expiry_ms)`.

Stored fields:

- `id: UID`
- `bs_source_id: u32`
- `expiry_ms: u64`
- `version: u64`
- `lane: OracleLane<RawSVI>`

Types:

- keep `SVIParams` in the SVI feed module unless a shared Propbook type module
  becomes cleaner during implementation
- `rho` and `m` remain signed `fixed_math::i64::I64`

Raw payload:

- `bs_source_id: u32`
- `expiry_ms: u64`
- `svi: SVIParams`

Normalized read:

- returns `Option<OracleRead<SVIParams>>`
- does not apply Predict's pricing-safe envelope
- returns `some` when an observation exists, because Propbook is not responsible
  for SVI validity policy

Public read/write shape:

- `id`
- `bs_source_id`
- `expiry_ms`
- `version`
- `raw_svi`
- `normalized_svi`
- `raw_svi_at`
- `normalized_svi_at`
- raw field getters
- SVI param getters
- `update`
- `insert_at`
- `migrate`

Updates must assert both `source_id` and `expiry_ms` match the object.

## Block Scholes Verifier Stub

Replace the current combined `Update` type with three stub update types and
constructors. The package remains explicitly unverified until the production
signature verifier replaces the stub.

### SpotUpdate

Fields:

- `source_id: u32`
- `published_at_ms: u64`
- `spot: u64`

Constructor:

- `new_spot_update(source_id, published_at_ms, spot): SpotUpdate`

### ForwardUpdate

Fields:

- `source_id: u32`
- `expiry_ms: u64`
- `published_at_ms: u64`
- `forward: u64`

Constructor:

- `new_forward_update(source_id, expiry_ms, published_at_ms, forward): ForwardUpdate`

### SVIUpdate

Fields:

- `source_id: u32`
- `expiry_ms: u64`
- `published_at_ms: u64`
- `svi_a: u64`
- `svi_b: u64`
- `svi_sigma: u64`
- `svi_rho_magnitude: u64`
- `svi_rho_is_negative: bool`
- `svi_m_magnitude: u64`
- `svi_m_is_negative: bool`

Constructor:

- `new_svi_update(...)`

Each Propbook feed accepts only its matching update type.

## Registry Model

Keep the registry's two-namespace design:

- source catalog: permissionless source object discovery
- canonical bindings: insert-only admin trust claims

Do not add a separate oracle bundle/coordinator object. The registry remains the
coordinator, and Predict validates current bindings at the pricing boundary.

### Source Catalog

Pyth spot remains unchanged.

Block Scholes sources become:

- BS spot source: one object per `bs_source_id`
- BS forward source: one object per `(bs_source_id, expiry_ms)`
- BS SVI source: one object per `(bs_source_id, expiry_ms)`

The current `OracleSourceKey { oracle_kind, source_id: u32 }` is not sufficient
for per-expiry feeds. Add an explicit source key shape that can include
`expiry_ms`; do not pack expiry into a fake `u32` source ID.

### Canonical Bindings

Underlying-level bindings:

- `(propbook_underlying_id, pyth_spot)` -> `PythFeed`
- `(propbook_underlying_id, bs_spot)` -> `BlockScholesSpotFeed`

Expiry-level bindings:

- `(propbook_underlying_id, expiry_ms, bs_forward)` -> `BlockScholesForwardFeed`
- `(propbook_underlying_id, expiry_ms, bs_svi)` -> `BlockScholesSVIFeed`

The existing binding key is not sufficient because forward and SVI need
expiry-aware canonical lookup. Add an explicit expiry-aware binding key rather
than overloading value kinds.

### Typed Registry API

Add typed source creation helpers:

- `create_and_share_block_scholes_spot_feed(registry, bs_source_id, ctx)`
- `create_and_share_block_scholes_forward_feed(registry, bs_source_id, expiry_ms, ctx)`
- `create_and_share_block_scholes_svi_feed(registry, bs_source_id, expiry_ms, ctx)`

Add typed canonical binding helpers:

- `bind_block_scholes_spot_to_underlying(registry, admin_cap, feed, underlying)`
- `bind_block_scholes_forward_to_underlying_expiry(registry, admin_cap, feed, underlying)`
- `bind_block_scholes_svi_to_underlying_expiry(registry, admin_cap, feed, underlying)`

The forward/SVI binding helpers should derive `expiry_ms` from the passed feed
object, not take an unchecked primitive expiry.

Add typed lookup and metadata helpers for all new canonical bindings.

## Predict Integration

Predict priced flows should accept:

- `PythFeed`
- `BlockScholesSpotFeed`
- `BlockScholesForwardFeed`
- `BlockScholesSVIFeed`
- `OracleRegistry`

`pricing::load_live_pricer` remains the sole boundary from Propbook oracle state
into Predict business logic.

### Binding Validation

Before reading values, `load_live_pricer` must validate:

- `PythFeed` matches the current underlying-level Pyth binding
- `BlockScholesSpotFeed` matches the current underlying-level BS spot binding
- `BlockScholesForwardFeed` matches the current expiry-level BS forward binding
- `BlockScholesSVIFeed` matches the current expiry-level BS SVI binding

Market creation should require all required current bindings to exist:

- Pyth spot for the underlying
- BS spot for the underlying
- BS forward for the market expiry
- BS SVI for the market expiry

Live pricing still re-validates current bindings every time, so a creation-time
check is only an admission guard against creating an immediately unpriceable
market.

### Freshness

Use these freshness windows:

- Pyth spot: existing `pyth_spot_freshness_ms`
- BS spot: existing Block Scholes freshness threshold, renamed to
  `block_scholes_price_freshness_ms`
- BS forward: `block_scholes_price_freshness_ms`
- BS SVI: new `block_scholes_svi_freshness_ms`, default `60_000`

Replace the current `block_scholes_surface_freshness_ms` field/getter/setter
with `block_scholes_price_freshness_ms`, preserving the current default and
validation envelope. Add a new default/assert/getter/setter path for
`block_scholes_svi_freshness_ms`.

### Pricing Behavior

Keep current behavior:

- read BS spot
- read BS forward
- read SVI
- if fresh Pyth spot exists, compute `forward = pyth_spot * (bs_forward / bs_spot)`
- otherwise use `forward = bs_forward`
- price ranges against the selected forward and SVI params

### Safety Envelope

Rename the conceptual envelope from "surface safety" to "combined input safety".
It should still enforce the same facts:

- BS spot > 0
- BS forward > 0
- BS forward <= current forward ceiling
- `(bs_forward / bs_spot)` basis <= current basis ceiling
- Pyth spot <= current spot ceiling when used
- SVI params stay within Predict's fixed-point pricing envelope
- `abs(rho) <= 1`
- sigma remains within Predict's accepted range

Propbook continues not to enforce these Predict-specific bounds.

## Events and Indexing

Keep using generic `oracle_lane` events:

- `ObservationRecorded<OracleRead<Payload>>`
- `ObservationInserted<OracleRead<Payload>>`

Payload types will change because BS spot, forward, and SVI are now separate
feeds. Indexers should distinguish the feed object type and payload type rather
than depending on a monolithic surface payload.

Registry events should reflect the new typed source and binding events through
their existing generic fields or equivalent expanded metadata.

## Relayer Shape

The relayer should discover separate feed IDs and send separate calls:

- BS spot update:
  - verifier stub creates `SpotUpdate`
  - call `block_scholes_spot_feed::update`

- BS forward update:
  - verifier stub creates `ForwardUpdate`
  - call `block_scholes_forward_feed::update`

- BS SVI update:
  - verifier stub creates `SVIUpdate`
  - call `block_scholes_svi_feed::update`

SVI does not need to update at the same cadence as spot or forward. It only
needs to stay within Predict's 60 second SVI freshness window.

Forward and SVI exact inserts are not currently used, but their endpoints remain
available for consistency with the feed abstraction.

## Testing Scope

Propbook tests:

- separate BS spot feed latest and exact-insert tests
- separate BS forward feed latest and exact-insert tests
- separate BS SVI feed latest and exact-insert tests
- source mismatch and expiry mismatch abort tests
- version/migration tests for each feed type
- registry tests for source catalog uniqueness
- registry tests for underlying-level BS spot binding
- registry tests for expiry-level BS forward and SVI binding
- no tests for the deleted monolithic `BlockScholesFeed`

Predict tests:

- pricing happy path with split BS feeds
- Pyth fresh path still re-anchors forward from BS basis
- stale/missing Pyth fallback still uses BS forward directly
- BS spot and BS forward stale checks use the existing threshold
- SVI stale check uses 60 seconds
- missing/wrong BS spot, forward, and SVI feed guards
- market creation guard for missing required oracle bindings
- pricing-safe combined input envelope rejects invalid combined inputs

Docs and simulations:

- update `packages/propbook/README.md`
- update Propbook product and relayer docs
- update Predict oracle/pricing docs and glossary
- update Predict simulation and test helpers that construct or pass BS feeds

## Out of Scope

- On-chain rebind or replace support for canonical bindings
- A new oracle bundle/coordinator shared object
- Backwards compatibility wrappers for the old `BlockScholesFeed`
- Moving Predict-specific pricing-safe validation into Propbook
- Making the Block Scholes verifier production-safe
