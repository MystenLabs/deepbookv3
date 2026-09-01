// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage for create-time strike-band padding and inversion.
#[test_only]
module deepbook_predict::strike_band_tests;

use deepbook_predict::{
    config_constants,
    constants,
    oracle_fixture,
    range_codec,
    strike_band,
    test_constants
};
use fixed_math::math;
use std::unit_test::assert_eq;

/// Independently padded 1.25x belly around $80–$120:
/// padded_low = 80e9 * 1e9 / 1.25e9 = 64e9
/// padded_high = 120e9 * 1.25e9 / 1e9 = 150e9
/// span = 86e9; ceil(86e9 / 899) = 95_661_847; align-ceil to 10_000 = 95_670_000
/// floor(64e9 / 95_670_000) = 668, but 1_567 * 95_670_000 = 149_914_890_000
/// is short of 150e9, so tick_size grows to ceil(150e9 / 1_567) = 95_724_314
/// and align-ceil to 10_000 = 95_730_000. Then min_tick = floor(64e9 / 95_730_000) = 668
/// and 1_567 * 95_730_000 = 150_008_910_000 covers 150e9.
const K_LOW: u64 = 80_000_000_000;
const K_HIGH: u64 = 120_000_000_000;
const BELLY_PAD_1_25: u64 = 1_250_000_000;
const MIN_TICK_SIZE: u64 = 1_000_000_000;
const PADDED_TICK_SIZE: u64 = 95_730_000;
const PADDED_MIN_TICK: u64 = 668;
const PADDED_MAX_RAW: u64 = 150_008_910_000;
const MIN_TICK_SIZE_MIN_TICK: u64 = 64;
const ONE_PCT: u64 = 10_000_000;
const NINETY_NINE_PCT: u64 = 990_000_000;
const EUnexpectedSuccess: u64 = 999;

#[test]
fun from_inverted_strikes_pads_and_aligns_independently() {
    let band = strike_band::from_inverted_strikes(K_LOW, K_HIGH, BELLY_PAD_1_25, MIN_TICK_SIZE);
    // Cadence tick size $1 is coarser than the aligned 95_670_000, so the floor wins.
    assert_eq!(band.tick_size(), MIN_TICK_SIZE);
    assert_eq!(band.min_tick(), MIN_TICK_SIZE_MIN_TICK);
    assert_eq!(constants::max_tick_in_band!(band.min_tick()), MIN_TICK_SIZE_MIN_TICK + 899);
}

#[test]
fun from_inverted_strikes_uses_derived_size_when_finer_than_floor() {
    // Unit floor (10_000) is below the aligned derived size, so the derived size sticks.
    let band = strike_band::from_inverted_strikes(
        K_LOW,
        K_HIGH,
        BELLY_PAD_1_25,
        constants::market_tick_size_unit!(),
    );
    assert_eq!(band.tick_size(), PADDED_TICK_SIZE);
    assert_eq!(band.min_tick(), PADDED_MIN_TICK);
    // Window high covers the independently padded $150: 1_567 * 95_730_000.
    assert_eq!(
        (band.min_tick() + constants::max_unique_strike_ticks!() - 1) * band.tick_size(),
        PADDED_MAX_RAW,
    );
}

#[test]
fun cadence_band_starts_at_tick_one() {
    let band = strike_band::cadence_band(MIN_TICK_SIZE);
    assert_eq!(band.tick_size(), MIN_TICK_SIZE);
    assert_eq!(band.min_tick(), 1);
}

#[test, expected_failure(abort_code = strike_band::EInvalidStrikeBand)]
fun from_inverted_strikes_zero_pad_aborts() {
    strike_band::from_inverted_strikes(K_LOW, K_HIGH, 0, MIN_TICK_SIZE);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = strike_band::EInvalidStrikeBand)]
fun from_inverted_strikes_inverted_bounds_aborts() {
    strike_band::from_inverted_strikes(K_HIGH, K_LOW, BELLY_PAD_1_25, MIN_TICK_SIZE);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = config_constants::EInvalidBellyPad)]
fun from_inverted_strikes_pad_below_one_aborts() {
    strike_band::from_inverted_strikes(K_LOW, K_HIGH, 500_000_000, MIN_TICK_SIZE);
    abort EUnexpectedSuccess
}

#[test]
fun invert_up_price_le_is_the_left_edge_of_the_target() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    let pricer = fx.load_pricer_bundle(&oracle);

    let k_99 = strike_band::invert_up_price_le(&pricer, NINETY_NINE_PCT);
    assert!(pricer.up_price(range_codec::strike_from_raw(k_99)) <= NINETY_NINE_PCT);
    if (k_99 > 1) {
        assert!(pricer.up_price(range_codec::strike_from_raw(k_99 - 1)) > NINETY_NINE_PCT);
    };

    let k_01 = strike_band::invert_up_price_le(&pricer, ONE_PCT);
    assert!(pricer.up_price(range_codec::strike_from_raw(k_01)) <= ONE_PCT);
    assert!(k_01 > k_99);
    if (k_01 > 1) {
        assert!(pricer.up_price(range_codec::strike_from_raw(k_01 - 1)) > ONE_PCT);
    };

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

#[test, expected_failure(abort_code = strike_band::ECannotInvertStrikeBand)]
fun invert_up_price_le_zero_target_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    let pricer = fx.load_pricer_bundle(&oracle);
    strike_band::invert_up_price_le(&pricer, 0);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = strike_band::ECannotInvertStrikeBand)]
fun invert_up_price_le_unit_target_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    let pricer = fx.load_pricer_bundle(&oracle);
    strike_band::invert_up_price_le(&pricer, math::float_scaling!());
    abort EUnexpectedSuccess
}
