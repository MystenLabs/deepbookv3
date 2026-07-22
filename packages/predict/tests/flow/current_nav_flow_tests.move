// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end guard of the live NAV mark: a non-monotone Block Scholes surface
/// over the active book's boundary ticks aborts `current_nav` instead of
/// producing a poisoned pool mark (registered policy: a fresh, usable surface
/// is the recovery path).
#[test_only]
module deepbook_predict::scope_flow__intent_guard__current_nav_tests;

use account::account;
use deepbook_predict::{
    account_setup,
    market_setup,
    oracle_profile,
    oracle_setup,
    pool_setup,
    pricing,
    test_values,
    test_world
};
use sui::test_scenario::return_shared;

const ALL_IN_ONE_X_COST: u64 = 505_000_000; // exact-half net_premium 5e8 + fee 5e6
const LOWER_TICK: u64 = 90;
// The huge-slope, rho = -1 surface makes total variance explode below the
// forward and vanish above it, so the up price at the lower active boundary
// falls below the up price at the higher one — the inversion the memo rejects.
const INVERTING_SVI_B: u64 = 100_000_000_000;
const SVI_RHO_UNIT: u64 = 1_000_000_000;
const INVERTING_SOURCE_TIMESTAMP_MS: u64 = 119_500; // after the exact-half row

#[test, expected_failure(abort_code = pricing::ENonMonotonePriceMemo)]
fun current_nav_rejects_non_monotone_active_book_surface() {
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
    test_world::next_tx(&mut world, test_values::alice());
    let account_handle = account_setup::create_funded_account(
        &mut world,
        &resources,
        test_values::trader_deposit(),
    );

    // A live position whose boundary ticks the NAV walk must price.
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
        test_values::mint_quantity(),
        test_values::leverage_one_x(),
        ALL_IN_ONE_X_COST,
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

    // Publish the inverting surface, then mark: the walk prices the active
    // boundaries in ascending order and rejects the inversion.
    test_world::next_tx(&mut world, test_values::admin());
    let inverting = oracle_profile::new(
        oracle_profile::spot_prices(
            oracle_profile::exact_half().pyth_spot(),
            oracle_profile::exact_half().pyth_spot(),
            oracle_profile::exact_half().pyth_spot(),
        ),
        oracle_profile::svi_params(
            1,
            false,
            INVERTING_SVI_B,
            1_000_000,
            SVI_RHO_UNIT,
            true,
            0,
            false,
        ),
        INVERTING_SOURCE_TIMESTAMP_MS,
    );
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &market_handle,
        &inverting,
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::admin());
    let market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let (pricer, _feeds) = oracle_setup::load_pricer(
        &world,
        &resources,
        &oracles,
        &market,
        &config,
    );
    let _ = market.current_nav(&pricer);

    abort 999
}
