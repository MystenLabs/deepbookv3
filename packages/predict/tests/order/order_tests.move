// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit tests for `order` ID packing/unpacking and its validation guards.
///
/// The packed-id expectations are derived INDEPENDENTLY from the documented u256
/// layout (order.move module doc), not from the contract's pack expression:
///   [200,232) quantity_lots_key = (2^32-1) - quantity_lots   (32b, complement)
///   [136,200) floor_shares_key = (2^64-1) - floor_shares   (64b, complement)
///   [ 88,136) opened_at_ms (48b)
///   [ 64, 88) lower_tick (24b)     [40, 64) higher_tick (24b)
///   [  0, 40) sequence (40b)
/// The exact-id assertions catch field overlap/offset/truncation bugs; the getter
/// assertions verify each decode; the abort tests cover all seven guards.
#[test_only]
module deepbook_predict::order_tests;

use deepbook_predict::{constants, order};
use std::unit_test::assert_eq;

// === Independently packed reference ids (see Python derivation in the PR) ===

// pack(opened=1000, lower=0, higher=100001, floor=50000, qlots=7, seq=12345)
const LEVERAGED_ID: u256 = 6901746335541997477621819577781881932119187661683188027568322148053049;
// pack(opened=2000, lower=3, higher=7, floor=0, qlots=12, seq=88)
const NONLEV_ID: u256 = 6901746327507307256326872555686368058426016465277024760643844810211416;

const LEV_OPENED: u64 = 1000;
const LEV_HIGHER: u64 = 100_001;
const LEV_FLOOR: u64 = 50_000;
const LEV_QLOTS: u64 = 7;
const LEV_QUANTITY: u64 = 70_000; // 7 * position_lot_size (10_000)
const LEV_SEQ: u64 = 12_345;

const NONLEV_OPENED: u64 = 2000;
const NONLEV_LOWER: u64 = 3;
const NONLEV_HIGHER: u64 = 7;
const NONLEV_QLOTS: u64 = 12;
const NONLEV_QUANTITY: u64 = 120_000; // 12 * 10_000
const NONLEV_SEQ: u64 = 88;

// === Out-of-range field values for the guard tests ===
const U48_OVERFLOW: u64 = 1 << 48; // > U48_MASK (opened_at)
const U40_OVERFLOW: u64 = 1 << 40; // > U40_MASK (sequence)
const U24_OVERFLOW: u64 = 1 << 24; // > U24_MASK (strike tick == pos_inf_tick)
const NON_LOT_QUANTITY: u64 = 10_001; // not a multiple of position_lot_size
const OVER_FLOOR_QUANTITY: u64 = 70_000;
const OVER_FLOOR_SHARES: u64 = 80_000; // > quantity
const PRIORITY_LOTS: u64 = 10;
const PRIORITY_QUANTITY: u64 = 100_000; // 10 * 10_000
const PRIORITY_HIGHER_TICK: u64 = 2;
const LOW_FLOOR_SHARES: u64 = 10_000;
const HIGH_FLOOR_SHARES: u64 = 20_000;

// === Exact-pack (independent layout) ===

#[test]
fun leveraged_order_packs_to_independent_layout() {
    let o = order::new_from_ticks(
        LEV_OPENED,
        0,
        LEV_HIGHER,
        LEV_FLOOR,
        LEV_QUANTITY,
        LEV_SEQ,
    );
    assert_eq!(o.id(), LEVERAGED_ID);
}

#[test]
fun nonleveraged_order_packs_to_independent_layout() {
    let o = order::new_from_ticks(
        NONLEV_OPENED,
        NONLEV_LOWER,
        NONLEV_HIGHER,
        0,
        NONLEV_QUANTITY,
        NONLEV_SEQ,
    );
    assert_eq!(o.id(), NONLEV_ID);
}

// === Decode (getter) coverage + round-trip identity ===

#[test]
fun from_order_id_decodes_every_leveraged_field() {
    let o = order::from_order_id(LEVERAGED_ID);
    assert_eq!(o.id(), LEVERAGED_ID);
    assert_eq!(o.opened_at_ms(), LEV_OPENED);
    assert_eq!(o.lower_tick(), 0);
    assert_eq!(o.higher_tick(), LEV_HIGHER);
    assert_eq!(o.floor_shares(), LEV_FLOOR);
    assert_eq!(o.quantity_lots(), LEV_QLOTS);
    assert_eq!(o.quantity(), LEV_QUANTITY);
    assert_eq!(o.sequence(), LEV_SEQ);
    assert!(o.is_leveraged());
}

