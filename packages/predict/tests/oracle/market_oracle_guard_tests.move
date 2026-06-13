// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// One `expected_failure` test per `market_oracle` guard error constant, plus
/// the `settlement_state` unsettled-read guard and no-op coverage for the
/// batch-race skip paths (settled / non-active / non-advancing source), driven
/// through the production-valid `oracle_fixture` bring-up
/// (`registry::create_expiry_market` path).
#[test_only]
module deepbook_predict::market_oracle_guard_tests;

use deepbook_predict::{
    admin,
    constants,
    market_oracle::{Self, MarketOracle, SVIParams},
    market_oracle_writer_cap,
    oracle_fixture::{Self, OracleFixture},
    protocol_config::ProtocolConfig,
    pyth_source::PythSource,
    registry::{Self, Registry},
    test_constants
};
use predict_math::i64;
use std::unit_test::assert_eq;
use sui::{random, test_scenario::return_shared};

/// Second-push source timestamp: strictly after the seed push at
/// `live_source_timestamp_ms` (99_000) and not ahead of the fixture clock
/// (`now_ms` = 100_000).
const SECOND_PUSH_SOURCE_TS_MS: u64 = 99_500;

/// `now_ms` (100_000) + 1: one millisecond ahead of the fixture clock.
const FUTURE_SOURCE_TS_MS: u64 = 100_001;

/// Equal to the oracle's initial SVI source timestamp (fields start at 0), so
/// the non-advancing source check skips the update.
const INITIAL_SOURCE_TS_MS: u64 = 0;

/// 1.05 x default_live_price (100e9).
const FIVE_PCT_ABOVE_LIVE_PRICE: u64 = 105_000_000_000;

/// Forward giving basis 200e9 / 100e9 = 2.0.
const DOUBLE_LIVE_PRICE_FORWARD: u64 = 200_000_000_000;

/// 105e9 / 100e9 = 1.05 in 1e9 scaling.
const BASIS_ONE_POINT_ZERO_FIVE: u64 = 1_050_000_000;

/// 200e9 / 100e9 = 2.0 in 1e9 scaling.
const BASIS_TWO: u64 = 2_000_000_000;

/// Post-expiry Pyth observation offsets used to settle the oracle: the source
/// timestamp lands after expiry and within default_settlement_freshness_ms
/// (3_000) of the update-time clock, so the observation latches and settles.
const POST_EXPIRY_SOURCE_OFFSET_MS: u64 = 1_000;
const POST_EXPIRY_UPDATE_OFFSET_MS: u64 = 2_000;

/// Distinct from `test_constants::pyth_feed_id()` (1): creates a second real
/// Pyth source that is not the one bound to the fixture's oracle.
const OTHER_PYTH_FEED_ID: u32 = 2;

const EUnexpectedSuccess: u64 = 999;

#[test, expected_failure(abort_code = market_oracle::EInvalidMarketOracleWriterCap)]
fun update_svi_with_unregistered_cap_aborts() {
    let (mut fx, _pyth, mut oracle, _config) = setup();
    let admin_cap = admin::new(fx.scenario_mut().ctx());
    let unregistered_cap = market_oracle_writer_cap::create(&admin_cap, fx.scenario_mut().ctx());
    oracle.update_svi(
        &unregistered_cap,
        default_svi(),
        test_constants::live_source_timestamp_ms(),
        fx.clock(),
    );
    abort EUnexpectedSuccess
}

