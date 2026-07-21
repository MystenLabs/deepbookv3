// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Settlement lifecycle behavior: idempotent settlement that keeps its price,
/// settlement through a replaced canonical feed, exact terminal liability
/// materialization, the owner's settled redeem surviving app deauthorization,
/// and full staked-DEEP custody return.
#[test_only]
module deepbook_predict::scope_flow__intent_behavior__settlement_tests;

use account::{account, account_registry};
use deepbook_predict::{
    account_setup,
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
use token::deep::DEEP;

const LOWER_TICK: u64 = 90;
const UPPER_LOSER_TICK: u64 = 110;
const TRADE_QUANTITY: u64 = 20_000_000;
const ALL_IN_TRADE_COST: u64 = 10_100_000; // exact-half premium 10e6 + fee 100e3
const IN_RANGE_SPOT: u64 = 95_000_000_000; // inside (90, 100]
const REBATE_RESERVE_TWO_TRADES: u64 = 100_000; // 0.5 x (2 x 100e3 fees)
const SECOND_PYTH_SOURCE_ID: u32 = 2;
const STAKED_DEEP: u64 = 5_000_000_000;

#[test]
fun try_settle_is_idempotent_and_keeps_settlement_price() {
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

    let expiry_ms = test_values::expiry_ms();
    test_world::clock_mut(&mut resources).set_for_testing(expiry_ms);
    test_world::next_tx(&mut world, test_values::admin());
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let mut pyth = oracle_setup::take_pyth(&world, &oracles);
    oracle_setup::seed_exact_pyth(&mut pyth, IN_RANGE_SPOT, expiry_ms, expiry_ms);
    assert!(
        market.try_settle(
            &config,
            &oracle_registry,
            &pyth,
            test_world::clock(&resources),
        ),
    );
    // The idempotent re-call reports settled and keeps the recorded price.
    assert!(
        market.try_settle(
            &config,
            &oracle_registry,
            &pyth,
            test_world::clock(&resources),
        ),
    );
    assert_eq!(market.settlement_price(), IN_RANGE_SPOT);
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(market);
    test_world::finish(world, resources);
}

#[test]
fun try_settle_uses_rebound_pyth_after_exact_backfill() {
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
    // Replace the canonical Pyth binding, then backfill the exact expiry
    // print on the replacement feed: settlement follows the live binding.
    test_world::next_tx(&mut world, test_values::admin());
    let replacement_oracles = oracle_setup::create_oracles(&mut world, SECOND_PYTH_SOURCE_ID);
    test_world::next_tx(&mut world, test_values::admin());
    let oracle_admin_cap = test_world::take_propbook_admin_cap(&world);
    let mut oracle_registry = test_world::take_oracle_registry(&world);
    let replacement_pyth = oracle_setup::take_pyth(&world, &replacement_oracles);
    oracle_registry.replace_pyth_binding_for_underlying(
        &oracle_admin_cap,
        &replacement_pyth,
        test_values::propbook_underlying_id(),
    );
    return_shared(replacement_pyth);
    return_shared(oracle_registry);
    test_world::return_propbook_admin_cap(&world, oracle_admin_cap);

    let expiry_ms = test_values::expiry_ms();
    test_world::clock_mut(&mut resources).set_for_testing(expiry_ms);
    test_world::next_tx(&mut world, test_values::admin());
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let mut replacement_pyth = oracle_setup::take_pyth(&world, &replacement_oracles);
    oracle_setup::seed_exact_pyth(&mut replacement_pyth, IN_RANGE_SPOT, expiry_ms, expiry_ms);
    assert!(
        market.try_settle(
            &config,
            &oracle_registry,
            &replacement_pyth,
            test_world::clock(&resources),
        ),
    );
    assert_eq!(market.settlement_price(), IN_RANGE_SPOT);
    return_shared(replacement_pyth);
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(market);
    test_world::finish(world, resources);
}

#[test]
fun try_settle_materializes_exact_terminal_liability() {
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
        2 * ALL_IN_TRADE_COST,
    );

    // A winner (90, 100] and a loser (100, 110] at the 95e9 settlement.
    test_world::next_tx(&mut world, test_values::alice());
    let mut wrapper = account_setup::take_account(&world, &account_handle);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let (pricer, feeds) = oracle_setup::load_pricer(&world, &resources, &oracles, &market, &config);
    let auth = account::generate_auth(test_world::ctx(&mut world));
    let _ = market.mint_exact_quantity(
        &mut wrapper,
        auth,
        &config,
        &pricer,
        LOWER_TICK,
        test_values::strike_tick(),
        TRADE_QUANTITY,
        test_values::leverage_one_x(),
        ALL_IN_TRADE_COST,
        std::u64::max_value!(),
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    let auth = account::generate_auth(test_world::ctx(&mut world));
    let _ = market.mint_exact_quantity(
        &mut wrapper,
        auth,
        &config,
        &pricer,
        test_values::strike_tick(),
        UPPER_LOSER_TICK,
        TRADE_QUANTITY,
        test_values::leverage_one_x(),
        ALL_IN_TRADE_COST,
        std::u64::max_value!(),
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    oracle_setup::return_feeds(feeds);
    return_shared(config);
    return_shared(market);
    return_shared(root);
    return_shared(wrapper);

    let expiry_ms = test_values::expiry_ms();
    test_world::clock_mut(&mut resources).set_for_testing(expiry_ms);
    test_world::next_tx(&mut world, test_values::admin());
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let mut pyth = oracle_setup::take_pyth(&world, &oracles);
    oracle_setup::seed_exact_pyth(&mut pyth, IN_RANGE_SPOT, expiry_ms, expiry_ms);
    assert!(
        market.try_settle(
            &config,
            &oracle_registry,
            &pyth,
            test_world::clock(&resources),
        ),
    );
    // Terminal liability is exactly the winner's payout; required cash adds
    // only the unresolved rebate reserve on both trades' fees.
    assert_eq!(market.payout_liability(), TRADE_QUANTITY);
    assert_eq!(market.required_cash(), TRADE_QUANTITY + REBATE_RESERVE_TWO_TRADES);
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(market);
    test_world::finish(world, resources);
}

#[test]
fun owner_auth_settled_redeem_survives_predict_app_deauth() {
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
        ALL_IN_TRADE_COST,
    );

    test_world::next_tx(&mut world, test_values::alice());
    let mut wrapper = account_setup::take_account(&world, &account_handle);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let (pricer, feeds) = oracle_setup::load_pricer(&world, &resources, &oracles, &market, &config);
    let auth = account::generate_auth(test_world::ctx(&mut world));
    let order_id = market.mint_exact_quantity(
        &mut wrapper,
        auth,
        &config,
        &pricer,
        LOWER_TICK,
        test_values::strike_tick(),
        TRADE_QUANTITY,
        test_values::leverage_one_x(),
        ALL_IN_TRADE_COST,
        std::u64::max_value!(),
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    oracle_setup::return_feeds(feeds);
    return_shared(config);
    return_shared(market);
    return_shared(root);
    return_shared(wrapper);

    let expiry_ms = test_values::expiry_ms();
    test_world::clock_mut(&mut resources).set_for_testing(expiry_ms);
    test_world::next_tx(&mut world, test_values::admin());
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let mut pyth = oracle_setup::take_pyth(&world, &oracles);
    oracle_setup::seed_exact_pyth(&mut pyth, IN_RANGE_SPOT, expiry_ms, expiry_ms);
    assert!(
        market.try_settle(
            &config,
            &oracle_registry,
            &pyth,
            test_world::clock(&resources),
        ),
    );
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(market);

    test_world::next_tx(&mut world, test_values::admin());
    let account_admin_cap = test_world::take_account_admin_cap(&world);
    let mut account_registry = test_world::take_account_registry(&world);
    account_registry::authorize_app<predict_account::PredictApp>(
        &mut account_registry,
        &account_admin_cap,
    );
    account_registry::deauthorize_app<predict_account::PredictApp>(
        &mut account_registry,
        &account_admin_cap,
    );
    return_shared(account_registry);
    test_world::return_account_admin_cap(&world, account_admin_cap);

    // The winner's own authority still reaches the terminal payout.
    test_world::next_tx(&mut world, test_values::alice());
    let mut wrapper = account_setup::take_account(&world, &account_handle);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let auth = account::generate_auth(test_world::ctx(&mut world));
    market.redeem_settled(
        &mut wrapper,
        auth,
        &config,
        order_id,
        TRADE_QUANTITY,
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    assert_eq!(
        wrapper.load_account().balance<DUSDC>(&root, test_world::clock(&resources)),
        TRADE_QUANTITY,
    );
    return_shared(config);
    return_shared(market);
    return_shared(root);
    return_shared(wrapper);
    test_world::finish(world, resources);
}

#[test]
fun unstake_deep_returns_all_staked_custody() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::alice());
    let account_handle = account_setup::create_funded_trader(
        &mut world,
        &resources,
        test_values::trader_deposit(),
        STAKED_DEEP,
    );

    test_world::next_tx(&mut world, test_values::alice());
    let mut vault = test_world::take_vault(&world);
    let mut wrapper = account_setup::take_account(&world, &account_handle);
    let root = test_world::take_accumulator_root(&world);
    let config = test_world::take_config(&world);
    let auth = account::generate_auth(test_world::ctx(&mut world));
    vault.stake_deep(
        &mut wrapper,
        auth,
        &config,
        STAKED_DEEP,
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    assert_eq!(vault.staked_deep(), STAKED_DEEP);
    assert_eq!(wrapper.load_account().balance<DEEP>(&root, test_world::clock(&resources)), 0);
    let auth = account::generate_auth(test_world::ctx(&mut world));
    vault.unstake_deep(
        &mut wrapper,
        auth,
        &config,
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    assert_eq!(vault.staked_deep(), 0);
    assert_eq!(
        wrapper.load_account().balance<DEEP>(&root, test_world::clock(&resources)),
        STAKED_DEEP,
    );
    assert_eq!(predict_account::active_stake(wrapper.load_account()), 0);
    assert_eq!(predict_account::inactive_stake(wrapper.load_account()), 0);
    return_shared(config);
    return_shared(root);
    return_shared(wrapper);
    return_shared(vault);
    test_world::finish(world, resources);
}
