// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Framework smoke test proving the Phase 7 flush driver drives a full-pool flush
/// end to end. A single funded, un-traded market conserves pool NAV: the flush
/// returns exactly the locked bootstrap capital (idle plus the market's own cash,
/// no liabilities, no protocol-profit exclusion).
#[test_only]
module deepbook_predict::scope_framework__intent_behavior__flush_tests;

use deepbook_predict::{
    flush_setup,
    market_setup,
    oracle_profile,
    oracle_setup,
    pool_setup,
    test_values,
    test_world
};
use std::unit_test::assert_eq;

#[test]
fun flush_over_funded_market_with_empty_queues_conserves_pool_nav() {
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

    test_world::next_tx(&mut world, test_values::admin());
    let handles = vector[market_handle];
    let pool_nav = flush_setup::flush(
        &mut world,
        &resources,
        &oracles,
        &handles,
        option::none(),
        option::none(),
    );
    assert_eq!(pool_nav, test_values::pool_capital());

    test_world::finish(world, resources);
}
