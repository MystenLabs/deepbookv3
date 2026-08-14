// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Sizing coverage for the budget-bias mint request (`mint_exact_amount` and the
/// budget-bias quote): the flow mints the largest lot-rounded quantity whose net
/// premium fits the budget, never charges past the budget, saturates at the lot
/// cap instead of aborting on oversized budgets (the DBU-566 regression), and
/// enforces `min_quantity` as the fill floor. Budgets and expected debits are
/// read from a quantity quote at the size in question rather than hardcoded: a
/// budget threshold IS the next lot's premium, and `pricing_exact_tests` owns
/// whether that premium is itself correct.
/// Not covered here: the one-lot-conservative probe edge at fractional leverage,
/// where the per-lot product rounds and the probe can diverge from the charge.
#[test_only]
module deepbook_predict::mint_exact_amount_tests;

use deepbook_predict::{
    constants,
    expiry_market::{Self, MintQuote},
    flow_test_helpers as helpers,
    strike_exposure,
    strike_exposure_config,
    test_constants
};
use dusdc::dusdc::DUSDC;
use std::unit_test::assert_eq;

/// 10_000 lots of 10_000 raw units, and the next lot up. Quantities are lot
/// arithmetic and independent of the price; every budget and debit below is
/// taken from a quantity quote at that size instead, because a budget threshold
/// is by definition "the premium of the next lot", not a number that can be
/// written down once. `pricing_exact_tests` owns whether the premium behind them
/// is right.
const TEN_THOUSAND_LOTS: u64 = 100_000_000;
const NEXT_LOT_QUANTITY: u64 = 100_010_000;
/// Lot-cap saturation quantity: max_quantity_lots (u32 max = 4_294_967_295)
/// * lot 10_000.
const LOT_CAP_QUANTITY: u64 = 42_949_672_950_000;

/// The anonymous 1x quantity quote at the fixture's at-the-money strike, the
/// reference every budget threshold and expected debit below is read from.
fun atm_quote(fx: &mut helpers::Fixture, market: &helpers::MarketBundle, quantity: u64): MintQuote {
    fx.quote_mint_bundle(
        market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        quantity,
    )
}

/// Every budget threshold and expected debit here flows through `atm_quote`, so
/// pinning its probability once against the independent reference keeps all of
/// them anchored to a verified price rather than to the contract's own output.
fun atm_quote_checked(
    fx: &mut helpers::Fixture,
    market: &helpers::MarketBundle,
    quantity: u64,
): MintQuote {
    let quote = atm_quote(fx, market, quantity);
    helpers::assert_atm_entry_probability(quote.entry_probability());
    quote
}

/// The largest budget that still sizes exactly `TEN_THOUSAND_LOTS`: one unit
/// below what the next lot up would cost.
fun budget_below_next_lot(fx: &mut helpers::Fixture, market: &helpers::MarketBundle): u64 {
    atm_quote_checked(fx, market, NEXT_LOT_QUANTITY).net_premium() - 1
}

#[test]
fun budget_mints_largest_fitting_quantity_and_debits_its_exact_cost() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // One unit below the 10_001-lot premium is the largest budget that still
    // sizes 10_000 lots. min_quantity equal to the expected fill pins sizing from
    // below (one lot fewer aborts on the fill floor) while the exact debit pins
    // it from above (one lot more would debit the next lot's total).
    let budget = atm_quote_checked(&mut fx, &market, NEXT_LOT_QUANTITY).net_premium() - 1;
    let expected_debit = atm_quote_checked(&mut fx, &market, TEN_THOUSAND_LOTS).all_in_cost();
    fx.mint_exact_amount_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        budget,
        TEN_THOUSAND_LOTS,
        std::u64::max_value!(),
    );

    assert_eq!(
        fx.account_balance_bundle<DUSDC>(&account),
        test_constants::mint_deposit() - expected_debit,
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

    // The smallest budget admitting the 10_001st lot is exactly that lot's premium.
    let next_lot = atm_quote_checked(&mut fx, &market, NEXT_LOT_QUANTITY);
    fx.mint_exact_amount_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        next_lot.net_premium(),
        NEXT_LOT_QUANTITY,
        std::u64::max_value!(),
    );

    assert_eq!(
        fx.account_balance_bundle<DUSDC>(&account),
        test_constants::mint_deposit() - next_lot.all_in_cost(),
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
    let budget = budget_below_next_lot(&mut fx, &market);
    fx.mint_exact_amount_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        budget,
        TEN_THOUSAND_LOTS + constants::position_lot_size!(),
        std::u64::max_value!(),
    );

    abort 999
}

