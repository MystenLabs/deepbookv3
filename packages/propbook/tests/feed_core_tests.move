// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module propbook::feed_core_tests;

use propbook::{constants, feed_core};
use std::unit_test::{assert_eq, destroy};

const BTC_FEED_ID: u32 = 1;
const SPOT_65K: u64 = 65_000_000_000_000;
/// A distinct spot carried by a stale call, to prove a stale call writes nothing.
const SPOT_OTHER: u64 = 66_000_000_000_000;
/// A package version older than `current_version!()`, for version states a fresh
/// core cannot reach.
const OLD_VERSION: u64 = 0;

#[test]
fun store_tick_if_fresh_writes_and_returns_true_when_fresh() {
    let ctx = &mut tx_context::dummy();
    let mut core = feed_core::new(BTC_FEED_ID, ctx);

    // Tick published at minute 7 + 0.123s; lands on-chain 50ms later.
    let source_ts = 7 * constants::minute_ms!() + 123;
    let update_ts = source_ts + 50;
    assert!(core.store_tick_if_fresh(SPOT_65K, source_ts, update_ts));

    assert_eq!(core.feed_id(), BTC_FEED_ID);
    assert_eq!(core.spot(), SPOT_65K);
    assert_eq!(core.source_timestamp_ms(), source_ts);
    assert_eq!(core.update_timestamp_ms(), update_ts);
    assert_eq!(core.freshness_timestamp_ms(), source_ts);
    assert_eq!(core.version(), constants::current_version!());

    assert!(core.has_minute(7 * constants::minute_ms!()));
    let point = core.price_at_minute(7 * constants::minute_ms!());
    assert_eq!(point.spot(), SPOT_65K);
    assert_eq!(point.source_timestamp_ms(), source_ts);
    assert_eq!(point.update_timestamp_ms(), update_ts);

    destroy(core);
}

#[test]
fun store_tick_if_fresh_noops_and_returns_false_when_stale() {
    let ctx = &mut tx_context::dummy();
    let mut core = feed_core::new(BTC_FEED_ID, ctx);

    // Baseline accepted tick at source = 5_000.
    assert!(core.store_tick_if_fresh(SPOT_65K, 5_000, 5_000));
    // A non-advancing source (5_000, not > 5_000) is a no-op that returns false.
    assert!(!core.store_tick_if_fresh(SPOT_OTHER, 5_000, 9_000));

    // Nothing changed: the stale spot/timestamps were not written.
    assert_eq!(core.spot(), SPOT_65K);
    assert_eq!(core.source_timestamp_ms(), 5_000);
    assert_eq!(core.update_timestamp_ms(), 5_000);

    destroy(core);
}

#[test, expected_failure(abort_code = feed_core::EZeroSpot)]
fun store_tick_zero_spot_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut core = feed_core::new(BTC_FEED_ID, ctx);

    core.store_tick_if_fresh(0, 1_000, 1_000);

    abort 999
}

#[test, expected_failure(abort_code = feed_core::EFutureSourceUpdate)]
fun store_tick_future_source_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut core = feed_core::new(BTC_FEED_ID, ctx);

    // Source timestamp ahead of the on-chain landing time is rejected.
    core.store_tick_if_fresh(SPOT_65K, 9_000, 8_000);

    abort 999
}

#[test, expected_failure(abort_code = feed_core::EWrongVersion)]
fun store_tick_wrong_version_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut core = feed_core::new(BTC_FEED_ID, ctx);

    core.set_version_for_testing(OLD_VERSION);
    core.store_tick_if_fresh(SPOT_65K, 1_000, 1_000);

    abort 999
}

#[test, expected_failure(abort_code = feed_core::ENotNewerVersion)]
fun migrate_at_current_version_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut core = feed_core::new(BTC_FEED_ID, ctx);

    // A fresh core is already at current_version!(); migrate has nothing to do.
    core.migrate();

    abort 999
}

#[test]
fun migrate_advances_stale_version() {
    let ctx = &mut tx_context::dummy();
    let mut core = feed_core::new(BTC_FEED_ID, ctx);

    // Simulate a core created under an older package version, then migrate.
    core.set_version_for_testing(OLD_VERSION);
    core.migrate();
    assert_eq!(core.version(), constants::current_version!());

    destroy(core);
}
