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

For Block Scholes, raw surface reads expose the source spot, forward, and SVI
payload. Normalized surface reads return `none` when the requested observation is
absent or the surface has zero spot or zero forward.

## Exact Timestamp Inserts

Propbook does not have a separate settlement or minute-bucket write mode. Feeds
can insert source-native observations into `exact_reads`, keyed by the exact
source timestamp derived from the update:

- Pyth uses the Lazer source timestamp in microseconds, rounded up to
  milliseconds.
- Block Scholes uses the update's published millisecond timestamp directly.

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

## Block Scholes Feed

`block_scholes_feed::BlockScholesFeed` is one shared object for one Block Scholes
source id. It stores a table of per-expiry lanes. At the individual expiry level,
BS and Pyth use the same mutation pattern: latest update, exact timestamp insert,
and generic events all come from `OracleLane`.

The BS payload stores raw source fields:

- `bs_source_id`
- `expiry_ms`
- spot
- forward
- SVI params

Propbook intentionally does not enforce Predict's pricing-safe numeric envelope
on BS ingestion. Consumers such as Predict must validate spot, forward, basis,
SVI bounds, and liveness before using the surface in pricing math.

Important caveat: `block_scholes_oracle::update` is currently a stub verifier.
Its `Update` values are forgeable until the real BS signature verifier replaces
the stub. Permissionless BS live updates and exact inserts are not production-safe
while this is true.

Throughput caveat: one BS shared object stores all expiries for a source, so all
BS writes for that source serialize on that object. The intended high-frequency
path is to use PTBs that update multiple expiries together. If a future source
needs independent parallel writes across expiries, the next design would shard BS
into one shared object per `(source_id, expiry_ms)` and move the per-expiry
mapping into the registry.

## Registry And Identifiers

`registry::OracleRegistry` owns source discovery and canonical Propbook bindings.
It keeps two namespaces:

- Source catalog: one Propbook oracle object per `(oracle_kind, source_id)`.
- Canonical binding: one active oracle per
  `(propbook_underlying_id, oracle_kind, value_kind)`.

Identifier pattern:

- Source id: source-native identifier, such as `pyth_source_id` or
  `bs_source_id`.
- Propbook oracle object id: shared object id for the Propbook wrapper, such as
  `propbook_pyth_id` or `propbook_block_scholes_id`.
- Propbook underlying id: canonical underlying identifier chosen by Propbook
  governance, such as the id used to mean BTC.
- Source underlying id: source-specific representation of the same underlying,
  when that oracle family has one. Pyth currently uses the Lazer source id as the
  source identifier; there is no additional Pyth source-underlying field in this
  package.

Source wrapper creation is permissionless and only records the source catalog.
Canonical binding is admin-gated because it is the trust claim that a source id
represents a Propbook underlying.

Admin trust model: package init mints one `RegistryAdminCap`, and canonical bind
or rebind is immediate for whoever holds that cap. Propbook does not implement
on-chain multisig, rotation, timelock, or two-step rebinds. Production deployments
should treat the cap as governance custody and enforce multisig/timelock
operationally, or add an on-chain governance layer before relying on registry
bindings as an irreversible trust anchor.

Typical discovery question:

> What is the Propbook Pyth oracle object for BTC?

Use `propbook_pyth_id_for_underlying(registry, propbook_underlying_id)`. The
equivalent BS lookup is
`propbook_block_scholes_id_for_underlying(registry, propbook_underlying_id)`.

## Events

Propbook emits generic oracle events:

- `ObservationRecorded<OracleRead<Payload>>`
- `ObservationInserted<OracleRead<Payload>>`

For BS, the payload includes the expiry, so the generic event is enough to index
per-expiry writes. Exact-insert events include the source timestamp in the
`OracleRead` envelope.

High-frequency cost caveats:

- `ObservationRecorded` emits for every accepted live update.
- `exact_reads` are unbounded tables. Storage growth is paid by writers; a
  permissionless prune flow can be added later if long-run retention needs it.
- Pyth source timestamps are ceil-rounded from microseconds to milliseconds, so
  two source updates inside the same millisecond collide at the Propbook freshness
  key and the second live update is a no-op. The expected source cadence is below
  1 kHz per feed.

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
`assert_surface_pricing_safe`: it validates spot, forward, basis, SVI bounds, and
freshness after reading Propbook data.
