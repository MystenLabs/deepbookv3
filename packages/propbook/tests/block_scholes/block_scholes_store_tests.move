// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Covers what a store accepts and what it refuses, driven through the batch entries a relayer
/// actually calls. The refusals matter most: a relayer chooses which signed batches to submit and
/// when, so descriptor mismatches fail the whole transaction while stale authenticated data is
/// skipped without discarding newer entries from the same canonical batch.
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
use std::{string::String, unit_test::assert_eq};
use sui::{clock::{Self, Clock}, event, test_scenario::{Self as test, Scenario, return_shared}};

const ADMIN: address = @0xAD;
const SERIES_KIND_SPOT: u8 = 0;
const SERIES_KIND_FORWARD: u8 = 1;
const SPOT_EXPIRY_MS: u64 = 0;

const EXPIRY_A: u64 = 1_700_100_000_000;
const EXPIRY_B: u64 = 1_700_200_000_000;

const SPOT: u128 = 50_000_000_000_000;
const SPOT_LATER: u128 = 49_000_000_000_000;
const FORWARD_A: u128 = 50_500_000_000_000;
const FORWARD_B: u128 = 51_500_000_000_000;

// Provider clocks. `MODEL_*` is when a series' data is "as of"; `PUBLISHED_*` is the envelope time
// of the batch carrying it, which advances on every flush whether or not the series moved.
const MODEL_EARLY: u64 = 100;
const MODEL_MID: u64 = 200;
const MODEL_LATE: u64 = 300;
const PUBLISHED_EARLY: u64 = 100;
const PUBLISHED_MID: u64 = 200;
const PUBLISHED_LATE: u64 = 300;
const PUBLISHED_LATER: u64 = 400;
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
    let (mut scenario, value_id, _svi_id) = setup_stores();
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut value_store,
        PUBLISHED_EARLY,
        vector[spot_update(&btc(), MODEL_EARLY, SPOT)],
        &chain_clock,
        scenario.ctx(),
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

/// Off-chain monitoring reads stored-series liveness from the observation event, so what it
/// reports must be exactly what was stored: this store's id, the series' own sid, and the kept
/// observation with all three clocks.
#[test]
fun a_stored_observation_is_what_its_event_reports() {
    let (mut scenario, value_id, _svi_id) = setup_stores();
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut value_store,
        PUBLISHED_EARLY,
        vector[spot_update(&btc(), MODEL_EARLY, SPOT)],
        &chain_clock,
        scenario.ctx(),
    );

    let events = event::events_by_type<store::BlockScholesObservationRecorded<BsRead<u128>>>();
    assert_eq!(events.length(), 1);
    let (oracle_id, sid, series_kind, expiry_ms, observation) = store::observation_recorded_fields(
        &events[0],
    );
    assert_eq!(oracle_id, value_id);
    assert_eq!(sid, block_scholes_sid::spot(&btc()));
    assert_eq!(series_kind, SERIES_KIND_SPOT);
    assert_eq!(expiry_ms, SPOT_EXPIRY_MS);
    assert_eq!(observation.read_value(), SPOT);
    assert_eq!(observation.read_model_timestamp_ms(), MODEL_EARLY);
    assert_eq!(observation.read_published_at_ms(), PUBLISHED_EARLY);
    assert_eq!(observation.read_recorded_at_ms(), CHAIN_TIME_MS);

    clock::destroy_for_testing(chain_clock);
    return_shared(value_store);
    scenario.end();
}

