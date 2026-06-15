// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module propbook::block_scholes_feed_tests;

use block_scholes_oracle::update::{Self, Update};
use propbook::{
    block_scholes_feed::{Self, BlockScholesFeed},
    registry::{Self, OracleRegistry}
};
use std::unit_test::assert_eq;
use sui::{clock, test_scenario::{Self as test, Scenario, return_shared}};

const ADMIN: address = @0xAD;
const BS_SOURCE_ID: u32 = 1;
const OTHER_BS_SOURCE_ID: u32 = 2;
const SHARED_SOURCE_ID: u32 = 7;

const SPOT: u64 = 50_000_000_000_000;
const SPOT_LATER: u64 = 49_000_000_000_000;
const EXPIRY_A: u64 = 1_700_100_000_000;
const EXPIRY_B: u64 = 1_700_200_000_000;
const UNKNOWN_EXPIRY: u64 = 9_999_999_999;
const FORWARD_A: u64 = 50_500_000_000_000;
const FORWARD_B: u64 = 49_000_000_000_000;
const FORWARD_A2: u64 = 50_600_000_000_000;
const SVI_A: u64 = 40_000_000;
const SVI_B: u64 = 120_000_000;
const SVI_SIGMA: u64 = 90_000_000;
const RHO_MAG: u64 = 300_000_000;
const RHO_NEG: bool = true;
const M_MAG: u64 = 25_000_000;
const M_NEG: bool = false;
const FLOAT_SCALING: u64 = 1_000_000_000;
const T_ZERO: u64 = 0;
const T_EARLY: u64 = 100;
const T_MID: u64 = 150;
const T_LATE: u64 = 200;
const T_FUTURE: u64 = 2_000_000;
const LANDED_EARLY: u64 = 120;
const LANDED_HIGH: u64 = 1_000_000;
const VERSION_ZERO: u64 = 0;

#[test]
fun update_records_raw_and_normalized_latest() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_EARLY);

    feed.update(
        bs_update(BS_SOURCE_ID, EXPIRY_A, T_EARLY, SPOT, FORWARD_A),
        &clock,
        scenario.ctx(),
    );

    assert_eq!(feed.bs_source_id(), BS_SOURCE_ID);
    assert_eq!(feed.version(), propbook::constants::current_version!());

    let raw_read = feed.raw_surface(EXPIRY_A);
    assert_eq!(raw_read.read_source_timestamp_ms(), T_EARLY);
    assert_eq!(raw_read.read_update_timestamp_ms(), LANDED_EARLY);
    let raw = raw_read.read_value();
    assert_eq!(block_scholes_feed::raw_bs_source_id(&raw), BS_SOURCE_ID);
    assert_eq!(block_scholes_feed::raw_expiry_ms(&raw), EXPIRY_A);
    assert_eq!(block_scholes_feed::raw_spot(&raw), SPOT);
    assert_eq!(block_scholes_feed::raw_forward(&raw), FORWARD_A);

    assert_surface(
        &feed.normalized_surface(EXPIRY_A).destroy_some(),
        SPOT,
        FORWARD_A,
        T_EARLY,
        LANDED_EARLY,
    );
    assert!(feed.normalized_surface_at(EXPIRY_A, T_EARLY).is_none());

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
}

#[test]
fun per_expiry_latest_advances_independently() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.update(bs_update(BS_SOURCE_ID, EXPIRY_A, T_EARLY, SPOT, FORWARD_A), &clock, scenario.ctx());
    feed.update(bs_update(BS_SOURCE_ID, EXPIRY_B, T_EARLY, SPOT, FORWARD_B), &clock, scenario.ctx());
    feed.update(
        bs_update(BS_SOURCE_ID, EXPIRY_A, T_MID, SPOT_LATER, FORWARD_A2),
        &clock,
        scenario.ctx(),
    );

    assert_surface(
        &feed.normalized_surface(EXPIRY_A).destroy_some(),
        SPOT_LATER,
        FORWARD_A2,
        T_MID,
        LANDED_HIGH,
    );
    assert_surface(
        &feed.normalized_surface(EXPIRY_B).destroy_some(),
        SPOT,
        FORWARD_B,
        T_EARLY,
        LANDED_HIGH,
    );

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
}

#[test]
fun insert_at_records_exact_surface_without_latest() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.insert_at(
        bs_update(BS_SOURCE_ID, EXPIRY_A, T_EARLY, SPOT, FORWARD_A),
        &clock,
        scenario.ctx(),
    );

    assert!(feed.normalized_surface(EXPIRY_A).is_none());
    assert_surface(
        &feed.normalized_surface_at(EXPIRY_A, T_EARLY).destroy_some(),
        SPOT,
        FORWARD_A,
        T_EARLY,
        LANDED_HIGH,
    );
    assert!(feed.normalized_surface_at(EXPIRY_A, T_EARLY + 1).is_none());

    let raw_read = feed.raw_surface_at(EXPIRY_A, T_EARLY);
    assert_eq!(raw_read.read_source_timestamp_ms(), T_EARLY);
    assert_eq!(block_scholes_feed::raw_forward(&raw_read.read_value()), FORWARD_A);

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
}

