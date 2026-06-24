// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module propbook::block_scholes_feed_tests;

use block_scholes_oracle::update::{Self, ForwardUpdate, SVIUpdate, SpotUpdate};
use propbook::{
    block_scholes_forward_feed::{Self as forward_feed, BlockScholesForwardFeed},
    block_scholes_spot_feed::{Self as spot_feed, BlockScholesSpotFeed},
    block_scholes_svi_feed::{Self as svi_feed, BlockScholesSVIFeed, SVIParams},
    registry::{Self, OracleRegistry, RegistryAdminCap}
};
use std::unit_test::assert_eq;
use sui::{clock, test_scenario::{Self as test, Scenario, return_shared}};

const ADMIN: address = @0xAD;
const BS_SOURCE_ID: u32 = 1;
const OTHER_BS_SOURCE_ID: u32 = 2;
const SHARED_SOURCE_ID: u32 = 7;
const UNDERLYING_ID: u32 = 42;

const SPOT: u64 = 50_000_000_000_000;
const SPOT_LATER: u64 = 49_000_000_000_000;
const FORWARD_A: u64 = 50_500_000_000_000;
const FORWARD_B: u64 = 51_500_000_000_000;
const EXPIRY_A: u64 = 1_700_100_000_000;
const EXPIRY_B: u64 = 1_700_200_000_000;
const UNKNOWN_TIMESTAMP: u64 = 9_999_999_999;
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
fun spot_update_records_raw_and_normalized_latest() {
    let (mut scenario, spot_id, _forward_id, _svi_id) = setup_feeds(BS_SOURCE_ID, EXPIRY_A);
    let mut feed = scenario.take_shared_by_id<BlockScholesSpotFeed>(spot_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_EARLY);

    feed.update(spot_update(BS_SOURCE_ID, T_EARLY, SPOT), &clock);

    assert_eq!(feed.bs_source_id(), BS_SOURCE_ID);
    assert_eq!(feed.version(), propbook::constants::current_version!());
    let raw_read = feed.raw_spot();
    assert_eq!(raw_read.read_source_timestamp_ms(), T_EARLY);
    assert_eq!(raw_read.read_update_timestamp_ms(), LANDED_EARLY);
    let raw = raw_read.read_value();
    assert_eq!(spot_feed::raw_bs_source_id(&raw), BS_SOURCE_ID);
    assert_eq!(spot_feed::raw_spot_value(&raw), SPOT);
    assert_price_read(&feed.normalized_spot().destroy_some(), SPOT, T_EARLY, LANDED_EARLY);
    assert!(feed.normalized_spot_at(T_EARLY).is_none());

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
}

#[test]
fun forward_update_records_raw_and_normalized_latest() {
    let (mut scenario, _spot_id, forward_id, _svi_id) = setup_feeds(BS_SOURCE_ID, EXPIRY_A);
    let mut feed = scenario.take_shared_by_id<BlockScholesForwardFeed>(forward_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_EARLY);

    feed.update(forward_update(BS_SOURCE_ID, EXPIRY_A, T_EARLY, FORWARD_A), &clock, scenario.ctx());

    assert_eq!(feed.bs_source_id(), BS_SOURCE_ID);
    assert_eq!(feed.version(), propbook::constants::current_version!());
    let raw_read = feed.raw_forward(EXPIRY_A);
    assert_eq!(raw_read.read_source_timestamp_ms(), T_EARLY);
    assert_eq!(raw_read.read_update_timestamp_ms(), LANDED_EARLY);
    let raw = raw_read.read_value();
    assert_eq!(forward_feed::raw_bs_source_id(&raw), BS_SOURCE_ID);
    assert_eq!(forward_feed::raw_expiry_ms(&raw), EXPIRY_A);
    assert_eq!(forward_feed::raw_forward_value(&raw), FORWARD_A);
    assert_price_read(
        &feed.normalized_forward(EXPIRY_A).destroy_some(),
        FORWARD_A,
        T_EARLY,
        LANDED_EARLY,
    );
    assert!(feed.normalized_forward_at(EXPIRY_A, T_EARLY).is_none());

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
}

