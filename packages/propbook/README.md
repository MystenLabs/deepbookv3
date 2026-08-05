# Propbook

Propbook is a source-oracle package for prediction-market data. It stores source
facts and discovery metadata, but it does not decide whether an observation is
safe for a specific consumer's pricing or settlement math.

## Pyth Lane Model

Every Pyth live source stream is stored through an `oracle_lane::OracleLane<Payload>`.
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

Pyth consumers should use the `source_timestamp_ms` returned on raw or normalized `OracleRead` values when they need a liveness reference. Block Scholes uses its latest-only typed stores and `BsRead` clocks described below.

## Canonical Propbook Reads And Raw Source Reads

Propbook stores source-native fields and also exposes canonical Propbook normalized reads for consumers that want normalized values instead of raw source payloads. Pyth modules follow this read pattern:

- `raw_*`: returns `OracleRead<Raw*>` and aborts when the requested raw
  observation does not exist.
- `normalized_*`: returns `Option<OracleRead<*>>`; `none` means the requested
  observation is absent or cannot produce a usable normalized Propbook value.

For Pyth, the raw payload keeps the source price magnitude/sign, exponent
magnitude/sign, and the microsecond time at which Pyth generated the price.
`normalized_spot()` and the
exact-history normalized spot reads derive a positive 1e9-scaled Propbook spot
from those fields. Missing data, negative source prices, zero normalized spots,
overflow, or unsupported exponent shapes return `none`.

For Block Scholes, latest-only typed reads expose source spot plus per-expiry forward and SVI payloads from permanent stores. Spot and forward reads return `none` when the requested observation is absent; SVI reads expose the stored provider parameters directly.

## Exact Timestamp Inserts

Propbook does not have a separate settlement or minute-bucket write mode. Pyth feeds can insert source-native observations into `exact_reads`, keyed by the exact source timestamp derived from the update:

- Pyth uses the Lazer envelope timestamp in microseconds, which must already be an
  exact whole millisecond. The envelope at a tick carries Pyth's canonical price as
  of that tick, so a consumer settling at the tick resolves the right mark even when
  Pyth generated that price earlier and carried it forward.

A Pyth read for `timestamp_ms` succeeds only if a source observation was inserted at exactly that timestamp and exposed by the source module's `*_at` getter. There is no first-transaction-after-minute fallback and no Propbook-specific "official resolution" policy. Block Scholes stores retain only the latest observation per series and expose no exact-history getter.

## Pyth Feed

`pyth_feed::PythFeed` is one lane for one Pyth Lazer source id. Propbook stores
the source-native price fields from the Lazer update:

- price magnitude and sign
- exponent magnitude and sign
- the per-feed `feedUpdateTimestamp` in microseconds: when Pyth generated this price

The 1e9-normalized spot reads are derived from those stored fields. This keeps
the stored oracle data close to what Pyth actually supplied, while still exposing
a non-aborting normalized view for consumers.

Pyth Lazer `Update` values are produced by the Pyth verifier package, so the Move
type system provides provenance for normal Pyth ingestion.

### Two Clocks: Envelope And Generation Time

A Lazer update carries two timestamps. The envelope `timestamp()` is when the signed
update was published. The per-feed `feedUpdateTimestamp` is when Pyth generated the
price the update carries. They are equal only when the update carries a freshly
generated aggregate; when Pyth has no new aggregate for a feed it carries the previous
price forward under a newer envelope, leaving `feedUpdateTimestamp` at the earlier
generation time. Subscribing clients must request the `feedUpdateTimestamp` property,
or ingestion aborts `ELazerValueUnavailable`.

The two lanes key on different clocks because they answer different questions:

- `latest` keys on the generation time, because a consumer asking "how old is this
  price?" wants its true age. Redelivering a carried price does not advance the
  generation time, so `lane::update` treats it as non-advancing and leaves `latest`
  untouched — a carried price ages out of a consumer's freshness window on schedule
  instead of looking permanently fresh.
- `exact_reads` keys on the envelope, because a consumer asking "what was the price at
  tick T?" wants the canonical mark as of T. Pyth guarantees the envelope at T holds
  the freshest aggregate as of T, so an envelope-keyed row is the right answer even
  when the price it carries was generated earlier. The stored payload retains the
  generation time, so the settled price's true age stays legible.

Canonical is not the same as fresh. The ordering guarantee fixes *which* price belongs
to a tick; it does not bound how long before that tick the price was generated. During
a stall the canonical price at a tick can be arbitrarily old, and an exact key is
insert-only, so the first writer's row owns that tick permanently. Exact inserts
therefore also require the carry to be within `constants::max_settlement_carry_ms`
(`ESettlementCarryExceedsWindow`); the bound is compiled rather than caller-supplied
because the write is permissionless. The bound applies only to exact inserts — a longer
carry still lands on `latest` with its true age, where read-time freshness ages it out.

A generation time later than its envelope is rejected (`EFeedTimestampAfterEnvelope`).

## Block Scholes Stores

Block Scholes data lives in two per-underlying shared objects:

- `block_scholes_store::BlockScholesValueStore`: latest spot and forward observations for one immutable provider base asset, keyed by signed series id.
- `block_scholes_store::BlockScholesSVIStore`: latest SVI parameter sets, bound to the same base asset and keyed by signed series id.

Writes are permissionless and enter only through `apply_spot_batch`, `apply_forward_batch`, and `apply_svi_batch`, which take a batch type that only the Block Scholes verifier (`bs_oracle::verify`) can mint — holding one is proof of a valid provider signature, so the relayer that lands it is untrusted. The registry binds each store pair to the exact provider base-asset spelling at creation. `block_scholes_sid` delegates to the provider-owned `bs_sid` package to derive the canonical spot, forward, and SVI ids from the oracle package, complete subscription descriptor, value scale, timestamp precision, and expiry. Each typed write derives the ids admitted by that store and requires the signed updates to match in order; forward and SVI callers supply expiry witnesses, which are checked through the derived ids before storage. Reads derive the same ids internally rather than accepting one from a caller.

