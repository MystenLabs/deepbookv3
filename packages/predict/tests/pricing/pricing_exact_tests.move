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
///
/// Block Scholes SSVI slices whose `sigma` sits below 1e-3, and synthetic surfaces at
/// the relaxed bounds (`sigma` at its 1e-5 floor, `a` past the former `|a| <= 100`
/// cap), are checked against the generated `pricing_ssvi_reference_data` module
/// (`tests/helper/reference/generate_ssvi_reference.py`) twice: at each slice's real
/// forward, quoting the forward, where the contract's log-moneyness is exactly zero
/// and the budget carries no `ln` error; and with the same shape seeded at a forward
/// of 1.0, where only `ln(strike)` carries a raw-unit error, at strikes around the
/// smile (`unit_forward_points`).
#[test_only]
module deepbook_predict::pricing_exact_tests;

use deepbook_predict::{
    constants,
    oracle_fixture::{Self, OracleBundle, OracleFixture},
    pricing,
    pricing_reference_data as ref_data,
    pricing_ssvi_reference_data as ssvi,
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
        let actual = pricer.range_price(strike(p.lower()), strike(p.higher())).probability();
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

/// Check SSVI reference slice `s` both ways the generator prices it: at its real
/// forward (quoting the forward, where log-moneyness is exactly zero), then with
/// the same SVI shape re-seeded one millisecond later at a forward of 1.0 (quoting
/// strikes around the smile), so every series advances and the roll-down stays 1.
fun run_ssvi_slice(s: u64) {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    seed_ssvi_slice(&mut fx, &mut oracle, s, ssvi::spot(s), ssvi::forward(s));
    assert_ssvi_points(&mut fx, &oracle, ssvi::points(s));

    let unit_forward = ssvi::unit_forward();
    let reseeded_at_ms = test_constants::now_ms() + 1;
    fx.set_clock_for_testing(reseeded_at_ms);
    fx.set_pyth_bundle(&mut oracle, unit_forward, reseeded_at_ms);
    fx.set_bs_spot_for_testing_bundle(&mut oracle, reseeded_at_ms, unit_forward);
    fx.set_bs_forward_for_testing_bundle(&mut oracle, reseeded_at_ms, unit_forward);
    fx.set_bs_svi_for_testing_bundle(
        &mut oracle,
        reseeded_at_ms,
        ssvi::svi_a_magnitude(s),
        ssvi::svi_a_is_negative(s),
        ssvi::svi_b(s),
        ssvi::svi_sigma(s),
        ssvi::svi_rho_magnitude(s),
        ssvi::svi_rho_is_negative(s),
        ssvi::svi_m_magnitude(s),
        ssvi::svi_m_is_negative(s),
    );
    assert_ssvi_points(&mut fx, &oracle, ssvi::unit_forward_points(s));

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

fun assert_ssvi_points(
    fx: &mut OracleFixture,
    oracle: &OracleBundle,
    points: vector<ssvi::RefPoint>,
) {
    let pricer = fx.load_pricer_bundle(oracle);
    points.do_ref!(|p| {
        let actual = pricer.range_price(strike(p.lower()), strike(p.higher())).probability();
        test_helpers::assert_within(actual, p.reference(), p.tolerance());
    });
}

fun seed_ssvi_slice(
    fx: &mut OracleFixture,
    oracle: &mut OracleBundle,
    s: u64,
    spot: u64,
    forward: u64,
) {
    fx.prepare_real_oracle_bundle(
        oracle,
        spot,
        forward,
        ssvi::svi_a_magnitude(s),
        ssvi::svi_a_is_negative(s),
        ssvi::svi_b(s),
        ssvi::svi_sigma(s),
        ssvi::svi_rho_magnitude(s),
        ssvi::svi_rho_is_negative(s),
        ssvi::svi_m_magnitude(s),
        ssvi::svi_m_is_negative(s),
    );
}

#[test]
fun short_dated_slice_with_the_smallest_sigma_prices_to_true_math() {
    run_ssvi_slice(ssvi::smallest_sigma_slice());
}

/// `a` is negative and the rounded analytical minimum total variance is one raw
/// unit, the smallest the load gate admits and the tightest margin in the backfill.
#[test]
fun short_dated_slice_with_negative_a_prices_to_true_math() {
    run_ssvi_slice(ssvi::negative_a_slice());
}

/// The former 1e9 smile root floored `sigma^2` to three raw units here and missed
/// the at-the-forward digital by about 562_500 units.
#[test]
fun one_minute_slice_the_1e9_root_mispriced_prices_to_true_math() {
    run_ssvi_slice(ssvi::one_minute_root_miss_slice());
}

/// A slice two minutes from expiry.
#[test]
fun one_to_five_minute_slice_the_1e9_root_mispriced_prices_to_true_math() {
    run_ssvi_slice(ssvi::one_to_five_minute_root_miss_slice());
}

/// A slice eight minutes from expiry.
#[test]
fun sub_hour_slice_the_1e9_root_mispriced_prices_to_true_math() {
    run_ssvi_slice(ssvi::sub_hour_root_miss_slice());
}

/// `sigma` exactly at the 1e-5 floor with the smile's vertex at the forward: the
/// former 1e9 root was zero here, so the skew slope's division aborted.
#[test]
fun surface_at_the_sigma_floor_prices_at_its_vertex() {
    run_ssvi_slice(ssvi::floor_vertex_slice());
}

/// `k - m == -sigma` at the floor, so both squares under the root are a tenth of
/// a raw unit at 1e9 and only the 1e18 input represents either; the former root
/// was zero and the wing term went negative.
#[test]
fun surface_at_the_sigma_floor_prices_one_width_from_its_vertex() {
    run_ssvi_slice(ssvi::floor_one_width_slice());
}

/// `k - m == 10 * sigma` at the floor, where `(k - m)^2` dominates the root.
#[test]
fun surface_at_the_sigma_floor_prices_in_its_wing() {
    run_ssvi_slice(ssvi::floor_wing_slice());
}

/// `a = -150`, past the former `|a| <= 100` cap, offset by `b * sigma` at the
/// `sigma` ceiling: the minimum total variance is 6.8, the forward's about 10, and
/// the skew correction is live at every quoted strike.
#[test]
fun negative_svi_a_past_the_former_cap_prices_to_true_math() {
    run_ssvi_slice(ssvi::negative_a_past_cap_slice());
}

/// `a = 101`, just past the former cap, on a slice-[0] shape.
#[test]
fun positive_svi_a_past_the_former_cap_prices_to_true_math() {
    run_ssvi_slice(ssvi::positive_a_past_cap_slice());
}

/// RP-20's pin: the rounded minimum clears the load gate, and at the forward the
/// true total variance is 0.99993e-9 — under one raw unit at 1e9 — so the 1e18
/// variance path prices it where a variance floored to 1e9 would round to zero
/// and abort `ENonPositiveVariance`.
#[test]
fun low_variance_surface_prices_where_the_1e9_path_aborted() {
    run_ssvi_slice(ssvi::sub_unit_variance_slice());
}

/// The other side of the per-strike rounding boundary: the analytical minimum
/// clears the load gate by one raw unit (min_increment 3 against `a = -2`), and the
/// exact root makes the forward's total variance exactly one raw unit, so the
/// surface prices.
#[test]
fun one_raw_unit_variance_surface_prices_to_true_math() {
    run_ssvi_slice(ssvi::one_raw_unit_variance_slice());
}

/// `rho = -1`: the SVI increment's infimum over strikes is 0, so the minimum total
/// variance is `a` alone, and one raw unit of positive `a` is the smallest that
/// loads (`pricing_guard_tests` rejects `a = 0` and `a = -1` on the same shape).
#[test]
fun unit_rho_surface_with_one_unit_of_a_prices_to_true_math() {
    run_ssvi_slice(ssvi::unit_rho_slice());
}

/// A one-minute slice seeded a minute before expiry and priced three quarters of
/// the way there: `a` and `b` roll down to a quarter of their published values
/// while `sigma` stays put, so the small-`sigma` root meets rolled variance.
#[test]
fun rolled_down_short_dated_slice_prices_to_true_math() {
    let s = ssvi::rolled_slice();
    let mut fx = oracle_fixture::setup_oracle(
        ssvi::spot(s),
        test_constants::default_tick_size(),
        ssvi::rolled_expiry_ms(),
    );
    let mut oracle = fx.take_oracle_bundle();
    seed_ssvi_slice(&mut fx, &mut oracle, s, ssvi::spot(s), ssvi::forward(s));

    let priced_at_ms = ssvi::rolled_priced_at_ms();
    fx.set_clock_for_testing(priced_at_ms);
    fx.set_bs_spot_for_testing_bundle(&mut oracle, priced_at_ms, ssvi::spot(s));
    fx.set_bs_forward_for_testing_bundle(&mut oracle, priced_at_ms, ssvi::forward(s));
    let pricer = fx.load_pricer_bundle(&oracle);

    test_helpers::assert_within(
        pricer.up_price(strike(ssvi::forward(s))),
        ssvi::rolled_up_at_forward(),
        ssvi::rolled_budget(),
    );

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

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

    let up = pricer
        .range_price(
            strike(test_constants::default_live_price()),
            strike(constants::pos_inf!()),
        )
        .probability();
    // Phi(-sqrt(1e-9)/2) at 1e9, from Python's stdlib erf (independent of the
    // contract's Cody rational approximation). Budget: `normal_cdf` is documented
    // to 20 raw units, and the d2 path adds under 1 more (the 1e18 variance and
    // its 1e9-scaled root together move d2 by ~6e-10, i.e. ~0.25 raw units of
    // probability), so 21 units bounds it.
    test_helpers::assert_within(
        up,
        ref_data::flat_surface_atm_up(),
        ref_data::flat_surface_atm_budget(),
    );

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// Production-valid SVI envelope point where strike == forward, m == 0, |rho| == 1,
/// b == max_svi_input, and sigma == 1e-3. Then d2 is near -0.158, so the
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
    let up = pricer
        .range_price(
            strike(test_constants::default_live_price()),
            strike(constants::pos_inf!()),
        )
        .probability();

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
    up
}