#[test]
fun a_newer_batch_replaces_the_stored_observation() {
    let (mut scenario, value_id, _svi_id) = setup_stores();
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut value_store,
        PUBLISHED_EARLY,
        vector[spot_update(&btc(), MODEL_EARLY, SPOT)],
        &chain_clock,
        scenario.ctx(),
    );
    apply_values(
        &mut value_store,
        PUBLISHED_LATE,
        vector[spot_update(&btc(), MODEL_LATE, SPOT_LATER)],
        &chain_clock,
        scenario.ctx(),
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
    let (mut scenario, value_id, _svi_id) = setup_stores();
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut value_store,
        PUBLISHED_EARLY,
        vector[spot_update(&btc(), MODEL_EARLY, SPOT)],
        &chain_clock,
        scenario.ctx(),
    );
    apply_values(
        &mut value_store,
        PUBLISHED_LATE,
        vector[spot_update(&btc(), MODEL_EARLY, SPOT)],
        &chain_clock,
        scenario.ctx(),
    );

    let read = store::spot(&value_store).destroy_some();
    assert_eq!(read.read_model_timestamp_ms(), MODEL_EARLY);
    assert_eq!(read.read_published_at_ms(), PUBLISHED_LATE);
    assert_eq!(read.read_value(), SPOT);

    clock::destroy_for_testing(chain_clock);
    return_shared(value_store);
    scenario.end();
}

/// The signed spot and forward lanes are applied separately, while forward expiries share one
/// homogeneous batch and remain independently readable.
#[test]
fun typed_batches_fill_spot_and_every_forward_expiry_independently() {
    let (mut scenario, value_id, _svi_id) = setup_stores();
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut value_store,
        PUBLISHED_EARLY,
        vector[spot_update(&btc(), MODEL_EARLY, SPOT)],
        &chain_clock,
        scenario.ctx(),
    );
    apply_forwards(
        &mut value_store,
        PUBLISHED_EARLY,
        vector[
            forward_update(&btc(), EXPIRY_A, MODEL_EARLY, FORWARD_A),
            forward_update(&btc(), EXPIRY_B, MODEL_EARLY, FORWARD_B),
        ],
        vector[EXPIRY_A, EXPIRY_B],
        &chain_clock,
        scenario.ctx(),
    );

    assert_eq!(store::spot(&value_store).destroy_some().read_value(), SPOT);
    assert_eq!(store::forward(&value_store, EXPIRY_A).destroy_some().read_value(), FORWARD_A);
    assert_eq!(store::forward(&value_store, EXPIRY_B).destroy_some().read_value(), FORWARD_B);
    let events = event::events_by_type<store::BlockScholesObservationRecorded<BsRead<u128>>>();
    assert_eq!(events.length(), 3);
    let (_, _, series_kind, expiry_ms, _) = store::observation_recorded_fields(&events[1]);
    assert_eq!(series_kind, SERIES_KIND_FORWARD);
    assert_eq!(expiry_ms, EXPIRY_A);
    let (_, _, series_kind, expiry_ms, _) = store::observation_recorded_fields(&events[2]);
    assert_eq!(series_kind, SERIES_KIND_FORWARD);
    assert_eq!(expiry_ms, EXPIRY_B);

    clock::destroy_for_testing(chain_clock);
    return_shared(value_store);
    scenario.end();
}

#[test]
fun reads_are_none_before_anything_lands() {
    let (scenario, value_id, svi_id) = setup_stores();
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
    let (mut scenario, value_id, _svi_id) = setup_stores();
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut value_store,
        PUBLISHED_LATE,
        vector[spot_update(&btc(), MODEL_LATE, SPOT_LATER)],
        &chain_clock,
        scenario.ctx(),
    );
    apply_values(
        &mut value_store,
        PUBLISHED_EARLY,
        vector[spot_update(&btc(), MODEL_EARLY, SPOT)],
        &chain_clock,
        scenario.ctx(),
    );

    let read = store::spot(&value_store).destroy_some();
    assert_eq!(read.read_value(), SPOT_LATER);
    assert_eq!(read.read_published_at_ms(), PUBLISHED_LATE);

    clock::destroy_for_testing(chain_clock);
    return_shared(value_store);
    scenario.end();
}

