// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Combined fee accounting, repeat fills, live exits, and cash-backing admission
/// for all-in-budget mints.
#[test_only]
module deepbook_predict::mint_exact_cost_accounting_tests;

use deepbook_predict::{constants, expiry_cash, flow_test_helpers as helpers, order, test_constants};
use std::unit_test::assert_eq;
use usdc::usdc::USDC;

const IMPACT_SCALE: u64 = 10_000_000_000;
const IMPACT_RATE: u64 = 200_000_000;
const BUFFER: u64 = 500_000_000;
const REFERRAL_RATE: u64 = 100_000_000;
const FIRST_QUANTITY: u64 = 4_000_000;
const SECOND_QUANTITY: u64 = 3_990_000;
const FIRST_COST: u64 = 2_018_134;
const SECOND_COST: u64 = 2_013_407;
const FIRST_CASH_DELTA: u64 = 2_018_534;
const SECOND_CASH_DELTA: u64 = 2_013_806;
const FIRST_IMPACT: u64 = 160;
const TOTAL_IMPACT: u64 = 638;
const TOTAL_SUBSIDY: u64 = 7_990;
/// Mint fees net of subsidy plus builder: 35,955. Close fees plus builder:
/// 43,945. Impact charges return in full and referral routing adds no charge.
const ROUND_TRIP_FEES: u64 = 79_900;
const BUILDER_CODE_INDEX: u64 = 0;
const BACKING_CASH: u64 = 2_000_000;
const BACKING_BUDGET: u64 = 4_000_000;
/// Across the reference digital's whole +/-21 band, 7.92m costs less than 4m
/// while 7.93m costs more. The quote does not fit quantity to the 2m cash seed.
const UNBACKED_QUANTITY: u64 = 7_920_000;
/// At 4m quantity, premium 1,999,974 plus fee 20,000; no other charges.
const BACKED_COST: u64 = 2_019_974;

