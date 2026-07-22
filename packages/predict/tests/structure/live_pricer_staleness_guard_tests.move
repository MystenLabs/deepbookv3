// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Independent spot, forward, and SVI live-pricing freshness guards.
#[test_only]
module deepbook_predict::scope_structure__intent_guard__live_pricer_staleness_tests;

use deepbook_predict::{
    market_setup,
    oracle_profile,
    oracle_setup,
    pricing,
    test_values,
    test_world
};

const FRESHNESS_MS: u64 = 1;
const FRESH_SOURCE_MS: u64 = 119_999;
const STALE_SOURCE_MS: u64 = 119_998;
const EUnexpectedSuccess: u64 = 999;

#[test, expected_failure(abort_code = pricing::EBlockScholesPriceStale)]
fun stale_block_scholes_spot_aborts_live_pricing() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::admin());
    let predict_admin_cap = test_world::take_predict_admin_cap(&world);
    market_setup::configure_default_cadence(&world, &predict_admin_cap);
    test_world::return_predict_admin_cap(&world, predict_admin_cap);
    let oracles = oracle_setup::create_default_oracles(&mut world);

    test_world::next_tx(&mut world, test_values::admin());
    let predict_admin_cap = test_world::take_predict_admin_cap(&world);
    let mut config = test_world::take_config(&world);
    config.set_block_scholes_price_freshness_ms(&predict_admin_cap, FRESHNESS_MS);
    test_world::return_predict_admin_cap(&world, predict_admin_cap);
    sui::test_scenario::return_shared(config);
    let propbook_admin_cap = test_world::take_propbook_admin_cap(&world);
    oracle_setup::bind_default_oracles(&world, &propbook_admin_cap, &oracles);
    test_world::return_propbook_admin_cap(&world, propbook_admin_cap);

    test_world::next_tx(&mut world, test_values::admin());
    let predict_admin_cap = test_world::take_predict_admin_cap(&world);
    let market_handle = market_setup::create_default_market(
        &mut world,
        &resources,
        &predict_admin_cap,
    );
    test_world::return_predict_admin_cap(&world, predict_admin_cap);

    test_world::next_tx(&mut world, test_values::admin());
    let market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let mut pyth = oracle_setup::take_pyth(&world, &oracles);
    let mut bs_spot = oracle_setup::take_bs_spot(&world, &oracles);
    let mut bs_forward = oracle_setup::take_bs_forward(&world, &oracles);
    let mut bs_svi = oracle_setup::take_bs_svi(&world, &oracles);
    let profile = oracle_profile::smoke_at(FRESH_SOURCE_MS);
    oracle_setup::seed_pyth(
        &mut pyth,
        profile.pyth_spot(),
        FRESH_SOURCE_MS,
        test_values::now_ms(),
    );
    oracle_setup::seed_bs_spot(
        &mut bs_spot,
        profile.block_scholes_spot(),
        STALE_SOURCE_MS,
        test_world::clock(&resources),
    );
    oracle_setup::seed_bs_forward(
        &mut bs_forward,
        market.expiry(),
        profile.block_scholes_forward(),
        FRESH_SOURCE_MS,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    oracle_setup::seed_bs_svi(
        &mut bs_svi,
        market.expiry(),
        &profile,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );

    let _ = market.load_live_pricer(
        &config,
        &oracle_registry,
        &pyth,
        &bs_spot,
        &bs_forward,
        &bs_svi,
        test_world::clock(&resources),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesPriceStale)]
