// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Covers what a store accepts and what it refuses, driven through the batch entries a relayer
/// actually calls. The refusals matter most: a relayer chooses which signed batches to submit and
/// when, so replaying an old batch, resubmitting one unchanged, or aiming another underlying's
/// batch at this store must leave the stored series alone without discarding the rest of the batch.
#[test_only]
module propbook::block_scholes_store_tests;

use bs_oracle::verify::{Self, ValueUpdate, SviUpdate};
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
use sui::{clock::{Self, Clock}, event, test_scenario::{Self as test, Scenario, return_shared}};

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
const CHAIN_TIME_MS: u64 = 1_000;

const SVI_A_MAG: u128 = 40_000_000;
const SVI_A_NEG: bool = true;
const SVI_B: u128 = 120_000_000;
const SVI_SIGMA: u128 = 90_000_000;
const SVI_RHO_MAG: u128 = 300_000_000;
const SVI_RHO_NEG: bool = true;
const SVI_M_MAG: u128 = 25_000_000;
const SVI_M_NEG: bool = false;

// === Accepting ===

#[test]
fun a_spot_observation_lands_with_all_three_clocks() {
    let (mut scenario, value_id, _svi_id) = setup_stores(UNDERLYING_ID);
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut value_store,
        PUBLISHED_EARLY,
        vector[spot_update(UNDERLYING_ID, MODEL_EARLY, SPOT)],
        &chain_clock,
    );

    let read = store::spot(&value_store).destroy_some();
    assert_eq!(read.read_value(), SPOT);
    assert_eq!(read.read_model_timestamp_ms(), MODEL_EARLY);
    assert_eq!(read.read_published_at_ms(), PUBLISHED_EARLY);
    assert_eq!(read.read_recorded_at_ms(), CHAIN_TIME_MS);

    clock::destroy_for_testing(chain_clock);
    return_shared(value_store);
    scenario.end();
}

#[test]
fun a_newer_batch_replaces_the_stored_observation() {
    let (mut scenario, value_id, _svi_id) = setup_stores(UNDERLYING_ID);
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut value_store,
        PUBLISHED_EARLY,
        vector[spot_update(UNDERLYING_ID, MODEL_EARLY, SPOT)],
        &chain_clock,
    );
    apply_values(
        &mut value_store,
        PUBLISHED_LATE,
        vector[spot_update(UNDERLYING_ID, MODEL_LATE, SPOT_LATER)],
        &chain_clock,
    );

    let read = store::spot(&value_store).destroy_some();
    assert_eq!(read.read_value(), SPOT_LATER);
    assert_eq!(read.read_published_at_ms(), PUBLISHED_LATE);

    clock::destroy_for_testing(chain_clock);
    return_shared(value_store);
    scenario.end();
}

/// A series that has not moved is retransmitted with its original model time while the envelope
/// advances, so the stored model time must stay put even as the series is refreshed.
#[test]
fun a_retransmission_advances_the_envelope_but_not_the_model_time() {
    let (mut scenario, value_id, _svi_id) = setup_stores(UNDERLYING_ID);
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut value_store,
        PUBLISHED_EARLY,
        vector[spot_update(UNDERLYING_ID, MODEL_EARLY, SPOT)],
        &chain_clock,
    );
    apply_values(
        &mut value_store,
        PUBLISHED_LATE,
        vector[spot_update(UNDERLYING_ID, MODEL_EARLY, SPOT)],
        &chain_clock,
    );

    let read = store::spot(&value_store).destroy_some();
    assert_eq!(read.read_model_timestamp_ms(), MODEL_EARLY);
    assert_eq!(read.read_published_at_ms(), PUBLISHED_LATE);
    assert_eq!(read.read_value(), SPOT);

    clock::destroy_for_testing(chain_clock);
    return_shared(value_store);
    scenario.end();
}

/// Spot and forward ride one batch and are separated only by their series ids.
#[test]
fun one_batch_fills_spot_and_every_forward_expiry_independently() {
    let (mut scenario, value_id, _svi_id) = setup_stores(UNDERLYING_ID);
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut value_store,
        PUBLISHED_EARLY,
        vector[
            spot_update(UNDERLYING_ID, MODEL_EARLY, SPOT),
            forward_update(UNDERLYING_ID, EXPIRY_A, MODEL_EARLY, FORWARD_A),
            forward_update(UNDERLYING_ID, EXPIRY_B, MODEL_EARLY, FORWARD_B),
        ],
        &chain_clock,
    );

    assert_eq!(store::spot(&value_store).destroy_some().read_value(), SPOT);
    assert_eq!(store::forward(&value_store, EXPIRY_A).destroy_some().read_value(), FORWARD_A);
    assert_eq!(store::forward(&value_store, EXPIRY_B).destroy_some().read_value(), FORWARD_B);

    clock::destroy_for_testing(chain_clock);
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

