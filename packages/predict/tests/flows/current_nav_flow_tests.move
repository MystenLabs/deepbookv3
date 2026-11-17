// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Differential coverage for a single expiry's exact NAV, read through the flush
/// that marks it (`plp::value_expiry` over `expiry_market::snapshot_nav`). Every
/// test builds protocol state through the mint flow, runs a one-market flush, and
/// asserts the flush's active-market NAV exactly equals an INDEPENDENT per-order
/// reference (`reference_nav`): `free_cash - Σ qty·P(range)`, computed straight
/// from each order's atoms and `pricing::range_price` at the flush's own pricer.
/// The reference reuses none of the tree walk or the NAV shape, so it is a
/// genuine oracle (unit-tests rule 1): it sums per order, while the contract nets
/// per boundary.
///
/// All fixtures anchor every finite boundary at `strike_tick` (whose raw strike ==
/// the seeded forward, so `UP(strike) = Φ(0) = 0.5` exactly with the SVI wing
/// rounded to zero) and use even quantities, so the boundary-aggregated linear term
/// equals the per-order sum bit-for-bit and `assert_eq` holds with no rounding
/// dust. Away from that anchoring the two can differ by boundary rounding, which is
/// why the fixtures pin it rather than relying on the identity in general.
#[test_only]
module deepbook_predict::current_nav_flow_tests;

use deepbook_predict::{
    constants,
    expiry_market::ExpiryMarket,
    flow_test_helpers as helpers,
    order,
    pricing::{Self, Pricer},
    range_codec,
    strike_payout_tree,
    test_constants,
    vault_events
};
use fixed_math::math::{Self, float_scaling as float};
use std::unit_test::assert_eq;
use sui::event;

/// The pool's genesis lock, which every flush requires.
const POOL_SEED: u64 = 10_000_000;
/// ATM up range, quantity 2e9: priced 0.5 -> 1e9 liability.
const ATM_QUANTITY: u64 = 2_000_000_000;
/// Second same-strike up order, quantity 4e9.
const SECOND_SAME_STRIKE_QUANTITY: u64 = 4_000_000_000;
const NON_MONOTONE_A_MAGNITUDE: u64 = 1;
const NON_MONOTONE_LOWER_TICK: u64 = 90;
const NON_MONOTONE_HIGHER_TICK: u64 = 100;

#[test]
fun empty_live_market_values_at_free_cash() {
    let (mut fx, expiry_id, _trader) = helpers::setup_everything();
    // A flush needs a bootstrapped pool.
    fx.bootstrap_lock(POOL_SEED);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);

    // No orders: NAV is exactly the seeded free cash (no fees yet -> rebate 0).
    let nav = flush_nav(&mut fx, &mut market);
    assert_eq!(nav, test_constants::default_seeded_expiry_cash());

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun single_atm_up_order() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    // A flush needs a bootstrapped pool.
    fx.bootstrap_lock(POOL_SEED);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        ATM_QUANTITY,
    );

    check_nav(&mut fx, &mut market, vector[id]);

    helpers::return_account_bundle(account);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun single_atm_down_order_anchored_at_neg_inf() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    // A flush needs a bootstrapped pool.
    fx.bootstrap_lock(POOL_SEED);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let id = fx.mint_bundle(
        &mut market,
        &mut account,
        constants::neg_inf!(),
        helpers::strike_tick(),
        ATM_QUANTITY,
    );

    // The (-inf, strike] range exercises the `tree.base` (P(-inf) = 1) anchor.
    check_nav(&mut fx, &mut market, vector[id]);

    helpers::return_account_bundle(account);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun two_atm_orders_same_strike_collapse_to_one_node() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    // A flush needs a bootstrapped pool.
    fx.bootstrap_lock(POOL_SEED);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let id1 = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        ATM_QUANTITY,
    );
    let id2 = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        SECOND_SAME_STRIKE_QUANTITY,
    );

    // Both up orders share the strike start boundary -> one tree node priced
    // once at P(strike); the aggregate quantity equals the per-order sum.
    check_nav(&mut fx, &mut market, vector[id1, id2]);

    helpers::return_account_bundle(account);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = strike_payout_tree::ENonMonotonePrice)]
