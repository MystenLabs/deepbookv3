// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registered policy pins: the flush executes at any exact NAV mark — zero,
/// far below, and far above PLP/DUSDC parity — with no mark-level circuit
/// breaker; with empty queues the flush completes and reports the exact mark.
/// The zero mark also pins the `lp_pool_value` floor-at-zero clamp direction.
#[test_only]
module deepbook_predict::scope_flow__intent_policy__pool_valuation_tests;

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

// --- zero-NAV pin: cash == required backing at mint, then the mark moves to
// P = 1 so free cash exactly equals the marked liability. ---
// Bootstrap 0.4975 * quantity: at exact-half the all-in mint cost is
// (0.5 + 0.005) * Q while required backing is Q + 0.5 * fee, so cash lands
// exactly on the backing floor and NAV reads exactly zero at P = 1.
const ZERO_NAV_BOOTSTRAP: u64 = 19_900_000;
const ZERO_NAV_QUANTITY: u64 = 40_000_000; // 4000 lots of 10_000
const ZERO_NAV_ALL_IN_COST: u64 = 20_200_000; // premium 20e6 + fee 200e3
const ZERO_NAV_DEPOSIT: u64 = 20_200_000;
// Spot strictly inside (90, 100] with near-zero variance prices the range at
// exactly 1: both boundary digitals clamp (1e9 above 90e9, 0 above 100e9).
const IN_RANGE_SPOT: u64 = 95_000_000_000;
const REMARK_SOURCE_TIMESTAMP_MS: u64 = 119_500; // after the exact-half row
const LOWER_TICK: u64 = 90;

// --- low-price pin: a settled trader win drains the pool to dust. ---
// Bootstrap 10 DUSDC (the minimum) funds the market; the trader mints 20e6 at
// exact-half (all-in 10.1e6) and wins at settlement, so the in-flush sweep
// returns only cash - (payout + rebate reserve) = 20.1e6 - 20.05e6.
const LOW_PRICE_BOOTSTRAP: u64 = 10_000_000;
const LOW_PRICE_QUANTITY: u64 = 20_000_000;
const LOW_PRICE_ALL_IN_COST: u64 = 10_100_000; // premium 10e6 + fee 100e3
const LOW_PRICE_DEPOSIT: u64 = 10_100_000;
// pool_nav 50_000 over total supply 10_000_000: PLP price 0.005, far below
// the 1/100 executable band edge.
const LOW_PRICE_POOL_NAV: u64 = 50_000;

// --- high-price pin: compounding trader losses over minimum bootstrap. ---
// Eight churn rounds in one market: each round the trader mints (90, 100] at
// the exact-half mark (all-in 0.505 * Q), the surface re-marks with both
// boundaries deep in the money (range value 0), and the live redeem closes
// worthless — the pool keeps the full premium plus fee. Quantities double each
// round at the backing cap (cash >= quantity + rebate reserve holds at every
// mint, tightest at the last: 2_585.5e6 >= 2_572.75e6).
const HIGH_PRICE_BOOTSTRAP: u64 = 10_000_000;
// Total quantity 5_100e6: premiums 2_550e6 + fees 25.5e6 land in expiry cash;
// rebate reserve holds 12.75e6, so the settled sweep returns 2_572.75e6; the
// terminal profit 2_562.75e6 realizes a 0.4 protocol cut of 1_025.1e6.
const HIGH_PRICE_DEPOSIT: u64 = 2_575_500_000; // sum of all-in mint costs
const OUT_OF_RANGE_SPOT: u64 = 200_000_000_000; // both boundaries deep ITM
const CHURN_ROUND_MS: u64 = 2_000; // mint and redeem need distinct timestamps
// idle 2_572.75e6 - protocol cut 1_025.1e6: PLP price 154.765 over 10e6 supply.
const HIGH_PRICE_POOL_NAV: u64 = 1_547_650_000;

