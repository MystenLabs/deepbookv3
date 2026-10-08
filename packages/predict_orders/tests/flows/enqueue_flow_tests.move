// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Queued placement (`enqueue_*`) effects, one test per order kind: the record
/// each one writes with Predict's admitted receipt and its own escrow, the USDC
/// it takes from the account, the pins and cash need Predict's ledger adds, the
/// cohort spans, and the `OrderEnqueued` event.
///
/// Every scenario places at `now_ms = 120_000` under the fixture policy unless
/// it says otherwise, so τ = floor((120_000 + delay 1_000) / tick 200) * 200 =
/// 121_000 and the deadline is τ + stall timeout 5_000 = 126_000. Cash needs use
/// the market's snapshotted minimum entry probability 0.01 and backing-buffer
/// lambda 0.31.
#[test_only]
module deepbook_predict_orders::enqueue_flow_tests;

use deepbook_predict::{constants, flow_test_helpers as helpers, pricing::VolSnapshot, test_constants};
use deepbook_predict_orders::{
    order_queue::{Self, OrderRequest, HeldPosition, OrderTiming, OrderView},
    queue_events,
    queue_fixture::{Self as fixture, QueueTest}
};
use std::{bcs, unit_test::assert_eq};
use sui::event;

/// The policy's default flat order fee: 0.02 USDC.
const ORDER_FEE: u64 = 20_000;
/// Pyth Lazer `fixed_rate@200ms`, the policy's default channel.
const CHANNEL_200MS: u8 = 3;
/// τ for a placement at 120_000: floor(121_000 / 200) * 200.
const TAU_MS: u64 = 121_000;
/// τ + stall timeout 5_000; the expiry is far later.
const DEADLINE_MS: u64 = 126_000;
/// Default expiry 31_536_120_000 - max(no-trade window 2_000, stall 5_000 + 5_000).
const DEFAULT_CUTOFF_MS: u64 = 31_536_110_000;
/// The first record a queue hands out.
const FIRST_RECORD: u64 = 0;
/// A disabled request field (an unused limit, or a close-side floor of zero).
const UNUSED: u64 = 0;
/// No budget (sells), no subsidy bound, no required cash, no committed τ.
const NONE: u64 = 0;
/// An unfinished record carries no refund reason.
const NO_REASON: u8 = 0;
/// The payout-tree node a `(strike_tick, +inf]` range pins: +inf never gets one.
const ONE_NODE: u64 = 1;

// Exact-quantity mint of `mint_quantity` = 1_000 contracts.
/// All-in cap: 600 USDC, above the ~505 USDC an at-the-money fill costs.
const QUANTITY_MAX_COST: u64 = 600_000_000;
/// Probability cap 0.6, above the ~0.5 at-the-money entry.
const QUANTITY_MAX_PROBABILITY: u64 = 600_000_000;
/// min(max_cost 600_000_000, available 1_000_000_000 - fee 20_000, quantity
/// 1_000_000_000).
const QUANTITY_BUDGET: u64 = 600_000_000;
/// The t₀ pre-subsidy trading fee. At base fee 1 the Bernoulli rate rounds to
/// 0, so the 0.005 minimum fee binds a year from expiry with no ramp: 0.005 *
/// 1_000_000_000 = 5_000_000, below the budget.
const QUANTITY_SUBSIDY_BOUND: u64 = 5_000_000;
/// ceil(1_000_000_000 * (1 - 0.01)) + 1.
const QUANTITY_CASH_NEED: u64 = 990_000_001;

// Premium-budget mint.
/// 100 USDC of premium, about 198 contracts near 0.5.
const AMOUNT_MAX_PREMIUM: u64 = 100_000_000;
/// 100 contracts.
const AMOUNT_MIN_QUANTITY: u64 = 100_000_000;
/// 200 USDC all-in cap.
const AMOUNT_MAX_COST: u64 = 200_000_000;
/// min(max_cost 200_000_000, available 1_000_000_000 - fee 20_000).
const AMOUNT_BUDGET: u64 = 200_000_000;

// All-in-cost mint.
/// 100 USDC all-in, about 196 contracts near 0.5.
const COST_MAX_COST: u64 = 100_000_000;
/// 100 contracts.
const COST_MIN_QUANTITY: u64 = 100_000_000;
/// min(max_cost 100_000_000, available 1_000_000_000 - fee 20_000).
const COST_BUDGET: u64 = 100_000_000;