#[test]
fun from_order_id_decodes_every_nonleveraged_field() {
    let o = order::from_order_id(NONLEV_ID);
    assert_eq!(o.opened_at_ms(), NONLEV_OPENED);
    assert_eq!(o.lower_tick(), NONLEV_LOWER);
    assert_eq!(o.higher_tick(), NONLEV_HIGHER);
    assert_eq!(o.floor_shares(), 0);
    assert_eq!(o.quantity_lots(), NONLEV_QLOTS);
    assert_eq!(o.quantity(), NONLEV_QUANTITY);
    assert_eq!(o.sequence(), NONLEV_SEQ);
    assert!(!o.is_leveraged());
}

#[test]
fun max_quantity_lots_round_trips_through_complement_encoding() {
    // quantity_lots == U32_MASK is the max; its complement key is 0. Round-trip
    // must recover U32_MASK, not wrap.
    let max_lots = ((1u256 << 32) - 1) as u64;
    let max_quantity = max_lots * constants::position_lot_size!();
    let o = order::new_from_ticks(
        LEV_OPENED,
        NONLEV_LOWER,
        NONLEV_HIGHER,
        0,
        max_quantity,
        LEV_SEQ,
    );
    assert_eq!(o.quantity_lots(), max_lots);
    assert_eq!(o.quantity(), max_quantity);
}

#[test]
fun larger_floor_shares_sort_before_smaller_floor_shares_for_equal_quantity() {
    let low_floor = order::new_from_ticks(
        LEV_OPENED,
        0,
        PRIORITY_HIGHER_TICK,
        LOW_FLOOR_SHARES,
        PRIORITY_QUANTITY,
        1,
    );
    let high_floor = order::new_from_ticks(
        LEV_OPENED,
        0,
        PRIORITY_HIGHER_TICK,
        HIGH_FLOOR_SHARES,
        PRIORITY_QUANTITY,
        2,
    );

    assert!(high_floor.id() < low_floor.id());
    assert_eq!(high_floor.quantity_lots(), PRIORITY_LOTS);
    assert_eq!(low_floor.quantity_lots(), PRIORITY_LOTS);
}

// === replacement inherits the original terms ===

#[test]
fun replacement_inherits_open_time_and_ticks() {
    let old = order::from_order_id(LEVERAGED_ID);
    let repl_quantity = 50_000; // < 70_000
    let repl_floor = 30_000;
    let repl_seq = 999;
    let repl = old.replacement(repl_quantity, repl_floor, repl_seq);
    // Inherited terms.
    assert_eq!(repl.opened_at_ms(), LEV_OPENED);
    assert_eq!(repl.lower_tick(), 0);
    assert_eq!(repl.higher_tick(), LEV_HIGHER);
    // Replaced terms.
    assert_eq!(repl.quantity(), repl_quantity);
    assert_eq!(repl.floor_shares(), repl_floor);
    assert_eq!(repl.sequence(), repl_seq);
}

// === Guard coverage (all seven abort codes) ===

#[test, expected_failure(abort_code = order::EInvalidOrderId)]
fun from_order_id_rejects_bits_above_envelope() {
    // A set bit above the 232-bit order envelope.
    order::from_order_id(1u256 << 233);
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidQuantity)]
fun new_rejects_non_lot_quantity() {
    order::new_from_ticks(LEV_OPENED, 0, LEV_HIGHER, 0, NON_LOT_QUANTITY, LEV_SEQ);
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidOpenedAt)]
fun new_rejects_opened_at_over_u48() {
    order::new_from_ticks(U48_OVERFLOW, 0, LEV_HIGHER, 0, LEV_QUANTITY, LEV_SEQ);
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidTick)]
fun new_rejects_tick_over_u24() {
    // A tick one past the 24-bit domain (pos_inf_tick is the max encodable tick).
    order::new_from_ticks(LEV_OPENED, U24_OVERFLOW, U24_OVERFLOW + 1, 0, LEV_QUANTITY, LEV_SEQ);
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidRange)]
fun new_rejects_lower_not_below_higher() {
    order::new_from_ticks(LEV_OPENED, 7, 5, 0, LEV_QUANTITY, LEV_SEQ);
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidFloorShares)]
fun new_rejects_floor_shares_above_quantity() {
    order::new_from_ticks(
        LEV_OPENED,
        0,
        LEV_HIGHER,
        OVER_FLOOR_SHARES,
        OVER_FLOOR_QUANTITY,
        LEV_SEQ,
    );
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidSequence)]
fun new_rejects_sequence_over_u40() {
    order::new_from_ticks(LEV_OPENED, 0, LEV_HIGHER, 0, LEV_QUANTITY, U40_OVERFLOW);
    abort 999
}
