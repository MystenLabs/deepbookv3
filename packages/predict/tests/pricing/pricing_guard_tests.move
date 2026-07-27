// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Guard coverage for `pricing.move`'s live quote path.
///
/// Two abort surfaces are exercised through the production-valid `oracle_fixture`
/// bring-up:
///   - `EInvalidRange`: a degenerate range (`lower == higher`) after freshness
///     passes;
///   - `EBlockScholesPriceStale`: a hard staleness abort when one of the split
///     Block Scholes price feeds is past its configured freshness window.
/// The old deep-ITM/deep-OTM aborts (`EInvalidStrikeRatio`) are gone: the price
/// tail now SATURATES instead of aborting, so those are pinned here as exact-value
/// tests (deep-ITM up tail -> 1.0, deep-OTM up tail -> 0). A stale Pyth spot no
/// longer aborts either — it falls back to the stored Block Scholes forward; that
/// fallback is pinned with exact values in
/// `pricing_tests::live_forward_switches_source_exactly_at_pyth_staleness_boundary`,
/// so it is not duplicated here.
///
/// The `assert_inputs_pricing_safe` envelope rejects (`EBlockScholesInputsInvalid`)
/// is covered here too: one test per reachable branch seeds a surface that violates
/// exactly that bound (`forward` ceiling, `basis`, `a` magnitude, `b`, `rho`, `m`,
/// `sigma`), leaving every other input default so only the targeted branch fires.
/// The `spot == 0` / `forward == 0` branch of that assert is unreachable through
/// `load_live_pricer`: the split Block Scholes feed reads drop a zero spot or zero
/// forward upstream, so the read arrives as `none` and pricing aborts on absence
/// (-> `EBlockScholesPriceUnavailable`) before any staleness check runs. Those two
/// conditions are defensive-only and not tested here. `EBlockScholesMinVarianceInvalid`
/// covers surfaces whose analytical minimum total variance is non-positive,
/// including negative `a` values that over-offset the SVI increment and the
/// degenerate `a == 0, b == 0` surface. `EZeroForward` is reached via a pyth spot
/// far below the BS spot (no LOWER basis bound), where the re-anchored
/// `spot * bs_forward / bs_spot` floors to 0. `ENonPositiveVariance` is pinned by
/// a boundary surface whose rounded analytical minimum is positive at load but
/// whose concrete at-forward quote rounds total variance non-positive, and by a
/// production-valid unchanged tuple whose remaining-time roll-down reaches zero
/// one millisecond before expiry.
/// `ECannotBeNegative` inside `compute_nd2` remains a defensive backstop after
/// the load-time envelope: no production input is known to reach it.
/// `ETickNotInPriceMemo` is a package-level cache contract guard and is covered
/// directly below; active-book non-monotone UP prices are covered by
/// `ENonMonotonePriceMemo`.
#[test_only]
module deepbook_predict::pricing_guard_tests;

use deepbook_predict::{
    constants,
    oracle_fixture::{Self, OracleBundle, OracleFixture},
    pricing,
    pricing_reference_data as ref_data,
    range_codec::strike_for_testing as strike,
    test_constants,
    test_helpers
};
use fixed_math::{i64, math::float_scaling as float};
use propbook::{
    block_scholes_forward_feed::BlockScholesForwardFeed,
    block_scholes_svi_feed::BlockScholesSVIFeed,
    registry::{Self as propbook_registry, OracleRegistry}
};
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

const EUnexpectedSuccess: u64 = 999;
const SECOND_SOURCE_ID: u32 = 2;

/// A strike so far below the forward that `strike * 1e9 / forward` truncates to 0,
/// hitting the deep-ITM saturation branch (the neg_inf limit). With the default
/// forward (100e9) the threshold is `forward / 1e9 == 100`, so strike 1 saturates.
const DEEP_ITM_STRIKE: u64 = 1;

/// A finite (non-`pos_inf`) strike so far above a tiny forward that
/// `strike * 1e9 / forward` exceeds `u64::MAX`, hitting the deep-OTM saturation
/// branch (the pos_inf limit). With forward 1 this needs `strike > ~1.8446e10`.
const DEEP_OTM_STRIKE: u64 = 1_000_000_000_000_000_000;
// Independent copies of `pricing.move`'s private pricing-safe envelope (the macros
// are module-private, so the bounds are reproduced here from the source, not read).
// The basis ceiling (100 * 1e9) is exercised by computing `spot * 101` directly.
const MAX_PRICING_SPOT: u64 = 184_467_440_737_095_516; // u64::MAX / 100
const PRICE_MEMO_MISSING_TICK: u64 = 100;
const NEGATIVE_SVI_A_MAG: u64 = 1_000_000;
const POSITIVE_MIN_VARIANCE_SVI_B: u64 = 10_000_000;
const POSITIVE_MIN_VARIANCE_SIGMA: u64 = 500_000_000;
const NEGATIVE_A_AT_FORWARD_REFERENCE: u64 = 487_386_440;
const NONPOSITIVE_MIN_VARIANCE_A_MAG: u64 = 5_000_001;
/// A surface whose per-strike total variance is positive but under one raw unit
/// at 1e9: `b * inner` is 2_999_999_000 at 1e18 and `a` is -2, so the 1e9 path
/// saw exactly zero while the true variance is 1e-9. `min_increment` is 3, so
/// `min_total_var` is 1 and the surface loads.
const ADMITTED_LOW_VARIANCE_A_MAG: u64 = 2;
const ADMITTED_LOW_VARIANCE_B: u64 = 1_000;
const ADMITTED_LOW_VARIANCE_SIGMA: u64 = 5_000_000;
const ADMITTED_LOW_VARIANCE_RHO: u64 = 800_000_000;
const ADMITTED_LOW_VARIANCE_M: u64 = 6_666_634;

