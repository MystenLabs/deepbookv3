// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Lattice construction, snapping, and apply/empty coverage for the inline
/// inventory-cell mirror. Economic charges live in `inventory_impact_tests`.
#[test_only]
module deepbook_predict::inventory_cells_tests;

use deepbook_predict::{constants, inventory_cells};
use fixed_math::math;
use std::unit_test::{assert_eq, destroy};

const LADDER_LOW: u64 = 90_000_000_000;
const LADDER_HIGH: u64 = 110_000_000_000;
const RANGE_LOW: u64 = 95_000_000_000;
const RANGE_HIGH: u64 = 105_000_000_000;
const QUANTITY: u64 = 1_000_000;

#[test]
fun an_open_line_covers_every_cell() {
    let cells = inventory_cells::new(LADDER_LOW, LADDER_HIGH);
    let (start, stop) = cells.cell_span(constants::neg_inf!(), constants::pos_inf!());
    assert_eq!(start, 0);
    assert_eq!(stop, inventory_cells::cell_count!());
    destroy(cells);
}

#[test]
fun apply_then_close_empties_the_mirror() {
    let mut cells = inventory_cells::new(LADDER_LOW, LADDER_HIGH);
    let (start, stop) = cells.cell_span(RANGE_LOW, RANGE_HIGH);
    assert!(stop > start);

    cells.apply_span(start, stop, QUANTITY, true);
    assert!(!cells.is_empty());
    assert_eq!(cells.cell_value(start), QUANTITY);
    assert_eq!(cells.cell_value(stop - 1), QUANTITY);
    assert_eq!(cells.span_max(start, stop, 0, 0, 0, true), QUANTITY);

    cells.apply_span(start, stop, QUANTITY, false);
    assert!(cells.is_empty());
    assert_eq!(cells.cell_value(start), 0);
    assert_eq!(cells.span_max(start, stop, 0, 0, 0, true), 0);
    destroy(cells);
}

#[test]
fun a_quoted_span_matches_the_committed_one() {
    let mut cells = inventory_cells::new(LADDER_LOW, LADDER_HIGH);
    let (start, stop) = cells.cell_span(RANGE_LOW, RANGE_HIGH);
    cells.apply_span(start, stop, QUANTITY, true);

    // Prospective max over the existing span plus a second equal order equals 2x.
    assert_eq!(cells.span_max(start, stop, start, stop, QUANTITY, true), QUANTITY + QUANTITY);
    cells.apply_span(start, stop, QUANTITY, true);
    assert_eq!(cells.span_max(start, stop, 0, 0, 0, true), QUANTITY + QUANTITY);
    destroy(cells);
}

#[test]
fun a_boundary_price_indexes_back_to_itself() {
    let cells = inventory_cells::new(LADDER_LOW, LADDER_HIGH);
    let index = inventory_cells::cell_count!() / 2;
    let price = cells.boundary_price_for_testing(index);
    assert_eq!(cells.boundary_index(price), index);
    destroy(cells);
}

#[test]
fun a_logged_price_indexes_the_same_cell_as_the_raw_price() {
    let cells = inventory_cells::new(LADDER_LOW, LADDER_HIGH);
    let index = inventory_cells::cell_count!() / 2;
    let price = cells.boundary_price_for_testing(index);
    assert_eq!(cells.boundary_index_from_ln(&math::ln(price)), cells.boundary_index(price));
    destroy(cells);
}

#[test, expected_failure(abort_code = inventory_cells::EInvalidCellSpan)]
fun lattice_rejects_an_open_lower_end() {
    destroy(inventory_cells::new(constants::neg_inf!(), LADDER_HIGH));
}

#[test, expected_failure(abort_code = inventory_cells::EInvalidCellSpan)]
fun lattice_rejects_an_open_upper_end() {
    destroy(inventory_cells::new(LADDER_LOW, constants::pos_inf!()));
}

#[test, expected_failure(abort_code = inventory_cells::EInvalidCellSpan)]
fun lattice_rejects_a_non_increasing_span() {
    destroy(inventory_cells::new(LADDER_HIGH, LADDER_LOW));
}
