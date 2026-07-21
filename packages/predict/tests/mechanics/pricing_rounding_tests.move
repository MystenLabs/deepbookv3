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

const RAW_UNIT: u64 = 1;
const SOURCE_AGE_MS: u64 = 1_000;
const MIN_SVI_SIGMA: u64 = 1_000_000;

#[test]
fun one_raw_variance_unit_at_forward_is_exactly_one_half() {
    let profile = oracle_profile::exact_half();
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
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &market_handle,
        &profile,
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::admin());
    let market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let (pricer, feeds) = oracle_setup::load_pricer(&world, &resources, &oracles, &market, &config);

    let actual = pricer.range_price(
        range_codec::strike_from_tick(test_values::strike_tick(), test_values::tick_size()),
        range_codec::strike_from_tick(constants::pos_inf_tick!(), test_values::tick_size()),
    );
    assert_eq!(actual, math::float_scaling!() / 2);

    oracle_setup::return_feeds(feeds);
    return_shared(config);
    return_shared(market);
    test_world::finish(world, resources);
}

#[test]
fun sub_scale_strike_ratio_saturates_to_one() {
    let profile = oracle_profile::exact_half();
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
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &market_handle,
        &profile,
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::admin());
    let market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let (pricer, feeds) = oracle_setup::load_pricer(&world, &resources, &oracles, &market, &config);

    let actual = pricer.range_price(
        range_codec::strike_for_testing(RAW_UNIT),
        range_codec::strike_from_tick(constants::pos_inf_tick!(), test_values::tick_size()),
    );

    assert_eq!(actual, math::float_scaling!());

    oracle_setup::return_feeds(feeds);
    return_shared(config);
    return_shared(market);
    test_world::finish(world, resources);
}

#[test]
fun overflowing_strike_ratio_saturates_to_zero() {
    let profile = oracle_profile::new(
        RAW_UNIT,
        RAW_UNIT,
        RAW_UNIT,
        RAW_UNIT,
        false,
        0,
        MIN_SVI_SIGMA,
        0,
        false,
        0,
        false,
        test_values::now_ms() - SOURCE_AGE_MS,
    );
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
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &market_handle,
        &profile,
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::admin());
    let market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let (pricer, feeds) = oracle_setup::load_pricer(&world, &resources, &oracles, &market, &config);

    let actual = pricer.range_price(
        range_codec::strike_for_testing(std::u64::max_value!() - RAW_UNIT),
        range_codec::strike_from_tick(constants::pos_inf_tick!(), test_values::tick_size()),
    );

    assert_eq!(actual, 0);

    oracle_setup::return_feeds(feeds);
    return_shared(config);
    return_shared(market);
    test_world::finish(world, resources);
}
