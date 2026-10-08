// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for live-market cash under delayed execution: `rebalance_expiry_cash`
/// holds a live market at the largest of its buffered required backing, its initial
/// cash, and required backing plus the queued orders' cash need. The tests check the
/// top-up toward the waiting need, the sweep floor while orders wait, the idle and
/// allocation caps on a top-up, and that a second caller finds nothing to move.
///
/// Every expected cash need comes from the spec's exact-quantity formula,
/// `ceil(quantity * (1 - p_min)) + 1`, worked by hand at the default minimum entry
/// probability of 0.01. Required backing and pre-call balances are read from state
/// as inputs. The function under test is the target, never its inputs.
#[test_only]
module deepbook_predict::queue_pool_cash_flow_tests;

use deepbook_predict::{
    flow_test_helpers as helpers,
    protocol_config::ProtocolConfig,
    queue_test_helpers as queue,
    registry::Registry,
    test_constants
};
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
/// All-in cost cap per queued mint: above an at-the-money fill of 8,000 contracts
/// and below the trader's deposit across two orders.
const QUEUED_MAX_COST: u64 = 6_000_000_000;
/// Probability cap per queued mint, above the at-the-money entry.
const QUEUED_MAX_PROBABILITY: u64 = 900_000_000;
/// Legacy position minted before the cutover so required backing is nonzero.
const LEGACY_QUANTITY: u64 = 2_000_000_000;
/// A pool small enough that idle caps the top-up: 10,000 funds the initial cash
/// and only 2,000 is left for the waiting need.
const SMALL_IDLE_SEED: u64 = 12_000_000_000;
/// An allocation cap that leaves 2,000 of room after the initial cash.
const TIGHT_MAX_EXPIRY_ALLOCATION: u64 = 12_000_000_000;
/// What both capped top-ups can still send: 12,000 - 10,000.
const CAPPED_TOP_UP: u64 = 2_000_000_000;

// === Top-up toward the waiting need ===

#[test]
fun rebalance_tops_up_to_required_backing_plus_the_waiting_need() {
    let (mut fx, expiry_id, trader) = setup_pool_market(
        IDLE_SEED,
        test_constants::default_max_expiry_allocation(),
    );

    // A pre-cutover position gives the market nonzero required backing.
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        LEGACY_QUANTITY,
    );
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.init_delayed_execution();
    fx.cutover();

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let required = helpers::market(&market).required_cash();
    let cash_before = helpers::market(&market).cash_balance();
    let idle_before = helpers::vault(&market).idle_balance();
    assert!(required > 0);

    enqueue_queued_mint(&mut fx, &mut market, &mut account);
    enqueue_queued_mint(&mut fx, &mut market, &mut account);
    assert_eq!(helpers::market(&market).waiting_cash_need(), TWO_QUEUED_NEED);
    // Waiting orders add no liability, and their escrow sits outside market cash.
    assert_eq!(helpers::market(&market).required_cash(), required);
    assert_eq!(helpers::market(&market).cash_balance(), cash_before);
    queue::assert_queue_invariants(helpers::market(&market));

    // The waiting need beats both other target terms: one buffer is at most
    // `required`, and required + need clears the 10,000 initial cash. So the
    // target is required + 15_840_000_002, and the market sits below it.
    assert!(TWO_QUEUED_NEED > required);
    assert!(required + TWO_QUEUED_NEED > INITIAL_CASH);
    assert!(required + TWO_QUEUED_NEED > cash_before);
    fx.rebalance_expiry_cash_bundle(&mut market);
    let target = required + TWO_QUEUED_NEED;
    assert_eq!(helpers::market(&market).cash_balance(), target);
    assert_eq!(helpers::vault(&market).idle_balance(), idle_before - (target - cash_before));
    helpers::assert_market_backed_bundle(&market);
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);

    // A second caller finds the market at its target, which is also its sweep
    // band, so it moves nothing and emits nothing.
    assert_second_rebalance_is_a_no_op(&mut fx, expiry_id, target);

    fx.finish();
}

