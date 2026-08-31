// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stores verifier-authenticated Block Scholes observations for one immutable base asset, including
/// the latest values and canonical spot observations at exact minute boundaries. Propbook derives
/// every accepted series id from that identity through the upstream SID package, so a valid
/// observation for another asset cannot enter this store.
/// Stored values are held exactly as the verifier produced them; scaling and signed-value
/// interpretation belong to the reading package. Exact spot history additionally admits only
/// positive `u64`-representable values whose model time is within
/// `constants::max_block_scholes_settlement_carry_ms` of the envelope, so an unusable or
/// long-carried observation cannot claim a permanent key.
/// Value and SVI observations use separate stores because the verifier exposes distinct batch and
/// value types. The registry creates and binds both stores atomically from one base-asset input.
module propbook::block_scholes_store;

use bs_oracle::verify::{ValueBatch, SviBatch};
use propbook::{block_scholes_sid, constants};
use std::string::String;
use sui::{clock::Clock, event, table::{Self, Table}};

const EWrongVersion: u64 = 0;
const ENotNewerVersion: u64 = 1;
const EUnexpectedBatchLength: u64 = 2;
const ESeriesIdMismatch: u64 = 3;

macro fun series_kind_spot(): u8 { 0 }

macro fun series_kind_forward(): u8 { 1 }

macro fun series_kind_svi(): u8 { 2 }

macro fun exact_spot_period_ms(): u64 { 60_000 }

macro fun spot_batch_length(): u64 { 1 }

/// One accepted observation and the three clocks that describe it.
/// The clocks answer different questions and are not interchangeable: a calibration that has not
/// changed republishes under its original model time, so only `source_timestamp_ms` distinguishes a
/// quiet feed from a stopped one.
public struct BsRead<Value: copy + drop + store> has copy, drop, store {
    /// Provider calibration time — when the series was last re-derived, held fixed across
    /// republishes of that calibration. The provider's per-series replay key: ordering keys on
    /// this first. The published VALUES are as-of the envelope time: per the provider contract,
    /// an SVI publish whose model time is unchanged carries the same calibration already rolled
    /// down to its new publish time, never duplicate data.
    model_timestamp_ms: u64,
    /// Envelope time of the batch this observation arrived in, advancing on every provider flush
    /// and never regressing once stored (see `apply`). The economic clock: consumers gate
    /// freshness on it and the SVI roll-down anchors on it, so a republished unchanged value is
    /// re-asserted as current at its new envelope time.
    source_timestamp_ms: u64,
    /// Sui clock time when the accepting transaction executed.
    onchain_timestamp_ms: u64,
    /// Digest of the transaction that accepted this observation.
    writer_digest: vector<u8>,
    value: Value,
}

/// Source-native Block Scholes SVI parameters.
/// `a`, `rho`, and `m` are signed and carried as magnitude plus sign, matching the provider's own
/// encoding: the values are 128-bit and `fixed_math` has no 128-bit signed type, so converting here
/// would mean choosing a representation on behalf of the reader.
public struct SVIParams has copy, drop, store {
    a_magnitude: u128,
    a_is_negative: bool,
    b: u128,
    sigma: u128,
    rho_magnitude: u128,
    rho_is_negative: bool,
    m_magnitude: u128,
    m_is_negative: bool,
}

/// Latest spot and forward observations plus exact minute-boundary spot history for one Block
/// Scholes base asset.
public struct BlockScholesValueStore has key {
    id: UID,
    propbook_underlying_id: u32,
    block_scholes_base_asset: String,
    /// Package version this store runs at; writes require an exact match and `migrate` advances it
    /// forward-only after a package upgrade.
    version: u64,
    values: Table<u256, BsRead<u128>>,
    /// First positive `u64`-representable canonical spot at each exact minute boundary.
    exact_spot_reads: Table<u64, BsRead<u128>>,
}

/// Latest SVI observations for one Block Scholes base asset.
public struct BlockScholesSVIStore has key {
    id: UID,
    propbook_underlying_id: u32,
    block_scholes_base_asset: String,
    version: u64,
    svis: Table<u256, BsRead<SVIParams>>,
}

