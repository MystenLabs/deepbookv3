// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Live binary-pricing invariants for `pricing::Pricer`, driven through the
/// minimal `oracle_fixture`.
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
use fixed_math::math::float_scaling as float;
use std::unit_test::assert_eq;

// Forward == `default_live_price` (spot==forward, basis 1.0). The two scenario
// strikes straddle it.
const STRIKE_BELOW: u64 = 90_000_000_000;
const STRIKE_ABOVE: u64 = 110_000_000_000;

/// A Pyth print diverged +2% from the 100e9 Block Scholes spot/forward.
/// Production-reachable: the Pyth feed applies no deviation cap against the
/// Block Scholes surface, so the live forward tracks the diverged spot.
const DIVERGED_PYTH_SPOT: u64 = 102_000_000_000;

/// Source timestamp for the diverged Pyth print. Strictly newer than the bootstrap
/// tick's `live_source_timestamp_ms` (99_000) so the feed accepts the overwrite
/// (`store_tick_if_fresh` requires a strictly newer source), yet old enough that
/// its `freshness_ts + pyth_budget` boundary stays inside the (longer) Block
/// Scholes surface window, so the post-staleness fallback is observable rather than
/// aborting on a stale surface.
const DIVERGED_PYTH_SOURCE_MS: u64 = 119_500;

#[test]
fun complementary_ranges_sum_to_one_at_the_forward() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let (mut pyth, mut bs, oracle_registry, config) = fx.take_oracle();
    fx.prepare_live_oracle(&mut bs, &mut pyth, test_constants::default_live_price());
    let pricer = fx.load_pricer(&config, &oracle_registry, &pyth, &bs);

    let below = pricer.range_price(
        constants::neg_inf!(),
        test_constants::default_live_price(),
    );
    let above = pricer.range_price(
        test_constants::default_live_price(),
        constants::pos_inf!(),
    );

    // Exact: the partition of the real line sums to probability 1.
    assert_eq!(below + above, float!());
    // Non-trivial: a finite at-the-forward strike splits strictly inside (0, 1).
    assert!(above > 0);
    assert!(above < float!());

    oracle_fixture::return_oracle(pyth, bs, oracle_registry, config);
    fx.finish();
}

#[test]
fun whole_line_range_is_certain() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let (mut pyth, mut bs, oracle_registry, config) = fx.take_oracle();
    fx.prepare_live_oracle(&mut bs, &mut pyth, test_constants::default_live_price());
    let pricer = fx.load_pricer(&config, &oracle_registry, &pyth, &bs);

    let whole = pricer.range_price(
        constants::neg_inf!(),
        constants::pos_inf!(),
    );
    assert_eq!(whole, float!());

    oracle_fixture::return_oracle(pyth, bs, oracle_registry, config);
    fx.finish();
}

#[test]
fun digital_above_probability_is_non_increasing_in_strike() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let (mut pyth, mut bs, oracle_registry, config) = fx.take_oracle();
    fx.prepare_live_oracle(&mut bs, &mut pyth, test_constants::default_live_price());
    let pricer = fx.load_pricer(&config, &oracle_registry, &pyth, &bs);

    // P(price > X) must be non-increasing as X rises: a higher strike is less
    // likely to be exceeded.
    let above_low = pricer.range_price(STRIKE_BELOW, constants::pos_inf!());
    let above_high = pricer.range_price(STRIKE_ABOVE, constants::pos_inf!());
    assert!(above_low >= above_high);
    // And strictly so straddling the forward with this curve.
    assert!(above_low > above_high);

    oracle_fixture::return_oracle(pyth, bs, oracle_registry, config);
    fx.finish();
}

/// Decision-pinned: the live forward switches source exactly at the Pyth
/// staleness boundary (`pricing::load_live_pricer`, fallback documented in-code).
/// While Pyth is fresh — inclusive: `now − freshness_ts == max_age` — the
/// forward is `mul(pyth_spot, basis)`; one millisecond later, with ZERO
/// oracle-data change, it is the stored Block Scholes forward. With a +2%
/// diverged Pyth print the mark therefore jumps 2% discontinuously on a 1 ms
/// clock advance — accepted behavior, pinned so any future smoothing
/// (blending, hysteresis) is an explicit decision.
#[test]
fun live_forward_switches_source_exactly_at_pyth_staleness_boundary() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let (mut pyth, mut bs, oracle_registry, config) = fx.take_oracle();
    // Block Scholes spot = forward = 100e9, so basis = div(100e9, 100e9) = 1.0
    // exactly; the surface freshness timestamp is min(99_000, landed) = 99_000.
    fx.prepare_live_oracle(&mut bs, &mut pyth, test_constants::default_live_price());
    // Overwrite only the Pyth print with the diverged spot at a strictly-newer
    // source timestamp (freshness uses min(source, update) = 99_500).
    fx.set_pyth(&mut pyth, DIVERGED_PYTH_SPOT, DIVERGED_PYTH_SOURCE_MS);

    // The stale-Pyth/fresh-Block-Scholes window exists because the Pyth budget
    // (default 2_000 ms) is strictly shorter than the BS surface budget (3_000 ms).
    let pyth_budget = config.pricing_config().pyth_spot_freshness_ms();
    assert!(pyth_budget < config.pricing_config().block_scholes_surface_freshness_ms());

    // AT the boundary (now − 99_500 == budget): Pyth is fresh (inclusive), so
    // forward = mul(102e9, 1.0) = floor(102e9 * 1e9 / 1e9) = 102e9 exactly.
    fx.set_clock_for_testing(DIVERGED_PYTH_SOURCE_MS + pyth_budget);
    let pricer = fx.load_pricer(&config, &oracle_registry, &pyth, &bs);
    assert_eq!(pricer.up_price(DIVERGED_PYTH_SPOT), float!() / 2);

    // ONE ms past the boundary: Pyth is stale, the BS surface still fresh, so the
    // forward falls back to the stored Block Scholes forward = 100e9.
    fx.set_clock_for_testing(DIVERGED_PYTH_SOURCE_MS + pyth_budget + 1);
    let pricer = fx.load_pricer(&config, &oracle_registry, &pyth, &bs);
    assert_eq!(pricer.up_price(test_constants::default_live_price()), float!() / 2);
    assert_eq!(pricer.up_price(DIVERGED_PYTH_SPOT), 0);

    oracle_fixture::return_oracle(pyth, bs, oracle_registry, config);
    fx.finish();
}