#[test]
fun price_push_on_settled_oracle_is_noop() {
    let (mut fx, mut pyth, mut oracle, config) = setup();
    seed_live_prices(&fx, &config, &mut oracle);
    settle(&mut fx, &config, &mut oracle, &mut pyth);
    let post_settle_ts = oracle.expiry() + POST_EXPIRY_UPDATE_OFFSET_MS;
    push_prices(
        &fx,
        &config,
        &mut oracle,
        FIVE_PCT_ABOVE_LIVE_PRICE,
        FIVE_PCT_ABOVE_LIVE_PRICE,
        post_settle_ts,
    );
    assert_eq!(oracle.block_scholes_spot(), test_constants::default_live_price());
    assert_eq!(oracle.block_scholes_forward(), test_constants::default_live_price());
    assert_eq!(
        oracle.block_scholes_price_source_timestamp_ms(),
        test_constants::live_source_timestamp_ms(),
    );
    oracle_fixture::return_oracle(pyth, oracle, config);
    fx.finish();
}

#[test]
fun large_spot_step_updates() {
    let (fx, pyth, mut oracle, config) = setup();
    seed_live_prices(&fx, &config, &mut oracle);
    push_prices(
        &fx,
        &config,
        &mut oracle,
        FIVE_PCT_ABOVE_LIVE_PRICE,
        FIVE_PCT_ABOVE_LIVE_PRICE,
        SECOND_PUSH_SOURCE_TS_MS,
    );
    assert_eq!(oracle.block_scholes_spot(), FIVE_PCT_ABOVE_LIVE_PRICE);
    assert_eq!(oracle.block_scholes_forward(), FIVE_PCT_ABOVE_LIVE_PRICE);
    oracle_fixture::return_oracle(pyth, oracle, config);
    fx.finish();
}

#[test]
fun large_basis_step_updates() {
    let (fx, pyth, mut oracle, config) = setup();
    seed_live_prices(&fx, &config, &mut oracle);
    push_prices(
        &fx,
        &config,
        &mut oracle,
        test_constants::default_live_price(),
        FIVE_PCT_ABOVE_LIVE_PRICE,
        SECOND_PUSH_SOURCE_TS_MS,
    );
    assert_eq!(oracle.block_scholes_spot(), test_constants::default_live_price());
    assert_eq!(oracle.block_scholes_forward(), FIVE_PCT_ABOVE_LIVE_PRICE);
    assert_eq!(oracle.block_scholes_basis(), BASIS_ONE_POINT_ZERO_FIVE);
    oracle_fixture::return_oracle(pyth, oracle, config);
    fx.finish();
}

#[test]
fun out_of_old_basis_range_updates() {
    let (fx, pyth, mut oracle, config) = setup();
    push_prices(
        &fx,
        &config,
        &mut oracle,
        test_constants::default_live_price(),
        DOUBLE_LIVE_PRICE_FORWARD,
        test_constants::live_source_timestamp_ms(),
    );
    assert_eq!(oracle.block_scholes_spot(), test_constants::default_live_price());
    assert_eq!(oracle.block_scholes_forward(), DOUBLE_LIVE_PRICE_FORWARD);
    assert_eq!(oracle.block_scholes_basis(), BASIS_TWO);
    oracle_fixture::return_oracle(pyth, oracle, config);
    fx.finish();
}

