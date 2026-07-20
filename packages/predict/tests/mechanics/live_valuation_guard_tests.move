// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Monotonicity enforcement for live boundary-price memo construction.
#[test_only]
module deepbook_predict::scope_mechanics__intent_guard__live_valuation_tests;

use deepbook_predict::{
    market_setup,
    oracle_profile,
    oracle_setup,
    pricing,
    test_values,
    test_world
};

const NON_MONOTONE_LOW_TICK: u64 = 90;
const NON_MONOTONE_HIGH_TICK: u64 = 95;
const SVI_A: u64 = 1;
const SVI_B: u64 = 100_000_000_000;
const SVI_SIGMA: u64 = 1_000_000;
const SVI_RHO_UNIT: u64 = 1_000_000_000;
const EUnexpectedSuccess: u64 = 999;

#[test, expected_failure(abort_code = pricing::ENonMonotonePriceMemo)]
fun price_memo_rejects_non_monotone_surface_over_active_ticks() {
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
    let market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let mut pyth = oracle_setup::take_pyth(&world, &oracles);
    let mut bs_spot = oracle_setup::take_bs_spot(&world, &oracles);
    let mut bs_forward = oracle_setup::take_bs_forward(&world, &oracles);
    let mut bs_svi = oracle_setup::take_bs_svi(&world, &oracles);
    let profile = oracle_profile::new(
        100_000_000_000,
        100_000_000_000,
        100_000_000_000,
        SVI_A,
        false,
        SVI_B,
        SVI_SIGMA,
        SVI_RHO_UNIT,
        true,
        0,
        false,
        test_values::now_ms() - 1_000,
    );
    oracle_setup::seed_surface(
        &mut pyth,
        &mut bs_spot,
        &mut bs_forward,
        &mut bs_svi,
        market.expiry(),
        &profile,
        test_values::now_ms(),
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    let pricer = market.load_live_pricer(
        &config,
        &oracle_registry,
        &pyth,
        &bs_spot,
        &bs_forward,
        &bs_svi,
        test_world::clock(&resources),
    );
    let mut memo = pricing::new_price_memo();

    memo.price_and_cache(&pricer, NON_MONOTONE_LOW_TICK, test_values::tick_size());
    memo.price_and_cache(&pricer, NON_MONOTONE_HIGH_TICK, test_values::tick_size());
    abort EUnexpectedSuccess
}