/// Emitted only for observations that were stored, so its presence means the series advanced.
public struct BlockScholesObservationRecorded<Observation: copy + drop> has copy, drop {
    propbook_underlying_id: u32,
    propbook_oracle_id: ID,
    sid: u256,
    /// `0` = spot, `1` = forward, and `2` = SVI.
    series_kind: u8,
    /// Absolute unix-millisecond expiry; zero for the non-expiring spot series.
    expiry_ms: u64,
    observation: Observation,
}

/// Emitted when the canonical spot is inserted into exact minute-boundary history.
public struct BlockScholesObservationInserted<Observation: copy + drop> has copy, drop {
    propbook_oracle_id: ID,
    observation: Observation,
}

/// Emitted once per latest-path batch, whether or not anything was stored.
/// The envelope time advances on every provider flush, so this is what shows the feed is running
/// during a stretch where no series moved and no observation event is emitted.
public struct BlockScholesBatchIngested has copy, drop {
    propbook_underlying_id: u32,
    propbook_oracle_id: ID,
    /// `0` = spot, `1` = forward, and `2` = SVI.
    series_kind: u8,
    source_timestamp_ms: u64,
    /// Sui clock time when the batch ingestion transaction executed.
    onchain_timestamp_ms: u64,
    /// Verified observations carried by the batch.
    update_count: u64,
    /// Observations that became their series' latest.
    applied: u64,
}

// === Read Functions ===

public fun value_store_id(store: &BlockScholesValueStore): ID {
    store.id.to_inner()
}

public fun svi_store_id(store: &BlockScholesSVIStore): ID {
    store.id.to_inner()
}

/// Returns the immutable provider base-asset spelling for external composition or devInspect.
public fun value_store_base_asset(store: &BlockScholesValueStore): String {
    store.block_scholes_base_asset
}

/// Returns the immutable provider base-asset spelling for external composition or devInspect.
public fun svi_store_base_asset(store: &BlockScholesSVIStore): String {
    store.block_scholes_base_asset
}

public fun value_store_version(store: &BlockScholesValueStore): u64 {
    store.version
}

public fun svi_store_version(store: &BlockScholesSVIStore): u64 {
    store.version
}

/// Returns the canonical spot series id for external subscription construction.
public fun spot_sid(store: &BlockScholesValueStore): u256 {
    block_scholes_sid::spot(&store.block_scholes_base_asset)
}

/// Returns one canonical forward series id for external subscription construction.
public fun forward_sid(store: &BlockScholesValueStore, expiry_ms: u64): u256 {
    block_scholes_sid::forward(&store.block_scholes_base_asset, expiry_ms)
}

/// Returns one canonical SVI series id for external subscription construction.
public fun svi_sid(store: &BlockScholesSVIStore, expiry_ms: u64): u256 {
    block_scholes_sid::svi(&store.block_scholes_base_asset, expiry_ms)
}

/// Returns the latest canonical spot observation, or `none` if none has landed.
public fun spot(store: &BlockScholesValueStore): Option<BsRead<u128>> {
    read(&store.values, store.spot_sid())
}

/// Returns the canonical spot observation published at exactly `source_timestamp_ms`.
public fun spot_at(store: &BlockScholesValueStore, source_timestamp_ms: u64): Option<BsRead<u128>> {
    read_at(&store.exact_spot_reads, source_timestamp_ms)
}

/// Returns the latest canonical forward observation at `expiry_ms`.
public fun forward(store: &BlockScholesValueStore, expiry_ms: u64): Option<BsRead<u128>> {
    read(&store.values, store.forward_sid(expiry_ms))
}

/// Returns the latest canonical SVI observation at `expiry_ms`.
public fun svi(store: &BlockScholesSVIStore, expiry_ms: u64): Option<BsRead<SVIParams>> {
    read(&store.svis, store.svi_sid(expiry_ms))
}

public fun read_model_timestamp_ms<Value: copy + drop + store>(read: &BsRead<Value>): u64 {
    read.model_timestamp_ms
}

public fun read_source_timestamp_ms<Value: copy + drop + store>(read: &BsRead<Value>): u64 {
    read.source_timestamp_ms
}

public fun read_onchain_timestamp_ms<Value: copy + drop + store>(read: &BsRead<Value>): u64 {
    read.onchain_timestamp_ms
}

public fun read_writer_digest<Value: copy + drop + store>(read: &BsRead<Value>): vector<u8> {
    read.writer_digest
}

