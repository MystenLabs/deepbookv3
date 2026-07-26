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
// `max_contract_price_deviation` is 1e6 at 1e9 scale, i.e. one part in a thousand.
const MINT_DEVIATION_DENOMINATOR: u64 = 1_000;
// Three-input re-anchor fixture: fresh Pyth spot != Block Scholes spot != forward.
// Expected forward = floor(pyth_spot * bs_forward / bs_spot)
//                  = floor(75_100e9 * 75_050e9 / 75_000e9) = 75_150_066_666_666.
const REANCHOR_BS_SPOT: u64 = 75_000_000_000_000;
const REANCHOR_BS_FORWARD: u64 = 75_050_000_000_000;
const REANCHOR_PYTH_SPOT: u64 = 75_100_000_000_000;
const REANCHOR_EXPECTED_FORWARD: u64 = 75_150_066_666_666;
const REANCHOR_PYTH_SOURCE_MS: u64 = 119_001;

/// The payout-tree tick a reference strike maps to. Infinity boundaries are never
/// tree nodes; the memo answers them from its own sentinels.
fun boundary_tick(reference_strike: u64, tick_size: u64): u64 {
    if (reference_strike == constants::neg_inf!()) return constants::neg_inf!();
    if (reference_strike == constants::pos_inf!()) return constants::pos_inf_tick!();
    reference_strike / tick_size
}

/// Every distinct finite boundary tick across a scenario's points, ascending —
/// the order `price_and_cache` requires, mirroring the in-order payout-tree walk.
fun ascending_finite_boundary_ticks(
    points: &vector<ref_data::RefPoint>,
    tick_size: u64,
): vector<u64> {
    let mut ticks = vector[];
    points.do_ref!(|p| {
        vector[p.lower(), p.higher()].do!(|reference_strike| {
            if (
                reference_strike == constants::neg_inf!()
                    || reference_strike == constants::pos_inf!()
            ) return;
            let tick = reference_strike / tick_size;
            let mut at = 0;
            while (at < ticks.length() && ticks[at] < tick) at = at + 1;
            if (at == ticks.length()) {
                ticks.push_back(tick)
            } else if (ticks[at] != tick) {
                ticks.insert(tick, at)
            };
        });
    });
    ticks
}

/// Stand up a production-valid oracle for real scenario `s`, seed its real SVI +
/// spot/forward, and assert `Pricer.range_price` matches its fixed-point regression
/// snapshot and the independent true-math reference within the per-point budget.
fun run_scenario(s: u64, enforce_mint_deviation: bool) {
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

    let tick_size = ref_data::tick_size(s);
    let points = ref_data::points(s);

    // Price every distinct finite boundary once, ascending, exactly as NAV's payout
    // walk does; `cached_range_price` then reads each point back the way NAV's
    // leveraged correction walk does. That is the production path the certified
    // price travels, so the certificate under test here is the one the protocol acts on.
    let mut memo = pricing::new_price_memo();
    let ticks = ascending_finite_boundary_ticks(&points, tick_size);
    ticks.do_ref!(|tick| { memo.price_and_cache(&pricer, *tick, tick_size); });

    let n = points.length();
    let mut i = 0;
    while (i < n) {
        let p = &points[i];
        let lower = strike(p.lower());
        let higher = strike(p.higher());
        let priced = memo.cached_range_price(
            boundary_tick(p.lower(), tick_size),
            boundary_tick(p.higher(), tick_size),
        );
        assert!(!priced.is_negative());
        assert!(priced.error() < std::u64::max_value!());
        let actual = priced.magnitude();
        assert_eq!(pricer.range_price(lower, higher), actual);
        assert_eq!(actual, p.expected_center());
        test_helpers::assert_within(actual, p.reference(), p.tolerance());
        test_helpers::assert_within(actual, p.reference_lower(), priced.error());
        test_helpers::assert_within(actual, p.reference_upper(), priced.error());
        if (enforce_mint_deviation) {
            // The production promise mint relies on: the admitted price is the same
            // center, and it really is within 0.1% of the independent reference.
            assert_eq!(pricer.admitted_range_price(lower, higher), actual);
            test_helpers::assert_within(
                actual,
                p.reference(),
                p.reference().divide_and_round_up(MINT_DEVIATION_DENOMINATOR),
            );
        };
        i = i + 1;
    };

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

#[test]
fun real_scenario_large_variance() { run_scenario(0, false); }

#[test]
fun real_scenario_medium_variance() { run_scenario(1, false); }

#[test]
fun real_scenario_small_variance() { run_scenario(2, false); }

/// This real one-minute SVI surface has w ~= 3.26e-8 at the selected strike.
/// Flooring `b * inner` to 1e9 before sqrt priced it about 3% below the independent
/// reference and produced a certificate above the 0.1% mint ceiling. Retaining
/// that one variance term through sqrt keeps both center and certificate in policy.
#[test]
fun real_short_dated_scenario_meets_mint_deviation() { run_scenario(3, true); }

/// Pin the three-input re-anchor when the fresh Pyth spot differs from the Block
/// Scholes spot. The flat SVI fixture has exactly 0.5 probability only at the
/// forward, so this observes the fused `pyth * bs_forward / bs_spot` result
/// without exposing `Pricer.forward`.
#[test]
fun unequal_spots_use_the_fused_live_forward() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        REANCHOR_BS_SPOT,
        REANCHOR_BS_FORWARD,
        FLAT_SVI_A,
        false,
        FLAT_SVI_B,
        test_constants::default_svi_sigma(),
        test_constants::default_svi_rho_magnitude(),
        false,
        test_constants::default_svi_m(),
        false,
    );
    fx.set_pyth_bundle(&mut oracle, REANCHOR_PYTH_SPOT, REANCHOR_PYTH_SOURCE_MS);
    let pricer = fx.load_pricer_bundle(&oracle);

    assert_eq!(
        pricer.range_price(
            strike(REANCHOR_EXPECTED_FORWARD),
            strike(constants::pos_inf!()),
        ),
        math::float_scaling!() / 2,
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

/// The single exact (`assert_eq!`) anchor. With `a` at one fixed-point ulp, `b == 0`,
/// and spot == forward, half the total variance truncates to zero, so `d2 == 0`;
/// the flat surface makes `w' == 0`. Therefore `Phi(d2) == 0.5 == 500_000_000`
/// exactly. This is the one point where the binary price is representable exactly;
/// every real-scenario point above carries fixed-point error and uses `assert_within`.
#[test]
fun at_the_forward_is_exactly_one_half() {
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
    // 0.5 in FLOAT_SCALING: a perfectly balanced at-the-forward digital.
    assert_eq!(up, math::float_scaling!() / 2);

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// Production-valid SVI envelope point where strike == forward, m == 0, |rho| == 1,
/// b == max_svi_input, and sigma == min_svi_sigma. Then d2 is near -0.158, so the
/// normal CDF/PDF tail guards do not fire; the enormous signed `w'` term is what
/// pushes the raw adjusted digital outside [0, 1] and exercises compute_up_price's final
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
