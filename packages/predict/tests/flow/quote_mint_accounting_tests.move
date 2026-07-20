// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Exact quote-to-mint payment composition for an exact-half live market.
#[test_only]
module deepbook_predict::scope_flow__intent_accounting__quote_mint_tests;

use account::account;
use deepbook_predict::{
    account_setup,
    builder_code::BuilderCode,
    config_constants,
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

const ENTRY_PROBABILITY_ATM: u64 = 500_000_000;
const NET_PREMIUM_ATM: u64 = 500_000_000;
const MIN_TRADING_FEE: u64 = 5_000_000;
const ALL_IN_MINT_COST: u64 = 505_000_000;
const BUILDER_CODE_INDEX: u64 = 0;
const BUILDER_FEE_ATM: u64 = 500_000;
const ALL_IN_WITH_BUILDER: u64 = 505_500_000;
const VARIANCE_SEED_QUANTITY: u64 = 100_000_000;
const VARIANCE_SEED_COST: u64 = 50_500_000;
const EWMA_PENALTY: u64 = 1_000_000;
const ALL_IN_WITH_PENALTY: u64 = 506_000_000;

#[test]
fun quote_matches_independent_costs_and_mint_debits_exactly_all_in_cost() {
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

    let quote = market.quote_mint(
        &config,
        &pricer,
        test_values::strike_tick(),
        constants::pos_inf_tick!(),
        0,
        test_values::mint_quantity(),
        true,
        test_values::leverage_one_x(),
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    assert_eq!(quote.entry_probability(), ENTRY_PROBABILITY_ATM);
    assert_eq!(quote.net_premium(), NET_PREMIUM_ATM);
    assert_eq!(quote.trading_fee(), MIN_TRADING_FEE);
    assert_eq!(quote.fee_incentive_subsidy(), 0);
    assert_eq!(quote.builder_fee(), 0);
    assert_eq!(quote.penalty_fee(), 0);
    assert_eq!(quote.all_in_cost(), ALL_IN_MINT_COST);

    let balance_before = wrapper
        .load_account()
        .balance<DUSDC>(&root, test_world::clock(&resources));
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
        quote.all_in_cost(),
        std::u64::max_value!(),
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    let account = wrapper.load_account();
    assert_eq!(
        balance_before - account.balance<DUSDC>(&root, test_world::clock(&resources)),
        ALL_IN_MINT_COST,
    );
    assert!(predict_account::has_position(account, market.id(), order_id));

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
fun builder_attribution_raises_account_quote_and_mint_debit_exactly() {
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
    let mut registry = test_world::take_registry(&world);
    let config = test_world::take_config(&world);
    let code_id = registry.create_and_share_builder_code(
        &config,
        BUILDER_CODE_INDEX,
        test_world::ctx(&mut world),
    );
    return_shared(config);
    return_shared(registry);

    test_world::next_tx(&mut world, test_values::alice());
    let mut wrapper = account_setup::take_account(&world, &account_handle);
    let code = test_world::take_shared_by_id<BuilderCode>(&world, code_id);
    let auth = account::generate_auth(test_world::ctx(&mut world));
    predict_account::set_builder_code(&mut wrapper, auth, &code, test_world::ctx(&mut world));
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

    let anonymous = market.quote_mint(
        &config,
        &pricer,
        test_values::strike_tick(),
        constants::pos_inf_tick!(),
        0,
        test_values::mint_quantity(),
        true,
        test_values::leverage_one_x(),
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    let account_quote = market.quote_mint_for_account(
        &wrapper,
        &config,
        &pricer,
        test_values::strike_tick(),
        constants::pos_inf_tick!(),
        0,
        test_values::mint_quantity(),
        true,
        test_values::leverage_one_x(),
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    assert_eq!(anonymous.builder_fee(), 0);
    assert_eq!(anonymous.all_in_cost(), ALL_IN_MINT_COST);
    assert_eq!(account_quote.builder_fee(), BUILDER_FEE_ATM);
    assert_eq!(account_quote.all_in_cost(), ALL_IN_WITH_BUILDER);

    let balance_before = wrapper
        .load_account()
        .balance<DUSDC>(&root, test_world::clock(&resources));
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
        account_quote.all_in_cost(),
        std::u64::max_value!(),
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    let account = wrapper.load_account();
    assert_eq!(
        balance_before - account.balance<DUSDC>(&root, test_world::clock(&resources)),
        ALL_IN_WITH_BUILDER,
    );
    assert!(predict_account::has_position(account, market.id(), order_id));

    return_shared(bs_svi);
    return_shared(bs_forward);
    return_shared(bs_spot);
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(market);
    return_shared(root);
    return_shared(code);
    return_shared(wrapper);
    test_world::finish(world, resources);
}

#[test]
fun ewma_penalty_included_in_quote_and_mint_debits_exactly() {
    let (mut world, mut resources) = test_world::new(
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
    let mut config = test_world::take_config(&world);
    let admin_cap = test_world::take_predict_admin_cap(&world);
    config.set_ewma_params(
        &admin_cap,
        config_constants::default_ewma_alpha!(),
        config_constants::min_ewma_z_score_threshold!(),
        config_constants::default_ewma_penalty_rate!(),
    );
    config.set_ewma_enabled(&admin_cap, true);
    test_world::return_predict_admin_cap(&world, admin_cap);
    return_shared(config);
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

    test_world::next_tx_with_gas_price(&mut world, test_values::alice(), 2_000);
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
    let seed_balance = wrapper.load_account().balance<DUSDC>(&root, test_world::clock(&resources));
    let auth = account::generate_auth(test_world::ctx(&mut world));
    let _ = market.mint_exact_quantity(
        &mut wrapper,
        auth,
        &config,
        &pricer,
        test_values::strike_tick(),
        constants::pos_inf_tick!(),
        VARIANCE_SEED_QUANTITY,
        test_values::leverage_one_x(),
        std::u64::max_value!(),
        std::u64::max_value!(),
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    assert_eq!(
        seed_balance
            - wrapper
                .load_account()
                .balance<DUSDC>(&root, test_world::clock(&resources)),
        VARIANCE_SEED_COST,
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

    test_world::next_tx_with_gas_price(&mut world, test_values::alice(), 3_000);
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
    let quote = market.quote_mint(
        &config,
        &pricer,
        test_values::strike_tick(),
        constants::pos_inf_tick!(),
        0,
        test_values::mint_quantity(),
        true,
        test_values::leverage_one_x(),
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    assert_eq!(quote.penalty_fee(), EWMA_PENALTY);
    assert_eq!(quote.all_in_cost(), ALL_IN_WITH_PENALTY);
    let balance_before = wrapper
        .load_account()
        .balance<DUSDC>(&root, test_world::clock(&resources));
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
        quote.all_in_cost(),
        std::u64::max_value!(),
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    assert_eq!(
        balance_before
            - wrapper
                .load_account()
                .balance<DUSDC>(&root, test_world::clock(&resources)),
        ALL_IN_WITH_PENALTY,
    );
    assert!(predict_account::has_position(wrapper.load_account(), market.id(), order_id));

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