/// `normal_cdf` and `normal_pdf` saturate beyond `|8|`; the cap sits one raw unit
/// past that so a capped value is unambiguously outside the live domain.
const SATURATED_D2_MAGNITUDE: u64 = 8_000_000_001;
/// w = 1e-9 at 1e18 (`b * inner / 1e9` = 1e9), the smallest variance the load gate
/// can admit: sqrt(w) is 31_622 and d2 stays far inside the cap. `b` is the rolled
/// 1e18 form, so raw b = 1_000 arrives as 1_000 * 1e9.
const WELL_CONDITIONED_B_1E18: u128 = 1_000_000_000_000;
const WELL_CONDITIONED_INNER: u64 = 1_000_000;
const WELL_CONDITIONED_SQRT_W: u64 = 31_622;
/// The smallest representable variance: `b * inner / 1e9` = 1 raw unit at 1e18.
const MINIMAL_B_1E18: u128 = 1_000_000_000;
const MINIMAL_INNER: u64 = 1;

/// A loadable surface (`|rho| == 1e9` zeroes min_increment, so it clears the gate
/// on `a` alone) whose skew correction is live and whose small `sqrt(w)` amplifies
/// it, separating the 1e18 and 1e9 forms of `w'`. `m` is negative.
const W_PRIME_SURFACE_A: u64 = 203;
const W_PRIME_SURFACE_B: u64 = 13;
const W_PRIME_SURFACE_RHO: u64 = 1_000_000_000;
const W_PRIME_SURFACE_M: u64 = 831_439;
const W_PRIME_SURFACE_SIGMA: u64 = 5_000_000;
/// Seed the tuple at `now_ms`, price one second later: the anchor is preserved by
/// the identical retransmit, so the roll-down is live at 119_000/120_000.
const W_PRIME_EXPIRY_MS: u64 = 240_000;
const W_PRIME_PRICED_AT_MS: u64 = 121_000;

const PER_STRIKE_NONPOSITIVE_A_MAG: u64 = 99_494;
const PER_STRIKE_NONPOSITIVE_B: u64 = 100_000_000;
const PER_STRIKE_NONPOSITIVE_RHO: u64 = 100_000_000;
const PER_STRIKE_NONPOSITIVE_M: u64 = 100_498;
const NON_MONOTONE_LOW_TICK: u64 = 90;
const NON_MONOTONE_HIGH_TICK: u64 = 95;
const ROLL_DOWN_ZERO_VARIANCE_RAW_A: u64 = 1;
const ROLL_DOWN_ZERO_VARIANCE_RAW_B: u64 = 0;
const ROLL_DOWN_CLOCK_ADVANCE_MS: u64 = 1;
const TERMINAL_ROLL_DOWN_REMAINING_MS: u64 = 1;
const ZERO_SVI_SHAPE_PARAM: u64 = 0;

// === Abort guards ===

#[test, expected_failure(abort_code = pricing::ETickNotInPriceMemo)]
fun cached_range_price_with_missing_finite_tick_aborts() {
    let memo = pricing::new_price_memo();
    memo.cached_range_price(PRICE_MEMO_MISSING_TICK, constants::pos_inf_tick!());
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::ENonMonotonePriceMemo)]
fun price_memo_rejects_non_monotone_surface_over_active_ticks() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        1,
        false,
        test_constants::pricing_max_svi_input(),
        test_constants::pricing_min_svi_sigma(),
        test_constants::float(),
        true,
        0,
        false,
    );
    let pricer = fx.load_pricer_bundle(&oracle);
    let mut memo = pricing::new_price_memo();

    memo.price_and_cache(&pricer, NON_MONOTONE_LOW_TICK, test_constants::float());
    memo.price_and_cache(&pricer, NON_MONOTONE_HIGH_TICK, test_constants::float());

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EInvalidRange)]
fun live_quote_with_equal_range_bounds_aborts() {
    let (fx, oracle) = setup_live();
    // lower must be strictly below higher; the empty (degenerate) range aborts
    // after the freshness gates pass.
    live_quote(
        &fx,
        &oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesPriceUnavailable)]
