// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Cross-market terminal profit ordering: the protocol cut should reserve the
/// share of NET pool profit regardless of which settled expiry is swept first.
/// The loss-first order does; the profit-first order books the cut against the
/// gross profit before the offsetting loss is carried, so its sibling fails —
/// the enrolled production finding on the reserve's accrual basis.
#[test_only]
module deepbook_predict::scope_flow__intent_policy__protocol_profit_tests;

use account::account;
use deepbook_predict::{
    account_setup,
    market_setup,
    oracle_profile,
    oracle_setup,
    pool_setup,
    test_values,
    test_world
};
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

const LOWER_TICK: u64 = 90;
const TWO_MARKET_WINDOW: u64 = 2;
const TWO_MARKET_CAPITAL: u64 = 20_000_000_000; // exactly two 10e9 funding floors
// Profit market: the trader loses a 20e6 exact-half position (all-in 10.1e6);
// the sweep returns cash minus the 50e3 rebate reserve, a 10.05e6 profit.
const PROFIT_QUANTITY: u64 = 20_000_000;
const PROFIT_ALL_IN_COST: u64 = 10_100_000;
// Loss market: the trader wins a 2e9 exact-half position (all-in 1.01e9); the
// sweep keeps the 2e9 payout + 5e6 rebate reserve, a 995e6 terminal loss.
const LOSS_QUANTITY: u64 = 2_000_000_000;
const LOSS_ALL_IN_COST: u64 = 1_010_000_000;
const TRADER_DEPOSIT: u64 = 1_020_100_000; // both all-in costs
const PROFIT_SETTLE_SPOT: u64 = 200_000_000_000; // above (90, 100]: trader loses
const LOSS_SETTLE_SPOT: u64 = 95_000_000_000; // inside (90, 100]: trader wins
const LOSS_SURFACE_TIMESTAMP_MS: u64 = 119_100; // after the profit market's row
// Net pool P&L is 10.05e6 profit minus 995e6 loss: negative, so the
// order-independent protocol cut is zero.
const NET_POOL_PROFIT_CUT: u64 = 0;
// Sweeps return 10_010.05e6 and 9_005e6; with a zero cut all of it is idle.
const IDLE_AFTER_BOTH_SWEEPS: u64 = 19_015_050_000;

