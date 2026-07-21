// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end live-NAV rounding at the aggregate-linear/per-order-correction seam.
#[test_only]
module deepbook_predict::scope_flow__intent_rounding__current_nav_red_tests;

use account::account;
use deepbook_predict::{
    account_setup,
    constants,
    market_setup,
    oracle_profile,
    oracle_setup,
    pool_setup,
    pricing_reference_data,
    test_values,
    test_world
};
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

const ENTRY_FORWARD: u64 = 110_000_000_000;
const ENTRY_TICK: u64 = 110;
const ENTRY_SOURCE_MS: u64 = 118_000;
const POSITION_QUANTITY: u64 = 4_000_000;
const LEVERAGE_TWO_X: u64 = 2_000_000_000;
const ORDER_COUNT: u64 = 4;
const REPRICE_PROFILE_INDEX: u64 = 0;

// KNOWN-FAILING: P-14
#[test]
fun liquidatable_orders_leave_positive_aggregate_live_liability() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    market_setup::configure_low_fee_unrestricted_leverage_market(&world, &admin_cap);
    test_world::return_predict_admin_cap(&world, admin_cap);
    let oracles = oracle_setup::create_default_oracles(&mut world);
    test_world::next_tx(&mut world, test_values::admin());
    let oracle_admin_cap = test_world::take_propbook_admin_cap(&world);
    oracle_setup::bind_default_oracles(&world, &oracle_admin_cap, &oracles);
    test_world::return_propbook_admin_cap(&world, oracle_admin_cap);
    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let market_handle = market_setup::create_default_market(&mut world, &resources, &admin_cap);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::next_tx(&mut world, test_values::admin());
    pool_setup::fund_market(
        &mut world,
        &resources,
        &market_handle,
        test_values::pool_capital(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let entry_profile = oracle_profile::new(
        ENTRY_FORWARD,
        ENTRY_FORWARD,
        ENTRY_FORWARD,
        1,
        false,
        0,
        1_000_000,
        0,
        false,
        0,
        false,
        ENTRY_SOURCE_MS,
    );
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &market_handle,
        &entry_profile,
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::alice());
    let account_handle = account_setup::create_funded_account(
        &mut world,
        &resources,
        test_values::trader_deposit(),
    );

    test_world::next_tx(&mut world, test_values::alice());
    let mut wrapper = account_setup::take_account(&world, &account_handle);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let (pricer, feeds) = oracle_setup::load_pricer(&world, &resources, &oracles, &market, &config);
    let mut order_ids = vector[];
    let mut index = 0;
    while (index < ORDER_COUNT) {
        let auth = account::generate_auth(test_world::ctx(&mut world));
        order_ids.push_back(market.mint_exact_quantity(
            &mut wrapper,
            auth,
            &config,
            &pricer,
            ENTRY_TICK,
            constants::pos_inf_tick!(),
            POSITION_QUANTITY,
            LEVERAGE_TWO_X,
            std::u64::max_value!(),
            std::u64::max_value!(),
            &root,
            test_world::clock(&resources),
            test_world::ctx(&mut world),
        ));
        index = index + 1;
    };
    assert_eq!(order_ids.length(), ORDER_COUNT);
    oracle_setup::return_feeds(feeds);
    return_shared(config);
    return_shared(market);
    return_shared(root);
    return_shared(wrapper);

    test_world::next_tx(&mut world, test_values::admin());
    let repriced_profile = pricing_reference_data::profile(REPRICE_PROFILE_INDEX);
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &market_handle,
        &repriced_profile,
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::bob());
    let market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let (pricer, feeds) = oracle_setup::load_pricer(&world, &resources, &oracles, &market, &config);
    let mut index = 0;
    while (index < order_ids.length()) {
        assert_eq!(market.order_value(option::some(pricer), order_ids[index]), 0);
        index = index + 1;
    };
    let independently_recoverable_nav = market.cash_balance() - market.rebate_reserve();
    assert_eq!(market.current_nav(&pricer), independently_recoverable_nav);

    oracle_setup::return_feeds(feeds);
    return_shared(config);
    return_shared(market);
    test_world::finish(world, resources);
}
