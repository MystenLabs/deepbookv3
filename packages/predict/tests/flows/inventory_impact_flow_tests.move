// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end custody and slippage coverage for inventory impact. Unit tests pin
/// the state-function math; these tests drive the real quote, account withdrawal,
/// market escrow, live payout, and settlement paths.
#[test_only]
module deepbook_predict::inventory_impact_flow_tests;

use deepbook_predict::{constants, flow_test_helpers as helpers, test_constants};
use dusdc::dusdc::DUSDC;
use std::unit_test::assert_eq;

const IMPACT_SCALE: u64 = 10_000_000_000;
const IMPACT_MAX_RATE: u64 = 200_000_000; // 20%
const BACKING_BUFFER_LAMBDA: u64 = 500_000_000;
const EXPECTED_SINGLE_ORDER_CHARGE: u64 = 10_000_000;
const ORDINARY_MIN_FEE: u64 = 5_000_000;
const LEVERAGE_TWO_X: u64 = 2_000_000_000;
const DROPPED_SPOT: u64 = 99_000_000_000;

#[test]
fun mint_charge_and_live_close_rebate_use_isolated_escrow() {
    let (mut fx, expiry_id, trader) = setup_enabled_market();
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.seed_market_cash(
        helpers::market_mut(&mut market),
        test_constants::default_seeded_expiry_cash(),
    );

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    assert_eq!(quote.inventory_impact_charge(), EXPECTED_SINGLE_ORDER_CHARGE);
    assert_eq!(
        quote.all_in_cost(),
        quote.net_premium()
            + (quote.trading_fee() - quote.fee_incentive_subsidy())
            + quote.builder_fee()
            + quote.penalty_fee()
            + EXPECTED_SINGLE_ORDER_CHARGE,
    );

    let balance_before_mint = fx.account_balance_bundle<DUSDC>(&account);
    let cash_before_mint = helpers::market(&market).cash_balance();
    let order_id = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );

    assert_eq!(
        fx.account_balance_bundle<DUSDC>(&account),
        balance_before_mint - quote.all_in_cost(),
    );
    assert_eq!(
        helpers::market(&market).cash_balance(),
        cash_before_mint
            + quote.net_premium()
            + quote.trading_fee()
            + quote.penalty_fee()
            + EXPECTED_SINGLE_ORDER_CHARGE,
    );
    assert_eq!(helpers::market(&market).inventory_impact_reserve(), EXPECTED_SINGLE_ORDER_CHARGE);
    helpers::assert_market_backed_bundle(&market);

    // Reprice one millisecond later, then close the only position. Its full
    // liability reduction returns the exact charge independently of the normal
    // close fee.
    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    let gross = fx.order_value_bundle(&market, order_id);
    let balance_before_close = fx.account_balance_bundle<DUSDC>(&account);
    fx.redeem_bundle(
        &mut market,
        &mut account,
        order_id,
        test_constants::mint_quantity(),
    );

    assert_eq!(helpers::market(&market).inventory_impact_reserve(), 0);
    assert_eq!(
        fx.account_balance_bundle<DUSDC>(&account),
        balance_before_close + gross + EXPECTED_SINGLE_ORDER_CHARGE - ORDINARY_MIN_FEE,
    );
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun settlement_releases_unused_inventory_escrow_to_pool_surplus() {
    let (mut fx, expiry_id, trader) = setup_enabled_market();
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.seed_market_cash(
        helpers::market_mut(&mut market),
        test_constants::default_seeded_expiry_cash(),
    );

    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    assert_eq!(helpers::market(&market).inventory_impact_reserve(), EXPECTED_SINGLE_ORDER_CHARGE);
    let cash_before_settlement = helpers::market(&market).cash_balance();

    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(&mut market, test_constants::default_live_price());
    assert!(fx.try_settle_bundle(&mut market));

    // Settlement changes only the earmark: no cash leaves the market, and no
    // later close can claim an inventory rebate.
    assert_eq!(helpers::market(&market).inventory_impact_reserve(), 0);
    assert_eq!(helpers::market(&market).cash_balance(), cash_before_settlement);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun liquidation_reduces_risk_without_paying_an_inventory_rebate() {
    let (mut fx, expiry_id, trader) = setup_enabled_market();
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.seed_market_cash(
        helpers::market_mut(&mut market),
        test_constants::default_seeded_expiry_cash(),
    );

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        LEVERAGE_TWO_X,
    );
    assert!(quote.inventory_impact_charge() > 0);
    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        LEVERAGE_TWO_X,
    );
    let reserve_after_mint = helpers::market(&market).inventory_impact_reserve();
    let balance_after_mint = fx.account_balance_bundle<DUSDC>(&account);

    // One tick below the lower strike makes the UP digital worthless in the
    // fixture and sends the leveraged order through the zero-payout liquidation
    // arm. Risk falls, but only a voluntary live close earns a rebate.
    fx.advance_live_oracle_bundle(&mut market, DROPPED_SPOT);
    fx.redeem_bundle(
        &mut market,
        &mut account,
        order_id,
        test_constants::mint_quantity(),
    );

    assert_eq!(fx.account_balance_bundle<DUSDC>(&account), balance_after_mint);
    assert_eq!(helpers::market(&market).inventory_impact_reserve(), reserve_after_mint);
    assert_eq!(helpers::market(&market).payout_liability(), 0);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

fun setup_enabled_market(): (helpers::Fixture, ID, helpers::Trader) {
    let mut fx = helpers::setup_market_default();
    fx.set_template_backing_buffer_lambda(BACKING_BUFFER_LAMBDA);
    fx.set_template_inventory_impact_max_rate(IMPACT_MAX_RATE);
    fx.set_default_cadence_allocation(IMPACT_SCALE, constants::expiry_cash_floor!());
    let expiry_id = fx.create_expiry(test_constants::short_expiry_ms());
    let trader = fx.create_funded_manager(test_constants::mint_deposit());
    (fx, expiry_id, trader)
}
