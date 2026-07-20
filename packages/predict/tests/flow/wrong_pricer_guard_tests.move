// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A live pricing snapshot is bound to exactly one expiry-market identity.
#[test_only]
module deepbook_predict::scope_flow__intent_guard__wrong_pricer_tests;

use deepbook_predict::{
    expiry_market,
    market_setup,
    oracle_profile,
    oracle_setup,
    test_values,
    test_world
};

const MARKET_COUNT: u64 = 2;

#[test, expected_failure(abort_code = expiry_market::EWrongPricer)]
fun current_nav_rejects_pricer_bound_to_another_market() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    market_setup::configure_cadence(
        &world,
        &admin_cap,
        test_values::composition_cadence_window_size(),
    );
    test_world::return_predict_admin_cap(&world, admin_cap);
    let oracles = oracle_setup::create_default_oracles(&mut world);
    test_world::next_tx(&mut world, test_values::admin());
    let oracle_admin_cap = test_world::take_propbook_admin_cap(&world);
    oracle_setup::bind_default_oracles(&world, &oracle_admin_cap, &oracles);
    test_world::return_propbook_admin_cap(&world, oracle_admin_cap);
    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut markets = market_setup::create_markets(
        &mut world,
        &resources,
        &admin_cap,
        MARKET_COUNT,
    );
    test_world::return_predict_admin_cap(&world, admin_cap);
    let first = markets.remove(0);
    let second = markets.remove(0);
    test_world::next_tx(&mut world, test_values::admin());
    let profile = oracle_profile::exact_half();
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &first,
        &profile,
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &second,
        &profile,
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::alice());
    let first_market = market_setup::take_market(&world, &first);
    let second_market = market_setup::take_market(&world, &second);
    assert!(first_market.id() != second_market.id());
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let pyth = oracle_setup::take_pyth(&world, &oracles);
    let bs_spot = oracle_setup::take_bs_spot(&world, &oracles);
    let bs_forward = oracle_setup::take_bs_forward(&world, &oracles);
    let bs_svi = oracle_setup::take_bs_svi(&world, &oracles);
    let first_pricer = first_market.load_live_pricer(
        &config,
        &oracle_registry,
        &pyth,
        &bs_spot,
        &bs_forward,
        &bs_svi,
        test_world::clock(&resources),
    );

    let _ = second_market.current_nav(&first_pricer);

    abort 999
}
