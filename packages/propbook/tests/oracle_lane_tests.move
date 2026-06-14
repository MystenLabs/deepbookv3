// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module propbook::oracle_lane_tests;

use propbook::oracle_lane::{Self, OracleLane, OracleRead};
use std::unit_test::{assert_eq, destroy};
use sui::object;

public struct TestPayload has copy, drop, store {
    spot: u64,
}

const PROPBOOK_ORACLE_ADDRESS: address = @0xA11CE;
const SPOT_A: u64 = 65_000_000_000_000;
const SPOT_B: u64 = 66_000_000_000_000;
const T_ZERO: u64 = 0;
const T_EARLY: u64 = 100;
const T_MID: u64 = 150;
const T_LATE: u64 = 200;
const UPDATE_EARLY: u64 = 120;
const UPDATE_MID: u64 = 170;
const UPDATE_LATE: u64 = 220;

#[test]
fun update_accepts_newer_latest_without_exact_insert() {
    let ctx = &mut tx_context::dummy();
    let mut lane = new_lane(ctx);

    lane.update(oracle_id(), new_read(SPOT_A, T_EARLY, UPDATE_EARLY));
    lane.update(oracle_id(), new_read(SPOT_B, T_MID, UPDATE_MID));

    let latest = lane.latest_read().destroy_some();
    assert_eq!(latest.read_source_timestamp_ms(), T_MID);
    assert_eq!(latest.read_update_timestamp_ms(), UPDATE_MID);
    assert_eq!(read_spot(&latest), SPOT_B);
    assert!(lane.read_at(T_EARLY).is_none());
    assert!(lane.read_at(T_MID).is_none());

    destroy(lane);
}

#[test]
fun update_stale_future_and_zero_sources_are_no_ops() {
    let ctx = &mut tx_context::dummy();
    let mut lane = new_lane(ctx);

    lane.update(oracle_id(), new_read(SPOT_A, T_MID, UPDATE_MID));
    lane.update(oracle_id(), new_read(SPOT_B, T_MID, UPDATE_LATE));
    lane.update(oracle_id(), new_read(SPOT_B, T_EARLY, UPDATE_LATE));
    lane.update(oracle_id(), new_read(SPOT_B, T_LATE, T_EARLY));
    lane.update(oracle_id(), new_read(SPOT_B, T_ZERO, UPDATE_LATE));

    let latest = lane.latest_read().destroy_some();
    assert_eq!(latest.read_source_timestamp_ms(), T_MID);
    assert_eq!(latest.read_update_timestamp_ms(), UPDATE_MID);
    assert_eq!(read_spot(&latest), SPOT_A);

    destroy(lane);
}

#[test]
fun insert_at_records_exact_read_without_latest() {
    let ctx = &mut tx_context::dummy();
    let mut lane = new_lane(ctx);

    lane.insert_at(oracle_id(), new_read(SPOT_A, T_EARLY, UPDATE_EARLY));

    assert!(lane.latest_read().is_none());
    let exact = lane.read_at(T_EARLY).destroy_some();
    assert_eq!(exact.read_source_timestamp_ms(), T_EARLY);
    assert_eq!(exact.read_update_timestamp_ms(), UPDATE_EARLY);
    assert_eq!(read_spot(&exact), SPOT_A);
    assert!(lane.read_at(T_EARLY + 1).is_none());

    destroy(lane);
}

#[test]
fun insert_at_duplicate_future_and_zero_sources_are_no_ops() {
    let ctx = &mut tx_context::dummy();
    let mut lane = new_lane(ctx);

    lane.insert_at(oracle_id(), new_read(SPOT_A, T_EARLY, UPDATE_EARLY));
    lane.insert_at(oracle_id(), new_read(SPOT_B, T_EARLY, UPDATE_LATE));
    lane.insert_at(oracle_id(), new_read(SPOT_B, T_LATE, T_EARLY));
    lane.insert_at(oracle_id(), new_read(SPOT_B, T_ZERO, UPDATE_LATE));

    let exact = lane.read_at(T_EARLY).destroy_some();
    assert_eq!(exact.read_source_timestamp_ms(), T_EARLY);
    assert_eq!(read_spot(&exact), SPOT_A);
    assert!(lane.read_at(T_LATE).is_none());
    assert!(lane.read_at(T_ZERO).is_none());
    assert!(lane.latest_read().is_none());

    destroy(lane);
}

#[test]
fun read_has_valid_timestamp_reports_lane_entry_shape() {
    assert!(oracle_lane::read_has_valid_timestamp(&new_read(SPOT_A, T_EARLY, UPDATE_EARLY)));
    assert!(!oracle_lane::read_has_valid_timestamp(&new_read(SPOT_A, T_ZERO, UPDATE_EARLY)));
    assert!(!oracle_lane::read_has_valid_timestamp(&new_read(SPOT_A, T_LATE, T_EARLY)));
}

fun new_lane(ctx: &mut TxContext): OracleLane<TestPayload> {
    oracle_lane::new(ctx)
}

fun new_read(
    spot: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
): OracleRead<TestPayload> {
    oracle_lane::new_read(source_timestamp_ms, update_timestamp_ms, TestPayload { spot })
}

fun read_spot(read: &OracleRead<TestPayload>): u64 {
    read.read_value().spot
}

fun oracle_id(): ID {
    object::id_from_address(PROPBOOK_ORACLE_ADDRESS)
}
