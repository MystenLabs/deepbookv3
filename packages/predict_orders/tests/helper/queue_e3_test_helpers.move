// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Shared fixtures for the queue refund, cleanup, and settlement flow tests
/// (delayed execution slice E3).
///
/// Every scenario places its orders at the fixture clock `test_constants::now_ms`
/// (120_000) under the default policy, so they share one cohort whose τ and
/// deadline follow by hand from the spec's placement rule (see `tau_ms` and
/// `deadline_ms`). Fills go through the real commit and resolve, with a Lazer tick
/// built by `queue_test_helpers`. Event checks compare BCS bytes against local
/// mirrors of the event layouts.
#[test_only]
module deepbook_predict::queue_e3_test_helpers;

use deepbook_predict::{
    constants,
    expiry_market::ExpiryMarket,
    flow_test_helpers::{Self as helpers, Fixture, MarketBundle, AccountBundle},
    order_queue::{Self, QueuedOrder},
    queue_test_helpers as queue,
    test_constants
};
use std::{bcs, unit_test::assert_eq};

/// Lazer channel id of `fixed_rate@200ms`, the default policy channel.
const CHANNEL_200MS: u8 = 3;
/// Lazer exponent `-9`: the tick's price magnitude is already 1e9-scaled.
const NEG_EXPONENT_9: u16 = 9;
const US_PER_MS: u64 = 1_000;
/// Enough resolve visits for every scenario's single cohort.
const RESOLVE_ALL: u64 = 100;

// === Fixture values ===

/// τ of an order placed at `now_ms` = 120_000 under the default policy:
/// ⌊(120_000 + delay 1_000) / 200⌋ × 200 = 121_000 (already on the 200 ms grid).
public fun tau_ms(): u64 { 121_000 }

/// Deadline of that cohort: min(τ + stall timeout 5_000, expiry) = 126_000.
public fun deadline_ms(): u64 { 126_000 }

/// τ of a sell placed at τ 121_000: ⌊(121_000 + delay 1_000) / 200⌋ × 200 =
/// 122_000.
public fun sell_tau_ms(): u64 { 122_000 }

/// One queued order's quantity: 100 contracts, a multiple of the 10_000 lot.
public fun quantity(): u64 { 100_000_000 }

/// One queued order's `max_cost`. Below `quantity` and the 1_000 USDC deposit,
/// so the escrowed budget is min(max_cost, quantity, available - fee) = max_cost.
public fun max_cost(): u64 { 90_000_000 }

/// The default policy's flat order fee (spec default 0.02 USDC).
public fun order_fee(): u64 { 20_000 }

/// Cash need of one exact-quantity order: ⌈quantity × (1 - p_min)⌉ + 1 with the
/// default minimum entry probability 0.01: ⌈100_000_000 × 0.99⌉ + 1 = 99_000_001.
public fun cash_need(): u64 { 99_000_001 }

/// Settlement spot one tick above the strike: inside `(strike, +inf)` and
/// outside `(-inf, strike]`.
public fun spot_above_strike(): u64 {
    (helpers::strike_tick() + 1) * test_constants::default_tick_size()
}

// === Flows ===

/// Place an exact-quantity mint of `quantity()` on `(strike, +inf)` as the
/// account's owner. The caller has the owner as the transaction sender.
public fun enqueue_up(
    fx: &mut Fixture,
    market: &mut MarketBundle,
    account: &mut AccountBundle,
): u64 {
    queue::enqueue_exact_quantity(
        fx,
        market,
        account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        quantity(),
        max_cost(),
        std::u64::max_value!(),
    )
}

/// Same on `(-inf, strike]`.
public fun enqueue_down(
    fx: &mut Fixture,
    market: &mut MarketBundle,
    account: &mut AccountBundle,
): u64 {
    queue::enqueue_exact_quantity(
        fx,
        market,
        account,
        0,
        helpers::strike_tick(),
        quantity(),
        max_cost(),
        std::u64::max_value!(),
    )
}

