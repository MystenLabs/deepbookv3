// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Range fees and mint eligibility over production-valid oracle observations.
#[test_only]
module deepbook_predict::range_leg_fee_tests;

use deepbook_predict::{
    constants,
    flow_test_helpers as helpers,
    pricing::RangePrice,
    range_codec::strike_for_testing as strike,
    range_test_helpers,
    strike_exposure_config,
    test_constants
};
use std::unit_test::{assert_eq, destroy};
use usdc::usdc::USDC;

const LOWER_TICK: u64 = 100;
const HIGHER_TICK: u64 = 110;
const FAR_LOWER_TICK: u64 = 1;
const FAR_HIGHER_TICK: u64 = 1000;
const DUST_QUANTITY: u64 = 75;
const TWO_DEFAULT_FLOORS: u64 = 44_000;
const ONE_DEFAULT_FLOOR: u64 = 22_000;
const TWO_FLOW_FLOORS: u64 = 10_000_000;
const HALF_QUANTITY: u64 = 500_000_000;
const HALF_CLOSE_FEE: u64 = 5_000_000;
const RAMP_WINDOW_MS: u64 = 60_000;
const HALF_WINDOW_MS: u64 = 30_000;
const DOUBLE_MULTIPLIER: u64 = 2_000_000_000;
const NARROW_MIN_PROBABILITY: u64 = 200_000_000;
const ASYMMETRIC_MAX_PROBABILITY: u64 = 600_000_000;
const CAPPED_LEG_FEE: u64 = 300_000_000;

fun range(lower: u64, higher: u64): RangePrice {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    range_test_helpers::prepare_range(&mut fx, &mut market);
    let pricer = fx.load_pricer_bundle(&market);
    let price = pricer.range_prices(strike(lower), strike(higher));
    helpers::return_market_bundle(market);
    fx.finish();
    price
}

fun bounded_range(): RangePrice {
    range(
        LOWER_TICK * test_constants::default_tick_size(),
        HIGHER_TICK * test_constants::default_tick_size(),
    )
}

#[test]
fun finite_boundaries_each_pay_the_floor() {
    let mut config = strike_exposure_config::new();
    config.set_base_fee(1);
    let price = bounded_range();
    assert_eq!(
        config.range_trading_fee(
            test_constants::default_expiry_ms(),
            &price,
            test_constants::usdc_unit(),
            test_constants::now_ms(),
        ),
        TWO_DEFAULT_FLOORS,
    );
    destroy(config);
}

