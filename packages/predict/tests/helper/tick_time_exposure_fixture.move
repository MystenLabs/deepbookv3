// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Standalone `StrikeExposure` books over a live oracle fixture, for the
/// delayed-execution exposure tests (slice C). The exposure is a plain local
/// value the test destroys, like the payout-tree unit tests; the oracle fixture
/// supplies the `Pricer`.
#[test_only]
module deepbook_predict::tick_time_exposure_fixture;

use deepbook_predict::{
    oracle_fixture::{Self, OracleBundle, OracleFixture},
    strike_exposure::{Self, StrikeExposure},
    strike_exposure_config::{Self, StrikeExposureConfig},
    test_constants
};
use std::unit_test::destroy;

/// The zero-forward surface: Block Scholes spot 1e17 (under the spot ceiling)
/// with forward 1, re-anchored at a Pyth spot of 1e9, so the forward
/// `1e9 * 1 / 1e17` floors to 0.
const ZERO_FORWARD_BS_SPOT: u64 = 100_000_000_000_000_000;
const ZERO_FORWARD_BS_FORWARD: u64 = 1;
const ZERO_FORWARD_PYTH_SPOT: u64 = 1_000_000_000;

/// A short-expiry market at the default ATM live oracle, and an exposure book
/// for it with `config` on the default fine and admission grids.
public fun setup(
    config: StrikeExposureConfig,
    inventory_impact_scale: u64,
): (OracleFixture, OracleBundle, StrikeExposure) {
    let mut fx = oracle_fixture::setup_oracle(
        test_constants::default_live_price(),
        test_constants::default_tick_size(),
        test_constants::short_expiry_ms(),
    );
    let expiry_id = fx.expiry_id();
    let exposure = new_exposure(&mut fx, expiry_id, config, inventory_impact_scale);
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    (fx, oracle, exposure)
}

/// A surface whose re-anchored forward floors to zero, so every finite-strike
/// digital aborts `pricing::EZeroForward` (the `pricing_guard_tests` surface:
/// Block Scholes spot 1e17 with forward 1, Pyth spot 1e9).
public fun setup_zero_forward(
    config: StrikeExposureConfig,
    inventory_impact_scale: u64,
): (OracleFixture, OracleBundle, StrikeExposure) {
    let mut fx = oracle_fixture::setup_oracle_default();
    let expiry_id = fx.expiry_id();
    let exposure = new_exposure(&mut fx, expiry_id, config, inventory_impact_scale);
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        ZERO_FORWARD_BS_SPOT,
        ZERO_FORWARD_BS_FORWARD,
        test_constants::default_svi_a(),
        false,
        test_constants::default_svi_b(),
        test_constants::default_svi_sigma(),
        test_constants::default_svi_rho_magnitude(),
        false,
        test_constants::default_svi_m(),
        false,
    );
    let pyth_source_ts = fx.clock().timestamp_ms();
    fx.set_pyth_bundle(&mut oracle, ZERO_FORWARD_PYTH_SPOT, pyth_source_ts);
    (fx, oracle, exposure)
}

/// A second exposure book bound to a different market ID, for binding checks.
public fun other_exposure(
    fx: &mut OracleFixture,
    config: StrikeExposureConfig,
    inventory_impact_scale: u64,
): StrikeExposure {
    let id = object::new(fx.scenario_mut().ctx());
    let other_market_id = id.to_inner();
    id.delete();
    new_exposure(fx, other_market_id, config, inventory_impact_scale)
}

/// Default config with the backing-buffer lambda and inventory-impact rate set.
public fun config(
    backing_buffer_lambda: u64,
    inventory_impact_max_rate: u64,
): StrikeExposureConfig {
    let mut config = strike_exposure_config::new();
    config.set_lambda(backing_buffer_lambda);
    config.set_impact(inventory_impact_max_rate);
    config
}

public fun finish(fx: OracleFixture, oracle: OracleBundle, exposure: StrikeExposure) {
    destroy(exposure);
    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

fun new_exposure(
    fx: &mut OracleFixture,
    expiry_market_id: ID,
    config: StrikeExposureConfig,
    inventory_impact_scale: u64,
): StrikeExposure {
    let expiry_ms = fx.expiry();
    strike_exposure::new(
        expiry_market_id,
        config,
        test_constants::default_tick_size(),
        test_constants::default_admission_tick_size(),
        expiry_ms - test_constants::default_cadence_period_ms(),
        inventory_impact_scale,
        fx.scenario_mut().ctx(),
    )
}
