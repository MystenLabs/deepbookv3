// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for the liquidate-during-flush valuation lane (DBU-605 /
/// P-10): `plp::value_expiry` marks each live market through
/// `current_nav_with_liquidations`, which knocks out every active leveraged
/// order at or below its liquidation threshold at the valuation prices in the
/// same pass. Pins: (a) the flush mark excludes killed orders and removes them
/// from the liquidation book and payout tree with `OrderLiquidated` emitted;
/// (b) a zero-liquidatable book marks bit-identical to the read-only
/// `current_nav`; (c) the holder of a flush-killed order clears it through the
/// zero-payout Liquidated close arm; (d) 1x orders are never killed.
///
/// Markets are pool-funded through the production bootstrap + rebalance path
/// (the `pool_valuation_flow_tests` scaffolding). The band fixture leans on the
/// degenerate default SVI: at-the-money digitals price at 0.5 exactly, and a
/// forward 0.00223% under the strike lands the repriced digital near 0.24 —
/// inside the 1.8x order's liquidation band `(floor, floor/0.85]` in
/// gross terms, `(200_000_000, 235_294_117]` — asserted in-test before the
/// flush so a fixture drift fails loudly at setup. NAV references are
/// independent per-order sums over order atoms and `range_price`
/// (the `current_nav_flow_tests::reference_nav` pattern).
#[test_only]
module deepbook_predict::liquidate_during_flush_tests;

use deepbook_predict::{
    constants,
    flow_test_helpers as helpers,
    order,
    order_events::{LiquidatedOrderRedeemed, LiveOrderRedeemed, OrderLiquidated},
    range_codec::{Self, Strike},
    test_constants
};
use dusdc::dusdc::DUSDC;
use fixed_math::math;
use std::unit_test::assert_eq;
use sui::event;

/// Pool idle locked at genesis; covers each market's initial cash funding.
const IDLE_SEED: u64 = 100_000_000_000;
/// 1.8x on an exact-ATM (p = 0.5) mint: entry = mul(0.5, 9e8) = 450_000_000,
/// net_premium = div(450e6, 1.8) = 250_000_000 exact, so the static floor is
/// F = 450e6 - 250e6 = 200_000_000 exact.
const BAND_LEVERAGE: u64 = 1_800_000_000;
const BAND_QUANTITY: u64 = 900_000_000;
const BAND_FLOOR: u64 = 200_000_000;
/// 2x on the same ATM mint shape: F = 500_000_000; at the unchanged 0.5 price
/// its gross (1e9) sits far above the threshold div(5e8, 0.85) = 588_235_294.
const LEVERAGE_TWO_X: u64 = 2_000_000_000;
const TWO_X_QUANTITY: u64 = 2_000_000_000;
const ONE_X_QUANTITY: u64 = 2_000_000_000;
/// Live reserve after the three test-A mints: identical `(strike, +inf]`
/// ranges make point payouts coincide (gap 0), so the reserve is the exact sum
/// of net payouts `2*(9e8 - 2e8) + 2e9`.
const PRE_FLUSH_RESERVE: u64 = 3_400_000_000;
/// Forward 0.00223% below the 100e9 strike. Under the degenerate default SVI
/// the total variance collapses to a = 1e-9, so d2 = -ln(K/F)/sqrt(w)
/// ~= -22_300e-9 / 3.1622e-5 ~= -0.705 and the UP digital reprices to
/// ~0.2403: gross ~= 216e6, comfortably inside the band (see module doc).
const BAND_FORWARD: u64 = 99_997_770_000;
/// 1% below the strike: far outside the degenerate surface's narrow smooth
/// zone (|d2| ~ 315), so the UP digital saturates to exactly 0.
const DROPPED_FORWARD: u64 = 99_000_000_000;
const REPRICE_MS: u64 = 121_000;
/// Strictly after the setup's 119_000 seed and within every freshness window
/// of the REPRICE_MS clock.
const REPRICE_SOURCE_TS: u64 = 119_500;

// === (a) + (d): the flush kills band orders, excludes them from the mark ===