#[test]
fun above_and_below_pay_one_floor_and_whole_line_pays_none() {
    let mut config = strike_exposure_config::new();
    config.set_base_fee(1);
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    range_test_helpers::prepare_range(&mut fx, &mut market);
    let pricer = fx.load_pricer_bundle(&market);
    let above = pricer.range_prices(
        strike(LOWER_TICK * test_constants::default_tick_size()),
        strike(constants::pos_inf!()),
    );
    let below = pricer.range_prices(
        strike(constants::neg_inf!()),
        strike(HIGHER_TICK * test_constants::default_tick_size()),
    );
    let whole = pricer.range_prices(strike(constants::neg_inf!()), strike(constants::pos_inf!()));
    assert_eq!(above.higher_up(), option::none());
    assert_eq!(below.lower_up(), option::none());
    assert_eq!(whole.probability(), 1_000_000_000);
    config.assert_range_mint_probability_policy(&above);
    config.assert_range_mint_probability_policy(&below);
    assert_eq!(
        config.range_trading_fee(
            test_constants::default_expiry_ms(),
            &above,
            test_constants::usdc_unit(),
            test_constants::now_ms(),
        ),
        ONE_DEFAULT_FLOOR,
    );
    assert_eq!(
        config.range_trading_fee(
            test_constants::default_expiry_ms(),
            &below,
            test_constants::usdc_unit(),
            test_constants::now_ms(),
        ),
        ONE_DEFAULT_FLOOR,
    );
    assert_eq!(
        config.range_trading_fee(
            test_constants::default_expiry_ms(),
            &whole,
            test_constants::usdc_unit(),
            test_constants::now_ms(),
        ),
        0,
    );
    destroy(config);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun finite_zero_and_one_probabilities_still_pay_two_floors() {
    let config = strike_exposure_config::new();
    let price = range(
        FAR_LOWER_TICK * test_constants::default_tick_size(),
        FAR_HIGHER_TICK * test_constants::default_tick_size(),
    );
    assert_eq!(price.lower_up(), option::some(1_000_000_000));
    assert_eq!(price.higher_up(), option::some(0));
    assert_eq!(
        config.range_trading_fee(
            test_constants::default_expiry_ms(),
            &price,
            test_constants::usdc_unit(),
            test_constants::now_ms(),
        ),
        TWO_DEFAULT_FLOORS,
    );
    destroy(config);
}

#[test]
fun leg_amounts_round_separately_before_summing() {
    let mut config = strike_exposure_config::new();
    config.set_base_fee(1);
    let price = bounded_range();
    // Each 0.022 * 75 = 1.65 rounds to 1, giving 2 rather than floor(3.3).
    assert_eq!(
        config.range_trading_fee(
            test_constants::default_expiry_ms(),
            &price,
            DUST_QUANTITY,
            test_constants::now_ms(),
        ),
        2,
    );
    config.set_expiry_fee_window_ms(RAMP_WINDOW_MS);
    config.set_expiry_fee_max_multiplier(DOUBLE_MULTIPLIER);
    // Halfway through a 1x -> 2x ramp: each 0.033 * 75 floors to 2.
    assert_eq!(
        config.range_trading_fee(
            test_constants::now_ms() + HALF_WINDOW_MS,
            &price,
            DUST_QUANTITY,
            test_constants::now_ms(),
        ),
        4,
    );
    destroy(config);
}

#[test]
fun bernoulli_range_fee_equals_two_standalone_boundary_fees() {
    let config = strike_exposure_config::new();
    let price = bounded_range();
    let expiry = test_constants::default_expiry_ms();
    let now = test_constants::now_ms();
    let quantity = test_constants::usdc_unit();
    // Metamorphic contract: composing a range charges exactly the two existing
    // standalone fees, including rounding. Absolute fee math is tested in config tests.
    let lower_fee = config.trading_fee(expiry, price.lower_up().destroy_some(), quantity, now);
    let upper_fee = config.trading_fee(expiry, price.higher_up().destroy_some(), quantity, now);
    assert_eq!(config.range_trading_fee(expiry, &price, quantity, now), lower_fee + upper_fee);
    assert!(
        config.range_trading_fee(expiry, &price, quantity, now) > 2 * config.trading_fee(expiry, price.probability(), quantity, now),
    );
    destroy(config);
}

#[test, expected_failure(abort_code = strike_exposure_config::EEntryProbabilityOutOfBounds)]
fun lower_tail_invalidates_an_otherwise_admissible_range() {
    let config = strike_exposure_config::new();
    let price = range(
        FAR_LOWER_TICK * test_constants::default_tick_size(),
        LOWER_TICK * test_constants::default_tick_size(),
    );
    config.assert_mint_probability_policy(price.probability());
    config.assert_range_mint_probability_policy(&price);
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::EEntryProbabilityOutOfBounds)]
fun upper_tail_invalidates_an_otherwise_admissible_range() {
    let config = strike_exposure_config::new();
    let price = range(
        LOWER_TICK * test_constants::default_tick_size(),
        FAR_HIGHER_TICK * test_constants::default_tick_size(),
    );
    config.assert_mint_probability_policy(price.probability());
    config.assert_range_mint_probability_policy(&price);
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::EEntryProbabilityOutOfBounds)]
fun admissible_legs_do_not_rescue_a_too_narrow_range() {
    let mut config = strike_exposure_config::new();
    config.set_min_entry_probability(NARROW_MIN_PROBABILITY);
    let price = bounded_range();
    config.assert_mint_probability_policy(price.lower_up().destroy_some());
    config.assert_mint_probability_policy(1_000_000_000 - price.higher_up().destroy_some());
    config.assert_range_mint_probability_policy(&price);
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::EEntryProbabilityOutOfBounds)]
fun upper_leg_eligibility_uses_below_probability_under_asymmetric_bounds() {
    let mut config = strike_exposure_config::new();
    config.set_max_entry_probability(ASYMMETRIC_MAX_PROBABILITY);
    let price = bounded_range();
    config.assert_mint_probability_policy(price.lower_up().destroy_some());
    config.assert_mint_probability_policy(price.higher_up().destroy_some());
    config.assert_mint_probability_policy(price.probability());
    config.assert_range_mint_probability_policy(&price);
    abort 999
}

