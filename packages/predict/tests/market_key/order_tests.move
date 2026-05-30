// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::order_tests;

use deepbook_predict::{constants, order};
use std::unit_test::assert_eq;

// Position lot size is 10_000 (from constants::position_lot_size!()), so a
// quantity must be a multiple of 10_000.
const ONE_LOT_QTY: u64 = 10_000;
const TWO_LOTS_QTY: u64 = 20_000;
const SEQUENCE_ZERO: u64 = 0;
const OPENED_AT_MS: u64 = 1_700_000_000_000;
// Strikes are indices into the 100_000-tick grid; pick safe values.
const STRIKE_INDEX_LO: u64 = 100;
const STRIKE_INDEX_HI: u64 = 200;

// === Leverage constants ===

#[test]
fun leverage_constants_are_distinct_and_ordered() {
    let l1 = order::leverage_one_x();
    let l15 = order::leverage_one_and_half_x();
    let l2 = order::leverage_two_x();
    let l25 = order::leverage_two_and_half_x();
    let l3 = order::leverage_three_x();

    assert_eq!(l1, constants::float_scaling!());
    assert!(l1 < l15);
    assert_eq!(l15, constants::float_scaling!() + constants::float_scaling!() / 2);
    assert!(l15 < l2);
    assert_eq!(l2, 2 * constants::float_scaling!());
    assert!(l2 < l25);
    assert_eq!(l25, 2 * constants::float_scaling!() + constants::float_scaling!() / 2);
    assert!(l25 < l3);
    assert_eq!(l3, 3 * constants::float_scaling!());
}

// === open_strike_index sentinel ===

#[test]
fun open_strike_index_is_above_grid() {
    // The sentinel is one above the maximum valid finite strike index.
    assert_eq!(order::open_strike_index(), constants::oracle_strike_grid_ticks!() + 1);
}

// === assert_valid_quantity ===

#[test]
fun assert_valid_quantity_accepts_lot_multiples() {
    order::assert_valid_quantity(ONE_LOT_QTY);
    order::assert_valid_quantity(TWO_LOTS_QTY);
    order::assert_valid_quantity(ONE_LOT_QTY * 12345);
}

#[test, expected_failure(abort_code = order::EInvalidQuantity)]
fun assert_valid_quantity_zero_aborts() {
    order::assert_valid_quantity(0);
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidQuantity)]
fun assert_valid_quantity_not_a_lot_multiple_aborts() {
    order::assert_valid_quantity(ONE_LOT_QTY + 1);
    abort 999
}

// === new_from_strike_indices: happy path + getters ===

#[test]
fun new_from_strike_indices_round_trips_through_getters() {
    let leverage = order::leverage_one_x();
    let entry_probability = 500_000_000; // 0.5 in 1e9
    let o = order::new_from_strike_indices(
        OPENED_AT_MS,
        STRIKE_INDEX_LO,
        STRIKE_INDEX_HI,
        leverage,
        entry_probability,
        TWO_LOTS_QTY,
        SEQUENCE_ZERO,
    );

    assert_eq!(o.opened_at_ms(), OPENED_AT_MS);
    assert_eq!(o.min_strike_index(), STRIKE_INDEX_LO);
    assert_eq!(o.max_strike_index(), STRIKE_INDEX_HI);
    assert_eq!(o.leverage(), leverage);
    assert_eq!(o.entry_probability(), entry_probability);
    assert_eq!(o.quantity(), TWO_LOTS_QTY);
    assert_eq!(o.quantity_lots(), TWO_LOTS_QTY / constants::position_lot_size!());
    assert_eq!(o.sequence(), SEQUENCE_ZERO);
}

