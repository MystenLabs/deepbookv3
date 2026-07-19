// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Exact packed-order layout, priority ordering, and replacement behavior.
#[test_only]
module deepbook_predict::scope_mechanics__intent_behavior__order_tests;

use deepbook_predict::{constants, order};
use std::unit_test::assert_eq;

// Independently packed from the documented 196-bit layout.
const LEVERAGED_ID: u256 = 100433627602498708840311440548712299381715794625565424627769;
const NONLEVERAGED_ID: u256 = 100433627485578577853839270474947524179424892805837616054360;
const LOWER_TICK: u64 = 3;
const HIGHER_TICK: u64 = 7;
const QUANTITY: u64 = 120_000;
const FLOOR_SHARES: u64 = 50_000;
const SEQUENCE: u64 = 12_345;
const NEG_INF_TICK: u64 = 0;
const ZERO_FLOOR_SHARES: u64 = 0;
const RAW_UNIT: u64 = 1;
const LEVERAGED_HIGHER_TICK: u64 = 100_001;
const LEVERAGED_QUANTITY_LOTS: u64 = 7;
const LEVERAGED_QUANTITY: u64 = 70_000;
const NONLEVERAGED_QUANTITY_LOTS: u64 = 12;
const NONLEVERAGED_SEQUENCE: u64 = 88;
const MAX_QUANTITY_LOTS: u64 = 4_294_967_295;
const MAX_SEQUENCE: u64 = 1_099_511_627_775;
const LOWER_PRIORITY_QUANTITY: u64 = 100_000;
const LOWER_PRIORITY_FLOOR: u64 = 10_000;
const HIGHER_PRIORITY_FLOOR: u64 = 20_000;
const REPLACEMENT_FLOOR: u64 = 40_000;
const FIRST_SEQUENCE: u64 = 1;
const SECOND_SEQUENCE: u64 = 2;
const FIRST_QUANTITY_LOT_COUNT: u64 = 1;

#[test]
fun independently_packed_ids_decode_every_field() {
    let leveraged = order::from_order_id(LEVERAGED_ID);
    assert_eq!(leveraged.id(), LEVERAGED_ID);
    assert_eq!(leveraged.lower_tick(), NEG_INF_TICK);
    assert_eq!(leveraged.higher_tick(), LEVERAGED_HIGHER_TICK);
    assert_eq!(leveraged.quantity_lots(), LEVERAGED_QUANTITY_LOTS);
    assert_eq!(leveraged.quantity(), LEVERAGED_QUANTITY);
    assert_eq!(leveraged.floor_shares(), FLOOR_SHARES);
    assert_eq!(leveraged.sequence(), SEQUENCE);
    assert!(leveraged.is_leveraged());

    let nonleveraged = order::from_order_id(NONLEVERAGED_ID);
    assert_eq!(nonleveraged.lower_tick(), LOWER_TICK);
    assert_eq!(nonleveraged.higher_tick(), HIGHER_TICK);
    assert_eq!(nonleveraged.quantity_lots(), NONLEVERAGED_QUANTITY_LOTS);
    assert_eq!(nonleveraged.quantity(), QUANTITY);
    assert_eq!(nonleveraged.floor_shares(), ZERO_FLOOR_SHARES);
    assert_eq!(nonleveraged.sequence(), NONLEVERAGED_SEQUENCE);
    assert!(!nonleveraged.is_leveraged());
}

#[test]
fun constructors_cover_max_quantity_and_both_open_ends() {
    let max_quantity = MAX_QUANTITY_LOTS * constants::position_lot_size!();
    let open_lower = order::new_from_ticks(
        NEG_INF_TICK,
        RAW_UNIT,
        max_quantity,
        max_quantity,
        MAX_SEQUENCE,
    );
    assert_eq!(open_lower.quantity_lots(), MAX_QUANTITY_LOTS);
    assert_eq!(open_lower.quantity(), max_quantity);
    assert_eq!(open_lower.floor_shares(), max_quantity);
    assert_eq!(open_lower.sequence(), MAX_SEQUENCE);
    assert_eq!(open_lower.lower_tick(), NEG_INF_TICK);
    assert_eq!(open_lower.higher_tick(), RAW_UNIT);

    let open_upper = order::new_from_ticks(
        constants::pos_inf_tick!() - RAW_UNIT,
        constants::pos_inf_tick!(),
        ZERO_FLOOR_SHARES,
        constants::position_lot_size!(),
        FIRST_SEQUENCE,
    );
    assert_eq!(open_upper.lower_tick(), constants::pos_inf_tick!() - RAW_UNIT);
    assert_eq!(open_upper.higher_tick(), constants::pos_inf_tick!());
    assert_eq!(open_upper.quantity_lots(), FIRST_QUANTITY_LOT_COUNT);
    assert_eq!(open_upper.quantity(), constants::position_lot_size!());
}

#[test]
fun larger_quantity_then_larger_floor_have_priority() {
    let lower_quantity = order::new_from_ticks(
        LOWER_TICK,
        HIGHER_TICK,
        ZERO_FLOOR_SHARES,
        LOWER_PRIORITY_QUANTITY,
        FIRST_SEQUENCE,
    );
    let higher_quantity = order::new_from_ticks(
        LOWER_TICK,
        HIGHER_TICK,
        ZERO_FLOOR_SHARES,
        QUANTITY,
        SECOND_SEQUENCE,
    );
    assert!(higher_quantity.id() < lower_quantity.id());

    let lower_floor = order::new_from_ticks(
        LOWER_TICK,
        HIGHER_TICK,
        LOWER_PRIORITY_FLOOR,
        QUANTITY,
        FIRST_SEQUENCE,
    );
    let higher_floor = order::new_from_ticks(
        LOWER_TICK,
        HIGHER_TICK,
        HIGHER_PRIORITY_FLOOR,
        QUANTITY,
        SECOND_SEQUENCE,
    );
    assert!(higher_floor.id() < lower_floor.id());
}

#[test]
fun replacement_inherits_range_and_replaces_mutable_terms() {
    let original = order::new_from_ticks(
        LOWER_TICK,
        HIGHER_TICK,
        FLOOR_SHARES,
        QUANTITY,
        FIRST_SEQUENCE,
    );
    let replacement = original.replacement(
        QUANTITY - constants::position_lot_size!(),
        REPLACEMENT_FLOOR,
        SECOND_SEQUENCE,
    );
    assert_eq!(replacement.lower_tick(), LOWER_TICK);
    assert_eq!(replacement.higher_tick(), HIGHER_TICK);
    assert_eq!(replacement.quantity(), QUANTITY - constants::position_lot_size!());
    assert_eq!(replacement.floor_shares(), REPLACEMENT_FLOOR);
    assert_eq!(replacement.sequence(), SECOND_SEQUENCE);
}