fun live_quote_with_no_block_scholes_price_aborts() {
    // A market that has never received a BS push: normalized_spot is none, so
    // pricing aborts on absence (distinct from the staleness code below).
    let mut fx = oracle_fixture::setup_oracle_default();
    let oracle = fx.take_oracle_bundle();
    live_quote(&fx, &oracle, test_constants::default_live_price(), constants::pos_inf!());
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesSVIUnavailable)]
fun live_quote_with_prices_but_no_svi_aborts() {
    // Spot and forward pushed, SVI never pushed: the SVI absence code fires,
    // distinct from EBlockScholesSVIStale.
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    let now = test_constants::live_source_timestamp_ms();
    fx.set_bs_spot_for_testing_bundle(&mut oracle, now, test_constants::default_live_price());
    fx.set_bs_forward_for_testing_bundle(&mut oracle, now, test_constants::default_live_price());
    live_quote(&fx, &oracle, test_constants::default_live_price(), constants::pos_inf!());
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesPriceStale)]
fun live_quote_with_stale_block_scholes_surface_aborts() {
    let (mut fx, oracle) = setup_live();
    // One ms past the BS price freshness window, the spot and forward feeds are
    // stale and the quote aborts before any pricing.
    let stale_now =
        test_constants::live_source_timestamp_ms()
        + oracle_fixture::config(&oracle).pricing_config().block_scholes_price_freshness_ms()
        + 1;
    fx.set_clock_for_testing(stale_now);
    live_quote(
        &fx,
        &oracle,
        test_constants::default_live_price(),
        constants::pos_inf!(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesPriceStale)]
fun live_quote_with_fresh_spot_but_stale_forward_aborts() {
    let (mut fx, mut oracle) = setup_live();
    let stale_now =
        test_constants::live_source_timestamp_ms()
        + oracle_fixture::config(&oracle).pricing_config().block_scholes_price_freshness_ms()
        + 1;
    fx.set_clock_for_testing(stale_now);
    fx.set_bs_spot_for_testing_bundle(&mut oracle, stale_now, test_constants::default_live_price());

    live_quote(
        &fx,
        &oracle,
        test_constants::default_live_price(),
        constants::pos_inf!(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesSVIStale)]
fun live_quote_with_fresh_prices_but_stale_svi_aborts() {
    let (mut fx, mut oracle) = setup_live();
    let stale_now =
        test_constants::now_ms()
        + oracle_fixture::config(&oracle).pricing_config().block_scholes_svi_freshness_ms()
        + 1;
    fx.set_clock_for_testing(stale_now);
    fx.set_bs_spot_for_testing_bundle(&mut oracle, stale_now, test_constants::default_live_price());
    fx.set_bs_forward_for_testing_bundle(
        &mut oracle,
        stale_now,
        test_constants::default_live_price(),
    );

    live_quote(
        &fx,
        &oracle,
        test_constants::default_live_price(),
        constants::pos_inf!(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EWrongBlockScholesForwardFeed)]
fun live_pricer_with_wrong_forward_feed_aborts() {
    let (mut fx, oracle) = setup_live();
    oracle_fixture::return_oracle_bundle(oracle);
    let wrong_forward_id = create_wrong_forward_feed(&mut fx);

    fx.scenario_mut().next_tx(test_constants::admin());
    let oracle = fx.take_oracle_bundle();
    let wrong_forward = fx
        .scenario_mut()
        .take_shared_by_id<BlockScholesForwardFeed>(
            wrong_forward_id,
        );
    load_pricer_with_forward(&fx, &oracle, &wrong_forward);

    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EWrongBlockScholesSVIFeed)]
fun live_pricer_with_wrong_svi_feed_aborts() {
    let (mut fx, oracle) = setup_live();
    oracle_fixture::return_oracle_bundle(oracle);
    let wrong_svi_id = create_wrong_svi_feed(&mut fx);

    fx.scenario_mut().next_tx(test_constants::admin());
    let oracle = fx.take_oracle_bundle();
    let wrong_svi = fx.scenario_mut().take_shared_by_id<BlockScholesSVIFeed>(wrong_svi_id);
    load_pricer_with_svi(&fx, &oracle, &wrong_svi);

    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EPythSpotInvalid)]
fun fresh_pyth_spot_above_pricing_ceiling_aborts() {
    let (fx, mut oracle) = setup_live();
    fx.set_pyth_bundle(
        &mut oracle,
        MAX_PRICING_SPOT + 1,
        test_constants::live_source_timestamp_ms() + 1,
    );

    let _pricer = fx.load_pricer_bundle(&oracle);

    abort EUnexpectedSuccess
}

// === Price-tail saturation (replaces the deleted strike-ratio aborts) ===

/// Deep-ITM up tail: a strike far below the forward underflows the strike ratio to
/// 0, so `up_price` returns ~1.0 (the neg_inf limit) instead of aborting.
#[test]
fun deep_itm_up_price_saturates_to_one() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    // Fresh spot == forward == 100e9.
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    let pricer = fx.load_pricer_bundle(&oracle);

    assert_eq!(pricer.up_price(strike(DEEP_ITM_STRIKE)), float!());

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// Deep-OTM up tail: a strike far above the forward overflows the strike ratio past
/// `u64::MAX`, so `up_price` returns 0 (the pos_inf limit) instead of aborting.
#[test]
fun deep_otm_up_price_saturates_to_zero() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    // Fresh spot == forward == 1 (a tiny forward, so a finite u64 strike can clear
    // the saturation threshold without being the pos_inf sentinel).
    fx.prepare_live_oracle_bundle(&mut oracle, 1);
    let pricer = fx.load_pricer_bundle(&oracle);

    assert_eq!(pricer.up_price(strike(DEEP_OTM_STRIKE)), 0);

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

// === Surface pricing-safe envelope rejects (EBlockScholesInputsInvalid) ===

#[test, expected_failure(abort_code = pricing::EBlockScholesInputsInvalid)]
fun surface_with_forward_above_spot_ceiling_aborts() {
    // forward just over the spot ceiling fires the `forward <= max_pricing_spot`
    // branch before the basis check. spot small so the basis arithmetic stays in u128.
    load_pricer_with_spot_forward(test_constants::float(), MAX_PRICING_SPOT + 1);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesInputsInvalid)]
