// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module propbook::pyth_feed_tests;

use propbook::{
    constants,
    oracle_lane,
    pyth_feed::{Self, PythFeed},
    registry::{Self, OracleRegistry}
};
use std::unit_test::assert_eq;
use sui::test_scenario::{Self as test, Scenario, return_shared};

const ADMIN: address = @0xAD;
const BTC_SOURCE_ID: u32 = 1;
const UNKNOWN_SOURCE_ID: u32 = 999;
const SPOT_65K: u64 = 65_000_000_000_000;
const EXPONENT_NEG_9: u16 = 9;
const SOURCE_TS_US_NON_EXACT_MS: u64 = 1_001;
const SOURCE_TS_MS_CEIL: u64 = 2;
const VERSION_ZERO: u64 = 0;

// === Registry / permissionless creation tests ===

#[test]
fun registry_records_created_pyth_source() {
    let (scenario, feed_obj_id) = setup_feed();
    let registry = scenario.take_shared<OracleRegistry>();

    assert!(registry.contains_pyth_source(BTC_SOURCE_ID));
    assert!(!registry.contains_pyth_source(UNKNOWN_SOURCE_ID));
    assert_eq!(registry.propbook_pyth_id_for_source(BTC_SOURCE_ID).destroy_some(), feed_obj_id);
    assert!(registry.propbook_pyth_id_for_source(UNKNOWN_SOURCE_ID).is_none());

    return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = registry::ESourceAlreadyExists)]
fun create_duplicate_pyth_source_aborts() {
    let (mut scenario, _feed_obj_id) = setup_feed();
    let mut registry = scenario.take_shared<OracleRegistry>();

    registry::create_and_share_pyth_feed(&mut registry, BTC_SOURCE_ID, scenario.ctx());

    abort 999
}

// === Integration: a source observation flows into the generic lane ===

#[test]
fun empty_feed_has_no_latest_and_zero_freshness() {
    let (scenario, feed_obj_id) = setup_feed();
    let feed = scenario.take_shared_by_id<PythFeed>(feed_obj_id);

    assert!(!feed.has_latest());
    assert_eq!(feed.freshness_timestamp_ms(), 0);

    return_shared(feed);
    scenario.end();
}

#[test, expected_failure(abort_code = pyth_feed::ENoLatest)]
fun latest_observation_on_empty_feed_aborts() {
    let (scenario, feed_obj_id) = setup_feed();
    let feed = scenario.take_shared_by_id<PythFeed>(feed_obj_id);

    feed.latest_observation();

    abort 999
}

#[test, expected_failure(abort_code = pyth_feed::ENoLatest)]
fun spot_on_empty_feed_aborts() {
    let (scenario, feed_obj_id) = setup_feed();
    let feed = scenario.take_shared_by_id<PythFeed>(feed_obj_id);

    feed.spot();

    abort 999
}

#[test]
fun store_observation_flows_into_lane() {
    let (scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<PythFeed>(feed_obj_id);

    let source_ts = 7 * constants::minute_ms!() + 123;
    let update_ts = source_ts + 50;
    assert!(!feed.has_latest());
    store_spot(&mut feed, SPOT_65K, source_ts, update_ts);

    assert!(feed.has_latest());
    assert_eq!(feed.pyth_source_id(), BTC_SOURCE_ID);
    assert_eq!(feed.spot(), SPOT_65K);
    assert_eq!(feed.source_timestamp_us(), source_ts * 1000);
    assert_eq!(feed.source_timestamp_ms(), source_ts);
    assert_eq!(feed.update_timestamp_ms(), update_ts);
    assert_eq!(feed.freshness_timestamp_ms(), source_ts);
    assert_eq!(feed.version(), constants::current_version!());

    assert!(feed.has_observation(7 * constants::minute_ms!()));
    let observation = feed.observation_at_minute(7 * constants::minute_ms!());
    assert_eq!(pyth_feed::normalized_spot_1e9(&observation), SPOT_65K);
    assert_eq!(pyth_feed::observation_source_timestamp_us(&observation), source_ts * 1000);
    assert_eq!(pyth_feed::observation_source_timestamp_ms(&observation), source_ts);
    assert_eq!(pyth_feed::observation_update_timestamp_ms(&observation), update_ts);

    return_shared(feed);
    scenario.end();
}

#[test]
fun official_settlement_for_testing_ceil_rounds_source_us_without_latest() {
    let (scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<PythFeed>(feed_obj_id);

    feed.record_official_settlement_for_testing(
        SPOT_65K,
        false,
        EXPONENT_NEG_9,
        true,
        SOURCE_TS_US_NON_EXACT_MS,
        SOURCE_TS_MS_CEIL,
    );

    assert!(!feed.has_latest());
    assert!(feed.has_official_settlement(SOURCE_TS_MS_CEIL));
    assert!(!feed.has_official_settlement(SOURCE_TS_MS_CEIL - 1));
    let settlement = feed.official_observation_at_resolution(SOURCE_TS_MS_CEIL);
    assert_eq!(pyth_feed::observation_source_timestamp_us(&settlement), SOURCE_TS_US_NON_EXACT_MS);
    assert_eq!(pyth_feed::observation_source_timestamp_ms(&settlement), SOURCE_TS_MS_CEIL);
    assert_eq!(pyth_feed::normalized_spot_1e9(&settlement), SPOT_65K);

    return_shared(feed);
    scenario.end();
}

#[test, expected_failure(abort_code = oracle_lane::EStaleSourceUpdate)]
fun store_observation_stale_source_aborts() {
    let (scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<PythFeed>(feed_obj_id);

    store_spot(&mut feed, SPOT_65K, 5_000, 5_000);
    store_spot(&mut feed, SPOT_65K, 5_000, 9_000);

    abort 999
}

#[test, expected_failure(abort_code = pyth_feed::EWrongVersion)]
fun store_observation_wrong_version_aborts() {
    let (scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<PythFeed>(feed_obj_id);

    feed.set_version_for_testing(VERSION_ZERO);
    store_spot(&mut feed, SPOT_65K, 5_000, 5_000);

    abort 999
}

#[test]
fun migrate_restores_current_version_and_updates_resume() {
    let (scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<PythFeed>(feed_obj_id);

    feed.set_version_for_testing(VERSION_ZERO);
    feed.migrate();
    assert_eq!(feed.version(), constants::current_version!());
    store_spot(&mut feed, SPOT_65K, 5_000, 5_000);
    assert_eq!(feed.spot(), SPOT_65K);

    return_shared(feed);
    scenario.end();
}

#[test, expected_failure(abort_code = pyth_feed::ENotNewerVersion)]
fun migrate_current_version_aborts() {
    let (scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<PythFeed>(feed_obj_id);

    feed.migrate();

    abort 999
}

fun store_spot(feed: &mut PythFeed, spot: u64, source_timestamp_ms: u64, update_timestamp_ms: u64) {
    feed.store_observation_for_testing(
        spot,
        false,
        EXPONENT_NEG_9,
        true,
        source_timestamp_ms * 1000,
        update_timestamp_ms,
    );
}

/// Initialize the package, create+share a feed through the registry, and advance
/// so the shared feed is takeable. Returns the scenario and the feed object ID.
fun setup_feed(): (Scenario, ID) {
    let mut scenario = test::begin(ADMIN);
    registry::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);

    let mut registry = scenario.take_shared<OracleRegistry>();
    let feed_obj_id = registry::create_and_share_pyth_feed(
        &mut registry,
        BTC_SOURCE_ID,
        scenario.ctx(),
    );
    return_shared(registry);
    scenario.next_tx(ADMIN);

    (scenario, feed_obj_id)
}
