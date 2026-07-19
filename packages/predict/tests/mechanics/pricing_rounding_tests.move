// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Exact fixed-point pricing behavior for an algebraically exact surface.
#[test_only]
module deepbook_predict::scope_mechanics__intent_rounding__pricing_tests;

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
fun one_raw_variance_unit_at_forward_is_exactly_one_half() {
    let profile = oracle_profile::exact_half();
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
    let (market_handle, lifecycle_cap) = market_setup::create_default_market(
        &mut world,
        &resources,
    );

    test_world::next_tx(&mut world, test_values::admin());
    let market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let mut pyth = oracle_setup::take_pyth(&world, &oracles);
    let mut bs_spot = oracle_setup::take_bs_spot(&world, &oracles);
    let mut bs_forward = oracle_setup::take_bs_forward(&world, &oracles);
    let mut bs_svi = oracle_setup::take_bs_svi(&world, &oracles);
    oracle_setup::seed_surface(
        &mut pyth,
        &mut bs_spot,
        &mut bs_forward,
        &mut bs_svi,
        market_setup::expiry_ms(&market_handle),
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

    let actual = pricer.range_price(
        range_codec::strike_from_tick(test_values::strike_tick(), test_values::tick_size()),
        range_codec::strike_from_tick(constants::pos_inf_tick!(), test_values::tick_size()),
    );
    assert_eq!(actual, math::float_scaling!() / 2);

    return_shared(bs_svi);
    return_shared(bs_forward);
    return_shared(bs_spot);
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(market);
    lifecycle_cap.destroy();
    test_world::finish(world, resources);
}