/// Budget-mint cash need over a 100 USDC premium bound, the exact-amount
/// min(max_premium 100_000_000, budget 200_000_000) and the exact-cost budget
/// alike: ceil((100_000_000 + 1) * (1 / 0.01 - 1)) + 1 = 100_000_001 * 99 + 1.
const BUDGET_100_CASH_NEED: u64 = 9_900_000_100;

// Sells.
/// ceil(1_000_000_000 * (1 - 0.31)) + 1.
const FULL_SELL_CASH_NEED: u64 = 690_000_001;
/// Half of the `mint_quantity` position.
const HALF_QUANTITY: u64 = 500_000_000;
/// ceil(500_000_000 * (1 - 0.31)) + 1.
const HALF_SELL_CASH_NEED: u64 = 345_000_001;
/// The fill and sell clock: one tick after τ 121_000.
const FILL_AT_MS: u64 = 121_200;
/// τ for a placement at 121_200: floor(122_200 / 200) * 200.
const FILL_TAU_MS: u64 = 122_200;
/// τ 122_200 + stall timeout 5_000.
const FILL_DEADLINE_MS: u64 = 127_200;

// Spans.
/// 100 contracts per order in the span scenario.
const SMALL_QUANTITY: u64 = 100_000_000;
/// All-in cap for 100 contracts near 0.5: 100 USDC.
const SMALL_MAX_COST: u64 = 100_000_000;
/// ceil(100_000_000 * (1 - 0.01)) + 1.
const SMALL_CASH_NEED: u64 = 99_000_001;
/// Still inside the 121_000 cohort: floor(121_100 / 200) * 200 = 121_000.
const SAME_COHORT_AT_MS: u64 = 120_100;
/// Opens the next cohort: floor(121_200 / 200) * 200 = 121_200.
const NEXT_COHORT_AT_MS: u64 = 120_200;
const NEXT_TAU_MS: u64 = 121_200;
const NEXT_DEADLINE_MS: u64 = 126_200;

/// Field-for-field mirror of `queue_events::OrderEnqueued`, compared by BCS.
public struct ExpectedOrderEnqueued has copy, drop {
    expiry_market_id: ID,
    record_id: u64,
    account_id: ID,
    kind: u8,
    request: OrderRequest,
    position: HeldPosition,
    timing: OrderTiming,
    vol: VolSnapshot,
    budget: u64,
    order_fee: u64,
    cash_need: u64,
    subsidy_bound: u64,
    builder_code_id: Option<ID>,
    referrer_account_id: Option<ID>,
    source_record_id: Option<u64>,
    market_cash: u64,
    required_cash: u64,
    waiting_cash_need: u64,
    onchain_timestamp_ms: u64,
}

// === Mints ===