fun surface_with_basis_above_max_aborts() {
    // basis = forward * 1e9 / spot = 101e9 > 100e9, with forward still under the
    // spot ceiling so the basis branch (not the ceiling branch) is the one that fires.
    let spot = 100 * test_constants::float();
    let forward = spot * 101;
    load_pricer_with_spot_forward(spot, forward);
    abort EUnexpectedSuccess
}

/// The basis envelope is exact: `forward == factor * spot` is the largest
/// admitted forward. The old widening compare admitted a `floor(spot/1e9)`-unit
/// sliver above it; the `div_ceil` form deliberately tightens that away, so the
/// very next unit must reject (companion admit case below pins the boundary
/// from the other side).
#[test, expected_failure(abort_code = pricing::EBlockScholesInputsInvalid)]
fun surface_with_basis_one_above_exact_factor_aborts() {
    let spot = 100 * test_constants::float();
    let forward = spot * 100 + 1;
    load_pricer_with_spot_forward(spot, forward);
    abort EUnexpectedSuccess
}

#[test]
fun surface_with_basis_at_exact_factor_admits() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    let spot = 100 * test_constants::float();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        spot,
        spot * 100, // basis exactly at the factor: the largest admitted forward
        default_svi_a(),
        false,
        default_svi_b(),
        default_svi_sigma(),
        test_constants::default_svi_rho_magnitude(),
        false,
        default_svi_m_magnitude(),
        false,
    );
    let pricer = fx.load_pricer_bundle(&oracle);

    // Envelope admitted: quote at the re-anchored forward itself (pyth spot
    // equals the BS spot here, so the live forward is spot * 100), where the
    // at-the-forward digital is strictly interior — neither the zero-forward
    // abort nor a saturated tail. Exact pricing values are owned by the oracle
    // scenario tests; this test pins that the exact-boundary basis is admitted
    // and priceable.
    let price = pricer.up_price(strike(spot * 100));
    assert!(0 < price && price < float!());

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

#[test, expected_failure(abort_code = pricing::EBlockScholesInputsInvalid)]
fun surface_with_svi_a_above_max_aborts() {
    load_pricer_with_invalid_svi(
        test_constants::pricing_max_svi_input() + 1,
        default_svi_b(),
        default_svi_sigma(),
    );
    abort EUnexpectedSuccess
}

#[test]
fun negative_svi_a_with_positive_min_variance_prices() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        NEGATIVE_SVI_A_MAG,
        true,
        POSITIVE_MIN_VARIANCE_SVI_B,
        POSITIVE_MIN_VARIANCE_SIGMA,
        0,
        false,
        0,
        false,
    );
    let pricer = fx.load_pricer_bundle(&oracle);

    let up = pricer.range_price(
        strike(test_constants::default_live_price()),
        strike(constants::pos_inf!()),
    );
    // Independent Python true-math reference:
    // w = -0.001 + 0.01 * sqrt(0^2 + 0.5^2) = 0.004, w' = 0,
    // d2 = -(w / 2) / sqrt(w), Phi(d2) = 0.4873864396849802.
    // The tolerance uses the committed pricing-reference generator's worst-case
    // per-endpoint error budget. This at-forward, zero-skew point is less
    // ill-conditioned than that generated small-variance worst case.
    test_helpers::assert_within(
        up,
        NEGATIVE_A_AT_FORWARD_REFERENCE,
        ref_data::worst_case_budget(),
    );

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

#[test, expected_failure(abort_code = pricing::EBlockScholesMinVarianceInvalid)]
fun negative_svi_a_with_nonpositive_min_variance_aborts_at_load() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        NONPOSITIVE_MIN_VARIANCE_A_MAG,
        true,
        POSITIVE_MIN_VARIANCE_SVI_B,
        POSITIVE_MIN_VARIANCE_SIGMA,
        0,
        false,
        0,
        false,
    );

    let _pricer = fx.load_pricer_bundle(&oracle);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesInputsInvalid)]
