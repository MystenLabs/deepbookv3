// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Shared bring-up and thin wrappers for delayed-execution queue flow tests.
///
/// `setup_queue_market` stands up the `flow_test_helpers` live market, writes
/// the delayed-execution policy, and crosses the cutover with a real watermark
/// bump, so queue suites run in the post-cutover state while the legacy suites
/// keep the pre-cutover fixture. Commit tests drive `commit_decoded` with
/// `LazerTick`s built here, because a real Pyth Lazer `Update` has no Move test
/// constructor; the decode step itself is rehearsed against real payloads off
/// chain.
#[test_only]
module deepbook_predict::queue_test_helpers;

use account::account;
use deepbook_predict::{
    expiry_market::{Self, ExpiryMarket, LazerTick, LazerTickFeed},
    flow_test_helpers::{Self, Fixture, Trader, MarketBundle, AccountBundle},
    order_queue
};
use pyth_lazer::{
    i16::{Self as lazer_i16, I16 as LazerI16},
    i64::{Self as lazer_i64, I64 as LazerI64}
};
use std::unit_test::assert_eq;

// === Setup ===

/// `flow_test_helpers::setup_live_market` plus the default delayed-execution
/// policy and the cutover. Returns `(fixture, expiry_id, funded alice)`.
public fun setup_queue_market(expiry_ms: u64, live_price: u64): (Fixture, ID, Trader) {
    let (mut fx, expiry_id, trader) = flow_test_helpers::setup_live_market(expiry_ms, live_price);
    fx.init_delayed_execution();
    fx.cutover();
    (fx, expiry_id, trader)
}

// === Placement ===

public fun enqueue_exact_quantity(
    fx: &mut Fixture,
    market: &mut MarketBundle,
    account: &mut AccountBundle,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    max_cost: u64,
    max_probability: u64,
): u64 {
    let (expiry_market, config, oracle_registry, pyth, bs) = market.market_parts_mut();
    let (wrapper, root) = account.account_parts_mut();
    let (clock, ctx) = fx.clock_and_ctx();
    let auth = account::generate_auth(ctx);
    expiry_market.enqueue_exact_quantity(
        wrapper,
        auth,
        config,
        oracle_registry,
        pyth,
        bs.values(),
        bs.svi(),
        lower_tick,
        higher_tick,
        quantity,
        max_cost,
        max_probability,
        root,
        clock,
        ctx,
    )
}

public fun enqueue_exact_amount(
    fx: &mut Fixture,
    market: &mut MarketBundle,
    account: &mut AccountBundle,
    lower_tick: u64,
    higher_tick: u64,
    max_premium: u64,
    min_quantity: u64,
    max_cost: u64,
): u64 {
    let (expiry_market, config, oracle_registry, pyth, bs) = market.market_parts_mut();
    let (wrapper, root) = account.account_parts_mut();
    let (clock, ctx) = fx.clock_and_ctx();
    let auth = account::generate_auth(ctx);
    expiry_market.enqueue_exact_amount(
        wrapper,
        auth,
        config,
        oracle_registry,
        pyth,
        bs.values(),
        bs.svi(),
        lower_tick,
        higher_tick,
        max_premium,
        min_quantity,
        max_cost,
        root,
        clock,
        ctx,
    )
}

public fun enqueue_exact_cost(
    fx: &mut Fixture,
    market: &mut MarketBundle,
    account: &mut AccountBundle,
    lower_tick: u64,
    higher_tick: u64,
    max_cost: u64,
    min_quantity: u64,
): u64 {
    let (expiry_market, config, oracle_registry, pyth, bs) = market.market_parts_mut();
    let (wrapper, root) = account.account_parts_mut();
    let (clock, ctx) = fx.clock_and_ctx();
    let auth = account::generate_auth(ctx);
    expiry_market.enqueue_exact_cost(
        wrapper,
        auth,
        config,
        oracle_registry,
        pyth,
        bs.values(),
        bs.svi(),
        lower_tick,
        higher_tick,
        max_cost,
        min_quantity,
        root,
        clock,
        ctx,
    )
}

public fun enqueue_redeem_open(
    fx: &mut Fixture,
    market: &mut MarketBundle,
    account: &mut AccountBundle,
    record_id: u64,
    close_quantity: u64,
    min_probability: u64,
    min_proceeds: u64,
): u64 {
    let (expiry_market, config, oracle_registry, pyth, bs) = market.market_parts_mut();
    let (wrapper, root) = account.account_parts_mut();
    let (clock, ctx) = fx.clock_and_ctx();
    let auth = account::generate_auth(ctx);
    expiry_market.enqueue_redeem_open(
        wrapper,
        auth,
        config,
        oracle_registry,
        pyth,
        bs.values(),
        bs.svi(),
        record_id,
        close_quantity,
        min_probability,
        min_proceeds,
        root,
        clock,
        ctx,
    )
}

// === Commit and resolve ===

