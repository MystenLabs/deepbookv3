// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Queued placement (`enqueue_*`) effects, one test per order kind: the record
/// each one writes, the USDC it escrows, the pins and cohort spans it adds, and
/// the `OrderEnqueued` event it emits.
///
/// Every scenario places at `now_ms = 120_000` under the default policy unless it
/// says otherwise, so τ = ⌊(120_000 + delay 1_000) / tick 200⌋ × 200 = 121_000 and
/// the deadline is τ + stall timeout 5_000 = 126_000. Cash needs use the market's
/// snapshotted minimum entry probability 0.01 and backing-buffer lambda 0.31.
#[test_only]
module deepbook_predict::enqueue_flow_tests;

use deepbook_predict::{
    enqueue_test_helpers as enqueue,
    expiry_market,
    flow_test_helpers::{Self as helpers, AccountBundle},
    order_events,
    order_queue::{Self, OrderRequest, HeldPosition, OrderTiming, QueuedOrder},
    pricing::VolSnapshot,
    queue_test_helpers as queue,
    test_constants
};
use std::{bcs, unit_test::assert_eq};
use sui::event;
use usdc::usdc::USDC;

/// The policy's default flat order fee: 0.02 USDC.
const ORDER_FEE: u64 = 20_000;
/// Pyth Lazer `fixed_rate@200ms`, the policy's default channel.
const CHANNEL_200MS: u8 = 3;
/// τ for a placement at 120_000: ⌊121_000 / 200⌋ × 200.
const TAU_MS: u64 = 121_000;
/// τ + stall timeout 5_000; the expiry is far later.
const DEADLINE_MS: u64 = 126_000;
/// Default expiry 31_536_120_000 − max(no-trade window 2_000, stall 5_000 + 5_000).
const DEFAULT_CUTOFF_MS: u64 = 31_536_110_000;
/// The first record a market's book hands out.
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
/// The t₀ pre-subsidy trading fee. Only the finite lower leg is charged; at base
/// fee 1 the Bernoulli rate rounds to 0, so the 0.005 minimum fee binds, a year
/// from expiry carries no ramp: 0.005 × 1_000_000_000 = 5_000_000, below the
/// budget.
const QUANTITY_SUBSIDY_BOUND: u64 = 5_000_000;
/// ⌈1_000_000_000 × (1 - 0.01)⌉ + 1.
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
/// alike: ⌈(100_000_000 + 1) × (1 / 0.01 - 1)⌉ + 1 = 100_000_001 × 99 + 1.
const BUDGET_100_CASH_NEED: u64 = 9_900_000_100;

// Sells.
/// ⌈1_000_000_000 × (1 - 0.31)⌉ + 1.
const FULL_SELL_CASH_NEED: u64 = 690_000_001;
/// Half of the `mint_quantity` position.
const HALF_QUANTITY: u64 = 500_000_000;
/// ⌈500_000_000 × (1 - 0.31)⌉ + 1.
const HALF_SELL_CASH_NEED: u64 = 345_000_001;
/// The fill clock for the Open-record scenario: one tick after τ 121_000.
const FILL_AT_MS: u64 = 121_200;
/// τ for a placement at 121_200: ⌊122_200 / 200⌋ × 200.
const FILL_TAU_MS: u64 = 122_200;
/// τ 122_200 + stall timeout 5_000.
const FILL_DEADLINE_MS: u64 = 127_200;

// Spans.
/// 100 contracts per order in the span scenario.
const SMALL_QUANTITY: u64 = 100_000_000;
/// All-in cap for 100 contracts near 0.5: 100 USDC.
const SMALL_MAX_COST: u64 = 100_000_000;
/// ⌈100_000_000 × (1 - 0.01)⌉ + 1.
const SMALL_CASH_NEED: u64 = 99_000_001;
/// Still inside the 121_000 cohort: ⌊121_100 / 200⌋ × 200 = 121_000.
const SAME_COHORT_AT_MS: u64 = 120_100;
/// Opens the next cohort: ⌊121_200 / 200⌋ × 200 = 121_200.
const NEXT_COHORT_AT_MS: u64 = 120_200;
const NEXT_TAU_MS: u64 = 121_200;
const NEXT_DEADLINE_MS: u64 = 126_200;

/// Field-for-field mirror of `order_events::OrderEnqueued`, compared by BCS.
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
}

// === Mints ===

