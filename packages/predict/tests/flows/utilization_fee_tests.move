// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for the pool-wide utilization fee multiplier: the L/E ratio
/// frozen into each flush, the cache write onto `ProtocolConfig`, the settled-
/// market liability exclusion, and the rebalance-invariance of L/E.
#[test_only]
module deepbook_predict::utilization_fee_tests;

use deepbook_predict::{
    constants::min_supply_request as min_supply,
    flow_test_helpers as helpers,
    plp::PoolVault,
    protocol_config::ProtocolConfig,
    test_constants,
    vault_events
};
use fixed_math::math;
use std::unit_test::assert_eq;
use sui::{event, test_scenario::return_shared};

/// Peak multiplier used when a test wants the ramp armed (2× at full utilization).
const TWO_X: u64 = 2_000_000_000;
/// 1% supply fee so a fill's fee is observationally non-zero when the ramp fires.
const ONE_PERCENT: u64 = 10_000_000;
/// Account funding for the LP staging supply requests.
const LP_DEPOSIT: u64 = 1_000_000_000;
const NO_MIN_OUT: u64 = 0;

// === Defaults are an exact no-op on the flush path ===

/// Empty-pool flush at shipped defaults freezes the base rates unchanged and
/// writes utilization 0 / multiplier 1.0 into the cache.
#[test]
fun flush_at_defaults_is_utilization_noop_and_writes_cache() {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(min_supply!());

    flush_empty(&mut fx);

    let events = event::events_by_type<vault_events::FlushExecuted>();
    assert_eq!(events.length(), 1);
    let (supply_rate, withdraw_rate) = vault_events::flush_executed_fee_rates(&events[0]);
    assert_eq!(supply_rate, 0);
    assert_eq!(withdraw_rate, 2_000_000);
    let (utilization, multiplier, cached_ms) = vault_events::flush_executed_utilization(&events[0]);
    assert_eq!(utilization, 0);
    assert_eq!(multiplier, math::float_scaling!());

    fx.scenario_mut().next_tx(test_constants::admin());
    let config = fx.scenario_mut().take_shared<ProtocolConfig>();
    assert_eq!(config.cached_pool_utilization(), 0);
    assert_eq!(config.cached_pool_utilization_ms(), cached_ms);
    return_shared(config);

    fx.finish();
}

/// Two supply fills in one flush are charged at the same frozen (scaled) rate —
/// the multiplier is snapshotted once into the mark, not re-read per fill.
#[test]
fun two_fills_in_one_flush_share_the_frozen_scaled_rate() {
    let (mut fx, mut account) = setup_pool_with_lp();
    set_supply_fee(&mut fx, ONE_PERCENT);
    set_max_multiplier(&mut fx, TWO_X);
    // Empty pool: u = 0 → multiplier 1.0, so effective rate is the 1% base. The
    // freeze property does not need the ramp to fire; it needs one mark to price
    // every fill.
    queue_supply(&mut fx, &mut account, NO_MIN_OUT);
    queue_supply(&mut fx, &mut account, NO_MIN_OUT);

    flush_empty(&mut fx);

    let fills = event::events_by_type<vault_events::SupplyFilled>();
    assert_eq!(fills.length(), 2);
    // fee = ceil(10_000_000 * 1%) = 100_000 on each identical request.
    assert_eq!(vault_events::supply_filled_fee(&fills[0]), 100_000);
    assert_eq!(vault_events::supply_filled_fee(&fills[1]), 100_000);
    let events = event::events_by_type<vault_events::FlushExecuted>();
    let (supply_rate, _) = vault_events::flush_executed_fee_rates(&events[0]);
    assert_eq!(supply_rate, ONE_PERCENT);

    helpers::return_account_bundle(account);
    fx.finish();
}

// === Settled-market liability must not enter utilization ===

/// A settled winner still reports `settled_payout_liability` until redeem. If
/// `value_expiry` folded that into `total_liability` on the swept branch, u would
/// be positive and — with the ramp armed — the multiplier would rise. Pinning
/// both to the no-op values proves liability followed the same branch as NAV.
#[test]
fun settled_market_liability_does_not_enter_utilization() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.bootstrap_lock(min_supply!());

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(
        &mut market,
        settlement_inside_default_finite_range(),
    );
    assert_eq!(fx.try_settle_bundle(&mut market), true);
    // The bug's precondition: liability is still live on the settled market.
    assert_eq!(helpers::market(&market).payout_liability(), test_constants::mint_quantity());

    fx.set_utilization_max_multiplier_bundle(&mut market, TWO_X);

    let mut valuation = fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut valuation, &mut market);
    let _ = fx.finish_flush_bundle(valuation, &mut market, option::none(), option::none());

    // Liability was still non-zero after the sweep path ran — the market object
    // retains settled_payout_liability — but utilization must ignore it.
    assert_eq!(helpers::market(&market).payout_liability(), test_constants::mint_quantity());

    let events = event::events_by_type<vault_events::FlushExecuted>();
    assert_eq!(events.length(), 1);
    let (utilization, multiplier, _) = vault_events::flush_executed_utilization(&events[0]);
    assert_eq!(utilization, 0);
    assert_eq!(multiplier, math::float_scaling!());

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === Rebalance griefing regression ===