#[test]
fun the_top_up_is_capped_by_idle_cash() {
    // 12,000 of idle: the initial funding takes 10,000, leaving 2,000 against a
    // 5,840 shortfall.
    let (mut fx, expiry_id, trader) = setup_pool_market(
        SMALL_IDLE_SEED,
        test_constants::default_max_expiry_allocation(),
    );
    fx.init_delayed_execution();
    fx.cutover();

    let mut market = enqueue_two_queued_mints(&mut fx, expiry_id, &trader);
    fx.rebalance_expiry_cash_bundle(&mut market);
    assert_eq!(helpers::market(&market).cash_balance(), INITIAL_CASH + CAPPED_TOP_UP);
    assert_eq!(helpers::vault(&market).idle_balance(), 0);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun the_top_up_is_capped_by_the_markets_allocation() {
    // A 12,000 allocation cap: the initial funding uses 10,000 of it, leaving
    // 2,000 of room against a 5,840 shortfall while idle has plenty.
    let (mut fx, expiry_id, trader) = setup_pool_market(
        IDLE_SEED,
        TIGHT_MAX_EXPIRY_ALLOCATION,
    );
    fx.init_delayed_execution();
    fx.cutover();

    let mut market = enqueue_two_queued_mints(&mut fx, expiry_id, &trader);
    fx.rebalance_expiry_cash_bundle(&mut market);
    assert_eq!(helpers::market(&market).cash_balance(), INITIAL_CASH + CAPPED_TOP_UP);
    assert_eq!(helpers::vault(&market).idle_balance(), IDLE_SEED - INITIAL_CASH - CAPPED_TOP_UP);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_market_bundle(market);
    fx.finish();
}

// === Sweep floor ===

#[test]
fun with_no_waiting_orders_a_sweep_returns_a_live_market_to_its_initial_cash() {
    // The control for the floor below: a market seeded far above its band and
    // with no order book sweeps down to its 10,000 initial cash.
    let (mut fx, expiry_id, _trader) = setup_seeded_queue_market();

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    assert_eq!(helpers::market(&market).waiting_cash_need(), 0);
    assert_eq!(helpers::market(&market).required_cash(), 0);
    let idle_before = helpers::vault(&market).idle_balance();
    fx.rebalance_expiry_cash_bundle(&mut market);
    assert_eq!(helpers::market(&market).cash_balance(), INITIAL_CASH);
    // 300,000 seeded - 10,000 kept.
    assert_eq!(helpers::vault(&market).idle_balance(), idle_before + 290_000_000_000);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun a_sweep_never_takes_a_live_market_below_required_plus_the_waiting_need() {
    let (mut fx, expiry_id, trader) = setup_seeded_queue_market();

    let mut market = enqueue_two_queued_mints(&mut fx, expiry_id, &trader);
    assert_eq!(helpers::market(&market).required_cash(), 0);
    assert_eq!(
        helpers::market(&market).cash_balance(),
        test_constants::default_seeded_expiry_cash(),
    );
    let idle_before = helpers::vault(&market).idle_balance();

    // Target = max(0 + 0, 10,000, 0 + 15_840_000_002), so the sweep stops at the
    // waiting need rather than at the initial cash the control sweeps to, and
    // returns 300_000_000_000 - 15_840_000_002 = 284_159_999_998.
    fx.rebalance_expiry_cash_bundle(&mut market);
    assert_eq!(helpers::market(&market).cash_balance(), TWO_QUEUED_NEED);
    assert_eq!(helpers::vault(&market).idle_balance(), idle_before + 284_159_999_998);
    helpers::assert_market_backed_bundle(&market);
    helpers::return_market_bundle(market);

    assert_second_rebalance_is_a_no_op(&mut fx, expiry_id, TWO_QUEUED_NEED);

    fx.finish();
}

// === Helpers ===

/// A bootstrapped pool with `idle_seed` of genesis liquidity, alice funded with
/// the default manager deposit, and one live market funded by a first rebalance
/// to its initial cash. The cadence template's allocation cap is set to
/// `max_expiry_allocation` before the market is created, so the market
/// snapshots it. The fixture is still before the cutover.
fun setup_pool_market(
    idle_seed: u64,
    max_expiry_allocation: u64,
): (helpers::Fixture, ID, helpers::Trader) {
    let mut fx = helpers::setup_market_default();
    let trader = fx.create_funded_manager(test_constants::default_manager_deposit());
    fx.bootstrap_lock(idle_seed);
    set_template_max_expiry_allocation(&mut fx, max_expiry_allocation);
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());

    // No order waits yet, so the first rebalance funds the market to its initial
    // cash: target = max(0 + 0, 10,000, 0 + 0).
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.rebalance_expiry_cash_bundle(&mut market);
    assert_eq!(helpers::market(&market).cash_balance(), INITIAL_CASH);
    assert_eq!(helpers::vault(&market).idle_balance(), idle_seed - INITIAL_CASH);
    helpers::return_market_bundle(market);
    (fx, expiry_id, trader)
}

/// The standard live market seeded with 300,000 of cash from outside the pool and
/// alice funded with the default manager deposit, past the cutover.
fun setup_seeded_queue_market(): (helpers::Fixture, ID, helpers::Trader) {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.init_delayed_execution();
    fx.cutover();
    (fx, expiry_id, trader)
}

/// Set the default cadence's allocation cap through the real admin path, keeping
/// every other template value at the fixture default.
fun set_template_max_expiry_allocation(fx: &mut helpers::Fixture, max_expiry_allocation: u64) {
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

/// Alice queues two at-the-money exact-quantity mints in a fresh transaction and
/// the market bundle is handed back still taken. Each order's own need fits the
/// market's spare cash, which is all placement checks, and together they wait on
/// 15_840_000_002 of cash.
fun enqueue_two_queued_mints(
    fx: &mut helpers::Fixture,
    expiry_id: ID,
    trader: &helpers::Trader,
): helpers::MarketBundle {
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(trader);
    enqueue_queued_mint(fx, &mut market, &mut account);
    assert_eq!(helpers::market(&market).waiting_cash_need(), QUEUED_NEED);
    enqueue_queued_mint(fx, &mut market, &mut account);
    assert_eq!(helpers::market(&market).waiting_cash_need(), TWO_QUEUED_NEED);
    queue::assert_queue_invariants(helpers::market(&market));
    helpers::return_account_bundle(account);
    market
}

fun enqueue_queued_mint(
    fx: &mut helpers::Fixture,
    market: &mut helpers::MarketBundle,
    account: &mut helpers::AccountBundle,
) {
    queue::enqueue_exact_quantity(
        fx,
        market,
        account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        QUEUED_QUANTITY,
        QUEUED_MAX_COST,
        QUEUED_MAX_PROBABILITY,
    );
}

/// Bob rebalances a market already at `expected_cash` in his own transaction:
/// cash stays put and the transaction emits no event, so a market at its target
/// takes no zero-amount sweep.
fun assert_second_rebalance_is_a_no_op(
    fx: &mut helpers::Fixture,
    expiry_id: ID,
    expected_cash: u64,
) {
    fx.scenario_mut().next_tx(test_constants::bob());
    let mut market = fx.take_market_bundle(expiry_id);
    let idle_before = helpers::vault(&market).idle_balance();
    fx.rebalance_expiry_cash_bundle(&mut market);
    assert_eq!(helpers::market(&market).cash_balance(), expected_cash);
    assert_eq!(helpers::vault(&market).idle_balance(), idle_before);
    helpers::return_market_bundle(market);
    let effects = fx.scenario_mut().next_tx(test_constants::admin());
    assert_eq!(effects.num_user_events(), 0);
}