#[test]
fun finish_flush_with_zero_pool_nav_and_empty_queues_succeeds() {
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
        ZERO_NAV_BOOTSTRAP,
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
        ZERO_NAV_DEPOSIT,
    );

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
        ZERO_NAV_QUANTITY,
        test_values::leverage_one_x(),
        ZERO_NAV_ALL_IN_COST,
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

    // Re-mark the surface inside the range: the position values at P = 1, so
    // marked liability exactly consumes free cash and pool NAV reads zero.
    test_world::next_tx(&mut world, test_values::admin());
    let remark = oracle_profile::new(
        oracle_profile::spot_prices(IN_RANGE_SPOT, IN_RANGE_SPOT, IN_RANGE_SPOT),
        oracle_profile::svi_params(1, false, 0, 1_000_000, 0, false, 0, false),
        REMARK_SOURCE_TIMESTAMP_MS,
    );
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &market_handle,
        &remark,
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

    // The flush completes at the exact zero mark: no mark-level guard fires,
    // nothing drains, supply and idle are untouched.
    assert_eq!(pool_nav, 0);
    assert_eq!(vault.plp_total_supply(), ZERO_NAV_BOOTSTRAP);
    assert_eq!(vault.idle_balance(), 0);
    assert_eq!(vault.supply_requests_pending(), 0);
    assert_eq!(vault.withdraw_requests_pending(), 0);

    oracle_setup::return_feeds(feeds);
    return_shared(market);
    return_shared(vault);
    return_shared(config);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
}

#[test]
fun finish_flush_with_low_plp_price_and_empty_queues_succeeds() {
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
        LOW_PRICE_BOOTSTRAP,
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
        LOW_PRICE_DEPOSIT,
    );

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
        LOW_PRICE_QUANTITY,
        test_values::leverage_one_x(),
        LOW_PRICE_ALL_IN_COST,
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

    // The trader's range wins at settlement, so the pool keeps only dust.
    let expiry_ms = test_values::expiry_ms();
    test_world::clock_mut(&mut resources).set_for_testing(expiry_ms);
    test_world::next_tx(&mut world, test_values::admin());
    oracle_setup::settle_market_at_exact_print(
        &mut world,
        &resources,
        &oracles,
        &market_handle,
        IN_RANGE_SPOT,
    );

    // The flush sweeps the settled market in-flush and freezes the dust mark.
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

    // PLP price 0.005 (50_000 over 10e6 supply), far below the 1/100 band
    // edge: the flush still completes and reports the exact mark.
    assert_eq!(pool_nav, LOW_PRICE_POOL_NAV);
    assert_eq!(vault.plp_total_supply(), LOW_PRICE_BOOTSTRAP);
    assert_eq!(vault.idle_balance(), LOW_PRICE_POOL_NAV);
    assert_eq!(vault.supply_requests_pending(), 0);
    assert_eq!(vault.withdraw_requests_pending(), 0);
    assert!(vault.active_expiry_markets().is_empty());

    oracle_setup::return_feeds(feeds);
    return_shared(market);
    return_shared(vault);
    return_shared(config);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
}