#[test]
fun range_quote_mint_and_partial_close_conserve_cash_with_two_fees() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    range_test_helpers::prepare_range(&mut fx, &mut market);
    let quote = fx.quote_mint_bundle(
        &market,
        LOWER_TICK,
        HIGHER_TICK,
        test_constants::mint_quantity(),
    );
    assert_eq!(quote.trading_fee(), TWO_FLOW_FLOORS);
    let balance_before = fx.account_balance_bundle<USDC>(&account);
    let order = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        LOWER_TICK,
        HIGHER_TICK,
        test_constants::mint_quantity(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );
    assert_eq!(fx.account_balance_bundle<USDC>(&account), balance_before - quote.all_in_cost());
    helpers::assert_market_backed_bundle(&market);
    range_test_helpers::prepare_range(&mut fx, &mut market);
    let gross = helpers::market(&market).live_order_value(&fx.load_pricer_bundle(&market), order);
    let before_close = fx.account_balance_bundle<USDC>(&account);
    let cash_before = helpers::market(&market).cash_balance();
    let survivor = fx
        .redeem_live_bundle(&mut market, &mut account, order, HALF_QUANTITY)
        .destroy_some();
    let proceeds = gross / 2 - HALF_CLOSE_FEE;
    assert_eq!(fx.account_balance_bundle<USDC>(&account), before_close + proceeds);
    assert_eq!(helpers::market(&market).cash_balance(), cash_before - proceeds);
    assert!(helpers::has_position_bundle(&account, expiry_id, survivor));
    helpers::assert_market_backed_bundle(&market);
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = strike_exposure_config::EEntryProbabilityOutOfBounds)]
fun public_quote_rejects_a_range_with_an_ineligible_upper_leg() {
    let (mut fx, expiry_id, _trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    let market = fx.take_market_bundle(expiry_id);
    // The default tiny variance prices the upper finite boundary at zero.
    fx.quote_mint_bundle(&market, LOWER_TICK, HIGHER_TICK, test_constants::mint_quantity());
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::EEntryProbabilityOutOfBounds)]
fun public_mint_rejects_a_range_with_an_ineligible_lower_leg() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.mint_bundle(
        &mut market,
        &mut account,
        LOWER_TICK - 10,
        LOWER_TICK,
        test_constants::mint_quantity(),
    );
    abort 999
}

#[test]
fun existing_range_closes_after_a_finite_leg_moves_outside_entry_bounds() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    range_test_helpers::prepare_range(&mut fx, &mut market);
    let order = fx.mint_bundle(
        &mut market,
        &mut account,
        LOWER_TICK,
        HIGHER_TICK,
        test_constants::mint_quantity(),
    );
    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    let pricer = fx.load_pricer_bundle(&market);
    let price = pricer.range_prices(
        strike(LOWER_TICK * test_constants::default_tick_size()),
        strike(HIGHER_TICK * test_constants::default_tick_size()),
    );
    assert_eq!(price.higher_up(), option::some(0));
    let gross = helpers::market(&market).live_order_value(&pricer, order);
    let before = fx.account_balance_bundle<USDC>(&account);
    assert_eq!(
        fx.redeem_live_bundle(&mut market, &mut account, order, test_constants::mint_quantity()),
        option::none(),
    );
    assert_eq!(fx.account_balance_bundle<USDC>(&account), before + gross - TWO_FLOW_FLOORS);
    assert!(!helpers::has_position_bundle(&account, expiry_id, order));
    helpers::assert_market_backed_bundle(&market);
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun range_close_caps_the_sum_at_redemption_value() {
    let mut fx = helpers::setup_market_default();
    fx.set_template_min_fee(CAPPED_LEG_FEE);
    let expiry_id = fx.create_expiry(test_constants::short_expiry_ms());
    let trader = fx.create_funded_manager(test_constants::mint_deposit());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.seed_market_cash(
        helpers::market_mut(&mut market),
        test_constants::default_seeded_expiry_cash(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut account = fx.take_account_bundle(&trader);
    range_test_helpers::prepare_range(&mut fx, &mut market);
    let quote = fx.quote_mint_bundle(
        &market,
        LOWER_TICK,
        HIGHER_TICK,
        test_constants::mint_quantity(),
    );
    assert_eq!(quote.trading_fee(), 2 * CAPPED_LEG_FEE);
    assert!(quote.premium() < quote.trading_fee());
    let order = fx.mint_bundle(
        &mut market,
        &mut account,
        LOWER_TICK,
        HIGHER_TICK,
        test_constants::mint_quantity(),
    );
    range_test_helpers::prepare_range(&mut fx, &mut market);
    let balance = fx.account_balance_bundle<USDC>(&account);
    let cash = helpers::market(&market).cash_balance();
    assert_eq!(
        fx.redeem_live_bundle(&mut market, &mut account, order, test_constants::mint_quantity()),
        option::none(),
    );
    assert_eq!(fx.account_balance_bundle<USDC>(&account), balance);
    assert_eq!(helpers::market(&market).cash_balance(), cash);
    assert!(!helpers::has_position_bundle(&account, expiry_id, order));
    assert_eq!(helpers::market(&market).payout_liability(), 0);
    helpers::assert_market_backed_bundle(&market);
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}
