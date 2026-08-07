// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for the inventory-skew charge: what a mint pays on top of its
/// fees, where that money sits until it is claimed, and what a close earns back.
///
/// The charge is a transaction-price shift, so it is asserted the way the other
/// fee components are — as an exact line item in the quote that the mint then
/// debits exactly. The escrow is asserted separately, because the skew charge is
/// the only cash a mint pays in that the pool does not immediately own.
///
/// Every expectation is derived from the design formula
/// `rate = gamma * (delta / net_payout) * p * (1 - p)`, capped, with
/// `delta / net_payout` written out from a hand-derived book state rather than
/// read back from the contract. Only `p` comes from the quote: it is an input to
/// the formula, and the fixture's exact Cody-approximation probability is not
/// independently derivable (see `quote_mint_tests`).
#[test_only]
module deepbook_predict::inventory_skew_flow_tests;

use deepbook_predict::{constants, flow_test_helpers as helpers, range_codec, test_constants};
use dusdc::dusdc::DUSDC;
use fixed_math::math::{Self, float_scaling as float};
use std::unit_test::assert_eq;

/// Full-strength skew: `gamma = 1.0` makes the rate exactly
/// `crowding * p(1-p)`, so every expectation below is a product of one
/// hand-derived fraction and the Bernoulli variance.
const GAMMA_ONE: u64 = 1_000_000_000;
/// A cap at 1.0 cannot bind — `crowding` and `p(1-p)` are all at most 1.0, and
/// `p(1-p)` peaks at 0.25.
const CAP_UNBOUNDED: u64 = 1_000_000_000;
/// 1% per contract: far below the ~0.25 uncapped ATM rate, so the cap binds and
/// the charge stops depending on `p` at all.
const CAP_ONE_PERCENT: u64 = 10_000_000;

/// The fixture's default backing buffer. A range whose peak sits below the book's
/// max point only consumes the `λ` share of its own dollar.
const LAMBDA_DEFAULT: u64 = 250_000_000;

/// A smooth high-variance surface (base variance 0.1) at a forward well below the
/// 100e9 strike, so the UP range prices far from the coin flip and its `p(1-p)` is
/// a fraction of the at-the-money 0.25. Used to open a book cheaply and then close
/// it back at the money, where the rebate rate is worth more than what was paid in.
const CHEAP_SURFACE_A: u64 = 100_000_000;
const CHEAP_SURFACE_FORWARD: u64 = 75_000_000_000;

/// The fixture floors `base_fee` to 1, so the trading fee binds at
/// `min_fee (0.005) * mint_quantity (1e9)`, matching `quote_mint_tests`.
const MIN_TRADING_FEE: u64 = 5_000_000;

const SKEW_OFF: bool = false;
const SKEW_REBATE_ON: bool = true;

/// A live default-expiry market whose expiry snapshotted the given skew knobs.
/// Mirrors `helpers::setup_live_market`, but arms the template first because the
/// knobs are snapshotted at market creation and immutable after it.
fun setup_skew_market(
    gamma: u64,
    cap: u64,
    rebate_enabled: bool,
): (helpers::Fixture, ID, helpers::Trader) {
    let mut fx = helpers::setup_market_default();
    fx.set_template_inventory_skew(gamma, cap, rebate_enabled);
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let trader = fx.create_funded_manager(test_constants::default_manager_deposit());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.seed_market_cash(
        helpers::market_mut(&mut market),
        test_constants::default_seeded_expiry_cash(),
    );
    helpers::return_market_bundle(market);
    fx.scenario_mut().next_tx(test_constants::alice());
    (fx, expiry_id, trader)
}

/// Bernoulli variance of the quoted probability, the one factor that has to be
/// carried from the quote rather than written down.
fun variance_of(entry_probability: u64): u64 {
    math::mul_down(entry_probability, float!() - entry_probability)
}