/// Move the clock to τ, commit the cohort at the update stamped τ (spot at the
/// strike, generation exactly τ), and resolve it. Returns resolve's count.
public fun commit_and_resolve(fx: &mut Fixture, market: &mut MarketBundle): u64 {
    fx.set_clock_for_testing(tau_ms());
    let tick = queue::lazer_tick(
        tau_ms(),
        CHANNEL_200MS,
        test_constants::pyth_feed_id(),
        test_constants::default_live_price(),
        NEG_EXPONENT_9,
        tau_ms() * US_PER_MS,
    );
    queue::commit_decoded(fx, market, vector[tick]);
    queue::resolve(fx, market, RESOLVE_ALL)
}

/// Sell Open record `record_id`'s whole position early and fill the sell, so the
/// source and the sell record both end Closed. Runs after `commit_and_resolve`,
/// at τ: it reseeds the feeds there, places the sell (τ `sell_tau_ms`), then
/// commits that cohort at the default live price and resolves it. Returns the
/// sell's record ID.
public fun sell_and_fill(
    fx: &mut Fixture,
    market: &mut MarketBundle,
    account: &mut AccountBundle,
    record_id: u64,
): u64 {
    fx.advance_live_oracle_bundle_to(market, test_constants::default_live_price(), tau_ms());
    let sell_id = queue::enqueue_redeem_open(fx, market, account, record_id, quantity(), 0, 0);
    fx.set_clock_for_testing(sell_tau_ms());
    let tick = queue::lazer_tick(
        sell_tau_ms(),
        CHANNEL_200MS,
        test_constants::pyth_feed_id(),
        test_constants::default_live_price(),
        NEG_EXPONENT_9,
        sell_tau_ms() * US_PER_MS,
    );
    queue::commit_decoded(fx, market, vector[tick]);
    assert_eq!(queue::resolve(fx, market, RESOLVE_ALL), 1);
    assert_status(helpers::market(market), record_id, order_queue::status_closed());
    assert_status(helpers::market(market), sell_id, order_queue::status_closed());
    sell_id
}

/// Set the two settle batch sizes through the real admin setter, keeping the
/// policy's other limits.
public fun set_settle_batches(
    fx: &mut Fixture,
    market: &mut MarketBundle,
    refund_batch: u64,
    payout_batch: u64,
) {
    let policy = helpers::config(market).delayed_execution_policy().destroy_some();
    let (admin_cap, clock, _) = fx.admin_parts();
    helpers::config_mut(market).set_delayed_execution_limits(
        admin_cap,
        policy.mint_capacity(),
        policy.sell_capacity(),
        policy.per_account_cap(),
        policy.min_sell_quantity(),
        refund_batch,
        payout_batch,
        clock,
    );
}

/// Move the clock to the market's expiry and record the exact settlement spot.
public fun reach_expiry_with_spot(fx: &mut Fixture, market: &mut MarketBundle, spot: u64) {
    fx.set_clock_for_testing(helpers::market(market).expiry());
    fx.insert_exact_settlement_spot_bundle(market, spot);
}

// === Reads ===

public fun record(market: &ExpiryMarket, record_id: u64): QueuedOrder {
    market.queued_order(record_id).destroy_some()
}

public fun status(market: &ExpiryMarket, record_id: u64): u8 {
    record(market, record_id).status()
}

/// The packed position ID an Open record holds.
public fun held_order_id(market: &ExpiryMarket, record_id: u64): u256 {
    record(market, record_id).position().order_id()
}

public fun assert_status(market: &ExpiryMarket, record_id: u64, expected: u8) {
    assert_eq!(status(market, record_id), expected);
}

public fun assert_pending(market: &ExpiryMarket, mints: u64, sells: u64) {
    let (pending_mints, pending_sells) = market.pending_counts();
    assert_eq!(pending_mints, mints);
    assert_eq!(pending_sells, sells);
}

public fun assert_heads(market: &ExpiryMarket, resolve_head: u64, next_id: u64) {
    let (actual_resolve_head, actual_next_id, _, _) = market.queue_heads();
    assert_eq!(actual_resolve_head, resolve_head);
    assert_eq!(actual_next_id, next_id);
}

public fun assert_payout_progress(market: &ExpiryMarket, payout_cursor: u64, next_id: u64) {
    let (actual_payout_cursor, actual_next_id) = market.payout_progress();
    assert_eq!(actual_payout_cursor, payout_cursor);
    assert_eq!(actual_next_id, next_id);
}

