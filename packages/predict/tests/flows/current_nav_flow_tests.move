// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Differential coverage for the exact single-expiry live NAV reader
/// (`expiry_market::current_nav`). Every test builds protocol state through the
/// production mint flow, then asserts `current_nav` exactly equals an INDEPENDENT
/// per-order reference (`reference_nav`): `free_cash - Σ qty·P(range)`, computed
/// straight from each order's atoms and `pricing::range_price`. The reference
/// reuses NONE of `walk_linear` / `live_marked_liability` / `current_nav` /
/// `expiry_cash::free_cash`, so it is a genuine oracle (unit-tests rule 1): it
/// sums per order, while the contract nets per boundary.
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
    test_constants
};
use fixed_math::math::{Self, float_scaling as float};
use std::unit_test::assert_eq;

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
    fx.scenario_mut().next_tx(test_constants::alice());
    let market = fx.take_market_bundle(expiry_id);

    // No orders: NAV is exactly the seeded free cash (no fees yet -> rebate 0).
    let nav = fx.current_nav_bundle(&market);
    assert_eq!(nav, test_constants::default_seeded_expiry_cash());
    check_nav(&mut fx, &market, vector[], float!());

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun single_atm_up_order() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
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

    check_nav(&mut fx, &market, vector[id], float!());

    helpers::return_account_bundle(account);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun single_atm_down_order_anchored_at_neg_inf() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
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
    check_nav(&mut fx, &market, vector[id], float!());

    helpers::return_account_bundle(account);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun two_atm_orders_same_strike_collapse_to_one_node() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
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
    check_nav(&mut fx, &market, vector[id1, id2], float!());

    helpers::return_account_bundle(account);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = strike_payout_tree::ENonMonotonePrice)]
fun current_nav_rejects_non_monotone_active_book_surface() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

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
    fx.set_clock_for_testing(test_constants::now_ms() + 1);
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
        test_constants::now_ms() + 1,
    );

    fx.current_nav_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === Helpers ===

/// Assert `current_nav` equals the independent per-order reference and the market
/// stays solvent (S1 backing). The contract builds its own pricer internally; we
/// build an identical one (the oracle is frozen within the tx) for the reference.
fun check_nav(
    fx: &mut helpers::Fixture,
    market: &helpers::MarketBundle,
    order_ids: vector<u256>,
    _index_now: u64,
) {
    let pricer = fx.load_pricer_bundle(market);
    let nav = fx.current_nav_bundle(market);
    let expiry_market = helpers::market(market);
    assert_eq!(nav, reference_nav(expiry_market, &pricer, &order_ids));
    helpers::assert_market_backed(expiry_market);
}

/// Independent NAV oracle (unit-tests rule 1): `free_cash - Σ contribution` per
/// open order, using only order atoms and `pricing::range_price`. Every order is
/// worth `qty·P(range)` live, so each contributes exactly that. The order's ticks
/// are converted to raw strikes through the same `range_codec` boundary the
/// contract uses (the codec is the pricing boundary, not the NAV math under test).
fun reference_nav(market: &ExpiryMarket, pricer: &Pricer, order_ids: &vector<u256>): u64 {
    let mut liability = 0;
    order_ids.do_ref!(|id| {
        let decoded = order::from_order_id(*id);
        let lower = range_codec::strike_from_tick(decoded.lower_tick(), market.tick_size());
        let higher = range_codec::strike_from_tick(decoded.higher_tick(), market.tick_size());
        liability =
            liability + math::mul_down(pricer.range_price(lower, higher), decoded.quantity());
    });
    let free_cash = market.cash_balance().saturating_sub(market.rebate_reserve());
    free_cash.saturating_sub(liability)
}