// === Refusing ===

/// Replaying an older batch must not roll the series back.
#[test]
fun an_older_batch_leaves_the_stored_observation_intact() {
    let (mut scenario, value_id, _svi_id) = setup_stores(UNDERLYING_ID);
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut value_store,
        PUBLISHED_LATE,
        vector[spot_update(UNDERLYING_ID, MODEL_LATE, SPOT_LATER)],
        &chain_clock,
    );
    apply_values(
        &mut value_store,
        PUBLISHED_EARLY,
        vector[spot_update(UNDERLYING_ID, MODEL_EARLY, SPOT)],
        &chain_clock,
    );

    let read = store::spot(&value_store).destroy_some();
    assert_eq!(read.read_value(), SPOT_LATER);
    assert_eq!(read.read_published_at_ms(), PUBLISHED_LATE);

    clock::destroy_for_testing(chain_clock);
    return_shared(value_store);
    scenario.end();
}

/// Two relayers racing the same batch must not make either of them fail.
#[test]
fun resubmitting_the_same_batch_changes_nothing_and_does_not_abort() {
    let (mut scenario, value_id, _svi_id) = setup_stores(UNDERLYING_ID);
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut value_store,
        PUBLISHED_MID,
        vector[spot_update(UNDERLYING_ID, MODEL_EARLY, SPOT)],
        &chain_clock,
    );
    apply_values(
        &mut value_store,
        PUBLISHED_MID,
        vector[spot_update(UNDERLYING_ID, MODEL_EARLY, SPOT_LATER)],
        &chain_clock,
    );

    let read = store::spot(&value_store).destroy_some();
    assert_eq!(read.read_value(), SPOT);
    assert_eq!(read.read_published_at_ms(), PUBLISHED_MID);

    clock::destroy_for_testing(chain_clock);
    return_shared(value_store);
    scenario.end();
}

/// A foreign series in an otherwise valid batch must be dropped while its neighbours still land.
#[test]
fun a_foreign_series_is_dropped_without_discarding_the_rest_of_the_batch() {
    let (mut scenario, value_id, _svi_id) = setup_stores(UNDERLYING_ID);
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut value_store,
        PUBLISHED_EARLY,
        vector[
            spot_update(OTHER_UNDERLYING_ID, MODEL_EARLY, SPOT_LATER),
            spot_update(UNDERLYING_ID, MODEL_EARLY, SPOT),
        ],
        &chain_clock,
    );

    assert_eq!(store::spot(&value_store).destroy_some().read_value(), SPOT);

    clock::destroy_for_testing(chain_clock);
    return_shared(value_store);
    scenario.end();
}

/// Aiming another underlying's batch at this store must neither store anything nor let the store
/// claim its own feed is alive.
#[test]
fun a_wholly_foreign_batch_stores_nothing_and_does_not_advance_liveness() {
    let (mut scenario, value_id, _svi_id) = setup_stores(UNDERLYING_ID);
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut value_store,
        PUBLISHED_LATE,
        vector[
            spot_update(OTHER_UNDERLYING_ID, MODEL_EARLY, SPOT),
            forward_update(OTHER_UNDERLYING_ID, EXPIRY_A, MODEL_EARLY, FORWARD_A),
        ],
        &chain_clock,
    );

    assert!(store::spot(&value_store).is_none());
    assert_eq!(value_store.value_store_last_batch_ts_ms(), 0);

    clock::destroy_for_testing(chain_clock);
    return_shared(value_store);
    scenario.end();
}

#[test]
fun a_zero_envelope_time_is_skipped() {
    let (mut scenario, value_id, _svi_id) = setup_stores(UNDERLYING_ID);
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut value_store,
        0,
        vector[spot_update(UNDERLYING_ID, MODEL_EARLY, SPOT)],
        &chain_clock,
    );

    assert!(store::spot(&value_store).is_none());

    clock::destroy_for_testing(chain_clock);
    return_shared(value_store);
    scenario.end();
}

/// An envelope stamped after the chain's own clock cannot be a real observation.
#[test]
fun an_envelope_time_after_chain_time_is_skipped() {
    let (mut scenario, value_id, _svi_id) = setup_stores(UNDERLYING_ID);
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut value_store,
        CHAIN_TIME_MS + 1,
        vector[spot_update(UNDERLYING_ID, MODEL_EARLY, SPOT)],
        &chain_clock,
    );

    assert!(store::spot(&value_store).is_none());

    clock::destroy_for_testing(chain_clock);
    return_shared(value_store);
    scenario.end();
}

// === SVI ===

