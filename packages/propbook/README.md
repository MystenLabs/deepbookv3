# Propbook

Propbook is a source-oracle package for prediction-market data. It stores source
facts and discovery metadata, but it does not decide whether an observation is
safe for a specific consumer's pricing or settlement math.

## Core Model

Every live source stream is stored through an `oracle_lane::OracleLane<Payload>`.
A lane owns:

- `latest`: the most recent accepted source observation.
- `exact_reads`: insert-only observations keyed by exact source timestamp.
- Generic latest-update and exact-insert events.

An `OracleRead<Value>` wraps a value with two Propbook timestamps:

- `source_timestamp_ms`: source/publisher time, converted to milliseconds.
- `update_timestamp_ms`: Sui clock time when the update landed on chain.

There are two write shapes:

- `update`: latest-state update. It records the read only when
  `source_timestamp_ms` is positive, not ahead of `update_timestamp_ms`, and
  strictly newer than the current latest read. Future, zero, stale, or duplicate
  reads are no-ops.
- `insert_at`: exact timestamp insert. It records the read only when the
  timestamp is valid and no read already exists at that exact source timestamp.
  It does not mutate `latest`; invalid or duplicate inserts are no-ops.

Consumers should use the `source_timestamp_ms` returned on raw or normalized
`OracleRead` values when they need a liveness reference.

## Canonical Propbook Reads And Raw Source Reads

Propbook stores source-native fields and also exposes canonical Propbook
normalized reads for consumers that want normalized values instead of raw source
payloads. Every source module follows the same read pattern:

- `raw_*`: returns `OracleRead<Raw*>` and aborts when the requested raw
  observation does not exist.
- `normalized_*`: returns `Option<OracleRead<*>>`; `none` means the requested
  observation is absent or cannot produce a usable normalized Propbook value.

For Pyth, the raw payload keeps the source price magnitude/sign, exponent
magnitude/sign, and microsecond source timestamp. `normalized_spot()` and the
exact-history normalized spot reads derive a positive 1e9-scaled Propbook spot
from those fields. Missing data, negative source prices, zero normalized spots,
overflow, or unsupported exponent shapes return `none`.

For Block Scholes, raw reads expose source spot plus per-expiry forward and SVI
payloads from permanent source-level feed objects. Normalized spot and forward
reads return `none` when the requested observation is absent or zero; normalized
SVI reads expose the stored SVI parameters directly.

## Exact Timestamp Inserts

Propbook does not have a separate settlement or minute-bucket write mode. Feeds
can insert source-native observations into `exact_reads`, keyed by the exact
source timestamp derived from the update:

- Pyth uses the Lazer source timestamp in microseconds, rounded up to
  milliseconds.
- Block Scholes spot, forward, and SVI use each update's published millisecond
  timestamp directly.

A read for `timestamp_ms` succeeds only if a source observation was inserted or
latest-updated at exactly that timestamp and exposed by the source module's
`*_at` getter. There is no first-transaction-after-minute fallback and no
Propbook-specific "official resolution" policy. Consumers that need a terminal
price should define which exact timestamp they are sampling and read the exact
Propbook value at that timestamp.

## Pyth Feed

`pyth_feed::PythFeed` is one lane for one Pyth Lazer source id. Propbook stores
the source-native price fields from the Lazer update:

- price magnitude and sign
- exponent magnitude and sign
- native source timestamp in microseconds

The 1e9-normalized spot reads are derived from those stored fields. This keeps
the stored oracle data close to what Pyth actually supplied, while still exposing
a non-aborting normalized view for consumers.

Pyth Lazer `Update` values are produced by the Pyth verifier package, so the Move
type system provides provenance for normal Pyth ingestion.

## Block Scholes Feeds

Block Scholes data is split across three shared-object types:

- `block_scholes_spot_feed::BlockScholesSpotFeed`: one source-level spot stream
  per Block Scholes source id.
- `block_scholes_forward_feed::BlockScholesForwardFeed`: one source-level
  forward object per Block Scholes source id, with per-expiry lanes.
- `block_scholes_svi_feed::BlockScholesSVIFeed`: one source-level SVI object per
  Block Scholes source id, with per-expiry lanes.

The spot feed wraps one `OracleLane`; the forward and SVI feeds keep a table of
`expiry_ms -> OracleLane`. Every BS value still uses the same mutation pattern as
Pyth: latest update, exact timestamp insert, and generic lane events.

