// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Guard coverage for `pricing.move`'s live quote path.
///
/// Two abort surfaces are exercised through the production-valid `oracle_fixture`
/// bring-up:
///   - `EInvalidRange`: a degenerate range (`lower == higher`) after freshness
///     passes;
///   - `EBlockScholesSurfaceStale`: the single hard staleness abort — the Block
///     Scholes surface (spot + forward + SVI, written together) is past its one
///     collapsed freshness window.
/// The old deep-ITM/deep-OTM aborts (`EInvalidStrikeRatio`) are gone: the price
/// tail now SATURATES instead of aborting, so those are pinned here as exact-value
/// tests (deep-ITM up tail -> 1.0, deep-OTM up tail -> 0). A stale Pyth spot no
/// longer aborts either — it falls back to the stored Block Scholes forward; that
/// fallback is pinned with exact values in
/// `pricing_tests::live_forward_switches_source_exactly_at_pyth_staleness_boundary`,
/// so it is not duplicated here.
///
/// The `assert_surface_pricing_safe` envelope rejects (`EBlockScholesSurfaceInvalid`)
/// is covered here too: one test per reachable branch seeds a surface that violates
/// exactly that bound (`forward` ceiling, `basis`, `a`, `b`, `rho`, `m`, `sigma`),
/// leaving every other input default so only the targeted branch fires. The
/// `spot == 0` / `forward == 0` branch of that assert is unreachable through
/// `load_live_pricer`: `block_scholes_feed::normalized_surface_from_read` drops a
/// zero-spot/zero-forward surface upstream (-> `EBlockScholesSurfaceStale`), so those
/// two conditions are defensive-only and not tested here. `EZeroForward` is reached
/// via a tiny-forward / large-spot surface (no LOWER basis bound), where the
/// re-anchored `spot * (forward/spot)` rounds to 0. `EZeroVariance` is reached by a
/// degenerate-but-in-envelope surface (`a == 0, b == 0`, so total variance
/// `a + b*inner == 0`): a/b are bounded only from above, and the `sigma >= 1e-3`
/// floor bounds the SVI wing parameter, NOT the total variance, so it does not
/// prevent this. It is the same recoverable fail-closed liveness stop a near-expiry
/// surface hits as total variance rounds to 0: all quoting (incl. NAV) aborts until
/// a valid surface is pushed, never a mispricing. `ECannotBeNegative` in
/// `compute_nd2` is the one genuinely unreachable guard: the envelope's `|rho| <= 1`
/// makes `inner = rho*(k-m) + sqrt((k-m)^2 + sigma^2) >= 0` always; it is a
/// defensive fixed-point guard, noted not tested.
#[test_only]
module deepbook_predict::pricing_guard_tests;

use deepbook_predict::{
    constants,
    oracle_fixture::{Self, OracleFixture},
    pricing,
    protocol_config::ProtocolConfig,
    test_constants
};
use fixed_math::math::float_scaling as float;
use propbook::{block_scholes_feed::BlockScholesFeed, pyth_feed::PythFeed, registry::OracleRegistry};
use std::unit_test::assert_eq;

const EUnexpectedSuccess: u64 = 999;

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

// === Abort guards (production-valid fixture bring-up) ===

#[test, expected_failure(abort_code = pricing::EInvalidRange)]
fun live_quote_with_equal_range_bounds_aborts() {
    let (fx, pyth, bs, oracle_registry, config) = setup_live();
    // lower must be strictly below higher; the empty (degenerate) range aborts
    // after the freshness gates pass.
    live_quote(
        &fx,
        &pyth,
        &bs,
        &oracle_registry,
        &config,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesSurfaceStale)]
fun live_quote_with_stale_block_scholes_surface_aborts() {
    let (mut fx, pyth, bs, oracle_registry, config) = setup_live();
    // The surface freshness timestamp is min(source, update) =
    // live_source_timestamp_ms (99_000); one ms past the collapsed surface window
    // the surface is stale and the quote aborts before any pricing.
    let stale_now =
        test_constants::live_source_timestamp_ms()
        + config.pricing_config().block_scholes_surface_freshness_ms()
        + 1;
    fx.set_clock_for_testing(stale_now);
    live_quote(
        &fx,
        &pyth,
        &bs,
        &oracle_registry,
        &config,
        test_constants::default_live_price(),
        constants::pos_inf!(),
    );
    abort EUnexpectedSuccess
}