/// Commit decoded ticks as the scenario's current sender.
public fun commit_decoded(fx: &mut Fixture, market: &mut MarketBundle, ticks: vector<LazerTick>) {
    let (expiry_market, config, _, _, _) = market.market_parts_mut();
    let (clock, ctx) = fx.clock_and_ctx();
    let sender = ctx.sender();
    expiry_market.commit_decoded(config, ticks, clock, sender);
}

public fun resolve(fx: &mut Fixture, market: &mut MarketBundle, max_orders: u64): u64 {
    let (expiry_market, config, _, _, _) = market.market_parts_mut();
    let (clock, ctx) = fx.clock_and_ctx();
    expiry_market.resolve(config, max_orders, clock, ctx)
}

// === Refunds, cleanup, settlement ===

public fun refund(fx: &mut Fixture, market: &mut MarketBundle, max_orders: u64): u64 {
    let (expiry_market, config, _, _, _) = market.market_parts_mut();
    let (clock, ctx) = fx.clock_and_ctx();
    expiry_market.refund(config, max_orders, clock, ctx)
}

/// Admin-refund `record_ids` with the fixture's `AdminCap`.
public fun admin_refund(fx: &mut Fixture, market: &mut MarketBundle, record_ids: vector<u64>) {
    let (expiry_market, config, _, _, _) = market.market_parts_mut();
    let (admin_cap, clock, ctx) = fx.admin_parts();
    expiry_market.admin_refund(config, admin_cap, record_ids, clock, ctx);
}

public fun cleanup(fx: &mut Fixture, market: &mut MarketBundle, record_ids: vector<u64>) {
    let (expiry_market, config, _, _, _) = market.market_parts_mut();
    let (clock, ctx) = fx.clock_and_ctx();
    expiry_market.cleanup(config, record_ids, clock, ctx);
}

public fun try_settle(fx: &Fixture, market: &mut MarketBundle): bool {
    fx.try_settle_bundle(market)
}

// === Lazer ticks ===

/// One-feed tick on `channel` with envelope `envelope_ms`, carrying a requested
/// positive `price` with exponent `-neg_exponent` and generation time
/// `generation_us`.
public fun lazer_tick(
    envelope_ms: u64,
    channel: u8,
    feed_id: u32,
    price: u64,
    neg_exponent: u16,
    generation_us: u64,
): LazerTick {
    lazer_tick_with_feeds(
        envelope_ms * 1000,
        channel,
        vector[
            lazer_feed(
                feed_id,
                option::some(option::some(lazer_i64::new(price, false))),
                option::some(lazer_i16::new(neg_exponent, true)),
                option::some(option::some(generation_us)),
            ),
        ],
    )
}

/// A tick with an explicit µs envelope and feed list, for malformed-envelope
/// and multi-feed cases.
public fun lazer_tick_with_feeds(
    envelope_us: u64,
    channel: u8,
    feeds: vector<LazerTickFeed>,
): LazerTick {
    expiry_market::new_lazer_tick_for_testing(envelope_us, channel, feeds)
}

/// One feed with every `Option` layer explicit, for the not-requested
/// (`none`) and requested-but-empty (`some(none)`) cases.
public fun lazer_feed(
    feed_id: u32,
    price: Option<Option<LazerI64>>,
    exponent: Option<LazerI16>,
    feed_update_timestamp_us: Option<Option<u64>>,
): LazerTickFeed {
    expiry_market::new_lazer_tick_feed_for_testing(
        feed_id,
        price,
        exponent,
        feed_update_timestamp_us,
    )
}

// === Invariants ===

/// Sum of budget, order fee, and reserved subsidy over the market's unfinished
/// (Pending, Committed, RefundDue) records, read through the public queue reads.
public fun escrow_sum(market: &ExpiryMarket): u64 {
    let (_, next_id, _, _) = market.queue_heads();
    let mut sum = 0;
    next_id.do!(|record_id| {
        let order = market.queued_order(record_id);
        if (order.is_some()) {
            let order = order.destroy_some();
            if (is_unfinished(order.status())) {
                let escrow = order.escrow();
                sum = sum + escrow.budget() + escrow.order_fee() + escrow.subsidy_reserved();
            };
        };
    });
    sum
}

/// Sum of cash need over the market's unfinished records.
public fun cash_need_sum(market: &ExpiryMarket): u64 {
    let (_, next_id, _, _) = market.queue_heads();
    let mut sum = 0;
    next_id.do!(|record_id| {
        let order = market.queued_order(record_id);
        if (order.is_some()) {
            let order = order.destroy_some();
            if (is_unfinished(order.status())) sum = sum + order.escrow().cash_need();
        };
    });
    sum
}

/// Rule-17 queue invariants: escrow equals the unfinished records' budget, fee,
/// and reserved subsidy, and `waiting_cash_need` equals their summed cash need.
public fun assert_queue_invariants(market: &ExpiryMarket) {
    assert_eq!(expiry_market::queue_escrow_for_testing(market), escrow_sum(market));
    assert_eq!(market.waiting_cash_need(), cash_need_sum(market));
}

fun is_unfinished(status: u8): bool {
    status == order_queue::status_pending()
        || status == order_queue::status_committed()
        || status == order_queue::status_refund_due()
}
