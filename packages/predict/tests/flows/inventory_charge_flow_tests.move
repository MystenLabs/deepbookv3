// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end coverage for the inventory charge. Unit tests pin the lattice's
/// arithmetic; these drive the real quote, account withdrawal, close, and
/// settlement paths, and pin the property the design exists for: the measure
/// re-anchors to the live forward, so a market whose spot has run far from where
/// it opened still prices inventory risk instead of falling silent.
#[test_only]
module deepbook_predict::inventory_charge_flow_tests;

use deepbook_predict::{constants, flow_test_helpers as helpers, test_constants};
use dusdc::dusdc::DUSDC;
use std::unit_test::assert_eq;

const EXPIRY_ALLOCATION: u64 = 10_000_000_000;
/// 0.5%, the maximum admissible rate, so the charges here are the largest the
/// mechanism can produce and the assertions are the tightest.
const INVENTORY_RATE: u64 = 5_000_000;
const ORDINARY_MIN_FEE: u64 = 5_000_000;

#[test]
fun a_concentrating_mint_pays_a_charge_into_expiry_cash() {
    let (mut fx, mut market, mut account, _trader) = setup_market(INVENTORY_RATE);

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    let charge = quote.inventory_charge();
    assert!(charge > 0);
    assert_eq!(
        quote.all_in_cost(),
        quote.premium()
            + (quote.trading_fee() - quote.fee_incentive_subsidy())
            + quote.builder_fee()
            + quote.penalty_fee()
            + charge,
    );

    let balance_before = fx.account_balance_bundle<DUSDC>(&account);
    let cash_before = helpers::market(&market).cash_balance();
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
    // The charge is ordinary expiry surplus, not an escrow: it lands in cash
    // alongside the premium and the fee.
    assert_eq!(
        helpers::market(&market).cash_balance(),
        cash_before + quote.premium() + quote.trading_fee() + quote.penalty_fee() + charge,
    );
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// Completing a set flattens the book: the pool owes the same wherever
/// settlement lands, so the measure returns to zero and the balancing leg is
/// free. This is what keeps a guaranteed-payout position from being charged for
/// risk it does not add.
#[test]
fun completing_a_set_is_free() {
    let (mut fx, mut market, mut account, _trader) = setup_market(INVENTORY_RATE);

    let first = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    assert!(first.inventory_charge() > 0);
    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        first.all_in_cost(),
        std::u64::max_value!(),
    );

    let second = fx.quote_mint_bundle(
        &market,
        0,
        helpers::strike_tick(),
        test_constants::mint_quantity(),
    );
    assert_eq!(second.inventory_charge(), 0);
    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        0,
        helpers::strike_tick(),
        test_constants::mint_quantity(),
        second.all_in_cost(),
        std::u64::max_value!(),
    );
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// A close that leaves the book more concentrated is charged, and the charge is
/// withheld from the payout rather than billed separately.
#[test]
fun a_close_that_unbalances_the_book_is_charged_from_its_payout() {
    let (mut fx, mut market, mut account, _trader) = setup_market(INVENTORY_RATE);

    let up_leg = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    fx.mint_bundle(
        &mut market,
        &mut account,
        0,
        helpers::strike_tick(),
        test_constants::mint_quantity(),
    );

    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    let gross = fx.live_order_value_bundle(&market, up_leg);
    let balance_before = fx.account_balance_bundle<DUSDC>(&account);
    fx.redeem_live_bundle(&mut market, &mut account, up_leg, test_constants::mint_quantity());

    // Closing one leg of a flat book leaves the survivor exposed, so the close
    // pays: the account receives strictly less than payout minus the ordinary fee.
    let credited = fx.account_balance_bundle<DUSDC>(&account) - balance_before;
    assert!(credited < gross - ORDINARY_MIN_FEE);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// A zero snapshotted rate is fully inert: no charge, and no lattice is ever
/// built, so a disabled market pays none of the mechanism's cost.
#[test]
fun a_zero_rate_market_charges_nothing() {
    let (mut fx, mut market, mut account, _trader) = setup_market(0);

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    assert_eq!(quote.inventory_charge(), 0);
    assert_eq!(
        quote.all_in_cost(),
        quote.premium()
            + (quote.trading_fee() - quote.fee_incentive_subsidy())
            + quote.builder_fee()
            + quote.penalty_fee(),
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
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

fun setup_market(
    rate: u64,
): (helpers::Fixture, helpers::MarketBundle, helpers::AccountBundle, helpers::Trader) {
    let mut fx = helpers::setup_market_default();
    fx.set_template_min_fee(ORDINARY_MIN_FEE);
    fx.set_template_inventory_skew_rate(rate);
    fx.set_default_cadence_allocation(EXPIRY_ALLOCATION, constants::expiry_cash_floor!());
    let expiry_id = fx.create_expiry(test_constants::short_expiry_ms());
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
