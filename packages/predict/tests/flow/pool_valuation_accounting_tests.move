// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Single-mark conservation of the full-pool valuation: pool NAV equals idle
/// plus every active market's exact NAV minus the protocol-profit exclusion,
/// across empty, funded-untraded, and traded multi-market states.
#[test_only]
module deepbook_predict::scope_flow__intent_accounting__pool_valuation_tests;

use account::account;
use deepbook_predict::{
    account_setup,
    constants,
    market_setup,
    oracle_profile,
    oracle_setup,
    plp,
    pool_setup,
    test_values,
    test_world
};
use dusdc::dusdc::DUSDC;
use std::unit_test::assert_eq;
use sui::{coin, test_scenario::return_shared};

const TWO_MARKET_CAPITAL: u64 = 30_000_000_000; // funds two 10e9 floors + 10e9 idle
const TWO_MARKET_WINDOW: u64 = 2;
const ALL_IN_ONE_X_COST: u64 = 505_000_000; // exact-half net_premium 5e8 + fee 5e6
// Market A holds one 1x order: NAV_a = cash 10_505e6 - reserve 2.5e6 - 5e8
// liability; market B is untraded at its 10e9 funding floor.
const TRADED_MARKET_NAV: u64 = 10_002_500_000;
// The exclusion prices the unrealized protocol share: credits 0 + active NAV
// 20_002.5e6 - debits 20_000e6 = 2.5e6, times the 0.4 default reserve share.
const UNREALIZED_PROFIT_EXCLUSION: u64 = 1_000_000;
// pool_nav = idle 10e9 + NAV_a + NAV_b 10e9 - exclusion.
const TWO_MARKET_TRADED_POOL_NAV: u64 = 30_001_500_000;
const SECOND_SURFACE_TIMESTAMP_MS: u64 = 119_100; // after market A's 119_000 row

#[test]
fun empty_pool_valuation_returns_idle() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    // Bootstrap only: no market exists, so the snapshot is empty and the pool
    // is exactly its idle liquidity.
    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut vault = test_world::take_vault(&world);
    let config = test_world::take_config(&world);
    let capital = coin::mint_for_testing<DUSDC>(
        test_values::pool_capital(),
        test_world::ctx(&mut world),
    );
    vault.lock_capital(&config, &admin_cap, capital);
    return_shared(config);
    return_shared(vault);
    test_world::return_predict_admin_cap(&world, admin_cap);

    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut registry = test_world::take_registry(&world);
    let mut config = test_world::take_config(&world);
    let mut vault = test_world::take_vault(&world);
    let lifecycle_cap = registry.mint_lifecycle_cap(
        &config,
        &admin_cap,
        test_world::ctx(&mut world),
    );
    let proof = registry.generate_lifecycle_proof(&lifecycle_cap);
    let valuation = plp::start_pool_valuation(&mut config, &vault, proof);
    let pool_nav = plp::finish_flush(
        valuation,
        &mut vault,
        &mut config,
        option::none(),
        option::none(),
        test_world::ctx(&mut world),
    );
    lifecycle_cap.destroy();
    assert_eq!(pool_nav, test_values::pool_capital());
    assert_eq!(vault.idle_balance(), test_values::pool_capital());
    return_shared(vault);
    return_shared(config);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
}

