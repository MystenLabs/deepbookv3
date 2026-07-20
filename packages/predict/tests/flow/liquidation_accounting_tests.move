// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Exact knockout and zero-payout cleanup accounting through public flows.
#[test_only]
module deepbook_predict::scope_flow__intent_accounting__liquidation_tests;

use account::account;
use deepbook_predict::{
    account_setup,
    constants,
    market_setup,
    oracle_profile,
    oracle_setup,
    pool_setup,
    predict_account,
    test_values,
    test_world
};
use dusdc::dusdc::DUSDC;
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

const LEVERAGE_TWO_X: u64 = 2_000_000_000; // 2x in 1e9 scale
const MINT_COST: u64 = 255_000_000; // 2x ATM net_premium 2.5e8 (entry 5e8 - financed 2.5e8) + fee 5e6
const LIVE_BACKING: u64 = 750_000_000; // payout backing = quantity 1e9 - floor_shares 2.5e8 (2x)
const DROPPED_SPOT: u64 = 99_000_000_000; // 99e9 spot drop to force the order liquidatable
const DROPPED_SOURCE_MS: u64 = 119_500; // source timestamp for the dropped-spot observation

#[test]
fun liquidated_order_removes_backing_and_pays_zero_exactly_once() {
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
    let cash_before_mint = market.cash_balance();
    let auth = account::generate_auth(test_world::ctx(&mut world));
    let order_id = market.mint_exact_quantity(
        &mut wrapper,
        auth,
        &config,
        &pricer,
        test_values::strike_tick(),
        constants::pos_inf_tick!(),
        test_values::mint_quantity(),
        LEVERAGE_TWO_X,
        MINT_COST,
        std::u64::max_value!(),
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    let market_id = market.id();
    assert_eq!(market.payout_liability(), LIVE_BACKING);
    assert_eq!(market.cash_balance() - cash_before_mint, MINT_COST);
    assert!(predict_account::has_position(wrapper.load_account(), market_id, order_id));
    return_shared(bs_svi);
    return_shared(bs_forward);
    return_shared(bs_spot);
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(market);
    return_shared(root);
    return_shared(wrapper);

    test_world::next_tx(&mut world, test_values::admin());
    let dropped = oracle_profile::new(
        DROPPED_SPOT,
        DROPPED_SPOT,
        DROPPED_SPOT,
        1,
        false,
        0,
        1_000_000,
        0,
        false,
        0,
        false,
        DROPPED_SOURCE_MS,
    );
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &market_handle,
        &dropped,
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::bob());
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
    let cash_before_liquidation = market.cash_balance();
    assert_eq!(market.order_value(option::some(pricer), order_id), 0);
    assert_eq!(market.liquidate(&config, &pricer, 0, test_world::clock(&resources)), 0);
    assert_eq!(market.payout_liability(), LIVE_BACKING);
    assert_eq!(market.cash_balance(), cash_before_liquidation);
    assert!(market.liquidate_order(&config, &pricer, order_id, test_world::clock(&resources)));
    assert_eq!(market.payout_liability(), 0);
    assert_eq!(market.cash_balance(), cash_before_liquidation);
    assert!(!market.liquidate_order(&config, &pricer, order_id, test_world::clock(&resources)));
    return_shared(bs_svi);
    return_shared(bs_forward);
    return_shared(bs_spot);
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(market);

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
    let balance_before_cleanup = wrapper
        .load_account()
        .balance<DUSDC>(&root, test_world::clock(&resources));
    let cash_before_cleanup = market.cash_balance();
    let auth = account::generate_auth(test_world::ctx(&mut world));
    let (closed, replacement) = market.redeem_live(
        &mut wrapper,
        auth,
        &config,
        &pricer,
        order_id,
        test_values::mint_quantity(),
        0,
        0,
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    assert_eq!(closed, order_id);
    assert!(replacement.is_none());
    assert_eq!(
        wrapper.load_account().balance<DUSDC>(&root, test_world::clock(&resources)),
        balance_before_cleanup,
    );
    assert_eq!(market.cash_balance(), cash_before_cleanup);
    assert!(!predict_account::has_position(wrapper.load_account(), market_id, order_id));
    assert!(!market.liquidate_order(&config, &pricer, order_id, test_world::clock(&resources)));

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
