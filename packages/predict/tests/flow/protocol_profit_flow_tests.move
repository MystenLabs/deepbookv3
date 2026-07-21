// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Cross-market terminal profit ordering: the protocol cut should reserve the
/// share of NET pool profit regardless of which settled expiry is swept first.
/// The loss-first order does; the profit-first order books the cut against the
/// gross profit before the offsetting loss is carried, so its sibling fails —
/// the enrolled production finding on the reserve's accrual basis.
#[test_only]
module deepbook_predict::scope_flow__intent_policy__protocol_profit_tests;

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
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

const LOWER_TICK: u64 = 90;
const TWO_MARKET_WINDOW: u64 = 2;
const TWO_MARKET_CAPITAL: u64 = 20_000_000_000; // exactly two 10e9 funding floors
// Profit market: the trader loses a 20e6 exact-half position (all-in 10.1e6);
// the sweep returns cash minus the 50e3 rebate reserve, a 10.05e6 profit.
const PROFIT_QUANTITY: u64 = 20_000_000;
const PROFIT_ALL_IN_COST: u64 = 10_100_000;
// Loss market: the trader wins a 2e9 exact-half position (all-in 1.01e9); the
// sweep keeps the 2e9 payout + 5e6 rebate reserve, a 995e6 terminal loss.
const LOSS_QUANTITY: u64 = 2_000_000_000;
const LOSS_ALL_IN_COST: u64 = 1_010_000_000;
const TRADER_DEPOSIT: u64 = 1_020_100_000; // both all-in costs
const PROFIT_SETTLE_SPOT: u64 = 200_000_000_000; // above (90, 100]: trader loses
const LOSS_SETTLE_SPOT: u64 = 95_000_000_000; // inside (90, 100]: trader wins
const LOSS_SURFACE_TIMESTAMP_MS: u64 = 119_100; // after the profit market's row
// Net pool P&L is 10.05e6 profit minus 995e6 loss: negative, so the
// order-independent protocol cut is zero.
const NET_POOL_PROFIT_CUT: u64 = 0;
// Sweeps return 10_010.05e6 and 9_005e6; with a zero cut all of it is idle.
const IDLE_AFTER_BOTH_SWEEPS: u64 = 19_015_050_000;

#[test]
fun loss_first_sweep_reserves_share_of_net_pool_profit() {
    let (mut world, mut resources) = test_world::new(
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
    let profit_market = handles[0];
    let loss_market = handles[1];
    test_world::next_tx(&mut world, test_values::admin());
    pool_setup::fund_market(
        &mut world,
        &resources,
        &profit_market,
        TWO_MARKET_CAPITAL,
    );
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut market = market_setup::take_market(&world, &loss_market);
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
        &profit_market,
        &profile,
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let profile_l = oracle_profile::exact_half_at(LOSS_SURFACE_TIMESTAMP_MS);
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &loss_market,
        &profile_l,
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::alice());
    let account_handle = account_setup::create_funded_account(
        &mut world,
        &resources,
        TRADER_DEPOSIT,
    );

    test_world::next_tx(&mut world, test_values::alice());
    let mut wrapper = account_setup::take_account(&world, &account_handle);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &profit_market);
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
        PROFIT_QUANTITY,
        test_values::leverage_one_x(),
        PROFIT_ALL_IN_COST,
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
    test_world::next_tx(&mut world, test_values::alice());
    let mut wrapper = account_setup::take_account(&world, &account_handle);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &loss_market);
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
        LOSS_QUANTITY,
        test_values::leverage_one_x(),
        LOSS_ALL_IN_COST,
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

    // Both markets settle: the profit market's print lands outside its range,
    // the loss market's inside.
    let loss_expiry_ms = test_values::expiry_ms() + test_values::cadence_period_ms();
    test_world::clock_mut(&mut resources).set_for_testing(loss_expiry_ms);
    test_world::next_tx(&mut world, test_values::admin());
    let mut p_market = market_setup::take_market(&world, &profit_market);
    let mut l_market = market_setup::take_market(&world, &loss_market);
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let mut pyth = oracle_setup::take_pyth(&world, &oracles);
    oracle_setup::seed_exact_pyth(
        &mut pyth,
        PROFIT_SETTLE_SPOT,
        test_values::expiry_ms(),
        loss_expiry_ms,
    );
    oracle_setup::seed_exact_pyth(&mut pyth, LOSS_SETTLE_SPOT, loss_expiry_ms, loss_expiry_ms);
    assert!(
        p_market.try_settle(
            &config,
            &oracle_registry,
            &pyth,
            test_world::clock(&resources),
        ),
    );
    assert!(
        l_market.try_settle(
            &config,
            &oracle_registry,
            &pyth,
            test_world::clock(&resources),
        ),
    );
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(l_market);
    return_shared(p_market);

    // Loss-first sweep order: the 995e6 terminal loss is booked before the
    // 10.05e6 profit, which only refills the carry — no cut is taken.
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut l_market = market_setup::take_market(&world, &loss_market);
    let config = test_world::take_config(&world);
    vault.rebalance_expiry_cash(&mut l_market, &config, test_world::clock(&resources));
    return_shared(config);
    return_shared(l_market);
    return_shared(vault);
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut p_market = market_setup::take_market(&world, &profit_market);
    let config = test_world::take_config(&world);
    vault.rebalance_expiry_cash(&mut p_market, &config, test_world::clock(&resources));
    assert_eq!(vault.protocol_reserve_balance(), NET_POOL_PROFIT_CUT);
    assert_eq!(vault.idle_balance(), IDLE_AFTER_BOTH_SWEEPS);
    return_shared(config);
    return_shared(p_market);
    return_shared(vault);
    test_world::finish(world, resources);
}