/// Permissionless `rebalance_expiry_cash` can move idle into expiry cash (and
/// vice versa). An idle-based utilization would rise under that grief; L/E is
/// invariant to it. After a rebalance that actually relocates cash, the flush's
/// reported utilization must still equal `liability / pool_nav` — not track the
/// idle share.
#[test]
fun rebalance_before_flush_does_not_change_utilization() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.bootstrap_lock(min_supply!());

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    fx.set_utilization_max_multiplier_bundle(&mut market, TWO_X);

    let liability = helpers::market(&market).payout_liability();
    assert!(liability > 0);
    let idle_before = helpers::vault(&market).idle_balance();
    let market_cash_before = helpers::market(&market).cash_balance();

    fx.rebalance_expiry_cash_bundle(&mut market);

    let idle_after = helpers::vault(&market).idle_balance();
    let market_cash_after = helpers::market(&market).cash_balance();
    // The grief vector must have fired: cash relocated between idle and the market.
    assert!(idle_before != idle_after || market_cash_before != market_cash_after);
    // Conservation: relocating cash does not create or destroy it.
    assert_eq!(idle_before + market_cash_before, idle_after + market_cash_after);

    let mut valuation = fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut valuation, &mut market);
    let pool_nav = fx.finish_flush_bundle(valuation, &mut market, option::none(), option::none());

    let events = event::events_by_type<vault_events::FlushExecuted>();
    let (utilization, _, _) = vault_events::flush_executed_utilization(&events[0]);
    let expected_u = math::mul_div_down(liability, math::float_scaling!(), pool_nav).min(
        math::float_scaling!(),
    );
    assert_eq!(utilization, expected_u);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === Live-market ramp wiring ===

/// With the ramp armed and a live mint pushing utilization above the threshold,
/// the flush freezes a multiplier strictly above 1.0 and writes that u into the
/// config cache.
#[test]
fun live_mint_above_threshold_raises_multiplier_and_caches_u() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.bootstrap_lock(min_supply!());

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    // Drop the threshold to 0 so any positive utilization fires the ramp.
    fx.set_utilization_threshold_bundle(&mut market, 0);
    fx.set_utilization_max_multiplier_bundle(&mut market, TWO_X);

    let liability = helpers::market(&market).payout_liability();
    assert!(liability > 0);

    let mut valuation = fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut valuation, &mut market);
    let pool_nav = fx.finish_flush_bundle(valuation, &mut market, option::none(), option::none());

    let events = event::events_by_type<vault_events::FlushExecuted>();
    let (utilization, multiplier, cached_ms) = vault_events::flush_executed_utilization(&events[0]);
    let expected_u = math::mul_div_down(liability, math::float_scaling!(), pool_nav).min(
        math::float_scaling!(),
    );
    assert_eq!(utilization, expected_u);
    assert!(multiplier > math::float_scaling!());
    // Hand check at threshold 0, max 2×: multiplier = 1 + u.
    assert_eq!(multiplier, math::float_scaling!() + expected_u);

    assert_eq!(helpers::config(&market).cached_pool_utilization(), utilization);
    assert_eq!(helpers::config(&market).cached_pool_utilization_ms(), cached_ms);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === Helpers ===

fun setup_pool_with_lp(): (helpers::Fixture, helpers::AccountBundle) {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(min_supply!());
    let trader = fx.create_funded_manager(LP_DEPOSIT);
    let account = fx.take_account_bundle(&trader);
    (fx, account)
}

fun queue_supply(
    fx: &mut helpers::Fixture,
    account: &mut helpers::AccountBundle,
    min_plp_out: u64,
) {
    fx.scenario_mut().next_tx(test_constants::alice());
    let config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    fx.request_supply_direct(&mut vault, &config, account, min_supply!(), min_plp_out);
    return_shared(vault);
    return_shared(config);
}

fun set_supply_fee(fx: &mut helpers::Fixture, rate: u64) {
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    fx.set_plp_supply_fee_rate(&mut config, rate);
    return_shared(config);
}

fun set_max_multiplier(fx: &mut helpers::Fixture, value: u64) {
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    fx.set_utilization_max_multiplier(&mut config, value);
    return_shared(config);
}

fun flush_empty(fx: &mut helpers::Fixture) {
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let val = fx.start_flush(&mut config, &vault);
    let _ = val.finish_flush(
        &mut vault,
        &mut config,
        option::none(),
        option::none(),
        fx.scenario_mut().ctx(),
    );
    return_shared(config);
    return_shared(vault);
}

fun settlement_inside_default_finite_range(): u64 {
    (helpers::strike_tick() + 1) * test_constants::default_tick_size()
}