#[test]
fun finish_flush_with_high_plp_price_and_empty_queues_succeeds() {
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
        HIGH_PRICE_BOOTSTRAP,
    );
    test_world::next_tx(&mut world, test_values::alice());
    let account_handle = account_setup::create_funded_account(
        &mut world,
        &resources,
        HIGH_PRICE_DEPOSIT,
    );

    // Churn rounds: quantities double at the backing cap; each round's premium
    // and fee stay in expiry cash when the position closes worthless.
    let round_quantities = vector[
        20_000_000u64,
        40_000_000,
        80_000_000,
        160_000_000,
        320_000_000,
        640_000_000,
        1_280_000_000,
        2_560_000_000,
    ];
    let mut round = 0;
    while (round < round_quantities.length()) {
        let quantity = round_quantities[round];
        let mint_ms = test_values::now_ms() + round * CHURN_ROUND_MS;
        // Mark at exact-half and mint (90, 100] for 0.505 * quantity all-in.
        test_world::clock_mut(&mut resources).set_for_testing(mint_ms);
        test_world::next_tx(&mut world, test_values::admin());
        let half = oracle_profile::exact_half_at(mint_ms - 500);
        oracle_setup::seed_market_surface(
            &mut world,
            &resources,
            &oracles,
            &market_handle,
            &half,
            mint_ms,
        );
        test_world::next_tx(&mut world, test_values::alice());
        let mut wrapper = account_setup::take_account(&world, &account_handle);
        let root = test_world::take_accumulator_root(&world);
        let mut market = market_setup::take_market(&world, &market_handle);
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

        // Re-mark with both boundaries deep in the money and close worthless.
        test_world::clock_mut(&mut resources).set_for_testing(mint_ms + 1_000);
        test_world::next_tx(&mut world, test_values::admin());
        let collapse = oracle_profile::new(
            oracle_profile::spot_prices(
                OUT_OF_RANGE_SPOT,
                OUT_OF_RANGE_SPOT,
                OUT_OF_RANGE_SPOT,
            ),
            oracle_profile::svi_params(1, false, 0, 1_000_000, 0, false, 0, false),
            mint_ms + 500,
        );
        oracle_setup::seed_market_surface(
            &mut world,
            &resources,
            &oracles,
            &market_handle,
            &collapse,
            mint_ms + 1_000,
        );
        test_world::next_tx(&mut world, test_values::alice());
        let mut wrapper = account_setup::take_account(&world, &account_handle);
        let root = test_world::take_accumulator_root(&world);
        let mut market = market_setup::take_market(&world, &market_handle);
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

    // The trader spent the full deposit on premiums and fees, all retained by
    // the market.
    test_world::next_tx(&mut world, test_values::alice());
    let wrapper = account_setup::take_account(&world, &account_handle);
    let root = test_world::take_accumulator_root(&world);
    assert_eq!(wrapper.load_account().balance<DUSDC>(&root, test_world::clock(&resources)), 0);
    return_shared(root);
    return_shared(wrapper);

    // Settle the now-empty book and record the terminal state.
    let expiry_ms = test_values::expiry_ms();
    test_world::clock_mut(&mut resources).set_for_testing(expiry_ms);
    test_world::next_tx(&mut world, test_values::admin());
    oracle_setup::settle_market_at_exact_print(
        &mut world,
        &resources,
        &oracles,
        &market_handle,
        OUT_OF_RANGE_SPOT,
    );

    // Standalone settled sweep: premium and fees return to idle and the
    // terminal profit's protocol cut is realized before the flush.
    test_world::next_tx(&mut world, test_values::admin());
    let mut vault = test_world::take_vault(&world);
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    vault.rebalance_expiry_cash(&mut market, &config, test_world::clock(&resources));
    assert!(vault.active_expiry_markets().is_empty());
    return_shared(config);
    return_shared(market);
    return_shared(vault);

    // The flush over the empty active set freezes the appreciated mark.
    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut registry = test_world::take_registry(&world);
    let mut config = test_world::take_config(&world);
    let mut vault = test_world::take_vault(&world);
    let lifecycle_cap = registry.mint_lifecycle_cap(
        &config,
        &admin_cap,
        test_world::ctx(&mut world),
    );
    let proof = registry.generate_lifecycle_proof(&lifecycle_cap);
    let valuation = plp::start_pool_valuation(&mut config, &vault, proof);
    let pool_nav = plp::finish_flush(
        valuation,
        &mut vault,
        &mut config,
        option::none(),
        option::none(),
        test_world::ctx(&mut world),
    );
    lifecycle_cap.destroy();

    // PLP price 154.765 (1.54765e9 over 10e6 supply), far above the 100x band
    // edge: the flush still completes and reports the exact mark.
    assert_eq!(pool_nav, HIGH_PRICE_POOL_NAV);
    assert_eq!(vault.plp_total_supply(), HIGH_PRICE_BOOTSTRAP);
    assert_eq!(vault.idle_balance(), HIGH_PRICE_POOL_NAV);
    assert_eq!(vault.supply_requests_pending(), 0);
    assert_eq!(vault.withdraw_requests_pending(), 0);

    return_shared(vault);
    return_shared(config);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
}
