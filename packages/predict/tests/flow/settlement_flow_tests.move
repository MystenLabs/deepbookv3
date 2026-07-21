// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registered settlement and rebate policy pins: a past-expiry market without
/// its exact settlement print stays unsettled and inert (no substitute mark,
/// no cash movement), explicit settlement unblocks the pool valuation sweep,
/// and the trading-loss rebate resolves only on settled markets with closed
/// positions, through the app-auth gate or the owner's own authority.
#[test_only]
module deepbook_predict::scope_flow__intent_policy__settlement_tests;

use account::{account, account_registry};
use deepbook_predict::{
    account_setup,
    market_setup,
    oracle_profile,
    oracle_setup,
    plp,
    pool_setup,
    predict_account,
    test_values,
    test_world
};
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

const LOWER_TICK: u64 = 90;
const TRADE_QUANTITY: u64 = 20_000_000;
const ALL_IN_TRADE_COST: u64 = 10_100_000; // exact-half premium 10e6 + fee 100e3
const SMALL_BOOTSTRAP: u64 = 10_000_000;
const OUT_OF_RANGE_SPOT: u64 = 200_000_000_000; // above (90, 100]: trader loses
// Loser-market ledger after the standalone sweep: cash 20.1e6 returns minus
// the 50e3 rebate reserve; terminal profit 10.05e6 takes a 0.4 cut of 4.02e6.
const IDLE_AFTER_SWEEP: u64 = 16_030_000;
const PROTOCOL_CUT_AFTER_SWEEP: u64 = 4_020_000;
// The unstaked loser's rebate is 0 (benefit ratio 0), so the full 50e3
// residual returns to the pool and materializes a further 0.4 cut of 20e3.
const IDLE_AFTER_RESIDUAL: u64 = 16_060_000; // 16.03e6 + 50e3 - 20e3
const PROTOCOL_CUT_AFTER_RESIDUAL: u64 = 4_040_000;
const STAKED_DEEP: u64 = 5_000_000_000;

#[test]
fun try_settle_without_exact_expiry_spot_returns_false_without_mutation() {
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

    // Past expiry with a fresh observation at the exact millisecond that is
    // NOT flagged exact: settlement must not use it, and nothing may move.
    let expiry_ms = test_values::expiry_ms();
    test_world::clock_mut(&mut resources).set_for_testing(expiry_ms);
    test_world::next_tx(&mut world, test_values::admin());
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let mut pyth = oracle_setup::take_pyth(&world, &oracles);
    oracle_setup::seed_pyth(
        &mut pyth,
        oracle_profile::exact_half().pyth_spot(),
        expiry_ms,
        expiry_ms,
    );
    let cash_before = market.cash_balance();
    assert!(
        !market.try_settle(
            &config,
            &oracle_registry,
            &pyth,
            test_world::clock(&resources),
        ),
    );
    assert!(!market.is_settled());
    assert!(market.try_settlement_price().is_none());
    assert_eq!(market.cash_balance(), cash_before);
    assert_eq!(market.payout_liability(), 0);
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(market);
    test_world::finish(world, resources);
}

#[test]
fun expired_unsettled_standalone_rebalance_moves_no_cash() {
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
    // The premium leaves the market's cash above its live sweep band, so a
    // wrongly classified live rebalance at expiry would visibly move cash.
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
    oracle_setup::return_feeds(feeds);
    return_shared(config);
    return_shared(market);
    return_shared(root);
    return_shared(wrapper);

    // At exactly the expiry millisecond, unsettled: the rebalance window
    // closes at expiry inclusive, so no top-up or sweep may run.
    test_world::clock_mut(&mut resources).set_for_testing(test_values::expiry_ms());
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let idle_before = vault.idle_balance();
    let cash_before = market.cash_balance();
    vault.rebalance_expiry_cash(&mut market, &config, test_world::clock(&resources));
    assert_eq!(vault.idle_balance(), idle_before);
    assert_eq!(market.cash_balance(), cash_before);
    assert!(!vault.active_expiry_markets().is_empty());
    return_shared(config);
    return_shared(market);
    return_shared(vault);
    test_world::finish(world, resources);
}

