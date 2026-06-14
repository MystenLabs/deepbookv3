// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module propbook::observation_history_tests;

use propbook::{constants, observation_history};
use std::unit_test::{assert_eq, destroy};

public struct TestObservation has copy, drop, store {
    spot: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
}

const SPOT_A: u64 = 65_000_000_000_000;
const SPOT_B: u64 = 66_000_000_000_000;
const RESOLUTION_A: u64 = 1_700_100_123_000;
const RESOLUTION_B: u64 = 1_700_100_124_000;

#[test]
fun first_observed_in_minute_wins() {
    let ctx = &mut tx_context::dummy();
    let mut history = observation_history::new(ctx);

    // Two observations in the same UTC minute: 60_001 and 119_999.
    let first_src = constants::minute_ms!() + 1;
    let second_src = 2 * constants::minute_ms!() - 1;
    history.record_first_observed(first_src, new_observation(SPOT_A, first_src, first_src + 10));
    history.record_first_observed(second_src, new_observation(SPOT_B, second_src, second_src + 10));

    let observation = history.observation_at_minute(constants::minute_ms!());
    assert_eq!(observation.spot, SPOT_A);
    assert_eq!(observation.source_timestamp_ms, first_src);

    destroy(history);
}

#[test]
fun mid_minute_observation_rounds_into_bucket() {
    let ctx = &mut tx_context::dummy();
    let mut history = observation_history::new(ctx);

    // 3 minutes + 37.123s = 217_123 ms, which rounds down to bucket 180_000.
    let src = 3 * constants::minute_ms!() + 37_123;
    history.record_first_observed(src, new_observation(SPOT_A, src, src + 5));

    let bucket = 3 * constants::minute_ms!();
    let observation = history.observation_at_minute(bucket);
    assert_eq!(observation.spot, SPOT_A);
    assert_eq!(observation.source_timestamp_ms, src);
    assert_eq!(observation.update_timestamp_ms, src + 5);

    let unrounded = bucket + (constants::minute_ms!() - 1);
    assert_eq!(history.observation_at_minute(unrounded).spot, SPOT_A);

    destroy(history);
}

#[test]
fun has_observation_reflects_recorded_buckets() {
    let ctx = &mut tx_context::dummy();
    let mut history = observation_history::new(ctx);

    let src = constants::minute_ms!() + 1;
    history.record_first_observed(src, new_observation(SPOT_A, src, src));

    assert!(history.has_observation(constants::minute_ms!()));
    assert!(!history.has_observation(5 * constants::minute_ms!()));

    destroy(history);
}

#[test, expected_failure(abort_code = observation_history::EObservationNotFound)]
fun observation_at_absent_minute_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut history = observation_history::new(ctx);
    history.record_first_observed(
        constants::minute_ms!(),
        new_observation(SPOT_A, constants::minute_ms!(), constants::minute_ms!() + 1),
    );

    history.observation_at_minute(5 * constants::minute_ms!());

    abort 999
}

#[test]
fun official_settlement_is_exact_timestamp_only() {
    let ctx = &mut tx_context::dummy();
    let mut history = observation_history::new(ctx);
    history.record_first_observed(
        RESOLUTION_A,
        new_observation(SPOT_A, RESOLUTION_A, RESOLUTION_A + 1),
    );
    history.record_official_settlement(
        RESOLUTION_B,
        new_observation(SPOT_B, RESOLUTION_B, RESOLUTION_B + 1),
    );

    assert!(history.has_observation(RESOLUTION_A));
    assert!(!history.has_official_settlement(RESOLUTION_A));
    assert!(history.has_official_settlement(RESOLUTION_B));
    assert!(!history.has_official_settlement(RESOLUTION_B + 1));

    let settlement = history.official_observation_at_resolution(RESOLUTION_B);
    assert_eq!(settlement.spot, SPOT_B);
    assert_eq!(settlement.source_timestamp_ms, RESOLUTION_B);

    destroy(history);
}

#[test, expected_failure(abort_code = observation_history::EOfficialSettlementAlreadyExists)]
fun duplicate_official_settlement_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut history = observation_history::new(ctx);
    history.record_official_settlement(
        RESOLUTION_A,
        new_observation(SPOT_A, RESOLUTION_A, RESOLUTION_A + 1),
    );
    history.record_official_settlement(
        RESOLUTION_A,
        new_observation(SPOT_B, RESOLUTION_A, RESOLUTION_A + 2),
    );

    abort 999
}

fun new_observation(
    spot: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
): TestObservation {
    TestObservation { spot, source_timestamp_ms, update_timestamp_ms }
}
