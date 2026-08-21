// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end custody coverage for the probability-weighted inventory-skew
/// charge. Unit tests pin the statistic's arithmetic; these tests drive the real
/// quote, account withdrawal, escrow, close, and settlement paths, and assert the
/// state-function property through custody: cycles that return the book to a
/// state return the escrow to that state's potential, exactly.
#[test_only]
module deepbook_predict::inventory_skew_flow_tests;

use deepbook_predict::{constants, flow_test_helpers as helpers, test_constants};
use dusdc::dusdc::DUSDC;
use std::unit_test::assert_eq;

const IMPACT_SCALE: u64 = 10_000_000_000;
/// 0.5%: the max admissible skew rate, and within twice the ordinary fee floor.
const SKEW_RATE: u64 = 5_000_000;
const ORDINARY_MIN_FEE: u64 = 5_000_000;

#[test]
fun a_concentrating_mint_pays_a_charge_into_the_skew_escrow() {
    let (mut fx, mut market, mut account, _trader) = setup_skewed_market(SKEW_RATE);

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    let skew_charge = quote.skew_charge();
    assert!(skew_charge > 0);
    assert_eq!(quote.skew_rebate(), 0);
    assert_eq!(
        quote.all_in_cost(),
        quote.premium()
            + (quote.trading_fee() - quote.fee_incentive_subsidy())
            + quote.builder_fee()
            + quote.penalty_fee()
            + skew_charge,
    );

    let balance_before = fx.account_balance_bundle<DUSDC>(&account);
    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );

    assert_eq!(fx.account_balance_bundle<DUSDC>(&account), balance_before - quote.all_in_cost());
    assert_eq!(helpers::market(&market).skew_reserve(), skew_charge);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// The balancing leg of a complete set is rebated at mint, and because a complete
/// set is a flat book — the same payout at every settlement price — the rebate
/// returns the first leg's charge exactly and the escrow lands on zero.
#[test]
fun completing_a_set_rebates_the_first_legs_charge_exactly() {
    let (mut fx, mut market, mut account, _trader) = setup_skewed_market(SKEW_RATE);

    let first = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        first.all_in_cost(),
        std::u64::max_value!(),
    );
    assert_eq!(helpers::market(&market).skew_reserve(), first.skew_charge());

    let second = fx.quote_mint_bundle(
        &market,
        0,
        helpers::strike_tick(),
        test_constants::mint_quantity(),
    );
    assert_eq!(second.skew_charge(), 0);
    assert_eq!(second.skew_rebate(), first.skew_charge());
    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        0,
        helpers::strike_tick(),
        test_constants::mint_quantity(),
        second.all_in_cost(),
        std::u64::max_value!(),
    );

    assert_eq!(helpers::market(&market).skew_reserve(), 0);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// Mint then full close, with the oracle moved between them. The weights froze at
/// the first mint, so the close reads exactly what the open wrote and the rebate
/// returns the charge to the unit — a live measure would re-weight the book and
/// break the refund. The rebate rides the close payout, so the account receives
/// the gross order value plus the charge back, minus the ordinary fee.
#[test]
fun a_round_trip_refunds_the_charge_exactly_across_an_oracle_move() {
    let (mut fx, mut market, mut account, _trader) = setup_skewed_market(SKEW_RATE);

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    let order_id = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );
    assert_eq!(helpers::market(&market).skew_reserve(), quote.skew_charge());

    // Reprice one millisecond later at a moved spot: live prices change, frozen
    // weights do not.
    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price() + 1_000_000);
    let gross = fx.live_order_value_bundle(&market, order_id);
    let balance_before_close = fx.account_balance_bundle<DUSDC>(&account);
    fx.redeem_live_bundle(
        &mut market,
        &mut account,
        order_id,
        test_constants::mint_quantity(),
    );

    assert_eq!(
        fx.account_balance_bundle<DUSDC>(&account),
        balance_before_close + gross + quote.skew_charge() - ORDINARY_MIN_FEE,
    );
    assert_eq!(helpers::market(&market).skew_reserve(), 0);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// Closing one leg of a complete set unbalances a flat book, so the close is
