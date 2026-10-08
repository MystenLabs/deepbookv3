// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Live-market cash under delayed execution: Predict's `rebalance_expiry_cash`
/// holds a live market at the largest of its buffered required backing, its
/// initial cash, and required backing plus the waiting cash need that queued
/// orders put in Predict's ledger. The tests check the top-up toward the
/// waiting need, the sweep floor while orders wait, the idle and allocation caps
/// on a top-up, and that a second caller finds nothing to move.
///
/// Every expected cash need comes from the exact-quantity formula,
/// `ceil(quantity * (1 - p_min)) + 1`, worked by hand at the default minimum
/// entry probability of 0.01. Required backing and pre-call balances are read
/// from state as inputs. The function under test is the target, never its
/// inputs.
#[test_only]
module deepbook_predict_orders::queue_pool_cash_flow_tests;

use deepbook_predict::{
    flow_test_helpers::{Self as helpers, Fixture, Trader},
    protocol_config::ProtocolConfig,
    registry::Registry,
    test_constants
};
use deepbook_predict_orders::queue_fixture::{Self as fixture, QueueTest};
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

/// Pool genesis liquidity, well above any target below.
const IDLE_SEED: u64 = 100_000_000_000;
/// Per-market initial cash target snapshotted from the default cadence.
const INITIAL_CASH: u64 = 10_000_000_000;
/// Quantity of each queued exact-quantity mint (8,000 contracts).
const QUEUED_QUANTITY: u64 = 8_000_000_000;
/// One queued mint's cash need at p_min = 0.01:
/// ceil(8_000_000_000 * 0.99) + 1 = 7_920_000_000 + 1.
const QUEUED_NEED: u64 = 7_920_000_001;
/// Two queued mints: 2 * 7_920_000_001.
const TWO_QUEUED_NEED: u64 = 15_840_000_002;
/// All-in cost cap per queued mint: above an at-the-money fill of 8,000
/// contracts and below the trader's deposit across two orders.
const QUEUED_MAX_COST: u64 = 6_000_000_000;
/// Probability cap per queued mint, above the at-the-money entry.
const QUEUED_MAX_PROBABILITY: u64 = 900_000_000;
/// A position filled from the queue first, so required backing is nonzero.
const FILLED_QUANTITY: u64 = 2_000_000_000;
const FILLED_MAX_COST: u64 = 1_500_000_000;
const TAU: u64 = 121_000;
const RESOLVE_ALL: u64 = 10;
/// A pool small enough that idle caps the top-up: 10,000 funds the initial cash
/// and only 2,000 is left for the waiting need.
const SMALL_IDLE_SEED: u64 = 12_000_000_000;
/// An allocation cap that leaves 2,000 of room after the initial cash.
const TIGHT_MAX_EXPIRY_ALLOCATION: u64 = 12_000_000_000;
/// What both capped top-ups can still send: 12,000 - 10,000.
const CAPPED_TOP_UP: u64 = 2_000_000_000;
/// 300,000 seeded - 10,000 kept.
const SWEPT_TO_INITIAL_CASH: u64 = 290_000_000_000;
/// 300_000_000_000 - 15_840_000_002.
const SWEPT_TO_WAITING_NEED: u64 = 284_159_999_998;

// === Top-up toward the waiting need ===

