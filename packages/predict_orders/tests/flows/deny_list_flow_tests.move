// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The queue under USDC's deny list (`usdc_deny_list`, which makes the test
/// USDC regulated as Mainnet's is). Sui aborts a transaction that sends USDC to
/// a denied address, so nothing here may send to one: a fill keeps a denied
/// builder's or referrer's fee in market cash and proceeds; a fill for a denied
/// trader refunds with reason 9; every refund to a denied trader (reasons 5, 7,
/// and 9, and the settlement drain) is parked in its record, which
/// `claim_parked` sends once the denial lifts; a denied winner's payout is
/// skipped and `pay_open` pays it later, as it does a payout skipped for short
/// cash. A global USDC pause denies every address the same way.
///
/// Move tests do not run Sui's end-of-transaction receive check, so a send to a
/// denied address would not abort here; the tests assert that none happens
/// (the funds stay parked) instead. Each deny-list change starts the epoch it
/// takes effect in.
///
/// Default-expiry orders are the 4m at-the-money mints of the accounting
/// suites: a 3 USDC budget, a 0.02 USDC order fee, premium 1_999_974 and
/// trading fee 20_000. Settlement scenarios use 100m mints with a 90 USDC
/// budget on the short-expiry market (expiry 240_000).
#[test_only]
module deepbook_predict_orders::deny_list_flow_tests;

use deepbook_predict::{constants, expiry_market, flow_test_helpers as helpers, test_constants};
use deepbook_predict_orders::{
    order_queue,
    queue,
    queue_event_views as events,
    queue_fixture::{Self as fixture, QueueTest}
};
use std::unit_test::{assert_eq, destroy};

const QUANTITY: u64 = 4_000_000;
const MAX_COST: u64 = 3_000_000;
const ORDER_FEE: u64 = 20_000;
/// The escrow of one 4m order: its 3m budget and the order fee.
const ESCROW: u64 = 3_020_000;
/// The premium floor(p * 4m) = 1_999_974 plus the 0.005 * 4m trading fee.
const ALL_IN_COST: u64 = 2_019_974;
/// Market cash one 4m fill adds: the premium, the trading fee, the order fee.
const MINT_CASH: u64 = 2_039_974;
/// min(0.1 * 20_000, 0.005 * 4m).
const BUILDER_FEE: u64 = 2_000;
/// The default 10% referral share of the 20_000 trading fee.
const REFERRAL_FEE: u64 = 2_000;
const BUILDER_CODE_INDEX: u64 = 0;
const HALF: u64 = 2_000_000;
const TAU: u64 = 121_000;
const SELL_TAU: u64 = 122_000;
const DEADLINE: u64 = 126_000;
const RESOLVE_ALL: u64 = 10;
/// The settlement scenarios' 100m order with a 90 USDC budget.
const BIG_QUANTITY: u64 = 100_000_000;
const BIG_MAX_COST: u64 = 90_000_000;
/// Its escrow: the 90m budget and the order fee.
const BIG_ESCROW: u64 = 90_020_000;
const EXPIRY: u64 = 240_000;
/// A placement at 120_999 lands on τ 121_800, a later cohort than 121_000.
const SECOND_PLACED_AT: u64 = 120_999;
const MISSING_RECORD: u64 = 99;

// === Fills ===

/// A denied builder and referrer receive nothing: both fees stay in market
/// cash, the fill goes through, and the trader is charged as usual.
#[test]
fun a_fill_keeps_a_denied_builders_and_referrers_fees_in_market_cash() {
    let (q, referrer) = fixture::new_referred();
    let (mut q, code_id) = q.link_builder_code(BUILDER_CODE_INDEX);
    let referrer_address = q.receive_address_of(&referrer);
    let mut q = q.deny(code_id.to_address()).deny(referrer_address);
    let record_id = q.enqueue_atm(QUANTITY, MAX_COST);
    q.commit_at(TAU, fixture::live_price());
    let cash_before = q.market().cash_balance();

    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fill = events::fills()[0];
    assert_eq!(fill.builder_fee(), BUILDER_FEE);
    assert_eq!(fill.referral_fee(), REFERRAL_FEE);
    assert_eq!(fill.amount(), ALL_IN_COST + BUILDER_FEE);
    // Normally the market gains MINT_CASH - REFERRAL_FEE and the builder fee
    // leaves; here both stay.
    assert_eq!(q.market().cash_balance(), cash_before + MINT_CASH + BUILDER_FEE);
    let record = q.record(record_id);
    assert_eq!(record.status(), order_queue::status_open());
    // The trader is not denied, so the change went out.
    assert_eq!(record.funds(), 0);
    assert!(events::parked().is_empty());
    q.assert_invariants();
    q.assert_backed();
    q.finish();
}

