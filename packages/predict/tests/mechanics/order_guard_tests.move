// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Reachable packed-order and replacement validation guards.
#[test_only]
module deepbook_predict::mechanics_order_guard_tests;

use deepbook_predict::{constants, order};

const VALID_QUANTITY: u64 = 70_000;
const LOWER_TICK: u64 = 3;
const HIGHER_TICK: u64 = 7;
const FIRST_SEQUENCE: u64 = 1;
const SECOND_SEQUENCE: u64 = 2;
const U40_LIMIT: u64 = 1_099_511_627_776;
const ORDER_ID_BITS: u8 = 196;
const NEG_INF_TICK: u64 = 0;
const ZERO_FLOOR_SHARES: u64 = 0;
const ZERO_QUANTITY: u64 = 0;
const RAW_UNIT: u64 = 1;
const ONE_U256: u256 = 1;
const ZERO_QUANTITY_ID: u256 = 100433627766186892221372630770055012060951232579776664305752;
const FLOOR_ABOVE_QUANTITY_ID: u256 = 100433627742802866024078171401022401854968459896752986652760;
const EQUAL_RANGE_ID: u256 = 100433627742802866024078184078796054742213070748151388831832;

#[test, expected_failure(abort_code = order::EInvalidQuantity)]
fun zero_quantity_aborts() {
    order::assert_valid_quantity(ZERO_QUANTITY);
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidQuantity)]
fun non_lot_quantity_aborts() {
    order::assert_valid_quantity(constants::position_lot_size!() + RAW_UNIT);
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidQuantity)]
fun max_quantity_plus_one_lot_aborts() {
    order::assert_valid_quantity(
        (order::max_quantity_lots() + RAW_UNIT) * constants::position_lot_size!(),
    );
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidTick)]
fun tick_above_domain_aborts() {
    order::new_from_ticks(
        RAW_UNIT,
        constants::pos_inf_tick!() + RAW_UNIT,
        ZERO_FLOOR_SHARES,
        VALID_QUANTITY,
        FIRST_SEQUENCE,
    );
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidRange)]
fun equal_range_aborts() {
    order::new_from_ticks(
        HIGHER_TICK,
        HIGHER_TICK,
        ZERO_FLOOR_SHARES,
        VALID_QUANTITY,
        FIRST_SEQUENCE,
    );
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidRange)]
fun full_open_range_aborts() {
    order::new_from_ticks(
        NEG_INF_TICK,
        constants::pos_inf_tick!(),
        ZERO_FLOOR_SHARES,
        VALID_QUANTITY,
        FIRST_SEQUENCE,
    );
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidFloorShares)]
fun floor_above_quantity_aborts() {
    order::new_from_ticks(
        LOWER_TICK,
        HIGHER_TICK,
        VALID_QUANTITY + RAW_UNIT,
        VALID_QUANTITY,
        FIRST_SEQUENCE,
    );
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidSequence)]
fun sequence_above_domain_aborts() {
    order::new_from_ticks(
        LOWER_TICK,
        HIGHER_TICK,
        ZERO_FLOOR_SHARES,
        VALID_QUANTITY,
        U40_LIMIT,
    );
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidOrderId)]
fun packed_high_bit_aborts() {
    order::from_order_id(ONE_U256 << ORDER_ID_BITS);
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidQuantity)]
fun packed_zero_quantity_aborts() {
    order::from_order_id(ZERO_QUANTITY_ID);
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidFloorShares)]
fun packed_floor_above_quantity_aborts() {
    order::from_order_id(FLOOR_ABOVE_QUANTITY_ID);
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidRange)]
fun packed_equal_range_aborts() {
    order::from_order_id(EQUAL_RANGE_ID);
    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidQuantity)]
fun replacement_requires_strictly_lower_quantity() {
    let order = order::new_from_ticks(
        LOWER_TICK,
        HIGHER_TICK,
        ZERO_FLOOR_SHARES,
        VALID_QUANTITY,
        FIRST_SEQUENCE,
    );
    order.replacement(VALID_QUANTITY, ZERO_FLOOR_SHARES, SECOND_SEQUENCE);
    abort 999
}
