// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module propbook::oracle_lane_tests;

use propbook::{constants, observation_history, oracle_lane::{Self, OracleLane, OracleObservation}};
use std::unit_test::{assert_eq, destroy};
use sui::object;

public struct TestPayload has copy, drop, store {
    spot: u64,
}

const PROPBOOK_ORACLE_ADDRESS: address = @0xA11CE;
const SPOT_65K: u64 = 65_000_000_000_000;
const SPOT_OTHER: u64 = 66_000_000_000_000;
const RESOLUTION_MS: u64 = 1_700_100_123_000;

#[test]
fun record_observation_if_fresh_updates_latest_and_first_observed() {
    let ctx = &mut tx_context::dummy();
    let mut lane = new_lane(ctx);

    let source_ts = 7 * constants::minute_ms!() + 123;
    let update_ts = source_ts + 50;
    lane.record_observation_if_fresh(oracle_id(), new_observation(SPOT_65K, source_ts, update_ts));

    assert!(lane.has_latest());
    assert_eq!(lane.freshness_timestamp_ms(), source_ts);

    let latest = lane.latest();
    assert_eq!(latest.source_timestamp_ms(), source_ts);
    assert_eq!(latest.update_timestamp_ms(), update_ts);
    assert_eq!(observation_spot(&latest), SPOT_65K);

    let first_observed = lane.observation_at_minute(7 * constants::minute_ms!());
    assert_eq!(observation_spot(&first_observed), SPOT_65K);
    assert_eq!(first_observed.source_timestamp_ms(), source_ts);

    destroy(lane);
}

#[test, expected_failure(abort_code = oracle_lane::EStaleSourceUpdate)]
fun record_observation_stale_source_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut lane = new_lane(ctx);

    lane.record_observation_if_fresh(oracle_id(), new_observation(SPOT_65K, 5_000, 5_000));
    lane.record_observation_if_fresh(oracle_id(), new_observation(SPOT_OTHER, 5_000, 9_000));

    abort 999
}

#[test, expected_failure(abort_code = oracle_lane::EFutureSourceUpdate)]
fun record_observation_future_source_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut lane = new_lane(ctx);

    lane.record_observation_if_fresh(oracle_id(), new_observation(SPOT_65K, 9_000, 8_000));

    abort 999
}

#[test]
fun official_settlement_is_exact_and_does_not_advance_latest() {
    let ctx = &mut tx_context::dummy();
    let mut lane = new_lane(ctx);

    lane.record_official_settlement(
        oracle_id(),
        new_observation(SPOT_65K, RESOLUTION_MS, RESOLUTION_MS + 1),
    );

    assert!(!lane.has_latest());
    assert!(!lane.has_observation(RESOLUTION_MS));
    assert!(lane.has_official_settlement(RESOLUTION_MS));
    assert!(!lane.has_official_settlement(RESOLUTION_MS + 1));

    let settlement = lane.official_observation_at_resolution(RESOLUTION_MS);
    assert_eq!(observation_spot(&settlement), SPOT_65K);
    assert_eq!(settlement.source_timestamp_ms(), RESOLUTION_MS);

    destroy(lane);
}

#[test, expected_failure(abort_code = observation_history::EOfficialSettlementAlreadyExists)]
fun duplicate_official_settlement_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut lane = new_lane(ctx);

    lane.record_official_settlement(
        oracle_id(),
        new_observation(SPOT_65K, RESOLUTION_MS, RESOLUTION_MS + 1),
    );
    lane.record_official_settlement(
        oracle_id(),
        new_observation(SPOT_OTHER, RESOLUTION_MS, RESOLUTION_MS + 2),
    );

    abort 999
}

fun new_lane(ctx: &mut TxContext): OracleLane<TestPayload> {
    oracle_lane::new(TestPayload { spot: 0 }, ctx)
}

fun new_observation(
    spot: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
): OracleObservation<TestPayload> {
    oracle_lane::new_observation(TestPayload { spot }, source_timestamp_ms, update_timestamp_ms)
}

fun observation_spot(observation: &OracleObservation<TestPayload>): u64 {
    observation.payload().spot
}

fun oracle_id(): ID {
    object::id_from_address(PROPBOOK_ORACLE_ADDRESS)
}
