// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The gates Predict's admission applies to queued placement, reached through
/// the companion: the cutover, the emergency freeze, the trading and market
/// mint pauses (mints only), the snapshot stage, and the witness allowlist. A
/// queued sell stays open under both pauses (`enqueue_flow_tests`) but not under
/// the freeze, the snapshot stage, or a removed witness. The builder-fee
/// cutover refuses only orders that name a builder: below it, plain mints and
/// sells still admit and fill.
#[test_only]
module deepbook_predict_orders::enqueue_gate_tests;

use deepbook_predict::{
    expiry_market,
    flow_test_helpers as helpers,
    protocol_config,
    test_constants
};
use deepbook_predict_orders::{
    order_queue,
    queue_event_views as events,
    queue_fixture::{Self as fixture, QueueTest}
};
use std::unit_test::{assert_eq, destroy};

const QUANTITY: u64 = 4_000_000;
const MAX_COST: u64 = 3_000_000;
/// The exact-cost and exact-amount budgets.
const COST_BUDGET: u64 = 3_000_000;
const AMOUNT_PREMIUM: u64 = 2_000_000;
const NO_MIN_QUANTITY: u64 = 0;
const TAU: u64 = 121_000;
const FILL_AT_MS: u64 = 121_200;
/// A sell placed at FILL_AT_MS lands on floor(122_200 / 200) * 200.
const SELL_TAU: u64 = 122_200;
const OPEN_RECORD: u64 = 0;
const NO_FLOOR: u64 = 0;
/// Pool liquidity, so a flush can start.
const SUPPLY_AMOUNT: u64 = 100_000_000_000;
/// The 4m at-the-money mint at the live price: every probability in the
/// reference digital's band floors p * 4m to 1_999_974, which a close of the
/// position also redeems, and the 0.005 minimum fee is 0.005 * 4m = 20_000.
const PREMIUM: u64 = 1_999_974;
const TRADING_FEE: u64 = 20_000;
/// PREMIUM + TRADING_FEE.
const ALL_IN_COST: u64 = 2_019_974;
/// A builder fee of 0.0005 per $1 contract, in FLOAT_SCALING, below the 5c cap.
const BUILDER_FEE_PER_CONTRACT: u64 = 500_000;
const BUILDER_CODE_INDEX: u64 = 0;

#[test, expected_failure(abort_code = protocol_config::ECutoverNotReached)]
fun enqueue_before_the_cutover_aborts() {
    let mut q = fixture::new_before_cutover();
    q.enqueue_atm(QUANTITY, MAX_COST);
    abort 999
}

/// Builder admission opens at a later cutover than queued placement; a plain
/// mint below it admits and fills with no builder fee.
#[test]
fun a_plain_mint_admits_and_fills_before_the_builder_fee_cutover() {
    let mut q = fixture::new_before_builder_fee_cutover();
    fill_one_mint(&mut q);

    let fill = events::fills()[0];
    assert_eq!(fill.record_id(), OPEN_RECORD);
    assert_eq!(fill.builder_fee(), 0);
    assert_eq!(fill.amount(), ALL_IN_COST);
    assert_eq!(q.record(OPEN_RECORD).status(), order_queue::status_open());
    q.finish();
}

#[test, expected_failure(abort_code = protocol_config::EBuilderFeeCutoverNotReached)]
fun a_builder_mint_before_the_builder_fee_cutover_aborts() {
    let q = fixture::new_before_builder_fee_cutover();
    let (mut q, code_id) = q.new_builder_code(BUILDER_CODE_INDEX);
    q.enqueue_atm_with_builder(QUANTITY, MAX_COST, code_id, BUILDER_FEE_PER_CONTRACT);
    abort 999
}

#[test]
fun a_plain_sell_admits_and_fills_before_the_builder_fee_cutover() {
    let mut q = with_open_record(fixture::new_before_builder_fee_cutover());
    let sell_id = q.enqueue_sell(OPEN_RECORD, QUANTITY, NO_FLOOR, NO_FLOOR);
    assert_eq!(q.record(sell_id).status(), order_queue::status_pending());
    assert_eq!(q.builder_fee_of(sell_id), 0);

    q.commit_at(SELL_TAU, fixture::live_price());
    assert_eq!(q.resolve(1), 1);

    let fills = events::fills();
    let fill = fills[fills.length() - 1];
    assert_eq!(fill.record_id(), sell_id);
    assert_eq!(fill.builder_fee(), 0);
    assert_eq!(fill.amount(), PREMIUM - TRADING_FEE);
    assert_eq!(q.record(sell_id).status(), order_queue::status_closed());
    q.finish();
}

