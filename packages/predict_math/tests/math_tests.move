// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// `math::order_terms` against order IDs packed by hand from Predict's order-ID
/// layout: lots at bit 100, the lower tick at bit 70, the higher tick at bit 40,
/// and the sequence in the low 40 bits.
#[test_only]
module deepbook_predict_math::math_tests;

use deepbook_predict_math::math;
use std::unit_test::assert_eq;

const LOWER_TICK: u64 = 100;
const HIGHER_TICK: u64 = 110;
/// 400 lots of 10_000 units.
const LOTS: u64 = 400;
const QUANTITY: u64 = 4_000_000;
const SEQUENCE: u64 = 7;
/// The open-ended sentinels: tick 0 below, `2^30 - 1` above.
const POS_INF_TICK: u64 = 1_073_741_823;
/// The widest lot field, `2^32 - 1` lots.
const MAX_LOTS: u64 = 4_294_967_295;
const MAX_QUANTITY: u64 = 42_949_672_950_000;

#[test]
fun order_terms_decodes_a_packed_order_id() {
    let order_id =
        ((LOTS as u256) << 100) | ((LOWER_TICK as u256) << 70)
        | ((HIGHER_TICK as u256) << 40) | (SEQUENCE as u256);
    let (lower, higher, quantity) = math::order_terms(order_id);
    assert_eq!(lower, LOWER_TICK);
    assert_eq!(higher, HIGHER_TICK);
    assert_eq!(quantity, QUANTITY);
}

/// The sentinel ticks and the widest lot count decode without bleeding into the
/// neighbouring fields.
#[test]
fun order_terms_decodes_the_field_extremes() {
    let order_id =
        ((MAX_LOTS as u256) << 100) | ((POS_INF_TICK as u256) << 40)
        | (((1u256 << 40) - 1));
    let (lower, higher, quantity) = math::order_terms(order_id);
    assert_eq!(lower, 0);
    assert_eq!(higher, POS_INF_TICK);
    assert_eq!(quantity, MAX_QUANTITY);
}