fun the_flush_rejects_a_non_monotone_active_book_surface() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    // A flush needs a bootstrapped pool.
    fx.bootstrap_lock(POOL_SEED);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    deepbook_predict::range_test_helpers::prepare_range(&mut fx, &mut market);

    // First create a normal order with live boundaries at ticks 90 and 100. Then
    // replace the oracle surface with a synthetic bad surface where the higher
    // strike has a higher UP price than the lower strike. NAV should reject that
    // instead of using a price order that can overstate pool value.
    fx.mint_bundle(
        &mut market,
        &mut account,
        NON_MONOTONE_LOWER_TICK,
        NON_MONOTONE_HIGHER_TICK,
        ATM_QUANTITY,
    );
    // These SVI values are intentionally extreme: tiny positive `a`, max `b`,
    // min `sigma`, and `rho = -1`. Together they make the model report a higher
    // chance of finishing above tick 100 than above tick 90, which is impossible
    // for a valid UP price curve.
    fx.set_clock_for_testing(test_constants::now_ms() + 2);
    fx.seed_bs_surface_with_svi_bundle(
        &mut market,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        NON_MONOTONE_A_MAGNITUDE,
        false,
        test_constants::pricing_max_svi_input(),
        test_constants::pricing_min_svi_sigma(),
        float!(),
        true,
        0,
        false,
        test_constants::now_ms() + 2,
    );

    flush_nav(&mut fx, &mut market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === Helpers ===

/// Assert the flush's NAV for the market equals the independent per-order
/// reference at the flush's own pricer, and the market stays solvent (S1 backing).
fun check_nav(
    fx: &mut helpers::Fixture,
    market: &mut helpers::MarketBundle,
    order_ids: vector<u256>,
) {
    let pricer = flush_pricer(fx, market);
    let nav = flush_nav(fx, market);
    let expiry_market = helpers::market(market);
    assert_eq!(nav, reference_nav(expiry_market, &pricer, &order_ids));
    helpers::assert_market_backed(expiry_market);
}

/// The pricer the flush builds for the market at the current clock: the feeds'
/// latest Pyth spot and Block Scholes inputs, all signed at the clock
/// (`helpers::flush_data_at`), through `pricing::snap_v2` and `pricing::pricer_at`.
fun flush_pricer(fx: &mut helpers::Fixture, market: &helpers::MarketBundle): Pricer {
    let now = fx.clock().timestamp_ms();
    let (price, vol) = helpers::flush_data_at(market, now);
    let price = price.destroy_some();
    let expiry_market = helpers::market(market);
    let mut market_uid = object::new(fx.scenario_mut().ctx());
    let snapshot = pricing::snap_v2(
        vol.borrow(),
        test_constants::pyth_feed_id(),
        &mut market_uid,
    );
    let pricer = pricing::pricer_at(
        &snapshot,
        &market_uid,
        price.spot(),
        price.generation_us() / 1000,
        now,
        expiry_market.id(),
        expiry_market.expiry(),
    );
    market_uid.delete();
    pricer.destroy_some()
}

/// The market's NAV through a one-market flush at the current clock: the snapshot
/// stage marks it from the feeds' rows signed at the clock, `value_expiry` values
/// it, and the flush operator finishes. Returns the flush's active-market NAV.
fun flush_nav(fx: &mut helpers::Fixture, market: &mut helpers::MarketBundle): u64 {
    fx.scenario_mut().next_tx(test_constants::admin());
    let stage = fx.start_flush_unsnapshotted(market);
    let now = fx.clock().timestamp_ms();
    let (price, vol) = helpers::flush_data_at(market, now);
    fx.snapshot_v2_bundle(&stage, market, price, vol);
    helpers::seal_snapshot_bundle(stage, market);
    fx.value_expiry_bundle(market);
    fx.finish_flush_bundle(market);
    let events = event::events_by_type<vault_events::FlushExecuted>();
    vault_events::flush_executed_active_market_nav(&events[events.length() - 1])
}

/// Independent NAV oracle (unit-tests rule 1): `free_cash - Σ contribution` per
/// open order, using only order atoms and `pricing::range_price`. Every order is
/// worth `qty·P(range)` live, so each contributes exactly that. The order's ticks
/// are converted to raw strikes through the same `range_codec` boundary the
/// contract uses (the codec is the pricing boundary, not the NAV math under test).
fun reference_nav(market: &ExpiryMarket, pricer: &Pricer, order_ids: &vector<u256>): u64 {
    let mut liability = 0;
    order_ids.do_ref!(|id| {
        let decoded = order::from_id(*id);
        let lower = range_codec::strike_from_tick(decoded.lower_tick(), market.tick_size());
        let higher = range_codec::strike_from_tick(decoded.higher_tick(), market.tick_size());
        liability =
            liability + math::mul_down(pricer.range_price(lower, higher).probability(), decoded.quantity());
    });
    let free_cash = market.cash_balance();
    free_cash.saturating_sub(liability)
}
