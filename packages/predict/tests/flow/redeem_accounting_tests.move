// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Exact account and market accounting for a seasoned live-position close.
#[test_only]
module deepbook_predict::scope_flow__intent_accounting__redeem_tests;

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

// Exact-half profile: gross close = 0.5 * closed quantity, close fee = 0.5% * closed quantity.
const ALL_IN_MINT_COST: u64 = 505_000_000; // net_premium 5e8 + trading_fee 5e6
const PARTIAL_CLOSE_QUANTITY: u64 = 400_000_000; // 4e8 of the 1e9 position
const REMAINING_QUANTITY: u64 = 600_000_000; // 1e9 - 4e8
const PARTIAL_REDEEM_PROCEEDS: u64 = 198_000_000; // gross 0.5*4e8 - close fee 0.5%*4e8
const REMAINING_REDEEM_PROCEEDS: u64 = 297_000_000; // gross 0.5*6e8 - close fee 0.5%*6e8
const LIVE_REDEEM_PROCEEDS: u64 = 495_000_000; // gross 0.5*1e9 - close fee 0.5%*1e9
const ROUND_TRIP_FEES: u64 = 10_000_000; // mint fee 5e6 + close fee 5e6

#[test]
fun global_trading_pause_keeps_exact_full_live_redeem_available() {
    let (mut world, mut resources) = test_world::new(
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
    let (pricer, feeds) = oracle_setup::load_pricer(&world, &resources, &oracles, &market, &config);
    let market_id = market.id();
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
        test_values::leverage_one_x(),
        ALL_IN_MINT_COST,
        std::u64::max_value!(),
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    assert_eq!(
        wrapper.load_account().balance<DUSDC>(&root, test_world::clock(&resources)),
        test_values::trader_deposit() - ALL_IN_MINT_COST,
    );
    assert_eq!(market.cash_balance() - cash_before_mint, ALL_IN_MINT_COST);
    assert!(predict_account::has_position(wrapper.load_account(), market_id, order_id));
    oracle_setup::return_feeds(feeds);
    return_shared(config);
    return_shared(market);
    return_shared(root);
    return_shared(wrapper);

    test_world::clock_mut(&mut resources).set_for_testing(test_values::later_ms());
    test_world::next_tx(&mut world, test_values::admin());
    let profile = oracle_profile::exact_half_at(test_values::now_ms());
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &market_handle,
        &profile,
        test_values::later_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let mut market = market_setup::take_market(&world, &market_handle);
    let mut config = test_world::take_config(&world);
    let admin_cap = test_world::take_predict_admin_cap(&world);
    config.set_trading_paused(&admin_cap, true);
    market.set_mint_paused(&config, &admin_cap, true);
    assert!(config.trading_paused());
    assert!(market.mint_paused());
    test_world::return_predict_admin_cap(&world, admin_cap);
    return_shared(config);
    return_shared(market);

    test_world::next_tx(&mut world, test_values::alice());
    let mut wrapper = account_setup::take_account(&world, &account_handle);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let (pricer, feeds) = oracle_setup::load_pricer(&world, &resources, &oracles, &market, &config);
    let balance_before_redeem = wrapper
        .load_account()
        .balance<DUSDC>(&root, test_world::clock(&resources));
    let cash_before_redeem = market.cash_balance();
    let auth = account::generate_auth(test_world::ctx(&mut world));
    let (closed_id, replacement) = market.redeem_live(
        &mut wrapper,
        auth,
        &config,
        &pricer,
        order_id,
        PARTIAL_CLOSE_QUANTITY,
        0,
        0,
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    assert_eq!(closed_id, order_id);
    let replacement_id = replacement.destroy_some();
    assert_eq!(
        wrapper
            .load_account()
            .balance<DUSDC>(&root, test_world::clock(&resources))
            - balance_before_redeem,
        PARTIAL_REDEEM_PROCEEDS,
    );
    assert_eq!(cash_before_redeem - market.cash_balance(), PARTIAL_REDEEM_PROCEEDS);
    assert!(!predict_account::has_position(wrapper.load_account(), market_id, order_id));
    assert!(predict_account::has_position(wrapper.load_account(), market_id, replacement_id));
    assert_eq!(predict_account::expiry_position_count(wrapper.load_account(), market_id), 1);

    let auth = account::generate_auth(test_world::ctx(&mut world));
    let (closed_id, replacement) = market.redeem_live(
        &mut wrapper,
        auth,
        &config,
        &pricer,
        replacement_id,
        REMAINING_QUANTITY,
        0,
        0,
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    assert_eq!(closed_id, replacement_id);
    assert!(replacement.is_none());
    assert_eq!(
        wrapper
            .load_account()
            .balance<DUSDC>(&root, test_world::clock(&resources))
            - balance_before_redeem,
        LIVE_REDEEM_PROCEEDS,
    );
    assert_eq!(cash_before_redeem - market.cash_balance(), LIVE_REDEEM_PROCEEDS);
    assert_eq!(LIVE_REDEEM_PROCEEDS, PARTIAL_REDEEM_PROCEEDS + REMAINING_REDEEM_PROCEEDS);
    assert_eq!(market.cash_balance() - cash_before_mint, ROUND_TRIP_FEES);
    assert!(!predict_account::has_position(wrapper.load_account(), market_id, order_id));
    assert!(!predict_account::has_position(wrapper.load_account(), market_id, replacement_id));
    assert_eq!(predict_account::expiry_position_count(wrapper.load_account(), market_id), 0);

    oracle_setup::return_feeds(feeds);
    return_shared(config);
    return_shared(market);
    return_shared(root);
    return_shared(wrapper);
    test_world::finish(world, resources);
}