/// An exact-quantity mint escrows min(max_cost, quantity, available - fee) plus
/// the fee in its own record, Predict pins its finite boundary and counts its
/// cash need, and the queue opens its first cohort and announces the record
/// with the market's unchanged cash.
#[test]
fun enqueue_exact_quantity_records_escrows_and_announces_the_order() {
    let mut q = fixture::new();
    let account_id = q.account_id();
    let receive_address = q.receive_address();
    // Before its first order the queue is empty and the market has no node.
    let (_, next_id, _, _) = q.queue().queue_heads();
    assert_eq!(next_id, FIRST_RECORD);
    let (_, nodes) = q.ledger();
    assert_eq!(nodes, NONE);

    let record_id = q.enqueue_quantity(
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        test_constants::mint_quantity(),
        QUANTITY_MAX_COST,
        QUANTITY_MAX_PROBABILITY,
    );
    assert_eq!(record_id, FIRST_RECORD);

    let record = q.record(record_id);
    let request = order_queue::new_request(
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        test_constants::mint_quantity(),
        UNUSED,
        UNUSED,
        QUANTITY_MAX_COST,
        QUANTITY_MAX_PROBABILITY,
        UNUSED,
        UNUSED,
    );
    assert_eq!(record.kind(), order_queue::kind_exact_quantity());
    assert_eq!(record.request(), request);
    assert_eq!(record.account_id(), account_id);
    assert_eq!(record.receive_address(), receive_address);
    assert_timing(&record, test_constants::now_ms(), TAU_MS, DEADLINE_MS, DEFAULT_CUTOFF_MS);
    assert_escrow(&record, QUANTITY_BUDGET, QUANTITY_SUBSIDY_BOUND, QUANTITY_CASH_NEED);
    assert_eq!(record.position(), order_queue::empty_position());
    assert_waiting_unpriced(&record);
    // The record holds Predict's admitted mint receipt and exactly its escrow.
    assert_eq!(record.receipt_stage(), constants::receipt_stage_mint!());
    assert_eq!(record.funds(), QUANTITY_BUDGET + ORDER_FEE);

    // The budget and fee left the account for the record, outside market cash.
    assert_eq!(q.balance(), test_constants::mint_deposit() - QUANTITY_BUDGET - ORDER_FEE);
    assert_eq!(q.market().cash_balance(), test_constants::default_seeded_expiry_cash());
    // The finite lower boundary now has a pinned node; +inf never gets one.
    let (waiting_cash_need, nodes) = q.ledger();
    assert_eq!(nodes, ONE_NODE);
    assert_eq!(waiting_cash_need, QUANTITY_CASH_NEED);

    let (resolve_head, next_id, last_tau_ms, last_committed_tau_ms) = q.queue().queue_heads();
    assert_eq!(resolve_head, FIRST_RECORD);
    assert_eq!(next_id, FIRST_RECORD + 1);
    assert_eq!(last_tau_ms, TAU_MS);
    assert_eq!(last_committed_tau_ms, NONE);
    let (cohorts, oldest_uncommitted, oldest_above_committed) = q.queue().waiting_cohorts();
    assert_eq!(cohorts, 1);
    assert_eq!(oldest_uncommitted, option::some(TAU_MS));
    assert_eq!(oldest_above_committed, option::some(TAU_MS));
    assert_pending(&q, 1, 0);
    assert_eq!(q.queue().waiting_orders(account_id), 1);
    assert_eq!(q.queue().oldest_unfinished_tau_ms(), option::some(TAU_MS));

    assert_one_enqueued(ExpectedOrderEnqueued {
        expiry_market_id: q.expiry_id(),
        record_id,
        account_id,
        kind: order_queue::kind_exact_quantity(),
        request,
        position: order_queue::empty_position(),
        timing: record.timing(),
        vol: receipt_vol(&q, record_id),
        budget: QUANTITY_BUDGET,
        order_fee: ORDER_FEE,
        cash_need: QUANTITY_CASH_NEED,
        subsidy_bound: QUANTITY_SUBSIDY_BOUND,
        builder_code_id: option::none(),
        referrer_account_id: option::none(),
        source_record_id: option::none(),
        market_cash: test_constants::default_seeded_expiry_cash(),
        required_cash: NONE,
        waiting_cash_need: QUANTITY_CASH_NEED,
        onchain_timestamp_ms: test_constants::now_ms(),
    });

    q.assert_invariants();
    q.assert_backed();
    q.finish();
}