public fun assert_refunded_with(market: &ExpiryMarket, record_id: u64, reason: u8, at_ms: u64) {
    let record = record(market, record_id);
    assert_eq!(record.status(), order_queue::status_refunded());
    assert_eq!(record.result().reason(), reason);
    assert_eq!(record.result().finished_at_ms(), at_ms);
}

// === Event mirrors ===

public struct ExpectedQueuedOrderRefunded has copy, drop {
    market_cash: u64,
    required_cash: u64,
    waiting_cash_need: u64,
    expiry_market_id: ID,
    record_id: u64,
    account_id: ID,
    kind: u8,
    reason: u8,
    escrow_returned: u64,
    order_fee_returned: u64,
    subsidy_returned: u64,
    position_returned: bool,
    sender: address,
    onchain_timestamp_ms: u64,
}

public struct ExpectedRecordIds has copy, drop {
    expiry_market_id: ID,
    record_ids: vector<u64>,
    onchain_timestamp_ms: u64,
}

public struct ExpectedQueueEscrowSwept has copy, drop {
    expiry_market_id: ID,
    amount: u64,
    onchain_timestamp_ms: u64,
}

/// Mirror of both `OpenRecordSettled` and `OpenRecordPayoutSkipped`, which share
/// one layout.
public struct ExpectedOpenRecordPayout has copy, drop {
    expiry_market_id: ID,
    record_id: u64,
    account_id: ID,
    order_id: u256,
    payout: u64,
    onchain_timestamp_ms: u64,
}

public struct ExpectedMarketPayoutsCompleted has copy, drop {
    expiry_market_id: ID,
    onchain_timestamp_ms: u64,
}

/// A deadline or settlement refund of one unfilled exact-quantity mint: its whole
/// budget and its order fee back, nothing reserved, no position.
public fun expected_mint_refund(
    market_cash: u64,
    required_cash: u64,
    waiting_cash_need: u64,
    expiry_market_id: ID,
    record_id: u64,
    account_id: ID,
    reason: u8,
    sender: address,
    onchain_timestamp_ms: u64,
): ExpectedQueuedOrderRefunded {
    ExpectedQueuedOrderRefunded {
        market_cash,
        required_cash,
        waiting_cash_need,
        expiry_market_id,
        record_id,
        account_id,
        kind: order_queue::kind_exact_quantity(),
        reason,
        escrow_returned: max_cost(),
        order_fee_returned: order_fee(),
        subsidy_returned: 0,
        position_returned: false,
        sender,
        onchain_timestamp_ms,
    }
}

/// Mirror of `QueuedOrdersCleaned`.
public fun expected_record_ids(
    expiry_market_id: ID,
    record_ids: vector<u64>,
    onchain_timestamp_ms: u64,
): ExpectedRecordIds {
    ExpectedRecordIds { expiry_market_id, record_ids, onchain_timestamp_ms }
}

public fun expected_escrow_swept(
    expiry_market_id: ID,
    amount: u64,
    onchain_timestamp_ms: u64,
): ExpectedQueueEscrowSwept {
    ExpectedQueueEscrowSwept { expiry_market_id, amount, onchain_timestamp_ms }
}

public fun expected_open_record_payout(
    expiry_market_id: ID,
    record_id: u64,
    account_id: ID,
    order_id: u256,
    payout: u64,
    onchain_timestamp_ms: u64,
): ExpectedOpenRecordPayout {
    ExpectedOpenRecordPayout {
        expiry_market_id,
        record_id,
        account_id,
        order_id,
        payout,
        onchain_timestamp_ms,
    }
}

public fun expected_payouts_completed(
    expiry_market_id: ID,
    onchain_timestamp_ms: u64,
): ExpectedMarketPayoutsCompleted {
    ExpectedMarketPayoutsCompleted { expiry_market_id, onchain_timestamp_ms }
}

/// Assert an emitted event's BCS bytes equal its mirror's.
public fun assert_event<Event: copy + drop, Mirror: copy + drop>(event: &Event, mirror: &Mirror) {
    assert_eq!(bcs::to_bytes(event), bcs::to_bytes(mirror));
}