/// The provider never promises that a later flush carries later model times, so a fresher envelope
/// alone must not be able to roll a series' model data back.
#[test]
fun a_newer_envelope_with_an_older_model_time_cannot_roll_the_series_back() {
    let (mut scenario, value_id, _svi_id) = setup_stores();
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut value_store,
        PUBLISHED_LATE,
        vector[spot_update(&btc(), MODEL_LATE, SPOT)],
        &chain_clock,
        scenario.ctx(),
    );
    apply_values(
        &mut value_store,
        PUBLISHED_LATER,
        vector[spot_update(&btc(), MODEL_EARLY, SPOT_LATER)],
        &chain_clock,
        scenario.ctx(),
    );

    let read = store::spot(&value_store).destroy_some();
    assert_eq!(read.read_value(), SPOT);
    assert_eq!(read.read_model_timestamp_ms(), MODEL_LATE);
    assert_eq!(read.read_published_at_ms(), PUBLISHED_LATE);

    clock::destroy_for_testing(chain_clock);
    return_shared(value_store);
    scenario.end();
}

/// Newer model data is the better observation whichever flush carried it; it lands even from an
/// older envelope, and freshness then honestly reflects that envelope's publish time.
#[test]
fun newer_model_data_in_an_older_envelope_still_lands() {
    let (mut scenario, value_id, _svi_id) = setup_stores();
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut value_store,
        PUBLISHED_LATE,
        vector[spot_update(&btc(), MODEL_EARLY, SPOT)],
        &chain_clock,
        scenario.ctx(),
    );
    apply_values(
        &mut value_store,
        PUBLISHED_MID,
        vector[spot_update(&btc(), MODEL_MID, SPOT_LATER)],
        &chain_clock,
        scenario.ctx(),
    );

    let read = store::spot(&value_store).destroy_some();
    assert_eq!(read.read_value(), SPOT_LATER);
    assert_eq!(read.read_model_timestamp_ms(), MODEL_MID);
    assert_eq!(read.read_published_at_ms(), PUBLISHED_MID);

    clock::destroy_for_testing(chain_clock);
    return_shared(value_store);
    scenario.end();
}

/// The relayer chooses submission order, so the stored observation must be the same for any order
/// of the same signed batches — otherwise ordering becomes a lever over the data.
#[test]
fun the_stored_observation_is_the_same_whatever_order_batches_land_in() {
    let mut scenario = test::begin(ADMIN);
    let forward_id = store::create_and_share_value_store(btc(), scenario.ctx());
    let reversed_id = store::create_and_share_value_store(btc(), scenario.ctx());
    scenario.next_tx(ADMIN);
    let mut forward_store = scenario.take_shared_by_id<BlockScholesValueStore>(forward_id);
    let mut reversed_store = scenario.take_shared_by_id<BlockScholesValueStore>(reversed_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut forward_store,
        PUBLISHED_MID,
        vector[spot_update(&btc(), MODEL_MID, SPOT)],
        &chain_clock,
        scenario.ctx(),
    );
    apply_values(
        &mut forward_store,
        PUBLISHED_LATE,
        vector[spot_update(&btc(), MODEL_EARLY, SPOT_LATER)],
        &chain_clock,
        scenario.ctx(),
    );

    apply_values(
        &mut reversed_store,
        PUBLISHED_LATE,
        vector[spot_update(&btc(), MODEL_EARLY, SPOT_LATER)],
        &chain_clock,
        scenario.ctx(),
    );
    apply_values(
        &mut reversed_store,
        PUBLISHED_MID,
        vector[spot_update(&btc(), MODEL_MID, SPOT)],
        &chain_clock,
        scenario.ctx(),
    );

    let forward_read = store::spot(&forward_store).destroy_some();
    let reversed_read = store::spot(&reversed_store).destroy_some();
    assert_eq!(forward_read.read_value(), reversed_read.read_value());
    assert_eq!(forward_read.read_model_timestamp_ms(), reversed_read.read_model_timestamp_ms());
    assert_eq!(forward_read.read_published_at_ms(), reversed_read.read_published_at_ms());
    assert_eq!(forward_read.read_value(), SPOT);
    assert_eq!(forward_read.read_model_timestamp_ms(), MODEL_MID);

    clock::destroy_for_testing(chain_clock);
    return_shared(forward_store);
    return_shared(reversed_store);
    scenario.end();
}

