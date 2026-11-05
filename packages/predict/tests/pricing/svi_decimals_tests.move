// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A Propbook SVI store at 18 decimals (P-33): Predict reads `a` and `b` at the 1e18 they arrive at,
/// so an exactly scaled slice prices bit for bit as at 9 decimals, and a final-seconds slice whose
/// `a` and minimum-variance increment each round below one raw unit at 1e9 loads and prices to
/// true math instead of aborting the load. The SVI cache a fill reads is pinned at its own inputs:
/// what it returns, what it refuses, and what it evicts.
///
/// References are the adjusted digital `Phi(d2) - phi(d2) * w' / (2 sqrt(w))` in Python stdlib math,
/// at a forward of 1.0 so only `ln(strike)` carries a raw-unit error; budgets come from the pricing
/// reference generator's `up_error_budget` (`tests/helper/reference/generate_pricing_reference.py`).
#[test_only]
module deepbook_predict::svi_decimals_tests;

use deepbook_predict::{
    constants,
    oracle_fixture::{Self, OracleBundle, OracleFixture},
    pricing::{Self, EBlockScholesMinVarianceInvalid, PricingSVI, VolSnapshot},
    pricing_ssvi_reference_data as ssvi,
    range_codec::strike_for_testing as strike,
    test_constants,
    test_helpers
};
use fixed_math::i64;
use std::unit_test::assert_eq;

const HIGH_PRECISION_DECIMALS: u8 = 18;
const SCALE: u128 = 1_000_000_000;
const UNIT_FORWARD: u64 = 1_000_000_000;

// A slice 1e9 cannot carry: `a = 0.4e-9` and `b * sigma = 1e-5 * 4e-5 = 0.4e-9`, so at 1e9 `a`
// rounds to zero and the floored increment is zero, while the true minimum variance is 0.8e-9.
const SUB_UNIT_A_1E18: u128 = 400_000_000;
const SUB_UNIT_B_1E9: u64 = 10_000;
const SUB_UNIT_SIGMA_1E9: u64 = 40_000;
/// `UP` at the forward and at `exp(-+sqrt(w0))` on the sub-unit slice, each with its error budget:
/// `generate_pricing_reference.up_error_budget` plus its 2-unit cushion, with `d_k = 0` at the forward
/// (`ln(1) = 0` exactly) and `d_k = 1e-7 * |ln(strike)| + 2e-9` either side, the generators' model.
const SUB_UNIT_AT_FORWARD: u64 = 499_994_358;
const SUB_UNIT_AT_FORWARD_BUDGET: u64 = 7_077;
const STRIKE_BELOW: u64 = 999_971_716;
const SUB_UNIT_BELOW: u64 = 853_098_301;
const SUB_UNIT_BELOW_BUDGET: u64 = 39_962;
const STRIKE_ABOVE: u64 = 1_000_028_285;
const SUB_UNIT_ABOVE: u64 = 146_893_296;
const SUB_UNIT_ABOVE_BUDGET: u64 = 39_961;

const CACHE_SOURCE_MS: u64 = 120_000;
const CACHE_CAPACITY: u64 = 64;
const PRECISE_A_1E18: u128 = 1_400_000_000;
const B_1E9: u64 = 10_000;
const SIGMA_1E9: u64 = 1_000_000;

// === Loads at 18 decimals ===

/// The decimals choose the scale Predict reads, not how it prices: a slice signed at 18 decimals as
/// the exact 1e9 multiples of a 9-decimal slice prices to the same raw units at every point.
#[test]
fun an_exactly_scaled_slice_prices_bit_for_bit_at_eighteen_decimals() {
    let s = ssvi::smallest_sigma_slice();
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    let ts = seed_unit_forward(&mut fx, &mut oracle, test_constants::now_ms() + 1);
    fx.set_bs_svi_for_testing_bundle(
        &mut oracle,
        ts,
        ssvi::svi_a_magnitude(s),
        ssvi::svi_a_is_negative(s),
        ssvi::svi_b(s),
        ssvi::svi_sigma(s),
        ssvi::svi_rho_magnitude(s),
        ssvi::svi_rho_is_negative(s),
        ssvi::svi_m_magnitude(s),
        ssvi::svi_m_is_negative(s),
    );
    let at_nine = fx.load_pricer_bundle(&oracle);

    fx.set_bs_svi_decimals_bundle(&mut oracle, HIGH_PRECISION_DECIMALS);
    let ts = seed_unit_forward(&mut fx, &mut oracle, ts + 1);
    fx.set_bs_svi_wide_for_testing_bundle(
        &mut oracle,
        ts,
        widen(ssvi::svi_a_magnitude(s)),
        ssvi::svi_a_is_negative(s),
        widen(ssvi::svi_b(s)),
        widen(ssvi::svi_sigma(s)),
        widen(ssvi::svi_rho_magnitude(s)),
        ssvi::svi_rho_is_negative(s),
        widen(ssvi::svi_m_magnitude(s)),
        ssvi::svi_m_is_negative(s),
    );
    let at_eighteen = fx.load_pricer_bundle(&oracle);

    ssvi::unit_forward_points(s).do_ref!(|p| {
        assert_eq!(
            at_eighteen.range_price(strike(p.lower()), strike(p.higher())).probability(),
            at_nine.range_price(strike(p.lower()), strike(p.higher())).probability(),
        );
    });

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// At 9 decimals the sub-unit slice arrives as `a = 0` with an increment that floors to zero, so
/// the load gate refuses it: the final-seconds abort the 18-decimal store removes.
#[test, expected_failure(abort_code = EBlockScholesMinVarianceInvalid, location = pricing)]
fun a_sub_unit_slice_at_nine_decimals_aborts_the_load() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    let ts = seed_unit_forward(&mut fx, &mut oracle, test_constants::now_ms() + 1);
    fx.set_bs_svi_for_testing_bundle(
        &mut oracle,
        ts,
        0,
        false,
        SUB_UNIT_B_1E9,
        SUB_UNIT_SIGMA_1E9,
        0,
        false,
        0,
        false,
    );

    let _pricer = fx.load_pricer_bundle(&oracle);

    abort
}

