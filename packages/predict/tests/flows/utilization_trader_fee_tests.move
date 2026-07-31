// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for the trade-path utilization fee multiplier: mint and redeem
/// read the flush-cached `L/E` from `ProtocolConfig`, compose it after the expiry
/// ramp, and respect the staleness decay policy.
#[test_only]
module deepbook_predict::utilization_trader_fee_tests;

use deepbook_predict::{
    constants::{min_supply_request as min_supply, pos_inf_tick},
    flow_test_helpers as helpers,
    order_events,
    test_constants
};
use dusdc::dusdc::DUSDC;
use fixed_math::math;
use std::unit_test::assert_eq;
use sui::event;

/// Fixture floors base_fee to 1, so the ATM `mint_quantity()` (1e9) fee binds at
/// min_fee (0.005) × quantity = 5_000_000 when the utilization multiplier is 1.0.
const BASE_TRADING_FEE: u64 = 5_000_000;
/// Same fee at utilization multiplier 2.0 (mul_down).
const SURCHARGED_TRADING_FEE: u64 = 10_000_000;
const TWO_X: u64 = 2_000_000_000;

// === Defaults are an exact no-op on the trade path ===

#[test]
fun mint_quote_at_defaults_is_utilization_noop() {
    let (mut fx, expiry_id, _trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let market = fx.take_market_bundle(expiry_id);

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    assert_eq!(quote.trading_fee(), BASE_TRADING_FEE);
    // Cache never written on a fresh deployment.
    assert!(!helpers::config(&market).utilization_cache_written());

    helpers::return_market_bundle(market);
    fx.finish();
}

// === Mint and redeem both surcharge when the cache is above threshold ===

#[test]
fun mint_and_redeem_surcharge_when_cache_is_hot() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.bootstrap_lock(min_supply!());

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // Arm the ramp: any positive u → multiplier > 1; at u = 1.0 → exactly 2×.
    fx.set_utilization_max_multiplier_bundle(&mut market, TWO_X);
    fx.set_utilization_threshold_bundle(&mut market, 0);

    // Seed a hot cache at full utilization without depending on a particular
    // live L/E — the trade path must read whatever the flush last wrote.
    helpers::write_pool_utilization_cache_bundle(
        &mut market,
        math::float_scaling!(),
        fx.clock().timestamp_ms(),
    );

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    assert_eq!(quote.trading_fee(), SURCHARGED_TRADING_FEE);

    let order_id = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );

    // Advance one ms so mint/redeem same-timestamp guard passes, then re-seed
    // the oracle for the redeem's live pricer.
    let redeem_ms = fx.clock().timestamp_ms() + 1;
    fx.set_clock_for_testing(redeem_ms);
    fx.prepare_live_oracle_bundle_at(
        &mut market,
        test_constants::default_live_price(),
        redeem_ms,
    );

    // Refresh the cache timestamp so the redeem still sees a fresh 2×.
    helpers::write_pool_utilization_cache_bundle(&mut market, math::float_scaling!(), redeem_ms);

    let balance_before = fx.account_balance_bundle<DUSDC>(&account);
    let (_closed_id, _replacement) = fx.redeem_bundle(
        &mut market,
        &mut account,
        order_id,
        test_constants::mint_quantity(),
    );
    let balance_after = fx.account_balance_bundle<DUSDC>(&account);

    // Redeem withholds the surcharged fee from the payout. Read it off the
    // event so the assertion is the fee the path charged, not a balance
    // reconstruction that could hide a different withhold.
    let events = event::events_by_type<order_events::LiveOrderRedeemed>();
    assert_eq!(events.length(), 1);
    assert_eq!(order_events::live_order_redeemed_trading_fee(&events[0]), SURCHARGED_TRADING_FEE);
    assert!(balance_after > balance_before); // received a net payout

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// An LP exit that raises pool-wide `L/E` is written into the cache at the next
/// flush; the following trade must see the higher surcharge. Modelled here by
/// writing a higher cached `u` between two quotes — the same write path the
/// flush uses — because a unit-test accumulator root cannot complete a withdraw
/// fill into account custody.
#[test]
fun higher_cached_utilization_raises_the_next_mint_fee() {
    let (mut fx, expiry_id, _trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);

    fx.set_utilization_max_multiplier_bundle(&mut market, TWO_X);
    fx.set_utilization_threshold_bundle(&mut market, 0);

    // Post-mint flush: moderate utilization (u = 0.5 → mult = 1.5).
    helpers::write_pool_utilization_cache_bundle(
        &mut market,
        500_000_000,
        fx.clock().timestamp_ms(),
    );
    let mid = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    // 5e6 × 1.5 = 7.5e6.
    assert_eq!(mid.trading_fee(), 7_500_000);

    // Post-withdrawal flush: full utilization (u = 1.0 → mult = 2.0).
    helpers::write_pool_utilization_cache_bundle(
        &mut market,
        math::float_scaling!(),
        fx.clock().timestamp_ms(),
    );
    let after_exit = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    assert_eq!(after_exit.trading_fee(), SURCHARGED_TRADING_FEE);
    assert!(after_exit.trading_fee() > mid.trading_fee());

    helpers::return_market_bundle(market);
    fx.finish();
}

/// Past the fresh+decay window the trade path decays to multiplier 1.0 rather
/// than trusting a crisis number indefinitely.
#[test]
fun stale_cache_decays_mint_fee_to_base() {
    let (mut fx, expiry_id, _trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);

    fx.set_utilization_max_multiplier_bundle(&mut market, TWO_X);
    fx.set_utilization_threshold_bundle(&mut market, 0);
    // Tight windows so the test can advance the clock without fighting oracle
    // freshness: 1s fresh, 1s decay.
    fx.set_utilization_cache_fresh_ms_bundle(&mut market, 1_000);
    fx.set_utilization_cache_decay_ms_bundle(&mut market, 1_000);

    let written_at = fx.clock().timestamp_ms();
    helpers::write_pool_utilization_cache_bundle(&mut market, math::float_scaling!(), written_at);

    // Hot: 2×.
    assert_eq!(
        fx
            .quote_mint_bundle(
                &market,
                helpers::strike_tick(),
                pos_inf_tick!(),
                test_constants::mint_quantity(),
                test_constants::leverage_one_x(),
            )
            .trading_fee(),
        SURCHARGED_TRADING_FEE,
    );

    // Fully decayed: advance past fresh+decay, re-seed oracle for the new clock.
    let stale_ms = written_at + 2_000;
    fx.set_clock_for_testing(stale_ms);
    fx.prepare_live_oracle_bundle_at(
        &mut market,
        test_constants::default_live_price(),
        stale_ms,
    );
    assert_eq!(
        fx
            .quote_mint_bundle(
                &market,
                helpers::strike_tick(),
                pos_inf_tick!(),
                test_constants::mint_quantity(),
                test_constants::leverage_one_x(),
            )
            .trading_fee(),
        BASE_TRADING_FEE,
    );

    helpers::return_market_bundle(market);
    fx.finish();
}