#[test]
fun rebalance_tops_up_to_required_backing_plus_the_waiting_need() {
    let mut q = pool_queue(IDLE_SEED, test_constants::default_max_expiry_allocation());
    // A filled position gives the market nonzero required backing.
    q.enqueue_atm(FILLED_QUANTITY, FILLED_MAX_COST);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);
    q.refresh_oracle_at(TAU);
    let required = q.market().required_cash();
    let cash_before = q.market().cash_balance();
    let idle_before = helpers::vault(q.bundle()).idle_balance();
    assert!(required > 0);

    enqueue_queued_mint(&mut q);
    enqueue_queued_mint(&mut q);
    let (waiting_cash_need, _) = q.ledger();
    assert_eq!(waiting_cash_need, TWO_QUEUED_NEED);
    // Waiting orders add no liability, and their escrow sits outside market cash.
    assert_eq!(q.market().required_cash(), required);
    assert_eq!(q.market().cash_balance(), cash_before);
    q.assert_invariants();

    // The waiting need beats both other target terms: one buffer is at most
    // `required`, and required + need clears the 10,000 initial cash. So the
    // target is required + 15_840_000_002, and the market sits below it.
    assert!(TWO_QUEUED_NEED > required);
    assert!(required + TWO_QUEUED_NEED > INITIAL_CASH);
    assert!(required + TWO_QUEUED_NEED > cash_before);
    q.rebalance();
    let target = required + TWO_QUEUED_NEED;
    assert_eq!(q.market().cash_balance(), target);
    assert_eq!(helpers::vault(q.bundle()).idle_balance(), idle_before - (target - cash_before));
    q.assert_backed();

    assert_second_rebalance_is_a_no_op(q, target);
}

#[test]
fun the_top_up_is_capped_by_idle_cash() {
    // 12,000 of idle: the initial funding takes 10,000, leaving 2,000 against a
    // 5,840 shortfall.
    let mut q = pool_queue(SMALL_IDLE_SEED, test_constants::default_max_expiry_allocation());
    enqueue_two_queued_mints(&mut q);

    q.rebalance();

    assert_eq!(q.market().cash_balance(), INITIAL_CASH + CAPPED_TOP_UP);
    assert_eq!(helpers::vault(q.bundle()).idle_balance(), 0);
    q.assert_backed();
    q.finish();
}

#[test]
fun the_top_up_is_capped_by_the_markets_allocation() {
    // A 12,000 allocation cap: the initial funding uses 10,000 of it, leaving
    // 2,000 of room against a 5,840 shortfall while idle has plenty.
    let mut q = pool_queue(IDLE_SEED, TIGHT_MAX_EXPIRY_ALLOCATION);
    enqueue_two_queued_mints(&mut q);

    q.rebalance();

    assert_eq!(q.market().cash_balance(), INITIAL_CASH + CAPPED_TOP_UP);
    assert_eq!(
        helpers::vault(q.bundle()).idle_balance(),
        IDLE_SEED - INITIAL_CASH - CAPPED_TOP_UP,
    );
    q.assert_backed();
    q.finish();
}

// === Sweep floor ===

#[test]
fun with_no_waiting_orders_a_sweep_returns_a_live_market_to_its_initial_cash() {
    // The control for the floor below: a market seeded far above its band and
    // with no waiting order sweeps down to its 10,000 initial cash.
    let mut q = seeded_queue();
    let (waiting_cash_need, _) = q.ledger();
    assert_eq!(waiting_cash_need, 0);
    assert_eq!(q.market().required_cash(), 0);
    let idle_before = helpers::vault(q.bundle()).idle_balance();

    q.rebalance();

    assert_eq!(q.market().cash_balance(), INITIAL_CASH);
    assert_eq!(helpers::vault(q.bundle()).idle_balance(), idle_before + SWEPT_TO_INITIAL_CASH);
    q.finish();
}

#[test]
fun a_sweep_never_takes_a_live_market_below_required_plus_the_waiting_need() {
    let mut q = seeded_queue();
    enqueue_two_queued_mints(&mut q);
    assert_eq!(q.market().required_cash(), 0);
    assert_eq!(q.market().cash_balance(), test_constants::default_seeded_expiry_cash());
    let idle_before = helpers::vault(q.bundle()).idle_balance();

    // Target = max(0 + 0, 10,000, 0 + 15_840_000_002), so the sweep stops at the
    // waiting need rather than at the initial cash the control sweeps to.
    q.rebalance();

    assert_eq!(q.market().cash_balance(), TWO_QUEUED_NEED);
    assert_eq!(helpers::vault(q.bundle()).idle_balance(), idle_before + SWEPT_TO_WAITING_NEED);
    q.assert_backed();
    assert_second_rebalance_is_a_no_op(q, TWO_QUEUED_NEED);
}