/// Data cannot be "as of" later than its own publish time; storing such an entry would let the
/// pricing roll-down anchor land on or past a live market's expiry. The garbage entry is dropped
/// while its valid neighbour still lands.
#[test]
fun a_model_time_after_its_own_envelope_is_skipped() {
    let (mut scenario, value_id, _svi_id) = setup_stores();
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_forwards(
        &mut value_store,
        PUBLISHED_EARLY,
        vector[
            forward_update(&btc(), EXPIRY_A, MODEL_LATE, FORWARD_A),
            forward_update(&btc(), EXPIRY_B, MODEL_EARLY, FORWARD_B),
        ],
        vector[EXPIRY_A, EXPIRY_B],
        &chain_clock,
        scenario.ctx(),
    );

    assert!(store::forward(&value_store, EXPIRY_A).is_none());
    assert_eq!(store::forward(&value_store, EXPIRY_B).destroy_some().read_value(), FORWARD_B);

    let events = event::events_by_type<store::BlockScholesBatchIngested>();
    let (_, _, update_count, applied) = store::batch_ingested_fields(&events[0]);
    assert_eq!(update_count, 2);
    assert_eq!(applied, 1);

    clock::destroy_for_testing(chain_clock);
    return_shared(value_store);
    scenario.end();
}

#[test]
fun an_svi_model_time_after_its_own_envelope_is_skipped() {
    let (mut scenario, _value_id, svi_id) = setup_stores();
    let mut svi_store = scenario.take_shared_by_id<BlockScholesSVIStore>(svi_id);
    let chain_clock = new_clock(&mut scenario);

    apply_svis(
        &mut svi_store,
        PUBLISHED_EARLY,
        vector[svi_update(&btc(), EXPIRY_A, MODEL_LATE)],
        &chain_clock,
        scenario.ctx(),
    );

    assert!(store::svi(&svi_store, EXPIRY_A).is_none());

    clock::destroy_for_testing(chain_clock);
    return_shared(svi_store);
    scenario.end();
}

/// Two relayers racing the same batch must not make either of them fail.
#[test]
fun resubmitting_the_same_batch_changes_nothing_and_does_not_abort() {
    let (mut scenario, value_id, _svi_id) = setup_stores();
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut value_store,
        PUBLISHED_MID,
        vector[spot_update(&btc(), MODEL_EARLY, SPOT)],
        &chain_clock,
        scenario.ctx(),
    );
    apply_values(
        &mut value_store,
        PUBLISHED_MID,
        vector[spot_update(&btc(), MODEL_EARLY, SPOT_LATER)],
        &chain_clock,
        scenario.ctx(),
    );

    let read = store::spot(&value_store).destroy_some();
    assert_eq!(read.read_value(), SPOT);
    assert_eq!(read.read_published_at_ms(), PUBLISHED_MID);

    clock::destroy_for_testing(chain_clock);
    return_shared(value_store);
    scenario.end();
}

/// Every descriptor is checked before storage, so one foreign SID rejects the whole batch.
#[test, expected_failure(abort_code = store::ESeriesIdMismatch)]
fun a_foreign_series_rejects_the_whole_forward_batch() {
    let (mut scenario, value_id, _svi_id) = setup_stores();
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_forwards(
        &mut value_store,
        PUBLISHED_EARLY,
        vector[
            forward_update(&eth(), EXPIRY_A, MODEL_EARLY, FORWARD_A),
            forward_update(&btc(), EXPIRY_B, MODEL_EARLY, FORWARD_B),
        ],
        vector[EXPIRY_A, EXPIRY_B],
        &chain_clock,
        scenario.ctx(),
    );

    abort 999
}

