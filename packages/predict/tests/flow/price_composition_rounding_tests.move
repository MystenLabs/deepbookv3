// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Composition properties the protocol must hold for its own solvency, stated
/// without an external oracle: the book's aggregated liability must cover the
/// sum of what the market would actually pay each holder, and a set of
/// positions whose combined settlement is certain must be reserved in full.
/// Both survive today; they exist to catch a regression in either direction of
/// the aggregate-versus-per-order rounding seam.
#[test_only]
module deepbook_predict::scope_flow__intent_rounding__price_composition_tests;

use account::account;
use deepbook_predict::{
    account_setup,
    constants,
    market_setup,
    oracle_setup,
    pool_setup,
    pricing_reference_data,
    test_values,
    test_world
};
use dusdc::dusdc::DUSDC;
use sui::test_scenario::return_shared;

const TICK_LOW: u64 = 90;
const TICK_MID: u64 = 100;
const TICK_HIGH: u64 = 110;
const QUANTITY: u64 = 20_000_000;
const LEVERAGE_ONE_X: u64 = 1_000_000_000;
const PROBE_PROFILE: u64 = 0;
// Tick 0 is the neg-inf sentinel (pricing::cached_up_price).
const NEG_INF_TICK: u64 = 0;

/// PROPERTY A — aggregate liability must cover the sum of per-order values.
/// `current_nav` prices the book through one aggregated walk; `order_value`
/// prices each order the way the market would actually pay it on a full close.
/// If the aggregate marks the book cheaper than the sum of its own payables,
/// NAV is overstated and an LP withdrawal at that mark is funded by cash the
/// pool still owes holders.
#[test]
fun aggregate_liability_covers_the_sum_of_per_order_values() {
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
    let profile = pricing_reference_data::profile(PROBE_PROFILE);
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

    // Two adjacent ranges sharing tick 100: at the shared boundary the walk's
    // start and end quantities cancel, so the aggregate prices the union
    // (90, 110] through one flooring while each order is payable on its own.
    let auth = account::generate_auth(test_world::ctx(&mut world));
    let lower_order = market.mint_exact_quantity(
        &mut wrapper,
        auth,
        &config,
        &pricer,
        TICK_LOW,
        TICK_MID,
        QUANTITY,
        LEVERAGE_ONE_X,
        std::u64::max_value!(),
        std::u64::max_value!(),
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    let auth = account::generate_auth(test_world::ctx(&mut world));
    let upper_order = market.mint_exact_quantity(
        &mut wrapper,
        auth,
        &config,
        &pricer,
        TICK_MID,
        TICK_HIGH,
        QUANTITY,
        LEVERAGE_ONE_X,
        std::u64::max_value!(),
        std::u64::max_value!(),
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );

    let free_cash = market.cash_balance() - market.rebate_reserve();
    let aggregate_liability = free_cash - market.current_nav(&pricer);
    let payable_sum =
        market.order_value(option::some(pricer), lower_order) +
        market.order_value(option::some(pricer), upper_order);
    assert!(aggregate_liability >= payable_sum);

    oracle_setup::return_feeds(feeds);
    return_shared(config);
    return_shared(market);
    return_shared(root);
    return_shared(wrapper);
    test_world::finish(world, resources);
}

/// PROPERTY B — a certain payout must be fully reserved. Three 1x orders
/// partition the line, so their combined settlement pays exactly `QUANTITY`
/// whatever the print. The pool's marked liability must therefore be at least
/// `QUANTITY`: any shortfall is cash the pool marks as its own while owing it
/// to holders, and the same shortfall is what a trader pays below certainty.
#[test]
fun a_full_partition_of_the_line_reserves_the_certain_payout() {
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
    let profile = pricing_reference_data::profile(PROBE_PROFILE);
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

    let balance_before = wrapper
        .load_account()
        .balance<DUSDC>(&root, test_world::clock(&resources));
    let free_cash_before = market.cash_balance() - market.rebate_reserve();
    let nav_before = market.current_nav(&pricer);

    // (neg_inf, 90] + (90, 110] + (110, pos_inf] covers every settlement print
    // exactly once, so the holder is certain to redeem QUANTITY in total.
    let auth = account::generate_auth(test_world::ctx(&mut world));
    market.mint_exact_quantity(
        &mut wrapper,
        auth,
        &config,
        &pricer,
        NEG_INF_TICK,
        TICK_LOW,
        QUANTITY,
        LEVERAGE_ONE_X,
        std::u64::max_value!(),
        std::u64::max_value!(),
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    let auth = account::generate_auth(test_world::ctx(&mut world));
    market.mint_exact_quantity(
        &mut wrapper,
        auth,
        &config,
        &pricer,
        TICK_LOW,
        TICK_HIGH,
        QUANTITY,
        LEVERAGE_ONE_X,
        std::u64::max_value!(),
        std::u64::max_value!(),
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    let auth = account::generate_auth(test_world::ctx(&mut world));
    market.mint_exact_quantity(
        &mut wrapper,
        auth,
        &config,
        &pricer,
        TICK_HIGH,
        constants::pos_inf_tick!(),
        QUANTITY,
        LEVERAGE_ONE_X,
        std::u64::max_value!(),
        std::u64::max_value!(),
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );

    let free_cash_after = market.cash_balance() - market.rebate_reserve();
    let marked_liability = free_cash_after - market.current_nav(&pricer);
    // The pool's marked liability must cover the certain payout.
    assert!(marked_liability >= QUANTITY);
    // The pool's NAV must not rise by more than the fees it actually kept:
    // premiums for a certain payout are fully offset by the liability.
    let balance_after = wrapper.load_account().balance<DUSDC>(&root, test_world::clock(&resources));
    let trader_paid = balance_before - balance_after;
    let fees_kept = free_cash_after - free_cash_before - QUANTITY;
    assert!(trader_paid >= QUANTITY);
    assert!(market.current_nav(&pricer) <= nav_before + fees_kept);

    oracle_setup::return_feeds(feeds);
    return_shared(config);
    return_shared(market);
    return_shared(root);
    return_shared(wrapper);
    test_world::finish(world, resources);
}
