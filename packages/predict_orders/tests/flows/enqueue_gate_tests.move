// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The gates Predict's admission applies to queued placement, reached through
/// the companion: the cutover, the emergency freeze, the trading and market
/// mint pauses (mints only), the snapshot stage, and the witness allowlist. A
/// queued sell stays open under both pauses (`enqueue_flow_tests`) but not under
/// the freeze, the snapshot stage, or a removed witness.
#[test_only]
module deepbook_predict_orders::enqueue_gate_tests;

use deepbook_predict::{
    expiry_market,
    flow_test_helpers as helpers,
    protocol_config,
    test_constants
};
use deepbook_predict_orders::queue_fixture::{Self as fixture, QueueTest};
use std::unit_test::{assert_eq, destroy};

const QUANTITY: u64 = 4_000_000;
const MAX_COST: u64 = 3_000_000;
/// The exact-cost and exact-amount budgets.
const COST_BUDGET: u64 = 3_000_000;
const AMOUNT_PREMIUM: u64 = 2_000_000;
const NO_MIN_QUANTITY: u64 = 0;
const TAU: u64 = 121_000;
const FILL_AT_MS: u64 = 121_200;
const OPEN_RECORD: u64 = 0;
const NO_FLOOR: u64 = 0;
/// Pool liquidity, so a flush can start.
const SUPPLY_AMOUNT: u64 = 100_000_000_000;

#[test, expected_failure(abort_code = protocol_config::ECutoverNotReached)]
fun enqueue_before_the_cutover_aborts() {
    let mut q = fixture::new_before_cutover();
    q.enqueue_atm(QUANTITY, MAX_COST);
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
    let mut q = fixture::new();
    fill_one_mint(&mut q);
    let mut q = q.next_tx(test_constants::alice());
    q.refresh_oracle_at(FILL_AT_MS);
    q
}
