// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stores the latest Block Scholes observation for each series of one underlying, keyed by the
/// series id the provider signed. Nothing here decides where a value belongs: the id names its own
/// slot, so a valid observation for one series can only ever land in that series' slot, and reads
/// derive the id they want rather than trusting one supplied by a caller.
/// Values are held exactly as the verifier produced them; scaling and signed-value interpretation
/// belong to the reading package.
/// Spot and forward share the value store because they ride one signed batch and are separated by
/// their ids; SVI has its own store because it arrives as an independently signed batch.
module propbook::block_scholes_store;

use propbook::{block_scholes_sid, constants};
use sui::{event, table::{Self, Table}};

const EWrongVersion: u64 = 0;
const ENotNewerVersion: u64 = 1;

/// One accepted observation and the three clocks that describe it.
/// The clocks answer different questions and are not interchangeable: a series that has not moved
/// is retransmitted with its original model time, so only `published_at_ms` distinguishes a quiet
/// feed from a stopped one.
public struct BsRead<Value: copy + drop + store> has copy, drop, store {
    /// Provider time the series data is "as of", held fixed across retransmissions of a value that
    /// has not changed.
    model_timestamp_ms: u64,
    /// Envelope time of the batch this observation arrived in, advancing on every provider flush.
    /// Ordering, replay, and freshness all key on this.
    published_at_ms: u64,
    /// Sui clock time when the accepting transaction executed.
    recorded_at_ms: u64,
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

/// Latest spot and forward observations for one underlying, keyed by series id.
public struct BlockScholesValueStore has key {
    id: UID,
    /// The sole underlying this store holds series for; observations for any other are skipped.
    propbook_underlying_id: u32,
    /// Package version this store runs at; writes require an exact match and `migrate` advances it
    /// forward-only after a package upgrade.
    version: u64,
    values: Table<u256, BsRead<u128>>,
    /// Greatest envelope time accepted for this underlying, so a store whose series have all gone
    /// quiet is still visibly running.
    last_batch_ts_ms: u64,
}

/// Latest SVI observations for one underlying, keyed by series id.
public struct BlockScholesSVIStore has key {
    id: UID,
    propbook_underlying_id: u32,
    version: u64,
    svis: Table<u256, BsRead<SVIParams>>,
    last_batch_ts_ms: u64,
}

/// Emitted only for observations that were stored, so its presence means the series advanced.
public struct BlockScholesObservationRecorded<Observation: copy + drop> has copy, drop {
    propbook_oracle_id: ID,
    sid: u256,
    observation: Observation,
}

// === Read Functions ===

public fun value_store_id(store: &BlockScholesValueStore): ID {
    store.id.to_inner()
}

public fun svi_store_id(store: &BlockScholesSVIStore): ID {
    store.id.to_inner()
}

public fun value_store_underlying_id(store: &BlockScholesValueStore): u32 {
    store.propbook_underlying_id
}

public fun svi_store_underlying_id(store: &BlockScholesSVIStore): u32 {
    store.propbook_underlying_id
}

public fun value_store_version(store: &BlockScholesValueStore): u64 {
    store.version
}

public fun svi_store_version(store: &BlockScholesSVIStore): u64 {
    store.version
}

/// Returns the greatest envelope time accepted for this underlying's value series.
/// A consumer reading this alongside a series' own `published_at_ms` can tell a feed that is
/// running but unchanged from one that has stopped.
public fun value_store_last_batch_ts_ms(store: &BlockScholesValueStore): u64 {
    store.last_batch_ts_ms
}

public fun svi_store_last_batch_ts_ms(store: &BlockScholesSVIStore): u64 {
    store.last_batch_ts_ms
}

/// Returns the latest spot observation for this store's underlying, or `none` if none has landed.
public fun spot(store: &BlockScholesValueStore): Option<BsRead<u128>> {
    read(&store.values, block_scholes_sid::spot(store.propbook_underlying_id))
}

/// Returns the latest forward observation at `expiry_ms`, or `none` if none has landed.
public fun forward(store: &BlockScholesValueStore, expiry_ms: u64): Option<BsRead<u128>> {
    read(&store.values, block_scholes_sid::forward(store.propbook_underlying_id, expiry_ms))
}

/// Returns the latest SVI observation at `expiry_ms`, or `none` if none has landed.
public fun svi(store: &BlockScholesSVIStore, expiry_ms: u64): Option<BsRead<SVIParams>> {
    read(&store.svis, block_scholes_sid::svi(store.propbook_underlying_id, expiry_ms))
}

public fun read_model_timestamp_ms<Value: copy + drop + store>(read: &BsRead<Value>): u64 {
    read.model_timestamp_ms
}

public fun read_published_at_ms<Value: copy + drop + store>(read: &BsRead<Value>): u64 {
    read.published_at_ms
}

public fun read_recorded_at_ms<Value: copy + drop + store>(read: &BsRead<Value>): u64 {
    read.recorded_at_ms
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

/// Create and share the value store for `propbook_underlying_id`.
public(package) fun create_and_share_value_store(
    propbook_underlying_id: u32,
    ctx: &mut TxContext,
): ID {
    let store = BlockScholesValueStore {
        id: object::new(ctx),
        propbook_underlying_id,
        version: constants::current_version!(),
        values: table::new(ctx),
        last_batch_ts_ms: 0,
    };
    let id = store.value_store_id();
    transfer::share_object(store);
    id
}

/// Create and share the SVI store for `propbook_underlying_id`.
public(package) fun create_and_share_svi_store(
    propbook_underlying_id: u32,
    ctx: &mut TxContext,
): ID {
    let store = BlockScholesSVIStore {
        id: object::new(ctx),
        propbook_underlying_id,
        version: constants::current_version!(),
        svis: table::new(ctx),
        last_batch_ts_ms: 0,
    };
    let id = store.svi_store_id();
    transfer::share_object(store);
    id
}

/// Store one verified spot or forward observation, returning whether it was kept.
/// Returns `false` rather than aborting when the series belongs to another underlying, when the
/// clocks are unusable, or when the observation does not advance the series: one batch carries many
/// series, and a single unusable entry must not discard the rest of them.
public(package) fun apply_value(
    store: &mut BlockScholesValueStore,
    sid: u256,
    model_timestamp_ms: u64,
    published_at_ms: u64,
    recorded_at_ms: u64,
    value: u128,
): bool {
    assert!(store.version == constants::current_version!(), EWrongVersion);
    let id = store.value_store_id();
    apply(
        &mut store.values,
        id,
        store.propbook_underlying_id,
        sid,
        BsRead { model_timestamp_ms, published_at_ms, recorded_at_ms, value },
    )
}

/// Store one verified SVI observation, returning whether it was kept. Same skip rules as
/// `apply_value`.
public(package) fun apply_svi(
    store: &mut BlockScholesSVIStore,
    sid: u256,
    model_timestamp_ms: u64,
    published_at_ms: u64,
    recorded_at_ms: u64,
    value: SVIParams,
): bool {
    assert!(store.version == constants::current_version!(), EWrongVersion);
    let id = store.svi_store_id();
    apply(
        &mut store.svis,
        id,
        store.propbook_underlying_id,
        sid,
        BsRead { model_timestamp_ms, published_at_ms, recorded_at_ms, value },
    )
}

/// Record that a batch carrying this underlying's series was accepted at `published_at_ms`.
/// Separate from applying observations because a batch in which every series was unchanged still
/// proves the feed is running.
public(package) fun record_value_batch(store: &mut BlockScholesValueStore, published_at_ms: u64) {
    if (published_at_ms > store.last_batch_ts_ms) {
        store.last_batch_ts_ms = published_at_ms;
    };
}

public(package) fun record_svi_batch(store: &mut BlockScholesSVIStore, published_at_ms: u64) {
    if (published_at_ms > store.last_batch_ts_ms) {
        store.last_batch_ts_ms = published_at_ms;
    };
}

/// Assemble source-native SVI parameters from a verified update's fields.
public(package) fun new_svi_params(
    a_magnitude: u128,
    a_is_negative: bool,
    b: u128,
    sigma: u128,
    rho_magnitude: u128,
    rho_is_negative: bool,
    m_magnitude: u128,
    m_is_negative: bool,
): SVIParams {
    SVIParams {
        a_magnitude,
        a_is_negative,
        b,
        sigma,
        rho_magnitude,
        rho_is_negative,
        m_magnitude,
        m_is_negative,
    }
}

// === Private Functions ===

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

/// Keeps `read` as the series' latest observation when it belongs here and advances the series.
/// The series id is the slot key, so this decides only whether to keep an observation, never where
/// it goes.
fun apply<Value: copy + drop + store>(
    reads: &mut Table<u256, BsRead<Value>>,
    propbook_oracle_id: ID,
    propbook_underlying_id: u32,
    sid: u256,
    read: BsRead<Value>,
): bool {
    if (block_scholes_sid::underlying(sid) != propbook_underlying_id) return false;
    if (read.published_at_ms == 0 || read.published_at_ms > read.recorded_at_ms) return false;

    if (reads.contains(sid)) {
        let latest = reads.borrow_mut(sid);
        if (read.published_at_ms <= latest.published_at_ms) return false;
        *latest = read;
    } else {
        reads.add(sid, read);
    };

    event::emit(BlockScholesObservationRecorded<BsRead<Value>> {
        propbook_oracle_id,
        sid,
        observation: read,
    });
    true
}
