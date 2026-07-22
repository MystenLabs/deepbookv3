// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pool-to-market cash allocation accounting through the production vault path.
#[test_only]
module deepbook_predict::scope_flow__intent_accounting__pool_funding_tests;

use deepbook_predict::{market_setup, oracle_setup, test_values, test_world};
use dusdc::dusdc::DUSDC;
use std::unit_test::assert_eq;
use sui::{coin, test_scenario::return_shared};

#[test]
fun expiry_cash_rebalance_moves_only_the_configured_allocation() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::admin());
    let predict_admin_cap = test_world::take_predict_admin_cap(&world);
    market_setup::configure_default_cadence(&world, &predict_admin_cap);
    test_world::return_predict_admin_cap(&world, predict_admin_cap);
    let oracles = oracle_setup::create_default_oracles(&mut world);

    test_world::next_tx(&mut world, test_values::admin());
    let propbook_admin_cap = test_world::take_propbook_admin_cap(&world);
    oracle_setup::bind_default_oracles(&world, &propbook_admin_cap, &oracles);
    test_world::return_propbook_admin_cap(&world, propbook_admin_cap);

    test_world::next_tx(&mut world, test_values::admin());
    let predict_admin_cap = test_world::take_predict_admin_cap(&world);
    let market_handle = market_setup::create_default_market(
        &mut world,
        &resources,
        &predict_admin_cap,
    );
    test_world::return_predict_admin_cap(&world, predict_admin_cap);

    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let capital = coin::mint_for_testing<DUSDC>(
        test_values::pool_capital(),
        test_world::ctx(&mut world),
    );
    let predict_admin_cap = test_world::take_predict_admin_cap(&world);
    vault.lock_capital(&config, &predict_admin_cap, capital);
    test_world::return_predict_admin_cap(&world, predict_admin_cap);
    assert_eq!(vault.idle_balance(), test_values::pool_capital());
    assert_eq!(vault.plp_total_supply(), test_values::pool_capital());

    vault.rebalance_expiry_cash(
        &mut market,
        &config,
        test_world::clock(&resources),
    );
    assert_eq!(market.cash_balance(), test_values::initial_expiry_cash());
    assert_eq!(
        vault.idle_balance(),
        test_values::pool_capital() - test_values::initial_expiry_cash(),
    );
    assert_eq!(vault.profit_basis_debits(), test_values::initial_expiry_cash());
    assert_eq!(vault.profit_basis_credits(), 0);
    assert_eq!(vault.idle_balance() + market.cash_balance(), test_values::pool_capital());
    return_shared(config);
    return_shared(market);
    return_shared(vault);

    test_world::finish(world, resources);
}
