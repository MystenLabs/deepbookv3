// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Live-pricer source projections, freshness selection, and accepted feed separation.
#[test_only]
module deepbook_predict::scope_structure__intent_behavior__live_pricer_tests;

use deepbook_predict::{
    market_setup,
    oracle_profile,
    oracle_setup,
    pricing,
    range_codec,
    test_values,
    test_world
};
use fixed_math::math;
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

const PYTH_SOURCE_MS: u64 = 119_100;
const BS_SPOT_SOURCE_MS: u64 = 119_200;
const BS_FORWARD_SOURCE_MS: u64 = 119_300;
const BS_SVI_SOURCE_MS: u64 = 119_400;
const STALENESS_SOURCE_MS: u64 = 119_500;
const PYTH_FRESHNESS_MS: u64 = 2_000;
const BS_SPOT: u64 = 100_000_000_000;
const DIVERGED_PYTH_SPOT: u64 = 102_000_000_000;
const EXTREME_PYTH_SPOT: u64 = 51_000_000_000;
const EXTREME_BS_SPOT: u64 = 1_000_000_000;
const EXTREME_BS_FORWARD: u64 = 100_000_000_000;
const EXTREME_REANCHORED_FORWARD: u64 = 5_100_000_000_000;
const FLAT_SVI_A: u64 = 1;
const FLAT_SVI_SIGMA: u64 = 1_000_000;

#[test]
fun pricer_snapshots_each_distinct_oracle_source_timestamp() {
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
    let profile = oracle_profile::smoke_at(BS_SVI_SOURCE_MS);
    oracle_setup::seed_pyth(
        &mut pyth,
        profile.pyth_spot(),
        PYTH_SOURCE_MS,
        test_values::now_ms(),
    );
    oracle_setup::seed_bs_spot(
        &mut bs_spot,
        profile.block_scholes_spot(),
        BS_SPOT_SOURCE_MS,
        test_world::clock(&resources),
    );
    oracle_setup::seed_bs_forward(
        &mut bs_forward,
        market.expiry(),
        profile.block_scholes_forward(),
        BS_FORWARD_SOURCE_MS,
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

    let pricer = market.load_live_pricer(
        &config,
        &oracle_registry,
        &pyth,
        &bs_spot,
        &bs_forward,
        &bs_svi,
        test_world::clock(&resources),
    );

    assert_eq!(pricing::pyth_spot_source_timestamp_ms(&pricer), PYTH_SOURCE_MS);
    assert_eq!(pricing::block_scholes_spot_source_timestamp_ms(&pricer), BS_SPOT_SOURCE_MS);
    assert_eq!(pricing::block_scholes_forward_source_timestamp_ms(&pricer), BS_FORWARD_SOURCE_MS);
    assert_eq!(pricing::block_scholes_svi_source_timestamp_ms(&pricer), BS_SVI_SOURCE_MS);

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
fun live_forward_switches_source_one_ms_past_pyth_freshness() {
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
    let mut pyth = oracle_setup::take_pyth(&world, &oracles);
    let mut bs_spot = oracle_setup::take_bs_spot(&world, &oracles);
    let mut bs_forward = oracle_setup::take_bs_forward(&world, &oracles);
    let mut bs_svi = oracle_setup::take_bs_svi(&world, &oracles);
    let profile = oracle_profile::new(
        oracle_profile::spot_prices(DIVERGED_PYTH_SPOT, BS_SPOT, BS_SPOT),
        oracle_profile::svi_params(FLAT_SVI_A, false, 0, FLAT_SVI_SIGMA, 0, false, 0, false),
        STALENESS_SOURCE_MS,
    );
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

    test_world::clock_mut(&mut resources).set_for_testing(
        STALENESS_SOURCE_MS + PYTH_FRESHNESS_MS,
    );
    let at_boundary = market.load_live_pricer(
        &config,
        &oracle_registry,
        &pyth,
        &bs_spot,
        &bs_forward,
        &bs_svi,
        test_world::clock(&resources),
    );
    assert_eq!(
        at_boundary.up_price(range_codec::strike_for_testing(DIVERGED_PYTH_SPOT)),
        math::float_scaling!() / 2,
    );

    test_world::clock_mut(&mut resources).set_for_testing(
        STALENESS_SOURCE_MS + PYTH_FRESHNESS_MS + 1,
    );
    let one_ms_stale = market.load_live_pricer(
        &config,
        &oracle_registry,
        &pyth,
        &bs_spot,
        &bs_forward,
        &bs_svi,
        test_world::clock(&resources),
    );
    assert_eq!(
        one_ms_stale.up_price(range_codec::strike_for_testing(BS_SPOT)),
        math::float_scaling!() / 2,
    );

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
fun live_pricer_accepts_pricing_safe_cross_feed_deviation() {
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
    let profile = oracle_profile::new(
        oracle_profile::spot_prices(EXTREME_PYTH_SPOT, EXTREME_BS_SPOT, EXTREME_BS_FORWARD),
        oracle_profile::svi_params(FLAT_SVI_A, false, 0, FLAT_SVI_SIGMA, 0, false, 0, false),
        BS_SVI_SOURCE_MS,
    );
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

    assert_eq!(
        pricer.up_price(range_codec::strike_for_testing(EXTREME_REANCHORED_FORWARD)),
        math::float_scaling!() / 2,
    );

    return_shared(bs_svi);
    return_shared(bs_forward);
    return_shared(bs_spot);
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(market);
    test_world::finish(world, resources);
}