#[test]
fun from_order_id_round_trips_through_id_getter() {
    let leverage = order::leverage_one_x();
    let o = order::new_from_strike_indices(
        OPENED_AT_MS,
        STRIKE_INDEX_LO,
        STRIKE_INDEX_HI,
        leverage,
        0,
        ONE_LOT_QTY,
        0,
    );
    let packed_id = o.id();

    let parsed = order::from_order_id(packed_id);
    assert_eq!(parsed.id(), packed_id);
    assert_eq!(parsed.opened_at_ms(), o.opened_at_ms());
    assert_eq!(parsed.min_strike_index(), o.min_strike_index());
}

#[test]
fun is_leveraged_distinguishes_one_x_from_others() {
    let o1 = order::new_from_strike_indices(
        OPENED_AT_MS,
        STRIKE_INDEX_LO,
        STRIKE_INDEX_HI,
        order::leverage_one_x(),
        0,
        ONE_LOT_QTY,
        0,
    );
    assert!(!o1.is_leveraged());

    // Leveraged orders must have one side at the open sentinel.
    let o2 = order::new_from_strike_indices(
        OPENED_AT_MS,
        order::open_strike_index(),
        STRIKE_INDEX_HI,
        order::leverage_two_x(),
        0,
        ONE_LOT_QTY,
        0,
    );
    assert!(o2.is_leveraged());
}

// === new_from_strike_indices abort cases ===

#[test, expected_failure(abort_code = order::EInvalidOpenedAt)]
fun new_opened_at_above_u48_aborts() {
    let above_u48: u64 = 1 << 48;
    order::new_from_strike_indices(
        above_u48,
        STRIKE_INDEX_LO,
        STRIKE_INDEX_HI,
        order::leverage_one_x(),
        0,
        ONE_LOT_QTY,
        0,
    );
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidStrikeIndex)]
fun new_strike_index_above_u24_aborts() {
    let above_u24: u64 = 1 << 24;
    order::new_from_strike_indices(
        OPENED_AT_MS,
        above_u24,
        above_u24 + 1,
        order::leverage_one_x(),
        0,
        ONE_LOT_QTY,
        0,
    );
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidEntryProbability)]
fun new_entry_probability_above_one_aborts() {
    order::new_from_strike_indices(
        OPENED_AT_MS,
        STRIKE_INDEX_LO,
        STRIKE_INDEX_HI,
        order::leverage_one_x(),
        constants::float_scaling!() + 1,
        ONE_LOT_QTY,
        0,
    );
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidQuantity)]
fun new_zero_quantity_aborts() {
    order::new_from_strike_indices(
        OPENED_AT_MS,
        STRIKE_INDEX_LO,
        STRIKE_INDEX_HI,
        order::leverage_one_x(),
        0,
        0,
        0,
    );
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidLeverage)]
fun new_leverage_above_three_x_aborts() {
    order::new_from_strike_indices(
        OPENED_AT_MS,
        STRIKE_INDEX_LO,
        STRIKE_INDEX_HI,
        order::leverage_three_x() + 1,
        0,
        ONE_LOT_QTY,
        0,
    );
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidLeverage)]
fun new_unsupported_leverage_multiplier_aborts() {
    order::new_from_strike_indices(
        OPENED_AT_MS,
        STRIKE_INDEX_LO,
        STRIKE_INDEX_HI,
        order::leverage_one_x() + 1,
        0,
        ONE_LOT_QTY,
        0,
    );
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidStrikeRange)]
fun new_swapped_finite_strike_range_aborts() {
    // Both sides finite -> require min < max strictly.
    order::new_from_strike_indices(
        OPENED_AT_MS,
        STRIKE_INDEX_HI,
        STRIKE_INDEX_LO,
        order::leverage_one_x(),
        0,
        ONE_LOT_QTY,
        0,
    );
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidStrikeRange)]
fun new_both_sides_open_aborts() {
    // (open, open] is rejected: the order would have no range at all.
    order::new_from_strike_indices(
        OPENED_AT_MS,
        order::open_strike_index(),
        order::open_strike_index(),
        order::leverage_one_x(),
        0,
        ONE_LOT_QTY,
        0,
    );
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidStrikeRange)]
fun new_leveraged_with_both_sides_finite_aborts() {
    // Leveraged orders must have exactly one side at the open sentinel.
    order::new_from_strike_indices(
        OPENED_AT_MS,
        STRIKE_INDEX_LO,
        STRIKE_INDEX_HI,
        order::leverage_two_x(),
        0,
        ONE_LOT_QTY,
        0,
    );
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidSequence)]
fun new_sequence_above_u40_aborts() {
    let above_u40: u64 = 1 << 40;
    order::new_from_strike_indices(
        OPENED_AT_MS,
        STRIKE_INDEX_LO,
        STRIKE_INDEX_HI,
        order::leverage_one_x(),
        0,
        ONE_LOT_QTY,
        above_u40,
    );
    abort 999
}