public fun read_value<Value: copy + drop + store>(read: &BsRead<Value>): Value {
    read.value
}

public fun svi_a_magnitude(params: &SVIParams): u128 {
    params.a_magnitude
}

public fun svi_a_is_negative(params: &SVIParams): bool {
    params.a_is_negative
}

public fun svi_b(params: &SVIParams): u128 {
    params.b
}

public fun svi_sigma(params: &SVIParams): u128 {
    params.sigma
}

public fun svi_rho_magnitude(params: &SVIParams): u128 {
    params.rho_magnitude
}

public fun svi_rho_is_negative(params: &SVIParams): bool {
    params.rho_is_negative
}

public fun svi_m_magnitude(params: &SVIParams): u128 {
    params.m_magnitude
}

public fun svi_m_is_negative(params: &SVIParams): bool {
    params.m_is_negative
}

// === Write Functions ===

/// Ingest the canonical spot batch for this store's base asset.
public fun apply_spot_batch(
    store: &mut BlockScholesValueStore,
    batch: ValueBatch,
    clock: &Clock,
    ctx: &TxContext,
) {
    let expected_sid = store.spot_sid();
    let read = store.checked_spot_read(
        batch,
        expected_sid,
        clock,
        ctx,
    );
    let stored = store.apply_value(expected_sid, series_kind_spot!(), 0, read);
    let _ = store.insert_exact_spot(read);
    event::emit(BlockScholesBatchIngested {
        propbook_underlying_id: store.propbook_underlying_id,
        propbook_oracle_id: store.value_store_id(),
        series_kind: series_kind_spot!(),
        source_timestamp_ms: read.source_timestamp_ms,
        onchain_timestamp_ms: read.onchain_timestamp_ms,
        update_count: spot_batch_length!(),
        applied: if (stored) spot_batch_length!() else 0,
    });
}

/// Insert the canonical spot batch into exact minute-boundary history without changing `latest`.
/// A valid batch whose signed `source_timestamp_ms` is not a minute boundary, whose model time is
/// more than `constants::max_block_scholes_settlement_carry_ms` before that envelope, or whose
/// spot is zero or wider than `u64`, is ignored without aborting. The first admissible
/// observation at a boundary owns the key and cannot be replaced.
public fun insert_at(
    store: &mut BlockScholesValueStore,
    batch: ValueBatch,
    clock: &Clock,
    ctx: &TxContext,
) {
    let expected_sid = store.spot_sid();
    let read = store.checked_spot_read(
        batch,
        expected_sid,
        clock,
        ctx,
    );
    let _ = store.insert_exact_spot(read);
}

/// Ingest canonical forwards for this store's base asset.
/// `expiries_ms[i]` is an untrusted descriptor witness for signed update `i`; equality with the
/// upstream-derived SID proves the association before any observation is stored.
public fun apply_forward_batch(
    store: &mut BlockScholesValueStore,
    batch: ValueBatch,
    expiries_ms: vector<u64>,
    clock: &Clock,
    ctx: &TxContext,
) {
    let mut expected_sids = vector[];
    let mut i = 0;
    while (i < expiries_ms.length()) {
        expected_sids.push_back(store.forward_sid(expiries_ms[i]));
        i = i + 1;
    };
    store.apply_checked_value_batch(
        batch,
        expected_sids,
        expiries_ms,
        series_kind_forward!(),
        clock,
        ctx,
    )
}

/// Ingest canonical SVI observations for this store's base asset.
public fun apply_svi_batch(
    store: &mut BlockScholesSVIStore,
    batch: SviBatch,
    expiries_ms: vector<u64>,
    clock: &Clock,
    ctx: &TxContext,
) {
    let mut expected_sids = vector[];
    let mut i = 0;
    while (i < expiries_ms.length()) {
        expected_sids.push_back(store.svi_sid(expiries_ms[i]));
        i = i + 1;
    };
    store.apply_checked_svi_batch(batch, expected_sids, expiries_ms, clock, ctx)
}

/// Migrate this store to the running package version. Forward-only:
/// `current_version!()` is compiled into each package version's bytecode.
public fun migrate_value_store(store: &mut BlockScholesValueStore) {
    assert!(constants::current_version!() > store.version, ENotNewerVersion);
    store.version = constants::current_version!();
}

