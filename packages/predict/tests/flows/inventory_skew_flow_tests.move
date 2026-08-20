// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end custody coverage for inventory skew. Unit tests pin the deviation
/// math; these tests drive the real quote, account withdrawal, market escrow,
/// live close, and settlement paths, and they are the only coverage that a skew
/// rebate actually reaches the trader.
#[test_only]
module deepbook_predict::inventory_skew_flow_tests;

use deepbook_predict::{
    config_constants,
    constants,
    flow_test_helpers as helpers,
    order_events,
    test_constants
};
use dusdc::dusdc::DUSDC;
use std::{bcs, unit_test::assert_eq};
use sui::event;

/// Mirror of `order_events::OrderMinted` for byte-exact event comparison; the
/// event's own fields are module-private.
public struct ExpectedOrderMinted has drop {
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
    inventory_impact_charge: u64,
    skew_charge: u64,
    skew_rebate: u64,
    builder_code_id: Option<ID>,
    minted_at_ms: u64,
    pyth_spot_source_timestamp_ms: u64,
    block_scholes_spot_source_timestamp_ms: u64,
    block_scholes_forward_source_timestamp_ms: u64,
    block_scholes_svi_source_timestamp_ms: u64,
}

const IMPACT_SCALE: u64 = 10_000_000_000;
/// The configured rate ceiling, so escrow movements are large enough to read
/// against the ordinary fee.
const SKEW_RATE: u64 = 5_000_000;
/// One reference tick of half-width per day. The fixture's reference tick is
/// `100` and its cadence is one minute, so tenor scaling leaves a half-width of
/// two ticks; the production-scale 10% floors to zero at this tick granularity.
const FULL_WINDOW_FRACTION: u64 = 1_000_000_000;
/// A single `(reference, +inf]` order covers exactly half of the resulting
/// four-tick window, so the payout profile is a step of height `quantity` over
/// half the window and its standard deviation is `quantity / 2 = 5e8`. At
/// `SKEW_RATE` the charge is `0.005 * 5e8`.
const HALF_WINDOW_CHARGE: u64 = 2_500_000;
/// Half the quantity leaves a step of half the height, so half the deviation.
const QUARTER_WINDOW_CHARGE: u64 = 1_250_000;
const ORDINARY_MIN_FEE: u64 = 5_000_000;
const HALF_QUANTITY: u64 = 500_000_000;
const BACKING_BUFFER_LAMBDA: u64 = 500_000_000;
const IMPACT_MAX_RATE: u64 = 200_000_000;
/// `0.2 * Q^2 / (2 * IMPACT_SCALE)` with `M = T = Q`.
const CONCENTRATING_OCCUPANCY_CHARGE: u64 = 10_000_000;
/// The same potential at `L = 1.5Q`, less what the first mint already paid.
const BALANCING_OCCUPANCY_CHARGE: u64 = 12_500_000;
/// The rates the two mechanisms were calibrated against together: 0.1% occupancy
/// and 0.13% skew, versus the exaggerated rates the other tests use to make
/// escrow movements legible.
const CALIBRATED_OCCUPANCY_RATE: u64 = 1_000_000;
const CALIBRATED_SKEW_RATE: u64 = 1_300_000;
const CALIBRATED_OCCUPANCY_REBATE: u64 = 62_500;
const CALIBRATED_SKEW_CHARGE: u64 = 650_000;
/// Half the reference price with minutes to expiry, so a `(reference, +inf]` leg
/// prices at effectively zero.
const DEEP_OUT_OF_THE_MONEY_PRICE: u64 = 50_000_000_000;
const EUnexpectedSuccess: u64 = 999;