// === Price-tail saturation (replaces the deleted strike-ratio aborts) ===

/// Deep-ITM up tail: a strike far below the forward underflows the strike ratio to
/// 0, so `up_price` returns ~1.0 (the neg_inf limit) instead of aborting.
#[test]
fun deep_itm_up_price_saturates_to_one() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let (mut pyth, mut bs, oracle_registry, config) = fx.take_oracle();
    // Fresh spot == forward == 100e9.
    fx.prepare_live_oracle(&mut bs, &mut pyth, test_constants::default_live_price());
    let pricer = fx.load_pricer(&config, &oracle_registry, &pyth, &bs);

    assert_eq!(pricer.up_price(DEEP_ITM_STRIKE), float!());

    oracle_fixture::return_oracle(pyth, bs, oracle_registry, config);
    fx.finish();
}

/// Deep-OTM up tail: a strike far above the forward overflows the strike ratio past
/// `u64::MAX`, so `up_price` returns 0 (the pos_inf limit) instead of aborting.
#[test]
fun deep_otm_up_price_saturates_to_zero() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let (mut pyth, mut bs, oracle_registry, config) = fx.take_oracle();
    // Fresh spot == forward == 1 (a tiny forward, so a finite u64 strike can clear
    // the saturation threshold without being the pos_inf sentinel).
    fx.prepare_live_oracle(&mut bs, &mut pyth, 1);
    let pricer = fx.load_pricer(&config, &oracle_registry, &pyth, &bs);

    assert_eq!(pricer.up_price(DEEP_OTM_STRIKE), 0);

    oracle_fixture::return_oracle(pyth, bs, oracle_registry, config);
    fx.finish();
}

// === Surface pricing-safe envelope rejects (EBlockScholesSurfaceInvalid) ===

#[test, expected_failure(abort_code = pricing::EBlockScholesSurfaceInvalid)]
fun surface_with_forward_above_spot_ceiling_aborts() {
    // forward just over the spot ceiling fires the `forward <= max_pricing_spot`
    // branch before the basis check. spot small so the basis arithmetic stays in u128.
    load_pricer_with_spot_forward(test_constants::float(), MAX_PRICING_SPOT + 1);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesSurfaceInvalid)]
fun surface_with_basis_above_max_aborts() {
    // basis = forward * 1e9 / spot = 101e9 > 100e9, with forward still under the
    // spot ceiling so the basis branch (not the ceiling branch) is the one that fires.
    let spot = 100 * test_constants::float();
    let forward = spot * 101;
    load_pricer_with_spot_forward(spot, forward);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesSurfaceInvalid)]
fun surface_with_svi_a_above_max_aborts() {
    load_pricer_with_invalid_svi(MAX_SVI_INPUT + 1, default_svi_b(), default_svi_sigma());
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesSurfaceInvalid)]
fun surface_with_svi_b_above_max_aborts() {
    load_pricer_with_invalid_svi(default_svi_a(), MAX_SVI_INPUT + 1, default_svi_sigma());
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesSurfaceInvalid)]
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

#[test, expected_failure(abort_code = pricing::EBlockScholesSurfaceInvalid)]
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

#[test, expected_failure(abort_code = pricing::EBlockScholesSurfaceInvalid)]
fun surface_with_svi_sigma_below_min_aborts() {
    load_pricer_with_invalid_svi(default_svi_a(), default_svi_b(), MIN_SVI_SIGMA - 1);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesSurfaceInvalid)]
fun surface_with_svi_sigma_above_max_aborts() {
    load_pricer_with_invalid_svi(default_svi_a(), default_svi_b(), MAX_SVI_INPUT + 1);
    abort EUnexpectedSuccess
}

// === Deep-math abort (EZeroForward) ===