fun surface_with_svi_b_above_max_aborts() {
    load_pricer_with_invalid_svi(
        default_svi_a(),
        test_constants::pricing_max_svi_input() + 1,
        default_svi_sigma(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesInputsInvalid)]
fun surface_with_svi_rho_above_one_aborts() {
    // rho magnitude just over 1.0 fails `|rho| <= 1e9`.
    load_pricer_with_full_svi(
        default_svi_a(),
        default_svi_b(),
        default_svi_sigma(),
        test_constants::float() + 1,
        false,
        default_svi_m_magnitude(),
        false,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesInputsInvalid)]
fun surface_with_svi_m_above_max_aborts() {
    load_pricer_with_full_svi(
        default_svi_a(),
        default_svi_b(),
        default_svi_sigma(),
        test_constants::float(),
        false,
        test_constants::pricing_max_svi_input() + 1,
        false,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesInputsInvalid)]
fun surface_with_svi_sigma_below_min_aborts() {
    load_pricer_with_invalid_svi(
        default_svi_a(),
        default_svi_b(),
        test_constants::pricing_min_svi_sigma() - 1,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesInputsInvalid)]
fun surface_with_svi_sigma_above_max_aborts() {
    load_pricer_with_invalid_svi(
        default_svi_a(),
        default_svi_b(),
        test_constants::pricing_max_svi_input() + 1,
    );
    abort EUnexpectedSuccess
}

// === Deep-math abort (EZeroForward) ===

/// A surface whose forward is tiny relative to the BS spot passes the envelope
/// (there is no LOWER basis bound), but re-anchoring at a pyth spot far below the
/// BS spot floors `spot * bs_forward / bs_spot` to 0, and `compute_nd2` aborts on
/// the first finite-strike quote.
#[test, expected_failure(abort_code = pricing::EZeroForward)]
fun re_anchored_zero_forward_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    let bs_spot = 100_000_000_000_000_000; // 1e17, under the spot ceiling
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        bs_spot,
        1, // bs_forward == 1
        default_svi_a(),
        false,
        default_svi_b(),
        default_svi_sigma(),
        test_constants::default_svi_rho_magnitude(),
        false,
        default_svi_m_magnitude(),
        false,
    );
    // Re-anchor at a pyth spot far below the BS spot: 1e9 * 1 / 1e17 floors to 0.
    fx.set_pyth_bundle(&mut oracle, 1_000_000_000, fx.clock().timestamp_ms());
    let pricer = fx.load_pricer_bundle(&oracle);

    pricer.up_price(strike(test_constants::default_live_price()));

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
    abort EUnexpectedSuccess
}

/// A boundary-valid surface can still hit the quote-time positive-variance
/// backstop: the load-time rounded analytical minimum is positive by 4 units,
/// but at the forward strike this specific surface rounds the per-strike SVI
/// increment 5 units lower, making total variance negative.
#[test, expected_failure(abort_code = pricing::ENonPositiveVariance)]
fun boundary_loaded_surface_with_nonpositive_per_strike_variance_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        PER_STRIKE_NONPOSITIVE_A_MAG,
        true,
        PER_STRIKE_NONPOSITIVE_B,
        test_constants::pricing_min_svi_sigma(),
        PER_STRIKE_NONPOSITIVE_RHO,
        false,
        PER_STRIKE_NONPOSITIVE_M,
        false,
    );
    let pricer = fx.load_pricer_bundle(&oracle);

    pricer.up_price(strike(test_constants::default_live_price()));

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
    abort EUnexpectedSuccess
}