/// The same slice at 18 decimals loads, and prices to true math at the forward and a total
/// standard deviation either side.
#[test]
fun a_sub_unit_slice_at_eighteen_decimals_loads_and_prices_to_true_math() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.set_bs_svi_decimals_bundle(&mut oracle, HIGH_PRECISION_DECIMALS);
    let ts = seed_unit_forward(&mut fx, &mut oracle, test_constants::now_ms() + 1);
    fx.set_bs_svi_wide_for_testing_bundle(
        &mut oracle,
        ts,
        SUB_UNIT_A_1E18,
        false,
        widen(SUB_UNIT_B_1E9),
        widen(SUB_UNIT_SIGMA_1E9),
        0,
        false,
        0,
        false,
    );

    let pricer = fx.load_pricer_bundle(&oracle);
    test_helpers::assert_within(
        up(&pricer, UNIT_FORWARD),
        SUB_UNIT_AT_FORWARD,
        SUB_UNIT_AT_FORWARD_BUDGET,
    );
    test_helpers::assert_within(up(&pricer, STRIKE_BELOW), SUB_UNIT_BELOW, SUB_UNIT_BELOW_BUDGET);
    test_helpers::assert_within(up(&pricer, STRIKE_ABOVE), SUB_UNIT_ABOVE, SUB_UNIT_ABOVE_BUDGET);

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// At 18 decimals the gate checks the snapshot's own rounded values at 1e18, so every admitted
/// snapshot can price without its cached tuple. `a = 0.4e-9` with `b = 0` has positive variance at
/// 1e18 but rounds to an all-zero snapshot, so the load refuses it rather than admit an order a
/// cache miss could not fill.
#[test, expected_failure(abort_code = EBlockScholesMinVarianceInvalid, location = pricing)]
fun a_slice_that_only_prices_at_1e18_is_refused_at_eighteen_decimals() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.set_bs_svi_decimals_bundle(&mut oracle, HIGH_PRECISION_DECIMALS);
    let ts = seed_unit_forward(&mut fx, &mut oracle, test_constants::now_ms() + 1);
    fx.set_bs_svi_wide_for_testing_bundle(
        &mut oracle,
        ts,
        SUB_UNIT_A_1E18,
        false,
        0,
        widen(SUB_UNIT_SIGMA_1E9),
        0,
        false,
        0,
        false,
    );

    let _pricer = fx.load_pricer_bundle(&oracle);

    abort
}

/// At 18 decimals the gate also checks the stored 1e18 tuple every live price uses. `a = -0.4e-9`
/// rounds to zero, so the snapshot's own values pass, but with `b * sigma = 1e-10` the true minimum
/// variance is `-3e-10`, and the load refuses it.
#[test, expected_failure(abort_code = EBlockScholesMinVarianceInvalid, location = pricing)]
fun a_slice_whose_true_minimum_is_negative_is_refused_at_eighteen_decimals() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.set_bs_svi_decimals_bundle(&mut oracle, HIGH_PRECISION_DECIMALS);
    let ts = seed_unit_forward(&mut fx, &mut oracle, test_constants::now_ms() + 1);
    fx.set_bs_svi_wide_for_testing_bundle(
        &mut oracle,
        ts,
        SUB_UNIT_A_1E18,
        true,
        widen(SUB_UNIT_B_1E9),
        widen(SUB_UNIT_B_1E9),
        0,
        false,
        0,
        false,
    );

    let _pricer = fx.load_pricer_bundle(&oracle);

    abort
}