public fun migrate_svi_store(store: &mut BlockScholesSVIStore) {
    assert!(constants::current_version!() > store.version, ENotNewerVersion);
    store.version = constants::current_version!();
}

// === Public-Package Functions ===

/// Create and share a value store for one immutable Block Scholes base asset.
public(package) fun create_and_share_value_store(
    propbook_underlying_id: u32,
    block_scholes_base_asset: String,
    ctx: &mut TxContext,
): ID {
    let store = BlockScholesValueStore {
        id: object::new(ctx),
        propbook_underlying_id,
        block_scholes_base_asset,
        version: constants::current_version!(),
        values: table::new(ctx),
        exact_spot_reads: table::new(ctx),
    };
    let id = store.value_store_id();
    transfer::share_object(store);
    id
}

/// Create and share an SVI store for one immutable Block Scholes base asset.
public(package) fun create_and_share_svi_store(
    propbook_underlying_id: u32,
    block_scholes_base_asset: String,
    ctx: &mut TxContext,
): ID {
    let store = BlockScholesSVIStore {
        id: object::new(ctx),
        propbook_underlying_id,
        block_scholes_base_asset,
        version: constants::current_version!(),
        svis: table::new(ctx),
    };
    let id = store.svi_store_id();
    transfer::share_object(store);
    id
}

// === Private Functions ===

fun checked_spot_read(
    store: &BlockScholesValueStore,
    batch: ValueBatch,
    expected_sid: u256,
    clock: &Clock,
    ctx: &TxContext,
): BsRead<u128> {
    assert!(store.version == constants::current_version!(), EWrongVersion);
    let source_timestamp_ms = batch.value_batch_timestamp();
    let updates = batch.into_value_updates();
    assert!(updates.length() == spot_batch_length!(), EUnexpectedBatchLength);
    let update = &updates[0];
    assert!(update.value_sid() == expected_sid, ESeriesIdMismatch);
    BsRead {
        model_timestamp_ms: update.value_timestamp(),
        source_timestamp_ms,
        onchain_timestamp_ms: clock.timestamp_ms(),
        writer_digest: *ctx.digest(),
        value: update.value_v(),
    }
}

fun apply_checked_value_batch(
    store: &mut BlockScholesValueStore,
    batch: ValueBatch,
    expected_sids: vector<u256>,
    expiries_ms: vector<u64>,
    series_kind: u8,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(store.version == constants::current_version!(), EWrongVersion);
    let source_timestamp_ms = batch.value_batch_timestamp();
    let updates = batch.into_value_updates();
    let update_count = updates.length();
    assert!(update_count == expected_sids.length(), EUnexpectedBatchLength);
    assert!(update_count == expiries_ms.length(), EUnexpectedBatchLength);

    let mut i = 0;
    while (i < update_count) {
        assert!(updates[i].value_sid() == expected_sids[i], ESeriesIdMismatch);
        i = i + 1;
    };

    let onchain_timestamp_ms = clock.timestamp_ms();
    let writer_digest = *ctx.digest();
    let mut applied = 0;
    i = 0;
    while (i < update_count) {
        let update = &updates[i];
        let stored = store.apply_value(
            update.value_sid(),
            series_kind,
            expiries_ms[i],
            BsRead {
                model_timestamp_ms: update.value_timestamp(),
                source_timestamp_ms,
                onchain_timestamp_ms,
                writer_digest: copy writer_digest,
                value: update.value_v(),
            },
        );
        if (stored) applied = applied + 1;
        i = i + 1;
    };

    event::emit(BlockScholesBatchIngested {
        propbook_underlying_id: store.propbook_underlying_id,
        propbook_oracle_id: store.value_store_id(),
        series_kind,
        source_timestamp_ms,
        onchain_timestamp_ms,
        update_count,
        applied,
    });
}

