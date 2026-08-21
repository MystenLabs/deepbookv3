// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end custody coverage for the probability-weighted inventory-skew
/// charge. Unit tests pin the statistic's arithmetic; these tests drive the real
/// quote, account withdrawal, escrow, close, and settlement paths, and assert the
/// state-function property through custody: cycles that return the book to a
/// state return the escrow to that state's potential, exactly.
#[test_only]
module deepbook_predict::inventory_skew_flow_tests;

use deepbook_predict::{constants, flow_test_helpers as helpers, order_events, test_constants};
use dusdc::dusdc::DUSDC;
use std::{bcs, unit_test::assert_eq};
use sui::event;

const IMPACT_SCALE: u64 = 10_000_000_000;
/// 0.5%: the max admissible skew rate, and within twice the ordinary fee floor.
const SKEW_RATE: u64 = 5_000_000;
const ORDINARY_MIN_FEE: u64 = 5_000_000;
/// A spot far below every strike in play, so the up-leg being closed is worthless.
const DEEP_OUT_OF_THE_MONEY_PRICE: u64 = 50_000_000_000;
const EUnexpectedSuccess: u64 = 999;

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
    // Independent magnitude pin for the whole weight -> mass -> deviation -> rate
    // composition. For one digital of quantity q and frozen mass m, the deviation
    // is q*sqrt(m*(S-m))/S by definition. The scipy-derived reference for this
    // fixture's ATM up price is 499,993,716 +/- 21 (pricing_reference_data), and at
    // the ATM point the deviation is flat in m to first order, so the floored
    // charge rate*D/S = 5e6 * 499,999,999 / 1e9 is exactly 2,499,999 across the
    // entire reference budget (invariant even to +/-1000 raw units of m).
    assert_eq!(skew_charge, 2_499_999);
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

/// BCS mirror of `OrderMinted`, field for field, so the emitted skew amounts are
/// pinned at the byte level. Kept in sync with the source struct by the
/// assertion itself: any drift fails the byte comparison.
public struct ExpectedOrderMinted has copy, drop {
    expiry_market_id: ID,
    account_id: ID,
    order_id: u256,
    position_root_id: u256,
    owner: address,
    lower_tick: u64,
    higher_tick: u64,
    entry_probability: u64,
    quantity: u64,
    premium: u64,
    trading_fee: u64,
    fee_incentive_subsidy: u64,
    builder_fee: u64,
    penalty_fee: u64,
    referral_fee: u64,
    inventory_impact_charge: u64,
    skew_charge: u64,
    skew_rebate: u64,
    builder_code_id: Option<ID>,
    referrer_account_id: Option<ID>,
    onchain_timestamp_ms: u64,
    pyth_spot_source_timestamp_ms: u64,
    block_scholes_spot_source_timestamp_ms: u64,
    block_scholes_forward_source_timestamp_ms: u64,
    block_scholes_svi_source_timestamp_ms: u64,
}

