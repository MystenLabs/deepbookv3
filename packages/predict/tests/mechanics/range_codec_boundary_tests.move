// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Exact strike conversion and half-open settlement boundaries.
#[test_only]
module deepbook_predict::mechanics_range_codec_boundary_tests;

use deepbook_predict::{constants, range_codec};
use std::unit_test::assert_eq;

const RAW_UNIT: u64 = 1;
const NEG_INF_TICK: u64 = 0;
const TICK_SIZE: u64 = 1_000_000_000;
const FINITE_TICK: u64 = 100;
const FINITE_STRIKE: u64 = 100_000_000_000;
const PREFIX_TICK: u64 = 150;
const PREFIX_STRIKE: u64 = 150_000_000_000;
const LOWER_TICK: u64 = 100;
const HIGHER_TICK: u64 = 200;
const LOWER_STRIKE: u64 = 100_000_000_000;
const HIGHER_STRIKE: u64 = 200_000_000_000;

#[test]
fun sentinel_ticks_map_to_open_strikes() {
    let lower = range_codec::strike_from_tick(NEG_INF_TICK, TICK_SIZE);
    let upper = range_codec::strike_from_tick(constants::pos_inf_tick!(), TICK_SIZE);

    assert_eq!(lower.value(), constants::neg_inf!());
    assert!(lower.is_neg_inf());
    assert_eq!(upper.value(), constants::pos_inf!());
    assert!(upper.is_pos_inf());
}

#[test]
fun finite_ticks_scale_without_becoming_sentinels() {
    let strike = range_codec::strike_from_tick(FINITE_TICK, TICK_SIZE);
    let max_finite = range_codec::strike_from_tick(constants::pos_inf_tick!() - 1, TICK_SIZE);

    assert_eq!(strike.value(), FINITE_STRIKE);
    assert!(!strike.is_neg_inf());
    assert!(!strike.is_pos_inf());
    assert_eq!(max_finite.value(), (constants::pos_inf_tick!() - 1) * TICK_SIZE);
    assert!(!max_finite.is_pos_inf());
}

#[test]
fun prefix_limit_rounds_strict_settlement_boundary_up() {
    assert_eq!(range_codec::prefix_limit_tick(0, TICK_SIZE), 0);
    assert_eq!(range_codec::prefix_limit_tick(RAW_UNIT, TICK_SIZE), RAW_UNIT);
    assert_eq!(range_codec::prefix_limit_tick(PREFIX_STRIKE, TICK_SIZE), PREFIX_TICK);
    assert_eq!(
        range_codec::prefix_limit_tick(PREFIX_STRIKE + RAW_UNIT, TICK_SIZE),
        PREFIX_TICK + RAW_UNIT,
    );
}

#[test]
fun grid_tick_rounds_containing_interval_down() {
    assert_eq!(range_codec::grid_tick(RAW_UNIT, TICK_SIZE), 0);
    assert_eq!(range_codec::grid_tick(PREFIX_STRIKE - RAW_UNIT, TICK_SIZE), PREFIX_TICK - 1);
    assert_eq!(range_codec::grid_tick(PREFIX_STRIKE, TICK_SIZE), PREFIX_TICK);
    assert_eq!(range_codec::grid_tick(PREFIX_STRIKE + RAW_UNIT, TICK_SIZE), PREFIX_TICK);
}

#[test]
fun finite_settlement_range_is_open_lower_and_closed_higher() {
    assert!(
        !range_codec::settlement_in_range(
            LOWER_TICK,
            HIGHER_TICK,
            LOWER_STRIKE,
            TICK_SIZE,
        ),
    );
    assert!(
        range_codec::settlement_in_range(
            LOWER_TICK,
            HIGHER_TICK,
            LOWER_STRIKE + RAW_UNIT,
            TICK_SIZE,
        ),
    );
    assert!(
        range_codec::settlement_in_range(
            LOWER_TICK,
            HIGHER_TICK,
            HIGHER_STRIKE,
            TICK_SIZE,
        ),
    );
    assert!(
        !range_codec::settlement_in_range(
            LOWER_TICK,
            HIGHER_TICK,
            HIGHER_STRIKE + RAW_UNIT,
            TICK_SIZE,
        ),
    );
}

#[test]
fun open_upper_range_admits_values_beyond_finite_ladder() {
    assert!(
        !range_codec::settlement_in_range(
            LOWER_TICK,
            constants::pos_inf_tick!(),
            LOWER_STRIKE,
            TICK_SIZE,
        ),
    );
    assert!(
        range_codec::settlement_in_range(
            LOWER_TICK,
            constants::pos_inf_tick!(),
            std::u64::max_value!(),
            TICK_SIZE,
        ),
    );
}