/// A premium-budget mint escrows min(max_cost, available - fee) plus the fee, and
/// its cash need counts only min(max_premium, budget).
#[test]
fun enqueue_exact_amount_escrows_the_cost_cap_and_bounds_its_need_by_premium() {
    let mut q = fixture::new();
    let account_id = q.account_id();

    let record_id = q.enqueue_amount(
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        AMOUNT_MAX_PREMIUM,
        AMOUNT_MIN_QUANTITY,
        AMOUNT_MAX_COST,
    );
    assert_eq!(record_id, FIRST_RECORD);

    let record = q.record(record_id);
    let request = order_queue::new_request(
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        UNUSED,
        AMOUNT_MAX_PREMIUM,
        AMOUNT_MIN_QUANTITY,
        AMOUNT_MAX_COST,
        UNUSED,
        UNUSED,
        UNUSED,
    );
    assert_eq!(record.kind(), order_queue::kind_exact_amount());
    assert_eq!(record.request(), request);
    assert_timing(&record, test_constants::now_ms(), TAU_MS, DEADLINE_MS, DEFAULT_CUTOFF_MS);
    // The subsidy bound depends on the t₀ fill size; the exact-quantity test pins
    // the bound's rule.
    let subsidy_bound = record.escrow().subsidy_bound();
    assert_escrow(&record, AMOUNT_BUDGET, subsidy_bound, BUDGET_100_CASH_NEED);
    assert_waiting_unpriced(&record);
    assert_eq!(record.funds(), AMOUNT_BUDGET + ORDER_FEE);
    assert_eq!(q.balance(), test_constants::mint_deposit() - AMOUNT_BUDGET - ORDER_FEE);
    assert_pending(&q, 1, 0);
    let (waiting_cash_need, _) = q.ledger();
    assert_eq!(waiting_cash_need, BUDGET_100_CASH_NEED);

    assert_one_enqueued(ExpectedOrderEnqueued {
        expiry_market_id: q.expiry_id(),
        record_id,
        account_id,
        kind: order_queue::kind_exact_amount(),
        request,
        position: order_queue::empty_position(),
        timing: record.timing(),
        vol: receipt_vol(&q, record_id),
        budget: AMOUNT_BUDGET,
        order_fee: ORDER_FEE,
        cash_need: BUDGET_100_CASH_NEED,
        subsidy_bound,
        builder_code_id: option::none(),
        referrer_account_id: option::none(),
        source_record_id: option::none(),
        market_cash: test_constants::default_seeded_expiry_cash(),
        required_cash: NONE,
        waiting_cash_need: BUDGET_100_CASH_NEED,
        onchain_timestamp_ms: test_constants::now_ms(),
    });

    q.assert_invariants();
    q.finish();
}

/// An all-in-cost mint escrows min(max_cost, available - fee) plus the fee, and
/// its cash need counts the whole budget.
#[test]
fun enqueue_exact_cost_escrows_its_budget_and_needs_cash_for_all_of_it() {
    let mut q = fixture::new();

    let record_id = q.enqueue_cost(
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        COST_MAX_COST,
        COST_MIN_QUANTITY,
    );

    let record = q.record(record_id);
    let request = order_queue::new_request(
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        UNUSED,
        UNUSED,
        COST_MIN_QUANTITY,
        COST_MAX_COST,
        UNUSED,
        UNUSED,
        UNUSED,
    );
    assert_eq!(record.kind(), order_queue::kind_exact_cost());
    assert_eq!(record.request(), request);
    let subsidy_bound = record.escrow().subsidy_bound();
    assert_escrow(&record, COST_BUDGET, subsidy_bound, BUDGET_100_CASH_NEED);
    assert_waiting_unpriced(&record);
    assert_eq!(record.funds(), COST_BUDGET + ORDER_FEE);
    assert_eq!(q.balance(), test_constants::mint_deposit() - COST_BUDGET - ORDER_FEE);
    let (waiting_cash_need, _) = q.ledger();
    assert_eq!(waiting_cash_need, BUDGET_100_CASH_NEED);
    let events = event::events_by_type<queue_events::OrderEnqueued>();
    assert_eq!(events.length(), 1);

    q.assert_invariants();
    q.finish();
}

/// Orders in one channel tick share a cohort span and its deadline; the next
/// tick opens a new span. Pins on the same range add no node.
#[test]
fun orders_in_one_tick_share_a_cohort_and_the_next_tick_opens_another() {
    let mut q = fixture::new();
    let account_id = q.account_id();

    let first = q.enqueue_atm(SMALL_QUANTITY, SMALL_MAX_COST);
    q.set_clock(SAME_COHORT_AT_MS);
    let second = q.enqueue_atm(SMALL_QUANTITY, SMALL_MAX_COST);
    q.set_clock(NEXT_COHORT_AT_MS);
    let third = q.enqueue_atm(SMALL_QUANTITY, SMALL_MAX_COST);
    assert_eq!(first, FIRST_RECORD);
    assert_eq!(second, FIRST_RECORD + 1);
    assert_eq!(third, FIRST_RECORD + 2);

    assert_timing(
        &q.record(second),
        SAME_COHORT_AT_MS,
        TAU_MS,
        DEADLINE_MS,
        DEFAULT_CUTOFF_MS,
    );
    assert_timing(
        &q.record(third),
        NEXT_COHORT_AT_MS,
        NEXT_TAU_MS,
        NEXT_DEADLINE_MS,
        DEFAULT_CUTOFF_MS,
    );

    let (cohorts, oldest_uncommitted, _) = q.queue().waiting_cohorts();
    assert_eq!(cohorts, 2);
    assert_eq!(oldest_uncommitted, option::some(TAU_MS));
    let (_, next_id, last_tau_ms, _) = q.queue().queue_heads();
    assert_eq!(next_id, FIRST_RECORD + 3);
    assert_eq!(last_tau_ms, NEXT_TAU_MS);
    assert_pending(&q, 3, 0);
    assert_eq!(q.queue().waiting_orders(account_id), 3);
    let (waiting_cash_need, nodes) = q.ledger();
    assert_eq!(waiting_cash_need, 3 * SMALL_CASH_NEED);
    assert_eq!(nodes, ONE_NODE);

    q.assert_invariants();
    q.assert_backed();
    q.finish();
}

