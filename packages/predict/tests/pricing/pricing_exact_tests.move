// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Exact-value coverage for `pricing::Pricer` range prices over REAL on-chain
/// Block Scholes SVI scenarios.
///
/// The structural tests in `pricing_tests.move` only pin invariants that
/// algebraically cancel the actual digital probability (complementarity,
/// whole-line, monotonicity), so the real skew-adjusted digital VALUE is untested
/// there. This file pins that value: per scenario it stands up a production-valid
/// oracle, seeds the real SVI + spot/forward through the Block Scholes surface
/// update, and asserts each live range price matches an INDEPENDENT true-math
/// reference (Python stdlib `erf`, NOT the contract and NOT `python_replay`'s
/// fixed-point pricer) within a per-point, analytically-derived precision budget.
/// Inputs, references, budgets, and provenance live in the committed, generated
/// `pricing_reference_data` module
/// (regenerate with `tests/helper/reference/generate_pricing_reference.py`).
///
/// Precision contract (see the generator header for the full derivation): each
/// tolerance is the worst-case absolute fixed-point error of `UP = N(d2) -
/// phi(d2)*w'(k)/(2*sqrt(w))`, propagated from `math.move`'s documented
/// per-primitive budgets (ln <= 1e-7 rel, sqrt/mul/div <= 1 ULP, normal_cdf <=
/// 2e-8 abs, normal_pdf <= 50 units) at the TRUE values. The worst case over all
/// scenarios/strikes is `pricing_reference_data::worst_case_budget()`, dominated
/// by small-variance points where both `d2 = -(k + w/2)/sqrt(w)` and the skew term's
/// `1/sqrt(w)` denominator amplify fixed-point variance and slope dust. Far-wing
/// strikes hit the normal CDF/PDF clamps and are EXACT (tolerance = 2-unit cushion).
#[test_only]
module deepbook_predict::pricing_exact_tests;

use deepbook_predict::{
    constants,
    oracle_fixture,
    pricing,
    pricing_reference_data as ref_data,
    range_codec::strike_for_testing as strike,
    test_constants,
    test_helpers
};
use fixed_math::math;
use std::unit_test::assert_eq;

const SKEW_CLAMP_SVI_A: u64 = 1;
const SKEW_CLAMP_SVI_B: u64 = 100_000_000_000;
const SKEW_CLAMP_RHO_UNIT: u64 = 1_000_000_000;
const SKEW_CLAMP_M: u64 = 0;
const SKEW_CLAMP_SIGMA: u64 = 1_000_000;
const FLAT_SVI_A: u64 = 1;
const FLAT_SVI_B: u64 = 0;
// Phi(-sqrt(1e-9)/2) * 1e9 — the true at-the-forward digital on the flat surface
// above, from `0.5*(1+erf(d2/sqrt(2)))` in Python's stdlib.
const FLAT_FORWARD_UP_REFERENCE: u64 = 499_993_692;

/// Stand up a production-valid oracle for real scenario `s`, seed its real SVI +
/// spot/forward, and assert `Pricer.range_price` matches the independent
/// true-math reference within the per-point derived budget at every reference point.
fun run_scenario(s: u64) {
    let mut fx = oracle_fixture::setup_oracle(
        ref_data::creation_spot(s),
        ref_data::tick_size(s),
        test_constants::default_expiry_ms(),
    );
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        ref_data::spot(s),
        ref_data::forward(s),
        ref_data::svi_a(s),
        false,
        ref_data::svi_b(s),
        ref_data::svi_sigma(s),
        ref_data::svi_rho_magnitude(s),
        ref_data::svi_rho_is_negative(s),
        ref_data::svi_m_magnitude(s),
        ref_data::svi_m_is_negative(s),
    );
    let pricer = fx.load_pricer_bundle(&oracle);

    let points = ref_data::points(s);
    let n = points.length();
    let mut i = 0;
    while (i < n) {
        let p = &points[i];
        let actual = pricer.range_price(strike(p.lower()), strike(p.higher()));
        test_helpers::assert_within(actual, p.reference(), p.tolerance());
        i = i + 1;
    };

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

#[test]
fun real_scenario_large_variance() { run_scenario(0); }

#[test]
fun real_scenario_medium_variance() { run_scenario(1); }

#[test]
fun real_scenario_small_variance() { run_scenario(2); }

#[test]
fun positive_svi_slope_clamps_adjusted_digital_to_zero() {
    assert_eq!(skew_clamp_up_price(false), 0);
}

#[test]
fun negative_svi_slope_clamps_adjusted_digital_to_one() {
    assert_eq!(skew_clamp_up_price(true), math::float_scaling!());
}

/// The flat-surface at-the-forward digital, and the only test that drives the
/// exact-zero slope branch (`b == 0` makes `w' == 0` identically).
///
/// With `a` at one fixed-point ulp and `b == 0`, `w == 1e-9` at every strike, and
/// spot == forward gives `k == 0`, so the true digital is
/// `Phi(-sqrt(w)/2) = 0.49999369217` — about 6,308 raw units BELOW one half.
/// It is not exactly one half: an at-the-forward digital is only balanced in the
/// zero-variance limit, and positive variance always shades it down.
#[test]
fun flat_surface_at_the_forward_matches_true_math() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        FLAT_SVI_A,
        false,
        FLAT_SVI_B,
        test_constants::default_svi_sigma(),
        test_constants::default_svi_rho_magnitude(),
        false,
        test_constants::default_svi_m(),
        false,
    );
    let pricer = fx.load_pricer_bundle(&oracle);

    let up = pricer.range_price(
        strike(test_constants::default_live_price()),
        strike(constants::pos_inf!()),
    );
    // Phi(-sqrt(1e-9)/2) at 1e9, from Python's stdlib erf (independent of the
    // contract's Cody rational approximation). Budget: `normal_cdf` is documented
    // to 20 raw units, and the d2 path adds under 1 more (the 1e18 variance and
    // its 1e9-scaled root together move d2 by ~6e-10, i.e. ~0.25 raw units of
    // probability), so 21 units bounds it.
    test_helpers::assert_within(up, FLAT_FORWARD_UP_REFERENCE, 21);

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// Production-valid SVI envelope point where strike == forward, m == 0, |rho| == 1,
/// b == max_svi_input, and sigma == min_svi_sigma. Then d2 is near -0.158, so the
/// normal CDF/PDF tail guards do not fire; the enormous signed `w'` term is what
/// pushes the raw adjusted digital outside [0, 1] and exercises compute_nd2's final
/// clamp.
fun skew_clamp_up_price(rho_is_negative: bool): u64 {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        SKEW_CLAMP_SVI_A,
        false,
        SKEW_CLAMP_SVI_B,
        SKEW_CLAMP_SIGMA,
        SKEW_CLAMP_RHO_UNIT,
        rho_is_negative,
        SKEW_CLAMP_M,
        false,
    );
    let pricer = fx.load_pricer_bundle(&oracle);
    let up = pricer.range_price(
        strike(test_constants::default_live_price()),
        strike(constants::pos_inf!()),
    );

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
    up
}
