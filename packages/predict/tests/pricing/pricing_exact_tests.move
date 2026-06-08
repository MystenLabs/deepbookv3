// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Exact-value coverage for `pricing::live_range_probability` over REAL on-chain
/// Block Scholes SVI scenarios.
///
/// The structural tests in `pricing_tests.move` only pin invariants that
/// algebraically cancel the actual digital probability (complementarity,
/// whole-line, monotonicity), so the real `Phi(d2)` VALUE is untested there. This
/// file pins that value: per scenario it stands up a production-valid oracle, seeds
/// the real SVI + spot/forward through the cap path, and asserts each live range
/// price matches an INDEPENDENT true-math reference (Python stdlib `erf`, NOT the
/// contract and NOT `python_replay`'s fixed-point pricer) within a per-point,
/// analytically-derived precision budget. Inputs, references, budgets, and
/// provenance live in the committed, generated `pricing_reference_data` module
/// (regenerate with `tests/helper/reference/generate_pricing_reference.py`).
///
/// Precision contract (see the generator header for the full derivation): each
/// tolerance is the worst-case absolute fixed-point error of `UP = Phi(d2)`,
/// propagated from `math.move`'s documented per-primitive budgets (ln <= 1e-7 rel,
/// sqrt/mul/div <= 1 ULP, normal_cdf <= 2e-8 abs) at the TRUE values. The worst case
/// over all scenarios/strikes is `pricing_reference_data::worst_case_budget()` =
/// 2_401 units (2.4e-6), dominated by the small-variance (near-expiry) scenario at
/// |d2| ~ 1, where `d2 = -(k + w/2)/sqrt(w)` is ill-conditioned in `w` (a `w^-3/2`
/// sensitivity): a 1-ULP variance rounding there moves the quote ~1e-6. Far-wing
/// strikes hit the `normal_cdf` clamp and are EXACT (tolerance = 2-unit cushion).
#[test_only]
module deepbook_predict::pricing_exact_tests;

use deepbook_predict::{
    constants,
    oracle_fixture,
    pricing,
    pricing_reference_data as ref_data,
    test_constants,
    test_helpers
};
use predict_math::math;
use std::unit_test::assert_eq;

/// Stand up a production-valid oracle for real scenario `s`, seed its real SVI +
/// spot/forward, and assert `live_range_probability` matches the independent
/// true-math reference within the per-point derived budget at every reference point.
fun run_scenario(s: u64) {
    let mut fx = oracle_fixture::setup_oracle(
        ref_data::creation_spot(s),
        ref_data::tick_size(s),
        test_constants::default_expiry_ms(),
    );
    let (mut pyth, mut oracle, config) = fx.take_oracle();
    fx.prepare_real_oracle(
        &config,
        &mut oracle,
        &mut pyth,
        ref_data::spot(s),
        ref_data::forward(s),
        ref_data::svi(s),
    );

    let points = ref_data::points(s);
    let n = points.length();
    let mut i = 0;
    while (i < n) {
        let p = &points[i];
        let actual = pricing::live_range_probability(
            config.pricing_config(),
            &oracle,
            &pyth,
            p.lower(),
            p.higher(),
            fx.clock(),
        );
        test_helpers::assert_within(actual, p.reference(), p.tolerance());
        i = i + 1;
    };

    oracle_fixture::return_oracle(pyth, oracle, config);
    fx.finish();
}

#[test]
fun real_scenario_large_variance() { run_scenario(0); }

#[test]
fun real_scenario_medium_variance() { run_scenario(1); }

#[test]
fun real_scenario_small_variance() { run_scenario(2); }

/// The single exact (`assert_eq!`) anchor. On the flat default fixture (degenerate
/// SVI, spot == forward), the at-the-forward digital has `d2 == 0` exactly, so
/// `Phi(d2) == 0.5 == 500_000_000`. This is the one point where the binary price is
/// representable exactly; every real-scenario point above is an interior value that
/// carries fundamental fixed-point error and so uses `assert_within`.
#[test]
fun at_the_forward_is_exactly_one_half() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let (mut pyth, mut oracle, config) = fx.take_oracle();
    fx.prepare_live_oracle(&config, &mut oracle, &mut pyth, test_constants::default_live_price());

    let up = pricing::live_range_probability(
        config.pricing_config(),
        &oracle,
        &pyth,
        test_constants::default_live_price(),
        constants::pos_inf!(),
        fx.clock(),
    );
    // 0.5 in FLOAT_SCALING: a perfectly balanced at-the-forward digital.
    assert_eq!(up, math::float_scaling!() / 2);

    oracle_fixture::return_oracle(pyth, oracle, config);
    fx.finish();
}
