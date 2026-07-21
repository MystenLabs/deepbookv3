// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Framework smoke tests proving one World can drive the full privileged flush
/// end to end: the admin mints the lifecycle cap, proves it, and runs
/// `start_pool_valuation` -> `value_expiry` -> `finish_flush` in one
/// transaction. The live-market smoke conserves pool NAV over a funded,
/// un-traded market; the settled-market smoke proves the same inlined flush
/// sweeps a settled expiry and drains a queued LP supply request at the frozen
/// mark.
#[test_only]
module deepbook_predict::scope_framework__intent_behavior__flush_tests;

use account::account;
use deepbook_predict::{
    account_setup,
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
use sui::test_scenario::return_shared;

// The supply request fills at the frozen parity mark (pool value 20e9 over
// total supply 20e9), minting shares one-for-one with the escrowed DUSDC.
const SUPPLY_REQUEST: u64 = 1_000_000_000;
const EXPECTED_SUPPLY_SHARES: u64 = 1_000_000_000;

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
fun flush_sweeps_settled_market_and_drains_supply_queue_at_frozen_mark() {
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
        SUPPLY_REQUEST,
    );

    // Queue the supply request: escrow leaves account custody immediately.
    test_world::next_tx(&mut world, test_values::alice());
    let mut vault = test_world::take_vault(&world);
    let mut wrapper = account_setup::take_account(&world, &account_handle);
    let root = test_world::take_accumulator_root(&world);
    let config = test_world::take_config(&world);
    let auth = account::generate_auth(test_world::ctx(&mut world));
    vault.request_supply(
        &mut wrapper,
        auth,
        &config,
        SUPPLY_REQUEST,
        EXPECTED_SUPPLY_SHARES,
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    assert_eq!(vault.supply_requests_pending(), 1);
    assert_eq!(wrapper.load_account().balance<DUSDC>(&root, test_world::clock(&resources)), 0);
    return_shared(config);
    return_shared(root);
    return_shared(wrapper);
    return_shared(vault);

    // Settle the untraded market at its exact expiry print.
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

    // The inlined flush: value_expiry sweeps the settled market (contributing
    // 0 NAV, returning its full untraded cash to idle), and finish_flush
    // drains the supply queue at the frozen parity mark.
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

    // The untraded settled market conserves the locked capital exactly, so the
    // frozen mark is parity and the fill mints shares one-for-one.
    assert_eq!(pool_nav, test_values::pool_capital());
    assert!(vault.active_expiry_markets().is_empty());
    assert_eq!(vault.supply_requests_pending(), 0);
    assert_eq!(vault.plp_total_supply(), test_values::pool_capital() + EXPECTED_SUPPLY_SHARES);
    assert_eq!(vault.idle_balance(), test_values::pool_capital() + SUPPLY_REQUEST);
    assert_eq!(market.cash_balance(), 0);

    oracle_setup::return_feeds(feeds);
    return_shared(market);
    return_shared(vault);
    return_shared(config);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
}