#[test]
fun budget_mint_at_exact_all_in_cost_cap_succeeds() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // The all-in cap bounds premium plus fees, so the cap that exactly equals
    // this fill's total debit must pass — the passing side of the boundary the
    // next test pins from above.
    let budget = budget_below_next_lot(&mut fx, &market);
    let expected_debit = atm_quote_checked(&mut fx, &market, TEN_THOUSAND_LOTS).all_in_cost();
    fx.mint_exact_amount_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        budget,
        TEN_THOUSAND_LOTS,
        expected_debit,
    );

    assert_eq!(
        fx.account_balance_bundle<DUSDC>(&account),
        test_constants::mint_deposit() - expected_debit,
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = expiry_market::EMintCostAboveMax)]
fun budget_mint_one_unit_over_all_in_cost_cap_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // The budget itself still fits: this cap sits one raw unit below the fill's
    // total debit, so only the fee charged on top of the premium breaches it.
    let budget = budget_below_next_lot(&mut fx, &market);
    let expected_debit = atm_quote_checked(&mut fx, &market, TEN_THOUSAND_LOTS).all_in_cost();
    fx.mint_exact_amount_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        budget,
        TEN_THOUSAND_LOTS,
        expected_debit - 1,
    );

    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EMintCostCapRequired)]
fun budget_mint_without_an_all_in_cost_cap_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // Zero is not "uncapped": the budget mint has no disabling value, so it
    // aborts on the missing cap rather than on the breached one.
    let budget = budget_below_next_lot(&mut fx, &market);
    fx.mint_exact_amount_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        budget,
        TEN_THOUSAND_LOTS,
        0,
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
    );

    assert_eq!(quote.quantity(), LOT_CAP_QUANTITY);
    assert_eq!(
        quote.net_premium(),
        atm_quote_checked(&mut fx, &market, LOT_CAP_QUANTITY).net_premium(),
    );

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun account_quote_caps_the_budget_to_the_account_balance() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let market = fx.take_market_bundle(expiry_id);
    let account = fx.take_account_bundle(&trader);

    // A u64-max budget is capped to the deposit: the fill is the largest lot
    // multiple the balance can pay for, so its premium fits the deposit and one
    // more lot does not — the same sizing a mint would perform.
    let quote = fx.quote_mint_for_account_amount_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        std::u64::max_value!(),
        constants::position_lot_size!(),
    );

    assert!(quote.net_premium() <= test_constants::mint_deposit());
    let one_more_lot = quote.quantity() + constants::position_lot_size!();
    assert!(
        atm_quote_checked(&mut fx, &market, one_more_lot).net_premium() > test_constants::mint_deposit(),
    );

    helpers::return_account_bundle(account);
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

    let budget = budget_below_next_lot(&mut fx, &market);
    let budget_quote = fx.quote_mint_amount_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        budget,
        TEN_THOUSAND_LOTS,
    );
    let quantity_quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        TEN_THOUSAND_LOTS,
    );

    assert_eq!(budget_quote.quantity(), TEN_THOUSAND_LOTS);
    assert_eq!(budget_quote.net_premium(), quantity_quote.net_premium());
    assert_eq!(budget_quote.all_in_cost(), quantity_quote.all_in_cost());
    assert_eq!(budget_quote.entry_probability(), quantity_quote.entry_probability());

    helpers::return_market_bundle(market);
    fx.finish();
}