#[test]
fun svi_update_records_raw_and_normalized_latest() {
    let (mut scenario, _spot_id, _forward_id, svi_id) = setup_feeds(BS_SOURCE_ID, EXPIRY_A);
    let mut feed = scenario.take_shared_by_id<BlockScholesSVIFeed>(svi_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_EARLY);

    feed.update(svi_update(BS_SOURCE_ID, EXPIRY_A, T_EARLY), &clock, scenario.ctx());

    assert_eq!(feed.bs_source_id(), BS_SOURCE_ID);
    assert_eq!(feed.version(), propbook::constants::current_version!());
    let raw_read = feed.raw_svi(EXPIRY_A);
    assert_eq!(raw_read.read_source_timestamp_ms(), T_EARLY);
    assert_eq!(raw_read.read_update_timestamp_ms(), LANDED_EARLY);
    let raw = raw_read.read_value();
    assert_eq!(svi_feed::raw_bs_source_id(&raw), BS_SOURCE_ID);
    assert_eq!(svi_feed::raw_expiry_ms(&raw), EXPIRY_A);
    assert_svi_params(&svi_feed::raw_svi_params(&raw));
    assert_svi_read(&feed.normalized_svi(EXPIRY_A).destroy_some(), T_EARLY, LANDED_EARLY);
    assert!(feed.normalized_svi_at(EXPIRY_A, T_EARLY).is_none());

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
}

