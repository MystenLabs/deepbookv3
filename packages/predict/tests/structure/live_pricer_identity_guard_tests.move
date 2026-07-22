// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Canonical-feed replacement and pre-expiry identity guards for live pricing.
#[test_only]
module deepbook_predict::scope_structure__intent_guard__live_pricer_identity_tests;

use deepbook_predict::{market_setup, oracle_setup, pricing, test_values, test_world};
use sui::test_scenario::return_shared;

const REPLACEMENT_SOURCE_ID: u32 = 2;
const EUnexpectedSuccess: u64 = 999;

#[test, expected_failure(abort_code = pricing::EWrongBlockScholesSpotFeed)]
fun unbound_block_scholes_spot_feed_aborts_live_pricing() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::admin());
    let predict_admin_cap = test_world::take_predict_admin_cap(&world);
    market_setup::configure_default_cadence(&world, &predict_admin_cap);
    test_world::return_predict_admin_cap(&world, predict_admin_cap);
    let canonical = oracle_setup::create_default_oracles(&mut world);

    test_world::next_tx(&mut world, test_values::admin());
    let propbook_admin_cap = test_world::take_propbook_admin_cap(&world);
    oracle_setup::bind_default_oracles(&world, &propbook_admin_cap, &canonical);
    test_world::return_propbook_admin_cap(&world, propbook_admin_cap);

    test_world::next_tx(&mut world, test_values::admin());
    let unbound = oracle_setup::create_oracles(&mut world, REPLACEMENT_SOURCE_ID);

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
    let pyth = oracle_setup::take_pyth(&world, &canonical);
    let bs_spot = oracle_setup::take_bs_spot(&world, &unbound);
    let bs_forward = oracle_setup::take_bs_forward(&world, &canonical);
    let bs_svi = oracle_setup::take_bs_svi(&world, &canonical);

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

#[test, expected_failure(abort_code = pricing::EWrongBlockScholesForwardFeed)]
fun unbound_block_scholes_forward_feed_aborts_live_pricing() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::admin());
    let predict_admin_cap = test_world::take_predict_admin_cap(&world);
    market_setup::configure_default_cadence(&world, &predict_admin_cap);
    test_world::return_predict_admin_cap(&world, predict_admin_cap);
    let canonical = oracle_setup::create_default_oracles(&mut world);

    test_world::next_tx(&mut world, test_values::admin());
    let propbook_admin_cap = test_world::take_propbook_admin_cap(&world);
    oracle_setup::bind_default_oracles(&world, &propbook_admin_cap, &canonical);
    test_world::return_propbook_admin_cap(&world, propbook_admin_cap);

    test_world::next_tx(&mut world, test_values::admin());
    let unbound = oracle_setup::create_oracles(&mut world, REPLACEMENT_SOURCE_ID);

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
    let pyth = oracle_setup::take_pyth(&world, &canonical);
    let bs_spot = oracle_setup::take_bs_spot(&world, &canonical);
    let bs_forward = oracle_setup::take_bs_forward(&world, &unbound);
    let bs_svi = oracle_setup::take_bs_svi(&world, &canonical);

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

#[test, expected_failure(abort_code = pricing::EWrongBlockScholesSVIFeed)]
fun unbound_block_scholes_svi_feed_aborts_live_pricing() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::admin());
    let predict_admin_cap = test_world::take_predict_admin_cap(&world);
    market_setup::configure_default_cadence(&world, &predict_admin_cap);
    test_world::return_predict_admin_cap(&world, predict_admin_cap);
    let canonical = oracle_setup::create_default_oracles(&mut world);

    test_world::next_tx(&mut world, test_values::admin());
    let propbook_admin_cap = test_world::take_propbook_admin_cap(&world);
    oracle_setup::bind_default_oracles(&world, &propbook_admin_cap, &canonical);
    test_world::return_propbook_admin_cap(&world, propbook_admin_cap);

    test_world::next_tx(&mut world, test_values::admin());
    let unbound = oracle_setup::create_oracles(&mut world, REPLACEMENT_SOURCE_ID);

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
    let pyth = oracle_setup::take_pyth(&world, &canonical);
    let bs_spot = oracle_setup::take_bs_spot(&world, &canonical);
    let bs_forward = oracle_setup::take_bs_forward(&world, &canonical);
    let bs_svi = oracle_setup::take_bs_svi(&world, &unbound);

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

#[test, expected_failure(abort_code = pricing::EWrongPythFeed)]
fun old_oracle_bundle_is_rejected_after_canonical_replacement() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::admin());
    let predict_admin_cap = test_world::take_predict_admin_cap(&world);
    market_setup::configure_default_cadence(&world, &predict_admin_cap);
    test_world::return_predict_admin_cap(&world, predict_admin_cap);
    let original = oracle_setup::create_default_oracles(&mut world);

    test_world::next_tx(&mut world, test_values::admin());
    let propbook_admin_cap = test_world::take_propbook_admin_cap(&world);
    oracle_setup::bind_default_oracles(&world, &propbook_admin_cap, &original);
    test_world::return_propbook_admin_cap(&world, propbook_admin_cap);

    test_world::next_tx(&mut world, test_values::admin());
    let replacement = oracle_setup::create_oracles(&mut world, REPLACEMENT_SOURCE_ID);

    test_world::next_tx(&mut world, test_values::admin());
    let mut oracle_registry = test_world::take_oracle_registry(&world);
    let propbook_admin_cap = test_world::take_propbook_admin_cap(&world);
    let replacement_pyth = oracle_setup::take_pyth(&world, &replacement);
    let replacement_spot = oracle_setup::take_bs_spot(&world, &replacement);
    let replacement_forward = oracle_setup::take_bs_forward(&world, &replacement);
    let replacement_svi = oracle_setup::take_bs_svi(&world, &replacement);
    oracle_registry.replace_pyth_binding_for_underlying(
        &propbook_admin_cap,
        &replacement_pyth,
        test_values::propbook_underlying_id(),
    );
    oracle_registry.replace_block_scholes_bindings_for_underlying(
        &propbook_admin_cap,
        &replacement_spot,
        &replacement_forward,
        &replacement_svi,
        test_values::propbook_underlying_id(),
    );
    return_shared(replacement_svi);
    return_shared(replacement_forward);
    return_shared(replacement_spot);
    return_shared(replacement_pyth);
    test_world::return_propbook_admin_cap(&world, propbook_admin_cap);
    return_shared(oracle_registry);

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
    let pyth = oracle_setup::take_pyth(&world, &original);
    let bs_spot = oracle_setup::take_bs_spot(&world, &original);
    let bs_forward = oracle_setup::take_bs_forward(&world, &original);
    let bs_svi = oracle_setup::take_bs_svi(&world, &original);

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

#[test, expected_failure(abort_code = pricing::ELivePricingExpired)]
fun live_pricing_at_the_expiry_timestamp_aborts() {
    let (mut world, mut resources) = test_world::new(
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
    let pyth = oracle_setup::take_pyth(&world, &oracles);
    let bs_spot = oracle_setup::take_bs_spot(&world, &oracles);
    let bs_forward = oracle_setup::take_bs_forward(&world, &oracles);
    let bs_svi = oracle_setup::take_bs_svi(&world, &oracles);
    test_world::clock_mut(&mut resources).set_for_testing(market.expiry());

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