/// An exact-quantity mint escrows min(max_cost, quantity, available - fee) plus
/// the fee, pins its finite boundary, opens the market's book and first cohort,
/// and announces the record with the market's unchanged cash.
#[test]
fun enqueue_exact_quantity_records_escrows_and_announces_the_order() {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let account_id = helpers::account_id_bundle(&account);
    let receive_address = wrapper_address(&mut account);
    // Before its first order the market has no book: an empty queue and no node.
    let (_, next_id, _, _) = market.market().queue_heads();
    assert_eq!(next_id, FIRST_RECORD);
    assert_eq!(market.market().payout_tree_node_count(), NONE);

    let record_id = queue::enqueue_exact_quantity(
        &mut fx,
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        test_constants::mint_quantity(),
        QUANTITY_MAX_COST,
        QUANTITY_MAX_PROBABILITY,
    );
    assert_eq!(record_id, FIRST_RECORD);

    let record = market.market().queued_order(record_id).destroy_some();
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
    assert_parties(&record, account_id, receive_address);
    assert_timing(&record, test_constants::now_ms(), TAU_MS, DEADLINE_MS, DEFAULT_CUTOFF_MS);
    assert_escrow(&record, QUANTITY_BUDGET, QUANTITY_SUBSIDY_BOUND, QUANTITY_CASH_NEED);
    assert_eq!(record.position(), order_queue::empty_position());
    assert_waiting_unpriced(&record);
    // Commit finds this feed in each Lazer update.
    assert_eq!(record.vol().pyth_source_id(), test_constants::pyth_feed_id());

    // The budget and fee left the account for escrow, outside market cash.
    assert_eq!(
        fx.account_balance_bundle<USDC>(&account),
        test_constants::mint_deposit() - QUANTITY_BUDGET - ORDER_FEE,
    );
    assert_eq!(
        expiry_market::queue_escrow_for_testing(market.market()),
        QUANTITY_BUDGET + ORDER_FEE,
    );
    assert_eq!(market.market().cash_balance(), test_constants::default_seeded_expiry_cash());
    // The finite lower boundary now has a pinned node; +inf never gets one.
    assert_eq!(market.market().payout_tree_node_count(), ONE_NODE);

    let (resolve_head, next_id, last_tau_ms, last_committed_tau_ms) = market.market().queue_heads();
    assert_eq!(resolve_head, FIRST_RECORD);
    assert_eq!(next_id, FIRST_RECORD + 1);
    assert_eq!(last_tau_ms, TAU_MS);
    assert_eq!(last_committed_tau_ms, NONE);
    let (cohorts, oldest_uncommitted, oldest_above_committed) = market.market().waiting_cohorts();
    assert_eq!(cohorts, 1);
    assert_eq!(oldest_uncommitted, option::some(TAU_MS));
    assert_eq!(oldest_above_committed, option::some(TAU_MS));
    assert_pending(&market, 1, 0);
    assert_eq!(market.market().waiting_orders(account_id), 1);
    assert_eq!(market.market().waiting_cash_need(), QUANTITY_CASH_NEED);

    assert_one_enqueued(ExpectedOrderEnqueued {
        expiry_market_id: expiry_id,
        record_id,
        account_id,
        kind: order_queue::kind_exact_quantity(),
        request,
        position: order_queue::empty_position(),
        timing: record.timing(),
        vol: record.vol(),
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
    });

    queue::assert_queue_invariants(market.market());
    helpers::assert_market_backed_bundle(&market);
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// A premium-budget mint escrows min(max_cost, available - fee) plus the fee, and
/// its cash need counts only min(max_premium, budget).
#[test]
fun enqueue_exact_amount_escrows_the_cost_cap_and_bounds_its_need_by_premium() {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let account_id = helpers::account_id_bundle(&account);
    let receive_address = wrapper_address(&mut account);

    let record_id = queue::enqueue_exact_amount(
        &mut fx,
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        AMOUNT_MAX_PREMIUM,
        AMOUNT_MIN_QUANTITY,
        AMOUNT_MAX_COST,
    );
    assert_eq!(record_id, FIRST_RECORD);

    let record = market.market().queued_order(record_id).destroy_some();
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
    assert_parties(&record, account_id, receive_address);
    assert_timing(&record, test_constants::now_ms(), TAU_MS, DEADLINE_MS, DEFAULT_CUTOFF_MS);
    // The subsidy bound depends on the t₀ fill size; the exact-quantity test pins
    // the bound's rule.
    let subsidy_bound = record.escrow().subsidy_bound();
    assert_escrow(&record, AMOUNT_BUDGET, subsidy_bound, BUDGET_100_CASH_NEED);
    assert_eq!(record.position(), order_queue::empty_position());
    assert_waiting_unpriced(&record);

    assert_eq!(
        fx.account_balance_bundle<USDC>(&account),
        test_constants::mint_deposit() - AMOUNT_BUDGET - ORDER_FEE,
    );
    assert_eq!(expiry_market::queue_escrow_for_testing(market.market()), AMOUNT_BUDGET + ORDER_FEE);
    assert_pending(&market, 1, 0);
    assert_eq!(market.market().waiting_cash_need(), BUDGET_100_CASH_NEED);

    assert_one_enqueued(ExpectedOrderEnqueued {
        expiry_market_id: expiry_id,
        record_id,
        account_id,
        kind: order_queue::kind_exact_amount(),
        request,
        position: order_queue::empty_position(),
        timing: record.timing(),
        vol: record.vol(),
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
    });

    queue::assert_queue_invariants(market.market());
    helpers::assert_market_backed_bundle(&market);
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// An all-in-cost mint escrows min(max_cost, available - fee) plus the fee, and
/// its cash need counts the whole budget.
#[test]
fun enqueue_exact_cost_escrows_its_budget_and_needs_cash_for_all_of_it() {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let account_id = helpers::account_id_bundle(&account);
    let receive_address = wrapper_address(&mut account);

    let record_id = queue::enqueue_exact_cost(
        &mut fx,
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        COST_MAX_COST,
        COST_MIN_QUANTITY,
    );
    assert_eq!(record_id, FIRST_RECORD);

    let record = market.market().queued_order(record_id).destroy_some();
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
    assert_parties(&record, account_id, receive_address);
    assert_timing(&record, test_constants::now_ms(), TAU_MS, DEADLINE_MS, DEFAULT_CUTOFF_MS);
    let subsidy_bound = record.escrow().subsidy_bound();
    assert_escrow(&record, COST_BUDGET, subsidy_bound, BUDGET_100_CASH_NEED);
    assert_eq!(record.position(), order_queue::empty_position());
    assert_waiting_unpriced(&record);

    assert_eq!(
        fx.account_balance_bundle<USDC>(&account),
        test_constants::mint_deposit() - COST_BUDGET - ORDER_FEE,
    );
    assert_eq!(expiry_market::queue_escrow_for_testing(market.market()), COST_BUDGET + ORDER_FEE);
    assert_pending(&market, 1, 0);
    assert_eq!(market.market().waiting_cash_need(), BUDGET_100_CASH_NEED);

    assert_one_enqueued(ExpectedOrderEnqueued {
        expiry_market_id: expiry_id,
        record_id,
        account_id,
        kind: order_queue::kind_exact_cost(),
        request,
        position: order_queue::empty_position(),
        timing: record.timing(),
        vol: record.vol(),
        budget: COST_BUDGET,
        order_fee: ORDER_FEE,
        cash_need: BUDGET_100_CASH_NEED,
        subsidy_bound,
        builder_code_id: option::none(),
        referrer_account_id: option::none(),
        source_record_id: option::none(),
        market_cash: test_constants::default_seeded_expiry_cash(),
        required_cash: NONE,
        waiting_cash_need: BUDGET_100_CASH_NEED,
    });

    queue::assert_queue_invariants(market.market());
    helpers::assert_market_backed_bundle(&market);
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// Orders in one channel tick share a cohort span and its deadline; the next
/// tick opens a new span. Pins on the same range add no node.
#[test]
fun orders_in_one_tick_share_a_cohort_and_the_next_tick_opens_another() {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let account_id = helpers::account_id_bundle(&account);

    let first = enqueue_small(&mut fx, &mut market, &mut account);
    fx.set_clock_for_testing(SAME_COHORT_AT_MS);
    let second = enqueue_small(&mut fx, &mut market, &mut account);
    fx.set_clock_for_testing(NEXT_COHORT_AT_MS);
    let third = enqueue_small(&mut fx, &mut market, &mut account);
    assert_eq!(first, FIRST_RECORD);
    assert_eq!(second, FIRST_RECORD + 1);
    assert_eq!(third, FIRST_RECORD + 2);

    let second_record = market.market().queued_order(second).destroy_some();
    assert_timing(&second_record, SAME_COHORT_AT_MS, TAU_MS, DEADLINE_MS, DEFAULT_CUTOFF_MS);
    let third_record = market.market().queued_order(third).destroy_some();
    assert_timing(
        &third_record,
        NEXT_COHORT_AT_MS,
        NEXT_TAU_MS,
        NEXT_DEADLINE_MS,
        DEFAULT_CUTOFF_MS,
    );

    let (cohorts, oldest_uncommitted, _) = market.market().waiting_cohorts();
    assert_eq!(cohorts, 2);
    assert_eq!(oldest_uncommitted, option::some(TAU_MS));
    let (_, next_id, last_tau_ms, _) = market.market().queue_heads();
    assert_eq!(next_id, FIRST_RECORD + 3);
    assert_eq!(last_tau_ms, NEXT_TAU_MS);
    assert_pending(&market, 3, 0);
    assert_eq!(market.market().waiting_orders(account_id), 3);
    assert_eq!(market.market().waiting_cash_need(), 3 * SMALL_CASH_NEED);
    assert_eq!(market.market().payout_tree_node_count(), ONE_NODE);

    queue::assert_queue_invariants(market.market());
    helpers::assert_market_backed_bundle(&market);
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === Sells ===

/// The trading pause and the market mint pause block new risk only: a partial
/// queued sell of an Open record still goes in, and moves the whole position
/// into the new record.
#[test]
fun enqueue_redeem_open_is_open_under_the_trading_and_mint_pauses() {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    let source_id = enqueue::fill_exact_quantity(
        &mut fx,
        expiry_id,
        &trader,
        test_constants::mint_quantity(),
        QUANTITY_MAX_COST,
        FILL_AT_MS,
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.advance_live_oracle_bundle_to(&mut market, test_constants::default_live_price(), FILL_AT_MS);
    let held = market.market().queued_order(source_id).destroy_some().position();
    fx.set_trading_paused_bundle(&mut market, true);
    fx.set_expiry_mint_paused_bundle(&mut market, true);

    let record_id = queue::enqueue_redeem_open(
        &mut fx,
        &mut market,
        &mut account,
        source_id,
        HALF_QUANTITY,
        UNUSED,
        UNUSED,
    );

    let record = market.market().queued_order(record_id).destroy_some();
    assert_eq!(record.kind(), order_queue::kind_redeem_open());
    assert_eq!(record.request().quantity(), HALF_QUANTITY);
    assert_eq!(record.escrow().cash_need(), HALF_SELL_CASH_NEED);
    assert_eq!(record.position(), held);
    let source = market.market().queued_order(source_id).destroy_some();
    assert_eq!(source.status(), order_queue::status_closed());
    assert_pending(&market, 0, 1);

    queue::assert_queue_invariants(market.market());
    helpers::assert_market_backed_bundle(&market);
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// Selling an Open record moves its position into the new record,
/// zeroes the source's copy and marks it Closed, and names the source in the
/// event.
#[test]
fun enqueue_redeem_open_closes_the_source_and_carries_its_position() {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    let source_id = enqueue::fill_exact_quantity(
        &mut fx,
        expiry_id,
        &trader,
        test_constants::mint_quantity(),
        QUANTITY_MAX_COST,
        FILL_AT_MS,
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.advance_live_oracle_bundle_to(&mut market, test_constants::default_live_price(), FILL_AT_MS);
    let account_id = helpers::account_id_bundle(&account);
    let receive_address = wrapper_address(&mut account);
    let held = market.market().queued_order(source_id).destroy_some().position();
    // A filled mint opens at its price tick.
    assert_eq!(held.opened_at_ms(), TAU_MS);
    let balance_before = fx.account_balance_bundle<USDC>(&account);
    let cash_before = market.market().cash_balance();
    let required_before = market.market().required_cash();

    let record_id = queue::enqueue_redeem_open(
        &mut fx,
        &mut market,
        &mut account,
        source_id,
        test_constants::mint_quantity(),
        UNUSED,
        UNUSED,
    );
    assert_eq!(record_id, source_id + 1);

    let source = market.market().queued_order(source_id).destroy_some();
    assert_eq!(source.status(), order_queue::status_closed());
    assert_eq!(source.position(), order_queue::empty_position());

    let record = market.market().queued_order(record_id).destroy_some();
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
    assert_parties(&record, account_id, receive_address);
    assert_timing(
        &record,
        FILL_AT_MS,
        FILL_TAU_MS,
        FILL_DEADLINE_MS,
        DEFAULT_CUTOFF_MS,
    );
    assert_escrow(&record, NONE, NONE, FULL_SELL_CASH_NEED);
    assert_eq!(record.position(), held);
    assert_waiting_unpriced(&record);

    assert_eq!(fx.account_balance_bundle<USDC>(&account), balance_before - ORDER_FEE);
    assert_eq!(expiry_market::queue_escrow_for_testing(market.market()), ORDER_FEE);
    assert_pending(&market, 0, 1);
    assert_eq!(market.market().waiting_orders(account_id), 1);
    assert_eq!(market.market().waiting_cash_need(), FULL_SELL_CASH_NEED);

    assert_one_enqueued(ExpectedOrderEnqueued {
        expiry_market_id: expiry_id,
        record_id,
        account_id,
        kind: order_queue::kind_redeem_open(),
        request,
        position: held,
        timing: record.timing(),
        vol: record.vol(),
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
    });

    queue::assert_queue_invariants(market.market());
    helpers::assert_market_backed_bundle(&market);
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === Helpers ===

/// The wrapper's address, where refunds and proceeds are delivered.
fun wrapper_address(account: &mut AccountBundle): address {
    let (wrapper, _) = account.account_parts_mut();
    wrapper.id().to_address()
}

/// An exact-quantity mint of 100 contracts over `(strike_tick, +inf]`.
fun enqueue_small(
    fx: &mut helpers::Fixture,
    market: &mut helpers::MarketBundle,
    account: &mut AccountBundle,
): u64 {
    queue::enqueue_exact_quantity(
        fx,
        market,
        account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        SMALL_QUANTITY,
        SMALL_MAX_COST,
        std::u64::max_value!(),
    )
}

/// The account facts every alice order snapshots: no referrer and no builder
/// code in these fixtures.
fun assert_parties(record: &QueuedOrder, account_id: ID, receive_address: address) {
    let parties = record.parties();
    assert_eq!(parties.account_id(), account_id);
    assert_eq!(parties.owner(), test_constants::alice());
    assert_eq!(parties.receive_address(), receive_address);
    assert_eq!(parties.referrer_account_id(), option::none());
    assert_eq!(parties.referrer_receive_address(), option::none());
    assert_eq!(parties.builder_code_id(), option::none());
}

/// τ is also the earliest price time, and the channel is the policy default.
fun assert_timing(
    record: &QueuedOrder,
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

/// Every order pays the default fee; commit sets the subsidy rate and reserve.
fun assert_escrow(record: &QueuedOrder, budget: u64, subsidy_bound: u64, cash_need: u64) {
    let escrow = record.escrow();
    assert_eq!(escrow.budget(), budget);
    assert_eq!(escrow.order_fee(), ORDER_FEE);
    assert_eq!(escrow.subsidy_bound(), subsidy_bound);
    assert_eq!(escrow.subsidy_rate(), NONE);
    assert_eq!(escrow.subsidy_reserved(), NONE);
    assert_eq!(escrow.cash_need(), cash_need);
}

/// A new record is Pending with no price and no result.
fun assert_waiting_unpriced(record: &QueuedOrder) {
    assert_eq!(record.status(), order_queue::status_pending());
    assert_eq!(record.price(), order_queue::new_committed_price(NONE, NONE, NONE));
    let result = record.result();
    assert_eq!(result.reason(), NO_REASON);
    assert_eq!(result.result_quantity(), NONE);
    assert_eq!(result.result_amount(), NONE);
    assert_eq!(result.finished_at_ms(), NONE);
}

fun assert_pending(market: &helpers::MarketBundle, mints: u64, sells: u64) {
    let (pending_mints, pending_sells) = market.market().pending_counts();
    assert_eq!(pending_mints, mints);
    assert_eq!(pending_sells, sells);
}

/// Exactly one `OrderEnqueued` in this transaction, equal to `expected`.
fun assert_one_enqueued(expected: ExpectedOrderEnqueued) {
    let events = event::events_by_type<order_events::OrderEnqueued>();
    assert_eq!(events.length(), 1);
    assert_eq!(bcs::to_bytes(&events[0]), bcs::to_bytes(&expected));
}