/// Reason 9: the trader is denied, so the mint is refused before anything
/// moves. Its whole escrow, order fee included, is parked in the record, which
/// finishes Refunded. Nothing is claimable while the trader is denied; once
/// the denial lifts, `claim_parked` sends it, once.
#[test]
fun a_denied_traders_mint_refunds_with_reason_9_into_parked_funds() {
    let mut q = fixture::new();
    let trader = q.receive_address();
    let account_id = q.account_id();
    let record_id = q.enqueue_atm(QUANTITY, MAX_COST);
    q.commit_at(TAU, fixture::live_price());
    let mut q = q.deny(trader);
    let cash_before = q.market().cash_balance();

    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let record = q.record(record_id);
    assert_eq!(record.status(), order_queue::status_refunded());
    assert_eq!(record.result().reason(), order_queue::reason_recipient_denied());
    assert_eq!(record.receipt_stage(), 0);
    assert_eq!(record.funds(), ESCROW);
    // The order fee comes back, so market cash is untouched.
    assert_eq!(q.market().cash_balance(), cash_before);
    let (waiting_cash_need, _) = q.ledger();
    assert_eq!(waiting_cash_need, 0);
    let refund = events::refunds()[0];
    assert_eq!(refund.refund_reason(), order_queue::reason_recipient_denied());
    assert_eq!(refund.refund_escrow_returned(), MAX_COST);
    assert_eq!(refund.refund_order_fee_returned(), ORDER_FEE);
    let parked = events::parked();
    assert_eq!(parked.length(), 1);
    assert_eq!(parked[0].funds_record_id(), record_id);
    assert_eq!(parked[0].funds_account_id(), account_id);
    assert_eq!(parked[0].funds_receive_address(), trader);
    assert_eq!(parked[0].funds_amount(), ESCROW);
    q.assert_invariants();
    assert_eq!(q.parked_sum(), ESCROW);

    // Still denied: nothing moves.
    assert_eq!(q.claim_parked(record_id), 0);
    assert_eq!(q.record(record_id).funds(), ESCROW);
    assert!(events::claimed().is_empty());

    let mut q = q.undeny(trader);
    assert_eq!(q.claim_parked(record_id), ESCROW);
    assert_eq!(q.record(record_id).funds(), 0);
    let claimed = events::claimed();
    assert_eq!(claimed.length(), 1);
    assert_eq!(claimed[0].funds_record_id(), record_id);
    assert_eq!(claimed[0].funds_receive_address(), trader);
    assert_eq!(claimed[0].funds_amount(), ESCROW);
    // A second claim finds nothing.
    assert_eq!(q.claim_parked(record_id), 0);
    assert_eq!(events::claimed().length(), 1);
    q.finish();
}

/// A denied trader's sell is refused with reason 9 too: the sell record goes
/// back to Open holding the whole position, with its order fee parked, and no
/// proceeds are paid.
#[test]
fun a_denied_traders_sell_refunds_with_reason_9_and_keeps_the_position() {
    let mut q = fixture::new();
    let trader = q.receive_address();
    let source = q.enqueue_atm(QUANTITY, MAX_COST);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);
    let order_id = q.record(source).position().order_id();
    q.refresh_oracle_at(TAU);
    let sell_id = q.enqueue_sell(source, HALF, 0, 0);
    q.commit_at(SELL_TAU, fixture::live_price());
    let mut q = q.deny(trader);
    let cash_before = q.market().cash_balance();

    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let sell = q.record(sell_id);
    assert_eq!(sell.status(), order_queue::status_open());
    assert_eq!(sell.result().reason(), order_queue::reason_recipient_denied());
    assert_eq!(sell.receipt_stage(), constants::receipt_stage_open!());
    assert_eq!(sell.position().order_id(), order_id);
    assert_eq!(sell.funds(), ORDER_FEE);
    assert_eq!(q.record(source).status(), order_queue::status_closed());
    assert_eq!(q.market().cash_balance(), cash_before);
    assert_eq!(q.market().payout_liability(), QUANTITY);
    let refund = events::refunds()[0];
    assert_eq!(refund.refund_reason(), order_queue::reason_recipient_denied());
    assert!(refund.refund_position_returned());
    assert_eq!(refund.refund_order_fee_returned(), ORDER_FEE);
    assert_eq!(events::parked()[0].funds_amount(), ORDER_FEE);
    q.assert_invariants();
    q.finish();
}

// === Refunds ===