#[test]
fun loss_first_sweep_reserves_share_of_net_pool_profit() {
    let (mut world, mut resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    market_setup::configure_cadence(&world, &admin_cap, TWO_MARKET_WINDOW);
    test_world::return_predict_admin_cap(&world, admin_cap);
    let oracles = oracle_setup::create_default_oracles(&mut world);
    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut config = test_world::take_config(&world);
    config.set_template_base_fee(&admin_cap, 1);
    config.set_template_no_leverage_window_ms(&admin_cap, 0);
    return_shared(config);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::next_tx(&mut world, test_values::admin());
    let oracle_admin_cap = test_world::take_propbook_admin_cap(&world);
    oracle_setup::bind_default_oracles(&world, &oracle_admin_cap, &oracles);
    test_world::return_propbook_admin_cap(&world, oracle_admin_cap);
    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let handles = market_setup::create_markets(
        &mut world,
        &resources,
        &admin_cap,
        TWO_MARKET_WINDOW,
    );
    test_world::return_predict_admin_cap(&world, admin_cap);
    let profit_market = handles[0];
    let loss_market = handles[1];
    test_world::next_tx(&mut world, test_values::admin());
    pool_setup::fund_market(
        &mut world,
        &resources,
        &profit_market,
        TWO_MARKET_CAPITAL,
    );
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut market = market_setup::take_market(&world, &loss_market);
    let config = test_world::take_config(&world);
    vault.rebalance_expiry_cash(&mut market, &config, test_world::clock(&resources));
    return_shared(config);
    return_shared(market);
    return_shared(vault);
    test_world::next_tx(&mut world, test_values::admin());
    let profile = oracle_profile::exact_half();
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &profit_market,
        &profile,
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let profile_l = oracle_profile::exact_half_at(LOSS_SURFACE_TIMESTAMP_MS);
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &loss_market,
        &profile_l,
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::alice());
    let account_handle = account_setup::create_funded_account(
        &mut world,
        &resources,
        TRADER_DEPOSIT,
    );

    test_world::next_tx(&mut world, test_values::alice());
    let mut wrapper = account_setup::take_account(&world, &account_handle);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &profit_market);
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
        PROFIT_QUANTITY,
        test_values::leverage_one_x(),
        PROFIT_ALL_IN_COST,
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
    test_world::next_tx(&mut world, test_values::alice());
    let mut wrapper = account_setup::take_account(&world, &account_handle);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &loss_market);
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
        LOSS_QUANTITY,
        test_values::leverage_one_x(),
        LOSS_ALL_IN_COST,
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

    // Both markets settle: the profit market's print lands outside its range,
    // the loss market's inside.
    let loss_expiry_ms = test_values::expiry_ms() + test_values::cadence_period_ms();
    test_world::clock_mut(&mut resources).set_for_testing(loss_expiry_ms);
    test_world::next_tx(&mut world, test_values::admin());
    let mut p_market = market_setup::take_market(&world, &profit_market);
    let mut l_market = market_setup::take_market(&world, &loss_market);
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let mut pyth = oracle_setup::take_pyth(&world, &oracles);
    oracle_setup::seed_exact_pyth(
        &mut pyth,
        PROFIT_SETTLE_SPOT,
        test_values::expiry_ms(),
        loss_expiry_ms,
    );
    oracle_setup::seed_exact_pyth(&mut pyth, LOSS_SETTLE_SPOT, loss_expiry_ms, loss_expiry_ms);
    assert!(
        p_market.try_settle(
            &config,
            &oracle_registry,
            &pyth,
            test_world::clock(&resources),
        ),
    );
    assert!(
        l_market.try_settle(
            &config,
            &oracle_registry,
            &pyth,
            test_world::clock(&resources),
        ),
    );
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(l_market);
    return_shared(p_market);

    // Loss-first sweep order: the 995e6 terminal loss is booked before the
    // 10.05e6 profit, which only refills the carry — no cut is taken.
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut l_market = market_setup::take_market(&world, &loss_market);
    let config = test_world::take_config(&world);
    vault.rebalance_expiry_cash(&mut l_market, &config, test_world::clock(&resources));
    return_shared(config);
    return_shared(l_market);
    return_shared(vault);
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut p_market = market_setup::take_market(&world, &profit_market);
    let config = test_world::take_config(&world);
    vault.rebalance_expiry_cash(&mut p_market, &config, test_world::clock(&resources));
    assert_eq!(vault.protocol_reserve_balance(), NET_POOL_PROFIT_CUT);
    assert_eq!(vault.idle_balance(), IDLE_AFTER_BOTH_SWEEPS);
    return_shared(config);
    return_shared(p_market);
    return_shared(vault);
    test_world::finish(world, resources);
}

