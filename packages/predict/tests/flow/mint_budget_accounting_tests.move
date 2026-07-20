// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Exact lot sizing and account debits for net-premium-budget mints.
#[test_only]
module deepbook_predict::scope_flow__intent_accounting__mint_budget_tests;

use account::account;
use deepbook_predict::{
    account_setup,
    constants,
    market_setup,
    oracle_profile,
    oracle_setup,
    order,
    pool_setup,
    test_values,
    test_world
};
use dusdc::dusdc::DUSDC;
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

const BUDGET_BELOW_NEXT_LOT: u64 = 50_004_999;
const TEN_THOUSAND_LOTS: u64 = 100_000_000;
const TEN_THOUSAND_LOTS_DEBIT: u64 = 50_500_000;
const BUDGET_AT_NEXT_LOT: u64 = 50_005_000;
const NEXT_LOT_QUANTITY: u64 = 100_010_000;
const NEXT_LOT_DEBIT: u64 = 50_505_050;
const LOT_CAP_QUANTITY: u64 = 42_949_672_950_000;
const LOT_CAP_NET_PREMIUM: u64 = 21_474_836_475_000;

#[test]
fun budget_mints_largest_fitting_quantity_and_debits_its_exact_cost() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    market_setup::configure_trading_defaults(&world, &admin_cap);
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
    let profile = oracle_profile::exact_half();
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &market_handle,
        &profile,
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
    let oracle_registry = test_world::take_oracle_registry(&world);
    let pyth = oracle_setup::take_pyth(&world, &oracles);
    let bs_spot = oracle_setup::take_bs_spot(&world, &oracles);
    let bs_forward = oracle_setup::take_bs_forward(&world, &oracles);
    let bs_svi = oracle_setup::take_bs_svi(&world, &oracles);
    let pricer = market.load_live_pricer(
        &config,
        &oracle_registry,
        &pyth,
        &bs_spot,
        &bs_forward,
        &bs_svi,
        test_world::clock(&resources),
    );
    let balance_before = wrapper
        .load_account()
        .balance<DUSDC>(&root, test_world::clock(&resources));
    let auth = account::generate_auth(test_world::ctx(&mut world));
    let order_id = market.mint_exact_amount(
        &mut wrapper,
        auth,
        &config,
        &pricer,
        test_values::strike_tick(),
        constants::pos_inf_tick!(),
        BUDGET_BELOW_NEXT_LOT,
        TEN_THOUSAND_LOTS,
        test_values::leverage_one_x(),
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    assert_eq!(order::from_order_id(order_id).quantity(), TEN_THOUSAND_LOTS);
    assert_eq!(
        balance_before
            - wrapper
                .load_account()
                .balance<DUSDC>(&root, test_world::clock(&resources)),
        TEN_THOUSAND_LOTS_DEBIT,
    );

    return_shared(bs_svi);
    return_shared(bs_forward);
    return_shared(bs_spot);
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(market);
    return_shared(root);
    return_shared(wrapper);
    test_world::finish(world, resources);
}

#[test]
fun budget_at_next_lot_premium_mints_the_next_lot() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    market_setup::configure_trading_defaults(&world, &admin_cap);
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
    let profile = oracle_profile::exact_half();
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &market_handle,
        &profile,
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
    let oracle_registry = test_world::take_oracle_registry(&world);
    let pyth = oracle_setup::take_pyth(&world, &oracles);
    let bs_spot = oracle_setup::take_bs_spot(&world, &oracles);
    let bs_forward = oracle_setup::take_bs_forward(&world, &oracles);
    let bs_svi = oracle_setup::take_bs_svi(&world, &oracles);
    let pricer = market.load_live_pricer(
        &config,
        &oracle_registry,
        &pyth,
        &bs_spot,
        &bs_forward,
        &bs_svi,
        test_world::clock(&resources),
    );
    let balance_before = wrapper
        .load_account()
        .balance<DUSDC>(&root, test_world::clock(&resources));
    let auth = account::generate_auth(test_world::ctx(&mut world));
    let order_id = market.mint_exact_amount(
        &mut wrapper,
        auth,
        &config,
        &pricer,
        test_values::strike_tick(),
        constants::pos_inf_tick!(),
        BUDGET_AT_NEXT_LOT,
        NEXT_LOT_QUANTITY,
        test_values::leverage_one_x(),
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    assert_eq!(order::from_order_id(order_id).quantity(), NEXT_LOT_QUANTITY);
    assert_eq!(
        balance_before
            - wrapper
                .load_account()
                .balance<DUSDC>(&root, test_world::clock(&resources)),
        NEXT_LOT_DEBIT,
    );

    return_shared(bs_svi);
    return_shared(bs_forward);
    return_shared(bs_spot);
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(market);
    return_shared(root);
    return_shared(wrapper);
    test_world::finish(world, resources);
}

#[test]
fun oversized_budget_saturates_at_the_lot_cap_without_aborting() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    market_setup::configure_trading_defaults(&world, &admin_cap);
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
    let profile = oracle_profile::exact_half();
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &market_handle,
        &profile,
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::alice());
    let market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let pyth = oracle_setup::take_pyth(&world, &oracles);
    let bs_spot = oracle_setup::take_bs_spot(&world, &oracles);
    let bs_forward = oracle_setup::take_bs_forward(&world, &oracles);
    let bs_svi = oracle_setup::take_bs_svi(&world, &oracles);
    let pricer = market.load_live_pricer(
        &config,
        &oracle_registry,
        &pyth,
        &bs_spot,
        &bs_forward,
        &bs_svi,
        test_world::clock(&resources),
    );
    let quote = market.quote_mint(
        &config,
        &pricer,
        test_values::strike_tick(),
        constants::pos_inf_tick!(),
        std::u64::max_value!(),
        LOT_CAP_QUANTITY,
        false,
        test_values::leverage_one_x(),
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    assert_eq!(quote.quantity(), LOT_CAP_QUANTITY);
    assert_eq!(quote.net_premium(), LOT_CAP_NET_PREMIUM);

    return_shared(bs_svi);
    return_shared(bs_forward);
    return_shared(bs_spot);
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(market);
    test_world::finish(world, resources);
}