#[test]
fun repeated_cost_mints_route_combined_fees_and_return_impact_escrow() {
    let mut fx = helpers::setup_market_default();
    fx.set_template_backing_buffer_lambda(BUFFER);
    fx.set_template_inventory_impact_max_rate(IMPACT_RATE);
    fx.set_default_cadence_allocation(IMPACT_SCALE, test_constants::default_initial_expiry_cash());
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let referrer = fx.create_funded_manager_as(test_constants::bob(), 0);
    let trader = fx.create_funded_manager_with_referrer_as(
        test_constants::alice(),
        test_constants::mint_deposit(),
        &referrer,
    );
    fx.create_and_link_builder_code(BUILDER_CODE_INDEX, &trader);
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.seed_market_cash(
        helpers::market_mut(&mut market),
        test_constants::default_seeded_expiry_cash(),
    );
    fx.set_referral_fee_rate_bundle(&mut market, REFERRAL_RATE);
    fx.sponsor_fee_incentives_bundle(&mut market, constants::min_fee_incentive_sponsorship!());
    fx.rebalance_expiry_cash_bundle(&mut market);
    helpers::return_market_bundle(market);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let initial_cash = helpers::market(&market).cash_balance();
    let initial_subsidy = helpers::market(&market).fee_incentive_balance();

    // Independently derived across the reference digital's whole error interval:
    // q=4m: premium 1,999,974, fee 20,000, subsidy 4,000, builder 2,000,
    // impact .2*(4m)^2/(2*10b)=160, referral 1,600.
    let first = fx.quote_mint_exact_cost_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        FIRST_COST,
        FIRST_QUANTITY,
    );
    helpers::assert_atm_entry_probability(first.entry_probability());
    assert_eq!(first.quantity(), FIRST_QUANTITY);
    assert_eq!(first.all_in_cost(), FIRST_COST);
    let first_id = fx.mint_exact_cost_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        FIRST_COST,
        FIRST_QUANTITY,
    );
    assert_eq!(order::from_order_id(first_id).quantity(), FIRST_QUANTITY);
    assert_eq!(helpers::market(&market).cash_balance(), initial_cash + FIRST_CASH_DELTA);
    assert_eq!(helpers::market(&market).inventory_impact_reserve(), FIRST_IMPACT);

    // The same budget now buys one fewer lot. q=3.99m has premium 1,994,974,
    // fee 19,950, subsidy 3,990, builder 1,995, impact floor(phi(7.99m))-160=478,
    // and referral 1,596. Another 4m would cost 2,018,454, over this budget.
    let second = fx.quote_mint_exact_cost_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        FIRST_COST,
        SECOND_QUANTITY,
    );
    assert_eq!(second.quantity(), SECOND_QUANTITY);
    assert_eq!(second.all_in_cost(), SECOND_COST);
    let second_id = fx.mint_exact_cost_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        FIRST_COST,
        SECOND_QUANTITY,
    );
    assert_eq!(order::from_order_id(second_id).quantity(), SECOND_QUANTITY);
    assert_eq!(
        helpers::market(&market).cash_balance(),
        initial_cash + FIRST_CASH_DELTA + SECOND_CASH_DELTA,
    );
    assert_eq!(helpers::market(&market).inventory_impact_reserve(), TOTAL_IMPACT);
    assert_eq!(helpers::market(&market).fee_incentive_balance(), initial_subsidy - TOTAL_SUBSIDY);
    assert_eq!(
        fx.account_balance_bundle<USDC>(&account),
        test_constants::mint_deposit() - FIRST_COST - SECOND_COST,
    );
    helpers::assert_market_backed_bundle(&market);

    // Fees are the only round-trip loss; impact telescopes even though closing
    // the first order returns a different impact amount than it paid on entry.
    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.redeem_live_bundle(&mut market, &mut account, first_id, FIRST_QUANTITY);
    fx.redeem_live_bundle(&mut market, &mut account, second_id, SECOND_QUANTITY);
    assert_eq!(helpers::market(&market).inventory_impact_reserve(), 0);
    assert_eq!(
        fx.account_balance_bundle<USDC>(&account),
        test_constants::mint_deposit() - ROUND_TRIP_FEES,
    );
    assert!(!helpers::has_position_bundle(&account, expiry_id, first_id));
    assert!(!helpers::has_position_bundle(&account, expiry_id, second_id));
    helpers::assert_market_backed_bundle(&market);
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun cost_quote_does_not_size_to_cash_backing() {
    let (mut fx, expiry_id, trader) = limited_backing_market();
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let quote = fx.quote_mint_exact_cost_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        BACKING_BUDGET,
        0,
    );
    helpers::assert_atm_entry_probability(quote.entry_probability());
    assert_eq!(quote.quantity(), UNBACKED_QUANTITY);
    assert_eq!(helpers::market(&market).cash_balance(), BACKING_CASH);
    // A smaller mint is executable with these exact objects and budget. The
    // all-in quote above nevertheless sizes to the budget, not the available cash.
    let order_id = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        FIRST_QUANTITY,
        BACKING_BUDGET,
        std::u64::max_value!(),
    );
    assert_eq!(order::from_order_id(order_id).quantity(), FIRST_QUANTITY);
    assert_eq!(
        fx.account_balance_bundle<USDC>(&account),
        test_constants::mint_deposit() - BACKED_COST,
    );
    assert_eq!(helpers::market(&market).cash_balance(), BACKING_CASH + BACKED_COST);
    helpers::assert_market_backed_bundle(&market);
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = expiry_cash::EInsufficientCash)]
fun cost_mint_without_enough_backing_aborts_instead_of_resizing() {
    let (mut fx, expiry_id, trader) = limited_backing_market();
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.mint_exact_cost_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        BACKING_BUDGET,
        0,
    );
    abort 999
}

fun limited_backing_market(): (helpers::Fixture, ID, helpers::Trader) {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let trader = fx.create_funded_manager(test_constants::mint_deposit());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.seed_market_cash(helpers::market_mut(&mut market), BACKING_CASH);
    helpers::return_market_bundle(market);
    fx.scenario_mut().next_tx(test_constants::alice());
    (fx, expiry_id, trader)
}
