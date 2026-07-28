// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Covers what a store accepts and what it refuses. The refusals matter most: a relayer chooses
/// which signed batches to submit and when, so replaying an old batch, resubmitting one unchanged,
/// or aiming another underlying's batch at this store must all leave the stored series alone
/// without discarding the rest of the batch.
#[test_only]
module propbook::block_scholes_store_tests;

use propbook::{
    block_scholes_sid,
    block_scholes_store::{
        Self as store,
        BlockScholesValueStore,
        BlockScholesSVIStore,
        SVIParams,
        BsRead,
    },
    constants
};
use std::unit_test::assert_eq;
use sui::test_scenario::{Self as test, Scenario, return_shared};

const ADMIN: address = @0xAD;
const UNDERLYING_ID: u32 = 42;
const OTHER_UNDERLYING_ID: u32 = 43;

const EXPIRY_A: u64 = 1_700_100_000_000;
const EXPIRY_B: u64 = 1_700_200_000_000;

const SPOT: u128 = 50_000_000_000_000;
const SPOT_LATER: u128 = 49_000_000_000_000;
const FORWARD_A: u128 = 50_500_000_000_000;
const FORWARD_B: u128 = 51_500_000_000_000;

// Provider clocks. `MODEL_*` is when a series' data is "as of"; `PUBLISHED_*` is the envelope time
// of the batch carrying it, which advances on every flush whether or not the series moved.
const MODEL_EARLY: u64 = 100;
const MODEL_LATE: u64 = 300;
const PUBLISHED_EARLY: u64 = 100;
const PUBLISHED_MID: u64 = 200;
const PUBLISHED_LATE: u64 = 300;
const RECORDED: u64 = 1_000;

const SVI_A_MAG: u128 = 40_000_000;
const SVI_A_NEG: bool = true;
const SVI_B: u128 = 120_000_000;
const SVI_SIGMA: u128 = 90_000_000;
const SVI_RHO_MAG: u128 = 300_000_000;
const SVI_RHO_NEG: bool = true;
const SVI_M_MAG: u128 = 25_000_000;
const SVI_M_NEG: bool = false;

// === Value store: accepting ===

#[test]
fun applying_a_spot_observation_stores_it_with_all_three_clocks() {
    let (mut scenario, value_id, _svi_id) = setup_stores(UNDERLYING_ID);
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);

    let applied = apply_spot(&mut value_store, MODEL_EARLY, PUBLISHED_EARLY, SPOT);
    assert_eq!(applied, true);

    let read = store::spot(&value_store).destroy_some();
    assert_eq!(read.read_value(), SPOT);
    assert_eq!(read.read_model_timestamp_ms(), MODEL_EARLY);
    assert_eq!(read.read_published_at_ms(), PUBLISHED_EARLY);
    assert_eq!(read.read_recorded_at_ms(), RECORDED);

    return_shared(value_store);
    scenario.end();
}

#[test]
fun a_newer_batch_replaces_the_stored_observation() {
    let (mut scenario, value_id, _svi_id) = setup_stores(UNDERLYING_ID);
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);

    apply_spot(&mut value_store, MODEL_EARLY, PUBLISHED_EARLY, SPOT);
    let applied = apply_spot(&mut value_store, MODEL_LATE, PUBLISHED_LATE, SPOT_LATER);
    assert_eq!(applied, true);

    let read = store::spot(&value_store).destroy_some();
    assert_eq!(read.read_value(), SPOT_LATER);
    assert_eq!(read.read_published_at_ms(), PUBLISHED_LATE);

    return_shared(value_store);
    scenario.end();
}

/// A series that has not moved is retransmitted with its original model time while the envelope
/// advances, so the stored model time must stay put even as the series is refreshed.
#[test]
fun a_retransmission_advances_the_envelope_but_not_the_model_time() {
    let (mut scenario, value_id, _svi_id) = setup_stores(UNDERLYING_ID);
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);

    apply_spot(&mut value_store, MODEL_EARLY, PUBLISHED_EARLY, SPOT);
    let applied = apply_spot(&mut value_store, MODEL_EARLY, PUBLISHED_LATE, SPOT);
    assert_eq!(applied, true);

    let read = store::spot(&value_store).destroy_some();
    assert_eq!(read.read_model_timestamp_ms(), MODEL_EARLY);
    assert_eq!(read.read_published_at_ms(), PUBLISHED_LATE);
    assert_eq!(read.read_value(), SPOT);

    return_shared(value_store);
    scenario.end();
}

