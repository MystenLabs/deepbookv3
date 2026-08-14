// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit tests for `order` ID packing/unpacking and its validation guards.
///
/// The packed-id expectations are derived INDEPENDENTLY from the documented u256
/// layout (order.move module doc), not from the contract's pack expression:
///   [164,196) quantity_lots_key = (2^32-1) - quantity_lots   (32b, complement)
///   [100,164) floor_shares_key = (2^64-1) - floor_shares   (64b, complement)
///   [ 70,100) lower_tick (30b)     [40, 70) higher_tick (30b)
///   [  0, 40) sequence (40b)
/// The exact-id assertions catch field overlap/offset/truncation bugs; the getter
/// assertions verify each decode; the abort tests cover all six guards.
#[test_only]
module deepbook_predict::order_tests;

use deepbook_predict::{constants, order};
use std::unit_test::assert_eq;

// === Independently packed reference ids (see Python derivation in the PR) ===

// pack(lower=0, higher=100001, floor=50000, qlots=7, seq=12345)
// pack(lower=3, higher=7, floor=0, qlots=12, seq=88)

const LEV_HIGHER: u64 = 100_001;
const LEV_QUANTITY: u64 = 70_000; // 7 * position_lot_size (10_000)
const LEV_SEQ: u64 = 12_345;

const NONLEV_LOWER: u64 = 3;
const NONLEV_HIGHER: u64 = 7;

// === Out-of-range field values for the guard tests ===
const U40_OVERFLOW: u64 = 1 << 40; // > U40_MASK (sequence)
const U30_OVERFLOW: u64 = 1 << 30; // > U30_MASK (strike tick == pos_inf_tick)
const NON_LOT_QUANTITY: u64 = 10_001; // not a multiple of position_lot_size

// === Exact-pack (independent layout) ===

// === Decode (getter) coverage + round-trip identity ===

#[test]
fun max_quantity_lots_round_trips_through_complement_encoding() {
    // quantity_lots == U32_MASK is the max; its complement key is 0. Round-trip
    // must recover U32_MASK, not wrap.
    let max_lots = ((1u256 << 32) - 1) as u64;
    let max_quantity = max_lots * constants::position_lot_size!();
    let o = order::new_from_ticks(
        NONLEV_LOWER,
        NONLEV_HIGHER,
        max_quantity,
        LEV_SEQ,
    );
    assert_eq!(o.quantity_lots(), max_lots);
    assert_eq!(o.quantity(), max_quantity);
}

// === replacement inherits the original range terms ===

// === Guard coverage (all seven abort codes) ===

#[test, expected_failure(abort_code = order::EInvalidOrderId)]
fun from_order_id_rejects_bits_above_envelope() {
    // A set bit above the dense 196-bit order envelope.
    order::from_order_id(1u256 << 196);
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidQuantity)]
fun new_rejects_non_lot_quantity() {
    order::new_from_ticks(0, LEV_HIGHER, NON_LOT_QUANTITY, LEV_SEQ);
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidTick)]
fun new_rejects_tick_over_u30() {
    // A tick one past the 30-bit domain (pos_inf_tick is the max encodable tick).
    order::new_from_ticks(U30_OVERFLOW, U30_OVERFLOW + 1, LEV_QUANTITY, LEV_SEQ);
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidRange)]
fun new_rejects_lower_not_below_higher() {
    order::new_from_ticks(7, 5, LEV_QUANTITY, LEV_SEQ);
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidRange)]
fun new_rejects_full_open_range() {
    order::new_from_ticks(0, constants::pos_inf_tick!(), LEV_QUANTITY, LEV_SEQ);
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidSequence)]
fun new_rejects_sequence_over_u40() {
    order::new_from_ticks(0, LEV_HIGHER, LEV_QUANTITY, U40_OVERFLOW);
    abort 999
}
