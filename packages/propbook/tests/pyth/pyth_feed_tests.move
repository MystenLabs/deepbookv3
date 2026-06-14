// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module propbook::pyth_feed_tests;

use propbook::{
    constants,
    pyth_feed::{Self, PythFeed},
    registry::{Self, OracleRegistry}
};
use std::unit_test::assert_eq;
use sui::test_scenario::{Self as test, Scenario, return_shared};

const ADMIN: address = @0xAD;
const BTC_SOURCE_ID: u32 = 1;
const UNKNOWN_SOURCE_ID: u32 = 999;
const SPOT_65K: u64 = 65_000_000_000_000;
const BTC_PYTH_MAGNITUDE: u64 = 6_500_012_345_678;
const BTC_NORMALIZED_SPOT: u64 = 65_000_123_456_780;
const IDENTITY_MAGNITUDE: u64 = 123_456_789;
const DIVIDE_MAGNITUDE: u64 = 12_345_678_901;
const DIVIDE_NORMALIZED_SPOT: u64 = 12_345_678;
const SUB_UNIT_MAGNITUDE: u64 = 5;
const ZERO_MAGNITUDE: u64 = 0;
const ONE_MAGNITUDE: u64 = 1;
const THREE_MAGNITUDE: u64 = 3;
const ONE_1E9_SPOT: u64 = 1_000_000_000;
const THREE_E11_SPOT: u64 = 300_000_000_000;
const EXPONENT_NEG_8: u16 = 8;
const EXPONENT_NEG_9: u16 = 9;
const EXPONENT_NEG_12: u16 = 12;
const EXPONENT_ZERO: u16 = 0;
const EXPONENT_POS_2: u16 = 2;
const EXPONENT_UNSAFE_POS: u16 = 19;
const SOURCE_TS_ZERO_US: u64 = 0;
const SOURCE_TS_ZERO_MS: u64 = 0;
const SOURCE_TS_1_US: u64 = 1_000;
const SOURCE_TS_1_MS: u64 = 1;
const SOURCE_TS_NON_EXACT_US: u64 = 1_001;
const SOURCE_TS_NON_EXACT_MS: u64 = 2;
const SOURCE_TS_2_US: u64 = 2_000;
const SOURCE_TS_2_MS: u64 = 2;
const SOURCE_TS_3_US: u64 = 3_000;
const SOURCE_TS_3_MS: u64 = 3;
const SOURCE_TS_4_US: u64 = 4_000;
const SOURCE_TS_4_MS: u64 = 4;
const SOURCE_TS_5_US: u64 = 5_000;
const SOURCE_TS_5_MS: u64 = 5;
const SOURCE_TS_FUTURE_US: u64 = 100_000;
const SOURCE_TS_FUTURE_MS: u64 = 100;
const UPDATE_1_MS: u64 = 10;
const UPDATE_2_MS: u64 = 20;
const UPDATE_3_MS: u64 = 30;
const UPDATE_4_MS: u64 = 40;
const UPDATE_5_MS: u64 = 50;
const VERSION_ZERO: u64 = 0;

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

#[test]
fun empty_feed_normalized_spot_is_none() {
    let (scenario, feed_obj_id) = setup_feed();
    let feed = scenario.take_shared_by_id<PythFeed>(feed_obj_id);

    assert!(feed.normalized_spot().is_none());
    assert!(feed.normalized_spot_at(SOURCE_TS_1_MS).is_none());

    return_shared(feed);
    scenario.end();
}

#[test, expected_failure(abort_code = pyth_feed::ERawSpotNotFound)]
fun raw_spot_on_empty_feed_aborts() {
    let (scenario, feed_obj_id) = setup_feed();
    let feed = scenario.take_shared_by_id<PythFeed>(feed_obj_id);

    feed.raw_spot();

    abort 999
}

