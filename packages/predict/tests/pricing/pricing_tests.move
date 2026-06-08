// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Live binary-pricing invariants for `pricing::live_range_probability`, driven
/// through the minimal `oracle_fixture`.
///
/// These assert EXACT structural invariants that need no precision budget:
///   - complementarity: P([-inf, X]) + P([X, +inf]) == 1 exactly (the shared
///     up(X) term cancels in `lower_up - higher_up`), for any finite X;
///   - whole-line: P([-inf, +inf]) == 1;
///   - monotonicity: the digital "above X" probability is non-increasing in X.
/// The interior binary value (Φ(d2)) carries fixed-point approximation error and
/// is intentionally NOT asserted here (that needs the documented precision budget
/// against an independent scipy reference — a separate, careful pass).
#[test_only]
module deepbook_predict::pricing_tests;

use deepbook_predict::{constants::{Self, float_scaling as float}, oracle_fixture, pricing};
use std::unit_test::assert_eq;

const FORWARD: u64 = 100_000_000_000; // default_live_price; spot==forward, basis 1.0
const STRIKE_BELOW: u64 = 90_000_000_000;
const STRIKE_ABOVE: u64 = 110_000_000_000;

#[test]
fun complementary_ranges_sum_to_one_at_the_forward() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let (mut pyth, mut oracle, config) = fx.take_oracle();
    fx.prepare_live_oracle(&config, &mut oracle, &mut pyth, FORWARD);

    let below = pricing::live_range_probability(
        config.pricing_config(),
        &oracle,
        &pyth,
        constants::neg_inf!(),
        FORWARD,
        fx.clock(),
    );
    let above = pricing::live_range_probability(
        config.pricing_config(),
        &oracle,
        &pyth,
        FORWARD,
        constants::pos_inf!(),
        fx.clock(),
    );

    // Exact: the partition of the real line sums to probability 1.
    assert_eq!(below + above, float!());
    // Non-trivial: a finite at-the-forward strike splits strictly inside (0, 1).
    assert!(above > 0);
    assert!(above < float!());

    oracle_fixture::return_oracle(pyth, oracle, config);
    fx.finish();
}

#[test]
fun whole_line_range_is_certain() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let (mut pyth, mut oracle, config) = fx.take_oracle();
    fx.prepare_live_oracle(&config, &mut oracle, &mut pyth, FORWARD);

    let whole = pricing::live_range_probability(
        config.pricing_config(),
        &oracle,
        &pyth,
        constants::neg_inf!(),
        constants::pos_inf!(),
        fx.clock(),
    );
    assert_eq!(whole, float!());

    oracle_fixture::return_oracle(pyth, oracle, config);
    fx.finish();
}

#[test]
fun digital_above_probability_is_non_increasing_in_strike() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let (mut pyth, mut oracle, config) = fx.take_oracle();
    fx.prepare_live_oracle(&config, &mut oracle, &mut pyth, FORWARD);

    // P(price > X) must be non-increasing as X rises: a higher strike is less
    // likely to be exceeded.
    let above_low = pricing::live_range_probability(
        config.pricing_config(),
        &oracle,
        &pyth,
        STRIKE_BELOW,
        constants::pos_inf!(),
        fx.clock(),
    );
    let above_high = pricing::live_range_probability(
        config.pricing_config(),
        &oracle,
        &pyth,
        STRIKE_ABOVE,
        constants::pos_inf!(),
        fx.clock(),
    );
    assert!(above_low >= above_high);
    // And strictly so straddling the forward with this curve.
    assert!(above_low > above_high);

    oracle_fixture::return_oracle(pyth, oracle, config);
    fx.finish();
}
