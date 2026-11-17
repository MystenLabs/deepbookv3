// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for `quote_redeem_open`, the read-only early-sell quote of an
/// Open record through Predict's `quote_close`. Predict retired `quote_close`
/// with live pricing in version 6 (it aborts `EUseV2`), so the quote aborts there
/// for an Open record, and still aborts `ERecordNotOpen` first for a missing,
/// Pending, or Closed record.
#[test_only]
module deepbook_predict_orders::quote_redeem_open_flow_tests;

use deepbook_predict::expiry_market::{Self, RedeemQuote};
use deepbook_predict_orders::{queue, queue_fixture::{Self as fixture, QueueTest}};
use std::unit_test::assert_eq;

const QUANTITY: u64 = 4_000_000;
const MAX_COST: u64 = 3_000_000;
const TAU: u64 = 121_000;
const MAX_ORDERS: u64 = 10;
/// The filled mint's record.
const OPEN_RECORD: u64 = 0;
/// A record ID no order has used.
const MISSING_RECORD: u64 = 7;
/// A close-side floor that accepts any fill.
const NO_FLOOR: u64 = 0;

#[test, expected_failure(abort_code = expiry_market::EUseV2)]
fun quote_redeem_open_of_an_open_record_aborts_in_predict() {
    let mut q = market_with_filled_position();
    quote_now(&mut q, OPEN_RECORD, QUANTITY);
    abort 999
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
/// clock, with no builder fee.
fun quote_now(q: &mut QueueTest, record_id: u64, close_quantity: u64): RedeemQuote {
    let pricer = q.load_pricer();
    q.quote_redeem_open(&pricer, record_id, close_quantity)
}