#[test]
fun an_svi_batch_lands_every_parameter_source_native() {
    let (mut scenario, _value_id, svi_id) = setup_stores(UNDERLYING_ID);
    let mut svi_store = scenario.take_shared_by_id<BlockScholesSVIStore>(svi_id);
    let chain_clock = new_clock(&mut scenario);

    apply_svis(
        &mut svi_store,
        PUBLISHED_EARLY,
        vector[svi_update(UNDERLYING_ID, EXPIRY_A, MODEL_EARLY)],
        &chain_clock,
    );

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

    clock::destroy_for_testing(chain_clock);
    return_shared(svi_store);
    scenario.end();
}

#[test]
fun svi_expiries_are_independent() {
    let (mut scenario, _value_id, svi_id) = setup_stores(UNDERLYING_ID);
    let mut svi_store = scenario.take_shared_by_id<BlockScholesSVIStore>(svi_id);
    let chain_clock = new_clock(&mut scenario);

    apply_svis(
        &mut svi_store,
        PUBLISHED_EARLY,
        vector[svi_update(UNDERLYING_ID, EXPIRY_A, MODEL_EARLY)],
        &chain_clock,
    );

    assert!(store::svi(&svi_store, EXPIRY_A).is_some());
    assert!(store::svi(&svi_store, EXPIRY_B).is_none());

    clock::destroy_for_testing(chain_clock);
    return_shared(svi_store);
    scenario.end();
}

#[test]
fun a_foreign_svi_batch_stores_nothing_and_does_not_advance_liveness() {
    let (mut scenario, _value_id, svi_id) = setup_stores(UNDERLYING_ID);
    let mut svi_store = scenario.take_shared_by_id<BlockScholesSVIStore>(svi_id);
    let chain_clock = new_clock(&mut scenario);

    apply_svis(
        &mut svi_store,
        PUBLISHED_LATE,
        vector[svi_update(OTHER_UNDERLYING_ID, EXPIRY_A, MODEL_EARLY)],
        &chain_clock,
    );

    assert!(store::svi(&svi_store, EXPIRY_A).is_none());
    assert_eq!(svi_store.svi_store_last_batch_ts_ms(), 0);

    clock::destroy_for_testing(chain_clock);
    return_shared(svi_store);
    scenario.end();
}

#[test]
fun an_older_svi_batch_leaves_the_stored_parameters_intact() {
    let (mut scenario, _value_id, svi_id) = setup_stores(UNDERLYING_ID);
    let mut svi_store = scenario.take_shared_by_id<BlockScholesSVIStore>(svi_id);
    let chain_clock = new_clock(&mut scenario);

    apply_svis(
        &mut svi_store,
        PUBLISHED_LATE,
        vector[svi_update(UNDERLYING_ID, EXPIRY_A, MODEL_LATE)],
        &chain_clock,
    );
    apply_svis(
        &mut svi_store,
        PUBLISHED_EARLY,
        vector[svi_update(UNDERLYING_ID, EXPIRY_A, MODEL_EARLY)],
        &chain_clock,
    );

    let read = store::svi(&svi_store, EXPIRY_A).destroy_some();
    assert_eq!(read.read_published_at_ms(), PUBLISHED_LATE);
    assert_eq!(read.read_model_timestamp_ms(), MODEL_LATE);

    clock::destroy_for_testing(chain_clock);
    return_shared(svi_store);
    scenario.end();
}

// === Liveness ===

/// The envelope time proves the feed is running, so a batch of this underlying's series advances it
/// even when every series was stale and nothing was stored.
#[test]
fun a_batch_of_stale_own_series_still_advances_liveness() {
    let (mut scenario, value_id, _svi_id) = setup_stores(UNDERLYING_ID);
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut value_store,
        PUBLISHED_LATE,
        vector[spot_update(UNDERLYING_ID, MODEL_LATE, SPOT_LATER)],
        &chain_clock,
    );
    apply_values(
        &mut value_store,
        PUBLISHED_MID,
        vector[spot_update(UNDERLYING_ID, MODEL_EARLY, SPOT)],
        &chain_clock,
    );

    assert_eq!(store::spot(&value_store).destroy_some().read_value(), SPOT_LATER);
    assert_eq!(value_store.value_store_last_batch_ts_ms(), PUBLISHED_LATE);

    clock::destroy_for_testing(chain_clock);
    return_shared(value_store);
    scenario.end();
}

#[test]
fun liveness_never_regresses() {
    let (mut scenario, value_id, _svi_id) = setup_stores(UNDERLYING_ID);
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut value_store,
        PUBLISHED_MID,
        vector[spot_update(UNDERLYING_ID, MODEL_EARLY, SPOT)],
        &chain_clock,
    );
    assert_eq!(value_store.value_store_last_batch_ts_ms(), PUBLISHED_MID);

    apply_values(
        &mut value_store,
        PUBLISHED_EARLY,
        vector[spot_update(UNDERLYING_ID, MODEL_EARLY, SPOT)],
        &chain_clock,
    );
    assert_eq!(value_store.value_store_last_batch_ts_ms(), PUBLISHED_MID);

    clock::destroy_for_testing(chain_clock);
    return_shared(value_store);
    scenario.end();
}