#[test]
fun update_flows_into_raw_and_normalized_latest_getters() {
    let (scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<PythFeed>(feed_obj_id);

    store_raw(
        &mut feed,
        SPOT_65K,
        false,
        EXPONENT_NEG_9,
        true,
        SOURCE_TS_1_US,
        UPDATE_1_MS,
    );

    assert_eq!(feed.pyth_source_id(), BTC_SOURCE_ID);
    assert_eq!(feed.version(), constants::current_version!());

    let raw_read = feed.raw_spot();
    assert_eq!(raw_read.read_source_timestamp_ms(), SOURCE_TS_1_MS);
    assert_eq!(raw_read.read_update_timestamp_ms(), UPDATE_1_MS);
    let raw = raw_read.read_value();
    assert_eq!(pyth_feed::raw_pyth_source_id(&raw), BTC_SOURCE_ID);
    assert_eq!(pyth_feed::raw_price_magnitude(&raw), SPOT_65K);
    assert!(!pyth_feed::raw_price_is_negative(&raw));
    assert_eq!(pyth_feed::raw_exponent_magnitude(&raw), EXPONENT_NEG_9);
    assert!(pyth_feed::raw_exponent_is_negative(&raw));
    assert_eq!(pyth_feed::raw_source_timestamp_us(&raw), SOURCE_TS_1_US);

    assert_latest_normalized(&feed, SPOT_65K, SOURCE_TS_1_MS, UPDATE_1_MS);
    assert!(feed.normalized_spot_at(SOURCE_TS_1_MS).is_none());

    return_shared(feed);
    scenario.end();
}

#[test]
fun normalized_spot_scales_every_exponent_branch_through_feed_getter() {
    let (scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<PythFeed>(feed_obj_id);

    // BTC-style: 65_000.12345678 USD as (6_500_012_345_678, -8).
    // Target shift = 9 - 8 = 1, so normalized = magnitude * 10.
    store_raw(
        &mut feed,
        BTC_PYTH_MAGNITUDE,
        false,
        EXPONENT_NEG_8,
        true,
        SOURCE_TS_1_US,
        UPDATE_1_MS,
    );
    assert_latest_normalized(&feed, BTC_NORMALIZED_SPOT, SOURCE_TS_1_MS, UPDATE_1_MS);

    // Exponent = -9: target shift is zero, so magnitude passes through.
    store_raw(
        &mut feed,
        IDENTITY_MAGNITUDE,
        false,
        EXPONENT_NEG_9,
        true,
        SOURCE_TS_2_US,
        UPDATE_2_MS,
    );
    assert_latest_normalized(&feed, IDENTITY_MAGNITUDE, SOURCE_TS_2_MS, UPDATE_2_MS);

    // Exponent = -12: target shift = -3, so integer division floors.
    store_raw(
        &mut feed,
        DIVIDE_MAGNITUDE,
        false,
        EXPONENT_NEG_12,
        true,
        SOURCE_TS_3_US,
        UPDATE_3_MS,
    );
    assert_latest_normalized(&feed, DIVIDE_NORMALIZED_SPOT, SOURCE_TS_3_MS, UPDATE_3_MS);

    // Exponent = 0: target shift = 9, so 1 becomes 1e9.
    store_raw(
        &mut feed,
        ONE_MAGNITUDE,
        false,
        EXPONENT_ZERO,
        false,
        SOURCE_TS_4_US,
        UPDATE_4_MS,
    );
    assert_latest_normalized(&feed, ONE_1E9_SPOT, SOURCE_TS_4_MS, UPDATE_4_MS);

    // Exponent = +2: target shift = 11, so 3 becomes 300e9.
    store_raw(
        &mut feed,
        THREE_MAGNITUDE,
        false,
        EXPONENT_POS_2,
        false,
        SOURCE_TS_5_US,
        UPDATE_5_MS,
    );
    assert_latest_normalized(&feed, THREE_E11_SPOT, SOURCE_TS_5_MS, UPDATE_5_MS);

    return_shared(feed);
    scenario.end();
}

#[test]
fun normalized_spot_returns_none_for_non_positive_or_unsafe_shapes() {
    let (scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<PythFeed>(feed_obj_id);

    store_raw(
        &mut feed,
        SUB_UNIT_MAGNITUDE,
        false,
        EXPONENT_NEG_12,
        true,
        SOURCE_TS_1_US,
        UPDATE_1_MS,
    );
    assert!(feed.normalized_spot().is_none());

    store_raw(
        &mut feed,
        ZERO_MAGNITUDE,
        false,
        EXPONENT_NEG_8,
        true,
        SOURCE_TS_2_US,
        UPDATE_2_MS,
    );
    assert!(feed.normalized_spot().is_none());

    store_raw(
        &mut feed,
        ONE_MAGNITUDE,
        true,
        EXPONENT_ZERO,
        false,
        SOURCE_TS_3_US,
        UPDATE_3_MS,
    );
    assert!(feed.normalized_spot().is_none());

    store_raw(
        &mut feed,
        ONE_MAGNITUDE,
        false,
        EXPONENT_UNSAFE_POS,
        false,
        SOURCE_TS_4_US,
        UPDATE_4_MS,
    );
    assert!(feed.normalized_spot().is_none());

    store_raw(
        &mut feed,
        std::u64::max_value!(),
        false,
        EXPONENT_NEG_8,
        true,
        SOURCE_TS_5_US,
        UPDATE_5_MS,
    );
    assert!(feed.normalized_spot().is_none());

    return_shared(feed);
    scenario.end();
}

#[test]
fun update_ceil_rounds_non_exact_source_us_without_exact_insert() {
    let (scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<PythFeed>(feed_obj_id);

    store_raw(
        &mut feed,
        SPOT_65K,
        false,
        EXPONENT_NEG_9,
        true,
        SOURCE_TS_NON_EXACT_US,
        UPDATE_1_MS,
    );

    assert_latest_normalized(&feed, SPOT_65K, SOURCE_TS_NON_EXACT_MS, UPDATE_1_MS);
    assert!(feed.normalized_spot_at(SOURCE_TS_NON_EXACT_MS - 1).is_none());
    assert!(feed.normalized_spot_at(SOURCE_TS_NON_EXACT_MS).is_none());

    return_shared(feed);
    scenario.end();
}

#[test]
fun insert_at_records_exact_read_without_latest() {
    let (scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<PythFeed>(feed_obj_id);

    insert_raw(
        &mut feed,
        SPOT_65K,
        false,
        EXPONENT_NEG_9,
        true,
        SOURCE_TS_1_US,
        UPDATE_1_MS,
    );

    assert!(feed.normalized_spot().is_none());
    assert!(feed.normalized_spot_at(SOURCE_TS_2_MS).is_none());

    let raw_read = feed.raw_spot_at(SOURCE_TS_1_MS);
    assert_eq!(raw_read.read_source_timestamp_ms(), SOURCE_TS_1_MS);
    assert_eq!(raw_read.read_update_timestamp_ms(), UPDATE_1_MS);
    let raw = raw_read.read_value();
    assert_eq!(pyth_feed::raw_source_timestamp_us(&raw), SOURCE_TS_1_US);
    assert_eq!(pyth_feed::raw_price_magnitude(&raw), SPOT_65K);

    let normalized = feed.normalized_spot_at(SOURCE_TS_1_MS).destroy_some();
    assert_eq!(normalized.read_source_timestamp_ms(), SOURCE_TS_1_MS);
    assert_eq!(normalized.read_update_timestamp_ms(), UPDATE_1_MS);
    assert_eq!(normalized.read_value(), SPOT_65K);

    return_shared(feed);
    scenario.end();
}

#[test, expected_failure(abort_code = pyth_feed::EInsertTimestampNotExactMillisecond)]
fun insert_at_non_exact_source_us_aborts() {
    let (scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<PythFeed>(feed_obj_id);

    insert_raw(
        &mut feed,
        SPOT_65K,
        false,
        EXPONENT_NEG_9,
        true,
        SOURCE_TS_NON_EXACT_US,
        UPDATE_1_MS,
    );

    abort 999
}

#[test]
fun stale_future_and_zero_updates_are_no_ops() {
    let (scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<PythFeed>(feed_obj_id);

    store_raw(&mut feed, SPOT_65K, false, EXPONENT_NEG_9, true, SOURCE_TS_3_US, UPDATE_3_MS);
    store_raw(&mut feed, ONE_MAGNITUDE, false, EXPONENT_ZERO, false, SOURCE_TS_3_US, UPDATE_5_MS);
    store_raw(&mut feed, ONE_MAGNITUDE, false, EXPONENT_ZERO, false, SOURCE_TS_2_US, UPDATE_5_MS);
    store_raw(
        &mut feed,
        ONE_MAGNITUDE,
        false,
        EXPONENT_ZERO,
        false,
        SOURCE_TS_FUTURE_US,
        UPDATE_5_MS,
    );
    store_raw(
        &mut feed,
        ONE_MAGNITUDE,
        false,
        EXPONENT_ZERO,
        false,
        SOURCE_TS_ZERO_US,
        UPDATE_5_MS,
    );

    assert_latest_normalized(&feed, SPOT_65K, SOURCE_TS_3_MS, UPDATE_3_MS);

    return_shared(feed);
    scenario.end();
}

#[test]
fun duplicate_future_and_zero_exact_inserts_are_no_ops() {
    let (scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<PythFeed>(feed_obj_id);

    insert_raw(&mut feed, SPOT_65K, false, EXPONENT_NEG_9, true, SOURCE_TS_1_US, UPDATE_1_MS);
    insert_raw(&mut feed, ONE_MAGNITUDE, false, EXPONENT_ZERO, false, SOURCE_TS_1_US, UPDATE_5_MS);
    insert_raw(
        &mut feed,
        ONE_MAGNITUDE,
        false,
        EXPONENT_ZERO,
        false,
        SOURCE_TS_FUTURE_US,
        UPDATE_5_MS,
    );
    insert_raw(
        &mut feed,
        ONE_MAGNITUDE,
        false,
        EXPONENT_ZERO,
        false,
        SOURCE_TS_ZERO_US,
        UPDATE_5_MS,
    );

    let exact = feed.normalized_spot_at(SOURCE_TS_1_MS).destroy_some();
    assert_eq!(exact.read_value(), SPOT_65K);
    assert_eq!(exact.read_update_timestamp_ms(), UPDATE_1_MS);
    assert!(feed.normalized_spot_at(SOURCE_TS_FUTURE_MS).is_none());
    assert!(feed.normalized_spot_at(SOURCE_TS_ZERO_MS).is_none());
    assert!(feed.normalized_spot().is_none());

    return_shared(feed);
    scenario.end();
}

#[test, expected_failure(abort_code = pyth_feed::EWrongVersion)]
fun update_raw_wrong_version_aborts() {
    let (scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<PythFeed>(feed_obj_id);

    feed.set_version_for_testing(VERSION_ZERO);
    store_raw(&mut feed, SPOT_65K, false, EXPONENT_NEG_9, true, SOURCE_TS_1_US, UPDATE_1_MS);

    abort 999
}

#[test]
fun migrate_restores_current_version_and_updates_resume() {
    let (scenario, feed_obj_id) = setup_feed();
    let mut feed = scenario.take_shared_by_id<PythFeed>(feed_obj_id);

    feed.set_version_for_testing(VERSION_ZERO);
    feed.migrate();
    assert_eq!(feed.version(), constants::current_version!());
    store_raw(&mut feed, SPOT_65K, false, EXPONENT_NEG_9, true, SOURCE_TS_1_US, UPDATE_1_MS);
    assert_latest_normalized(&feed, SPOT_65K, SOURCE_TS_1_MS, UPDATE_1_MS);

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

fun store_raw(
    feed: &mut PythFeed,
    price_magnitude: u64,
    price_is_negative: bool,
    exponent_magnitude: u16,
    exponent_is_negative: bool,
    source_timestamp_us: u64,
    update_timestamp_ms: u64,
) {
    pyth_feed::record_raw_for_testing(
        feed,
        price_magnitude,
        price_is_negative,
        exponent_magnitude,
        exponent_is_negative,
        source_timestamp_us,
        update_timestamp_ms,
        false,
    );
}

fun insert_raw(
    feed: &mut PythFeed,
    price_magnitude: u64,
    price_is_negative: bool,
    exponent_magnitude: u16,
    exponent_is_negative: bool,
    source_timestamp_us: u64,
    update_timestamp_ms: u64,
) {
    pyth_feed::record_raw_for_testing(
        feed,
        price_magnitude,
        price_is_negative,
        exponent_magnitude,
        exponent_is_negative,
        source_timestamp_us,
        update_timestamp_ms,
        true,
    );
}

fun assert_latest_normalized(
    feed: &PythFeed,
    expected_spot: u64,
    expected_source_timestamp_ms: u64,
    expected_update_timestamp_ms: u64,
) {
    let normalized = feed.normalized_spot().destroy_some();
    assert_eq!(normalized.read_source_timestamp_ms(), expected_source_timestamp_ms);
    assert_eq!(normalized.read_update_timestamp_ms(), expected_update_timestamp_ms);
    assert_eq!(normalized.read_value(), expected_spot);
}

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