#[test, expected_failure(abort_code = store::EUnexpectedBatchLength)]
fun forward_batch_with_wrong_expiry_count_aborts() {
    let (mut scenario, value_id, _svi_id) = setup_stores();
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_forwards(
        &mut value_store,
        PUBLISHED_LATE,
        vector[forward_update(&btc(), EXPIRY_A, MODEL_EARLY, FORWARD_A)],
        vector[],
        &chain_clock,
        scenario.ctx(),
    );

    abort 999
}

#[test]
fun a_zero_envelope_time_is_skipped() {
    let (mut scenario, value_id, _svi_id) = setup_stores();
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut value_store,
        0,
        vector[spot_update(&btc(), MODEL_EARLY, SPOT)],
        &chain_clock,
        scenario.ctx(),
    );

    assert!(store::spot(&value_store).is_none());

    clock::destroy_for_testing(chain_clock);
    return_shared(value_store);
    scenario.end();
}

/// An envelope stamped after the chain's own clock cannot be a real observation.
#[test]
fun an_envelope_time_after_chain_time_is_skipped() {
    let (mut scenario, value_id, _svi_id) = setup_stores();
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut value_store,
        CHAIN_TIME_MS + 1,
        vector[spot_update(&btc(), MODEL_EARLY, SPOT)],
        &chain_clock,
        scenario.ctx(),
    );

    assert!(store::spot(&value_store).is_none());

    clock::destroy_for_testing(chain_clock);
    return_shared(value_store);
    scenario.end();
}

/// The just-inside edge of the same skip: an envelope stamped at exactly the chain's clock is a
/// real observation and lands.
#[test]
fun an_envelope_time_at_exactly_chain_time_lands() {
    let (mut scenario, value_id, _svi_id) = setup_stores();
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_values(
        &mut value_store,
        CHAIN_TIME_MS,
        vector[spot_update(&btc(), MODEL_EARLY, SPOT)],
        &chain_clock,
        scenario.ctx(),
    );

    let read = store::spot(&value_store).destroy_some();
    assert_eq!(read.read_value(), SPOT);
    assert_eq!(read.read_published_at_ms(), CHAIN_TIME_MS);

    clock::destroy_for_testing(chain_clock);
    return_shared(value_store);
    scenario.end();
}

// === SVI ===