#[test]
fun explicit_settlement_unblocks_pool_valuation_sweep() {
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

    // Past expiry and unsettled the market cannot be valued; the explicit
    // settlement transition is what lets the flush sweep it.
    let expiry_ms = test_values::expiry_ms();
    test_world::clock_mut(&mut resources).set_for_testing(expiry_ms);
    test_world::next_tx(&mut world, test_values::admin());
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let mut pyth = oracle_setup::take_pyth(&world, &oracles);
    oracle_setup::seed_exact_pyth(
        &mut pyth,
        oracle_profile::exact_half().pyth_spot(),
        expiry_ms,
        expiry_ms,
    );
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
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut registry = test_world::take_registry(&world);
    let mut config = test_world::take_config(&world);
    let mut vault = test_world::take_vault(&world);
    let mut market = market_setup::take_market(&world, &market_handle);
    let feeds = oracle_setup::borrow_feeds(&world, &oracles);
    let lifecycle_cap = registry.mint_lifecycle_cap(
        &config,
        &admin_cap,
        test_world::ctx(&mut world),
    );
    let proof = registry.generate_lifecycle_proof(&lifecycle_cap);
    let mut valuation = plp::start_pool_valuation(&mut config, &vault, proof);
    plp::value_expiry(
        &mut valuation,
        &mut vault,
        &mut market,
        &config,
        feeds.oracle_registry(),
        feeds.pyth(),
        feeds.bs_spot(),
        feeds.bs_forward(),
        feeds.bs_svi(),
        test_world::clock(&resources),
    );
    let pool_nav = plp::finish_flush(
        valuation,
        &mut vault,
        &mut config,
        option::none(),
        option::none(),
        test_world::ctx(&mut world),
    );
    lifecycle_cap.destroy();

    // The settled market was swept inside the valuation: full untraded cash
    // returned, the expiry left the active set, and the flush completed.
    assert_eq!(pool_nav, test_values::pool_capital());
    assert!(vault.active_expiry_markets().is_empty());
    assert_eq!(market.cash_balance(), 0);

    oracle_setup::return_feeds(feeds);
    return_shared(market);
    return_shared(vault);
    return_shared(config);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
}

#[test, expected_failure(abort_code = plp::EMarketNotSettled)]
fun rebate_claim_requires_settled_market() {
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
    test_world::next_tx(&mut world, test_values::alice());
    let account_handle = account_setup::create_funded_account(
        &mut world,
        &resources,
        test_values::trader_deposit(),
    );

    // The market is live: the rebate claim's settled-market gate must fire.
    test_world::next_tx(&mut world, test_values::alice());
    let mut vault = test_world::take_vault(&world);
    let mut wrapper = account_setup::take_account(&world, &account_handle);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let auth = account::generate_auth(test_world::ctx(&mut world));
    vault.claim_trading_loss_rebate(
        &mut market,
        &mut wrapper,
        auth,
        &config,
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );

    abort 999
}

#[test, expected_failure(abort_code = predict_account::EExpirySummaryHasOpenPositions)]
fun rebate_claim_with_open_position_aborts() {
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
    oracle_setup::return_feeds(feeds);
    return_shared(config);
    return_shared(market);
    return_shared(root);
    return_shared(wrapper);

    // Settled, but the position is never redeemed: the claim must refuse to
    // resolve a summary that still has open positions.
    let expiry_ms = test_values::expiry_ms();
    test_world::clock_mut(&mut resources).set_for_testing(expiry_ms);
    test_world::next_tx(&mut world, test_values::admin());
    oracle_setup::settle_market_at_exact_print(
        &mut world,
        &resources,
        &oracles,
        &market_handle,
        OUT_OF_RANGE_SPOT,
    );

    test_world::next_tx(&mut world, test_values::alice());
    let mut vault = test_world::take_vault(&world);
    let mut wrapper = account_setup::take_account(&world, &account_handle);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let auth = account::generate_auth(test_world::ctx(&mut world));
    vault.claim_trading_loss_rebate(
        &mut market,
        &mut wrapper,
        auth,
        &config,
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );

    abort 999
}

#[test, expected_failure(abort_code = account_registry::EAppNotAuthorized)]
fun deauthorized_predict_app_blocks_permissionless_rebate_claim() {
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
    oracle_setup::settle_market_at_exact_print(
        &mut world,
        &resources,
        &oracles,
        &market_handle,
        OUT_OF_RANGE_SPOT,
    );

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
    return_shared(config);
    return_shared(market);
    return_shared(root);
    return_shared(wrapper);

    // Authorize then revoke Predict's app authority: the permissionless
    // keeper path must refuse to fabricate account authority after the
    // revocation.
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

    test_world::next_tx(&mut world, test_values::bob());
    let mut vault = test_world::take_vault(&world);
    let mut wrapper = account_setup::take_account(&world, &account_handle);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &market_handle);
    let account_registry = test_world::take_account_registry(&world);
    let config = test_world::take_config(&world);
    vault.claim_trading_loss_rebate_permissionless(
        &mut market,
        &mut wrapper,
        &account_registry,
        &config,
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );

    abort 999
}