#[test]
fun default_config_leaves_the_skew_charge_inert() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    // Shipping default is `gamma = 0`, so the charge is absent from the quote and
    // the all-in cost is the pre-feature premium plus fee.
    assert_eq!(quote.inventory_skew_charge(), 0);
    assert_eq!(quote.all_in_cost(), quote.net_premium() + MIN_TRADING_FEE);

    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );
    assert_eq!(helpers::market(&market).skew_reserve(), 0);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun first_mint_pays_the_full_crowding_rate_and_the_market_escrows_it() {
    let (mut fx, expiry_id, trader) = setup_skew_market(
        GAMMA_ONE,
        CAP_UNBOUNDED,
        SKEW_OFF,
    );
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let cash_before = helpers::market(&market).cash_balance();

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    helpers::assert_atm_entry_probability(quote.entry_probability());

    // Empty book: the candidate's whole dollar becomes the new max point, so
    // `delta == net_payout` and crowding is 1.0. With `gamma == 1.0` the rate
    // collapses to `p(1-p)`, and one contract of quantity makes the charge equal
    // the rate.
    let expected_charge = variance_of(quote.entry_probability());
    assert_eq!(quote.inventory_skew_charge(), expected_charge);
    // The charge is its own line item outside the fee cap, added to the debit.
    assert_eq!(quote.all_in_cost(), quote.net_premium() + MIN_TRADING_FEE + expected_charge);

    fx.mint_exact_quantity_bundle(
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
        test_constants::default_manager_deposit() - quote.all_in_cost(),
    );
    // The charge lands in expiry cash with the rest of the payment, and all of it
    // is reserved.
    assert_eq!(
        helpers::market(&market).cash_balance(),
        cash_before + quote.net_premium() + MIN_TRADING_FEE + expected_charge,
    );
    assert_eq!(helpers::market(&market).skew_reserve(), expected_charge);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun cold_range_pays_the_lambda_share_and_a_pile_on_pays_the_whole_dollar() {
    let (mut fx, expiry_id, trader) = setup_skew_market(
        GAMMA_ONE,
        CAP_UNBOUNDED,
        SKEW_OFF,
    );
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // Rest one contract on the UP side. The book's whole profile is now that one
    // contract: `M = T = 1e9`, and it pays nothing below the strike.
    let opening = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    let variance = variance_of(opening.entry_probability());
    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
        opening.all_in_cost(),
        std::u64::max_value!(),
    );
    assert_eq!(helpers::market(&market).skew_reserve(), variance);

    // The DOWN complement never overlaps the resting contract, so its range peak
    // is 0 while the book's max point is 1e9: it cannot lift the max point at all
    // and consumes only `λ` of its own dollar. Crowding is the only factor that
    // moved and the charge falls to a quarter of the pile-on charge.
    let cold = fx.quote_mint_bundle(
        &market,
        constants::neg_inf!(),
        helpers::strike_tick(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    // The complement's `p(1-p)` is the same number: the two probabilities sum to
    // 1e9 and the variance is symmetric about the coin flip.
    helpers::assert_atm_complement_entry_probability(cold.entry_probability());
    assert_eq!(variance_of(cold.entry_probability()), variance);
    assert_eq!(cold.inventory_skew_charge(), math::mul_down(LAMBDA_DEFAULT, variance));

    // A second UP contract stacks directly on the peak: `R == M`, so the whole
    // dollar lifts the max point and crowding is back to 1.0.
    let pile_on = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    assert_eq!(pile_on.inventory_skew_charge(), variance);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun the_cap_bounds_the_charge_independently_of_the_probability() {
    let (mut fx, expiry_id, trader) = setup_skew_market(
        GAMMA_ONE,
        CAP_ONE_PERCENT,
        SKEW_OFF,
    );
    let market = fx.take_market_bundle(expiry_id);
    let account = fx.take_account_bundle(&trader);

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    // Uncapped this mint pays `p(1-p)` — roughly 0.25 per contract near the money.
    // The 0.01 cap binds well below that, so the charge is a flat 1% of quantity.
    assert!(variance_of(quote.entry_probability()) > CAP_ONE_PERCENT);
    assert_eq!(
        quote.inventory_skew_charge(),
        math::mul_down(CAP_ONE_PERCENT, test_constants::mint_quantity()),
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun closing_with_rebates_disabled_leaves_the_escrow_untouched() {
    let (mut fx, expiry_id, trader) = setup_skew_market(
        GAMMA_ONE,
        CAP_UNBOUNDED,
        SKEW_OFF,
    );
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let opening = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    let charge = opening.inventory_skew_charge();
    // Sole order: crowding 1.0, so the charge is exactly the Bernoulli variance.
    assert_eq!(charge, variance_of(opening.entry_probability()));
    let order = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
        opening.all_in_cost(),
        std::u64::max_value!(),
    );

    // A close must land in a later millisecond than its mint, so step the clock
    // and reseed the oracle before redeeming.
    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.redeem_bundle(&mut market, &mut account, order, test_constants::mint_quantity());

    // Rebates are off, so the close claims nothing: the escrow still holds the
    // whole opening charge and stays out of free cash until settlement.
    assert_eq!(helpers::market(&market).skew_reserve(), charge);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun closing_the_only_order_rebates_its_full_crowding_charge() {
    let (mut fx, expiry_id, trader) = setup_skew_market(
        GAMMA_ONE,
        CAP_UNBOUNDED,
        SKEW_REBATE_ON,
    );
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let opening = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    let charge = opening.inventory_skew_charge();
    assert!(charge > 0);
    let order = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
        opening.all_in_cost(),
        std::u64::max_value!(),
    );

    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    // Close-side crowding is also 1.0 (`C = 0`). ATM variance after a 1ms roll
    // is at least the opening variance, so the unclamped rebate covers the
    // escrow and the close drains it fully.
    let at_close = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    assert!(variance_of(at_close.entry_probability()) >= charge);
    fx.redeem_bundle(&mut market, &mut account, order, test_constants::mint_quantity());
    assert_eq!(helpers::market(&market).skew_reserve(), 0);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun piled_close_rebates_full_crowding_not_a_lower_load_factor() {
    let (mut fx, expiry_id, trader) = setup_skew_market(
        GAMMA_ONE,
        CAP_UNBOUNDED,
        SKEW_REBATE_ON,
    );
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // Both contracts pile onto the same peak: each pays crowding 1.0, so they
    // pay the same charge at a shared probability (no load factor left to diverge).
    let first = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    let variance = variance_of(first.entry_probability());
    let first_charge = first.inventory_skew_charge();
    assert_eq!(first_charge, variance);
    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
        first.all_in_cost(),
        std::u64::max_value!(),
    );

    let second = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    let second_charge = second.inventory_skew_charge();
    assert_eq!(second_charge, variance);
    let second_order = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
        second.all_in_cost(),
        std::u64::max_value!(),
    );
    let escrow_after_mints = helpers::market(&market).skew_reserve();
    assert_eq!(escrow_after_mints, first_charge + second_charge);

    // A close must land in a later millisecond than its mint. The extra
    // millisecond of roll-down moves the range price, so the close-side variance
    // is re-read from a same-tick quote rather than reused from the mints.
    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    let at_close = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    let close_variance = variance_of(at_close.entry_probability());
    fx.redeem_bundle(&mut market, &mut account, second_order, test_constants::mint_quantity());

    // Closing the second contract still has crowding 1.0 (peak falls by a full
    // N while the first contract remains). The rebate is the full close-side
    // variance — not a lower utilization tier — so at equal `p` it would match
    // the opening charge exactly.
    let rebate = escrow_after_mints - helpers::market(&market).skew_reserve();
    assert_eq!(rebate, close_variance);
    assert_eq!(helpers::market(&market).skew_reserve(), first_charge + second_charge - rebate);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun the_escrow_caps_a_rebate_worth_more_than_the_market_collected() {
    let (mut fx, expiry_id, trader) = setup_skew_market(
        GAMMA_ONE,
        CAP_UNBOUNDED,
        SKEW_REBATE_ON,
    );
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // Open the book on a surface whose forward sits well below the strike, so both
    // mints are priced far from the coin flip and pay a small `p(1-p)`.
    fx.set_clock_for_testing(test_constants::now_ms() + 1);
    fx.seed_bs_surface_with_svi_bundle(
        &mut market,
        test_constants::default_live_price(),
        CHEAP_SURFACE_FORWARD,
        CHEAP_SURFACE_A,
        false,
        test_constants::default_svi_b(),
        test_constants::default_svi_sigma(),
        test_constants::default_svi_rho_magnitude(),
        false,
        0,
        false,
        test_constants::now_ms() + 1,
    );

    let first = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
        first.all_in_cost(),
        std::u64::max_value!(),
    );
    let second = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    let order = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
        second.all_in_cost(),
        std::u64::max_value!(),
    );
    // Both mints sit on the same range at the same tick, so each pays the full
    // crowding rate: the escrow is two off-the-money variances, not zero, and the
    // clamp below is not vacuous.
    let escrow = first.inventory_skew_charge() + second.inventory_skew_charge();
    assert_eq!(first.inventory_skew_charge(), second.inventory_skew_charge());
    assert!(escrow > 0);
    assert_eq!(helpers::market(&market).skew_reserve(), escrow);

    // Close back at the money, where `p(1-p)` peaks. Both contracts are on the same
    // range, so the close releases its whole dollar (crowding 1.0): the rate is the
    // full at-the-money variance, priced above everything the two mints paid in.
    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    let at_close = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    let unclamped_rebate = variance_of(at_close.entry_probability());
    assert!(unclamped_rebate > escrow);

    // The escrow is the whole rebate budget, so the close is paid what the market
    // holds and not the rate it earned — without the clamp this aborts in
    // `expiry_cash::pay_skew_rebate` rather than dipping into LP cash.
    fx.redeem_bundle(&mut market, &mut account, order, test_constants::mint_quantity());
    assert_eq!(helpers::market(&market).skew_reserve(), 0);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun the_escrow_is_held_out_of_the_pool_mark() {
    let (mut fx, expiry_id, trader) = setup_skew_market(
        GAMMA_ONE,
        CAP_UNBOUNDED,
        SKEW_OFF,
    );
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    let charge = quote.inventory_skew_charge();
    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );
    assert!(charge > 0);

    // Independent mark (unit-tests rule 1): one 1x order, so the book's liability
    // is its range price times quantity with no floor to net off.
    let pricer = fx.load_pricer_bundle(&market);
    let tick_size = helpers::market(&market).tick_size();
    let liability = math::mul_down(
        pricer.range_price(
            range_codec::strike_from_tick(helpers::strike_tick(), tick_size),
            range_codec::strike_from_tick(constants::pos_inf_tick!(), tick_size),
        ),
        test_constants::mint_quantity(),
    );
    let expiry_market = helpers::market(&market);
    let nav = fx.current_nav_bundle(&market);

    // The charge is in the market's cash but not the pool's: NAV nets the escrow
    // alongside the rebate reserve, so the pool marks exactly `charge` below what
    // the same coins would be worth if the escrow were spendable.
    assert_eq!(
        nav,
        expiry_market
            .cash_balance()
            .saturating_sub(expiry_market.rebate_reserve() + charge)
            .saturating_sub(liability),
    );
    assert_eq!(
        nav + charge,
        expiry_market.cash_balance().saturating_sub(expiry_market.rebate_reserve()) - liability,
    );
    // The escrow is a liability the market must keep funded, so it also joins
    // required cash: S1 backing still holds with it counted.
    helpers::assert_market_backed(expiry_market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun settlement_releases_the_residual_escrow_without_moving_cash() {
    let (mut fx, expiry_id, trader) = setup_skew_market(
        GAMMA_ONE,
        CAP_UNBOUNDED,
        SKEW_OFF,
    );
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    let charge = quote.inventory_skew_charge();
    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );
    assert!(charge > 0);
    assert_eq!(helpers::market(&market).skew_reserve(), charge);
    let cash_before_settle = helpers::market(&market).cash_balance();

    fx.set_clock_for_testing(test_constants::default_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(&mut market, test_constants::default_live_price());
    assert!(fx.try_settle_bundle(&mut market));

    // No live order can close after settlement, so the escrow is released rather
    // than stranded: the reserve drops to zero while the cash itself never moves,
    // which is exactly how the residual reaches LPs on the next sweep.
    assert_eq!(helpers::market(&market).skew_reserve(), 0);
    assert_eq!(helpers::market(&market).cash_balance(), cash_before_settle);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}
