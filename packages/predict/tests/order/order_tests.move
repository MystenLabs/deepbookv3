// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit tests for `order` ID packing/unpacking and its validation guards.
///
/// The packed-id expectations are derived INDEPENDENTLY from the documented u256
/// layout (order.move module doc), not from the contract's pack expression:
///   [100,132) quantity_lots (32b)  [70,100) lower_tick (30b)
///   [ 40, 70) higher_tick   (30b)  [  0, 40) sequence  (40b)
/// The exact-id assertions catch field overlap/offset/truncation bugs; the getter
/// assertions verify each decode; the abort tests cover all five guards.
#[test_only]
module deepbook_predict::order_tests;

use deepbook_predict::{constants, order};
use std::unit_test::assert_eq;

// === Independently packed reference ids ===
//
// Derived from the field offsets above only, with:
//   def pack(lower, higher, qlots, seq):
//       return (qlots << 100) | (lower << 70) | (higher << 40) | seq
//
// pack(lower=0,      higher=100_001, qlots=7,  seq=12_345)
const OPEN_LOWER_ID: u256 = 8_873_554_201_597_715_762_739_211_677_753;
// pack(lower=3,      higher=7,       qlots=12, seq=88)
const FINITE_RANGE_ID: u256 = 15_211_807_206_280_527_687_809_253_769_304;

const LEV_HIGHER: u64 = 100_001;
const LEV_QUANTITY: u64 = 70_000; // 7 * position_lot_size (10_000)
const LEV_SEQ: u64 = 12_345;

const NONLEV_LOWER: u64 = 3;
const NONLEV_HIGHER: u64 = 7;
const NONLEV_QUANTITY: u64 = 120_000; // 12 * position_lot_size (10_000)
const NONLEV_SEQ: u64 = 88;

// === Out-of-range field values for the guard tests ===
const U40_OVERFLOW: u64 = 1 << 40; // > U40_MASK (sequence)
const U30_OVERFLOW: u64 = 1 << 30; // > U30_MASK (strike tick == pos_inf_tick)
const NON_LOT_QUANTITY: u64 = 10_001; // not a multiple of position_lot_size

// === Exact-pack (independent layout) ===

#[test]
fun open_lower_order_packs_to_independent_layout() {
    let o = order::new_from_ticks(0, LEV_HIGHER, LEV_QUANTITY, LEV_SEQ);
    assert_eq!(o.id(), OPEN_LOWER_ID);
}

#[test]
fun finite_range_order_packs_to_independent_layout() {
    let o = order::new_from_ticks(NONLEV_LOWER, NONLEV_HIGHER, NONLEV_QUANTITY, NONLEV_SEQ);
    assert_eq!(o.id(), FINITE_RANGE_ID);
}

// === Decode (getter) coverage + round-trip identity ===

#[test]
fun every_getter_decodes_its_own_field() {
    let o = order::from_order_id(FINITE_RANGE_ID);
    assert_eq!(o.lower_tick(), NONLEV_LOWER);
    assert_eq!(o.higher_tick(), NONLEV_HIGHER);
    assert_eq!(o.quantity_lots(), 12);
    assert_eq!(o.quantity(), NONLEV_QUANTITY);
    assert_eq!(o.sequence(), NONLEV_SEQ);
}

#[test]
fun open_lower_order_round_trips_through_the_packed_id() {
    let o = order::from_order_id(OPEN_LOWER_ID);
    assert_eq!(o.lower_tick(), 0);
    assert_eq!(o.higher_tick(), LEV_HIGHER);
    assert_eq!(o.quantity(), LEV_QUANTITY);
    assert_eq!(o.sequence(), LEV_SEQ);
    assert_eq!(o.id(), OPEN_LOWER_ID);
}

#[test]
fun max_quantity_lots_round_trips_without_truncation() {
    // quantity_lots == U32_MASK is the widest value the 32-bit field holds; the
    // round-trip must recover it exactly rather than truncating into lower_tick.
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

#[test]
fun replacement_keeps_the_range_and_takes_the_new_quantity_and_sequence() {
    let original = order::new_from_ticks(NONLEV_LOWER, NONLEV_HIGHER, NONLEV_QUANTITY, NONLEV_SEQ);
    let survivor = order::replacement(&original, NONLEV_QUANTITY - 10_000, NONLEV_SEQ + 1);
    assert_eq!(survivor.lower_tick(), NONLEV_LOWER);
    assert_eq!(survivor.higher_tick(), NONLEV_HIGHER);
    assert_eq!(survivor.quantity(), NONLEV_QUANTITY - 10_000);
    assert_eq!(survivor.sequence(), NONLEV_SEQ + 1);
}

// === Guard coverage (all five abort codes) ===

#[test, expected_failure(abort_code = order::EInvalidOrderId)]
fun from_order_id_rejects_bits_above_envelope() {
    // The first bit above the dense 132-bit order envelope.
    order::from_order_id(1u256 << 132);
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
