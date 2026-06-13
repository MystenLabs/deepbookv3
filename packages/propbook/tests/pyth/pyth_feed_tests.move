// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module propbook::pyth_feed_tests;

use propbook::{constants, pyth_feed::{Self, PythFeed}, registry::{Self, OracleRegistry}};
use std::unit_test::assert_eq;
use sui::test_scenario::{Self as test, Scenario, return_shared};

const ADMIN: address = @0xAD;
const BTC_FEED_ID: u32 = 1;
const UNKNOWN_FEED_ID: u32 = 999;
const SPOT_65K: u64 = 65_000_000_000_000;

// === Registry / permissionless creation tests ===

#[test]
fun registry_records_created_feed() {
    let (scenario, feed_obj_id) = setup_feed();
    let registry = scenario.take_shared<OracleRegistry>();

    assert!(registry.contains_feed(registry::kind_pyth!(), BTC_FEED_ID));
    assert!(!registry.contains_feed(registry::kind_pyth!(), UNKNOWN_FEED_ID));
    assert_eq!(
        registry.feed_object_id(registry::kind_pyth!(), BTC_FEED_ID).destroy_some(),
        feed_obj_id,
    );
    assert!(registry.feed_object_id(registry::kind_pyth!(), UNKNOWN_FEED_ID).is_none());

    return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = registry::EFeedAlreadyExists)]
fun create_duplicate_feed_id_aborts() {
    let (mut scenario, _feed_obj_id) = setup_feed();
    let mut registry = scenario.take_shared<OracleRegistry>();

    // A second feed with the same feed_id reverts.
    pyth_feed::create_and_share(&mut registry, BTC_FEED_ID, scenario.ctx());

    abort 999
}

// === Integration: a tick flows into the embedded core ===

#[test]
fun store_tick_flows_into_embedded_core() {
    let (scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<PythFeed>(feed_obj_id);

    // Tick published at minute 7 + 0.123s; lands on-chain 50ms later.
    let source_ts = 7 * constants::minute_ms!() + 123;
    let update_ts = source_ts + 50;
    feed.store_tick_for_testing(SPOT_65K, source_ts, update_ts);

    assert_eq!(feed.feed_id(), BTC_FEED_ID);
    assert_eq!(feed.spot(), SPOT_65K);
    assert_eq!(feed.source_timestamp_ms(), source_ts);
    assert_eq!(feed.update_timestamp_ms(), update_ts);
    assert_eq!(feed.freshness_timestamp_ms(), source_ts);
    assert_eq!(feed.version(), constants::current_version!());

    assert!(feed.has_minute(7 * constants::minute_ms!()));
    let point = feed.price_at_minute(7 * constants::minute_ms!());
    assert_eq!(point.spot(), SPOT_65K);
    assert_eq!(point.source_timestamp_ms(), source_ts);
    assert_eq!(point.update_timestamp_ms(), update_ts);

    return_shared(feed);
    scenario.end();
}

#[test, expected_failure(abort_code = pyth_feed::EStaleSourceUpdate)]
fun store_tick_stale_source_aborts() {
    let (scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<PythFeed>(feed_obj_id);

    // Pyth keeps strict abort-on-stale: a non-advancing source ts reverts.
    feed.store_tick_for_testing(SPOT_65K, 5_000, 5_000);
    feed.store_tick_for_testing(SPOT_65K, 5_000, 9_000);

    abort 999
}

/// Initialize the package (shares the registry), create+share a feed, and advance
/// so the shared feed is takeable. Returns the scenario and the feed object ID.
fun setup_feed(): (Scenario, ID) {
    let mut scenario = test::begin(ADMIN);
    registry::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);

    let mut registry = scenario.take_shared<OracleRegistry>();
    let feed_obj_id = pyth_feed::create_and_share(&mut registry, BTC_FEED_ID, scenario.ctx());
    return_shared(registry);
    scenario.next_tx(ADMIN);

    (scenario, feed_obj_id)
}