#[test]
fun spot_and_forward_occupy_distinct_slots() {
    let (mut scenario, value_id, _svi_id) = setup_stores(UNDERLYING_ID);
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);

    apply_spot(&mut value_store, MODEL_EARLY, PUBLISHED_EARLY, SPOT);
    apply_forward(&mut value_store, EXPIRY_A, MODEL_EARLY, PUBLISHED_EARLY, FORWARD_A);

    assert_eq!(store::spot(&value_store).destroy_some().read_value(), SPOT);
    assert_eq!(store::forward(&value_store, EXPIRY_A).destroy_some().read_value(), FORWARD_A);

    return_shared(value_store);
    scenario.end();
}

#[test]
fun forward_expiries_are_independent() {
    let (mut scenario, value_id, _svi_id) = setup_stores(UNDERLYING_ID);
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);

    apply_forward(&mut value_store, EXPIRY_A, MODEL_EARLY, PUBLISHED_EARLY, FORWARD_A);
    apply_forward(&mut value_store, EXPIRY_B, MODEL_EARLY, PUBLISHED_EARLY, FORWARD_B);

    assert_eq!(store::forward(&value_store, EXPIRY_A).destroy_some().read_value(), FORWARD_A);
    assert_eq!(store::forward(&value_store, EXPIRY_B).destroy_some().read_value(), FORWARD_B);

    return_shared(value_store);
    scenario.end();
}

#[test]
fun reads_are_none_before_anything_lands() {
    let (mut scenario, value_id, svi_id) = setup_stores(UNDERLYING_ID);
    let value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let svi_store = scenario.take_shared_by_id<BlockScholesSVIStore>(svi_id);

    assert!(store::spot(&value_store).is_none());
    assert!(store::forward(&value_store, EXPIRY_A).is_none());
    assert!(store::svi(&svi_store, EXPIRY_A).is_none());

    return_shared(value_store);
    return_shared(svi_store);
    scenario.end();
}

// === Value store: refusing ===

/// Replaying an older batch must not roll the series back.
#[test]
fun an_older_batch_is_skipped_and_leaves_the_stored_observation_intact() {
    let (mut scenario, value_id, _svi_id) = setup_stores(UNDERLYING_ID);
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);

    apply_spot(&mut value_store, MODEL_LATE, PUBLISHED_LATE, SPOT_LATER);
    let applied = apply_spot(&mut value_store, MODEL_EARLY, PUBLISHED_EARLY, SPOT);
    assert_eq!(applied, false);

    let read = store::spot(&value_store).destroy_some();
    assert_eq!(read.read_value(), SPOT_LATER);
    assert_eq!(read.read_published_at_ms(), PUBLISHED_LATE);

    return_shared(value_store);
    scenario.end();
}

/// Resubmitting a batch already applied is a no-op, not an abort: two relayers racing the same
/// batch must not make one of them fail.
#[test]
fun resubmitting_the_same_batch_is_skipped_without_aborting() {
    let (mut scenario, value_id, _svi_id) = setup_stores(UNDERLYING_ID);
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);

    apply_spot(&mut value_store, MODEL_EARLY, PUBLISHED_MID, SPOT);
    let applied = apply_spot(&mut value_store, MODEL_EARLY, PUBLISHED_MID, SPOT);
    assert_eq!(applied, false);

    assert_eq!(store::spot(&value_store).destroy_some().read_published_at_ms(), PUBLISHED_MID);

    return_shared(value_store);
    scenario.end();
}

/// A store holds one underlying's series; a valid observation for another underlying belongs
/// nowhere here and must not create a slot.
#[test]
fun an_observation_for_another_underlying_is_skipped() {
    let (mut scenario, value_id, _svi_id) = setup_stores(UNDERLYING_ID);
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);

    let foreign_sid = block_scholes_sid::spot(OTHER_UNDERLYING_ID);
    let applied = store::apply_value(
        &mut value_store,
        foreign_sid,
        MODEL_EARLY,
        PUBLISHED_EARLY,
        RECORDED,
        SPOT,
    );
    assert_eq!(applied, false);
    assert!(store::spot(&value_store).is_none());

    return_shared(value_store);
    scenario.end();
}

#[test]
fun a_zero_envelope_time_is_skipped() {
    let (mut scenario, value_id, _svi_id) = setup_stores(UNDERLYING_ID);
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);

    let applied = apply_spot(&mut value_store, MODEL_EARLY, 0, SPOT);
    assert_eq!(applied, false);
    assert!(store::spot(&value_store).is_none());

    return_shared(value_store);
    scenario.end();
}