#[test]
fun mint_charge_escrows_and_full_close_returns_it() {
    let (mut fx, mut market, mut account, _trader) = setup_skewed_market();

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    assert_eq!(quote.skew_charge(), HALF_WINDOW_CHARGE);
    assert_eq!(quote.skew_rebate(), 0);
    assert_eq!(
        quote.all_in_cost(),
        quote.premium()
            + (quote.trading_fee() - quote.fee_incentive_subsidy())
            + quote.builder_fee()
            + quote.penalty_fee()
            + HALF_WINDOW_CHARGE,
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
    assert_eq!(
        helpers::market(&market).cash_balance(),
        cash_before_mint
            + quote.premium()
            + quote.trading_fee()
            + quote.penalty_fee()
            + HALF_WINDOW_CHARGE,
    );
    assert_eq!(helpers::market(&market).skew_reserve(), HALF_WINDOW_CHARGE);
    helpers::assert_market_backed_bundle(&market);

    // Closing the only position flattens the profile, so the escrow returns in
    // full and independently of the ordinary close fee.
    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    let gross = fx.live_order_value_bundle(&market, order_id);
    let balance_before_close = fx.account_balance_bundle<DUSDC>(&account);
    fx.redeem_live_bundle(&mut market, &mut account, order_id, test_constants::mint_quantity());

    assert_eq!(helpers::market(&market).skew_reserve(), 0);
    assert_eq!(
        fx.account_balance_bundle<DUSDC>(&account),
        balance_before_close + gross + HALF_WINDOW_CHARGE - ORDINARY_MIN_FEE,
    );
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// The mechanism's signature property: a mint that flattens the book is paid.
#[test]
fun mint_that_flattens_the_book_is_paid_a_rebate() {
    let (mut fx, mut market, mut account, _trader) = setup_skewed_market();

    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    assert_eq!(helpers::market(&market).skew_reserve(), HALF_WINDOW_CHARGE);

    // The complementary range tiles the window, so the pool owes the same
    // quantity wherever settlement lands and the deviation returns to zero.
    let quote = fx.quote_mint_bundle(
        &market,
        0,
        helpers::strike_tick(),
        test_constants::mint_quantity(),
    );
    assert_eq!(quote.skew_rebate(), HALF_WINDOW_CHARGE);
    assert_eq!(quote.skew_charge(), 0);
    let gross_cost =
        quote.premium()
            + (quote.trading_fee() - quote.fee_incentive_subsidy())
            + quote.builder_fee()
            + quote.penalty_fee();
    assert_eq!(quote.all_in_cost(), gross_cost - HALF_WINDOW_CHARGE);

    let balance_before_mint = fx.account_balance_bundle<DUSDC>(&account);
    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        0,
        helpers::strike_tick(),
        test_constants::mint_quantity(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );

    // The rebate rejoins the payment rather than being paid out separately, so
    // the trader withdraws strictly less than the trade's gross cost.
    assert_eq!(
        fx.account_balance_bundle<DUSDC>(&account),
        balance_before_mint - (gross_cost - HALF_WINDOW_CHARGE),
    );
    assert_eq!(helpers::market(&market).skew_reserve(), 0);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// A partial close moves the escrow by the difference of two book scores, not by
/// a share of the original charge.
#[test]
fun partial_close_moves_the_escrow_by_the_score_difference() {
    let (mut fx, mut market, mut account, _trader) = setup_skewed_market();

    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    assert_eq!(helpers::market(&market).skew_reserve(), HALF_WINDOW_CHARGE);

    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.redeem_live_bundle(&mut market, &mut account, order_id, HALF_QUANTITY);

    assert_eq!(helpers::market(&market).skew_reserve(), QUARTER_WINDOW_CHARGE);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun settlement_releases_the_unused_skew_escrow() {
    let (mut fx, mut market, mut account, _trader) = setup_skewed_market();

    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    assert_eq!(helpers::market(&market).skew_reserve(), HALF_WINDOW_CHARGE);
    let cash_before_settlement = helpers::market(&market).cash_balance();

    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(&mut market, test_constants::default_live_price());
    assert!(fx.try_settle_bundle(&mut market));

    // Settlement changes only the earmark: no cash leaves the market, and no
    // later close can claim a skew rebate.
    assert_eq!(helpers::market(&market).skew_reserve(), 0);
    assert_eq!(helpers::market(&market).cash_balance(), cash_before_settlement);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

fun setup_skewed_market(): (
    helpers::Fixture,
    helpers::MarketBundle,
    helpers::AccountBundle,
    helpers::Trader,
) {
    setup_skewed_market_with_min_fee(ORDINARY_MIN_FEE)
}

fun setup_skewed_market_with_min_fee(
    min_fee: u64,
): (helpers::Fixture, helpers::MarketBundle, helpers::AccountBundle, helpers::Trader) {
    let mut fx = helpers::setup_market_default();
    fx.set_template_min_fee(min_fee);
    fx.set_template_inventory_skew_rate(SKEW_RATE);
    fx.set_template_skew_window_fraction(FULL_WINDOW_FRACTION);
    fx.set_default_cadence_allocation(IMPACT_SCALE, constants::expiry_cash_floor!());
    let expiry_id = fx.create_expiry(test_constants::short_expiry_ms());
    // Four mint deposits: the rebate case funds both legs of a complete set.
    let trader = fx.create_funded_manager(8 * test_constants::mint_deposit());
    let mut market = fx.take_market_bundle(expiry_id);
    let account = fx.take_account_bundle(&trader);

    fx.set_reference_tick_bundle(&mut market, test_constants::default_live_price());
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.seed_market_cash(
        helpers::market_mut(&mut market),
        test_constants::default_seeded_expiry_cash(),
    );
    (fx, market, account, trader)
}

/// A close whose skew charge exceeds everything the close releases aborts rather
/// than collecting less than the potential moved. Reaching it needs a complete
/// set — so the book starts flat and closing either leg unbalances it — plus a
/// price far enough below the range that the leg being closed is worthless.
/// The position is recoverable: it settles for zero at expiry, which is what it
/// is already worth.
#[
    test,
    expected_failure(
        abort_code = deepbook_predict::expiry_market::ESkewChargeExceedsCloseProceeds,
    ),
]
fun close_of_a_worthless_leg_that_unbalances_the_book_aborts() {
    let (mut fx, mut market, mut account, _trader) = setup_skewed_market();

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

/// Closing a slice does not escape the bound above. The charge is convex in the
/// quantity closed, so smaller closes are never worse per unit — but the state
/// that makes a close maximally unbalancing is a book already flat across the
/// window, and there the charge is exactly linear, so proceeds and charge shrink
/// together and every fraction aborts alike.
#[
    test,
    expected_failure(
        abort_code = deepbook_predict::expiry_market::ESkewChargeExceedsCloseProceeds,
    ),
]
fun closing_a_slice_of_the_worthless_leg_aborts_the_same_way() {
    let (mut fx, mut market, mut account, _trader) = setup_skewed_market();

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

    fx.advance_live_oracle_bundle(&mut market, DEEP_OUT_OF_THE_MONEY_PRICE);
    fx.redeem_live_bundle_with_limits(
        &mut market,
        &mut account,
        up_leg,
        test_constants::mint_quantity() / 10,
        0,
        0,
    );
    abort EUnexpectedSuccess
}

/// The event reports the same signed adjustment the escrow moved, and never both
/// legs at once. Compared over the whole event, so a swapped or dropped emit
/// cannot pass — no state assertion can catch that, because events move no cash.
#[test]
fun mint_events_carry_the_skew_leg_that_moved_the_escrow() {
    let (mut fx, mut market, mut account, trader) = setup_skewed_market();
    let expiry_market_id = helpers::market(&market).id();
    let account_id = helpers::account_id_bundle(&account);
    let owner = helpers::owner(&trader);

    let charged = mint_and_assert_event(
        &mut fx,
        &mut market,
        &mut account,
        expiry_market_id,
        account_id,
        owner,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        HALF_WINDOW_CHARGE,
        0,
        1,
    );

    // The complementary leg flattens the book, so the same helper asserts the
    // rebate field carries the amount and the charge field stays clear.
    let rebated = mint_and_assert_event(
        &mut fx,
        &mut market,
        &mut account,
        expiry_market_id,
        account_id,
        owner,
        0,
        helpers::strike_tick(),
        0,
        HALF_WINDOW_CHARGE,
        2,
    );
    assert!(charged != rebated);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

fun mint_and_assert_event(
    fx: &mut helpers::Fixture,
    market: &mut helpers::MarketBundle,
    account: &mut helpers::AccountBundle,
    expiry_market_id: ID,
    account_id: ID,
    owner: address,
    lower_tick: u64,
    higher_tick: u64,
    skew_charge: u64,
    skew_rebate: u64,
    // The fixture keeps both mints in one transaction, and `events_by_type` is
    // transaction-scoped, so each call pins the running count as well as the
    // event it just produced.
    expected_event_count: u64,
): u256 {
    let quote = fx.quote_mint_bundle(
        market,
        lower_tick,
        higher_tick,
        test_constants::mint_quantity(),
    );
    let pricer = fx.load_pricer_bundle(market);
    let minted_at_ms = fx.clock().timestamp_ms();
    let order_id = fx.mint_exact_quantity_bundle(
        market,
        account,
        lower_tick,
        higher_tick,
        test_constants::mint_quantity(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );

    let events = event::events_by_type<order_events::OrderMinted>();
    assert_eq!(events.length(), expected_event_count);
    let expected = ExpectedOrderMinted {
        expiry_market_id,
        account_id,
        order_id,
        position_root_id: order_id,
        owner,
        lower_tick,
        higher_tick,
        entry_probability: quote.entry_probability(),
        quantity: test_constants::mint_quantity(),
        premium: quote.premium(),
        trading_fee: quote.trading_fee(),
        fee_incentive_subsidy: quote.fee_incentive_subsidy(),
        builder_fee: quote.builder_fee(),
        penalty_fee: quote.penalty_fee(),
        inventory_impact_charge: quote.inventory_impact_charge(),
        skew_charge,
        skew_rebate,
        builder_code_id: option::none(),
        minted_at_ms,
        pyth_spot_source_timestamp_ms: pricer.pyth_spot_source_timestamp_ms(),
        block_scholes_spot_source_timestamp_ms: pricer.block_scholes_spot_source_timestamp_ms(),
        block_scholes_forward_source_timestamp_ms: pricer.block_scholes_forward_source_timestamp_ms(),
        block_scholes_svi_source_timestamp_ms: pricer.block_scholes_svi_source_timestamp_ms(),
    };
    assert_eq!(bcs::to_bytes(&events[expected_event_count - 1]), bcs::to_bytes(&expected));
    order_id
}

/// A close that unbalances the book is charged, and the charge lands in the
/// escrow rather than in the pool's free cash. Closing the in-the-money leg of a
/// complete set leaves the book one-sided and pays enough to cover the charge.
#[test]
fun close_that_unbalances_the_book_credits_the_escrow() {
    let (mut fx, mut market, mut account, _trader) = setup_skewed_market();

    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    let down_leg = fx.mint_bundle(
        &mut market,
        &mut account,
        0,
        helpers::strike_tick(),
        test_constants::mint_quantity(),
    );
    assert_eq!(helpers::market(&market).skew_reserve(), 0);

    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    let cash_before_close = helpers::market(&market).cash_balance();
    fx.redeem_live_bundle(&mut market, &mut account, down_leg, test_constants::mint_quantity());

    // The remaining leg covers half the window again, so the escrow refills to
    // the same amount the first mint had paid.
    assert_eq!(helpers::market(&market).skew_reserve(), HALF_WINDOW_CHARGE);
    // The charge stays in the market, so the payout drains cash by strictly less
    // than the position was worth.
    assert!(helpers::market(&market).cash_balance() < cash_before_close);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// The escrow charge is senior to fee revenue, so it is taken out of the payout
/// before the trading fee is clamped against what remains. Without that ordering
/// a close whose fee already consumed the whole payout would abort instead of
/// collecting, stranding the position. Pinned with the fee floor at its ceiling,
/// where the fee always exceeds the payout.
#[test]
fun escrow_charge_outranks_the_fee_when_the_payout_is_fully_consumed() {
    let (mut fx, mut market, mut account, _trader) = setup_skewed_market_with_min_fee(
        config_constants::max_min_fee!(),
    );

    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    let down_leg = fx.mint_bundle(
        &mut market,
        &mut account,
        0,
        helpers::strike_tick(),
        test_constants::mint_quantity(),
    );
    assert_eq!(helpers::market(&market).skew_reserve(), 0);

    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    let balance_before_close = fx.account_balance_bundle<DUSDC>(&account);
    fx.redeem_live_bundle(&mut market, &mut account, down_leg, test_constants::mint_quantity());

    // The fee absorbs everything the charge left behind, so the trader nets
    // nothing — but the close lands and the escrow is whole.
    assert_eq!(fx.account_balance_bundle<DUSDC>(&account), balance_before_close);
    assert_eq!(helpers::market(&market).skew_reserve(), HALF_WINDOW_CHARGE);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// Skew and capital occupancy compose rather than collide: separate escrows,
/// separate potentials, and both telescope to zero over the same round trip.
///
/// It also pins why the second mechanism exists. The two mints below are a
/// complete set, so they are disjoint and the peak `M` never moves while `T`
/// doubles. Occupancy reads `L = M + lambda(T - M)`, so it charges the
/// *balancing* mint more than the concentrating one. That is not a defect:
/// `lambda(T - M)` is the early-exit liquidity buffer, and the second leg
/// genuinely adds to it. It is the point — occupancy ranks these two trades by
/// the cash the expiry must hold, which is the opposite of how they rank by
/// directional risk, and it has no term that could tell them apart. Skew
/// supplies that term.
#[test]
fun skew_and_occupancy_compose_without_aliasing() {
    let mut fx = helpers::setup_market_default();
    fx.set_template_backing_buffer_lambda(BACKING_BUFFER_LAMBDA);
    fx.set_template_inventory_impact_max_rate(IMPACT_MAX_RATE);
    fx.set_template_inventory_skew_rate(SKEW_RATE);
    fx.set_template_skew_window_fraction(FULL_WINDOW_FRACTION);
    fx.set_default_cadence_allocation(IMPACT_SCALE, constants::expiry_cash_floor!());
    let expiry_id = fx.create_expiry(test_constants::short_expiry_ms());
    let trader = fx.create_funded_manager(8 * test_constants::mint_deposit());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.set_reference_tick_bundle(&mut market, test_constants::default_live_price());
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.seed_market_cash(
        helpers::market_mut(&mut market),
        test_constants::default_seeded_expiry_cash(),
    );

    // Into an empty book: M = T = Q, so L = Q and the potential is
    // 0.2 * Q^2 / (2 * 1e10) = 1e7. The profile is a half-window step, so skew
    // charges 5e8 * 0.005.
    let concentrating = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    assert_eq!(concentrating.inventory_impact_charge(), CONCENTRATING_OCCUPANCY_CHARGE);
    assert_eq!(concentrating.skew_charge(), HALF_WINDOW_CHARGE);
    let up_leg = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );

    // The complementary leg is disjoint, so M stays Q while T doubles:
    // L = Q + 0.5 * Q = 1.5Q, the potential is 2.25e7, and occupancy charges the
    // 1.25e7 difference — more than it charged the trade that created the
    // imbalance. Skew reads the flattening and rebates.
    let balancing = fx.quote_mint_bundle(
        &market,
        0,
        helpers::strike_tick(),
        test_constants::mint_quantity(),
    );
    assert_eq!(balancing.inventory_impact_charge(), BALANCING_OCCUPANCY_CHARGE);
    assert_eq!(balancing.skew_rebate(), HALF_WINDOW_CHARGE);
    assert_eq!(balancing.skew_charge(), 0);

    // Occupancy alone ranks these backwards; the two together rank them right.
    assert!(BALANCING_OCCUPANCY_CHARGE > CONCENTRATING_OCCUPANCY_CHARGE);
    assert!(
        BALANCING_OCCUPANCY_CHARGE - HALF_WINDOW_CHARGE
            < CONCENTRATING_OCCUPANCY_CHARGE + HALF_WINDOW_CHARGE,
    );

    let down_leg = fx.mint_bundle(
        &mut market,
        &mut account,
        0,
        helpers::strike_tick(),
        test_constants::mint_quantity(),
    );

    // Each escrow holds its own mechanism's potential and neither reads the other.
    assert_eq!(
        helpers::market(&market).inventory_impact_reserve(),
        CONCENTRATING_OCCUPANCY_CHARGE + BALANCING_OCCUPANCY_CHARGE,
    );
    assert_eq!(helpers::market(&market).skew_reserve(), 0);
    helpers::assert_market_backed_bundle(&market);

    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.redeem_live_bundle(&mut market, &mut account, down_leg, test_constants::mint_quantity());
    fx.redeem_live_bundle(&mut market, &mut account, up_leg, test_constants::mint_quantity());

    // Both potentials are state functions, so the round trip returns both escrows
    // to zero even though neither individual leg nets zero.
    assert_eq!(helpers::market(&market).inventory_impact_reserve(), 0);
    assert_eq!(helpers::market(&market).skew_reserve(), 0);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// At the rates the two mechanisms were calibrated against, skew outweighs the
/// occupancy rebate on a risk-increasing close by roughly ten to one.
///
/// This is the calibration's load-bearing property and it is not visible at the
/// exaggerated rates the other tests use. Closing the balancing leg of a complete
/// set leaves the book one-sided, so occupancy — which reads only the cash the
/// expiry must hold — pays a rebate for a trade that makes the pool riskier. Skew
/// has to be the larger of the two for the net to come out a charge. It is, but
/// only because the two rates are within a small factor of each other; the test
/// fixture's ratio reverses the result, which is why this pins the calibrated one.
#[test]
fun at_calibrated_rates_skew_outweighs_the_occupancy_rebate() {
    let mut fx = helpers::setup_market_default();
    fx.set_template_backing_buffer_lambda(BACKING_BUFFER_LAMBDA);
    fx.set_template_inventory_impact_max_rate(CALIBRATED_OCCUPANCY_RATE);
    fx.set_template_inventory_skew_rate(CALIBRATED_SKEW_RATE);
    fx.set_template_skew_window_fraction(FULL_WINDOW_FRACTION);
    fx.set_default_cadence_allocation(IMPACT_SCALE, constants::expiry_cash_floor!());
    let expiry_id = fx.create_expiry(test_constants::short_expiry_ms());
    let trader = fx.create_funded_manager(8 * test_constants::mint_deposit());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.set_reference_tick_bundle(&mut market, test_constants::default_live_price());
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
    );
    let balancing_leg = fx.mint_bundle(
        &mut market,
        &mut account,
        0,
        helpers::strike_tick(),
        test_constants::mint_quantity(),
    );
    let occupancy_before = helpers::market(&market).inventory_impact_reserve();
    let skew_before = helpers::market(&market).skew_reserve();

    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.redeem_live_bundle(
        &mut market,
        &mut account,
        balancing_leg,
        test_constants::mint_quantity(),
    );

    // Occupancy: 0.001 * (1.5Q)^2 / 2B minus 0.001 * Q^2 / 2B = 112_500 - 50_000.
    let occupancy_rebate =
        occupancy_before
        - helpers::market(&market).inventory_impact_reserve();
    assert_eq!(occupancy_rebate, CALIBRATED_OCCUPANCY_REBATE);
    // Skew: 0.0013 * (5e8 - 0), the deviation the close reintroduces.
    let skew_charge = helpers::market(&market).skew_reserve() - skew_before;
    assert_eq!(skew_charge, CALIBRATED_SKEW_CHARGE);

    // The net must be a charge, or the pool pays traders to unbalance its book.
    assert!(skew_charge > occupancy_rebate);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}
