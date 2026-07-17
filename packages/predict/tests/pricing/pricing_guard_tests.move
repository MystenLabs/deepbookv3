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
/// exactly that bound (`forward` ceiling, `basis`, `a`, `b`, `rho`, `m`, `sigma`),
/// leaving every other input default so only the targeted branch fires. The
/// `spot == 0` / `forward == 0` branch of that assert is unreachable through
/// `load_live_pricer`: the split Block Scholes feed reads drop a zero spot or zero
/// forward upstream, so the read arrives as `none` and pricing aborts on absence
/// (-> `EBlockScholesPriceUnavailable`) before any staleness check runs. Those two
/// conditions are defensive-only and not tested here. `EZeroForward` is reached
/// via a pyth spot far below the BS spot (no LOWER basis bound), where the
/// re-anchored `spot * bs_forward / bs_spot` floors to 0. `EZeroVariance` is reached by a
/// degenerate-but-in-envelope surface (`a == 0, b == 0`, so total variance
/// `a + b*inner == 0`): a/b are bounded only from above, and the `sigma >= 1e-3`
/// floor bounds the SVI wing parameter, NOT the total variance, so it does not
/// prevent this. It is the same recoverable fail-closed liveness stop a near-expiry
/// surface hits as total variance rounds to 0: all quoting (incl. NAV) aborts until
/// a valid surface is pushed, never a mispricing. `ECannotBeNegative` in
/// `compute_nd2` is the one genuinely unreachable guard: the envelope's `|rho| <= 1`
/// makes `inner = rho*(k-m) + sqrt((k-m)^2 + sigma^2) >= 0` always; it is a
/// defensive fixed-point guard, noted not tested. `ETickNotInPriceMemo` is a
/// package-level cache contract guard and is covered directly below; the successful
/// memo path is covered in `payout_tree_walk_tests`.
#[test_only]
module deepbook_predict::pricing_guard_tests;

use deepbook_predict::{
    constants,
    oracle_fixture::{Self, OracleBundle, OracleFixture},
    pricing,
    range_codec::strike_for_testing as strike,
    test_constants
};
use fixed_math::math::float_scaling as float;
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
const MIN_SVI_SIGMA: u64 = 1_000_000; // 1e-3 in 1e9 fixed point
const MAX_SVI_INPUT: u64 = 100_000_000_000; // 100 * 1e9
const PRICE_MEMO_MISSING_TICK: u64 = 100;

// === Abort guards ===

#[test, expected_failure(abort_code = pricing::ETickNotInPriceMemo)]
fun cached_range_price_with_missing_finite_tick_aborts() {
    let memo = pricing::new_price_memo();
    memo.cached_range_price(PRICE_MEMO_MISSING_TICK, constants::pos_inf_tick!());
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
        test_constants::live_source_timestamp_ms()
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
    load_pricer_with_invalid_svi(MAX_SVI_INPUT + 1, default_svi_b(), default_svi_sigma());
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesInputsInvalid)]
fun surface_with_svi_b_above_max_aborts() {
    load_pricer_with_invalid_svi(default_svi_a(), MAX_SVI_INPUT + 1, default_svi_sigma());
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
        MAX_SVI_INPUT + 1,
        false,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesInputsInvalid)]
fun surface_with_svi_sigma_below_min_aborts() {
    load_pricer_with_invalid_svi(default_svi_a(), default_svi_b(), MIN_SVI_SIGMA - 1);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesInputsInvalid)]
fun surface_with_svi_sigma_above_max_aborts() {
    load_pricer_with_invalid_svi(default_svi_a(), default_svi_b(), MAX_SVI_INPUT + 1);
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

// === Deep-math abort (EZeroVariance) ===

/// A degenerate but in-envelope surface (`a == 0, b == 0`) has zero SVI total
/// variance (`total_var = a + b*inner == 0`). It passes `assert_inputs_pricing_safe`
/// (a/b are bounded only from above), but `compute_nd2` fails closed on the first
/// finite-strike quote. The `min_svi_sigma` floor does not prevent this: it bounds
/// the SVI wing parameter, not the total variance. This is the same recoverable
/// liveness stop a near-expiry surface hits as total variance rounds to 0.
#[test, expected_failure(abort_code = pricing::EZeroVariance)]
fun zero_total_variance_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        0, // svi_a == 0
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
