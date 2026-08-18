// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Live-solvency boundary for a thin finite-range order minted exactly at the
/// money and then partially closed. Pins the closed-slice liability change,
/// account replacement, and market-cash conservation with backing intact.
#[test_only]
module deepbook_predict::live_solvency_boundary_tests;

use deepbook_predict::{flow_test_helpers as helpers, order, test_constants};
use dusdc::dusdc::DUSDC;
use std::unit_test::assert_eq;

/// Per-trade fee floors at `min_fee`: the fixture floors base_fee to 1, so the
/// raw Bernoulli fee mul(1, sqrt(0.5 * 0.5)) rounds to 0 and the floor binds.
/// The default expiry-fee ramp multiplier is exactly 1.0 (ramp disabled).
const MINT_MIN_FEE: u64 = 5_000_000;
/// The order is the first admitted finite range above min_strike and the live
/// forward == min_strike, so it is exactly at the money and the upper tail clamps
/// to 0 (|d2| ≈ 315σ, far past the Φ clamp at 8σ). The premium is read from the
/// quote; the close payout is measured from the manager's
/// balance and cross-checked against the market's cash, which is what solvency
/// preservation actually asserts. `pricing_exact_tests` owns the price itself.
/// Half the minted quantity (a whole number of 10_000-unit lots).
const HALF_CLOSE: u64 = 500_000_000;

#[test]
fun finite_range_partial_close_preserves_live_solvency() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // --- Baseline: the fixture seeded the fresh expiry with cash while pool
    // funding is absent; nothing owed, nothing spent.
    let seeded_cash = test_constants::default_seeded_expiry_cash();
    helpers::check_market_cash_bundle(&market, helpers::expected_market_cash(seeded_cash, 0));
    fx.check_manager_bundle(
        &account,
        helpers::expected_manager_state(test_constants::mint_deposit()),
    );
    // --- Mint one order on the first admitted finite range above min_strike,
    // exactly at the money. Premium + fee land in expiry cash; the order
    // contributes its full quantity to live payout backing.
    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
    );
    helpers::assert_atm_entry_probability_short_expiry(quote.entry_probability());
    let premium = quote.premium();
    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
    );
    helpers::check_market_cash_bundle(
        &market,
        helpers::expected_market_cash(
            seeded_cash + premium + MINT_MIN_FEE,
            test_constants::mint_quantity(),
        ),
    );
    fx.check_manager_bundle(
        &account,
        helpers::expected_manager_state(test_constants::mint_deposit() - premium - MINT_MIN_FEE),
    );
    assert!(helpers::has_position_bundle(&account, expiry_id, order_id));

    // --- Partial live close of exactly half at the unchanged ATM mark. The
    // close removes the closed slice from payout backing and replaces the
    // account position with the surviving half.
    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    let balance_before_close = fx.account_balance_bundle<DUSDC>(&account);
    let cash_before_close = helpers::market(&market).cash_balance();
    let replacement = fx.redeem_live_bundle(
        &mut market,
        &mut account,
        order_id,
        HALF_CLOSE,
    );
    let survivor_id = replacement.destroy_some();
    let survivor = order::from_order_id(survivor_id);
    assert_eq!(survivor.quantity(), HALF_CLOSE);
    // Solvency: every unit that left expiry cash landed in the manager's balance.
    // The close moves value between the two sheets, it never creates or destroys.
    let close_net_payout = fx.account_balance_bundle<DUSDC>(&account) - balance_before_close;
    let cash_after_close = cash_before_close - close_net_payout;
    assert_eq!(cash_after_close, seeded_cash + premium + MINT_MIN_FEE - close_net_payout);
    helpers::check_market_cash_bundle(
        &market,
        helpers::expected_market_cash(cash_after_close, HALF_CLOSE),
    );
    fx.check_manager_bundle(
        &account,
        helpers::expected_manager_state(balance_before_close + close_net_payout),
    );
    assert!(!helpers::has_position_bundle(&account, expiry_id, order_id));
    assert!(helpers::has_position_bundle(&account, expiry_id, survivor_id));

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}