// === Sells ===

/// The trading pause and the market mint pause block new risk only: a partial
/// queued sell of an Open record still goes in, and moves the receipt and whole
/// position into the new record.
#[test]
fun enqueue_redeem_open_is_open_under_the_trading_and_mint_pauses() {
    let mut q = open_record_market();
    let held = q.record(FIRST_RECORD).position();
    q.set_trading_paused(true);
    q.set_mint_paused(true);

    let record_id = q.enqueue_sell(FIRST_RECORD, HALF_QUANTITY, UNUSED, UNUSED);

    let record = q.record(record_id);
    assert_eq!(record.kind(), order_queue::kind_redeem_open());
    assert_eq!(record.request().quantity(), HALF_QUANTITY);
    assert_eq!(record.escrow().cash_need(), HALF_SELL_CASH_NEED);
    assert_eq!(record.position(), held);
    assert_eq!(q.record(FIRST_RECORD).status(), order_queue::status_closed());
    assert_pending(&q, 0, 1);
    let (waiting_cash_need, _) = q.ledger();
    assert_eq!(waiting_cash_need, HALF_SELL_CASH_NEED);

    q.assert_invariants();
    q.assert_backed();
    q.finish();
}

/// Selling an Open record moves its receipt and position into the new record,
/// zeroes the source's copy and marks it Closed, and names the source in the
/// event.
#[test]
fun enqueue_redeem_open_closes_the_source_and_carries_its_position() {
    let mut q = open_record_market();
    let source_id = FIRST_RECORD;
    let account_id = q.account_id();
    let held = q.record(source_id).position();
    // A filled mint opens at its price tick.
    assert_eq!(held.opened_at_ms(), TAU_MS);
    let balance_before = q.balance();
    let cash_before = q.market().cash_balance();
    let required_before = q.market().required_cash();

    let record_id = q.enqueue_sell(source_id, test_constants::mint_quantity(), UNUSED, UNUSED);
    assert_eq!(record_id, source_id + 1);

    let source = q.record(source_id);
    assert_eq!(source.status(), order_queue::status_closed());
    assert_eq!(source.position(), order_queue::empty_position());
    // The source no longer holds a receipt; the sell record does.
    assert_eq!(source.receipt_stage(), 0);

    let record = q.record(record_id);
    let request = order_queue::new_request(
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        test_constants::mint_quantity(),
        UNUSED,
        UNUSED,
        UNUSED,
        UNUSED,
        UNUSED,
        UNUSED,
    );
    assert_eq!(record.kind(), order_queue::kind_redeem_open());
    assert_eq!(record.request(), request);
    assert_eq!(record.account_id(), account_id);
    assert_timing(&record, FILL_AT_MS, FILL_TAU_MS, FILL_DEADLINE_MS, DEFAULT_CUTOFF_MS);
    assert_escrow(&record, NONE, NONE, FULL_SELL_CASH_NEED);
    assert_eq!(record.position(), held);
    assert_waiting_unpriced(&record);
    assert_eq!(record.receipt_stage(), constants::receipt_stage_sell!());
    assert_eq!(record.funds(), ORDER_FEE);

    assert_eq!(q.balance(), balance_before - ORDER_FEE);
    assert_pending(&q, 0, 1);
    assert_eq!(q.queue().waiting_orders(account_id), 1);
    let (waiting_cash_need, _) = q.ledger();
    assert_eq!(waiting_cash_need, FULL_SELL_CASH_NEED);

    assert_one_enqueued(ExpectedOrderEnqueued {
        expiry_market_id: q.expiry_id(),
        record_id,
        account_id,
        kind: order_queue::kind_redeem_open(),
        request,
        position: held,
        timing: record.timing(),
        vol: receipt_vol(&q, record_id),
        budget: NONE,
        order_fee: ORDER_FEE,
        cash_need: FULL_SELL_CASH_NEED,
        subsidy_bound: NONE,
        builder_code_id: option::none(),
        referrer_account_id: option::none(),
        source_record_id: option::some(source_id),
        market_cash: cash_before,
        required_cash: required_before,
        waiting_cash_need: FULL_SELL_CASH_NEED,
        onchain_timestamp_ms: FILL_AT_MS,
    });

    q.assert_invariants();
    q.assert_backed();
    q.finish();
}

