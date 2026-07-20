// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Exact partition identities over a production-loaded live pricer.
#[test_only]
module deepbook_predict::scope_mechanics__intent_behavior__pricing_tests;

use deepbook_predict::{
    constants,
    market_setup,
    oracle_profile,
    oracle_setup,
    range_codec,
    test_values,
    test_world
};
use fixed_math::math;
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

#[test]
fun complementary_ranges_sum_to_one_at_the_forward() {
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
    let profile = oracle_profile::smoke();
    oracle_setup::seed_surface(
        &mut pyth,
        &mut bs_spot,
        &mut bs_forward,
        &mut bs_svi,
        market.expiry(),
        &profile,
        test_values::now_ms(),
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    let pricer = market.load_live_pricer(
        &config,
        &oracle_registry,
        &pyth,
        &bs_spot,
        &bs_forward,
        &bs_svi,
        test_world::clock(&resources),
    );

    let below = pricer.range_price(
        range_codec::strike_from_tick(0, test_values::tick_size()),
        range_codec::strike_for_testing(profile.block_scholes_forward()),
    );
    let above = pricer.range_price(
        range_codec::strike_for_testing(profile.block_scholes_forward()),
        range_codec::strike_from_tick(constants::pos_inf_tick!(), test_values::tick_size()),
    );

    assert_eq!(below + above, math::float_scaling!());
    assert!(above > 0 && above < math::float_scaling!());

    return_shared(bs_svi);
    return_shared(bs_forward);
    return_shared(bs_spot);
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(market);
    test_world::finish(world, resources);
}

#[test]
fun whole_line_range_is_certain() {
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
    let profile = oracle_profile::smoke();
    oracle_setup::seed_surface(
        &mut pyth,
        &mut bs_spot,
        &mut bs_forward,
        &mut bs_svi,
        market.expiry(),
        &profile,
        test_values::now_ms(),
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    let pricer = market.load_live_pricer(
        &config,
        &oracle_registry,
        &pyth,
        &bs_spot,
        &bs_forward,
        &bs_svi,
        test_world::clock(&resources),
    );

    let whole = pricer.range_price(
        range_codec::strike_from_tick(0, test_values::tick_size()),
        range_codec::strike_from_tick(constants::pos_inf_tick!(), test_values::tick_size()),
    );
    assert_eq!(whole, math::float_scaling!());

    return_shared(bs_svi);
    return_shared(bs_forward);
    return_shared(bs_spot);
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(market);
    test_world::finish(world, resources);
}