#[test, expected_failure(abort_code = market_oracle::EZeroSpot)]
fun zero_spot_push_aborts() {
    let (fx, _pyth, mut oracle, config) = setup();
    push_prices(
        &fx,
        &config,
        &mut oracle,
        0,
        test_constants::default_live_price(),
        test_constants::live_source_timestamp_ms(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = market_oracle::EZeroForward)]
fun zero_forward_push_aborts() {
    let (fx, _pyth, mut oracle, config) = setup();
    push_prices(
        &fx,
        &config,
        &mut oracle,
        test_constants::default_live_price(),
        0,
        test_constants::live_source_timestamp_ms(),
    );
    abort EUnexpectedSuccess
}

#[test]
fun price_push_with_non_advancing_source_timestamp_is_noop() {
    let (fx, pyth, mut oracle, config) = setup();
    seed_live_prices(&fx, &config, &mut oracle);
    // Repeat the seed's source timestamp with different prices: skipped, stored
    // prices unchanged.
    push_prices(
        &fx,
        &config,
        &mut oracle,
        FIVE_PCT_ABOVE_LIVE_PRICE,
        FIVE_PCT_ABOVE_LIVE_PRICE,
        test_constants::live_source_timestamp_ms(),
    );
    assert_eq!(oracle.block_scholes_spot(), test_constants::default_live_price());
    assert_eq!(oracle.block_scholes_forward(), test_constants::default_live_price());
    // The skip does not poison the sequence: an advancing push still lands.
    push_prices(
        &fx,
        &config,
        &mut oracle,
        FIVE_PCT_ABOVE_LIVE_PRICE,
        FIVE_PCT_ABOVE_LIVE_PRICE,
        SECOND_PUSH_SOURCE_TS_MS,
    );
    assert_eq!(oracle.block_scholes_spot(), FIVE_PCT_ABOVE_LIVE_PRICE);
    assert_eq!(oracle.block_scholes_price_source_timestamp_ms(), SECOND_PUSH_SOURCE_TS_MS);
    oracle_fixture::return_oracle(pyth, oracle, config);
    fx.finish();
}

#[test]
fun svi_update_with_non_advancing_source_timestamp_is_noop() {
    let (fx, pyth, mut oracle, config) = setup();
    // Repeat the initial zero source timestamp: skipped, stored SVI unchanged.
    oracle.update_svi(fx.cap(), default_svi(), INITIAL_SOURCE_TS_MS, fx.clock());
    assert_eq!(oracle.block_scholes_svi().sigma(), 0);
    assert_eq!(oracle.block_scholes_svi_source_timestamp_ms(), INITIAL_SOURCE_TS_MS);
    // The skip does not poison the sequence: an advancing update still lands.
    oracle.update_svi(
        fx.cap(),
        default_svi(),
        test_constants::live_source_timestamp_ms(),
        fx.clock(),
    );
    assert_eq!(oracle.block_scholes_svi().sigma(), constants::svi_sigma_min!());
    assert_eq!(
        oracle.block_scholes_svi_source_timestamp_ms(),
        test_constants::live_source_timestamp_ms(),
    );
    oracle_fixture::return_oracle(pyth, oracle, config);
    fx.finish();
}

#[test]
fun svi_update_on_pending_settlement_oracle_is_noop() {
    let (mut fx, pyth, mut oracle, config) = setup();
    fx.set_clock_for_testing(oracle.expiry() + POST_EXPIRY_UPDATE_OFFSET_MS);
    // Expired but unsettled: SVI is live-only, so the update is skipped.
    oracle.update_svi(
        fx.cap(),
        default_svi(),
        test_constants::live_source_timestamp_ms(),
        fx.clock(),
    );
    assert_eq!(oracle.block_scholes_svi().sigma(), 0);
    assert_eq!(oracle.block_scholes_svi_source_timestamp_ms(), 0);
    oracle_fixture::return_oracle(pyth, oracle, config);
    fx.finish();
}

#[test, expected_failure(abort_code = market_oracle::EFuturePriceSourceUpdate)]
fun price_push_with_future_source_timestamp_aborts() {
    let (fx, _pyth, mut oracle, config) = setup();
    let live = test_constants::default_live_price();
    push_prices(&fx, &config, &mut oracle, live, live, FUTURE_SOURCE_TS_MS);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = market_oracle::EFutureSVISourceUpdate)]