fun apply_checked_svi_batch(
    store: &mut BlockScholesSVIStore,
    batch: SviBatch,
    expected_sids: vector<u256>,
    expiries_ms: vector<u64>,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(store.version == constants::current_version!(), EWrongVersion);
    let source_timestamp_ms = batch.svi_batch_timestamp();
    let updates = batch.into_svi_updates();
    let update_count = updates.length();
    assert!(update_count == expected_sids.length(), EUnexpectedBatchLength);
    assert!(update_count == expiries_ms.length(), EUnexpectedBatchLength);

    let mut i = 0;
    while (i < update_count) {
        assert!(updates[i].svi_sid() == expected_sids[i], ESeriesIdMismatch);
        i = i + 1;
    };

    let onchain_timestamp_ms = clock.timestamp_ms();
    let writer_digest = *ctx.digest();
    let mut applied = 0;
    i = 0;
    while (i < update_count) {
        let update = &updates[i];
        let (
            a_magnitude,
            a_is_negative,
            b,
            sigma,
            rho_magnitude,
            rho_is_negative,
            m_magnitude,
            m_is_negative,
        ) = update.svi_fields();
        let stored = store.apply_svi(
            update.svi_sid(),
            expiries_ms[i],
            update.svi_timestamp(),
            source_timestamp_ms,
            onchain_timestamp_ms,
            copy writer_digest,
            SVIParams {
                a_magnitude,
                a_is_negative,
                b,
                sigma,
                rho_magnitude,
                rho_is_negative,
                m_magnitude,
                m_is_negative,
            },
        );
        if (stored) applied = applied + 1;
        i = i + 1;
    };

    event::emit(BlockScholesBatchIngested {
        propbook_underlying_id: store.propbook_underlying_id,
        propbook_oracle_id: store.svi_store_id(),
        series_kind: series_kind_svi!(),
        source_timestamp_ms,
        onchain_timestamp_ms,
        update_count,
        applied,
    });
}

/// Store one verified value observation, returning whether it was kept.
/// Returns `false` rather than aborting when the clocks are unusable or the observation does not
/// advance the series, so one unusable entry cannot discard the rest of its verified batch.
fun apply_value(
    store: &mut BlockScholesValueStore,
    sid: u256,
    series_kind: u8,
    expiry_ms: u64,
    read: BsRead<u128>,
): bool {
    // `apply_checked_value_batch` validates the store version before entering the batch loop.
    let id = store.value_store_id();
    let propbook_underlying_id = store.propbook_underlying_id;
    apply(
        &mut store.values,
        propbook_underlying_id,
        id,
        sid,
        series_kind,
        expiry_ms,
        read,
    )
}

/// Insert one verified canonical spot at its exact signed minute-boundary timestamp.
/// A model older than the compiled carry window is ignored so a long-held estimate cannot
/// claim a settlement key. Latest ingestion does not use this bound.
fun insert_exact_spot(store: &mut BlockScholesValueStore, read: BsRead<u128>): bool {
    if (read.source_timestamp_ms % exact_spot_period_ms!() != 0) return false;
    if (!read.has_valid_clocks()) return false;
    if (
        read.source_timestamp_ms - read.model_timestamp_ms
            > constants::max_block_scholes_settlement_carry_ms!()
    ) return false;
    if (read.value == 0 || read.value > (std::u64::max_value!() as u128)) return false;
    if (store.exact_spot_reads.contains(read.source_timestamp_ms)) return false;

    store.exact_spot_reads.add(read.source_timestamp_ms, read);
    event::emit(BlockScholesObservationInserted<BsRead<u128>> {
        propbook_oracle_id: store.value_store_id(),
        observation: read,
    });
    true
}

/// Store one verified SVI observation, returning whether it was kept. Same skip rules as
/// `apply_value`.
fun apply_svi(
    store: &mut BlockScholesSVIStore,
    sid: u256,
    expiry_ms: u64,
    model_timestamp_ms: u64,
    source_timestamp_ms: u64,
    onchain_timestamp_ms: u64,
    writer_digest: vector<u8>,
    value: SVIParams,
): bool {
    // `apply_checked_svi_batch` validates the store version before entering the batch loop.
    let id = store.svi_store_id();
    let propbook_underlying_id = store.propbook_underlying_id;
    apply(
        &mut store.svis,
        propbook_underlying_id,
        id,
        sid,
        series_kind_svi!(),
        expiry_ms,
        BsRead {
            model_timestamp_ms,
            source_timestamp_ms,
            onchain_timestamp_ms,
            writer_digest,
            value,
        },
    )
}