#[test]
fun flush_kills_band_orders_excludes_them_from_mark_and_holder_clears_at_zero() {
    let (mut fx, e, trader) = setup_pool_funded_market();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(e);
    let mut account = fx.take_account_bundle(&trader);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.rebalance_expiry_cash_bundle(&mut market);

    let band_a = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        BAND_QUANTITY,
        BAND_LEVERAGE,
    );
    let band_b = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        BAND_QUANTITY,
        BAND_LEVERAGE,
    );
    let survivor_1x = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        ONE_X_QUANTITY,
        test_constants::leverage_one_x(),
    );
    assert_eq!(order::from_order_id(band_a).floor_shares(), BAND_FLOOR);
    assert_eq!(helpers::market(&market).payout_liability(), PRE_FLUSH_RESERVE);

    // Reprice into the liquidation band and validate the band membership from
    // the order atoms before flushing (fixture sanity, loud on drift): gross
    // must sit in (floor, floor/ltv].
    fx.set_clock_for_testing(REPRICE_MS);
    fx.prepare_live_oracle_bundle_at(&mut market, BAND_FORWARD, REPRICE_SOURCE_TS);
    let pricer = fx.load_pricer_bundle(&market);
    let band_price = pricer.range_price(raw(helpers::strike_tick()), raw_pos_inf());
    let band_gross = math::mul(band_price, BAND_QUANTITY);
    let threshold = math::div(BAND_FLOOR, helpers::market(&market).liquidation_ltv());
    assert!(band_gross > BAND_FLOOR && band_gross <= threshold);
    assert_eq!(fx.order_value_bundle(&market, band_a), 0);

    let mut val = fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut val, &mut market);
    fx.finish_flush_bundle(val, &mut market, option::none(), option::none());

    // Both band orders were killed inside the valuation pass: events emitted,
    // liquidation book no longer targets them, and the payout tree retains
    // only the 1x survivor's terms (reserve drops to its full quantity).
    assert_eq!(event::events_by_type<OrderLiquidated>().length(), 2);
    assert!(!fx.liquidate_order_bundle(&mut market, band_a));
    assert!(!fx.liquidate_order_bundle(&mut market, band_b));
    assert_eq!(helpers::market(&market).payout_liability(), ONE_X_QUANTITY);
    assert!(helpers::has_position_bundle(&account, e, survivor_1x));
    helpers::assert_market_backed_bundle(&market);

    // The mark excludes the killed claims and prices exactly the survivor:
    // oracle state is unchanged since the flush, so this public read equals
    // the NAV `value_expiry` folded, and the independent per-order reference
    // is free cash minus the 1x order's range value.
    let expiry_market = helpers::market(&market);
    let free_cash = expiry_market.cash_balance() - expiry_market.rebate_reserve();
    let survivor_liability = math::mul(band_price, ONE_X_QUANTITY);
    assert_eq!(fx.current_nav_bundle(&market), free_cash - survivor_liability);

    // (d) The holder clears a flush-killed order through the Liquidated close
    // arm: full close, zero payout, no fee, position removed.
    let balance_before = fx.account_balance_bundle<DUSDC>(&account);
    let (closed_id, replacement) = fx.redeem_bundle(
        &mut market,
        &mut account,
        band_a,
        BAND_QUANTITY,
    );
    assert_eq!(closed_id, band_a);
    assert!(replacement.is_none());
    assert_eq!(fx.account_balance_bundle<DUSDC>(&account), balance_before);
    assert!(!helpers::has_position_bundle(&account, e, band_a));
    assert_eq!(event::events_by_type<LiquidatedOrderRedeemed>().length(), 1);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === (b): zero-liquidatable book marks bit-identical to current_nav ===

