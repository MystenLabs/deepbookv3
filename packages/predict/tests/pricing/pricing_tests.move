// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Live binary-pricing invariants for `pricing::live_range_probability`, driven
/// through the minimal `oracle_fixture`.
///
/// These assert EXACT structural invariants that need no precision budget:
///   - complementarity: P([-inf, X]) + P([X, +inf]) == 1 exactly (the shared
///     up(X) term cancels in `lower_up - higher_up`), for any finite X;
///   - whole-line: P([-inf, +inf]) == 1;
///   - monotonicity: the digital "above X" probability is non-increasing in X;
///   - forward-source selection: the live forward is Pyth-spot-based exactly
///     while Pyth is fresh (inclusive boundary) and falls back to the stored
///     Block Scholes forward one millisecond later.
/// The interior binary value (Φ(d2)) carries fixed-point approximation error and
/// is intentionally NOT asserted here (that needs the documented precision budget
/// against an independent scipy reference — a separate, careful pass).
#[test_only]
module deepbook_predict::pricing_tests;

use deepbook_predict::{constants, oracle_fixture, pricing, test_constants};
use predict_math::math::float_scaling as float;
use std::unit_test::assert_eq;

// Forward == `default_live_price` (spot==forward, basis 1.0). The two scenario
// strikes straddle it.
const STRIKE_BELOW: u64 = 90_000_000_000;
const STRIKE_ABOVE: u64 = 110_000_000_000;

/// A Pyth print diverged +2% from the 100e9 Block Scholes spot/forward.
/// Production-reachable: `pyth_source::update_from_lazer` applies no deviation
/// cap against the Block Scholes data.
const DIVERGED_PYTH_SPOT: u64 = 102_000_000_000;

#[test]
fun complementary_ranges_sum_to_one_at_the_forward() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let (mut pyth, mut oracle, config) = fx.take_oracle();
    fx.prepare_live_oracle(&config, &mut oracle, &mut pyth, test_constants::default_live_price());

    let below = pricing::live_range_probability(
        config.pricing_config(),
        &oracle,
        &pyth,
        constants::neg_inf!(),
        test_constants::default_live_price(),
        fx.clock(),
    );
    let above = pricing::live_range_probability(
        config.pricing_config(),
        &oracle,
        &pyth,
        test_constants::default_live_price(),
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
    fx.prepare_live_oracle(&config, &mut oracle, &mut pyth, test_constants::default_live_price());

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
    fx.prepare_live_oracle(&config, &mut oracle, &mut pyth, test_constants::default_live_price());

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

/// Decision-pinned: the live forward switches source exactly at the Pyth
/// staleness boundary (`pricing::live_inputs`, fallback documented in-code).
/// While Pyth is fresh — inclusive: `now − freshness_ts == max_age` — the
/// forward is `mul(pyth_spot, basis)`; one millisecond later, with ZERO
/// oracle-data change, it is the stored Block Scholes forward. With a +2%
/// diverged Pyth print the mark therefore jumps 2% discontinuously on a 1 ms
/// clock advance — accepted behavior, pinned so any future smoothing
/// (blending, hysteresis) is an explicit decision.
#[test]
fun live_forward_switches_source_exactly_at_pyth_staleness_boundary() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let (mut pyth, mut oracle, config) = fx.take_oracle();
    // Block Scholes spot = forward = 100e9, so basis = div(100e9, 100e9) = 1.0
    // exactly; all three sources stamped at live_source_timestamp_ms = 99_000.
    fx.prepare_live_oracle(&config, &mut oracle, &mut pyth, test_constants::default_live_price());
    // Overwrite only the Pyth print with the diverged spot at the same source
    // timestamp (freshness uses min(source, update) = 99_000).
    fx.set_pyth(&mut pyth, DIVERGED_PYTH_SPOT, test_constants::live_source_timestamp_ms());

    // The stale-Pyth/fresh-Block-Scholes window exists because the Pyth budget
    // (default 2_000 ms) is strictly shorter than the BS price budget (3_000 ms).
    let pyth_budget = config.pricing_config().pyth_spot_freshness_ms();
    assert!(pyth_budget < config.pricing_config().block_scholes_prices_freshness_ms());

    // AT the boundary (now − 99_000 == budget): Pyth is fresh (inclusive), so
    // forward = mul(102e9, 1.0) = floor(102e9 * 1e9 / 1e9) = 102e9 exactly.
    fx.set_clock_for_testing(test_constants::live_source_timestamp_ms() + pyth_budget);
    let (forward_fresh, _) = pricing::live_inputs(
        config.pricing_config(),
        &oracle,
        &pyth,
        fx.clock(),
    );
    assert_eq!(forward_fresh, DIVERGED_PYTH_SPOT);

    // ONE ms past the boundary: Pyth is stale, BS prices/SVI still fresh, so
    // the forward falls back to the stored Block Scholes forward = 100e9.
    fx.set_clock_for_testing(test_constants::live_source_timestamp_ms() + pyth_budget + 1);
    let (forward_stale, _) = pricing::live_inputs(
        config.pricing_config(),
        &oracle,
        &pyth,
        fx.clock(),
    );
    assert_eq!(forward_stale, test_constants::default_live_price());

    oracle_fixture::return_oracle(pyth, oracle, config);
    fx.finish();
}