// KNOWN-FAILING: P-8
#[test]
fun profit_first_sweep_reserves_share_of_net_pool_profit() {
    let (mut world, mut resources) = test_world::new(
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
    let profit_market = handles[0];
    let loss_market = handles[1];
    test_world::next_tx(&mut world, test_values::admin());
    pool_setup::fund_market(
        &mut world,
        &resources,
        &profit_market,
        TWO_MARKET_CAPITAL,
    );
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut market = market_setup::take_market(&world, &loss_market);
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
        &profit_market,
        &profile,
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let profile_l = oracle_profile::exact_half_at(LOSS_SURFACE_TIMESTAMP_MS);
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &loss_market,
        &profile_l,
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::alice());
    let account_handle = account_setup::create_funded_account(
        &mut world,
        &resources,
        TRADER_DEPOSIT,
    );

    test_world::next_tx(&mut world, test_values::alice());
    let mut wrapper = account_setup::take_account(&world, &account_handle);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &profit_market);
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
        PROFIT_QUANTITY,
        test_values::leverage_one_x(),
        PROFIT_ALL_IN_COST,
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
    test_world::next_tx(&mut world, test_values::alice());
    let mut wrapper = account_setup::take_account(&world, &account_handle);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &loss_market);
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
        LOSS_QUANTITY,
        test_values::leverage_one_x(),
        LOSS_ALL_IN_COST,
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

    let loss_expiry_ms = test_values::expiry_ms() + test_values::cadence_period_ms();
    test_world::clock_mut(&mut resources).set_for_testing(loss_expiry_ms);
    test_world::next_tx(&mut world, test_values::admin());
    let mut p_market = market_setup::take_market(&world, &profit_market);
    let mut l_market = market_setup::take_market(&world, &loss_market);
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let mut pyth = oracle_setup::take_pyth(&world, &oracles);
    oracle_setup::seed_exact_pyth(
        &mut pyth,
        PROFIT_SETTLE_SPOT,
        test_values::expiry_ms(),
        loss_expiry_ms,
    );
    oracle_setup::seed_exact_pyth(&mut pyth, LOSS_SETTLE_SPOT, loss_expiry_ms, loss_expiry_ms);
    assert!(
        p_market.try_settle(
            &config,
            &oracle_registry,
            &pyth,
            test_world::clock(&resources),
        ),
    );
    assert!(
        l_market.try_settle(
            &config,
            &oracle_registry,
            &pyth,
            test_world::clock(&resources),
        ),
    );
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(l_market);
    return_shared(p_market);

    // Profit-first sweep order: sweeping the profitable expiry before the
    // offsetting loss should still reserve only the share of NET pool profit
    // (zero here). The permissionless ordering must not change what the
    // protocol keeps — this is the enrolled production finding: the cut books
    // against gross recognized profit and the later loss never claws it back.
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut p_market = market_setup::take_market(&world, &profit_market);
    let config = test_world::take_config(&world);
    vault.rebalance_expiry_cash(&mut p_market, &config, test_world::clock(&resources));
    return_shared(config);
    return_shared(p_market);
    return_shared(vault);
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut l_market = market_setup::take_market(&world, &loss_market);
    let config = test_world::take_config(&world);
    vault.rebalance_expiry_cash(&mut l_market, &config, test_world::clock(&resources));
    assert_eq!(vault.protocol_reserve_balance(), NET_POOL_PROFIT_CUT);
    assert_eq!(vault.idle_balance(), IDLE_AFTER_BOTH_SWEEPS);
    return_shared(config);
    return_shared(l_market);
    return_shared(vault);
    test_world::finish(world, resources);
}

