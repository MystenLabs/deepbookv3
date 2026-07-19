// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Structural guards for incomplete canonical live-oracle state.
#[test_only]
module deepbook_predict::scope_structure__intent_guard__oracle_tests;

use deepbook_predict::{
    market_setup,
    oracle_profile,
    oracle_setup,
    pricing,
    test_values,
    test_world
};
use sui::test_scenario::return_shared;

#[test, expected_failure(abort_code = pricing::EBlockScholesPriceUnavailable)]
fun missing_forward_value_aborts_live_pricing() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::admin());
    market_setup::configure_default_cadence(&mut world, &resources);
    let oracles = oracle_setup::create_default_oracles(&mut world);

    test_world::next_tx(&mut world, test_values::admin());
    oracle_setup::bind_default_oracles(&world, &resources, &oracles);

    test_world::next_tx(&mut world, test_values::admin());
    let (market_handle, _lifecycle_cap) = market_setup::create_default_market(
        &mut world,
        &resources,
    );

    test_world::next_tx(&mut world, test_values::admin());
    let market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let mut pyth = oracle_setup::take_pyth(&world, &oracles);
    let mut bs_spot = oracle_setup::take_bs_spot(&world, &oracles);
    let bs_forward = oracle_setup::take_bs_forward(&world, &oracles);
    let mut bs_svi = oracle_setup::take_bs_svi(&world, &oracles);
    let profile = oracle_profile::smoke();

    oracle_setup::seed_pyth(
        &mut pyth,
        profile.pyth_spot(),
        profile.source_timestamp_ms(),
        test_values::now_ms(),
    );
    oracle_setup::seed_bs_spot(
        &mut bs_spot,
        profile.block_scholes_spot(),
        profile.source_timestamp_ms(),
        test_world::clock(&resources),
    );
    oracle_setup::seed_bs_svi(
        &mut bs_svi,
        market_setup::expiry_ms(&market_handle),
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

    return_shared(bs_svi);
    return_shared(bs_forward);
    return_shared(bs_spot);
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(market);
    abort 999
}
