// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module propbook::minute_history_tests;

use propbook::{constants, minute_history};
use std::unit_test::{assert_eq, destroy};

// Arbitrary distinct 1e9-scaled test spots.
const SPOT_A: u64 = 65_000_000_000_000;
const SPOT_B: u64 = 66_000_000_000_000;

#[test]
fun first_tick_in_minute_wins() {
    let ctx = &mut tx_context::dummy();
    let mut history = minute_history::new(ctx);

    // Two ticks in the same UTC minute (bucket 60_000): 60_001 and 119_999.
    let first_src = constants::minute_ms!() + 1;
    let second_src = 2 * constants::minute_ms!() - 1;
    history.record(minute_history::new_data_point(SPOT_A, first_src, first_src + 10));
    history.record(minute_history::new_data_point(SPOT_B, second_src, second_src + 10));

    // The first tick is retained; the second is dropped as a no-op.
    let point = history.price_at_minute(constants::minute_ms!());
    assert_eq!(point.spot(), SPOT_A);
    assert_eq!(point.source_timestamp_ms(), first_src);

    destroy(history);
}

#[test]
fun mid_minute_tick_rounds_into_bucket() {
    let ctx = &mut tx_context::dummy();
    let mut history = minute_history::new(ctx);

    // 3 minutes + 37.123s = 217_123 ms, which rounds down to bucket 180_000.
    let src = 3 * constants::minute_ms!() + 37_123;
    history.record(minute_history::new_data_point(SPOT_A, src, src + 5));

    let bucket = 3 * constants::minute_ms!();
    let point = history.price_at_minute(bucket);
    assert_eq!(point.spot(), SPOT_A);
    assert_eq!(point.source_timestamp_ms(), src);
    assert_eq!(point.update_timestamp_ms(), src + 5);

    // Defensive query rounding: an unrounded ms in the same minute also hits.
    let unrounded = bucket + (constants::minute_ms!() - 1);
    assert_eq!(history.price_at_minute(unrounded).spot(), SPOT_A);

    destroy(history);
}

#[test]
fun has_minute_reflects_recorded_buckets() {
    let ctx = &mut tx_context::dummy();
    let mut history = minute_history::new(ctx);

    let src = constants::minute_ms!() + 1;
    history.record(minute_history::new_data_point(SPOT_A, src, src));

    // Recorded minute (queried with an unrounded ms in the same bucket) is
    // present; a never-recorded minute is absent.
    assert!(history.has_minute(constants::minute_ms!()));
    assert!(!history.has_minute(5 * constants::minute_ms!()));

    destroy(history);
}

#[test, expected_failure(abort_code = minute_history::EMinuteNotFound)]
fun price_at_absent_minute_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut history = minute_history::new(ctx);
    history.record(
        minute_history::new_data_point(
            SPOT_A,
            constants::minute_ms!(),
            constants::minute_ms!() + 1,
        ),
    );

    // A minute that was never recorded aborts.
    history.price_at_minute(5 * constants::minute_ms!());

    abort 999
}
