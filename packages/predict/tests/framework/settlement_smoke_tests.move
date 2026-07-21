// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Framework smoke test proving one World composes the full settlement
/// lifecycle end to end: divergent positions minted against one market, the
/// clock advanced past expiry, the settlement spot seeded at the exact expiry
/// millisecond, `try_settle` driven in the test body, the settled sweep run
/// through the standalone rebalance, and both settled redeems resolved — with
/// pool cash conserved at every boundary.
#[test_only]
module deepbook_predict::scope_framework__intent_behavior__settlement_tests;

use account::account;
use deepbook_predict::{
    account_setup,
    constants,
    market_setup,
    oracle_profile,
    oracle_setup,
    pool_setup,
    predict_account,
    test_values,
    test_world
};
use dusdc::dusdc::DUSDC;
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

// Exact-half profile: each range digital over the at-forward boundary quotes
// exactly 0.5, so net_premium = 0.5 * quantity and the min-fee floor binds the
// trading fee at 0.5% * quantity.
const ALL_IN_MINT_COST: u64 = 505_000_000; // net_premium 5e8 + trading_fee 5e6
const TRADER_DEPOSIT: u64 = 1_010_000_000; // exactly two all-in mint costs
const SETTLEMENT_ABOVE_BOUNDARY: u64 = 101_000_000_000; // boundary strike is 100 * 1e9
const WINNER_PAYOUT: u64 = 1_000_000_000; // quantity - floor_shares, 1x floor is 0
const REBATE_RESERVE: u64 = 5_000_000; // floor(0.5 default rebate rate * 2 * 5e6 fees)
// Market cash after both mints: initial expiry cash 10e9 + 2 * 505e6.
const MARKET_CASH_AFTER_MINTS: u64 = 11_010_000_000;
// The settled sweep reserves winner payout + rebate reserve and returns the rest.
const MARKET_CASH_AFTER_SWEEP: u64 = 1_005_000_000;
// The sweep returns 11_010e6 - 1_005e6 = 10_005e6 to idle; terminal profit is
// that return minus the 10_000e6 funded, and the protocol cut is the 0.4
// default reserve share of it, realized out of idle.
const PROTOCOL_CUT: u64 = 2_000_000;
const IDLE_AFTER_SWEEP: u64 = 20_003_000_000; // 10_000e6 + 10_005e6 - 2e6

#[test]
fun divergent_positions_settle_sweep_and_redeem_with_conserved_pool_cash() {
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
        TRADER_DEPOSIT,
    );

    // Divergent positions: the winner covers (boundary, +inf], the loser covers
    // (-inf, boundary]; a settlement above the boundary resolves exactly one.
    test_world::next_tx(&mut world, test_values::alice());
    let mut wrapper = account_setup::take_account(&world, &account_handle);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let (pricer, feeds) = oracle_setup::load_pricer(&world, &resources, &oracles, &market, &config);
    let market_id = market.id();
    let auth = account::generate_auth(test_world::ctx(&mut world));
    let winner_order_id = market.mint_exact_quantity(
        &mut wrapper,
        auth,
        &config,
        &pricer,
        test_values::strike_tick(),
        constants::pos_inf_tick!(),
        test_values::mint_quantity(),
        test_values::leverage_one_x(),
        ALL_IN_MINT_COST,
        std::u64::max_value!(),
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    let auth = account::generate_auth(test_world::ctx(&mut world));
    let loser_order_id = market.mint_exact_quantity(
        &mut wrapper,
        auth,
        &config,
        &pricer,
        0,
        test_values::strike_tick(),
        test_values::mint_quantity(),
        test_values::leverage_one_x(),
        ALL_IN_MINT_COST,
        std::u64::max_value!(),
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    assert_eq!(wrapper.load_account().balance<DUSDC>(&root, test_world::clock(&resources)), 0);
    assert_eq!(market.cash_balance(), MARKET_CASH_AFTER_MINTS);
    oracle_setup::return_feeds(feeds);
    return_shared(config);
    return_shared(market);
    return_shared(root);
    return_shared(wrapper);

    // Settlement: advance past expiry, seed the exact-expiry-ms spot, and drive
    // the permissionless transition in the test body.
    let expiry_ms = test_values::expiry_ms();
    test_world::clock_mut(&mut resources).set_for_testing(expiry_ms);
    test_world::next_tx(&mut world, test_values::admin());
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let mut pyth = oracle_setup::take_pyth(&world, &oracles);
    oracle_setup::seed_exact_pyth(&mut pyth, SETTLEMENT_ABOVE_BOUNDARY, expiry_ms, expiry_ms);
    assert!(
        market.try_settle(
            &config,
            &oracle_registry,
            &pyth,
            test_world::clock(&resources),
        ),
    );
    assert!(market.is_settled());
    assert_eq!(market.settlement_price(), SETTLEMENT_ABOVE_BOUNDARY);
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(market);

    // Settled sweep through the standalone rebalance: the expiry deactivates,
    // free cash above the reserved payout + rebate backing returns to idle, and
    // the terminal profit's protocol cut is realized into the reserve.
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    vault.rebalance_expiry_cash(&mut market, &config, test_world::clock(&resources));
    assert!(vault.active_expiry_markets().is_empty());
    assert_eq!(market.cash_balance(), MARKET_CASH_AFTER_SWEEP);
    assert_eq!(market.payout_liability(), WINNER_PAYOUT);
    assert_eq!(market.rebate_reserve(), REBATE_RESERVE);
    assert_eq!(vault.idle_balance(), IDLE_AFTER_SWEEP);
    assert_eq!(vault.protocol_reserve_balance(), PROTOCOL_CUT);
    return_shared(config);
    return_shared(market);
    return_shared(vault);

    // Settled redeems against the reserved cash: the winner is paid its exact
    // terminal payout, the loser clears its position for nothing.
    test_world::next_tx(&mut world, test_values::alice());
    let mut wrapper = account_setup::take_account(&world, &account_handle);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let auth = account::generate_auth(test_world::ctx(&mut world));
    market.redeem_settled(
        &mut wrapper,
        auth,
        &config,
        winner_order_id,
        test_values::mint_quantity(),
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    let auth = account::generate_auth(test_world::ctx(&mut world));
    market.redeem_settled(
        &mut wrapper,
        auth,
        &config,
        loser_order_id,
        test_values::mint_quantity(),
        &root,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    assert_eq!(
        wrapper.load_account().balance<DUSDC>(&root, test_world::clock(&resources)),
        WINNER_PAYOUT,
    );
    assert!(!predict_account::has_position(wrapper.load_account(), market_id, winner_order_id));
    assert!(!predict_account::has_position(wrapper.load_account(), market_id, loser_order_id));
    // Only the unresolved rebate reserve remains in the expiry.
    assert_eq!(market.cash_balance(), MARKET_CASH_AFTER_SWEEP - WINNER_PAYOUT);
    return_shared(config);
    return_shared(market);
    return_shared(root);
    return_shared(wrapper);
    test_world::finish(world, resources);
}