#[test]
fun an_svi_batch_lands_every_parameter_source_native() {
    let (mut scenario, _value_id, svi_id) = setup_stores();
    let mut svi_store = scenario.take_shared_by_id<BlockScholesSVIStore>(svi_id);
    let chain_clock = new_clock(&mut scenario);

    apply_svis(
        &mut svi_store,
        PUBLISHED_EARLY,
        vector[svi_update(&btc(), EXPIRY_A, MODEL_EARLY)],
        &chain_clock,
        scenario.ctx(),
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
    let (mut scenario, _value_id, svi_id) = setup_stores();
    let mut svi_store = scenario.take_shared_by_id<BlockScholesSVIStore>(svi_id);
    let chain_clock = new_clock(&mut scenario);

    apply_svis(
        &mut svi_store,
        PUBLISHED_EARLY,
        vector[svi_update(&btc(), EXPIRY_A, MODEL_EARLY)],
        &chain_clock,
        scenario.ctx(),
    );

    assert!(store::svi(&svi_store, EXPIRY_A).is_some());
    assert!(store::svi(&svi_store, EXPIRY_B).is_none());

    clock::destroy_for_testing(chain_clock);
    return_shared(svi_store);
    scenario.end();
}

#[test, expected_failure(abort_code = store::ESeriesIdMismatch)]
fun a_foreign_svi_series_rejects_the_batch() {
    let (mut scenario, _value_id, svi_id) = setup_stores();
    let mut svi_store = scenario.take_shared_by_id<BlockScholesSVIStore>(svi_id);
    let chain_clock = new_clock(&mut scenario);

    apply_svis(
        &mut svi_store,
        PUBLISHED_LATE,
        vector[svi_update(&eth(), EXPIRY_A, MODEL_EARLY)],
        &chain_clock,
        scenario.ctx(),
    );

    abort 999
}

#[test]
fun an_older_svi_batch_leaves_the_stored_parameters_intact() {
    let (mut scenario, _value_id, svi_id) = setup_stores();
    let mut svi_store = scenario.take_shared_by_id<BlockScholesSVIStore>(svi_id);
    let chain_clock = new_clock(&mut scenario);

    apply_svis(
        &mut svi_store,
        PUBLISHED_LATE,
        vector[svi_update(&btc(), EXPIRY_A, MODEL_LATE)],
        &chain_clock,
        scenario.ctx(),
    );
    apply_svis(
        &mut svi_store,
        PUBLISHED_EARLY,
        vector[svi_update(&btc(), EXPIRY_A, MODEL_EARLY)],
        &chain_clock,
        scenario.ctx(),
    );

    let read = store::svi(&svi_store, EXPIRY_A).destroy_some();
    assert_eq!(read.read_published_at_ms(), PUBLISHED_LATE);
    assert_eq!(read.read_model_timestamp_ms(), MODEL_LATE);

    clock::destroy_for_testing(chain_clock);
    return_shared(svi_store);
    scenario.end();
}

// === Batch reporting ===

/// The counts let an off-chain consumer distinguish "the feed ran and nothing moved" from "the
/// feed ran and this much moved." Canonical admission is all-or-nothing, so `update_count` is the
/// verified batch size and `applied` excludes only observations that did not advance their series.
#[test]
fun an_ingested_batch_reports_what_it_carried_and_stored() {
    let (mut scenario, value_id, _svi_id) = setup_stores();
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_forwards(
        &mut value_store,
        PUBLISHED_LATE,
        vector[forward_update(&btc(), EXPIRY_A, MODEL_LATE, FORWARD_A)],
        vector[EXPIRY_A],
        &chain_clock,
        scenario.ctx(),
    );
    apply_forwards(
        &mut value_store,
        PUBLISHED_MID,
        vector[
            forward_update(&btc(), EXPIRY_A, MODEL_EARLY, FORWARD_A),
            forward_update(&btc(), EXPIRY_B, MODEL_EARLY, FORWARD_B),
        ],
        vector[EXPIRY_A, EXPIRY_B],
        &chain_clock,
        scenario.ctx(),
    );

    let events = event::events_by_type<store::BlockScholesBatchIngested>();
    assert_eq!(events.length(), 2);
    let (oracle_id, published_at_ms, update_count, applied) = store::batch_ingested_fields(
        &events[1],
    );
    assert_eq!(oracle_id, value_id);
    assert_eq!(published_at_ms, PUBLISHED_MID);
    assert_eq!(update_count, 2);
    assert_eq!(applied, 1);

    clock::destroy_for_testing(chain_clock);
    return_shared(value_store);
    scenario.end();
}

/// A batch naming one series twice resolves by model time, like everything else: an equal model
/// time cannot displace the first entry (the envelope is shared, so nothing advances), while a
/// strictly newer valid model time is newer data and wins.
#[test]
fun a_series_repeated_within_one_batch_resolves_by_model_time() {
    let (mut scenario, value_id, _svi_id) = setup_stores();
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let chain_clock = new_clock(&mut scenario);

    apply_forwards(
        &mut value_store,
        PUBLISHED_LATE,
        vector[
            forward_update(&btc(), EXPIRY_A, MODEL_EARLY, FORWARD_A),
            forward_update(&btc(), EXPIRY_A, MODEL_EARLY, FORWARD_B),
            forward_update(&btc(), EXPIRY_A, MODEL_MID, FORWARD_B),
        ],
        vector[EXPIRY_A, EXPIRY_A, EXPIRY_A],
        &chain_clock,
        scenario.ctx(),
    );

    let read = store::forward(&value_store, EXPIRY_A).destroy_some();
    assert_eq!(read.read_value(), FORWARD_B);
    assert_eq!(read.read_model_timestamp_ms(), MODEL_MID);

    let events = event::events_by_type<store::BlockScholesBatchIngested>();
    let (_, _, update_count, applied) = store::batch_ingested_fields(&events[0]);
    assert_eq!(update_count, 3);
    assert_eq!(applied, 2);

    clock::destroy_for_testing(chain_clock);
    return_shared(value_store);
    scenario.end();
}

// === Store identity and version ===

#[test]
fun a_new_store_reports_its_base_asset_and_running_version() {
    let (scenario, value_id, svi_id) = setup_stores();
    let value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);
    let svi_store = scenario.take_shared_by_id<BlockScholesSVIStore>(svi_id);

    assert_eq!(value_store.value_store_base_asset(), btc());
    assert_eq!(svi_store.svi_store_base_asset(), btc());
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
    let (scenario, value_id, _svi_id) = setup_stores();
    let mut value_store = scenario.take_shared_by_id<BlockScholesValueStore>(value_id);

    store::migrate_value_store(&mut value_store);

    abort
}

