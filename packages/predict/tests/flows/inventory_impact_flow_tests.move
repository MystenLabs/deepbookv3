// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end custody and slippage coverage for inventory impact. Unit tests pin
/// the state-function math; these tests drive the real quote, account withdrawal,
/// live payout, and settlement paths.
#[test_only]
module deepbook_predict::inventory_impact_flow_tests;

use deepbook_predict::{
    config_constants,
    constants,
    expiry_market,
    flow_test_helpers as helpers,
    order,
    order_events,
    strike_exposure,
    test_constants
};
use sui::event;
use dusdc::dusdc::DUSDC;
use std::unit_test::assert_eq;

const IMPACT_SCALE: u64 = 1_000_000_000;
const IMPACT_MAX_RATE: u64 = 20_000_000; // 2%
const BACKING_BUFFER_LAMBDA: u64 = 500_000_000;
const ORDINARY_MIN_FEE: u64 = 5_000_000;

#[test]
fun mint_charge_stays_with_the_pool_and_a_full_close_refunds_nothing() {
    let (mut fx, expiry_id, trader) = setup_enabled_market();
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.ensure_inventory_grid_bundle(&mut market);
    fx.seed_market_cash(
        helpers::market_mut(&mut market),
        test_constants::default_seeded_expiry_cash(),
    );

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    let inventory_impact_charge = quote.inventory_impact_charge();
    assert!(inventory_impact_charge > 0);
    assert_eq!(
        quote.all_in_cost(),
        quote.premium()
            + (quote.trading_fee() - quote.fee_incentive_subsidy())
            + quote.builder_fee()
            + quote.penalty_fee()
            + inventory_impact_charge,
    );

    let balance_before_mint = fx.account_balance_bundle<DUSDC>(&account);
    let cash_before_mint = helpers::market(&market).cash_balance();
    let order_id = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );

    assert_eq!(
        fx.account_balance_bundle<DUSDC>(&account),
        balance_before_mint - quote.all_in_cost(),
    );
    let cash_after_mint =
        cash_before_mint
        + quote.premium()
        + quote.trading_fee()
        + quote.penalty_fee()
        + inventory_impact_charge;
    assert_eq!(helpers::market(&market).cash_balance(), cash_after_mint);
    assert_eq!(helpers::market(&market).inventory_impact_potential(), inventory_impact_charge);
    helpers::assert_market_backed_bundle(&market);
    let minted = event::events_by_type<order_events::OrderMinted>();
    assert_eq!(minted.length(), 1);
    let (event_charge, k_before, k_after) = order_events::order_minted_inventory(&minted[0]);
    assert_eq!(event_charge, inventory_impact_charge);
    assert_eq!(k_before, 0);
    assert!(k_after > 0);

    // Reprice one millisecond later, then close the only position. It removes
    // the book's entire capital, and pays back none of the charge.
    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
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
        balance_before_close + gross - ORDINARY_MIN_FEE,
    );
    // The close moved only the payout and its fee, so the charge collected at
    // mint is still in the market's cash.
    assert_eq!(helpers::market(&market).cash_balance(), cash_after_mint - gross + ORDINARY_MIN_FEE);
    assert_eq!(helpers::market(&market).inventory_impact_potential(), 0);
    let redeemed = event::events_by_type<order_events::LiveOrderRedeemed>();
    assert_eq!(redeemed.length(), 1);
    let (close_charge, close_before, close_after) = order_events::live_order_redeemed_inventory(
        &redeemed[0],
    );
    assert_eq!(close_charge, 0);
    assert!(close_before > 0);
    assert_eq!(close_after, 0);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun partial_closes_unwind_the_potential_without_a_stored_position_payout() {
    let (mut fx, expiry_id, trader) = setup_enabled_market();
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.ensure_inventory_grid_bundle(&mut market);
    fx.seed_market_cash(
        helpers::market_mut(&mut market),
        test_constants::default_seeded_expiry_cash(),
    );

    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    let potential_after_mint = helpers::market(&market).inventory_impact_potential();
    assert!(potential_after_mint > 0);

    // Each close re-derives its own expected payout from the grid snapshot, so
    // two halves must unwind exactly what the whole added.
    let half = test_constants::mint_quantity() / 2;
    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    let replacement_id = fx
        .redeem_live_bundle(&mut market, &mut account, order_id, half)
        .destroy_some();
    assert!(helpers::market(&market).inventory_impact_potential() < potential_after_mint);

    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.redeem_live_bundle(&mut market, &mut account, replacement_id, half);
    assert!(!helpers::has_position_bundle(&account, expiry_id, replacement_id));
    assert_eq!(helpers::market(&market).inventory_impact_potential(), 0);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun settlement_leaves_the_collected_charge_in_market_cash() {
    let (mut fx, expiry_id, trader) = setup_enabled_market();
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.ensure_inventory_grid_bundle(&mut market);
    fx.seed_market_cash(
        helpers::market_mut(&mut market),
        test_constants::default_seeded_expiry_cash(),
    );

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    assert!(quote.inventory_impact_charge() > 0);
    let cash_before_settlement = helpers::market(&market).cash_balance();

    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(&mut market, test_constants::default_live_price());
    assert!(fx.try_settle_bundle(&mut market));

    // Settlement moves no cash, so the charge the market collected while live is
    // still there for the settled sweep to return to the pool.
    assert_eq!(helpers::market(&market).cash_balance(), cash_before_settlement);
    assert_eq!(helpers::market(&market).inventory_impact_potential(), 0);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun live_close_that_removes_a_hedge_collects_inventory_charge() {
    let (mut fx, expiry_id, trader) = setup_enabled_market();
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.ensure_inventory_grid_bundle(&mut market);
    fx.seed_market_cash(
        helpers::market_mut(&mut market),
        test_constants::default_seeded_expiry_cash(),
    );

    let median_tick = helpers::strike_tick();
    let risky_quote = fx.quote_mint_bundle(
        &market,
        0,
        median_tick,
        test_constants::mint_quantity(),
    );
    let charge = risky_quote.inventory_impact_charge();
    assert!(charge > 0);
    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        0,
        median_tick,
        test_constants::mint_quantity(),
        std::u64::max_value!(),
        std::u64::max_value!(),
    );

    let hedge_quote = fx.quote_mint_bundle(
        &market,
        median_tick,
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    assert_eq!(hedge_quote.inventory_impact_charge(), 0);
    let hedge_order_id = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        median_tick,
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        std::u64::max_value!(),
        std::u64::max_value!(),
    );
    assert_eq!(helpers::market(&market).inventory_impact_potential(), 0);
    let cash_before_close = helpers::market(&market).cash_balance();

    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    let gross = fx.live_order_value_bundle(&market, hedge_order_id);
    fx.redeem_live_bundle(
        &mut market,
        &mut account,
        hedge_order_id,
        test_constants::mint_quantity(),
    );

    // Removing the hedge restores the book's original capital, so the close pays
    // the same charge the risky mint did, on top of the ordinary close fee.
    assert_eq!(helpers::market(&market).inventory_impact_potential(), charge);
    assert_eq!(
        helpers::market(&market).cash_balance(),
        cash_before_close - gross + ORDINARY_MIN_FEE + charge,
    );
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = expiry_market::ERedeemCostAboveMax)]
fun live_close_inventory_debit_obeys_max_cost() {
    let mut fx = helpers::setup_market_default();
    fx.set_template_backing_buffer_lambda(BACKING_BUFFER_LAMBDA);
    fx.set_template_inventory_impact_max_rate(
        config_constants::max_inventory_impact_max_rate!(),
    );
    fx.set_template_inventory_impact_scale(config_constants::min_inventory_impact_scale!());
    let expiry_id = fx.create_expiry(test_constants::short_expiry_ms());
    let trader = fx.create_funded_manager(3 * test_constants::mint_deposit());

    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.ensure_inventory_grid_bundle(&mut market);
    fx.seed_market_cash(
        helpers::market_mut(&mut market),
        test_constants::default_seeded_expiry_cash(),
    );

    let median_tick = helpers::strike_tick();
    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        0,
        median_tick,
        test_constants::mint_quantity(),
        std::u64::max_value!(),
        std::u64::max_value!(),
    );
    let hedge_order_id = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        median_tick,
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        std::u64::max_value!(),
        std::u64::max_value!(),
    );

    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.redeem_live_bundle_with_max_cost(
        &mut market,
        &mut account,
        hedge_order_id,
        test_constants::mint_quantity(),
        0,
    );
    abort 999
}