#[test]
fun stale_future_and_zero_updates_are_no_ops() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.update(bs_update(BS_SOURCE_ID, EXPIRY_A, T_MID, SPOT, FORWARD_A), &clock, scenario.ctx());
    feed.update(
        bs_update(BS_SOURCE_ID, EXPIRY_A, T_MID, SPOT_LATER, FORWARD_A2),
        &clock,
        scenario.ctx(),
    );
    feed.update(
        bs_update(BS_SOURCE_ID, EXPIRY_A, T_EARLY, SPOT_LATER, FORWARD_A2),
        &clock,
        scenario.ctx(),
    );
    feed.update(
        bs_update(BS_SOURCE_ID, EXPIRY_A, T_FUTURE, SPOT_LATER, FORWARD_A2),
        &clock,
        scenario.ctx(),
    );
    feed.update(
        bs_update(BS_SOURCE_ID, EXPIRY_A, T_ZERO, SPOT_LATER, FORWARD_A2),
        &clock,
        scenario.ctx(),
    );

    assert_surface(
        &feed.normalized_surface(EXPIRY_A).destroy_some(),
        SPOT,
        FORWARD_A,
        T_MID,
        LANDED_HIGH,
    );
    assert!(feed.normalized_surface(EXPIRY_B).is_none());

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
}

#[test]
fun invalid_update_for_new_expiry_does_not_create_live_row() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(T_EARLY);

    feed.update(
        bs_update(BS_SOURCE_ID, EXPIRY_A, T_LATE, SPOT, FORWARD_A),
        &clock,
        scenario.ctx(),
    );

    assert!(feed.normalized_surface(EXPIRY_A).is_none());
    assert!(feed.normalized_surface_at(EXPIRY_A, T_LATE).is_none());

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
}

#[test]
fun duplicate_future_and_zero_exact_inserts_are_no_ops() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.insert_at(bs_update(BS_SOURCE_ID, EXPIRY_A, T_EARLY, SPOT, FORWARD_A), &clock, scenario.ctx());
    feed.insert_at(
        bs_update(BS_SOURCE_ID, EXPIRY_A, T_EARLY, SPOT_LATER, FORWARD_A2),
        &clock,
        scenario.ctx(),
    );
    feed.insert_at(
        bs_update(BS_SOURCE_ID, EXPIRY_A, T_FUTURE, SPOT_LATER, FORWARD_A2),
        &clock,
        scenario.ctx(),
    );
    feed.insert_at(
        bs_update(BS_SOURCE_ID, EXPIRY_A, T_ZERO, SPOT_LATER, FORWARD_A2),
        &clock,
        scenario.ctx(),
    );

    assert_surface(
        &feed.normalized_surface_at(EXPIRY_A, T_EARLY).destroy_some(),
        SPOT,
        FORWARD_A,
        T_EARLY,
        LANDED_HIGH,
    );
    assert!(feed.normalized_surface_at(EXPIRY_A, T_FUTURE).is_none());
    assert!(feed.normalized_surface_at(EXPIRY_A, T_ZERO).is_none());
    assert!(feed.normalized_surface(EXPIRY_A).is_none());

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
}

#[test]
fun update_accepts_raw_surface_without_pricing_envelope_validation() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.update(
        update::new_update(
            BS_SOURCE_ID,
            EXPIRY_A,
            T_EARLY,
            0,
            0,
            SVI_A,
            SVI_B,
            0,
            FLOAT_SCALING + 1,
            RHO_NEG,
            FLOAT_SCALING + 2,
            M_NEG,
        ),
        &clock,
        scenario.ctx(),
    );

    let raw = feed.raw_surface(EXPIRY_A).read_value();
    assert_eq!(block_scholes_feed::raw_spot(&raw), 0);
    assert_eq!(block_scholes_feed::raw_forward(&raw), 0);
    assert!(feed.normalized_surface(EXPIRY_A).is_none());
    let svi = block_scholes_feed::raw_svi(&raw);
    assert_eq!(svi.sigma(), 0);
    assert_eq!(svi.rho().magnitude(), FLOAT_SCALING + 1);
    assert_eq!(svi.m().magnitude(), FLOAT_SCALING + 2);

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
}

#[test]
fun registry_records_bs_source_feed() {
    let (scenario, feed_obj_id) = setup_feed();
    let registry = scenario.take_shared<OracleRegistry>();

    assert!(registry.contains_block_scholes_source(BS_SOURCE_ID));
    assert_eq!(
        registry.propbook_block_scholes_id_for_source(BS_SOURCE_ID).destroy_some(),
        feed_obj_id,
    );

    return_shared(registry);
    scenario.end();
}