/// The admin refund (reason 7) and the deadline refund (reason 5) both park
/// a denied trader's escrow in its record instead of sending it.
#[test]
fun deadline_and_admin_refunds_park_a_denied_traders_escrow() {
    let mut q = fixture::new();
    let trader = q.receive_address();
    let by_deadline = q.enqueue_atm(QUANTITY, MAX_COST);
    let by_admin = q.enqueue_atm(QUANTITY, MAX_COST);
    let mut q = q.deny(trader);

    q.admin_refund(vector[by_admin]);
    q.set_clock(DEADLINE);
    assert_eq!(q.refund(RESOLVE_ALL), 1);

    let admin = q.record(by_admin);
    assert_eq!(admin.status(), order_queue::status_refunded());
    assert_eq!(admin.result().reason(), order_queue::reason_admin());
    assert_eq!(admin.funds(), ESCROW);
    let deadline = q.record(by_deadline);
    assert_eq!(deadline.status(), order_queue::status_refunded());
    assert_eq!(deadline.result().reason(), order_queue::reason_deadline());
    assert_eq!(deadline.funds(), ESCROW);
    let parked = events::parked();
    assert_eq!(parked.length(), 2);
    assert_eq!(parked[0].funds_record_id(), by_admin);
    assert_eq!(parked[1].funds_record_id(), by_deadline);
    q.assert_invariants();
    assert_eq!(q.parked_sum(), 2 * ESCROW);
    q.finish();
}

/// The settlement drain parks a denied trader's refund and still finishes.
/// `cleanup` keeps the record while it holds parked funds and deletes it once
/// they are claimed.
#[test]
fun the_settlement_drain_parks_and_cleanup_waits_for_the_claim() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    let trader = q.receive_address();
    let record_id = q.enqueue_atm(BIG_QUANTITY, BIG_MAX_COST);
    let mut q = q.deny(trader);
    q.set_clock(EXPIRY);

    assert_eq!(q.settle_step(), queue::phase_pay());
    let record = q.record(record_id);
    assert_eq!(record.status(), order_queue::status_refunded());
    assert_eq!(record.result().reason(), order_queue::reason_deadline());
    assert_eq!(record.funds(), BIG_ESCROW);
    assert_eq!(events::parked()[0].funds_amount(), BIG_ESCROW);
    q.settle_market(spot_above_strike());
    assert_eq!(q.settle_step(), queue::phase_done());

    q.cleanup(vector[record_id]);
    assert!(q.queue().order(record_id).is_some());
    assert!(events::cleaned().is_empty());

    let mut q = q.undeny(trader);
    assert_eq!(q.claim_parked(record_id), BIG_ESCROW);
    q.cleanup(vector[record_id]);
    assert!(q.queue().order(record_id).is_none());
    assert_eq!(events::cleaned()[0], vector[record_id]);
    q.finish();
}

/// `claim_parked` never touches escrow: an unfinished record, an Open record
/// with nothing parked, and a missing record all return 0 and change nothing.
#[test]
fun claim_parked_leaves_escrow_and_unparked_records_alone() {
    let mut q = fixture::new();
    let filled = q.enqueue_atm(QUANTITY, MAX_COST);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);
    q.refresh_oracle_at(TAU);
    let waiting = q.enqueue_atm(QUANTITY, MAX_COST);

    assert_eq!(q.claim_parked(waiting), 0);
    assert_eq!(q.claim_parked(filled), 0);
    assert_eq!(q.claim_parked(MISSING_RECORD), 0);

    assert_eq!(q.record(waiting).status(), order_queue::status_pending());
    assert_eq!(q.record(waiting).funds(), ESCROW);
    assert!(events::claimed().is_empty());
    q.assert_invariants();
    q.finish();
}

// === Payouts ===

