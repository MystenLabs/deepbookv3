// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Loads a `VolSnapshot` through the production `pricing::load_vol` path
/// against the `oracle_fixture` feeds, bound to the fixture's market and expiry.
#[test_only]
module deepbook_predict::vol_snapshot_test_helpers;

use deepbook_predict::{
    oracle_fixture::{Self, OracleBundle, OracleFixture},
    pricing::{Self, Pricer, VolSnapshot},
    protocol_config::ProtocolConfig,
    test_constants
};
use propbook::{
    block_scholes_store::{BlockScholesSVIStore, BlockScholesValueStore},
    pyth_feed::PythFeed,
    registry::OracleRegistry
};
use sui::clock;

/// The order-flow policy's launch SVI age bound. The policy and its defaults
/// live in the order-flow companion; Predict only caps the bound at
/// `constants::max_svi_max_age_ms`.
const DEFAULT_SVI_MAX_AGE_MS: u64 = 60_000;

public fun default_svi_max_age_ms(): u64 { DEFAULT_SVI_MAX_AGE_MS }

/// Load a snapshot and its t₀ Pricer from the bundled feeds at the fixture clock.
public fun load_snapshot(
    fx: &mut OracleFixture,
    oracle: &OracleBundle,
    svi_max_age_ms: u64,
): (VolSnapshot, Pricer) {
    load_snapshot_with_stores(
        fx,
        oracle_fixture::config(oracle),
        oracle_fixture::oracle_registry(oracle),
        oracle_fixture::pyth(oracle),
        oracle_fixture::bs(oracle).values(),
        oracle_fixture::bs(oracle).svi(),
        svi_max_age_ms,
    )
}

/// Load a snapshot from explicit feed objects (binding-guard and same-transaction tests).
public fun load_snapshot_with_stores(
    fx: &mut OracleFixture,
    config: &ProtocolConfig,
    oracle_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    svi_max_age_ms: u64,
): (VolSnapshot, Pricer) {
    // The load borrows a clock and the scenario's context at once, so it reads a
    // local clock set to the fixture's time.
    let mut clock = clock::create_for_testing(fx.scenario_mut().ctx());
    clock.set_for_testing(fx.clock().timestamp_ms());
    let expiry_market_id = fx.expiry_id();
    let expiry = fx.expiry();
    let (snapshot, pricer) = pricing::load_vol(
        config.pricing_cfg(),
        oracle_registry,
        pyth,
        bs_values,
        bs_svi,
        expiry_market_id,
        test_constants::propbook_underlying_id(),
        expiry,
        svi_max_age_ms,
        &clock,
        fx.scenario_mut().ctx(),
    );
    clock.destroy_for_testing();
    (snapshot, pricer)
}