// KNOWN-FAILING: P-8
#[test]
fun profit_first_sweep_reserves_share_of_net_pool_profit() {
    let (mut world, mut resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    market_setup::configure_cadence(&world, &admin_cap, TWO_MARKET_WINDOW);
    test_world::return_predict_admin_cap(&world, admin_cap);
    let oracles = oracle_setup::create_default_oracles(&mut world);
    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut config = test_world::take_config(&world);
    config.set_template_base_fee(&admin_cap, 1);
    config.set_template_no_leverage_window_ms(&admin_cap, 0);
    return_shared(config);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::next_tx(&mut world, test_values::admin());
    let oracle_admin_cap = test_world::take_propbook_admin_cap(&world);
    oracle_setup::bind_default_oracles(&world, &oracle_admin_cap, &oracles);
    test_world::return_propbook_admin_cap(&world, oracle_admin_cap);
    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let handles = market_setup::create_markets(
        &mut world,
        &resources,
        &admin_cap,
        TWO_MARKET_WINDOW,
    );
    test_world::return_predict_admin_cap(&world, admin_cap);
    let profit_market = handles[0];
    let loss_market = handles[1];
    test_world::next_tx(&mut world, test_values::admin());
    pool_setup::fund_market(
        &mut world,
        &resources,
        &profit_market,
        TWO_MARKET_CAPITAL,
    );
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut market = market_setup::take_market(&world, &loss_market);
    let config = test_world::take_config(&world);
    vault.rebalance_expiry_cash(&mut market, &config, test_world::clock(&resources));
    return_shared(config);
    return_shared(market);
    return_shared(vault);
    test_world::next_tx(&mut world, test_values::admin());
    let profile = oracle_profile::exact_half();
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &profit_market,
        &profile,
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let profile_l = oracle_profile::exact_half_at(LOSS_SURFACE_TIMESTAMP_MS);
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &loss_market,
        &profile_l,
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::alice());
    let account_handle = account_setup::create_funded_account(
        &mut world,
        &resources,
        TRADER_DEPOSIT,
    );

    test_world::next_tx(&mut world, test_values::alice());
    let mut wrapper = account_setup::take_account(&world, &account_handle);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &profit_market);
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
        PROFIT_QUANTITY,
        test_values::leverage_one_x(),
        PROFIT_ALL_IN_COST,
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
    test_world::next_tx(&mut world, test_values::alice());
    let mut wrapper = account_setup::take_account(&world, &account_handle);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &loss_market);
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
        LOSS_QUANTITY,
        test_values::leverage_one_x(),
        LOSS_ALL_IN_COST,
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

    let loss_expiry_ms = test_values::expiry_ms() + test_values::cadence_period_ms();
    test_world::clock_mut(&mut resources).set_for_testing(loss_expiry_ms);
    test_world::next_tx(&mut world, test_values::admin());
    let mut p_market = market_setup::take_market(&world, &profit_market);
    let mut l_market = market_setup::take_market(&world, &loss_market);
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let mut pyth = oracle_setup::take_pyth(&world, &oracles);
    oracle_setup::seed_exact_pyth(
        &mut pyth,
        PROFIT_SETTLE_SPOT,
        test_values::expiry_ms(),
        loss_expiry_ms,
    );
    oracle_setup::seed_exact_pyth(&mut pyth, LOSS_SETTLE_SPOT, loss_expiry_ms, loss_expiry_ms);
    assert!(
        p_market.try_settle(
            &config,
            &oracle_registry,
            &pyth,
            test_world::clock(&resources),
        ),
    );
    assert!(
        l_market.try_settle(
            &config,
            &oracle_registry,
            &pyth,
            test_world::clock(&resources),
        ),
    );
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(l_market);
    return_shared(p_market);

    // Profit-first sweep order: sweeping the profitable expiry before the
    // offsetting loss should still reserve only the share of NET pool profit
    // (zero here). The permissionless ordering must not change what the
    // protocol keeps — this is the enrolled production finding: the cut books
    // against gross recognized profit and the later loss never claws it back.
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut p_market = market_setup::take_market(&world, &profit_market);
    let config = test_world::take_config(&world);
    vault.rebalance_expiry_cash(&mut p_market, &config, test_world::clock(&resources));
    return_shared(config);
    return_shared(p_market);
    return_shared(vault);
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut l_market = market_setup::take_market(&world, &loss_market);
    let config = test_world::take_config(&world);
    vault.rebalance_expiry_cash(&mut l_market, &config, test_world::clock(&resources));
    assert_eq!(vault.protocol_reserve_balance(), NET_POOL_PROFIT_CUT);
    assert_eq!(vault.idle_balance(), IDLE_AFTER_BOTH_SWEEPS);
    return_shared(config);
    return_shared(l_market);
    return_shared(vault);
    test_world::finish(world, resources);
}