// === Helpers ===

/// A bootstrapped pool with `idle_seed` of genesis liquidity, alice funded with
/// the default manager deposit, and one live market funded by a first rebalance
/// to its initial cash, then the queue fixture. The cadence template's
/// allocation cap is set to `max_expiry_allocation` before the market is
/// created, so the market snapshots it.
fun pool_queue(idle_seed: u64, max_expiry_allocation: u64): QueueTest {
    let mut fx = helpers::setup_market_default();
    let trader = fx.create_funded_manager(test_constants::default_manager_deposit());
    fx.bootstrap_lock(idle_seed);
    set_template_max_expiry_allocation(&mut fx, max_expiry_allocation);
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());

    // No order waits yet, so the first rebalance funds the market to its initial
    // cash: target = max(0 + 0, 10,000, 0 + 0).
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, fixture::live_price());
    fx.rebalance_expiry_cash_bundle(&mut market);
    assert_eq!(helpers::market(&market).cash_balance(), INITIAL_CASH);
    assert_eq!(helpers::vault(&market).idle_balance(), idle_seed - INITIAL_CASH);
    helpers::return_market_bundle(market);
    fixture::from_fixture(fx, expiry_id, trader)
}

/// The standard live market seeded with 300,000 of cash from outside the pool
/// and alice funded with the default manager deposit.
fun seeded_queue(): QueueTest {
    let (fx, expiry_id, trader): (Fixture, ID, Trader) = helpers::setup_everything();
    fixture::from_fixture(fx, expiry_id, trader)
}

/// Set the default cadence's allocation cap through the real admin path, keeping
/// every other template value at the fixture default.
fun set_template_max_expiry_allocation(fx: &mut Fixture, max_expiry_allocation: u64) {
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut registry = fx.scenario_mut().take_shared<Registry>();
    let config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let (admin_cap, _, _) = fx.admin_parts();
    registry.set_template_cadence_config(
        &config,
        admin_cap,
        test_constants::propbook_underlying_id(),
        test_constants::default_cadence_id(),
        test_constants::default_tick_size(),
        test_constants::default_admission_tick_size(),
        max_expiry_allocation,
        test_constants::default_initial_expiry_cash(),
        test_constants::default_cadence_window_size(),
    );
    return_shared(registry);
    return_shared(config);
}

/// Two at-the-money exact-quantity mints. Each order's own need fits the
/// market's spare cash, which is all admission checks, and together they wait
/// on 15_840_000_002 of cash.
fun enqueue_two_queued_mints(q: &mut QueueTest) {
    enqueue_queued_mint(q);
    let (waiting_cash_need, _) = q.ledger();
    assert_eq!(waiting_cash_need, QUEUED_NEED);
    enqueue_queued_mint(q);
    let (waiting_cash_need, _) = q.ledger();
    assert_eq!(waiting_cash_need, TWO_QUEUED_NEED);
    q.assert_invariants();
}

fun enqueue_queued_mint(q: &mut QueueTest) {
    q.enqueue_quantity(
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        QUEUED_QUANTITY,
        QUEUED_MAX_COST,
        QUEUED_MAX_PROBABILITY,
    );
}

/// Bob rebalances a market already at `expected_cash` in his own transaction:
/// cash and idle stay put.
fun assert_second_rebalance_is_a_no_op(q: QueueTest, expected_cash: u64) {
    let mut q = q.next_tx(test_constants::bob());
    let idle_before = helpers::vault(q.bundle()).idle_balance();
    q.rebalance();
    assert_eq!(q.market().cash_balance(), expected_cash);
    assert_eq!(helpers::vault(q.bundle()).idle_balance(), idle_before);
    q.finish();
}