fun read<Value: copy + drop + store>(
    reads: &Table<u256, BsRead<Value>>,
    sid: u256,
): Option<BsRead<Value>> {
    if (!reads.contains(sid)) {
        option::none()
    } else {
        option::some(*reads.borrow(sid))
    }
}

fun read_at<Value: copy + drop + store>(
    reads: &Table<u64, BsRead<Value>>,
    source_timestamp_ms: u64,
): Option<BsRead<Value>> {
    if (!reads.contains(source_timestamp_ms)) {
        option::none()
    } else {
        option::some(*reads.borrow(source_timestamp_ms))
    }
}

/// Same off-chain-consumer reasoning as `batch_ingested_fields`: this reader exists only so tests
/// can assert the emitted observation is the one that was stored.
#[test_only]
public fun observation_recorded_fields<Observation: copy + drop>(
    event: &BlockScholesObservationRecorded<Observation>,
): (u32, ID, u256, u8, u64, Observation) {
    (
        event.propbook_underlying_id,
        event.propbook_oracle_id,
        event.sid,
        event.series_kind,
        event.expiry_ms,
        event.observation,
    )
}

#[test_only]
public fun observation_inserted_fields<Observation: copy + drop>(
    event: &BlockScholesObservationInserted<Observation>,
): (ID, Observation) {
    (event.propbook_oracle_id, event.observation)
}

/// The batch event's fields exist for off-chain consumers, which decode them rather than calling
/// Move, so this reader exists only so tests can assert the decoded fields are right.
#[test_only]
public fun batch_ingested_fields(
    event: &BlockScholesBatchIngested,
): (u32, ID, u8, u64, u64, u64, u64) {
    (
        event.propbook_underlying_id,
        event.propbook_oracle_id,
        event.series_kind,
        event.source_timestamp_ms,
        event.onchain_timestamp_ms,
        event.update_count,
        event.applied,
    )
}

/// Build an older-version fixture without exposing a production mutation surface.
#[test_only]
public fun set_store_versions_for_testing(
    value_store: &mut BlockScholesValueStore,
    svi_store: &mut BlockScholesSVIStore,
    version: u64,
) {
    value_store.version = version;
    svi_store.version = version;
}

/// Ordering is lexicographic on (model time, envelope time), and the stored envelope time never
/// regresses. The provider names the per-series model time as the replay key and the envelope as
/// transport, so newer model data wins and an equal model time advances only with a fresher
/// envelope (a retransmission updates transport metadata). The envelope floor exists because
/// consumers price from the stored `source_timestamp_ms` — it gates freshness and anchors the SVI
/// roll-down — so a read that would move it backwards (a delayed batch whose newer model time
/// arrived in an older envelope: the provider's own publish stream regressed) is skipped rather
/// than allowed to stretch the anchor. A model time after its own envelope is provider garbage —
/// data cannot be "as of" later than its publish — and admitting it would let the roll-down
/// anchor land on or past expiry, so it is skipped like any other unusable entry.
fun apply<Value: copy + drop + store>(
    reads: &mut Table<u256, BsRead<Value>>,
    propbook_underlying_id: u32,
    propbook_oracle_id: ID,
    sid: u256,
    series_kind: u8,
    expiry_ms: u64,
    read: BsRead<Value>,
): bool {
    if (!read.has_valid_clocks()) return false;

    if (reads.contains(sid)) {
        let latest = reads.borrow_mut(sid);
        let advances =
            (read.source_timestamp_ms >= latest.source_timestamp_ms &&
                read.model_timestamp_ms > latest.model_timestamp_ms) ||
            (read.model_timestamp_ms == latest.model_timestamp_ms &&
                read.source_timestamp_ms > latest.source_timestamp_ms);
        if (!advances) return false;
        *latest = read;
    } else {
        reads.add(sid, read);
    };

    event::emit(BlockScholesObservationRecorded<BsRead<Value>> {
        propbook_underlying_id,
        propbook_oracle_id,
        sid,
        series_kind,
        expiry_ms,
        observation: read,
    });
    true
}

fun has_valid_clocks<Value: copy + drop + store>(read: &BsRead<Value>): bool {
    read.source_timestamp_ms > 0 &&
        read.source_timestamp_ms <= read.onchain_timestamp_ms &&
        read.model_timestamp_ms <= read.source_timestamp_ms
}