#[test, expected_failure(abort_code = protocol_config::EBuilderFeeCutoverNotReached)]
fun a_builder_sell_before_the_builder_fee_cutover_aborts() {
    let q = fixture::new_before_builder_fee_cutover();
    let (q, code_id) = q.new_builder_code(BUILDER_CODE_INDEX);
    let mut q = with_open_record(q);
    q.enqueue_sell_with_builder(
        OPEN_RECORD,
        QUANTITY,
        NO_FLOOR,
        NO_FLOOR,
        code_id,
        BUILDER_FEE_PER_CONTRACT,
    );
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EProtocolFrozen)]
fun enqueue_mint_under_the_freeze_aborts() {
    let mut q = fixture::new();
    q.set_frozen(true);
    q.enqueue_atm(QUANTITY, MAX_COST);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EProtocolFrozen)]
fun enqueue_sell_under_the_freeze_aborts() {
    let mut q = open_record_market();
    q.set_frozen(true);
    q.enqueue_sell(OPEN_RECORD, QUANTITY, NO_FLOOR, NO_FLOOR);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::ETradingPaused)]
fun enqueue_mint_under_the_trading_pause_aborts() {
    let mut q = fixture::new();
    q.set_trading_paused(true);
    q.enqueue_cost(helpers::strike_tick(), helpers::pos_inf_tick(), COST_BUDGET, NO_MIN_QUANTITY);
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EMintPaused)]
fun enqueue_mint_under_the_market_mint_pause_aborts() {
    let mut q = fixture::new();
    q.set_mint_paused(true);
    q.enqueue_amount(
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        AMOUNT_PREMIUM,
        NO_MIN_QUANTITY,
        MAX_COST,
    );
    abort 999
}

/// A mint composed into the keeper's open snapshot stage is refused.
#[test, expected_failure(abort_code = protocol_config::ESnapshotInProgress)]
fun enqueue_mint_inside_the_snapshot_stage_aborts() {
    let mut q = fixture::new_with_pool(SUPPLY_AMOUNT);
    let stage = q.start_snapshot();
    q.enqueue_atm(QUANTITY, MAX_COST);
    destroy(stage);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::ESnapshotInProgress)]
fun enqueue_sell_inside_the_snapshot_stage_aborts() {
    let mut q = fixture::new_with_pool(SUPPLY_AMOUNT);
    fill_one_mint(&mut q);
    let mut q = q.next_tx(test_constants::alice());
    q.refresh_oracle_at(FILL_AT_MS);
    let stage = q.start_snapshot();
    q.enqueue_sell(OPEN_RECORD, QUANTITY, NO_FLOOR, NO_FLOOR);
    destroy(stage);
    abort 999
}

/// With the witness removed Predict refuses every admission.
#[test, expected_failure(abort_code = protocol_config::EOrderFlowNotAllowed)]
fun enqueue_mint_with_the_witness_removed_aborts() {
    let mut q = fixture::new();
    q.set_witness(false);
    q.enqueue_atm(QUANTITY, MAX_COST);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EOrderFlowNotAllowed)]
fun enqueue_sell_with_the_witness_removed_aborts() {
    let mut q = open_record_market();
    q.set_witness(false);
    q.enqueue_sell(OPEN_RECORD, QUANTITY, NO_FLOOR, NO_FLOOR);
    abort 999
}

// === Helpers ===

fun fill_one_mint(q: &mut QueueTest) {
    q.enqueue_atm(QUANTITY, MAX_COST);
    q.commit_at(TAU, fixture::live_price());
    q.set_clock(FILL_AT_MS);
    assert_eq!(q.resolve(1), 1);
}

/// Record 0 Open, in a fresh transaction with fresh feeds.
fun open_record_market(): QueueTest {
    with_open_record(fixture::new())
}

/// `q` with record 0 a filled mint, Open, in a fresh transaction with fresh
/// feeds.
fun with_open_record(mut q: QueueTest): QueueTest {
    fill_one_mint(&mut q);
    let mut q = q.next_tx(test_constants::alice());
    q.refresh_oracle_at(FILL_AT_MS);
    q
}
