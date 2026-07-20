// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Live-Pricer memo, payout-walk, and leveraged-floor correction accounting.
#[test_only]
module deepbook_predict::scope_mechanics__intent_accounting__live_valuation_tests;

use deepbook_predict::{
    constants,
    expiry_market::ExpiryMarket,
    liquidation_book,
    market_setup,
    oracle_profile::{Self, SurfaceProfile},
    oracle_setup,
    order,
    pricing::{Self, PriceMemo, Pricer},
    protocol_config::ProtocolConfig,
    range_codec,
    strike_payout_tree,
    test_values,
    test_world::{Self, OwnedResources, World}
};
use fixed_math::math;
use propbook::{
    block_scholes_forward_feed::BlockScholesForwardFeed,
    block_scholes_spot_feed::BlockScholesSpotFeed,
    block_scholes_svi_feed::BlockScholesSVIFeed,
    pyth_feed::PythFeed,
    registry::OracleRegistry
};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::return_shared;

const LOW_TICK: u64 = 90;
const MID_TICK: u64 = 100;
const HIGH_TICK: u64 = 110;
const EQUAL_PRICE_LOW_TICK: u64 = 101;
const EQUAL_PRICE_HIGH_TICK: u64 = 102;
const FIRST_QUANTITY: u64 = 1_000_000_000;
const SECOND_QUANTITY: u64 = 2_000_000_000;
const LOW_FLOOR: u64 = 100_000_000;
const HIGH_FLOOR: u64 = 900_000_000;
const FIRST_SEQUENCE: u64 = 1;
const SECOND_SEQUENCE: u64 = 2;
const ZERO_FLOOR: u64 = 0;

fun seed_and_load_pricer(
    world: &mut World,
    resources: &OwnedResources,
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    oracle_registry: &OracleRegistry,
    pyth: &mut PythFeed,
    bs_spot: &mut BlockScholesSpotFeed,
    bs_forward: &mut BlockScholesForwardFeed,
    bs_svi: &mut BlockScholesSVIFeed,
    profile: &SurfaceProfile,
): Pricer {
    oracle_setup::seed_surface(
        pyth,
        bs_spot,
        bs_forward,
        bs_svi,
        market.expiry(),
        profile,
        test_values::now_ms(),
        test_world::clock(resources),
        test_world::ctx(world),
    );
    market.load_live_pricer(
        config,
        oracle_registry,
        pyth,
        bs_spot,
        bs_forward,
        bs_svi,
        test_world::clock(resources),
    )
}

#[test]
fun equal_boundary_prices_are_cacheable_and_reusable() {
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
    let profile = oracle_profile::exact_half();
    let pricer = seed_and_load_pricer(
        &mut world,
        &resources,
        &market,
        &config,
        &oracle_registry,
        &mut pyth,
        &mut bs_spot,
        &mut bs_forward,
        &mut bs_svi,
        &profile,
    );
    let mut memo = pricing::new_price_memo();

    let low = memo.price_and_cache(&pricer, EQUAL_PRICE_LOW_TICK, test_values::tick_size());
    let high = memo.price_and_cache(&pricer, EQUAL_PRICE_HIGH_TICK, test_values::tick_size());

    assert_eq!(low, high);
    assert_eq!(memo.cached_range_price(EQUAL_PRICE_LOW_TICK, EQUAL_PRICE_HIGH_TICK), 0);

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
fun linear_walk_matches_independent_range_composition_and_populates_memo() {
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
    let pricer = seed_and_load_pricer(
        &mut world,
        &resources,
        &market,
        &config,
        &oracle_registry,
        &mut pyth,
        &mut bs_spot,
        &mut bs_forward,
        &mut bs_svi,
        &profile,
    );
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(LOW_TICK, HIGH_TICK, FIRST_QUANTITY, ZERO_FLOOR);
    tree.insert_range(MID_TICK, constants::pos_inf_tick!(), SECOND_QUANTITY, ZERO_FLOOR);
    let mut memo = pricing::new_price_memo();

    let liability = tree.walk_linear(&pricer, &mut memo, test_values::tick_size());
    let first_probability = pricer.range_price(
        range_codec::strike_from_tick(LOW_TICK, test_values::tick_size()),
        range_codec::strike_from_tick(HIGH_TICK, test_values::tick_size()),
    );
    let second_probability = pricer.range_price(
        range_codec::strike_from_tick(MID_TICK, test_values::tick_size()),
        range_codec::strike_from_tick(constants::pos_inf_tick!(), test_values::tick_size()),
    );
    let expected =
        math::mul(first_probability, FIRST_QUANTITY)
        + math::mul(second_probability, SECOND_QUANTITY);

    assert_eq!(liability, expected);
    assert_eq!(memo.cached_range_price(LOW_TICK, HIGH_TICK), first_probability);
    assert_eq!(memo.cached_range_price(MID_TICK, constants::pos_inf_tick!()), second_probability);

    destroy(tree);
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
fun leveraged_floor_correction_sums_each_order_minimum_independently() {
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
    let profile = oracle_profile::exact_half();
    let pricer = seed_and_load_pricer(
        &mut world,
        &resources,
        &market,
        &config,
        &oracle_registry,
        &mut pyth,
        &mut bs_spot,
        &mut bs_forward,
        &mut bs_svi,
        &profile,
    );
    let mut memo = pricing::new_price_memo();
    let forward_probability = memo.price_and_cache(&pricer, MID_TICK, test_values::tick_size());
    assert_eq!(forward_probability, math::float_scaling!() / 2);

    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    let below = order::new_from_ticks(
        0,
        MID_TICK,
        LOW_FLOOR,
        FIRST_QUANTITY,
        FIRST_SEQUENCE,
    );
    let above = order::new_from_ticks(
        MID_TICK,
        constants::pos_inf_tick!(),
        HIGH_FLOOR,
        FIRST_QUANTITY,
        SECOND_SEQUENCE,
    );
    book.insert_order(&below);
    book.insert_order(&above);

    let correction = book.correction_value(&memo);
    let half_quantity = math::float_scaling!() / 2;
    let expected = LOW_FLOOR + half_quantity;
    assert_eq!(correction, expected);

    destroy(book);
    return_shared(bs_svi);
    return_shared(bs_forward);
    return_shared(bs_spot);
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(market);
    test_world::finish(world, resources);
}
