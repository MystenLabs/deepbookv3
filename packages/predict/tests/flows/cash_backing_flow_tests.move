// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// S1/S2 expiry-cash sheet: asserts the exact (cash_balance, payout_liability)
/// pair after EVERY cash-mutating LIVE operation of a two-sided
/// book on the far expiry — mint, mint, partial live redeem. Pins that mint
/// premium AND fee land in expiry cash, and that disjoint live liability is
/// the max settlement floor plus the default gap buffer. Terminal settlement
/// coverage lives in `settlement_flow_tests`.
#[test_only]
module deepbook_predict::cash_backing_flow_tests;

use deepbook_predict::{constants, flow_test_helpers as helpers, test_constants};
use dusdc::dusdc::DUSDC;
use fixed_math::math::float_scaling as float;
use std::unit_test::assert_eq;

/// Both mints sit exactly at the money (forward == min_strike) and the second
/// prices the complement range through the UP(neg_inf) = 1.0 sentinel. Each
/// premium is read from that order's own quote rather than written down, since
/// this file owns the cash sheet and `pricing_exact_tests` owns the price.
/// Second order: DOWN complement (-inf, min_strike], quantity 2e9.
const DOWN_QUANTITY: u64 = 2_000_000_000;
/// Fees floor at min_fee = 5e6 per 1e9 of quantity (fixture base_fee = 1 makes
/// the raw Bernoulli fee round to 0; the default ramp multiplier is exactly 1.0).
const MINT1_FEE: u64 = 5_000_000;
const MINT2_FEE: u64 = 10_000_000;
/// Partial live close of half of order 1 at the unchanged ATM mark. The payout is
/// measured from the manager's balance and cross-checked against expiry cash:
/// the close moves value between the two sheets, it never creates or destroys.
const HALF_CLOSE: u64 = 500_000_000;

#[test]
fun cash_sheet_exact_after_every_flow() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // --- Baseline: the fixture seeded the fresh expiry with cash while pool
    // funding is absent.
    let seeded_cash = test_constants::default_seeded_expiry_cash();
    let deposit = test_constants::default_manager_deposit();
    helpers::check_market_cash_bundle(&market, helpers::expected_market_cash(seeded_cash, 0));
    fx.check_manager_bundle(&account, helpers::expected_manager_state(deposit));

    // --- Mint 1: ATM UP range (min_strike, +inf], quantity 1e9. Premium and
    // fee both land in expiry cash; the order contributes its full quantity
    // to payout backing.
    let quote1 = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    helpers::assert_atm_entry_probability(quote1.entry_probability());
    let mint1_principal = quote1.premium();
    let order1 = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    helpers::check_market_cash_bundle(
        &market,
        helpers::expected_market_cash(
            seeded_cash + mint1_principal + MINT1_FEE,
            test_constants::mint_quantity(),
        ),
    );
    fx.check_manager_bundle(
        &account,
        helpers::expected_manager_state(deposit - mint1_principal - MINT1_FEE),
    );

    // --- Mint 2: DOWN complement (-inf, min_strike], quantity 2e9.
    // The two ranges are disjoint: M = max(1e9, 2e9) = 2e9, Σ = 3e9,
    // gap = 1e9, default buffer = 250e6, reserve = 2.25e9.
    let quote2 = fx.quote_mint_bundle(
        &market,
        constants::neg_inf!(),
        helpers::strike_tick(),
        DOWN_QUANTITY,
    );
    // The complement is exact: both sides are differences of the same UP(K), so
    // the two probabilities sum to 1e9 with no approximation of their own.
    helpers::assert_atm_complement_entry_probability(quote2.entry_probability());
    assert_eq!(quote1.entry_probability() + quote2.entry_probability(), float!());
    let mint2_principal = quote2.premium();
    let order2 = fx.mint_bundle(
        &mut market,
        &mut account,
        constants::neg_inf!(),
        helpers::strike_tick(),
        DOWN_QUANTITY,
    );
    let cash_after_mints =
        seeded_cash
        + mint1_principal
        + MINT1_FEE
        + mint2_principal
        + MINT2_FEE;
    helpers::check_market_cash_bundle(
        &market,
        helpers::expected_market_cash(
            cash_after_mints,
            // λ_default = 0.25, so the gap buffer is mint_quantity / 4.
            DOWN_QUANTITY + test_constants::mint_quantity() / 4,
        ),
    );
    let balance_after_mints = deposit - mint1_principal - MINT1_FEE - mint2_principal - MINT2_FEE;
    fx.check_manager_bundle(&account, helpers::expected_manager_state(balance_after_mints));

    // --- Partial live close of half of order 1 at the unchanged ATM quote.
    // Cash pays only the net redeem (the fee is withheld in expiry cash and
    // grows the rebate basis); cancel-and-replace leaves M = 2e9 and gap =
    // surviving UP backing 0.5e9, so default reserve = 2.125e9. The
    // replacement keeps the position count at 2.
    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    let replacement = fx.redeem_live_bundle(
        &mut market,
        &mut account,
        order1,
        HALF_CLOSE,
    );
    let order1b = replacement.destroy_some();
    let close_net_payout = fx.account_balance_bundle<DUSDC>(&account) - balance_after_mints;
    let cash_after_close = cash_after_mints - close_net_payout;
    // λ_default = 0.25, so the gap buffer is HALF_CLOSE / 4.
    let liability_after_close = DOWN_QUANTITY + HALF_CLOSE / 4;
    helpers::check_market_cash_bundle(
        &market,
        helpers::expected_market_cash(cash_after_close, liability_after_close),
    );
    let balance_after_close = balance_after_mints + close_net_payout;
    fx.check_manager_bundle(&account, helpers::expected_manager_state(balance_after_close));
    assert!(helpers::has_position_bundle(&account, expiry_id, order1b));
    assert!(helpers::has_position_bundle(&account, expiry_id, order2));

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}