/// The charge the trader pays is the charge the event reports: `OrderMinted`
/// carries the skew amounts, byte-exact, with the charge at its independently
/// derived ATM magnitude.
#[test]
fun a_charging_mint_emits_the_skew_amounts() {
    let (mut fx, mut market, mut account, trader) = setup_skewed_market(SKEW_RATE);

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

    let events = event::events_by_type<order_events::OrderMinted>();
    assert_eq!(events.length(), 1);
    let expected = ExpectedOrderMinted {
        expiry_market_id: helpers::market(&market).id(),
        account_id: helpers::account_id_bundle(&account),
        order_id,
        position_root_id: order_id,
        owner: helpers::owner(&trader),
        lower_tick: helpers::strike_tick(),
        higher_tick: constants::pos_inf_tick!(),
        entry_probability: quote.entry_probability(),
        quantity: test_constants::mint_quantity(),
        premium: quote.premium(),
        trading_fee: ORDINARY_MIN_FEE,
        fee_incentive_subsidy: 0,
        builder_fee: 0,
        penalty_fee: 0,
        referral_fee: 0,
        inventory_impact_charge: 0,
        // The exact ATM magnitude the quote pin derives; see the concentrating-mint test.
        skew_charge: 2_499_999,
        skew_rebate: 0,
        builder_code_id: option::none(),
        referrer_account_id: option::none(),
        onchain_timestamp_ms: test_constants::now_ms(),
        pyth_spot_source_timestamp_ms: test_constants::live_source_timestamp_ms(),
        block_scholes_spot_source_timestamp_ms: test_constants::live_source_timestamp_ms(),
        block_scholes_forward_source_timestamp_ms: test_constants::live_source_timestamp_ms(),
        block_scholes_svi_source_timestamp_ms: test_constants::live_source_timestamp_ms(),
    };
    assert_eq!(bcs::to_bytes(&events[0]), bcs::to_bytes(&expected));

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// Partial closes commit the accumulators for exactly the closed quantity: two
/// half-closes land where one full close lands, and the escrow follows the
/// potential through every intermediate state.
#[test]
fun two_half_closes_drain_the_escrow_like_one_full_close() {
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

    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    let half = test_constants::mint_quantity() / 2;
    let replacement = fx
        .redeem_live_bundle(&mut market, &mut account, order_id, half)
        .destroy_some();
    let mid_reserve = helpers::market(&market).skew_reserve();
    // Half the book is still concentrated, so half-scale potential remains.
    assert!(mid_reserve > 0 && mid_reserve < quote.skew_charge());
    helpers::assert_market_backed_bundle(&market);

    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.redeem_live_bundle(&mut market, &mut account, replacement, half);
    assert_eq!(helpers::market(&market).skew_reserve(), 0);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// Skew and the inventory-impact charge stack independently: each keeps its own
/// escrow, each telescopes on its own potential, and the backing invariant holds
/// with both live.
#[test]
fun skew_and_occupancy_charges_stack_with_isolated_escrows() {
    let mut fx = helpers::setup_market_default();
    fx.set_template_min_fee(ORDINARY_MIN_FEE);
    fx.set_template_inventory_skew_rate(SKEW_RATE);
    fx.set_template_inventory_impact_max_rate(200_000_000);
    fx.set_default_cadence_allocation(IMPACT_SCALE, constants::expiry_cash_floor!());
    let expiry_id = fx.create_expiry(test_constants::short_expiry_ms());
    let trader = fx.create_funded_manager(8 * test_constants::mint_deposit());
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
    );
    assert!(quote.skew_charge() > 0);
    assert!(quote.inventory_impact_charge() > 0);
    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );
    assert_eq!(helpers::market(&market).skew_reserve(), quote.skew_charge());
    assert_eq!(
        helpers::market(&market).inventory_impact_reserve(),
        quote.inventory_impact_charge(),
    );
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// A close whose skew charge exceeds everything the close releases aborts rather
/// than collecting less than the potential moved (the register's RP-29). Reaching
/// it needs a complete set — the book starts flat, so closing either leg
/// unbalances it and is charged — plus a spot far enough below the range that the
/// leg being closed is worthless. The position is recoverable: it settles for
/// zero at expiry, which is what it is already worth.
#[
    test,
    expected_failure(
        abort_code = deepbook_predict::expiry_market::ESkewChargeExceedsCloseProceeds,
    ),
]
fun close_of_a_worthless_leg_that_unbalances_the_book_aborts() {
    let (mut fx, mut market, mut account, _trader) = setup_skewed_market(SKEW_RATE);

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
    assert_eq!(helpers::market(&market).skew_reserve(), 0);

    fx.advance_live_oracle_bundle(&mut market, DEEP_OUT_OF_THE_MONEY_PRICE);
    fx.redeem_live_bundle_with_limits(
        &mut market,
        &mut account,
        up_leg,
        test_constants::mint_quantity(),
        0,
        0,
    );
    abort EUnexpectedSuccess
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