#[test]
fun owner_auth_rebate_claim_survives_predict_app_deauth() {
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
        SMALL_BOOTSTRAP,
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
    oracle_setup::settle_market_at_exact_print(
        &mut world,
        &resources,
        &oracles,
        &market_handle,
        OUT_OF_RANGE_SPOT,
    );

    // Close the losing position, sweep the settled market, then revoke
    // Predict's app authority.
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
    return_shared(config);
    return_shared(market);
    return_shared(root);
    return_shared(wrapper);
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    vault.rebalance_expiry_cash(&mut market, &config, test_world::clock(&resources));
    assert_eq!(vault.idle_balance(), IDLE_AFTER_SWEEP);
    assert_eq!(vault.protocol_reserve_balance(), PROTOCOL_CUT_AFTER_SWEEP);
    return_shared(config);
    return_shared(market);
    return_shared(vault);
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

    // The owner's own authority still resolves the rebate: the unstaked
    // loser is owed nothing, the residual reserve returns to the pool, and
    // only the residual's delta materializes further profit.
    test_world::next_tx(&mut world, test_values::alice());
    let mut vault = test_world::take_vault(&world);
    let mut wrapper = account_setup::take_account(&world, &account_handle);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let auth = account::generate_auth(test_world::ctx(&mut world));
    vault.claim_trading_loss_rebate(
        &mut market,
        &mut wrapper,
        auth,
        &config,
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    assert_eq!(
        wrapper
            .load_account()
            .balance<dusdc::dusdc::DUSDC>(
                &root,
                test_world::clock(&resources),
            ),
        0,
    );
    assert_eq!(market.cash_balance(), 0);
    assert_eq!(market.rebate_reserve(), 0);
    assert_eq!(vault.idle_balance(), IDLE_AFTER_RESIDUAL);
    assert_eq!(vault.protocol_reserve_balance(), PROTOCOL_CUT_AFTER_RESIDUAL);
    return_shared(config);
    return_shared(market);
    return_shared(root);
    return_shared(wrapper);
    return_shared(vault);
    test_world::finish(world, resources);
}

#[test]
fun prepare_settled_loss_with_inactive_rebate_stake() {
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
    let account_handle = account_setup::create_funded_trader(
        &mut world,
        &resources,
        test_values::trader_deposit(),
        STAKED_DEEP,
    );

    // Stake DEEP in the same epoch as the trade: the stake stays inactive
    // through settlement, which is exactly the state the claim-time-stake
    // policy's app-auth pins run over.
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
    assert_eq!(predict_account::active_stake(wrapper.load_account()), 0);
    assert_eq!(predict_account::inactive_stake(wrapper.load_account()), STAKED_DEEP);
    return_shared(config);
    return_shared(root);
    return_shared(wrapper);
    return_shared(vault);

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
    oracle_setup::settle_market_at_exact_print(
        &mut world,
        &resources,
        &oracles,
        &market_handle,
        OUT_OF_RANGE_SPOT,
    );

    // The staged state the register's app-auth pins rely on: a settled loss,
    // a closed position, and rebate stake that is still inactive at claim
    // time — asserted rather than assumed.
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
    assert!(market.is_settled());
    assert_eq!(market.settlement_price(), OUT_OF_RANGE_SPOT);
    assert_eq!(predict_account::active_stake(wrapper.load_account()), 0);
    assert_eq!(predict_account::inactive_stake(wrapper.load_account()), STAKED_DEEP);
    assert!(!predict_account::has_position(wrapper.load_account(), market.id(), order_id));
    return_shared(config);
    return_shared(market);
    return_shared(root);
    return_shared(wrapper);
    test_world::finish(world, resources);
}

#[test]
fun authorized_predict_app_permissionless_rebate_claim_resolves_account() {
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
        SMALL_BOOTSTRAP,
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
    oracle_setup::settle_market_at_exact_print(
        &mut world,
        &resources,
        &oracles,
        &market_handle,
        OUT_OF_RANGE_SPOT,
    );

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
    return_shared(config);
    return_shared(market);
    return_shared(root);
    return_shared(wrapper);
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    vault.rebalance_expiry_cash(&mut market, &config, test_world::clock(&resources));
    return_shared(config);
    return_shared(market);
    return_shared(vault);

    // With the app AUTHORIZED, anyone can run the cleanout: this is the
    // positive half the deauthorization pins revoke, so the app-auth gate is
    // demonstrably effective in both directions.
    test_world::next_tx(&mut world, test_values::admin());
    let account_admin_cap = test_world::take_account_admin_cap(&world);
    let mut account_registry = test_world::take_account_registry(&world);
    account_registry::authorize_app<predict_account::PredictApp>(
        &mut account_registry,
        &account_admin_cap,
    );
    return_shared(account_registry);
    test_world::return_account_admin_cap(&world, account_admin_cap);

    test_world::next_tx(&mut world, test_values::bob());
    let mut vault = test_world::take_vault(&world);
    let mut wrapper = account_setup::take_account(&world, &account_handle);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &market_handle);
    let account_registry = test_world::take_account_registry(&world);
    let config = test_world::take_config(&world);
    vault.claim_trading_loss_rebate_permissionless(
        &mut market,
        &mut wrapper,
        &account_registry,
        &config,
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    assert_eq!(market.cash_balance(), 0);
    assert_eq!(market.rebate_reserve(), 0);
    assert_eq!(vault.idle_balance(), IDLE_AFTER_RESIDUAL);
    assert_eq!(vault.protocol_reserve_balance(), PROTOCOL_CUT_AFTER_RESIDUAL);
    return_shared(config);
    return_shared(account_registry);
    return_shared(market);
    return_shared(root);
    return_shared(wrapper);
    return_shared(vault);
    test_world::finish(world, resources);
}