// --- Deferred protocol profit (defer-and-carry) constants. ---
// Twelve churn rounds compound the first market's cash to 41_369.5e6 with an
// empty book (rebate reserve 204.75e6 from 0.5% fees on 81_900e6 total churned
// quantity); the live rebalance sweeps the surplus above the 10e9 floor to
// idle WITHOUT terminal accounting — the sticky credit basis.
const FOUR_MARKET_WINDOW: u64 = 4;
const DEEP_BOOTSTRAP: u64 = 10_000_000;
const DEEP_CHURN_ROUND_MS: u64 = 2_000;
const CHURN_DEPOSIT: u64 = 41_359_500_000; // 0.505 x 81_900e6 total quantity
const LIVE_SWEPT_IDLE: u64 = 31_369_500_000; // cash 41_369.5e6 minus 10e9 target
const IDLE_AFTER_ABSORPTION: u64 = 1_369_500_000; // after three 10e9 fundings
// Each absorption market mints Q = 20_100_500_000 at exact-half (all-in
// 10_150_752_500), leaving cash exactly 1_250 above its backing floor; the
// P = 1 re-mark then values each market at that 1_250 dust NAV.
const ABSORPTION_QUANTITY: u64 = 20_100_500_000;
const ABSORPTION_ALL_IN_COST: u64 = 10_150_752_500;
const ABSORPTION_DEPOSIT: u64 = 30_452_257_500; // three all-in costs
const DUST_NAV: u64 = 1_250;
// Settle-sweeping the churn market returns 10e9 minus the 204.75e6 reserve;
// its 41_154.75e6 terminal profit takes a 0.4 cut of 16_461.9e6, capped at
// the 11_164.75e6 idle — the 5_297.15e6 remainder carries.
const CARRIED_PENDING: u64 = 5_297_150_000;
const RESERVE_AT_CARRY: u64 = 11_164_750_000;
// The next cash-abundant sweep (absorption market B settling as a loser,
// returning 20_100_501_250) realizes B's own 4_040_200_500 cut plus the carry.
const RESERVE_AFTER_REALIZATION: u64 = 20_502_100_500;
const IDLE_AFTER_REALIZATION: u64 = 10_763_150_750;
const DEEP_REMARK_SPOT: u64 = 95_000_000_000; // inside (90, 100]: P = 1