// === SVI cache ===

/// A tuple from another surface that shares a source time and rounds to the snapshot's `a` and `b`
/// is not the snapshot's calibration: its `rho`, `m`, and `sigma` differ, so the fill keeps the
/// snapshot's own values rather than pair either shape with the other's `a` and `b`.
#[test]
fun a_tuple_from_another_surface_is_not_used() {
    let mut market_uid = object::new(&mut tx_context::dummy());
    let other_shape = pricing::new_pricing_svi_for_testing(
        PRECISE_A_1E18,
        false,
        (B_1E9 as u128) * SCALE,
        i64::from_parts(300_000_000, true),
        i64::from_parts(25_000_000, false),
        2 * SIGMA_1E9,
    );
    pricing::keep_svi_for_testing(&mut market_uid, &snapshot(CACHE_SOURCE_MS), other_shape);

    assert_eq!(pricing::svi_for_testing(&market_uid, &snapshot(CACHE_SOURCE_MS)), own());
    market_uid.delete();
}

#[test]
fun a_recorded_tuple_prices_its_snapshot() {
    let mut market_uid = object::new(&mut tx_context::dummy());
    pricing::keep_svi_for_testing(&mut market_uid, &snapshot(CACHE_SOURCE_MS), precise());

    assert_eq!(pricing::svi_for_testing(&market_uid, &snapshot(CACHE_SOURCE_MS)), precise());
    market_uid.delete();
}

/// A market that never cached a tuple prices every snapshot on its own `a` and `b` at 1e18.
#[test]
fun without_a_cache_a_snapshot_prices_on_its_own_values() {
    let market_uid = object::new(&mut tx_context::dummy());

    assert_eq!(pricing::svi_for_testing(&market_uid, &snapshot(CACHE_SOURCE_MS)), own());
    market_uid.delete();
}

/// A snapshot from another publication never takes a recorded tuple, even with the same 1e9 values.
#[test]
fun a_tuple_from_another_publication_is_not_used() {
    let mut market_uid = object::new(&mut tx_context::dummy());
    pricing::keep_svi_for_testing(&mut market_uid, &snapshot(CACHE_SOURCE_MS), precise());

    assert_eq!(pricing::svi_for_testing(&market_uid, &snapshot(CACHE_SOURCE_MS + 1)), own());
    market_uid.delete();
}

/// A tuple whose `a` or `b` does not round to the snapshot's own is not that snapshot's tuple.
#[test]
fun a_tuple_that_does_not_round_to_the_snapshot_is_not_used() {
    let mut market_uid = object::new(&mut tx_context::dummy());
    let other_a = svi_with(2_400_000_000, B_1E9);
    let other_b = svi_with(PRECISE_A_1E18, B_1E9 + 1);
    pricing::keep_svi_for_testing(&mut market_uid, &snapshot(CACHE_SOURCE_MS), other_a);
    pricing::keep_svi_for_testing(&mut market_uid, &snapshot(CACHE_SOURCE_MS + 1), other_b);

    assert_eq!(pricing::svi_for_testing(&market_uid, &snapshot(CACHE_SOURCE_MS)), own());
    assert_eq!(pricing::svi_for_testing(&market_uid, &snapshot(CACHE_SOURCE_MS + 1)), own());
    market_uid.delete();
}

/// Recording a publication's tuple again does not grow the cache, and the entry still prices.
#[test]
fun recording_the_same_tuple_again_keeps_one_entry() {
    let mut market_uid = object::new(&mut tx_context::dummy());
    pricing::keep_svi_for_testing(&mut market_uid, &snapshot(CACHE_SOURCE_MS), precise());
    pricing::keep_svi_for_testing(&mut market_uid, &snapshot(CACHE_SOURCE_MS), precise());

    assert_eq!(pricing::svi_cache_length_for_testing(&market_uid), 1);
    assert_eq!(pricing::svi_for_testing(&market_uid, &snapshot(CACHE_SOURCE_MS)), precise());
    market_uid.delete();
}

/// Two different calibrations under one source time, as an SVI model switch can bring, round to the
/// same snapshot here (`a = 1.4e-9` and `a = 1.2e-9` both round to one raw unit). Neither can be told
/// apart from the snapshot, so the publication is held by neither and every order on it prices from
/// its own 1e9 values, rather than one surface's order filling at the other's precision.
#[test]
fun a_second_calibration_under_one_publication_is_held_by_neither() {
    let mut market_uid = object::new(&mut tx_context::dummy());
    pricing::keep_svi_for_testing(&mut market_uid, &snapshot(CACHE_SOURCE_MS), precise());
    pricing::keep_svi_for_testing(
        &mut market_uid,
        &snapshot(CACHE_SOURCE_MS),
        svi_with(1_200_000_000, B_1E9),
    );
    pricing::keep_svi_for_testing(&mut market_uid, &snapshot(CACHE_SOURCE_MS), precise());

    assert_eq!(pricing::svi_cache_length_for_testing(&market_uid), 1);
    assert_eq!(pricing::svi_for_testing(&market_uid, &snapshot(CACHE_SOURCE_MS)), own());
    market_uid.delete();
}