#[test]
fun live_order_value_does_not_require_book_membership() {
    let (mut fx, expiry_id, _) = setup_enabled_market();
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());

    let hypothetical = order::new_from_ticks(
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        0,
    );
    let value = fx.live_order_value_bundle(&market, hypothetical.id());
    // `mint_quantity()` is exactly the 1e9 fixed-point scale, so the range value
    // has the same integer representation as the independently generated
    // short-expiry ATM probability.
    helpers::assert_atm_entry_probability_short_expiry(value);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = strike_exposure::EInventoryGridRequired)]
fun mint_without_a_grid_aborts_when_the_rate_is_on() {
    let (mut fx, expiry_id, trader) = setup_enabled_market();
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.seed_market_cash(
        helpers::market_mut(&mut market),
        test_constants::default_seeded_expiry_cash(),
    );
    let _order_id = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::mint_deposit(),
        std::u64::max_value!(),
    );
    abort 999
}

#[test]
fun create_with_inventory_grid_is_filled_before_the_first_mint() {
    let mut fx = helpers::setup_market_default();
    fx.set_template_backing_buffer_lambda(BACKING_BUFFER_LAMBDA);
    fx.set_template_inventory_impact_max_rate(IMPACT_MAX_RATE);
    fx.set_template_inventory_impact_scale(IMPACT_SCALE);
    let expiry_id = fx.create_expiry_with_inventory(test_constants::short_expiry_ms());
    let trader = fx.create_funded_manager(3 * test_constants::mint_deposit());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    assert!(helpers::market(&market).has_inventory_grid());
    fx.seed_market_cash(
        helpers::market_mut(&mut market),
        test_constants::default_seeded_expiry_cash(),
    );

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    let inventory_impact_charge = quote.inventory_impact_charge();
    assert!(inventory_impact_charge > 0);

    let _order_id = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );
    assert_eq!(
        helpers::market(&market).inventory_impact_potential(),
        inventory_impact_charge,
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

fun setup_enabled_market(): (helpers::Fixture, ID, helpers::Trader) {
    let mut fx = helpers::setup_market_default();
    fx.set_template_backing_buffer_lambda(BACKING_BUFFER_LAMBDA);
    fx.set_template_inventory_impact_max_rate(IMPACT_MAX_RATE);
    fx.set_template_inventory_impact_scale(IMPACT_SCALE);
    let expiry_id = fx.create_expiry(test_constants::short_expiry_ms());
    let trader = fx.create_funded_manager(3 * test_constants::mint_deposit());
    (fx, expiry_id, trader)
}