The BS payloads store raw source fields:

- `bs_source_id`
- `expiry_ms` for forward and SVI feeds
- spot, forward, or SVI params, depending on the feed

Propbook intentionally does not enforce Predict's pricing-safe numeric envelope
on BS ingestion. Consumers such as Predict must validate spot, forward, basis,
SVI bounds, and liveness before using the values in pricing math.

Important caveat: `block_scholes_oracle::update` is currently a stub verifier.
Its `Update` values are forgeable until the real BS signature verifier replaces
the stub. Permissionless BS live updates and exact inserts are not production-safe
while this is true.

Binding caveat: Propbook binds the source-level BS spot feed first, then binds
the permanent forward/SVI surface pair with
`registry::bind_block_scholes_surface_to_underlying`. That function asserts that
the forward feed, SVI feed, and already-bound spot feed all share the same
`bs_source_id`, so consumers do not accidentally combine BS spot/basis data from
different sources for one underlying.

## Registry And Identifiers

`registry::OracleRegistry` owns source discovery and canonical Propbook bindings.
It keeps two namespaces:

- Source catalog: one Propbook oracle object per source key, keyed by
  `(oracle_kind, source_id)`.
- Canonical binding: one active oracle per
  `(propbook_underlying_id, oracle_kind, value_kind)`.

Identifier pattern:

- Source id: source-native identifier, such as `pyth_source_id` or
  `bs_source_id`.
- Propbook oracle object id: shared object id for the Propbook wrapper, such as
  `propbook_pyth_id` or `propbook_block_scholes_spot_id`.
- Propbook underlying id: canonical underlying identifier chosen by Propbook
  governance, such as the id used to mean BTC.
- Source underlying id: source-specific representation of the same underlying,
  when that oracle family has one. Pyth currently uses the Lazer source id as the
  source identifier; there is no additional Pyth source-underlying field in this
  package.

Source wrapper creation is permissionless and only records the source catalog.
Canonical binding is admin-gated because it is the trust claim that a source id
represents a Propbook underlying.

Admin trust model: package init mints one `RegistryAdminCap`, and canonical
bindings are insert-only for whoever holds that cap. Propbook does not implement
on-chain multisig, rotation, timelock, or replacement flows. Production
deployments should treat the cap as governance custody and enforce
multisig/timelock operationally, or add an on-chain governance layer before
relying on registry bindings as an irreversible trust anchor.

Typical discovery question:

> What is the Propbook Pyth oracle object for BTC?

Use `propbook_pyth_id_for_underlying(registry, propbook_underlying_id)`. The
equivalent BS spot lookup is
`propbook_block_scholes_spot_id_for_underlying(registry, propbook_underlying_id)`.
The BS surface lookups are
`propbook_block_scholes_forward_id_for_underlying(registry, propbook_underlying_id)`
and
`propbook_block_scholes_svi_id_for_underlying(registry, propbook_underlying_id)`.

## Events

Propbook emits generic oracle events:

- `ObservationRecorded<OracleRead<Payload>>`
- `ObservationInserted<OracleRead<Payload>>`

For BS forward and SVI rows, the payload includes the expiry, so the
generic event is enough to index per-expiry writes. BS spot is source-level and
does not carry an expiry. Exact-insert events include the source timestamp in the
`OracleRead` envelope.

High-frequency cost caveats:

- `ObservationRecorded` emits for every accepted live update.
- `exact_reads` are unbounded tables. Storage growth is paid by writers; a
  permissionless prune flow can be added later if long-run retention needs it.
- Pyth latest updates are ceil-rounded from microseconds to milliseconds, so two
  source updates inside the same millisecond can collide at the Propbook
  freshness key and the second live update is a no-op. Exact-history inserts are
  stricter: `pyth_feed::insert_at` accepts only source timestamps that are
  already exact whole milliseconds.

## Consumer Responsibilities

Propbook does not own:

- market binding checks
- consumer-specific freshness policy
- pricing-safe numeric envelopes
- DUSDC conversion or forward derivation
- Predict settlement valuation

Consumers should read Propbook as a source-data substrate and apply their own
policy at the point of use. For Predict, the reference pricing-safe envelope
lives in `packages/predict/sources/pricing/pricing.move` around
`assert_inputs_pricing_safe`: it validates spot, forward, basis, SVI bounds, and
freshness after reading Propbook data.