/// An envelope stamped after the chain's own clock cannot be a real observation.
#[test]
fun an_envelope_time_after_chain_time_is_skipped() {
    let (mut scenario, value_id, _svi_id) = setup_stores(UNDERLYING_ID);
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);

    let applied = store::apply_value(
        &mut value_store,
        block_scholes_sid::spot(UNDERLYING_ID),
        MODEL_EARLY,
        RECORDED + 1,
        RECORDED,
        SPOT,
    );
    assert_eq!(applied, false);
    assert!(store::spot(&value_store).is_none());

    return_shared(value_store);
    scenario.end();
}

// === SVI store ===

#[test]
fun applying_an_svi_observation_stores_every_parameter_source_native() {
    let (mut scenario, _value_id, svi_id) = setup_stores(UNDERLYING_ID);
    let mut svi_store = scenario.take_shared_by_id<BlockScholesSVIStore>(svi_id);

    let applied = apply_svi(&mut svi_store, EXPIRY_A, MODEL_EARLY, PUBLISHED_EARLY);
    assert_eq!(applied, true);

    let read = store::svi(&svi_store, EXPIRY_A).destroy_some();
    let params: SVIParams = read.read_value();
    assert_eq!(params.svi_a_magnitude(), SVI_A_MAG);
    assert_eq!(params.svi_a_is_negative(), SVI_A_NEG);
    assert_eq!(params.svi_b(), SVI_B);
    assert_eq!(params.svi_sigma(), SVI_SIGMA);
    assert_eq!(params.svi_rho_magnitude(), SVI_RHO_MAG);
    assert_eq!(params.svi_rho_is_negative(), SVI_RHO_NEG);
    assert_eq!(params.svi_m_magnitude(), SVI_M_MAG);
    assert_eq!(params.svi_m_is_negative(), SVI_M_NEG);
    assert_eq!(read.read_model_timestamp_ms(), MODEL_EARLY);

    return_shared(svi_store);
    scenario.end();
}

#[test]
fun svi_expiries_are_independent() {
    let (mut scenario, _value_id, svi_id) = setup_stores(UNDERLYING_ID);
    let mut svi_store = scenario.take_shared_by_id<BlockScholesSVIStore>(svi_id);

    apply_svi(&mut svi_store, EXPIRY_A, MODEL_EARLY, PUBLISHED_EARLY);

    assert!(store::svi(&svi_store, EXPIRY_A).is_some());
    assert!(store::svi(&svi_store, EXPIRY_B).is_none());

    return_shared(svi_store);
    scenario.end();
}

#[test]
fun an_svi_observation_for_another_underlying_is_skipped() {
    let (mut scenario, _value_id, svi_id) = setup_stores(UNDERLYING_ID);
    let mut svi_store = scenario.take_shared_by_id<BlockScholesSVIStore>(svi_id);

    let foreign_sid = block_scholes_sid::svi(OTHER_UNDERLYING_ID, EXPIRY_A);
    let applied = store::apply_svi(
        &mut svi_store,
        foreign_sid,
        MODEL_EARLY,
        PUBLISHED_EARLY,
        RECORDED,
        svi_params(),
    );
    assert_eq!(applied, false);
    assert!(store::svi(&svi_store, EXPIRY_A).is_none());

    return_shared(svi_store);
    scenario.end();
}

#[test]
fun an_older_svi_batch_is_skipped() {
    let (mut scenario, _value_id, svi_id) = setup_stores(UNDERLYING_ID);
    let mut svi_store = scenario.take_shared_by_id<BlockScholesSVIStore>(svi_id);

    apply_svi(&mut svi_store, EXPIRY_A, MODEL_LATE, PUBLISHED_LATE);
    let applied = apply_svi(&mut svi_store, EXPIRY_A, MODEL_EARLY, PUBLISHED_EARLY);
    assert_eq!(applied, false);

    assert_eq!(
        store::svi(&svi_store, EXPIRY_A).destroy_some().read_published_at_ms(),
        PUBLISHED_LATE,
    );

    return_shared(svi_store);
    scenario.end();
}

// === Liveness ===

