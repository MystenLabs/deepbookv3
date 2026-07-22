// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Sponsor-funded fee incentives: contributions join a pool reserve excluded
/// from LP value, and the live rebalance allocates them to a market's local
/// balance without moving any pool cash.
#[test_only]
module deepbook_predict::scope_flow__intent_accounting__fee_incentive_tests;

use deepbook_predict::{
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

// 1000 DUSDC sponsorship: well above the 10 DUSDC minimum and below the
// 0.02 x 250e9 = 5e9 live allocation target, so one rebalance moves all of it.
const SPONSORSHIP: u64 = 1_000_000_000;

#[test]
fun sponsor_fee_incentives_increases_reserve_without_lp_nav() {
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
    let profile = oracle_profile::exact_half();
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &market_handle,
        &profile,
        test_values::now_ms(),
    );

    // Anyone may sponsor; the payment joins the reserve, not idle.
    test_world::next_tx(&mut world, test_values::bob());
    let mut vault = test_world::take_vault(&world);
    let config = test_world::take_config(&world);
    let payment = coin::mint_for_testing<DUSDC>(SPONSORSHIP, test_world::ctx(&mut world));
    vault.sponsor_fee_incentives(&config, payment, test_world::ctx(&mut world));
    assert_eq!(vault.fee_incentive_reserve(), SPONSORSHIP);
    assert_eq!(
        vault.idle_balance(),
        test_values::pool_capital() - test_values::initial_expiry_cash(),
    );
    return_shared(config);
    return_shared(vault);

    // The flush prices the pool without the sponsored reserve.
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
    assert_eq!(pool_nav, test_values::pool_capital());

    oracle_setup::return_feeds(feeds);
    return_shared(market);
    return_shared(vault);
    return_shared(config);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
}

#[test]
fun live_rebalance_allocates_fee_incentives_without_cash_top_up() {
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
    test_world::next_tx(&mut world, test_values::bob());
    let mut vault = test_world::take_vault(&world);
    let config = test_world::take_config(&world);
    let payment = coin::mint_for_testing<DUSDC>(SPONSORSHIP, test_world::ctx(&mut world));
    vault.sponsor_fee_incentives(&config, payment, test_world::ctx(&mut world));
    return_shared(config);
    return_shared(vault);

    // The standalone rebalance moves the whole sponsorship into the market's
    // local incentive balance; pool cash and market cash are untouched.
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let idle_before = vault.idle_balance();
    let cash_before = market.cash_balance();
    vault.rebalance_expiry_cash(&mut market, &config, test_world::clock(&resources));
    assert_eq!(market.fee_incentive_balance(), SPONSORSHIP);
    assert_eq!(vault.fee_incentive_reserve(), 0);
    assert_eq!(vault.idle_balance(), idle_before);
    assert_eq!(market.cash_balance(), cash_before);
    return_shared(config);
    return_shared(market);
    return_shared(vault);
    test_world::finish(world, resources);
}