#[test]
fun exact_inserts_do_not_mutate_latest_reads() {
    let (mut scenario, spot_id, forward_id, svi_id) = setup_feeds(BS_SOURCE_ID, EXPIRY_A);
    let mut spot = scenario.take_shared_by_id<BlockScholesSpotFeed>(spot_id);
    let mut forward = scenario.take_shared_by_id<BlockScholesForwardFeed>(forward_id);
    let mut svi = scenario.take_shared_by_id<BlockScholesSVIFeed>(svi_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    spot.insert_at(spot_update(BS_SOURCE_ID, T_EARLY, SPOT), &clock);
    forward.insert_at(
        forward_update(BS_SOURCE_ID, EXPIRY_A, T_EARLY, FORWARD_A),
        &clock,
        scenario.ctx(),
    );
    svi.insert_at(svi_update(BS_SOURCE_ID, EXPIRY_A, T_EARLY), &clock, scenario.ctx());

    assert!(spot.normalized_spot().is_none());
    assert!(forward.normalized_forward(EXPIRY_A).is_none());
    assert!(svi.normalized_svi(EXPIRY_A).is_none());
    assert_price_read(&spot.normalized_spot_at(T_EARLY).destroy_some(), SPOT, T_EARLY, LANDED_HIGH);
    assert_price_read(
        &forward.normalized_forward_at(EXPIRY_A, T_EARLY).destroy_some(),
        FORWARD_A,
        T_EARLY,
        LANDED_HIGH,
    );
    assert_svi_read(&svi.normalized_svi_at(EXPIRY_A, T_EARLY).destroy_some(), T_EARLY, LANDED_HIGH);
    assert!(spot.normalized_spot_at(T_LATE).is_none());
    assert!(forward.normalized_forward_at(EXPIRY_A, T_LATE).is_none());
    assert!(svi.normalized_svi_at(EXPIRY_A, T_LATE).is_none());

    clock.destroy_for_testing();
    return_shared(svi);
    return_shared(forward);
    return_shared(spot);
    scenario.end();
}

#[test]
fun stale_future_and_zero_spot_updates_are_no_ops() {
    let (mut scenario, spot_id, _forward_id, _svi_id) = setup_feeds(BS_SOURCE_ID, EXPIRY_A);
    let mut feed = scenario.take_shared_by_id<BlockScholesSpotFeed>(spot_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.update(spot_update(BS_SOURCE_ID, T_MID, SPOT), &clock);
    feed.update(spot_update(BS_SOURCE_ID, T_MID, SPOT_LATER), &clock);
    feed.update(spot_update(BS_SOURCE_ID, T_EARLY, SPOT_LATER), &clock);
    feed.update(spot_update(BS_SOURCE_ID, T_FUTURE, SPOT_LATER), &clock);
    feed.update(spot_update(BS_SOURCE_ID, T_ZERO, SPOT_LATER), &clock);

    assert_price_read(&feed.normalized_spot().destroy_some(), SPOT, T_MID, LANDED_HIGH);

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
}

#[test]
fun duplicate_future_and_zero_exact_spot_inserts_are_no_ops() {
    let (mut scenario, spot_id, _forward_id, _svi_id) = setup_feeds(BS_SOURCE_ID, EXPIRY_A);
    let mut feed = scenario.take_shared_by_id<BlockScholesSpotFeed>(spot_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.insert_at(spot_update(BS_SOURCE_ID, T_EARLY, SPOT), &clock);
    feed.insert_at(spot_update(BS_SOURCE_ID, T_EARLY, SPOT_LATER), &clock);
    feed.insert_at(spot_update(BS_SOURCE_ID, T_FUTURE, SPOT_LATER), &clock);
    feed.insert_at(spot_update(BS_SOURCE_ID, T_ZERO, SPOT_LATER), &clock);

    assert_price_read(&feed.normalized_spot_at(T_EARLY).destroy_some(), SPOT, T_EARLY, LANDED_HIGH);
    assert!(feed.normalized_spot_at(T_FUTURE).is_none());
    assert!(feed.normalized_spot_at(T_ZERO).is_none());
    assert!(feed.normalized_spot().is_none());

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
}

#[test]
fun updates_accept_raw_values_without_pricing_envelope_validation() {
    let (mut scenario, spot_id, forward_id, svi_id) = setup_feeds(BS_SOURCE_ID, EXPIRY_A);
    let mut spot = scenario.take_shared_by_id<BlockScholesSpotFeed>(spot_id);
    let mut forward = scenario.take_shared_by_id<BlockScholesForwardFeed>(forward_id);
    let mut svi = scenario.take_shared_by_id<BlockScholesSVIFeed>(svi_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    spot.update(spot_update(BS_SOURCE_ID, T_EARLY, 0), &clock);
    forward.update(
        forward_update(BS_SOURCE_ID, EXPIRY_A, T_EARLY, 0),
        &clock,
        scenario.ctx(),
    );
    svi.update(
        update::new_svi_update(
            BS_SOURCE_ID,
            EXPIRY_A,
            T_EARLY,
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

    assert_eq!(spot_feed::raw_spot_value(&spot.raw_spot().read_value()), 0);
    assert_eq!(forward_feed::raw_forward_value(&forward.raw_forward(EXPIRY_A).read_value()), 0);
    assert!(spot.normalized_spot().is_none());
    assert!(forward.normalized_forward(EXPIRY_A).is_none());
    let params = svi.normalized_svi(EXPIRY_A).destroy_some().read_value();
    assert_eq!(params.sigma(), 0);
    assert_eq!(params.rho().magnitude(), FLOAT_SCALING + 1);
    assert_eq!(params.m().magnitude(), FLOAT_SCALING + 2);

    clock.destroy_for_testing();
    return_shared(svi);
    return_shared(forward);
    return_shared(spot);
    scenario.end();
}

#[test]
fun registry_records_split_bs_source_feeds() {
    let (scenario, spot_id, forward_id, svi_id) = setup_feeds(BS_SOURCE_ID, EXPIRY_A);
    let registry = scenario.take_shared<OracleRegistry>();

    assert!(registry.contains_block_scholes_spot_source(BS_SOURCE_ID));
    assert!(registry.contains_block_scholes_forward_source(BS_SOURCE_ID));
    assert!(registry.contains_block_scholes_svi_source(BS_SOURCE_ID));
    assert_eq!(
        registry.propbook_block_scholes_spot_id_for_source(BS_SOURCE_ID).destroy_some(),
        spot_id,
    );
    assert_eq!(
        registry
            .propbook_block_scholes_forward_id_for_source(BS_SOURCE_ID)
            .destroy_some(),
        forward_id,
    );
    assert_eq!(
        registry.propbook_block_scholes_svi_id_for_source(BS_SOURCE_ID).destroy_some(),
        svi_id,
    );

    return_shared(registry);
    scenario.end();
}

#[test]
fun pyth_and_split_bs_share_numeric_source_id_across_kinds() {
    let mut scenario = test::begin(ADMIN);
    registry::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);
    let mut registry = scenario.take_shared<OracleRegistry>();

    let spot_id = registry::create_and_share_block_scholes_spot_feed(
        &mut registry,
        SHARED_SOURCE_ID,
        scenario.ctx(),
    );
    let forward_id = registry::create_and_share_block_scholes_forward_feed(
        &mut registry,
        SHARED_SOURCE_ID,
        scenario.ctx(),
    );
    let svi_id = registry::create_and_share_block_scholes_svi_feed(
        &mut registry,
        SHARED_SOURCE_ID,
        scenario.ctx(),
    );
    let pyth_id = registry::create_and_share_pyth_feed(
        &mut registry,
        SHARED_SOURCE_ID,
        scenario.ctx(),
    );

    assert!(spot_id != pyth_id);
    assert!(forward_id != pyth_id);
    assert!(svi_id != pyth_id);
    assert_eq!(
        registry.propbook_block_scholes_spot_id_for_source(SHARED_SOURCE_ID).destroy_some(),
        spot_id,
    );
    assert_eq!(
        registry
            .propbook_block_scholes_forward_id_for_source(SHARED_SOURCE_ID)
            .destroy_some(),
        forward_id,
    );
    assert_eq!(
        registry
            .propbook_block_scholes_svi_id_for_source(SHARED_SOURCE_ID)
            .destroy_some(),
        svi_id,
    );
    assert_eq!(registry.propbook_pyth_id_for_source(SHARED_SOURCE_ID).destroy_some(), pyth_id);

    return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = registry::ESourceAlreadyExists)]
fun create_duplicate_spot_source_aborts() {
    let (mut scenario, _spot_id, _forward_id, _svi_id) = setup_feeds(BS_SOURCE_ID, EXPIRY_A);
    let mut registry = scenario.take_shared<OracleRegistry>();

    registry::create_and_share_block_scholes_spot_feed(&mut registry, BS_SOURCE_ID, scenario.ctx());

    abort 999
}

#[test, expected_failure(abort_code = registry::EBlockScholesSpotNotBound)]
fun bind_surface_without_spot_binding_aborts() {
    let (scenario, _spot_id, forward_id, svi_id) = setup_feeds(BS_SOURCE_ID, EXPIRY_A);
    let admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    let mut registry = scenario.take_shared<OracleRegistry>();
    let forward = scenario.take_shared_by_id<BlockScholesForwardFeed>(forward_id);
    let svi = scenario.take_shared_by_id<BlockScholesSVIFeed>(svi_id);

    registry.bind_block_scholes_surface_to_underlying(&admin_cap, &forward, &svi, UNDERLYING_ID);

    abort 999
}

#[test, expected_failure(abort_code = registry::EWrongBlockScholesSource)]
fun bind_surface_with_different_spot_source_aborts() {
    let (mut scenario, spot_id, _forward_id, _svi_id) = setup_feeds(BS_SOURCE_ID, EXPIRY_A);
    let (other_forward_id, other_svi_id) = create_forward_and_svi(
        &mut scenario,
        OTHER_BS_SOURCE_ID,
        EXPIRY_A,
    );
    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    let mut registry = scenario.take_shared<OracleRegistry>();
    let spot = scenario.take_shared_by_id<BlockScholesSpotFeed>(spot_id);
    let forward = scenario.take_shared_by_id<BlockScholesForwardFeed>(other_forward_id);
    let svi = scenario.take_shared_by_id<BlockScholesSVIFeed>(other_svi_id);

    registry.bind_block_scholes_spot_to_underlying(&admin_cap, &spot, UNDERLYING_ID);
    registry.bind_block_scholes_surface_to_underlying(&admin_cap, &forward, &svi, UNDERLYING_ID);

    abort 999
}

#[test, expected_failure(abort_code = registry::EWrongBlockScholesSource)]
fun bind_surface_with_mismatched_forward_and_svi_sources_aborts() {
    let (mut scenario, spot_id, forward_id, _svi_id) = setup_feeds(BS_SOURCE_ID, EXPIRY_A);
    let mismatched_svi_id = registry_svi(&mut scenario, OTHER_BS_SOURCE_ID);
    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    let mut registry = scenario.take_shared<OracleRegistry>();
    let spot = scenario.take_shared_by_id<BlockScholesSpotFeed>(spot_id);
    let forward = scenario.take_shared_by_id<BlockScholesForwardFeed>(forward_id);
    let svi = scenario.take_shared_by_id<BlockScholesSVIFeed>(mismatched_svi_id);

    registry.bind_block_scholes_spot_to_underlying(&admin_cap, &spot, UNDERLYING_ID);
    registry.bind_block_scholes_surface_to_underlying(&admin_cap, &forward, &svi, UNDERLYING_ID);

    abort 999
}

#[test, expected_failure(abort_code = spot_feed::EWrongSource)]
fun spot_update_wrong_source_aborts() {
    let (mut scenario, spot_id, _forward_id, _svi_id) = setup_feeds(BS_SOURCE_ID, EXPIRY_A);
    let mut feed = scenario.take_shared_by_id<BlockScholesSpotFeed>(spot_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.update(spot_update(OTHER_BS_SOURCE_ID, T_EARLY, SPOT), &clock);

    abort 999
}

#[test]
fun forward_and_svi_updates_store_independent_expiry_rows() {
    let (mut scenario, _spot_id, forward_id, _svi_id) = setup_feeds(BS_SOURCE_ID, EXPIRY_A);
    let mut forward = scenario.take_shared_by_id<BlockScholesForwardFeed>(forward_id);
    let mut svi = scenario.take_shared_by_id<BlockScholesSVIFeed>(_svi_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    forward.update(
        forward_update(BS_SOURCE_ID, EXPIRY_A, T_EARLY, FORWARD_A),
        &clock,
        scenario.ctx(),
    );
    forward.update(
        forward_update(BS_SOURCE_ID, EXPIRY_B, T_LATE, FORWARD_B),
        &clock,
        scenario.ctx(),
    );
    svi.update(svi_update(BS_SOURCE_ID, EXPIRY_A, T_EARLY), &clock, scenario.ctx());
    svi.update(svi_update(BS_SOURCE_ID, EXPIRY_B, T_LATE), &clock, scenario.ctx());

    assert_price_read(
        &forward.normalized_forward(EXPIRY_A).destroy_some(),
        FORWARD_A,
        T_EARLY,
        LANDED_HIGH,
    );
    assert_price_read(
        &forward.normalized_forward(EXPIRY_B).destroy_some(),
        FORWARD_B,
        T_LATE,
        LANDED_HIGH,
    );
    assert_svi_read(&svi.normalized_svi(EXPIRY_A).destroy_some(), T_EARLY, LANDED_HIGH);
    assert_svi_read(&svi.normalized_svi(EXPIRY_B).destroy_some(), T_LATE, LANDED_HIGH);

    clock.destroy_for_testing();
    return_shared(svi);
    return_shared(forward);
    scenario.end();
}

#[test, expected_failure(abort_code = svi_feed::EWrongSource)]
fun svi_update_wrong_source_aborts() {
    let (mut scenario, _spot_id, _forward_id, svi_id) = setup_feeds(BS_SOURCE_ID, EXPIRY_A);
    let mut feed = scenario.take_shared_by_id<BlockScholesSVIFeed>(svi_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.update(svi_update(OTHER_BS_SOURCE_ID, EXPIRY_A, T_EARLY), &clock, scenario.ctx());

    abort 999
}

#[test, expected_failure(abort_code = spot_feed::EWrongVersion)]
fun spot_update_wrong_version_aborts() {
    let (mut scenario, spot_id, _forward_id, _svi_id) = setup_feeds(BS_SOURCE_ID, EXPIRY_A);
    let mut feed = scenario.take_shared_by_id<BlockScholesSpotFeed>(spot_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.set_version_for_testing(VERSION_ZERO);
    feed.update(spot_update(BS_SOURCE_ID, T_EARLY, SPOT), &clock);

    abort 999
}

#[test]
fun migrate_restores_current_version_and_updates_resume() {
    let (mut scenario, spot_id, _forward_id, _svi_id) = setup_feeds(BS_SOURCE_ID, EXPIRY_A);
    let mut feed = scenario.take_shared_by_id<BlockScholesSpotFeed>(spot_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.set_version_for_testing(VERSION_ZERO);
    feed.migrate();
    assert_eq!(feed.version(), propbook::constants::current_version!());
    feed.update(spot_update(BS_SOURCE_ID, T_EARLY, SPOT), &clock);
    assert_price_read(&feed.normalized_spot().destroy_some(), SPOT, T_EARLY, LANDED_HIGH);

    clock.destroy_for_testing();
    return_shared(feed);
    scenario.end();
}

#[test, expected_failure(abort_code = spot_feed::ENotNewerVersion)]
fun migrate_current_version_aborts() {
    let (scenario, spot_id, _forward_id, _svi_id) = setup_feeds(BS_SOURCE_ID, EXPIRY_A);
    let mut feed = scenario.take_shared_by_id<BlockScholesSpotFeed>(spot_id);

    feed.migrate();

    abort 999
}

#[test, expected_failure(abort_code = spot_feed::ERawSpotNotFound)]
fun raw_spot_without_update_aborts() {
    let (scenario, spot_id, _forward_id, _svi_id) = setup_feeds(BS_SOURCE_ID, EXPIRY_A);
    let feed = scenario.take_shared_by_id<BlockScholesSpotFeed>(spot_id);

    feed.raw_spot();

    abort 999
}

#[test, expected_failure(abort_code = forward_feed::ERawForwardNotFound)]
fun raw_forward_at_unknown_timestamp_aborts() {
    let (mut scenario, _spot_id, forward_id, _svi_id) = setup_feeds(BS_SOURCE_ID, EXPIRY_A);
    let mut feed = scenario.take_shared_by_id<BlockScholesForwardFeed>(forward_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(LANDED_HIGH);

    feed.insert_at(
        forward_update(BS_SOURCE_ID, EXPIRY_A, T_EARLY, FORWARD_A),
        &clock,
        scenario.ctx(),
    );
    feed.raw_forward_at(EXPIRY_A, UNKNOWN_TIMESTAMP);

    abort 999
}

fun assert_price_read(
    read: &propbook::oracle_lane::OracleRead<u64>,
    expected_value: u64,
    expected_source_timestamp_ms: u64,
    expected_update_timestamp_ms: u64,
) {
    assert_eq!(read.read_source_timestamp_ms(), expected_source_timestamp_ms);
    assert_eq!(read.read_update_timestamp_ms(), expected_update_timestamp_ms);
    assert_eq!(read.read_value(), expected_value);
}

fun assert_svi_read(
    read: &propbook::oracle_lane::OracleRead<SVIParams>,
    expected_source_timestamp_ms: u64,
    expected_update_timestamp_ms: u64,
) {
    assert_eq!(read.read_source_timestamp_ms(), expected_source_timestamp_ms);
    assert_eq!(read.read_update_timestamp_ms(), expected_update_timestamp_ms);
    assert_svi_params(&read.read_value());
}

fun assert_svi_params(params: &SVIParams) {
    assert_eq!(params.a(), SVI_A);
    assert_eq!(params.b(), SVI_B);
    assert_eq!(params.sigma(), SVI_SIGMA);
    assert_eq!(params.rho().magnitude(), RHO_MAG);
    assert_eq!(params.rho().is_negative(), RHO_NEG);
    assert_eq!(params.m().magnitude(), M_MAG);
    assert_eq!(params.m().is_negative(), M_NEG);
}

fun spot_update(source_id: u32, published: u64, spot: u64): SpotUpdate {
    update::new_spot_update(source_id, published, spot)
}

fun forward_update(source_id: u32, expiry: u64, published: u64, forward: u64): ForwardUpdate {
    update::new_forward_update(source_id, expiry, published, forward)
}

fun svi_update(source_id: u32, expiry: u64, published: u64): SVIUpdate {
    update::new_svi_update(
        source_id,
        expiry,
        published,
        SVI_A,
        SVI_B,
        SVI_SIGMA,
        RHO_MAG,
        RHO_NEG,
        M_MAG,
        M_NEG,
    )
}

fun setup_feeds(source_id: u32, _expiry: u64): (Scenario, ID, ID, ID) {
    let mut scenario = test::begin(ADMIN);
    registry::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);

    let mut registry = scenario.take_shared<OracleRegistry>();
    let spot_id = registry::create_and_share_block_scholes_spot_feed(
        &mut registry,
        source_id,
        scenario.ctx(),
    );
    let forward_id = registry::create_and_share_block_scholes_forward_feed(
        &mut registry,
        source_id,
        scenario.ctx(),
    );
    let svi_id = registry::create_and_share_block_scholes_svi_feed(
        &mut registry,
        source_id,
        scenario.ctx(),
    );
    return_shared(registry);
    scenario.next_tx(ADMIN);

    (scenario, spot_id, forward_id, svi_id)
}

fun create_forward_and_svi(
    scenario: &mut Scenario,
    source_id: u32,
    _expiry: u64,
): (ID, ID) {
    let mut registry = scenario.take_shared<OracleRegistry>();
    let forward_id = registry::create_and_share_block_scholes_forward_feed(
        &mut registry,
        source_id,
        scenario.ctx(),
    );
    let svi_id = registry::create_and_share_block_scholes_svi_feed(
        &mut registry,
        source_id,
        scenario.ctx(),
    );
    return_shared(registry);
    (forward_id, svi_id)
}

fun registry_svi(scenario: &mut Scenario, source_id: u32): ID {
    let mut registry = scenario.take_shared<OracleRegistry>();
    let id = registry::create_and_share_block_scholes_svi_feed(
        &mut registry,
        source_id,
        scenario.ctx(),
    );
    return_shared(registry);
    id
}
