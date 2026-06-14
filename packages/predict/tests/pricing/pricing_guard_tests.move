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
use propbook::{
    block_scholes_feed::BlockScholesFeed,
    pyth_feed::PythFeed,
    registry::OracleRegistry
};
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

// === Helpers ===

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
