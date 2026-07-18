// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Mint accounting coverage from an explicitly production-funded market.
#[test_only]
module deepbook_predict::flow_mint_accounting_tests;

use account::{account::{Self, AccountWrapper}, account_registry::AccountRegistry};
use deepbook_predict::{
    constants,
    market_setup,
    oracle_profile,
    oracle_setup,
    predict_account,
    test_values,
    test_world
};
use dusdc::dusdc::DUSDC;
use std::{u64, unit_test::assert_eq};
use sui::{coin, test_scenario::return_shared};

#[test]
fun mint_preserves_cash_and_liability_accounting() {
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
    let mut vault = test_world::take_vault(&world);
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let capital = coin::mint_for_testing<DUSDC>(
        test_values::pool_capital(),
        test_world::ctx(&mut world),
    );
    vault.lock_capital(
        &config,
        test_world::predict_admin_cap(&resources),
        capital,
    );
    vault.rebalance_expiry_cash(
        &mut market,
        &config,
        test_world::clock(&resources),
    );
    return_shared(config);
    return_shared(market);
    return_shared(vault);

    test_world::next_tx(&mut world, test_values::admin());
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
        market_setup::expiry_ms(&market_handle),
        &profile,
        test_values::now_ms(),
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    return_shared(bs_svi);
    return_shared(bs_forward);
    return_shared(bs_spot);
    return_shared(pyth);

    test_world::next_tx(&mut world, test_values::alice());
    let mut account_registry = test_world::take_account_registry(&world);
    let root = test_world::take_accumulator_root(&world);
    let mut wrapper = account_registry.new(test_world::ctx(&mut world));
    let wrapper_id = wrapper.id();
    let deposit = coin::mint_for_testing<DUSDC>(
        test_values::trader_deposit(),
        test_world::ctx(&mut world),
    );
    let auth = account::generate_auth(test_world::ctx(&mut world));
    account::deposit_funds(
        &mut wrapper,
        auth,
        deposit,
        &root,
        test_world::clock(&resources),
    );
    assert_eq!(
        wrapper.load_account().balance<DUSDC>(&root, test_world::clock(&resources)),
        test_values::trader_deposit(),
    );
    wrapper.share();
    return_shared(root);
    return_shared(account_registry);

    test_world::next_tx(&mut world, test_values::alice());
    let mut wrapper = test_world::take_shared_by_id<AccountWrapper>(&world, wrapper_id);
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
    let account_balance_before = wrapper
        .load_account()
        .balance<DUSDC>(&root, test_world::clock(&resources));
    let market_cash_before = market.cash_balance();
    let payout_liability_before = market.payout_liability();
    let rebate_reserve_before = market.rebate_reserve();
    let trading_fees_before = predict_account::trading_fees_paid(
        wrapper.load_account(),
        market_setup::market_id(&market_handle),
    );

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
        u64::max_value!(),
        u64::max_value!(),
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );

    let account = wrapper.load_account();
    let account_balance_after = account.balance<DUSDC>(&root, test_world::clock(&resources));
    let market_cash_after = market.cash_balance();
    let payout_liability_after = market.payout_liability();
    let rebate_reserve_after = market.rebate_reserve();
    let trading_fees_after = predict_account::trading_fees_paid(
        account,
        market_setup::market_id(&market_handle),
    );
    let account_debit = account_balance_before - account_balance_after;
    let market_cash_credit = market_cash_after - market_cash_before;
    let trading_fee = trading_fees_after - trading_fees_before;

    assert!(account_debit > 0);
    assert_eq!(market_cash_credit, account_debit);
    assert_eq!(payout_liability_after - payout_liability_before, test_values::mint_quantity());
    assert!(trading_fee > 0 && trading_fee <= account_debit);
    assert!(rebate_reserve_after >= rebate_reserve_before);
    assert!(rebate_reserve_after - rebate_reserve_before <= trading_fee);
    assert!(
        predict_account::has_position(
            account,
            market_setup::market_id(&market_handle),
            order_id,
        ),
    );
    assert_eq!(
        predict_account::expiry_position_count(account, market_setup::market_id(&market_handle)),
        1,
    );
    assert_eq!(
        predict_account::trading_fees_paid(account, market_setup::market_id(&market_handle)),
        trading_fees_after,
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
    lifecycle_cap.destroy();
    test_world::finish(world, resources);
}
