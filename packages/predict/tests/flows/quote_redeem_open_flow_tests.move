// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for `quote_redeem_open`, the read-only early-sell quote of an
/// Open record: its hand-derived decomposition, its builder fee, that it carries
/// no version or freeze gate, that it equals a queued sell of the same record
/// filled at the same tick, and `ERecordNotOpen` for a missing, Pending, or
/// Closed record.
///
/// The position is a 4m (strike, +inf] mint filled from the queue at τ 121_000,
/// at the money. At the live price every probability in the reference digital's
/// ±21 band floors p * 4m to 1_999_974; the fixture's minimum fee is 0.005 per
/// unit, so the trading fee is 20_000; inventory impact is off.
#[test_only]
module deepbook_predict::quote_redeem_open_flow_tests;

use deepbook_predict::{
    commit_resolve_test_helpers as h,
    expiry_market::{Self, RedeemQuote},
    flow_test_helpers::{Self as helpers, Fixture, MarketBundle, AccountBundle},
    order_queue,
    queue_test_helpers as queue,
    test_constants
};
use std::unit_test::assert_eq;
use sui::clock;

const QUANTITY: u64 = 4_000_000;
const MAX_COST: u64 = 3_000_000;
/// floor(p * 4m) across the band.
const REDEEM_VALUE: u64 = 1_999_974;
/// 0.005 * 4m, below the redeem value it is capped at.
const TRADING_FEE: u64 = 20_000;
/// min(0.1 * 20_000, 0.005 * 4m) = min(2_000, 20_000).
const BUILDER_FEE: u64 = 2_000;
const BUILDER_CODE_INDEX: u64 = 0;
const TAU: u64 = 121_000;
/// A placement at 121_000 lands on floor(122_000 / 200) * 200.
const SELL_TAU: u64 = 122_000;
const MAX_ORDERS: u64 = 10;
/// The filled mint's record.
const OPEN_RECORD: u64 = 0;
/// A record ID no order has used.
const MISSING_RECORD: u64 = 7;
/// A close-side floor that accepts any fill.
const NO_FLOOR: u64 = 0;

#[test]
fun quote_redeem_open_prices_the_close_before_the_order_fee() {
    let (mut fx, market, mut account) = market_with_filled_position();

    let quote = quote_now(&mut fx, &market, &mut account, OPEN_RECORD, QUANTITY);

    helpers::assert_atm_entry_probability(quote.redeem_probability());
    assert_eq!(quote.redeem_close_quantity(), QUANTITY);
    assert_eq!(quote.redeem_trading_fee(), TRADING_FEE);
    assert_eq!(quote.redeem_builder_fee(), 0);
    assert_eq!(quote.redeem_inventory_impact_rebate(), 0);
    assert_eq!(quote.redeem_proceeds(), REDEEM_VALUE - TRADING_FEE);
    // A quote changes nothing: the record is still Open with its position.
    assert_eq!(h::record(&market, OPEN_RECORD).status(), order_queue::status_open());
    h::finish(fx, market, account);
}

#[test]
fun quote_redeem_open_charges_the_account_builder_fee() {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.create_and_link_builder_code(BUILDER_CODE_INDEX, &trader);
    let (mut market, mut account) = h::enter(&mut fx, expiry_id, &trader);
    fill_one_mint(&mut fx, &mut market, &mut account);

    let quote = quote_now(&mut fx, &market, &mut account, OPEN_RECORD, QUANTITY);

    assert_eq!(quote.redeem_trading_fee(), TRADING_FEE);
    assert_eq!(quote.redeem_builder_fee(), BUILDER_FEE);
    assert_eq!(quote.redeem_proceeds(), REDEEM_VALUE - TRADING_FEE - BUILDER_FEE);
    h::finish(fx, market, account);
}

#[test]
fun quote_redeem_open_still_quotes_while_frozen() {
    let (mut fx, mut market, mut account) = market_with_filled_position();
    fx.set_frozen_bundle(&mut market, true);

    let quote = quote_now(&mut fx, &market, &mut account, OPEN_RECORD, QUANTITY);

    assert_eq!(quote.redeem_proceeds(), REDEEM_VALUE - TRADING_FEE);
    h::finish(fx, market, account);
}

#[test]
fun quote_redeem_open_equals_a_queued_sell_of_the_record_filled_at_the_same_tick() {
    let (mut fx, mut market, mut account) = market_with_filled_position();
    // Reseed the feeds at 121_000, where the sell is placed.
    fx.advance_live_oracle_bundle_to(&mut market, test_constants::default_live_price(), TAU);

    // Quote the Open record at the sell's τ from feeds sampled at 121_000. The
    // live pricer rolls the surface from 121_000 to 122_000 and re-anchors on
    // the same Pyth price the commit carries, exactly as the fill's tick pricer
    // does. The quote runs on its own clock because the sell closes the record
    // and the fixture clock cannot run back to place the sell afterwards.
    let quote = quote_at(&mut fx, &market, &mut account, OPEN_RECORD, QUANTITY, SELL_TAU);
    let sell_id = queue::enqueue_redeem_open(
        &mut fx,
        &mut market,
        &mut account,
        OPEN_RECORD,
        QUANTITY,
        NO_FLOOR,
        NO_FLOOR,
    );
    fx.set_clock_for_testing(SELL_TAU);
    queue::commit_decoded(
        &mut fx,
        &mut market,
        vector[h::price_tick(SELL_TAU, test_constants::default_live_price())],
    );
    assert_eq!(queue::resolve(&mut fx, &mut market, MAX_ORDERS), 1);

    let fills = h::fills();
    let fill = fills[fills.length() - 1];
    assert_eq!(fill.record_id(), sell_id);
    assert_eq!(fill.tick_ms(), SELL_TAU);
    assert_eq!(fill.quantity(), quote.redeem_close_quantity());
    assert_eq!(fill.amount(), quote.redeem_proceeds());
    assert_eq!(fill.trading_fee(), quote.redeem_trading_fee());
    assert_eq!(fill.builder_fee(), quote.redeem_builder_fee());
    assert_eq!(fill.inventory_impact(), quote.redeem_inventory_impact_rebate());
    assert_eq!(quote.redeem_proceeds(), REDEEM_VALUE - TRADING_FEE);
    h::finish(fx, market, account);
}