fun stale_block_scholes_forward_aborts_live_pricing() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::admin());
    let predict_admin_cap = test_world::take_predict_admin_cap(&world);
    market_setup::configure_default_cadence(&world, &predict_admin_cap);
    test_world::return_predict_admin_cap(&world, predict_admin_cap);
    let oracles = oracle_setup::create_default_oracles(&mut world);

    test_world::next_tx(&mut world, test_values::admin());
    let predict_admin_cap = test_world::take_predict_admin_cap(&world);
    let mut config = test_world::take_config(&world);
    config.set_block_scholes_price_freshness_ms(&predict_admin_cap, FRESHNESS_MS);
    test_world::return_predict_admin_cap(&world, predict_admin_cap);
    sui::test_scenario::return_shared(config);
    let propbook_admin_cap = test_world::take_propbook_admin_cap(&world);
    oracle_setup::bind_default_oracles(&world, &propbook_admin_cap, &oracles);
    test_world::return_propbook_admin_cap(&world, propbook_admin_cap);

    test_world::next_tx(&mut world, test_values::admin());
    let predict_admin_cap = test_world::take_predict_admin_cap(&world);
    let market_handle = market_setup::create_default_market(
        &mut world,
        &resources,
        &predict_admin_cap,
    );
    test_world::return_predict_admin_cap(&world, predict_admin_cap);

    test_world::next_tx(&mut world, test_values::admin());
    let market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let mut pyth = oracle_setup::take_pyth(&world, &oracles);
    let mut bs_spot = oracle_setup::take_bs_spot(&world, &oracles);
    let mut bs_forward = oracle_setup::take_bs_forward(&world, &oracles);
    let mut bs_svi = oracle_setup::take_bs_svi(&world, &oracles);
    let profile = oracle_profile::smoke_at(FRESH_SOURCE_MS);
    oracle_setup::seed_pyth(
        &mut pyth,
        profile.pyth_spot(),
        FRESH_SOURCE_MS,
        test_values::now_ms(),
    );
    oracle_setup::seed_bs_spot(
        &mut bs_spot,
        profile.block_scholes_spot(),
        FRESH_SOURCE_MS,
        test_world::clock(&resources),
    );
    oracle_setup::seed_bs_forward(
        &mut bs_forward,
        market.expiry(),
        profile.block_scholes_forward(),
        STALE_SOURCE_MS,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    oracle_setup::seed_bs_svi(
        &mut bs_svi,
        market.expiry(),
        &profile,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );

    let _ = market.load_live_pricer(
        &config,
        &oracle_registry,
        &pyth,
        &bs_spot,
        &bs_forward,
        &bs_svi,
        test_world::clock(&resources),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesSVIStale)]
fun stale_block_scholes_svi_aborts_live_pricing() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::admin());
    let predict_admin_cap = test_world::take_predict_admin_cap(&world);
    market_setup::configure_default_cadence(&world, &predict_admin_cap);
    test_world::return_predict_admin_cap(&world, predict_admin_cap);
    let oracles = oracle_setup::create_default_oracles(&mut world);

    test_world::next_tx(&mut world, test_values::admin());
    let predict_admin_cap = test_world::take_predict_admin_cap(&world);
    let mut config = test_world::take_config(&world);
    config.set_block_scholes_svi_freshness_ms(&predict_admin_cap, FRESHNESS_MS);
    test_world::return_predict_admin_cap(&world, predict_admin_cap);
    sui::test_scenario::return_shared(config);
    let propbook_admin_cap = test_world::take_propbook_admin_cap(&world);
    oracle_setup::bind_default_oracles(&world, &propbook_admin_cap, &oracles);
    test_world::return_propbook_admin_cap(&world, propbook_admin_cap);

    test_world::next_tx(&mut world, test_values::admin());
    let predict_admin_cap = test_world::take_predict_admin_cap(&world);
    let market_handle = market_setup::create_default_market(
        &mut world,
        &resources,
        &predict_admin_cap,
    );
    test_world::return_predict_admin_cap(&world, predict_admin_cap);

    test_world::next_tx(&mut world, test_values::admin());
    let market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let mut pyth = oracle_setup::take_pyth(&world, &oracles);
    let mut bs_spot = oracle_setup::take_bs_spot(&world, &oracles);
    let mut bs_forward = oracle_setup::take_bs_forward(&world, &oracles);
    let mut bs_svi = oracle_setup::take_bs_svi(&world, &oracles);
    let stale_profile = oracle_profile::smoke_at(STALE_SOURCE_MS);
    oracle_setup::seed_pyth(
        &mut pyth,
        stale_profile.pyth_spot(),
        FRESH_SOURCE_MS,
        test_values::now_ms(),
    );
    oracle_setup::seed_bs_spot(
        &mut bs_spot,
        stale_profile.block_scholes_spot(),
        FRESH_SOURCE_MS,
        test_world::clock(&resources),
    );
    oracle_setup::seed_bs_forward(
        &mut bs_forward,
        market.expiry(),
        stale_profile.block_scholes_forward(),
        FRESH_SOURCE_MS,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    oracle_setup::seed_bs_svi(
        &mut bs_svi,
        market.expiry(),
        &stale_profile,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );

    let _ = market.load_live_pricer(
        &config,
        &oracle_registry,
        &pyth,
        &bs_spot,
        &bs_forward,
        &bs_svi,
        test_world::clock(&resources),
    );
    abort EUnexpectedSuccess
}
