// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Sizing coverage for the budget-bias mint request (`mint_exact_amount` and the
/// budget-bias quote): the flow mints the largest lot-rounded quantity whose net
/// premium fits the budget, never charges past the budget, saturates at the lot
/// cap instead of aborting on oversized budgets (the DBU-566 regression), and
/// enforces `min_quantity` as the fill floor. Every expected value is
/// hand-derived from the fixture's exact at-the-money probability Φ(0) = 0.5.
/// Not covered here: the one-lot-conservative probe edge at fractional leverage
/// with a rounding-lossy probability — at p = 0.5 every per-lot product is
/// exact, so the probe and the charge coincide at all these points.
#[test_only]
module deepbook_predict::mint_exact_amount_tests;

use deepbook_predict::{constants, flow_test_helpers as helpers, strike_exposure, test_constants};
use dusdc::dusdc::DUSDC;
use std::unit_test::assert_eq;

/// Largest budget that still sizes exactly 10_000 lots (the ATM 1x one-lot
/// premium is p * lot = 0.5 * 10_000 = 5_000): one unit below the 10_001-lot
/// premium 10_001 * 5_000 = 50_005_000.
const BUDGET_BELOW_NEXT_LOT: u64 = 50_004_999;
/// 10_000 lots of 10_000 raw units.
const TEN_THOUSAND_LOTS: u64 = 100_000_000;
/// Exact debit for the 10_000-lot 1x mint, same derivation as
/// `quote_mint_tests::VARIANCE_SEED_COST`: net premium 0.5 * 1e8 = 50_000_000
/// plus min fee 0.005 * 1e8 = 500_000.
const TEN_THOUSAND_LOTS_DEBIT: u64 = 50_500_000;
/// The smallest budget admitting the 10_001st lot, and its exact debit:
/// net premium 50_005_000 plus min fee 0.005 * 100_010_000 = 500_050.
const BUDGET_AT_NEXT_LOT: u64 = 50_005_000;
const NEXT_LOT_QUANTITY: u64 = 100_010_000;
const NEXT_LOT_DEBIT: u64 = 50_505_050;
/// Lot-cap saturation: quantity = max_quantity_lots (u32 max = 4_294_967_295)
/// * lot 10_000, and its net premium at p = 0.5, 1x leverage.
const LOT_CAP_QUANTITY: u64 = 42_949_672_950_000;
const LOT_CAP_NET_PREMIUM: u64 = 21_474_836_475_000;

#[test]
fun budget_mints_largest_fitting_quantity_and_debits_its_exact_cost() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // min_quantity equal to the expected fill pins sizing from below (one lot
    // fewer aborts on the fill floor) while the exact debit pins it from above
    // (one lot more would debit 50_505_050).
    fx.mint_exact_amount_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        BUDGET_BELOW_NEXT_LOT,
        TEN_THOUSAND_LOTS,
        test_constants::leverage_one_x(),
    );

    assert_eq!(
        fx.account_balance_bundle<DUSDC>(&account),
        test_constants::mint_deposit() - TEN_THOUSAND_LOTS_DEBIT,
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun budget_at_next_lot_premium_mints_the_next_lot() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.mint_exact_amount_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        BUDGET_AT_NEXT_LOT,
        NEXT_LOT_QUANTITY,
        test_constants::leverage_one_x(),
    );

    assert_eq!(
        fx.account_balance_bundle<DUSDC>(&account),
        test_constants::mint_deposit() - NEXT_LOT_DEBIT,
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = strike_exposure::EMintQuantityBelowMin)]
fun budget_fill_below_min_quantity_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // The budget sizes exactly 10_000 lots; a floor one lot higher must abort.
    fx.mint_exact_amount_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        BUDGET_BELOW_NEXT_LOT,
        TEN_THOUSAND_LOTS + constants::position_lot_size!(),
        test_constants::leverage_one_x(),
    );

    abort 999
}

#[test]
fun oversized_budget_saturates_at_the_lot_cap_without_aborting() {
    let (mut fx, expiry_id, _trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let market = fx.take_market_bundle(expiry_id);

    // The read-only quote has no balance cap, so a u64-max budget exercises the
    // former ENetPremiumBudgetTooHigh domain: sizing saturates at the lot cap
    // and quotes its exact premium instead of aborting.
    let quote = fx.quote_mint_amount_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        std::u64::max_value!(),
        LOT_CAP_QUANTITY,
        test_constants::leverage_one_x(),
    );

    assert_eq!(quote.net_premium(), LOT_CAP_NET_PREMIUM);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun budget_quote_matches_quantity_quote_for_the_sized_fill() {
    let (mut fx, expiry_id, _trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let market = fx.take_market_bundle(expiry_id);

    let budget_quote = fx.quote_mint_amount_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        BUDGET_BELOW_NEXT_LOT,
        TEN_THOUSAND_LOTS,
        test_constants::leverage_one_x(),
    );
    let quantity_quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        TEN_THOUSAND_LOTS,
        test_constants::leverage_one_x(),
    );

    assert_eq!(budget_quote.net_premium(), quantity_quote.net_premium());
    assert_eq!(budget_quote.all_in_cost(), quantity_quote.all_in_cost());
    assert_eq!(budget_quote.entry_probability(), quantity_quote.entry_probability());

    helpers::return_market_bundle(market);
    fx.finish();
}