#[test, expected_failure(abort_code = expiry_market::ERecordNotOpen)]
fun quote_redeem_open_of_a_missing_record_aborts() {
    let (mut fx, market, mut account) = market_with_filled_position();
    quote_now(&mut fx, &market, &mut account, MISSING_RECORD, QUANTITY);
    abort 999
}

/// A mint still waiting for its price holds no position yet.
#[test, expected_failure(abort_code = expiry_market::ERecordNotOpen)]
fun quote_redeem_open_of_a_pending_record_aborts() {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    let (mut market, mut account) = h::enter(&mut fx, expiry_id, &trader);
    let pending = enqueue_one_mint(&mut fx, &mut market, &mut account);
    quote_now(&mut fx, &market, &mut account, pending, QUANTITY);
    abort 999
}

/// A record whose position a queued sell already took is Closed.
#[test, expected_failure(abort_code = expiry_market::ERecordNotOpen)]
fun quote_redeem_open_of_a_closed_record_aborts() {
    let (mut fx, mut market, mut account) = market_with_filled_position();
    fx.advance_live_oracle_bundle_to(&mut market, test_constants::default_live_price(), TAU);
    queue::enqueue_redeem_open(
        &mut fx,
        &mut market,
        &mut account,
        OPEN_RECORD,
        QUANTITY,
        NO_FLOOR,
        NO_FLOOR,
    );
    quote_now(&mut fx, &market, &mut account, OPEN_RECORD, QUANTITY);
    abort 999
}

// === Helpers ===

/// A queue market whose record 0 is a filled 4m mint, Open, at clock τ.
fun market_with_filled_position(): (Fixture, MarketBundle, AccountBundle) {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    let (mut market, mut account) = h::enter(&mut fx, expiry_id, &trader);
    fill_one_mint(&mut fx, &mut market, &mut account);
    (fx, market, account)
}

fun enqueue_one_mint(
    fx: &mut Fixture,
    market: &mut MarketBundle,
    account: &mut AccountBundle,
): u64 {
    queue::enqueue_exact_quantity(
        fx,
        market,
        account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        QUANTITY,
        MAX_COST,
        std::u64::max_value!(),
    )
}

fun fill_one_mint(fx: &mut Fixture, market: &mut MarketBundle, account: &mut AccountBundle) {
    enqueue_one_mint(fx, market, account);
    fx.set_clock_for_testing(TAU);
    queue::commit_decoded(
        fx,
        market,
        vector[h::price_tick(TAU, test_constants::default_live_price())],
    );
    assert_eq!(queue::resolve(fx, market, MAX_ORDERS), 1);
}

/// Quote a close from `record_id` against a live pricer loaded at the fixture
/// clock, with the bundled account's builder code.
fun quote_now(
    fx: &mut Fixture,
    market: &MarketBundle,
    account: &mut AccountBundle,
    record_id: u64,
    close_quantity: u64,
): RedeemQuote {
    let pricer = fx.load_pricer_bundle(market);
    let (wrapper, _) = account.account_parts_mut();
    helpers::market(market).quote_redeem_open(
        wrapper,
        helpers::config(market),
        &pricer,
        record_id,
        close_quantity,
        fx.clock(),
    )
}

/// `quote_now` on a separate clock at `timestamp_ms`, for both the live pricer
/// and the fee time.
fun quote_at(
    fx: &mut Fixture,
    market: &MarketBundle,
    account: &mut AccountBundle,
    record_id: u64,
    close_quantity: u64,
    timestamp_ms: u64,
): RedeemQuote {
    let ctx = fx.scenario_mut().ctx();
    let mut quote_clock = clock::create_for_testing(ctx);
    quote_clock.set_for_testing(timestamp_ms);
    let expiry_market = helpers::market(market);
    let config = helpers::config(market);
    let pricer = expiry_market.load_live_pricer(
        config,
        helpers::oracle_registry(market),
        helpers::pyth(market),
        helpers::bs_values(market),
        helpers::bs_svi(market),
        &quote_clock,
        ctx,
    );
    let (wrapper, _) = account.account_parts_mut();
    let quote = expiry_market.quote_redeem_open(
        wrapper,
        config,
        &pricer,
        record_id,
        close_quantity,
        &quote_clock,
    );
    quote_clock.destroy_for_testing();
    quote
}