/// charged rather than rebated: the amount is withheld from the payout into the
/// escrow. Closing the surviving leg then flattens the empty book and takes the
/// escrow back out, exactly.
#[test]
fun a_close_that_unbalances_the_book_is_charged_and_the_drain_refunds_it() {
    let (mut fx, mut market, mut account, _trader) = setup_skewed_market(SKEW_RATE);

    let first_order = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        std::u64::max_value!(),
        std::u64::max_value!(),
    );
    let second_order = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        0,
        helpers::strike_tick(),
        test_constants::mint_quantity(),
        std::u64::max_value!(),
        std::u64::max_value!(),
    );
    // A complete set is flat: the two legs' adjustments cancelled through custody.
    assert_eq!(helpers::market(&market).skew_reserve(), 0);

    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    let first_gross = fx.live_order_value_bundle(&market, first_order);
    let balance_before = fx.account_balance_bundle<DUSDC>(&account);
    fx.redeem_live_bundle(
        &mut market,
        &mut account,
        first_order,
        test_constants::mint_quantity(),
    );
    let close_charge = helpers::market(&market).skew_reserve();
    assert!(close_charge > 0);
    assert_eq!(
        fx.account_balance_bundle<DUSDC>(&account),
        balance_before + first_gross - ORDINARY_MIN_FEE - close_charge,
    );
    helpers::assert_market_backed_bundle(&market);

    // Draining the surviving leg flattens an emptying book: rebated in full.
    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.redeem_live_bundle(
        &mut market,
        &mut account,
        second_order,
        test_constants::mint_quantity(),
    );
    assert_eq!(helpers::market(&market).skew_reserve(), 0);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// Settlement releases the residual escrow into ordinary expiry cash: no close
/// can earn a rebate afterwards, so nothing is owed against it.
#[test]
fun settlement_releases_the_residual_skew_escrow() {
    let (mut fx, mut market, mut account, _trader) = setup_skewed_market(SKEW_RATE);

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );
    let cash_before = helpers::market(&market).cash_balance();
    assert_eq!(helpers::market(&market).skew_reserve(), quote.skew_charge());

    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(&mut market, test_constants::default_live_price());
    assert_eq!(fx.try_settle_bundle(&mut market), true);
    assert_eq!(helpers::market(&market).skew_reserve(), 0);
    // Release moves nothing: the collected charge simply stops being earmarked.
    assert_eq!(helpers::market(&market).cash_balance(), cash_before);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// A zero snapshotted rate is fully inert: no charge, no rebate, no escrow, and
/// no frozen measure — the quote path never evaluates a weight.
#[test]
fun a_zero_rate_market_charges_and_freezes_nothing() {
    let (mut fx, mut market, mut account, _trader) = setup_skewed_market(0);

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    assert_eq!(quote.skew_charge(), 0);
    assert_eq!(quote.skew_rebate(), 0);

    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );
    assert_eq!(helpers::market(&market).skew_reserve(), 0);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

fun setup_skewed_market(
    rate: u64,
): (helpers::Fixture, helpers::MarketBundle, helpers::AccountBundle, helpers::Trader) {
    let mut fx = helpers::setup_market_default();
    fx.set_template_min_fee(ORDINARY_MIN_FEE);
    fx.set_template_inventory_skew_rate(rate);
    fx.set_default_cadence_allocation(IMPACT_SCALE, constants::expiry_cash_floor!());
    let expiry_id = fx.create_expiry(test_constants::short_expiry_ms());
    // Four mint deposits: the complete-set cases fund both legs twice over.
    let trader = fx.create_funded_manager(8 * test_constants::mint_deposit());
    let mut market = fx.take_market_bundle(expiry_id);
    let account = fx.take_account_bundle(&trader);

    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.seed_market_cash(
        helpers::market_mut(&mut market),
        test_constants::default_seeded_expiry_cash(),
    );
    (fx, market, account, trader)
}