#[test]
fun funded_untraded_markets_pool_nav_equals_locked_capital() {
    let (mut world, resources) = test_world::new(
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
    let market_a = handles[0];
    let market_b = handles[1];
    test_world::next_tx(&mut world, test_values::admin());
    pool_setup::fund_market(
        &mut world,
        &resources,
        &market_a,
        TWO_MARKET_CAPITAL,
    );
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut market = market_setup::take_market(&world, &market_b);
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
        &market_a,
        &profile,
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let profile_b = oracle_profile::exact_half_at(SECOND_SURFACE_TIMESTAMP_MS);
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &market_b,
        &profile_b,
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut registry = test_world::take_registry(&world);
    let mut config = test_world::take_config(&world);
    let mut vault = test_world::take_vault(&world);
    let mut a = market_setup::take_market(&world, &market_a);
    let mut b = market_setup::take_market(&world, &market_b);
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
        &mut a,
        &config,
        feeds.oracle_registry(),
        feeds.pyth(),
        feeds.bs_spot(),
        feeds.bs_forward(),
        feeds.bs_svi(),
        test_world::clock(&resources),
    );
    plp::value_expiry(
        &mut valuation,
        &mut vault,
        &mut b,
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

    // Two untraded funded floors plus idle conserve the locked capital.
    assert_eq!(pool_nav, TWO_MARKET_CAPITAL);
    assert_eq!(vault.idle_balance(), TWO_MARKET_CAPITAL - 2 * test_values::initial_expiry_cash());

    oracle_setup::return_feeds(feeds);
    return_shared(b);
    return_shared(a);
    return_shared(vault);
    return_shared(config);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
}

#[test]
fun multi_market_pool_nav_is_idle_plus_navs_minus_unrealized_exclusion() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    // The low-fee template values are set directly because this world also
    // needs a two-expiry cadence window.
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
    let market_a = handles[0];
    let market_b = handles[1];
    test_world::next_tx(&mut world, test_values::admin());
    pool_setup::fund_market(
        &mut world,
        &resources,
        &market_a,
        TWO_MARKET_CAPITAL,
    );
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut market = market_setup::take_market(&world, &market_b);
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
        &market_a,
        &profile,
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let profile_b = oracle_profile::exact_half_at(SECOND_SURFACE_TIMESTAMP_MS);
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &market_b,
        &profile_b,
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::alice());
    let account_handle = account_setup::create_funded_account(
        &mut world,
        &resources,
        test_values::trader_deposit(),
    );

    // One 1x position in market A gives it an exact traded NAV; B stays at
    // its funding floor.
    test_world::next_tx(&mut world, test_values::alice());
    let mut wrapper = account_setup::take_account(&world, &account_handle);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &market_a);
    let config = test_world::take_config(&world);
    let (pricer, feeds) = oracle_setup::load_pricer(&world, &resources, &oracles, &market, &config);
    let auth = account::generate_auth(test_world::ctx(&mut world));
    let _ = market.mint_exact_quantity(
        &mut wrapper,
        auth,
        &config,
        &pricer,
        test_values::strike_tick(),
        constants::pos_inf_tick!(),
        test_values::mint_quantity(),
        test_values::leverage_one_x(),
        ALL_IN_ONE_X_COST,
        std::u64::max_value!(),
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    assert_eq!(market.current_nav(&pricer), TRADED_MARKET_NAV);
    oracle_setup::return_feeds(feeds);
    return_shared(config);
    return_shared(market);
    return_shared(root);
    return_shared(wrapper);

    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut registry = test_world::take_registry(&world);
    let mut config = test_world::take_config(&world);
    let mut vault = test_world::take_vault(&world);
    let mut a = market_setup::take_market(&world, &market_a);
    let mut b = market_setup::take_market(&world, &market_b);
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
        &mut a,
        &config,
        feeds.oracle_registry(),
        feeds.pyth(),
        feeds.bs_spot(),
        feeds.bs_forward(),
        feeds.bs_svi(),
        test_world::clock(&resources),
    );
    plp::value_expiry(
        &mut valuation,
        &mut vault,
        &mut b,
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

    // idle + NAV_a + NAV_b minus the 0.4 share of the unrealized 2.5e6 net
    // profit basis (credits + active NAV over debits).
    assert_eq!(pool_nav, TWO_MARKET_TRADED_POOL_NAV);
    assert_eq!(vault.plp_total_supply(), TWO_MARKET_CAPITAL);

    oracle_setup::return_feeds(feeds);
    return_shared(b);
    return_shared(a);
    return_shared(vault);
    return_shared(config);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
}