/// The other side of that boundary, and the region the u128/1e18 variance path
/// newly admits (RP-20). This surface's per-strike total variance is positive but
/// smaller than one raw unit at 1e9, so the pre-1e18 pricer computed
/// `floor(b*inner/1e9) + a == 0` and aborted `ENonPositiveVariance` on a variance
/// that was never actually non-positive. The analytical minimum still clears the
/// load gate by one unit (min_increment 3 against `a = -2`), so the surface is
/// production-loadable rather than a contrived one.
///
/// Expected value is the independently generated true digital for this surface,
/// within the same documented budget the other pricing assertions use.
#[test]
fun low_variance_surface_prices_where_the_1e9_path_aborted() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        ADMITTED_LOW_VARIANCE_A_MAG,
        true,
        ADMITTED_LOW_VARIANCE_B,
        ADMITTED_LOW_VARIANCE_SIGMA,
        ADMITTED_LOW_VARIANCE_RHO,
        false,
        ADMITTED_LOW_VARIANCE_M,
        false,
    );
    let pricer = fx.load_pricer_bundle(&oracle);

    test_helpers::assert_within(
        pricer.up_price(strike(test_constants::default_live_price())),
        ref_data::admitted_low_variance_up(),
        ref_data::flow_fixture_atm_budget(),
    );

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// The `d2` saturation from RP-20, exercised at the helper's own scalar inputs.
///
/// `d2` is `(k + w/2) / sqrt(w)` with the numerator carried at 1e18 and the
/// divisor at 1e9, so as `w` collapses the quotient grows without bound and the
/// narrowing cast to the `I64` magnitude would abort. `normal_cdf` and
/// `normal_pdf` are already saturated everywhere past `|8|`, so the value is
/// capped there instead: the arithmetic cannot abort, and no reachable price
/// changes because the caller was already on the clamp.
///
/// Driven directly rather than through a surface: the pricer-load gate keeps the
/// minimum total variance at or above one raw unit at 1e9, which bounds `sqrt(w)`
/// from below and holds the quotient inside `u64` for every admissible surface
/// sampled. The guard is defence against that bound being wrong, so it is pinned
/// where it can actually be driven.
#[test]
fun d2_saturates_at_the_normal_clamp_instead_of_overflowing() {
    // w = 1 raw unit at 1e18, so sqrt(w) is 1 and d2 is the numerator itself:
    // k at its domain maximum would otherwise divide out to ~2e19, past u64.
    let k = i64::from_parts(20_000_000_000, true);
    let (sqrt_var, d2) = pricing::variance_sqrt_and_d2_for_testing(
        0,
        false,
        MINIMAL_B_1E18,
        MINIMAL_INNER,
        &k,
    );

    assert_eq!(sqrt_var, 1);
    assert_eq!(d2.magnitude(), SATURATED_D2_MAGNITUDE);
    assert!(!d2.is_negative());

    // A well-conditioned input on the same path is untouched by the cap.
    let (sqrt_var, d2) = pricing::variance_sqrt_and_d2_for_testing(
        0,
        false,
        WELL_CONDITIONED_B_1E18,
        WELL_CONDITIONED_INNER,
        &i64::from_u64(0),
    );
    assert_eq!(sqrt_var, WELL_CONDITIONED_SQRT_W);
    assert!(d2.magnitude() < SATURATED_D2_MAGNITUDE);
}

/// Raw `a == 1` one millisecond past the parameter anchor. The 1e9 roll-down
/// floored it straight to zero here and aborted `ENonPositiveVariance` on a
/// surface whose variance is barely reduced; carrying the roll-down at 1e18
/// leaves `a` at 0.9999833e-9 and the surface prices normally.
///
/// An identical retransmit at that later millisecond refreshes the envelope
/// without resetting the anchor, so this is the real production sequence, not a
/// contrived one. The expected value is the flat-surface reference: `b` is zero,
/// so `w` is just the rolled `a`, and the roll-down moves the digital by well
/// under one raw unit at this horizon.
#[test]
fun pre_expiry_roll_down_keeps_positive_variance() {
    let expiry_ms = test_constants::now_ms() + test_constants::default_cadence_period_ms();
    let mut fx = oracle_fixture::setup_oracle(
        test_constants::default_live_price(),
        test_constants::default_tick_size(),
        expiry_ms,
    );
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        ROLL_DOWN_ZERO_VARIANCE_RAW_A,
        false,
        ROLL_DOWN_ZERO_VARIANCE_RAW_B,
        default_svi_sigma(),
        ZERO_SVI_SHAPE_PARAM,
        false,
        ZERO_SVI_SHAPE_PARAM,
        false,
    );
    fx.set_clock_for_testing(test_constants::now_ms() + ROLL_DOWN_CLOCK_ADVANCE_MS);
    fx.set_bs_svi_for_testing_bundle(
        &mut oracle,
        test_constants::now_ms() + ROLL_DOWN_CLOCK_ADVANCE_MS,
        ROLL_DOWN_ZERO_VARIANCE_RAW_A,
        false,
        ROLL_DOWN_ZERO_VARIANCE_RAW_B,
        default_svi_sigma(),
        ZERO_SVI_SHAPE_PARAM,
        false,
        ZERO_SVI_SHAPE_PARAM,
        false,
    );
    let pricer = fx.load_pricer_bundle(&oracle);

    test_helpers::assert_within(
        pricer.up_price(strike(test_constants::default_live_price())),
        ref_data::flat_surface_atm_up(),
        ref_data::flat_surface_atm_budget(),
    );

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// A raw-valid `a = 1e-9, b = 0` tuple anchored at `now_ms`, then retransmitted
/// unchanged one millisecond before a one-year expiry. The retransmit refreshes
/// every feed clock without moving the parameter anchor. At that horizon,
/// `floor(1e9 * remaining_ms / anchor_tte_ms) == 0`, so the effective variance
/// is non-positive and the accepted RP-21 response is the existing quote abort.
#[test, expected_failure(abort_code = pricing::ENonPositiveVariance)]
fun terminal_roll_down_to_zero_aborts_before_expiry() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        ROLL_DOWN_ZERO_VARIANCE_RAW_A,
        false,
        ROLL_DOWN_ZERO_VARIANCE_RAW_B,
        default_svi_sigma(),
        ZERO_SVI_SHAPE_PARAM,
        false,
        ZERO_SVI_SHAPE_PARAM,
        false,
    );

    let terminal_source_timestamp_ms =
        test_constants::default_expiry_ms() - TERMINAL_ROLL_DOWN_REMAINING_MS;
    fx.set_clock_for_testing(terminal_source_timestamp_ms);
    fx.set_pyth_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        terminal_source_timestamp_ms,
    );
    fx.set_bs_spot_for_testing_bundle(
        &mut oracle,
        terminal_source_timestamp_ms,
        test_constants::default_live_price(),
    );
    fx.set_bs_forward_for_testing_bundle(
        &mut oracle,
        terminal_source_timestamp_ms,
        test_constants::default_live_price(),
    );
    fx.set_bs_svi_for_testing_bundle(
        &mut oracle,
        terminal_source_timestamp_ms,
        ROLL_DOWN_ZERO_VARIANCE_RAW_A,
        false,
        ROLL_DOWN_ZERO_VARIANCE_RAW_B,
        default_svi_sigma(),
        ZERO_SVI_SHAPE_PARAM,
        false,
        ZERO_SVI_SHAPE_PARAM,
        false,
    );
    let pricer = fx.load_pricer_bundle(&oracle);

    pricer.up_price(strike(test_constants::default_live_price()));

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
    abort EUnexpectedSuccess
}

