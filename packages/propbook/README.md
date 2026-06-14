# Propbook

Propbook is a source-oracle package for prediction-market data. It stores source
facts and discovery metadata, but it does not decide whether an observation is
safe for a specific consumer's pricing or settlement math.

## Core Model

Every live source stream is stored through an `oracle_lane::OracleLane<Payload>`.
A lane owns:

- `latest`: the most recent accepted source observation.
- `first_observed_minutes`: the first accepted on-chain observation for each
  rounded source minute.
- `official_settlements`: exact-timestamp official settlement observations.
- Generic observation and official-settlement events.

An `OracleObservation<Payload>` wraps source-native payload data with two
Propbook timestamps:

- `source_timestamp_ms`: source/publisher time, converted to milliseconds.
- `update_timestamp_ms`: Sui clock time when the update landed on chain.

Normal live updates are strictly advancing by `source_timestamp_ms`. A stale or
same-timestamp update aborts. Consumers should use `freshness_timestamp_ms()`,
which is the latest source timestamp, when they need a liveness reference. Live
updates reject source timestamps that are ahead of the on-chain landing time, so
freshness is source time under that invariant.

## Canonical Propbook Reads And Raw Source Reads

Propbook stores source-native fields and also exposes canonical Propbook
convenience reads for consumers that want normalized values instead of raw source
payloads.

For Pyth, the raw payload keeps the source price magnitude/sign, exponent
magnitude/sign, and microsecond source timestamp. The canonical `spot()` /
`normalized_spot_1e9()` read derives a positive-only 1e9-scaled Propbook spot
from those fields. Negative source prices, overflow, or unsupported exponent
shapes abort during that convenience normalization. Consumers that want to own
that policy themselves should use the raw payload getters instead.

Read getters are not all total. Pyth `latest_observation()` and `spot()` abort
until `has_latest()` is true. BS surface reads abort until `has_expiry(expiry)`
is true. Settlement reads abort unless the exact official settlement timestamp
was recorded. Integrators should call the relevant `has_*` function first when
they need non-aborting control flow.

## Settlement Observations

Official settlement writes do not take a caller-supplied resolution timestamp.
The resolution key is derived from the update itself:

- Pyth uses the Lazer source timestamp in microseconds, rounded up to
  milliseconds.
- Block Scholes uses the update's published millisecond timestamp directly.

The official settlement table is exact-timestamp and write-once. A read for
`resolution_timestamp_ms` succeeds only if official data was recorded at exactly
that timestamp. It does not fall back to first-observed minute data.

First-observed history is separate. It is keyed by
`(source_timestamp_ms / 60_000) * 60_000`, and the first accepted transaction for
that source minute wins. Later updates in the same minute never backfill or
replace the bucket.

## Pyth Feed

`pyth_feed::PythFeed` is one lane for one Pyth Lazer source id. Propbook stores
the source-native price fields from the Lazer update:

- price magnitude and sign
- exponent magnitude and sign
- native source timestamp in microseconds

The 1e9-normalized spot getter is derived from those stored fields. This keeps
the stored oracle data close to what Pyth actually supplied, while still exposing
a positive-only convenience read for consumers.

Pyth Lazer `Update` values are produced by the Pyth verifier package, so the Move
type system provides provenance for normal Pyth ingestion.

## Block Scholes Feed

`block_scholes_feed::BlockScholesFeed` is one shared object for one Block Scholes
source id. It stores a table of per-expiry lanes. At the individual expiry level,
BS and Pyth use the same mutation pattern: latest, first-observed history,
official settlement history, and generic events all come from `OracleLane`.

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
the stub. Permissionless BS live updates and official settlement writes are not
production-safe while this is true.

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

- `ObservationRecorded<OracleObservation<Payload>>`
- `OfficialSettlementRecorded<OracleObservation<Payload>>`

For BS, the payload includes the expiry, so the generic event is enough to index
per-expiry writes. Official settlement events include the exact
`resolution_timestamp_ms` derived from the source update.

High-frequency cost caveats:

- `ObservationRecorded` emits for every accepted live update.
- `first_observed_minutes` and `official_settlements` are unbounded dynamic-field
  tables. Storage growth is paid by writers; a permissionless prune flow can be
  added later if long-run retention needs it.
- Pyth source timestamps are ceil-rounded from microseconds to milliseconds, so
  two source updates inside the same millisecond collide at the Propbook freshness
  key and the second live update aborts as stale. The expected source cadence is
  below 1 kHz per feed. Theoretical 1 ms future-source aborts from ceil rounding
  are not expected on Sui because block latency is far above 1 ms.

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