/// The envelope time proves the feed is running even when no series moved, so it advances
/// separately from any observation and never regresses.
#[test]
fun recording_batches_advances_liveness_monotonically() {
    let (mut scenario, value_id, svi_id) = setup_stores(UNDERLYING_ID);
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let mut svi_store = scenario.take_shared_by_id<BlockScholesSVIStore>(svi_id);

    assert_eq!(value_store.value_store_last_batch_ts_ms(), 0);

    store::record_value_batch(&mut value_store, PUBLISHED_MID);
    assert_eq!(value_store.value_store_last_batch_ts_ms(), PUBLISHED_MID);

    store::record_value_batch(&mut value_store, PUBLISHED_EARLY);
    assert_eq!(value_store.value_store_last_batch_ts_ms(), PUBLISHED_MID);

    store::record_value_batch(&mut value_store, PUBLISHED_LATE);
    assert_eq!(value_store.value_store_last_batch_ts_ms(), PUBLISHED_LATE);

    store::record_svi_batch(&mut svi_store, PUBLISHED_LATE);
    store::record_svi_batch(&mut svi_store, PUBLISHED_EARLY);
    assert_eq!(svi_store.svi_store_last_batch_ts_ms(), PUBLISHED_LATE);

    return_shared(value_store);
    return_shared(svi_store);
    scenario.end();
}

// === Store identity and version ===

#[test]
fun a_new_store_reports_its_underlying_and_running_version() {
    let (mut scenario, value_id, svi_id) = setup_stores(UNDERLYING_ID);
    let value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let svi_store = scenario.take_shared_by_id<BlockScholesSVIStore>(svi_id);

    assert_eq!(value_store.value_store_underlying_id(), UNDERLYING_ID);
    assert_eq!(svi_store.svi_store_underlying_id(), UNDERLYING_ID);
    assert_eq!(value_store.value_store_version(), constants::current_version!());
    assert_eq!(svi_store.svi_store_version(), constants::current_version!());
    assert_eq!(value_store.value_store_id(), value_id);
    assert_eq!(svi_store.svi_store_id(), svi_id);

    return_shared(value_store);
    return_shared(svi_store);
    scenario.end();
}

#[test, expected_failure(abort_code = store::ENotNewerVersion)]
fun migrating_a_store_already_at_the_running_version_aborts() {
    let (mut scenario, value_id, _svi_id) = setup_stores(UNDERLYING_ID);
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);

    store::migrate_value_store(&mut value_store);

    abort
}

#[test, expected_failure(abort_code = store::ENotNewerVersion)]
fun migrating_an_svi_store_already_at_the_running_version_aborts() {
    let (mut scenario, _value_id, svi_id) = setup_stores(UNDERLYING_ID);
    let mut svi_store = scenario.take_shared_by_id<BlockScholesSVIStore>(svi_id);

    store::migrate_svi_store(&mut svi_store);

    abort
}

// === Helpers ===

fun setup_stores(propbook_underlying_id: u32): (Scenario, ID, ID) {
    let mut scenario = test::begin(ADMIN);
    let value_id = store::create_and_share_value_store(propbook_underlying_id, scenario.ctx());
    let svi_id = store::create_and_share_svi_store(propbook_underlying_id, scenario.ctx());
    scenario.next_tx(ADMIN);
    (scenario, value_id, svi_id)
}

fun apply_spot(
    value_store: &mut BlockScholesValueStore,
    model_timestamp_ms: u64,
    published_at_ms: u64,
    value: u128,
): bool {
    let sid = block_scholes_sid::spot(value_store.value_store_underlying_id());
    store::apply_value(value_store, sid, model_timestamp_ms, published_at_ms, RECORDED, value)
}

fun apply_forward(
    value_store: &mut BlockScholesValueStore,
    expiry_ms: u64,
    model_timestamp_ms: u64,
    published_at_ms: u64,
    value: u128,
): bool {
    let sid = block_scholes_sid::forward(value_store.value_store_underlying_id(), expiry_ms);
    store::apply_value(value_store, sid, model_timestamp_ms, published_at_ms, RECORDED, value)
}

fun apply_svi(
    svi_store: &mut BlockScholesSVIStore,
    expiry_ms: u64,
    model_timestamp_ms: u64,
    published_at_ms: u64,
): bool {
    let sid = block_scholes_sid::svi(svi_store.svi_store_underlying_id(), expiry_ms);
    store::apply_svi(svi_store, sid, model_timestamp_ms, published_at_ms, RECORDED, svi_params())
}

fun svi_params(): SVIParams {
    store::new_svi_params(
        SVI_A_MAG,
        SVI_A_NEG,
        SVI_B,
        SVI_SIGMA,
        SVI_RHO_MAG,
        SVI_RHO_NEG,
        SVI_M_MAG,
        SVI_M_NEG,
    )
}