/// Pins the rolled `b`'s precision through the SKEW CORRECTION, not just through
/// the variance. `compute_nd2` forms `w' = b * slope / 1e18` with `b` at 1e18;
/// narrowing `b` back to 1e9 first — the shape the variance path itself used to
/// have — silently drops up to a raw unit of it.
///
/// The flow fixtures cannot catch that: their `slope` is ~5 raw units, so `w'`
/// floors to zero and the correction term vanishes either way. And a fixture whose
/// pricer loads at the parameter anchor cannot either, because at ratio 1 the
/// rolled `b` is integral at 1e9 and both forms agree exactly. So this seeds the
/// tuple, advances the clock, and retransmits it unchanged (which preserves the
/// anchor) to get a genuinely non-integral rolled `b`. Carrying it at 1e18 lands
/// 4 units from the independently generated digital; narrowing to 1e9 misses by
/// ~890 — 42x the budget.
#[test]
fun w_prime_keeps_the_rolled_b_precision() {
    let mut fx = oracle_fixture::setup_oracle(
        test_constants::default_live_price(),
        test_constants::default_tick_size(),
        W_PRIME_EXPIRY_MS,
    );
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        W_PRIME_SURFACE_A,
        false,
        W_PRIME_SURFACE_B,
        W_PRIME_SURFACE_SIGMA,
        W_PRIME_SURFACE_RHO,
        false,
        W_PRIME_SURFACE_M,
        true,
    );

    fx.set_clock_for_testing(W_PRIME_PRICED_AT_MS);
    fx.set_bs_spot_for_testing_bundle(
        &mut oracle,
        W_PRIME_PRICED_AT_MS,
        test_constants::default_live_price(),
    );
    fx.set_bs_forward_for_testing_bundle(
        &mut oracle,
        W_PRIME_PRICED_AT_MS,
        test_constants::default_live_price(),
    );
    fx.set_bs_svi_for_testing_bundle(
        &mut oracle,
        W_PRIME_PRICED_AT_MS,
        W_PRIME_SURFACE_A,
        false,
        W_PRIME_SURFACE_B,
        W_PRIME_SURFACE_SIGMA,
        W_PRIME_SURFACE_RHO,
        false,
        W_PRIME_SURFACE_M,
        true,
    );

    let pricer = fx.load_pricer_bundle(&oracle);
    test_helpers::assert_within(
        pricer.up_price(strike(test_constants::default_live_price())),
        ref_data::w_prime_precision_surface_up(),
        ref_data::flow_fixture_atm_budget(),
    );

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

// === Surface minimum-variance abort ===

/// A degenerate surface (`a == 0, b == 0`) has zero analytical minimum total
/// variance (`a + b*sigma*sqrt(1-rho^2) == 0`), so it is rejected while loading
/// the live pricer rather than reaching the first finite-strike quote.
#[test, expected_failure(abort_code = pricing::EBlockScholesMinVarianceInvalid)]
fun zero_total_variance_aborts_at_load() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        0, // svi_a == 0
        false,
        0, // svi_b == 0, so total_var = a + b*inner == 0
        default_svi_sigma(),
        test_constants::default_svi_rho_magnitude(),
        false,
        default_svi_m_magnitude(),
        false,
    );
    let pricer = fx.load_pricer_bundle(&oracle);

    pricer.up_price(strike(test_constants::default_live_price()));

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
    abort EUnexpectedSuccess
}

// === Helpers ===

fun default_svi_a(): u64 { test_constants::default_svi_a() }