#[test]
fun zero_liquidatable_valuation_is_bit_identical_to_current_nav() {
    let (mut fx, e, trader) = setup_pool_funded_market();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(e);
    let mut account = fx.take_account_bundle(&trader);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.rebalance_expiry_cash_bundle(&mut market);

    let up = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        ONE_X_QUANTITY,
        test_constants::leverage_one_x(),
    );
    let down = fx.mint_bundle(
        &mut market,
        &mut account,
        constants::neg_inf!(),
        helpers::strike_tick(),
        ONE_X_QUANTITY,
        test_constants::leverage_one_x(),
    );
    let leveraged = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        TWO_X_QUANTITY,
        LEVERAGE_TWO_X,
    );

    // Same pricer, same book state: the liquidating valuation must return the
    // read-only mark's exact bits and mutate nothing when nothing is killable.
    let pricer = fx.load_pricer_bundle(&market);
    let reserve_before = helpers::market(&market).payout_liability();
    let nav_read_only = helpers::market(&market).current_nav(&pricer);
    let nav_liquidating = helpers::market_mut(&mut market).current_nav_with_liquidations(
        &pricer,
        fx.clock(),
    );
    assert_eq!(nav_liquidating, nav_read_only);
    assert!(event::events_by_type<OrderLiquidated>().is_empty());
    assert_eq!(helpers::market(&market).payout_liability(), reserve_before);
    assert_eq!(helpers::market(&market).current_nav(&pricer), nav_read_only);
    // The healthy leveraged order is still live at holder value (a liquidated
    // or liquidatable order would read zero).
    assert!(fx.order_value_bundle(&market, leveraged) > 0);
    assert!(helpers::has_position_bundle(&account, e, up));
    assert!(helpers::has_position_bundle(&account, e, down));

    // The production flush over the same zero-liquidatable book completes and
    // kills nothing.
    let mut val = fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut val, &mut market);
    fx.finish_flush_bundle(val, &mut market, option::none(), option::none());
    assert!(event::events_by_type<OrderLiquidated>().is_empty());
    assert_eq!(helpers::market(&market).payout_liability(), reserve_before);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === (e): 1x orders are never killed by the flush ===

#[test]
fun flush_never_liquidates_worthless_one_x_orders() {
    let (mut fx, e, trader) = setup_pool_funded_market();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(e);
    let mut account = fx.take_account_bundle(&trader);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.rebalance_expiry_cash_bundle(&mut market);

    let one_x = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        ONE_X_QUANTITY,
        test_constants::leverage_one_x(),
    );

    // Drop the digital to exactly zero: the order is worthless, which is
    // precisely the state a floor-less 1x order must ride out un-liquidated.
    fx.set_clock_for_testing(REPRICE_MS);
    fx.prepare_live_oracle_bundle_at(&mut market, DROPPED_FORWARD, REPRICE_SOURCE_TS);
    let pricer = fx.load_pricer_bundle(&market);
    assert_eq!(pricer.range_price(raw(helpers::strike_tick()), raw_pos_inf()), 0);

    let mut val = fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut val, &mut market);
    fx.finish_flush_bundle(val, &mut market, option::none(), option::none());

    // No kill: no event, and the order's full terms still back the reserve.
    assert!(event::events_by_type<OrderLiquidated>().is_empty());
    assert_eq!(helpers::market(&market).payout_liability(), ONE_X_QUANTITY);
    helpers::assert_market_backed_bundle(&market);

    // The holder exits through the LIVE close arm (worthless, not knocked
    // out): zero proceeds at the zero price, position cleared.
    let balance_before = fx.account_balance_bundle<DUSDC>(&account);
    let (closed_id, replacement) = fx.redeem_bundle(
        &mut market,
        &mut account,
        one_x,
        ONE_X_QUANTITY,
    );
    assert_eq!(closed_id, one_x);
    assert!(replacement.is_none());
    assert_eq!(fx.account_balance_bundle<DUSDC>(&account), balance_before);
    assert!(!helpers::has_position_bundle(&account, e, one_x));
    assert_eq!(event::events_by_type<LiveOrderRedeemed>().length(), 1);
    assert!(event::events_by_type<LiquidatedOrderRedeemed>().is_empty());

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === Helpers ===

/// Production pool bring-up: default market fixture, funded trader, genesis
/// idle lock, and one registered live expiry (funded to the cash floor by the
/// caller's rebalance so mint premiums flow through pool accounting).
fun setup_pool_funded_market(): (helpers::Fixture, ID, helpers::Trader) {
    let mut fx = helpers::setup_market_default();
    let trader = fx.create_funded_manager(test_constants::default_manager_deposit());
    fx.bootstrap_lock(IDLE_SEED);
    let e = fx.create_expiry(test_constants::default_expiry_ms());
    (fx, e, trader)
}

/// Strike for a tick under the default `tick_size` (the fixture market's).
fun raw(tick: u64): Strike {
    range_codec::strike_from_tick(tick, test_constants::default_tick_size())
}

fun raw_pos_inf(): Strike {
    range_codec::strike_from_tick(constants::pos_inf_tick!(), test_constants::default_tick_size())
}