#[test]
fun carried_protocol_profit_is_held_out_of_the_flush_mark() {
    let (mut world, mut resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    market_setup::configure_cadence(&world, &admin_cap, FOUR_MARKET_WINDOW);
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
        FOUR_MARKET_WINDOW,
    );
    test_world::return_predict_admin_cap(&world, admin_cap);
    let churn_market = handles[0];
    let absorb_b = handles[1];
    let absorb_c = handles[2];
    let absorb_d = handles[3];
    test_world::next_tx(&mut world, test_values::admin());
    pool_setup::fund_market(
        &mut world,
        &resources,
        &churn_market,
        DEEP_BOOTSTRAP,
    );
    test_world::next_tx(&mut world, test_values::alice());
    let churn_account = account_setup::create_funded_account(
        &mut world,
        &resources,
        CHURN_DEPOSIT,
    );

    // Compound the churn market's cash: each round's premium and fee stay when
    // the position closes worthless at the collapsed re-mark.
    let round_quantities = vector[
        20_000_000u64,
        40_000_000,
        80_000_000,
        160_000_000,
        320_000_000,
        640_000_000,
        1_280_000_000,
        2_560_000_000,
        5_120_000_000,
        10_240_000_000,
        20_480_000_000,
        40_960_000_000,
    ];
    let mut round = 0;
    while (round < round_quantities.length()) {
        let quantity = round_quantities[round];
        let mint_ms = test_values::now_ms() + round * DEEP_CHURN_ROUND_MS;
        test_world::clock_mut(&mut resources).set_for_testing(mint_ms);
        test_world::next_tx(&mut world, test_values::admin());
        let half = oracle_profile::exact_half_at(mint_ms - 500);
        oracle_setup::seed_market_surface(
            &mut world,
            &resources,
            &oracles,
            &churn_market,
            &half,
            mint_ms,
        );
        test_world::next_tx(&mut world, test_values::alice());
        let mut wrapper = account_setup::take_account(&world, &churn_account);
        let root = test_world::take_accumulator_root(&world);
        let mut market = market_setup::take_market(&world, &churn_market);
        let config = test_world::take_config(&world);
        let (pricer, feeds) = oracle_setup::load_pricer(
            &world,
            &resources,
            &oracles,
            &market,
            &config,
        );
        let auth = account::generate_auth(test_world::ctx(&mut world));
        let order_id = market.mint_exact_quantity(
            &mut wrapper,
            auth,
            &config,
            &pricer,
            LOWER_TICK,
            test_values::strike_tick(),
            quantity,
            test_values::leverage_one_x(),
            quantity / 2 + quantity / 200,
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

        test_world::clock_mut(&mut resources).set_for_testing(mint_ms + 1_000);
        test_world::next_tx(&mut world, test_values::admin());
        let collapse = oracle_profile::new(
            oracle_profile::spot_prices(
                PROFIT_SETTLE_SPOT,
                PROFIT_SETTLE_SPOT,
                PROFIT_SETTLE_SPOT,
            ),
            oracle_profile::svi_params(1, false, 0, 1_000_000, 0, false, 0, false),
            mint_ms + 500,
        );
        oracle_setup::seed_market_surface(
            &mut world,
            &resources,
            &oracles,
            &churn_market,
            &collapse,
            mint_ms + 1_000,
        );
        test_world::next_tx(&mut world, test_values::alice());
        let mut wrapper = account_setup::take_account(&world, &churn_account);
        let root = test_world::take_accumulator_root(&world);
        let mut market = market_setup::take_market(&world, &churn_market);
        let config = test_world::take_config(&world);
        let (pricer, feeds) = oracle_setup::load_pricer(
            &world,
            &resources,
            &oracles,
            &market,
            &config,
        );
        let auth = account::generate_auth(test_world::ctx(&mut world));
        let (_, replacement) = market.redeem_live(
            &mut wrapper,
            auth,
            &config,
            &pricer,
            order_id,
            quantity,
            0,
            0,
            &root,
            test_world::clock(&resources),
            test_world::ctx(&mut world),
        );
        assert!(replacement.is_none());
        oracle_setup::return_feeds(feeds);
        return_shared(config);
        return_shared(market);
        return_shared(root);
        return_shared(wrapper);
        round = round + 1;
    };

    // The live rebalance sweeps the surplus above the 10e9 floor into idle
    // with NO terminal accounting: the sticky credit excess is born here.
    test_world::clock_mut(&mut resources).set_for_testing(145_000);
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut market = market_setup::take_market(&world, &churn_market);
    let config = test_world::take_config(&world);
    vault.rebalance_expiry_cash(&mut market, &config, test_world::clock(&resources));
    assert_eq!(vault.idle_balance(), LIVE_SWEPT_IDLE);
    return_shared(config);
    return_shared(market);
    return_shared(vault);

    // Deploy the swollen idle into the three absorption markets.
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut market = market_setup::take_market(&world, &absorb_b);
    let config = test_world::take_config(&world);
    vault.rebalance_expiry_cash(&mut market, &config, test_world::clock(&resources));
    return_shared(config);
    return_shared(market);
    return_shared(vault);
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut market = market_setup::take_market(&world, &absorb_c);
    let config = test_world::take_config(&world);
    vault.rebalance_expiry_cash(&mut market, &config, test_world::clock(&resources));
    return_shared(config);
    return_shared(market);
    return_shared(vault);
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut market = market_setup::take_market(&world, &absorb_d);
    let config = test_world::take_config(&world);
    vault.rebalance_expiry_cash(&mut market, &config, test_world::clock(&resources));
    assert_eq!(vault.idle_balance(), IDLE_AFTER_ABSORPTION);
    return_shared(config);
    return_shared(market);
    return_shared(vault);

    // Backing-floor-exact mints drive each absorption market's NAV to dust.
    test_world::clock_mut(&mut resources).set_for_testing(150_000);
    test_world::next_tx(&mut world, test_values::admin());
    let half_b = oracle_profile::exact_half_at(149_000);
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &absorb_b,
        &half_b,
        150_000,
    );
    test_world::next_tx(&mut world, test_values::admin());
    let half_c = oracle_profile::exact_half_at(149_100);
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &absorb_c,
        &half_c,
        150_000,
    );
    test_world::next_tx(&mut world, test_values::admin());
    let half_d = oracle_profile::exact_half_at(149_200);
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &absorb_d,
        &half_d,
        150_000,
    );
    test_world::next_tx(&mut world, test_values::bob());
    let absorb_account = account_setup::create_funded_account(
        &mut world,
        &resources,
        ABSORPTION_DEPOSIT,
    );
    test_world::next_tx(&mut world, test_values::bob());
    let mut wrapper = account_setup::take_account(&world, &absorb_account);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &absorb_b);
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
        ABSORPTION_QUANTITY,
        test_values::leverage_one_x(),
        ABSORPTION_ALL_IN_COST,
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
    test_world::next_tx(&mut world, test_values::bob());
    let mut wrapper = account_setup::take_account(&world, &absorb_account);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &absorb_c);
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
        ABSORPTION_QUANTITY,
        test_values::leverage_one_x(),
        ABSORPTION_ALL_IN_COST,
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
    test_world::next_tx(&mut world, test_values::bob());
    let mut wrapper = account_setup::take_account(&world, &absorb_account);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &absorb_d);
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
        ABSORPTION_QUANTITY,
        test_values::leverage_one_x(),
        ABSORPTION_ALL_IN_COST,
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

    // Re-mark every absorption surface inside the range (P = 1), settle the
    // churn market at its exact print, and sweep it: the cut exceeds idle, so
    // the remainder carries in pending_protocol_profit.
    test_world::clock_mut(&mut resources).set_for_testing(test_values::expiry_ms());
    test_world::next_tx(&mut world, test_values::admin());
    let remark_b = oracle_profile::new(
        oracle_profile::spot_prices(DEEP_REMARK_SPOT, DEEP_REMARK_SPOT, DEEP_REMARK_SPOT),
        oracle_profile::svi_params(1, false, 0, 1_000_000, 0, false, 0, false),
        179_000,
    );
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &absorb_b,
        &remark_b,
        test_values::expiry_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let remark_c = oracle_profile::new(
        oracle_profile::spot_prices(DEEP_REMARK_SPOT, DEEP_REMARK_SPOT, DEEP_REMARK_SPOT),
        oracle_profile::svi_params(1, false, 0, 1_000_000, 0, false, 0, false),
        179_100,
    );
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &absorb_c,
        &remark_c,
        test_values::expiry_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let remark_d = oracle_profile::new(
        oracle_profile::spot_prices(DEEP_REMARK_SPOT, DEEP_REMARK_SPOT, DEEP_REMARK_SPOT),
        oracle_profile::svi_params(1, false, 0, 1_000_000, 0, false, 0, false),
        179_200,
    );
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &absorb_d,
        &remark_d,
        test_values::expiry_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let mut market = market_setup::take_market(&world, &churn_market);
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let mut pyth = oracle_setup::take_pyth(&world, &oracles);
    oracle_setup::seed_exact_pyth(
        &mut pyth,
        PROFIT_SETTLE_SPOT,
        test_values::expiry_ms(),
        test_values::expiry_ms(),
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
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut market = market_setup::take_market(&world, &churn_market);
    let config = test_world::take_config(&world);
    vault.rebalance_expiry_cash(&mut market, &config, test_world::clock(&resources));
    assert_eq!(vault.pending_protocol_profit(), CARRIED_PENDING);
    assert_eq!(vault.protocol_reserve_balance(), RESERVE_AT_CARRY);
    assert_eq!(vault.idle_balance(), 0);
    return_shared(config);
    return_shared(market);
    return_shared(vault);

    // The flush values three dust-NAV markets: gross pool value is a positive
    // 3_750, yet the carried 5_297.15e6 held-out exceeds it, so the mark
    // clamps to zero — the sticky-exclusion clamp firing on real state.
    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut registry = test_world::take_registry(&world);
    let mut config = test_world::take_config(&world);
    let mut vault = test_world::take_vault(&world);
    let mut b = market_setup::take_market(&world, &absorb_b);
    let mut c = market_setup::take_market(&world, &absorb_c);
    let mut d = market_setup::take_market(&world, &absorb_d);
    let feeds = oracle_setup::borrow_feeds(&world, &oracles);
    let dust_pricer = b.load_live_pricer(
        &config,
        feeds.oracle_registry(),
        feeds.pyth(),
        feeds.bs_spot(),
        feeds.bs_forward(),
        feeds.bs_svi(),
        test_world::clock(&resources),
    );
    assert_eq!(b.current_nav(&dust_pricer), DUST_NAV);
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
        &mut b,
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
        &mut c,
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
        &mut d,
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
    assert_eq!(pool_nav, 0);
    assert_eq!(vault.pending_protocol_profit(), CARRIED_PENDING);
    oracle_setup::return_feeds(feeds);
    return_shared(d);
    return_shared(c);
    return_shared(b);
    return_shared(vault);
    return_shared(config);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
}