fun default_svi_b(): u64 { test_constants::default_svi_b() }

fun default_svi_sigma(): u64 { test_constants::default_svi_sigma() }

fun default_svi_m_magnitude(): u64 { test_constants::default_svi_m() }

/// Seed a surface with the given spot/forward and default SVI, then load the pricer
/// (where `assert_inputs_pricing_safe` runs).
fun load_pricer_with_spot_forward(spot: u64, forward: u64) {
    load_pricer_with_full_svi_and_spot(
        spot,
        forward,
        default_svi_a(),
        default_svi_b(),
        default_svi_sigma(),
        test_constants::default_svi_rho_magnitude(),
        false,
        default_svi_m_magnitude(),
        false,
    );
}

/// Seed a default-spot/forward surface with the given SVI a/b/sigma (rho/m default),
/// then load the pricer.
fun load_pricer_with_invalid_svi(svi_a: u64, svi_b: u64, svi_sigma: u64) {
    load_pricer_with_full_svi(
        svi_a,
        svi_b,
        svi_sigma,
        test_constants::default_svi_rho_magnitude(),
        false,
        default_svi_m_magnitude(),
        false,
    );
}

/// Seed a default-spot/forward surface with a fully specified SVI, then load.
fun load_pricer_with_full_svi(
    svi_a: u64,
    svi_b: u64,
    svi_sigma: u64,
    svi_rho_magnitude: u64,
    svi_rho_is_negative: bool,
    svi_m_magnitude: u64,
    svi_m_is_negative: bool,
) {
    load_pricer_with_full_svi_and_spot(
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        svi_a,
        svi_b,
        svi_sigma,
        svi_rho_magnitude,
        svi_rho_is_negative,
        svi_m_magnitude,
        svi_m_is_negative,
    );
}

fun load_pricer_with_full_svi_and_spot(
    spot: u64,
    forward: u64,
    svi_a: u64,
    svi_b: u64,
    svi_sigma: u64,
    svi_rho_magnitude: u64,
    svi_rho_is_negative: bool,
    svi_m_magnitude: u64,
    svi_m_is_negative: bool,
) {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        spot,
        forward,
        svi_a,
        false,
        svi_b,
        svi_sigma,
        svi_rho_magnitude,
        svi_rho_is_negative,
        svi_m_magnitude,
        svi_m_is_negative,
    );
    // `load_pricer` runs `assert_inputs_pricing_safe`; the invalid surface aborts
    // here before the pricer is returned.
    let _pricer = fx.load_pricer_bundle(&oracle);

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

fun create_wrong_forward_feed(fx: &mut OracleFixture): ID {
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let wrong_forward_id = propbook_registry::create_and_share_block_scholes_forward_feed(
        &mut oracle_registry,
        SECOND_SOURCE_ID,
        fx.scenario_mut().ctx(),
    );
    return_shared(oracle_registry);
    wrong_forward_id
}

fun create_wrong_svi_feed(fx: &mut OracleFixture): ID {
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let wrong_svi_id = propbook_registry::create_and_share_block_scholes_svi_feed(
        &mut oracle_registry,
        SECOND_SOURCE_ID,
        fx.scenario_mut().ctx(),
    );
    return_shared(oracle_registry);
    wrong_svi_id
}

fun load_pricer_with_forward(
    fx: &OracleFixture,
    oracle: &OracleBundle,
    forward: &BlockScholesForwardFeed,
) {
    let _pricer = pricing::load_live_pricer(
        oracle_fixture::config(oracle).pricing_config(),
        oracle_fixture::oracle_registry(oracle),
        oracle_fixture::pyth(oracle),
        oracle_fixture::bs(oracle).spot(),
        forward,
        oracle_fixture::bs(oracle).svi(),
        fx.expiry_id(),
        test_constants::propbook_underlying_id(),
        fx.expiry(),
        fx.clock(),
    );
}

fun load_pricer_with_svi(fx: &OracleFixture, oracle: &OracleBundle, svi: &BlockScholesSVIFeed) {
    let _pricer = pricing::load_live_pricer(
        oracle_fixture::config(oracle).pricing_config(),
        oracle_fixture::oracle_registry(oracle),
        oracle_fixture::pyth(oracle),
        oracle_fixture::bs(oracle).spot(),
        oracle_fixture::bs(oracle).forward(),
        svi,
        fx.expiry_id(),
        test_constants::propbook_underlying_id(),
        fx.expiry(),
        fx.clock(),
    );
}

/// Bring up the default live oracle: fresh Pyth spot + split Block Scholes feeds,
/// quotable at the fixture clock (forward == 100e9).
fun setup_live(): (OracleFixture, OracleBundle) {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    (fx, oracle)
}

/// Worker: one live quote over `(lower, higher]` against the fixture market.
fun live_quote(fx: &OracleFixture, oracle: &OracleBundle, lower: u64, higher: u64): u64 {
    let pricer = fx.load_pricer_bundle(oracle);
    pricer.range_price(strike(lower), strike(higher))
}