#[test, expected_failure(abort_code = store::ENotNewerVersion)]
fun migrating_an_svi_store_already_at_the_running_version_aborts() {
    let (scenario, _value_id, svi_id) = setup_stores();
    let mut svi_store = scenario.take_shared_by_id<BlockScholesSVIStore>(svi_id);

    store::migrate_svi_store(&mut svi_store);

    abort
}

// === Helpers ===

fun setup_stores(): (Scenario, ID, ID) {
    let mut scenario = test::begin(ADMIN);
    let value_id = store::create_and_share_value_store(btc(), scenario.ctx());
    let svi_id = store::create_and_share_svi_store(btc(), scenario.ctx());
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
    ctx: &TxContext,
) {
    store::apply_spot_batch(
        value_store,
        verify::new_value_batch_for_testing(published_at_ms, updates),
        chain_clock,
        ctx,
    )
}

fun apply_svis(
    svi_store: &mut BlockScholesSVIStore,
    published_at_ms: u64,
    updates: vector<SviUpdate>,
    chain_clock: &Clock,
    ctx: &TxContext,
) {
    store::apply_svi_batch(
        svi_store,
        verify::new_svi_batch_for_testing(published_at_ms, updates),
        vector[EXPIRY_A],
        chain_clock,
        ctx,
    )
}

fun apply_forwards(
    value_store: &mut BlockScholesValueStore,
    published_at_ms: u64,
    updates: vector<ValueUpdate>,
    expiries_ms: vector<u64>,
    chain_clock: &Clock,
    ctx: &TxContext,
) {
    store::apply_forward_batch(
        value_store,
        verify::new_value_batch_for_testing(published_at_ms, updates),
        expiries_ms,
        chain_clock,
        ctx,
    )
}

fun spot_update(base_asset: &String, model_timestamp_ms: u64, value: u128): ValueUpdate {
    verify::new_value_update_for_testing(
        block_scholes_sid::spot(base_asset),
        model_timestamp_ms,
        value,
    )
}

fun forward_update(
    base_asset: &String,
    expiry_ms: u64,
    model_timestamp_ms: u64,
    value: u128,
): ValueUpdate {
    verify::new_value_update_for_testing(
        block_scholes_sid::forward(base_asset, expiry_ms),
        model_timestamp_ms,
        value,
    )
}

fun svi_update(base_asset: &String, expiry_ms: u64, model_timestamp_ms: u64): SviUpdate {
    verify::new_svi_for_testing(
        block_scholes_sid::svi(base_asset, expiry_ms),
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

fun btc(): String {
    b"BTC".to_string()
}

fun eth(): String {
    b"ETH".to_string()
}