#[test]
fun carried_protocol_profit_realizes_on_the_next_cash_abundant_sweep() {
    let (mut world, mut resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    market_setup::configure_cadence(&world, &admin_cap, FOUR_MARKET_WINDOW);
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
        FOUR_MARKET_WINDOW,
    );
    test_world::return_predict_admin_cap(&world, admin_cap);
    let churn_market = handles[0];
    let absorb_b = handles[1];
    let absorb_c = handles[2];
    let absorb_d = handles[3];
    test_world::next_tx(&mut world, test_values::admin());
    pool_setup::fund_market(
        &mut world,
        &resources,
        &churn_market,
        DEEP_BOOTSTRAP,
    );
    test_world::next_tx(&mut world, test_values::alice());
    let churn_account = account_setup::create_funded_account(
        &mut world,
        &resources,
        CHURN_DEPOSIT,
    );

    // Compound the churn market's cash: each round's premium and fee stay when
    // the position closes worthless at the collapsed re-mark.
    let round_quantities = vector[
        20_000_000u64,
        40_000_000,
        80_000_000,
        160_000_000,
        320_000_000,
        640_000_000,
        1_280_000_000,
        2_560_000_000,
        5_120_000_000,
        10_240_000_000,
        20_480_000_000,
        40_960_000_000,
    ];
    let mut round = 0;
    while (round < round_quantities.length()) {
        let quantity = round_quantities[round];
        let mint_ms = test_values::now_ms() + round * DEEP_CHURN_ROUND_MS;
        test_world::clock_mut(&mut resources).set_for_testing(mint_ms);
        test_world::next_tx(&mut world, test_values::admin());
        let half = oracle_profile::exact_half_at(mint_ms - 500);
        oracle_setup::seed_market_surface(
            &mut world,
            &resources,
            &oracles,
            &churn_market,
            &half,
            mint_ms,
        );
        test_world::next_tx(&mut world, test_values::alice());
        let mut wrapper = account_setup::take_account(&world, &churn_account);
        let root = test_world::take_accumulator_root(&world);
        let mut market = market_setup::take_market(&world, &churn_market);
        let config = test_world::take_config(&world);
        let (pricer, feeds) = oracle_setup::load_pricer(
            &world,
            &resources,
            &oracles,
            &market,
            &config,
        );
        let auth = account::generate_auth(test_world::ctx(&mut world));
        let order_id = market.mint_exact_quantity(
            &mut wrapper,
            auth,
            &config,
            &pricer,
            LOWER_TICK,
            test_values::strike_tick(),
            quantity,
            test_values::leverage_one_x(),
            quantity / 2 + quantity / 200,
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

        test_world::clock_mut(&mut resources).set_for_testing(mint_ms + 1_000);
        test_world::next_tx(&mut world, test_values::admin());
        let collapse = oracle_profile::new(
            oracle_profile::spot_prices(
                PROFIT_SETTLE_SPOT,
                PROFIT_SETTLE_SPOT,
                PROFIT_SETTLE_SPOT,
            ),
            oracle_profile::svi_params(1, false, 0, 1_000_000, 0, false, 0, false),
            mint_ms + 500,
        );
        oracle_setup::seed_market_surface(
            &mut world,
            &resources,
            &oracles,
            &churn_market,
            &collapse,
            mint_ms + 1_000,
        );
        test_world::next_tx(&mut world, test_values::alice());
        let mut wrapper = account_setup::take_account(&world, &churn_account);
        let root = test_world::take_accumulator_root(&world);
        let mut market = market_setup::take_market(&world, &churn_market);
        let config = test_world::take_config(&world);
        let (pricer, feeds) = oracle_setup::load_pricer(
            &world,
            &resources,
            &oracles,
            &market,
            &config,
        );
        let auth = account::generate_auth(test_world::ctx(&mut world));
        let (_, replacement) = market.redeem_live(
            &mut wrapper,
            auth,
            &config,
            &pricer,
            order_id,
            quantity,
            0,
            0,
            &root,
            test_world::clock(&resources),
            test_world::ctx(&mut world),
        );
        assert!(replacement.is_none());
        oracle_setup::return_feeds(feeds);
        return_shared(config);
        return_shared(market);
        return_shared(root);
        return_shared(wrapper);
        round = round + 1;
    };

    // The live rebalance sweeps the surplus above the 10e9 floor into idle
    // with NO terminal accounting: the sticky credit excess is born here.
    test_world::clock_mut(&mut resources).set_for_testing(145_000);
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut market = market_setup::take_market(&world, &churn_market);
    let config = test_world::take_config(&world);
    vault.rebalance_expiry_cash(&mut market, &config, test_world::clock(&resources));
    assert_eq!(vault.idle_balance(), LIVE_SWEPT_IDLE);
    return_shared(config);
    return_shared(market);
    return_shared(vault);

    // Deploy the swollen idle into the three absorption markets.
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut market = market_setup::take_market(&world, &absorb_b);
    let config = test_world::take_config(&world);
    vault.rebalance_expiry_cash(&mut market, &config, test_world::clock(&resources));
    return_shared(config);
    return_shared(market);
    return_shared(vault);
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut market = market_setup::take_market(&world, &absorb_c);
    let config = test_world::take_config(&world);
    vault.rebalance_expiry_cash(&mut market, &config, test_world::clock(&resources));
    return_shared(config);
    return_shared(market);
    return_shared(vault);
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut market = market_setup::take_market(&world, &absorb_d);
    let config = test_world::take_config(&world);
    vault.rebalance_expiry_cash(&mut market, &config, test_world::clock(&resources));
    assert_eq!(vault.idle_balance(), IDLE_AFTER_ABSORPTION);
    return_shared(config);
    return_shared(market);
    return_shared(vault);

    // Backing-floor-exact mints drive each absorption market's NAV to dust.
    test_world::clock_mut(&mut resources).set_for_testing(150_000);
    test_world::next_tx(&mut world, test_values::admin());
    let half_b = oracle_profile::exact_half_at(149_000);
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &absorb_b,
        &half_b,
        150_000,
    );
    test_world::next_tx(&mut world, test_values::admin());
    let half_c = oracle_profile::exact_half_at(149_100);
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &absorb_c,
        &half_c,
        150_000,
    );
    test_world::next_tx(&mut world, test_values::admin());
    let half_d = oracle_profile::exact_half_at(149_200);
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &absorb_d,
        &half_d,
        150_000,
    );
    test_world::next_tx(&mut world, test_values::bob());
    let absorb_account = account_setup::create_funded_account(
        &mut world,
        &resources,
        ABSORPTION_DEPOSIT,
    );
    test_world::next_tx(&mut world, test_values::bob());
    let mut wrapper = account_setup::take_account(&world, &absorb_account);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &absorb_b);
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
        ABSORPTION_QUANTITY,
        test_values::leverage_one_x(),
        ABSORPTION_ALL_IN_COST,
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
    test_world::next_tx(&mut world, test_values::bob());
    let mut wrapper = account_setup::take_account(&world, &absorb_account);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &absorb_c);
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
        ABSORPTION_QUANTITY,
        test_values::leverage_one_x(),
        ABSORPTION_ALL_IN_COST,
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
    test_world::next_tx(&mut world, test_values::bob());
    let mut wrapper = account_setup::take_account(&world, &absorb_account);
    let root = test_world::take_accumulator_root(&world);
    let mut market = market_setup::take_market(&world, &absorb_d);
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
        ABSORPTION_QUANTITY,
        test_values::leverage_one_x(),
        ABSORPTION_ALL_IN_COST,
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

    // Re-mark every absorption surface inside the range (P = 1), settle the
    // churn market at its exact print, and sweep it: the cut exceeds idle, so
    // the remainder carries in pending_protocol_profit.
    test_world::clock_mut(&mut resources).set_for_testing(test_values::expiry_ms());
    test_world::next_tx(&mut world, test_values::admin());
    let remark_b = oracle_profile::new(
        oracle_profile::spot_prices(DEEP_REMARK_SPOT, DEEP_REMARK_SPOT, DEEP_REMARK_SPOT),
        oracle_profile::svi_params(1, false, 0, 1_000_000, 0, false, 0, false),
        179_000,
    );
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &absorb_b,
        &remark_b,
        test_values::expiry_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let remark_c = oracle_profile::new(
        oracle_profile::spot_prices(DEEP_REMARK_SPOT, DEEP_REMARK_SPOT, DEEP_REMARK_SPOT),
        oracle_profile::svi_params(1, false, 0, 1_000_000, 0, false, 0, false),
        179_100,
    );
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &absorb_c,
        &remark_c,
        test_values::expiry_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let remark_d = oracle_profile::new(
        oracle_profile::spot_prices(DEEP_REMARK_SPOT, DEEP_REMARK_SPOT, DEEP_REMARK_SPOT),
        oracle_profile::svi_params(1, false, 0, 1_000_000, 0, false, 0, false),
        179_200,
    );
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &absorb_d,
        &remark_d,
        test_values::expiry_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let mut market = market_setup::take_market(&world, &churn_market);
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let mut pyth = oracle_setup::take_pyth(&world, &oracles);
    oracle_setup::seed_exact_pyth(
        &mut pyth,
        PROFIT_SETTLE_SPOT,
        test_values::expiry_ms(),
        test_values::expiry_ms(),
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
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut market = market_setup::take_market(&world, &churn_market);
    let config = test_world::take_config(&world);
    vault.rebalance_expiry_cash(&mut market, &config, test_world::clock(&resources));
    assert_eq!(vault.pending_protocol_profit(), CARRIED_PENDING);
    assert_eq!(vault.protocol_reserve_balance(), RESERVE_AT_CARRY);
    assert_eq!(vault.idle_balance(), 0);
    return_shared(config);
    return_shared(market);
    return_shared(vault);

    // Absorption market B settles as a loser and its sweep refills idle: the
    // realization drains B's own cut plus the full carry into the reserve.
    let b_expiry_ms = test_values::expiry_ms() + test_values::cadence_period_ms();
    test_world::clock_mut(&mut resources).set_for_testing(b_expiry_ms);
    test_world::next_tx(&mut world, test_values::admin());
    let mut market = market_setup::take_market(&world, &absorb_b);
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let mut pyth = oracle_setup::take_pyth(&world, &oracles);
    oracle_setup::seed_exact_pyth(&mut pyth, PROFIT_SETTLE_SPOT, b_expiry_ms, b_expiry_ms);
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
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut market = market_setup::take_market(&world, &absorb_b);
    let config = test_world::take_config(&world);
    vault.rebalance_expiry_cash(&mut market, &config, test_world::clock(&resources));
    assert_eq!(vault.pending_protocol_profit(), 0);
    assert_eq!(vault.protocol_reserve_balance(), RESERVE_AFTER_REALIZATION);
    assert_eq!(vault.idle_balance(), IDLE_AFTER_REALIZATION);
    return_shared(config);
    return_shared(market);
    return_shared(vault);
    test_world::finish(world, resources);
}