#[test]
fun pyth_and_bs_share_numeric_source_id_across_kinds() {
    let mut scenario = test::begin(ADMIN);
    registry::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);
    let mut registry = scenario.take_shared<OracleRegistry>();

    let bs_id = registry::create_and_share_block_scholes_feed(
        &mut registry,
        SHARED_SOURCE_ID,
        scenario.ctx(),
    );
    let pyth_id = registry::create_and_share_pyth_feed(
        &mut registry,
        SHARED_SOURCE_ID,
        scenario.ctx(),
    );

    assert!(bs_id != pyth_id);
    assert_eq!(
        registry.propbook_block_scholes_id_for_source(SHARED_SOURCE_ID).destroy_some(),
        bs_id,
    );
    assert_eq!(registry.propbook_pyth_id_for_source(SHARED_SOURCE_ID).destroy_some(), pyth_id);

    return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = registry::ESourceAlreadyExists)]
fun create_duplicate_source_aborts() {
    let (mut scenario, _feed_obj_id) = setup_feed();
    let mut registry = scenario.take_shared<OracleRegistry>();

    registry::create_and_share_block_scholes_feed(&mut registry, BS_SOURCE_ID, scenario.ctx());

    abort 999
}

#[test, expected_failure(abort_code = block_scholes_feed::EWrongSource)]
fun update_wrong_source_aborts() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.update(
        bs_update(OTHER_BS_SOURCE_ID, EXPIRY_A, T_EARLY, SPOT, FORWARD_A),
        &clock,
        scenario.ctx(),
    );

    abort 999
}

#[test, expected_failure(abort_code = block_scholes_feed::EWrongVersion)]
fun update_wrong_version_aborts() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.set_version_for_testing(VERSION_ZERO);
    feed.update(
        bs_update(BS_SOURCE_ID, EXPIRY_A, T_EARLY, SPOT, FORWARD_A),
        &clock,
        scenario.ctx(),
    );

    abort 999
}

#[test]
fun migrate_restores_current_version_and_updates_resume() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.set_version_for_testing(VERSION_ZERO);
    feed.migrate();
    assert_eq!(feed.version(), propbook::constants::current_version!());
    feed.update(
        bs_update(BS_SOURCE_ID, EXPIRY_A, T_EARLY, SPOT, FORWARD_A),
        &clock,
        scenario.ctx(),
    );
    assert_surface(
        &feed.normalized_surface(EXPIRY_A).destroy_some(),
        SPOT,
        FORWARD_A,
        T_EARLY,
        LANDED_HIGH,
    );

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
}

#[test, expected_failure(abort_code = block_scholes_feed::ENotNewerVersion)]
fun migrate_current_version_aborts() {
    let (scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);

    feed.migrate();

    abort 999
}

#[test, expected_failure(abort_code = block_scholes_feed::ERawSurfaceNotFound)]
fun raw_surface_on_unknown_expiry_aborts() {
    let (scenario, feed_obj_id) = setup_feed();
    let feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);

    feed.raw_surface(UNKNOWN_EXPIRY);

    abort 999
}

#[test, expected_failure(abort_code = block_scholes_feed::ERawSurfaceNotFound)]
fun raw_surface_at_unknown_timestamp_aborts() {
    let (mut scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<BlockScholesFeed>(feed_obj_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.insert_at(
        bs_update(BS_SOURCE_ID, EXPIRY_A, T_EARLY, SPOT, FORWARD_A),
        &clock,
        scenario.ctx(),
    );
    feed.raw_surface_at(EXPIRY_A, T_LATE);

    abort 999
}

fun assert_surface(
    read: &propbook::oracle_lane::OracleRead<block_scholes_feed::Surface>,
    expected_spot: u64,
    expected_forward: u64,
    expected_source_timestamp_ms: u64,
    expected_update_timestamp_ms: u64,
) {
    assert_eq!(read.read_source_timestamp_ms(), expected_source_timestamp_ms);
    assert_eq!(read.read_update_timestamp_ms(), expected_update_timestamp_ms);
    let surface = read.read_value();
    assert_eq!(block_scholes_feed::surface_spot(&surface), expected_spot);
    assert_eq!(block_scholes_feed::surface_forward(&surface), expected_forward);
    let svi = block_scholes_feed::surface_svi(&surface);
    assert_eq!(svi.a(), SVI_A);
    assert_eq!(svi.b(), SVI_B);
    assert_eq!(svi.sigma(), SVI_SIGMA);
    assert_eq!(svi.rho().magnitude(), RHO_MAG);
    assert_eq!(svi.rho().is_negative(), RHO_NEG);
    assert_eq!(svi.m().magnitude(), M_MAG);
    assert_eq!(svi.m().is_negative(), M_NEG);
}

fun bs_update(source_id: u32, expiry: u64, published: u64, spot: u64, forward: u64): Update {
    update::new_update(
        source_id,
        expiry,
        published,
        spot,
        forward,
        SVI_A,
        SVI_B,
        SVI_SIGMA,
        RHO_MAG,
        RHO_NEG,
        M_MAG,
        M_NEG,
    )
}

fun setup_feed(): (Scenario, ID) {
    let mut scenario = test::begin(ADMIN);
    registry::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);

    let mut registry = scenario.take_shared<OracleRegistry>();
    let feed_obj_id = registry::create_and_share_block_scholes_feed(
        &mut registry,
        BS_SOURCE_ID,
        scenario.ctx(),
    );
    return_shared(registry);
    scenario.next_tx(ADMIN);

    (scenario, feed_obj_id)
}