// === Helpers ===

/// The default market after one `mint_quantity` mint (record 0) filled at its
/// τ 121_000, in a fresh transaction at FILL_AT_MS with fresh feeds.
fun open_record_market(): QueueTest {
    let mut q = fixture::new();
    q.enqueue_quantity(
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        test_constants::mint_quantity(),
        QUANTITY_MAX_COST,
        std::u64::max_value!(),
    );
    q.commit_at(TAU_MS, fixture::live_price());
    q.set_clock(FILL_AT_MS);
    assert_eq!(q.resolve(1), 1);
    assert_eq!(q.record(FIRST_RECORD).status(), order_queue::status_open());
    let mut q = q.next_tx(test_constants::alice());
    q.refresh_oracle_at(FILL_AT_MS);
    q
}

/// The volatility snapshot Predict took for the record's receipt.
fun receipt_vol(q: &QueueTest, record_id: u64): VolSnapshot {
    let (_, _, _, _, _, _, _, vol) = q.queue().receipt_for_testing(record_id).receipt_info();
    vol
}

/// τ is also the earliest price time, and the channel is the policy default.
fun assert_timing(
    record: &OrderView,
    placed_at_ms: u64,
    tau_ms: u64,
    deadline_ms: u64,
    cutoff_ms: u64,
) {
    let timing = record.timing();
    assert_eq!(timing.placed_at_ms(), placed_at_ms);
    assert_eq!(timing.earliest_price_ms(), tau_ms);
    assert_eq!(timing.tau_ms(), tau_ms);
    assert_eq!(timing.deadline_ms(), deadline_ms);
    assert_eq!(timing.cutoff_ms(), cutoff_ms);
    assert_eq!(timing.pyth_channel(), CHANNEL_200MS);
}

/// Every order pays the default fee; commit sets the reserved subsidy.
fun assert_escrow(record: &OrderView, budget: u64, subsidy_bound: u64, cash_need: u64) {
    let escrow = record.escrow();
    assert_eq!(escrow.budget(), budget);
    assert_eq!(escrow.order_fee(), ORDER_FEE);
    assert_eq!(escrow.subsidy_bound(), subsidy_bound);
    assert_eq!(escrow.subsidy_reserved(), NONE);
    assert_eq!(escrow.cash_need(), cash_need);
}

/// A new record is Pending with no price and no result.
fun assert_waiting_unpriced(record: &OrderView) {
    assert_eq!(record.status(), order_queue::status_pending());
    assert_eq!(record.price(), order_queue::new_committed_price(NONE, NONE, NONE));
    let result = record.result();
    assert_eq!(result.reason(), NO_REASON);
    assert_eq!(result.result_quantity(), NONE);
    assert_eq!(result.result_amount(), NONE);
    assert_eq!(result.finished_at_ms(), NONE);
}

fun assert_pending(q: &QueueTest, mints: u64, sells: u64) {
    let (pending_mints, pending_sells) = q.queue().pending_counts();
    assert_eq!(pending_mints, mints);
    assert_eq!(pending_sells, sells);
}

/// Exactly one `OrderEnqueued` in this transaction, equal to `expected`.
fun assert_one_enqueued(expected: ExpectedOrderEnqueued) {
    let events = event::events_by_type<queue_events::OrderEnqueued>();
    assert_eq!(events.length(), 1);
    assert_eq!(bcs::to_bytes(&events[0]), bcs::to_bytes(&expected));
}