/// A surface whose forward is tiny relative to spot has basis 0 (no LOWER basis
/// bound), so it passes the envelope, but the re-anchored live forward
/// `mul(spot, div(forward, spot))` rounds to 0 and `compute_nd2` aborts on the first
/// finite-strike quote.
#[test, expected_failure(abort_code = pricing::EZeroForward)]
fun re_anchored_zero_forward_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let (mut pyth, mut bs, oracle_registry, config) = fx.take_oracle();
    let spot = 100_000_000_000_000_000; // 1e17, under the spot ceiling
    fx.prepare_real_oracle(
        &mut bs,
        &mut pyth,
        spot,
        1, // forward == 1: div(1, 1e17) == 0, so spot * 0 == 0
        default_svi_a(),
        default_svi_b(),
        default_svi_sigma(),
        test_constants::default_svi_rho_magnitude(),
        false,
        default_svi_m_magnitude(),
        false,
    );
    let pricer = fx.load_pricer(&config, &oracle_registry, &pyth, &bs);

    pricer.up_price(test_constants::default_live_price());

    oracle_fixture::return_oracle(pyth, bs, oracle_registry, config);
    fx.finish();
    abort EUnexpectedSuccess
}

// === Deep-math abort (EZeroVariance) ===

/// A degenerate but in-envelope surface (`a == 0, b == 0`) has zero SVI total
/// variance (`total_var = a + b*inner == 0`). It passes `assert_surface_pricing_safe`
/// (a/b are bounded only from above), but `compute_nd2` fails closed on the first
/// finite-strike quote. The `min_svi_sigma` floor does not prevent this: it bounds
/// the SVI wing parameter, not the total variance. This is the same recoverable
/// liveness stop a near-expiry surface hits as total variance rounds to 0.
#[test, expected_failure(abort_code = pricing::EZeroVariance)]
fun zero_total_variance_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let (mut pyth, mut bs, oracle_registry, config) = fx.take_oracle();
    fx.prepare_real_oracle(
        &mut bs,
        &mut pyth,
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
    let pricer = fx.load_pricer(&config, &oracle_registry, &pyth, &bs);

    pricer.up_price(test_constants::default_live_price());

    oracle_fixture::return_oracle(pyth, bs, oracle_registry, config);
    fx.finish();
    abort EUnexpectedSuccess
}

// === Helpers ===

fun default_svi_a(): u64 { test_constants::default_svi_a() }

fun default_svi_b(): u64 { test_constants::default_svi_b() }

fun default_svi_sigma(): u64 { test_constants::default_svi_sigma() }

fun default_svi_m_magnitude(): u64 { test_constants::default_svi_m() }

/// Seed a surface with the given spot/forward and default SVI, then load the pricer
/// (where `assert_surface_pricing_safe` runs).
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
    let (mut pyth, mut bs, oracle_registry, config) = fx.take_oracle();
    fx.prepare_real_oracle(
        &mut bs,
        &mut pyth,
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
    // `load_pricer` runs `assert_surface_pricing_safe`; the invalid surface aborts
    // here before the pricer is returned.
    let _pricer = fx.load_pricer(&config, &oracle_registry, &pyth, &bs);

    oracle_fixture::return_oracle(pyth, bs, oracle_registry, config);
    fx.finish();
}

/// Bring up the default live oracle: fresh Pyth spot + Block Scholes surface,
/// quotable at the fixture clock (forward == 100e9).
fun setup_live(): (OracleFixture, PythFeed, BlockScholesFeed, OracleRegistry, ProtocolConfig) {
    let mut fx = oracle_fixture::setup_oracle_default();
    let (mut pyth, mut bs, oracle_registry, config) = fx.take_oracle();
    fx.prepare_live_oracle(&mut bs, &mut pyth, test_constants::default_live_price());
    (fx, pyth, bs, oracle_registry, config)
}

/// Worker: one live quote over `(lower, higher]` against the fixture market.
fun live_quote(
    fx: &OracleFixture,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    oracle_registry: &OracleRegistry,
    config: &ProtocolConfig,
    lower: u64,
    higher: u64,
): u64 {
    let pricer = fx.load_pricer(config, oracle_registry, pyth, bs);
    pricer.range_price(lower, higher)
}