/// A denied winner's payout is skipped by the payout walk, which still
/// completes, and by `pay_open` while the denial lasts. Once it lifts,
/// `pay_open` pays the record and closes it; a second call changes nothing.
#[test]
fun a_denied_winners_skipped_payout_is_paid_by_pay_open_once_the_denial_lifts() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    let trader = q.receive_address();
    let account_id = q.account_id();
    let record_id = q.enqueue_atm(BIG_QUANTITY, BIG_MAX_COST);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);
    let order_id = q.record(record_id).position().order_id();
    q.settle_market(spot_above_strike());
    let mut q = q.deny(trader);
    let cash_before = q.market().cash_balance();

    assert_eq!(q.settle_step(), queue::phase_done());
    assert_eq!(q.record(record_id).status(), order_queue::status_open());
    assert_eq!(events::skipped()[0].payout(), BIG_QUANTITY);
    assert_eq!(events::payouts_completed_count(), 1);
    q.pay_open(record_id);
    assert_eq!(q.record(record_id).status(), order_queue::status_open());
    assert_eq!(events::skipped().length(), 2);
    assert_eq!(q.market().cash_balance(), cash_before);
    assert_eq!(q.market().payout_liability(), BIG_QUANTITY);

    let mut q = q.undeny(trader);
    q.pay_open(record_id);
    let record = q.record(record_id);
    assert_eq!(record.status(), order_queue::status_closed());
    assert_eq!(record.receipt_stage(), 0);
    let settled = events::settled();
    assert_eq!(settled.length(), 1);
    assert_eq!(settled[0].payout_record_id(), record_id);
    assert_eq!(settled[0].payout_account_id(), account_id);
    assert_eq!(settled[0].payout_order_id(), order_id);
    assert_eq!(settled[0].payout(), BIG_QUANTITY);
    assert_eq!(q.market().cash_balance(), cash_before - BIG_QUANTITY);
    assert_eq!(q.market().payout_liability(), 0);

    q.pay_open(record_id);
    assert_eq!(events::settled().length(), 1);
    assert_eq!(q.market().cash_balance(), cash_before - BIG_QUANTITY);
    q.finish();
}

/// `pay_open` also pays a record the payout walk skipped because the market was
/// short of cash, once the cash is back, after the walk completed. A missing ID
/// is left alone. Draining cash below a settled liability is not reachable in
/// production; a test-only Predict seam does it to pin the path.
#[test]
fun pay_open_pays_a_record_skipped_for_short_cash() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    let record_id = q.enqueue_atm(BIG_QUANTITY, BIG_MAX_COST);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);
    q.settle_market(spot_above_strike());
    let short_cash = BIG_QUANTITY - 1;
    let drain = q.market().cash_balance() - short_cash;
    destroy(expiry_market::take_market_cash_for_testing(q.market_mut(), drain));
    assert_eq!(q.settle_step(), queue::phase_done());
    assert_eq!(events::skipped().length(), 1);

    // Still short: skipped again.
    q.pay_open(record_id);
    assert_eq!(q.record(record_id).status(), order_queue::status_open());
    assert_eq!(events::skipped().length(), 2);

    q.seed_cash(1);
    q.pay_open(record_id);
    assert_eq!(q.record(record_id).status(), order_queue::status_closed());
    assert_eq!(events::settled()[0].payout(), BIG_QUANTITY);
    assert_eq!(q.market().cash_balance(), 0);
    assert_eq!(q.market().payout_liability(), 0);

    q.pay_open(MISSING_RECORD);
    assert_eq!(events::settled().length(), 1);
    q.finish();
}

#[test, expected_failure(abort_code = queue::EMarketNotSettled)]
fun pay_open_before_settlement_aborts() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    let record_id = q.enqueue_atm(BIG_QUANTITY, BIG_MAX_COST);
    q.commit_at(TAU, fixture::live_price());
    q.resolve(RESOLVE_ALL);
    q.pay_open(record_id);
    abort 999
}

// === Global pause ===

/// While USDC is globally paused every address counts as denied: the drain
/// parks a refund and the payout walk skips a winner. Once the pause lifts,
/// `claim_parked` and `pay_open` finish both.
#[test]
fun a_global_usdc_pause_parks_and_skips_until_it_lifts() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    let winner = q.enqueue_atm(BIG_QUANTITY, BIG_MAX_COST);
    q.refresh_oracle_at(SECOND_PLACED_AT);
    let waiting = q.enqueue_atm(BIG_QUANTITY, BIG_MAX_COST);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);
    let mut q = q.set_usdc_paused(true);
    q.set_clock(EXPIRY);

    assert_eq!(q.settle_step(), queue::phase_pay());
    assert_eq!(q.record(waiting).funds(), BIG_ESCROW);
    q.settle_market(spot_above_strike());
    assert_eq!(q.settle_step(), queue::phase_done());
    assert_eq!(q.record(winner).status(), order_queue::status_open());
    assert_eq!(q.claim_parked(waiting), 0);

    let mut q = q.set_usdc_paused(false);
    assert_eq!(q.claim_parked(waiting), BIG_ESCROW);
    q.pay_open(winner);
    assert_eq!(q.record(winner).status(), order_queue::status_closed());
    assert_eq!(events::settled()[0].payout(), BIG_QUANTITY);
    assert_eq!(q.parked_sum(), 0);
    q.finish();
}

// === Helpers ===

/// Settlement spot one tick above the strike: inside `(strike, +inf]`.
fun spot_above_strike(): u64 {
    (helpers::strike_tick() + 1) * test_constants::default_tick_size()
}