// === Batch reporting ===

/// The counts are how an off-chain consumer tells "the feed ran and nothing moved" from "the feed
/// ran and this much moved", so they must distinguish series that were not ours from ours that did
/// not advance. Here one update is another underlying's, one is ours but stale, one is ours and new.
#[test]
fun an_ingested_batch_reports_what_it_carried_matched_and_stored() {
    let (mut scenario, value_id, _svi_id) = setup_stores(UNDERLYING_ID);
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut value_store,
        PUBLISHED_LATE,
        vector[spot_update(UNDERLYING_ID, MODEL_LATE, SPOT_LATER)],
        &chain_clock,
    );
    apply_values(
        &mut value_store,
        PUBLISHED_MID,
        vector[
            spot_update(OTHER_UNDERLYING_ID, MODEL_EARLY, SPOT),
            spot_update(UNDERLYING_ID, MODEL_EARLY, SPOT),
            forward_update(UNDERLYING_ID, EXPIRY_A, MODEL_EARLY, FORWARD_A),
        ],
        &chain_clock,
    );

    let events = event::events_by_type<store::BlockScholesBatchIngested>();
    assert_eq!(events.length(), 2);
    let (oracle_id, published_at_ms, update_count, matched, applied) = store::batch_ingested_fields(
        &events[1],
    );
    assert_eq!(oracle_id, value_id);
    assert_eq!(published_at_ms, PUBLISHED_MID);
    assert_eq!(update_count, 3);
    assert_eq!(matched, 2);
    assert_eq!(applied, 1);

    clock::destroy_for_testing(chain_clock);
    return_shared(value_store);
    scenario.end();
}

/// Every update in a batch shares the envelope time, so a batch naming one series twice cannot have
/// its second entry advance that series. The first entry owns the slot.
#[test]
fun a_series_repeated_within_one_batch_keeps_its_first_entry() {
    let (mut scenario, value_id, _svi_id) = setup_stores(UNDERLYING_ID);
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut value_store,
        PUBLISHED_EARLY,
        vector[
            spot_update(UNDERLYING_ID, MODEL_EARLY, SPOT),
            spot_update(UNDERLYING_ID, MODEL_LATE, SPOT_LATER),
        ],
        &chain_clock,
    );

    let read = store::spot(&value_store).destroy_some();
    assert_eq!(read.read_value(), SPOT);
    assert_eq!(read.read_model_timestamp_ms(), MODEL_EARLY);

    let events = event::events_by_type<store::BlockScholesBatchIngested>();
    let (_, _, update_count, matched, applied) = store::batch_ingested_fields(&events[0]);
    assert_eq!(update_count, 2);
    assert_eq!(matched, 2);
    assert_eq!(applied, 1);

    clock::destroy_for_testing(chain_clock);
    return_shared(value_store);
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
fun migrating_a_value_store_already_at_the_running_version_aborts() {
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

fun new_clock(scenario: &mut Scenario): Clock {
    let mut chain_clock = clock::create_for_testing(scenario.ctx());
    chain_clock.set_for_testing(CHAIN_TIME_MS);
    chain_clock
}

fun apply_values(
    value_store: &mut BlockScholesValueStore,
    published_at_ms: u64,
    updates: vector<ValueUpdate>,
    chain_clock: &Clock,
) {
    store::apply_value_batch(
        value_store,
        verify::new_value_batch_for_testing(published_at_ms, updates),
        chain_clock,
    )
}

fun apply_svis(
    svi_store: &mut BlockScholesSVIStore,
    published_at_ms: u64,
    updates: vector<SviUpdate>,
    chain_clock: &Clock,
) {
    store::apply_svi_batch(
        svi_store,
        verify::new_svi_batch_for_testing(published_at_ms, updates),
        chain_clock,
    )
}

fun spot_update(propbook_underlying_id: u32, model_timestamp_ms: u64, value: u128): ValueUpdate {
    verify::new_value_update_for_testing(
        block_scholes_sid::spot(propbook_underlying_id),
        model_timestamp_ms,
        value,
    )
}

fun forward_update(
    propbook_underlying_id: u32,
    expiry_ms: u64,
    model_timestamp_ms: u64,
    value: u128,
): ValueUpdate {
    verify::new_value_update_for_testing(
        block_scholes_sid::forward(propbook_underlying_id, expiry_ms),
        model_timestamp_ms,
        value,
    )
}

fun svi_update(propbook_underlying_id: u32, expiry_ms: u64, model_timestamp_ms: u64): SviUpdate {
    verify::new_svi_for_testing(
        block_scholes_sid::svi(propbook_underlying_id, expiry_ms),
        model_timestamp_ms,
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