Each stored observation carries three clocks: the provider model time the
series data is "as of" (held fixed across retransmissions of an unchanged
value; the provider's per-series replay key and the clock consumers price
from), the batch envelope time (transport metadata, advancing on every
provider flush), and the Sui execution time. A series' latest observation is
ordered lexicographically on (model time, envelope time): newer model data
always wins regardless of the order a relayer lands batches in, and an equal
model time advances only with a fresher envelope — a retransmission updates
transport metadata without making the data economically newer. A model time
later than its own envelope is provider garbage and is skipped, mirroring the
Pyth lane's `EFeedTimestampAfterEnvelope`; that bound is also what keeps
Predict's SVI roll-down anchor strictly before any live market's expiry. The
stores keep no aggregate liveness field: consumers assert freshness on each
series' own `model_timestamp_ms`, and provider-wide liveness is monitored
off-chain from the per-batch `BlockScholesBatchIngested` events.

Values are stored exactly as the verifier produced them (`u128`, provider
scale). Propbook intentionally does not enforce Predict's pricing-safe numeric
envelope on ingestion: consumers such as Predict must validate spot, forward,
basis, SVI bounds, and liveness before pricing from the values.

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
  `propbook_pyth_id`.
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
bindings are controlled by whoever holds that cap. Propbook does not implement
on-chain multisig, rotation, or timelock. Production deployments should treat the
cap as governance custody and enforce multisig/timelock operationally, or add an
on-chain governance layer before relying on registry bindings as a trust anchor.

Canonical bindings are current accepted bindings, not historical snapshots. The
initial `bind_*` calls require an unbound canonical key and abort on duplicates.
Admin replacement APIs update an already-bound canonical key without creating an
unbound intermediate state:

- `replace_pyth_binding_for_underlying` replaces the active Pyth feed for one
  Propbook underlying.

Block Scholes stores sit outside the source catalog: `create_and_share_block_scholes_stores` binds the exact provider base-asset spelling, creates the pair, and records it as canonical for one underlying in a single admin-gated step. The registry row carries that spelling alongside the two object IDs, so `propbook_block_scholes_store_pair_for_underlying` answers the whole binding — including `block_scholes_base_asset` — in one lookup, and the value and SVI stores independently retain the same spelling. The spelling is bounded to 32 bytes and is otherwise unconstrained: it is carried into every derived series id exactly as given, and no on-chain fact can say whether it names the asset the underlying is meant to track. An underlying keeps that pair for its lifetime — there is no store rebinding — so a spelling the provider does not serve leaves the underlying permanently unfeedable, and one naming a different real asset prices the underlying off that asset with every check passing. Confirm the spelling against the provider's acknowledged subscription before binding; the emitted `BlockScholesStoresRegistered` and the registry reader exist so that confirmation can be made against the chain. Predict market creation requires Pyth bound plus both stores present.

Source assignment remains sticky: once a source key has been assigned to an
underlying, that source key can only be reused for the same underlying. Replacing
BTC's Pyth feed from source A to source B does not free source A for another
underlying. There is deliberately no unbind path; if a binding is wrong or a
source dies, governance should replace it with the corrected current feed.

Operational caveat for Pyth replacement: consumers such as Predict may need exact
historical rows from `normalized_spot_at(timestamp_ms)` for unsettled markets.
Before replacing a Pyth binding for an underlying with unsettled past expiries,
backfill every required exact millisecond row into the replacement feed via
`insert_at`, then replace the binding.

Typical discovery question:

> What is the Propbook Pyth oracle object for BTC?

Use `propbook_pyth_id_for_underlying(registry, propbook_underlying_id)`. The Block Scholes lookup is `propbook_block_scholes_store_pair_for_underlying(registry, propbook_underlying_id)`. Use `block_scholes_value_store_id(&pair)` and `block_scholes_svi_store_id(&pair)` to read the two shared-object IDs from the returned pair, and `block_scholes_base_asset(&pair)` to read the provider spelling those stores derive their accepted series ids from.

## Events

Pyth-backed sources emit generic oracle events:

- `ObservationRecorded<OracleRead<Payload>>`
- `ObservationInserted<OracleRead<Payload>>`
- `OracleSourceRegistered`
- `OracleBound`
- `OracleRebound`

Block Scholes stores emit their dedicated event surface:

- `BlockScholesStoresRegistered` records the Propbook underlying, both shared-object IDs, and the immutable provider base asset.
- `BlockScholesObservationRecorded<Observation>` records every stored observation with its store ID, SID, series kind (`0` spot, `1` forward, `2` SVI), absolute expiry in milliseconds (zero for spot), and observation payload.
- `BlockScholesBatchIngested` records every verified batch with its store ID, series kind (`0` spot, `1` forward, `2` SVI), provider publication time, verified update count, and applied update count, including batches where no series advanced.

High-frequency cost caveats:

- `ObservationRecorded` emits for every accepted live update.
- `exact_reads` are unbounded tables. Storage growth is paid by writers; a
  permissionless prune flow can be added later if long-run retention needs it.
- Pyth latest updates are ceil-rounded from generation microseconds to milliseconds,
  so two aggregates generated inside the same millisecond can collide at the Propbook
  freshness key and the second live update is a no-op. Exact-history inserts are
  stricter: `pyth_feed::insert_at` accepts only envelope timestamps that are
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
