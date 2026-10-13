// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for `quote_redeem_open`, the read-only early-sell quote of an
/// Open record through Predict's `quote_close`: its hand-derived decomposition,
/// its builder fee, that it carries no freeze or witness gate, that it equals a
/// queued sell of the same record filled at the same tick, and
/// `ERecordNotOpen` for a missing, Pending, or Closed record.
///
/// The position is a 4m (strike, +inf] mint filled from the queue at τ 121_000,
/// at the money. At the live price every probability in the reference digital's
/// ±21 band floors p * 4m to 1_999_974; the fixture's minimum fee is 0.005 per
/// unit, so the trading fee is 20_000; inventory impact is off.
#[test_only]
module deepbook_predict_orders::quote_redeem_open_flow_tests;

use deepbook_predict::{expiry_market::RedeemQuote, flow_test_helpers as helpers};
use deepbook_predict_orders::{
    order_queue,
    queue,
    queue_event_views as events,
    queue_fixture::{Self as fixture, QueueTest}
};
use std::unit_test::assert_eq;

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
    let mut q = market_with_filled_position();

    let quote = quote_now(&mut q, OPEN_RECORD, QUANTITY);

    helpers::assert_atm_entry_probability(quote.redeem_probability());
    assert_eq!(quote.redeem_close_quantity(), QUANTITY);
    assert_eq!(quote.redeem_trading_fee(), TRADING_FEE);
    assert_eq!(quote.redeem_builder_fee(), 0);
    assert_eq!(quote.redeem_inventory_impact_rebate(), 0);
    assert_eq!(quote.redeem_proceeds(), REDEEM_VALUE - TRADING_FEE);
    // A quote changes nothing: the record is still Open with its position.
    assert_eq!(q.record(OPEN_RECORD).status(), order_queue::status_open());
    q.finish();
}

#[test]
fun quote_redeem_open_charges_the_account_builder_fee() {
    let (mut q, _) = fixture::new().link_builder_code(BUILDER_CODE_INDEX);
    fill_one_mint(&mut q);

    let quote = quote_now(&mut q, OPEN_RECORD, QUANTITY);

    assert_eq!(quote.redeem_trading_fee(), TRADING_FEE);
    assert_eq!(quote.redeem_builder_fee(), BUILDER_FEE);
    assert_eq!(quote.redeem_proceeds(), REDEEM_VALUE - TRADING_FEE - BUILDER_FEE);
    q.finish();
}

#[test]
fun quote_redeem_open_still_quotes_while_frozen_and_without_the_witness() {
    let mut q = market_with_filled_position();
    q.set_frozen(true);
    q.set_witness(false);

    let quote = quote_now(&mut q, OPEN_RECORD, QUANTITY);

    assert_eq!(quote.redeem_proceeds(), REDEEM_VALUE - TRADING_FEE);
    q.finish();
}

#[test]
fun quote_redeem_open_equals_a_queued_sell_of_the_record_filled_at_the_same_tick() {
    let mut q = market_with_filled_position();
    // Reseed the feeds at 121_000, where the sell is placed.
    q.refresh_oracle_at(TAU);

    // Quote the Open record at the sell's τ from feeds sampled at 121_000. The
    // live pricer rolls the surface from 121_000 to 122_000 and re-anchors on
    // the same Pyth price the commit carries, exactly as the fill's tick pricer
    // does. The quote runs on its own clock because the sell closes the record
    // and the fixture clock cannot run back to place the sell afterwards.
    let quote = q.quote_redeem_open_at(OPEN_RECORD, QUANTITY, SELL_TAU);
    let sell_id = q.enqueue_sell(OPEN_RECORD, QUANTITY, NO_FLOOR, NO_FLOOR);
    q.commit_at(SELL_TAU, fixture::live_price());
    assert_eq!(q.resolve(MAX_ORDERS), 1);

    let fills = events::fills();
    let fill = fills[fills.length() - 1];
    assert_eq!(fill.record_id(), sell_id);
    assert_eq!(fill.tick_ms(), SELL_TAU);
    assert_eq!(fill.quantity(), quote.redeem_close_quantity());
    assert_eq!(fill.amount(), quote.redeem_proceeds());
    assert_eq!(fill.trading_fee(), quote.redeem_trading_fee());
    assert_eq!(fill.builder_fee(), quote.redeem_builder_fee());
    assert_eq!(fill.inventory_impact(), quote.redeem_inventory_impact_rebate());
    assert_eq!(quote.redeem_proceeds(), REDEEM_VALUE - TRADING_FEE);
    q.finish();
}

#[test, expected_failure(abort_code = queue::ERecordNotOpen)]
fun quote_redeem_open_of_a_missing_record_aborts() {
    let mut q = market_with_filled_position();
    quote_now(&mut q, MISSING_RECORD, QUANTITY);
    abort 999
}

/// A mint still waiting for its price holds no position yet.
#[test, expected_failure(abort_code = queue::ERecordNotOpen)]
fun quote_redeem_open_of_a_pending_record_aborts() {
    let mut q = fixture::new();
    let pending = q.enqueue_atm(QUANTITY, MAX_COST);
    quote_now(&mut q, pending, QUANTITY);
    abort 999
}

/// A record whose position a queued sell already took is Closed.
#[test, expected_failure(abort_code = queue::ERecordNotOpen)]
fun quote_redeem_open_of_a_closed_record_aborts() {
    let mut q = market_with_filled_position();
    q.refresh_oracle_at(TAU);
    q.enqueue_sell(OPEN_RECORD, QUANTITY, NO_FLOOR, NO_FLOOR);
    quote_now(&mut q, OPEN_RECORD, QUANTITY);
    abort 999
}

// === Helpers ===

/// A queue whose record 0 is a filled 4m mint, Open, at clock τ.
fun market_with_filled_position(): QueueTest {
    let mut q = fixture::new();
    fill_one_mint(&mut q);
    q
}

fun fill_one_mint(q: &mut QueueTest) {
    q.enqueue_atm(QUANTITY, MAX_COST);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(MAX_ORDERS), 1);
}

/// Quote a close from `record_id` against a live pricer loaded at the fixture
/// clock, with the account's builder code.
fun quote_now(q: &mut QueueTest, record_id: u64, close_quantity: u64): RedeemQuote {
    let pricer = q.load_pricer();
    q.quote_redeem_open(&pricer, record_id, close_quantity)
}