/// A slightly negative `a` rounds to a snapshot `a` of zero, which `i64::from_parts` makes
/// nonnegative, so the cached tuple, whose sign is negative, still matches its own snapshot.
#[test]
fun a_negative_a_that_rounds_to_zero_matches_its_snapshot() {
    let mut market_uid = object::new(&mut tx_context::dummy());
    let negative = pricing::new_pricing_svi_for_testing(
        400_000_000,
        true,
        (B_1E9 as u128) * SCALE,
        i64::zero(),
        i64::zero(),
        SIGMA_1E9,
    );
    let rounds_to_zero = pricing::new_vol_snapshot_for_testing(
        test_constants::pyth_feed_id(),
        UNIT_FORWARD,
        UNIT_FORWARD,
        i64::from_parts(0, true),
        B_1E9,
        i64::zero(),
        i64::zero(),
        SIGMA_1E9,
        CACHE_SOURCE_MS,
        CACHE_SOURCE_MS,
        CACHE_SOURCE_MS,
    );
    pricing::keep_svi_for_testing(&mut market_uid, &rounds_to_zero, negative);

    assert_eq!(pricing::svi_for_testing(&market_uid, &rounds_to_zero), negative);
    market_uid.delete();
}

/// Past capacity the oldest publication goes first, and its snapshot prices on its own values.
#[test]
fun the_oldest_entry_is_evicted_past_capacity() {
    let mut market_uid = object::new(&mut tx_context::dummy());
    let mut i = 0;
    while (i <= CACHE_CAPACITY) {
        pricing::keep_svi_for_testing(&mut market_uid, &snapshot(CACHE_SOURCE_MS + i), precise());
        i = i + 1;
    };

    assert_eq!(pricing::svi_cache_length_for_testing(&market_uid), CACHE_CAPACITY);
    assert_eq!(pricing::svi_for_testing(&market_uid, &snapshot(CACHE_SOURCE_MS)), own());
    assert_eq!(
        pricing::svi_for_testing(&market_uid, &snapshot(CACHE_SOURCE_MS + CACHE_CAPACITY)),
        precise(),
    );
    market_uid.delete();
}

// === Helpers ===

/// Seed spot, forward and Pyth at 1.0 at `ts`, move the clock there, and return `ts` for the SVI
/// row, so the load prices unrolled.
fun seed_unit_forward(fx: &mut OracleFixture, oracle: &mut OracleBundle, ts: u64): u64 {
    fx.set_clock_for_testing(ts);
    fx.set_pyth_bundle(oracle, UNIT_FORWARD, ts);
    fx.set_bs_spot_for_testing_bundle(oracle, ts, UNIT_FORWARD);
    fx.set_bs_forward_for_testing_bundle(oracle, ts, UNIT_FORWARD);
    ts
}

fun up(pricer: &pricing::Pricer, lower: u64): u64 {
    pricer.range_price(strike(lower), strike(constants::pos_inf!())).probability()
}

fun widen(value: u64): u128 {
    (value as u128) * SCALE
}

/// A snapshot whose `a` is one raw unit and `b` is `B_1E9` at 1e9, published at `svi_source_timestamp_ms`.
fun snapshot(svi_source_timestamp_ms: u64): VolSnapshot {
    pricing::new_vol_snapshot_for_testing(
        test_constants::pyth_feed_id(),
        UNIT_FORWARD,
        UNIT_FORWARD,
        i64::from_parts(1, false),
        B_1E9,
        i64::zero(),
        i64::zero(),
        SIGMA_1E9,
        svi_source_timestamp_ms,
        svi_source_timestamp_ms,
        svi_source_timestamp_ms,
    )
}

/// `snapshot`'s full-precision form: `a = 1.4e-9`, which rounds to its one raw unit.
fun precise(): PricingSVI {
    svi_with(PRECISE_A_1E18, B_1E9)
}

/// `snapshot`'s own `a` and `b` scaled to 1e18.
fun own(): PricingSVI {
    svi_with((1 as u128) * SCALE, B_1E9)
}

fun svi_with(a_1e18: u128, b_1e9: u64): PricingSVI {
    pricing::new_pricing_svi_for_testing(
        a_1e18,
        false,
        (b_1e9 as u128) * SCALE,
        i64::zero(),
        i64::zero(),
        SIGMA_1E9,
    )
}