// === from_order_id validation ===

#[test, expected_failure(abort_code = order::EInvalidOrderId)]
fun from_order_id_with_bits_above_payload_aborts() {
    // Setting any bit above ORDER_ID_BITS=232 must be rejected.
    let bad_id: u256 = 1u256 << 232;
    order::from_order_id(bad_id);
    abort 999
}

// === liquidation priority ordering ===

#[test]
fun higher_leverage_order_id_sorts_first() {
    let high = order::new_from_strike_indices(
        OPENED_AT_MS,
        order::open_strike_index(),
        STRIKE_INDEX_HI,
        order::leverage_three_x(),
        500_000_000,
        ONE_LOT_QTY,
        0,
    );
    let low = order::new_from_strike_indices(
        OPENED_AT_MS,
        order::open_strike_index(),
        STRIKE_INDEX_HI,
        order::leverage_two_x(),
        500_000_000,
        ONE_LOT_QTY,
        0,
    );

    assert!(high.id() < low.id());
}

#[test]
fun larger_quantity_order_id_sorts_first_before_leverage() {
    let large = order::new_from_strike_indices(
        OPENED_AT_MS,
        order::open_strike_index(),
        STRIKE_INDEX_HI,
        order::leverage_two_x(),
        500_000_000,
        TWO_LOTS_QTY,
        0,
    );
    let small = order::new_from_strike_indices(
        OPENED_AT_MS,
        order::open_strike_index(),
        STRIKE_INDEX_HI,
        order::leverage_three_x(),
        500_000_000,
        ONE_LOT_QTY,
        0,
    );

    assert!(large.id() < small.id());
}

// === replacement ===

#[test]
fun replacement_inherits_terms_and_uses_new_sequence() {
    let original = order::new_from_strike_indices(
        OPENED_AT_MS,
        STRIKE_INDEX_LO,
        STRIKE_INDEX_HI,
        order::leverage_one_x(),
        500_000_000,
        TWO_LOTS_QTY,
        0,
    );
    let next_sequence = 1;
    let replaced = original.replacement(ONE_LOT_QTY, next_sequence);

    // Inherits the original strike range, leverage, entry probability, and open
    // time; only quantity and sequence change.
    assert_eq!(replaced.opened_at_ms(), original.opened_at_ms());
    assert_eq!(replaced.min_strike_index(), original.min_strike_index());
    assert_eq!(replaced.max_strike_index(), original.max_strike_index());
    assert_eq!(replaced.leverage(), original.leverage());
    assert_eq!(replaced.entry_probability(), original.entry_probability());
    assert_eq!(replaced.quantity(), ONE_LOT_QTY);
    assert_eq!(replaced.sequence(), next_sequence);
}

#[test, expected_failure(abort_code = order::EInvalidQuantity)]
fun replacement_at_or_above_original_quantity_aborts() {
    // Replacement quantity must be strictly less than original.
    let original = order::new_from_strike_indices(
        OPENED_AT_MS,
        STRIKE_INDEX_LO,
        STRIKE_INDEX_HI,
        order::leverage_one_x(),
        0,
        ONE_LOT_QTY,
        0,
    );
    let _ = original.replacement(ONE_LOT_QTY, 1);
    abort 999
}