fun svi_update_with_future_source_timestamp_aborts() {
    let (fx, _pyth, mut oracle, _config) = setup();
    oracle.update_svi(fx.cap(), default_svi(), FUTURE_SOURCE_TS_MS, fx.clock());
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = market_oracle::EWrongPythSource)]
fun pyth_observation_from_unbound_source_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let admin_cap = admin::new(fx.scenario_mut().ctx());
    let mut registry = fx.scenario_mut().take_shared<Registry>();
    let other_pyth_id = registry::create_pyth_source(
        &mut registry,
        &admin_cap,
        OTHER_PYTH_FEED_ID,
        test_constants::default_tick_size(),
        fx.scenario_mut().ctx(),
    );
    return_shared(registry);
    fx.scenario_mut().next_tx(test_constants::admin());
    let (_pyth, mut oracle, _config) = fx.take_oracle();
    let other_pyth = fx.scenario_mut().take_shared_by_id<PythSource>(other_pyth_id);
    oracle.record_pyth_settlement_observation(&other_pyth, fx.clock());
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = market_oracle::EPackageVersionDisabled)]
fun update_svi_after_current_version_disabled_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let admin_cap = admin::new(fx.scenario_mut().ctx());
    let mut registry = fx.scenario_mut().take_shared<Registry>();
    let (_pyth, mut oracle, _config) = fx.take_oracle();
    registry::enable_version(&mut registry, &admin_cap, constants::current_version!() + 1);
    registry::disable_version(&mut registry, &admin_cap, constants::current_version!());
    registry::sync_market_oracle_allowed_versions(&registry, &mut oracle);
    oracle.update_svi(
        fx.cap(),
        default_svi(),
        test_constants::live_source_timestamp_ms(),
        fx.clock(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = deepbook_predict::settlement_state::EMarketNotSettled)]
fun settlement_price_read_before_settlement_aborts() {
    let (_fx, _pyth, oracle, _config) = setup();
    oracle.settlement_price();
    abort EUnexpectedSuccess
}

// === Helpers ===

/// Default oracle bring-up with the three shared objects already taken.
fun setup(): (OracleFixture, PythSource, MarketOracle, ProtocolConfig) {
    let mut fx = oracle_fixture::setup_oracle_default();
    let (pyth, oracle, config) = fx.take_oracle();
    (fx, pyth, oracle, config)
}

/// Push Block Scholes prices through the fixture's authorized cap.
fun push_prices(
    fx: &OracleFixture,
    _config: &ProtocolConfig,
    oracle: &mut MarketOracle,
    spot: u64,
    forward: u64,
    source_timestamp_ms: u64,
) {
    oracle.update_block_scholes_prices(
        fx.cap(),
        spot,
        forward,
        source_timestamp_ms,
        fx.clock(),
    );
}

/// Seed a first valid push (spot = forward = default_live_price, basis 1.0) at
/// the fixture's live source timestamp, so the deviation and staleness guards
/// have a prior to compare against.
fun seed_live_prices(fx: &OracleFixture, config: &ProtocolConfig, oracle: &mut MarketOracle) {
    push_prices(
        fx,
        config,
        oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        test_constants::live_source_timestamp_ms(),
    );
}

/// The fixture-default valid SVI parameter set (mirrors
/// `oracle_fixture::prepare_live_oracle`).
fun default_svi(): SVIParams {
    market_oracle::new_svi_params(
        test_constants::default_svi_a(),
        test_constants::default_svi_b(),
        i64::from_u64(test_constants::default_svi_rho_magnitude()),
        i64::from_u64(test_constants::default_svi_m()),
        constants::svi_sigma_min!(),
    )
}

/// Settle the fixture oracle via a fresh post-expiry Pyth spot (the
/// single-observation fallback settlement path).
fun settle(
    fx: &mut OracleFixture,
    config: &ProtocolConfig,
    oracle: &mut MarketOracle,
    pyth: &mut PythSource,
) {
    let expiry = oracle.expiry();
    fx.set_clock_for_testing(expiry + POST_EXPIRY_UPDATE_OFFSET_MS);
    fx.set_pyth(pyth, test_constants::default_live_price(), expiry + POST_EXPIRY_SOURCE_OFFSET_MS);
    let mut generator = random::new_generator_for_testing();
    oracle.settle_with_generator_for_testing(config, pyth, &mut generator, fx.clock());
    assert!(oracle.is_settled());
}
