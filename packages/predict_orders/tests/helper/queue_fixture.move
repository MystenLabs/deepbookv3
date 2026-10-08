// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow fixture for the companion's queue tests: Predict's live test market
/// past the cutover with this package's `OrderFlow` witness allowlisted, an
/// `OrderDesk`, and the market's `MarketQueue`, held together with one trader's
/// account for the current transaction.
///
/// The desk runs the launch policy except for a 1_000 ms delay, which the
/// hand-derived fixtures assume: from the fixture clock 120_000, τ =
/// floor((t₀ + 1_000) / 200) * 200 and the deadline is τ + 5_000. Commits use
/// `queue::commit_for_testing`, because a real Lazer `Update` has no Move test
/// constructor; `lazer_price` decodes real updates and has its own tests.
#[test_only]
module deepbook_predict_orders::queue_fixture;

use account::account;
use deepbook_predict::{
    expiry_market::{ExpiryMarket, RedeemQuote},
    flow_test_helpers::{Self as helpers, Fixture, Trader, MarketBundle, AccountBundle},
    plp::SnapshotStage,
    pricing::Pricer,
    protocol_config::ProtocolConfig,
    test_constants
};
use deepbook_predict_math::lazer_price;
use deepbook_predict_orders::{
    desk::{Self, OrderDesk},
    order_flow::OrderFlow,
    order_queue::{Self, OrderView},
    queue::{Self, MarketQueue, TestUpdate}
};
use std::unit_test::assert_eq;
use sui::{clock, test_scenario::return_shared};
use usdc::usdc::USDC;

const CHANNEL_200MS: u8 = 3;
const US_PER_MS: u64 = 1_000;
/// The delay the hand-derived fixtures assume.
const FIXTURE_DELAY_MS: u64 = 1_000;
const STALL_TIMEOUT_MS: u64 = 5_000;
const STUCK_THRESHOLD_MS: u64 = 1_500;
const GAP_WAIT_MS: u64 = 2_000;
const SVI_MAX_AGE_MS: u64 = 60_000;

/// Everything one queue test transaction holds.
public struct QueueTest {
    fx: Fixture,
    expiry_id: ID,
    trader: Trader,
    desk_id: ID,
    queue_id: ID,
    market: MarketBundle,
    account: AccountBundle,
    desk: OrderDesk,
    queue: MarketQueue,
}

// === Setup ===

/// The default live market at the default expiry, in alice's transaction.
public fun new(): QueueTest {
    new_at(test_constants::default_expiry_ms())
}

public fun new_at(expiry_ms: u64): QueueTest {
    let (fx, expiry_id, trader) = helpers::setup_live_market(expiry_ms, live_price());
    from_fixture(fx, expiry_id, trader)
}

/// A default live market holding exactly `cash` and no position, so its spare
/// cash is `cash`.
public fun new_with_cash(cash: u64): QueueTest {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let trader = fx.create_funded_manager(test_constants::mint_deposit());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, live_price());
    fx.seed_market_cash(helpers::market_mut(&mut market), cash);
    assert_eq!(helpers::market(&market).cash_balance(), cash);
    helpers::return_market_bundle(market);
    from_fixture(fx, expiry_id, trader)
}

/// The default live market with alice referred by bob. Returns bob's handle.
public fun new_referred(): (QueueTest, Trader) {
    let (fx, expiry_id, trader, referrer) = helpers::setup_referred_live_market(
        test_constants::default_expiry_ms(),
        live_price(),
    );
    (from_fixture(fx, expiry_id, trader), referrer)
}

/// The default market plus a second expiry at `short_expiry_ms`, which has no
/// queue. Returns its ID.
public fun new_with_other_market(): (QueueTest, ID) {
    let mut fx = helpers::setup_market_default();
    // The cadence deploys expiries in order, so the earlier one comes first.
    let other = fx.create_expiry(test_constants::short_expiry_ms());
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let trader = fx.create_funded_manager(test_constants::mint_deposit());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, live_price());
    fx.seed_market_cash(
        helpers::market_mut(&mut market),
        test_constants::default_seeded_expiry_cash(),
    );
    helpers::return_market_bundle(market);
    (from_fixture(fx, expiry_id, trader), other)
}

/// Cross the cutover, allowlist `OrderFlow`, create the desk with the fixture
/// delay, and create the market's queue. Returns in `trader`'s transaction.
public fun from_fixture(fx: Fixture, expiry_id: ID, trader: Trader): QueueTest {
    assemble(fx, expiry_id, trader, true)
}

/// The default live market with the queue set up but Predict's watermark still
/// below the cutover.
public fun new_before_cutover(): QueueTest {
    let (fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        live_price(),
    );
    assemble(fx, expiry_id, trader, false)
}

/// The default live market over a pool bootstrapped with `lock_amount`, so a
/// flush can start.
public fun new_with_pool(lock_amount: u64): QueueTest {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        live_price(),
    );
    fx.bootstrap_lock(lock_amount);
    from_fixture(fx, expiry_id, trader)
}

fun assemble(mut fx: Fixture, expiry_id: ID, trader: Trader, cross_cutover: bool): QueueTest {
    if (cross_cutover) {
        fx.cutover();
    } else {
        fx.scenario_mut().next_tx(test_constants::admin());
    };
    let mut market = fx.take_market_bundle(expiry_id);
    let desk_id = {
        let (admin_cap, clock, ctx) = fx.admin_parts();
        let config = helpers::config_mut(&mut market);
        config.set_order_flow<OrderFlow>(admin_cap, true, clock);
        desk::create_and_share(admin_cap, config, clock, ctx)
    };
    helpers::return_market_bundle(market);
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut desk = fx.scenario_mut().take_shared_by_id<OrderDesk>(desk_id);
    let market = fx.take_market_bundle(expiry_id);
    let queue_id = {
        let (admin_cap, clock, ctx) = fx.admin_parts();
        desk.set_timing(
            admin_cap,
            helpers::config(&market),
            FIXTURE_DELAY_MS,
            STALL_TIMEOUT_MS,
            STUCK_THRESHOLD_MS,
            GAP_WAIT_MS,
            0,
            CHANNEL_200MS,
            SVI_MAX_AGE_MS,
            clock,
        );
        queue::create_and_share(&mut desk, helpers::market(&market), ctx)
    };
    helpers::return_market_bundle(market);
    return_shared(desk);
    let owner = trader.owner();
    fx.scenario_mut().next_tx(owner);
    take(fx, expiry_id, trader, desk_id, queue_id)
}

/// Return every shared object and end the scenario.
public fun finish(q: QueueTest) {
    let QueueTest { fx, market, account, desk, queue, .. } = q;
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    return_shared(desk);
    return_shared(queue);
    fx.finish();
}

// === Transactions ===

/// Start a new transaction as `sender`, keeping the same trader's account.
/// Events read afterwards are the new transaction's.
public fun next_tx(q: QueueTest, sender: address): QueueTest {
    let trader = q.trader;
    q.retake(trader, sender)
}

/// Start a new transaction as `trader`, holding that trader's account.
public fun as_trader(q: QueueTest, trader: Trader): QueueTest {
    let owner = trader.owner();
    q.retake(trader, owner)
}

/// Create and fund a new trader at `owner`, then continue in that trader's
/// transaction holding its account. Returns its handle.
public fun new_trader(q: QueueTest, owner: address, deposit: u64): (QueueTest, Trader) {
    let QueueTest { fx, expiry_id, desk_id, queue_id, market, account, desk, queue, .. } = q;
    let mut fx = fx;
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    return_shared(desk);
    return_shared(queue);
    let trader = fx.create_funded_manager_as(owner, deposit);
    (take(fx, expiry_id, trader, desk_id, queue_id), trader)
}

/// Create a builder code and link it to the current trader's account, then
/// continue in the trader's next transaction. Returns the code's ID.
public fun link_builder_code(q: QueueTest, code_index: u64): (QueueTest, ID) {
    let QueueTest { fx, expiry_id, trader, desk_id, queue_id, market, account, desk, queue } = q;
    let mut fx = fx;
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    return_shared(desk);
    return_shared(queue);
    let code_id = fx.create_and_link_builder_code(code_index, &trader);
    fx.scenario_mut().next_tx(trader.owner());
    (take(fx, expiry_id, trader, desk_id, queue_id), code_id)
}

/// Continue in a new transaction holding `expiry_id`'s market in place of the
/// queue's own, for the binding checks.
public fun with_market(q: QueueTest, expiry_id: ID): QueueTest {
    let QueueTest { fx, trader, desk_id, queue_id, market, account, desk, queue, .. } = q;
    let mut fx = fx;
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    return_shared(desk);
    return_shared(queue);
    fx.scenario_mut().next_tx(trader.owner());
    take(fx, expiry_id, trader, desk_id, queue_id)
}

/// Create a second desk and continue in a new transaction holding it in place
/// of the queue's own, for the binding checks.
public fun with_new_desk(q: QueueTest): QueueTest {
    let QueueTest { fx, expiry_id, trader, queue_id, market, account, desk, queue, .. } = q;
    let mut fx = fx;
    helpers::return_account_bundle(account);
    return_shared(desk);
    return_shared(queue);
    let desk_id = {
        let (admin_cap, clock, ctx) = fx.admin_parts();
        desk::create_and_share(admin_cap, helpers::config(&market), clock, ctx)
    };
    helpers::return_market_bundle(market);
    fx.scenario_mut().next_tx(trader.owner());
    take(fx, expiry_id, trader, desk_id, queue_id)
}

/// Create a queue for the held market under the held desk.
public fun create_queue(q: &mut QueueTest): ID {
    let QueueTest { fx, market, desk, .. } = q;
    let (_, ctx) = fx.clock_and_ctx();
    queue::create_and_share(desk, helpers::market(market), ctx)
}

public fun desk_id(q: &QueueTest): ID { q.desk_id }

public fun queue_id(q: &QueueTest): ID { q.queue_id }

fun retake(q: QueueTest, trader: Trader, sender: address): QueueTest {
    let QueueTest { fx, expiry_id, desk_id, queue_id, market, account, desk, queue, .. } = q;
    let mut fx = fx;
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    return_shared(desk);
    return_shared(queue);
    fx.scenario_mut().next_tx(sender);
    take(fx, expiry_id, trader, desk_id, queue_id)
}

fun take(mut fx: Fixture, expiry_id: ID, trader: Trader, desk_id: ID, queue_id: ID): QueueTest {
    let market = fx.take_market_bundle(expiry_id);
    let account = fx.take_account_bundle(&trader);
    let desk = fx.scenario_mut().take_shared_by_id<OrderDesk>(desk_id);
    let queue = fx.scenario_mut().take_shared_by_id<MarketQueue>(queue_id);
    QueueTest { fx, expiry_id, trader, desk_id, queue_id, market, account, desk, queue }
}

// === Accessors ===

public fun live_price(): u64 { test_constants::default_live_price() }

public fun channel_200ms(): u8 { CHANNEL_200MS }

public fun fx(q: &mut QueueTest): &mut Fixture { &mut q.fx }

public fun market(q: &QueueTest): &ExpiryMarket { helpers::market(&q.market) }

public fun market_mut(q: &mut QueueTest): &mut ExpiryMarket { helpers::market_mut(&mut q.market) }

public fun bundle(q: &QueueTest): &MarketBundle { &q.market }

public fun bundle_mut(q: &mut QueueTest): &mut MarketBundle { &mut q.market }

public fun config(q: &QueueTest): &ProtocolConfig { helpers::config(&q.market) }

public fun queue(q: &QueueTest): &MarketQueue { &q.queue }

public fun desk(q: &QueueTest): &OrderDesk { &q.desk }

public fun expiry_id(q: &QueueTest): ID { q.expiry_id }

public fun trader(q: &QueueTest): Trader { q.trader }

public fun account_id(q: &QueueTest): ID { helpers::account_id_bundle(&q.account) }

/// The account's receive address, where refunds and proceeds go.
public fun receive_address(q: &mut QueueTest): address {
    let (wrapper, _) = q.account.account_parts_mut();
    wrapper.load_account().receive_address()
}

public fun balance(q: &QueueTest): u64 { q.fx.account_balance_bundle<USDC>(&q.account) }

/// One record that must exist.
public fun record(q: &QueueTest, record_id: u64): OrderView {
    q.queue.order(record_id).destroy_some()
}

/// `(waiting cash need, payout-tree node count)` from Predict's ledger.
public fun ledger(q: &QueueTest): (u64, u64) {
    let (waiting_cash_need, nodes, _) = q.market().order_flow_state();
    (waiting_cash_need, nodes)
}

/// Whether placement would refuse a new order as stuck now.
public fun is_stuck(q: &QueueTest): bool {
    q.queue.queue_stuck(&q.desk, q.fx.clock())
}

/// Withdraw the account's USDC down to exactly `remaining`, with owner auth
/// from the current sender.
public fun withdraw_down_to(q: &mut QueueTest, remaining: u64) {
    let amount = q.balance() - remaining;
    let QueueTest { fx, account, .. } = q;
    let (wrapper, root) = account.account_parts_mut();
    let (clock, ctx) = fx.clock_and_ctx();
    let auth = account::generate_auth(ctx);
    let coin = account::withdraw_funds<USDC>(wrapper, auth, amount, root, clock, ctx);
    std::unit_test::destroy(coin);
}

public fun set_clock(q: &mut QueueTest, timestamp_ms: u64) {
    q.fx.set_clock_for_testing(timestamp_ms);
}

/// Move the clock to `timestamp_ms` with fresh live feeds there, so a placement
/// passes the freshness checks.
public fun refresh_oracle_at(q: &mut QueueTest, timestamp_ms: u64) {
    q.fx.advance_live_oracle_bundle_to(&mut q.market, live_price(), timestamp_ms);
}

// === Admin ===

public fun set_timing(
    q: &mut QueueTest,
    delay_ms: u64,
    stall_timeout_ms: u64,
    stuck_threshold_ms: u64,
    gap_wait_ms: u64,
    pyth_price_buffer_ms: u64,
    pyth_channel: u8,
) {
    let QueueTest { fx, market, desk, .. } = q;
    let (admin_cap, clock, _) = fx.admin_parts();
    desk.set_timing(
        admin_cap,
        helpers::config(market),
        delay_ms,
        stall_timeout_ms,
        stuck_threshold_ms,
        gap_wait_ms,
        pyth_price_buffer_ms,
        pyth_channel,
        SVI_MAX_AGE_MS,
        clock,
    );
}

/// The fixture timing on `channel` with a price buffer of `buffer_ms`.
public fun set_channel(q: &mut QueueTest, channel: u8, buffer_ms: u64) {
    q.set_timing(
        FIXTURE_DELAY_MS,
        STALL_TIMEOUT_MS,
        STUCK_THRESHOLD_MS,
        GAP_WAIT_MS,
        buffer_ms,
        channel,
    );
}

public fun set_limits(
    q: &mut QueueTest,
    mint_capacity: u64,
    sell_capacity: u64,
    per_account_cap: u64,
    min_sell_quantity: u64,
    settle_refund_batch: u64,
    settle_payout_batch: u64,
) {
    let QueueTest { fx, market, desk, .. } = q;
    let (admin_cap, clock, _) = fx.admin_parts();
    desk.set_limits(
        admin_cap,
        helpers::config(market),
        mint_capacity,
        sell_capacity,
        per_account_cap,
        min_sell_quantity,
        settle_refund_batch,
        settle_payout_batch,
        clock,
    );
}

public fun set_order_fee(q: &mut QueueTest, order_fee: u64) {
    let QueueTest { fx, market, desk, .. } = q;
    let (admin_cap, clock, _) = fx.admin_parts();
    desk.set_order_fee(admin_cap, helpers::config(market), order_fee, clock);
}

public fun set_frozen(q: &mut QueueTest, frozen: bool) {
    q.fx.set_frozen_bundle(&mut q.market, frozen);
}

/// Set Predict's referral share of the trader-paid trading fee.
public fun set_referral_fee_rate(q: &mut QueueTest, rate: u64) {
    q.fx.set_referral_fee_rate_bundle(&mut q.market, rate);
}

public fun set_trading_paused(q: &mut QueueTest, paused: bool) {
    q.fx.set_trading_paused_bundle(&mut q.market, paused);
}

/// Pause or unpause mints on this market.
public fun set_mint_paused(q: &mut QueueTest, paused: bool) {
    q.fx.set_expiry_mint_paused_bundle(&mut q.market, paused);
}

/// Allowlist or remove this companion's witness in Predict.
public fun set_witness(q: &mut QueueTest, enabled: bool) {
    let QueueTest { fx, market, .. } = q;
    let (admin_cap, clock, _) = fx.admin_parts();
    helpers::config_mut(market).set_order_flow<OrderFlow>(admin_cap, enabled, clock);
}

/// Start a pool flush and hold its snapshot stage open.
public fun start_snapshot(q: &mut QueueTest): SnapshotStage {
    q.fx.start_flush_bundle_stage(&mut q.market)
}

/// Run Predict's `rebalance_expiry_cash` on the market.
public fun rebalance(q: &mut QueueTest) {
    q.fx.rebalance_expiry_cash_bundle(&mut q.market);
}

/// Sponsor `amount` of fee incentives and move them into the market.
public fun fund_incentives(q: &mut QueueTest, amount: u64) {
    q.fx.sponsor_fee_incentives_bundle(&mut q.market, amount);
    q.fx.rebalance_expiry_cash_bundle(&mut q.market);
}

// === Placement ===

public fun enqueue_quantity(
    q: &mut QueueTest,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    max_cost: u64,
    max_probability: u64,
): u64 {
    let QueueTest { fx, market, account, desk, queue, .. } = q;
    let (expiry_market, config, oracle_registry, pyth, bs) = market.market_parts_mut();
    let (wrapper, root) = account.account_parts_mut();
    let (clock, ctx) = fx.clock_and_ctx();
    let auth = account::generate_auth(ctx);
    queue.enqueue_exact_quantity(
        expiry_market,
        wrapper,
        auth,
        desk,
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

/// An exact-quantity mint over `(strike, +inf]` with no probability cap.
public fun enqueue_atm(q: &mut QueueTest, quantity: u64, max_cost: u64): u64 {
    q.enqueue_quantity(
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        quantity,
        max_cost,
        std::u64::max_value!(),
    )
}

public fun enqueue_amount(
    q: &mut QueueTest,
    lower_tick: u64,
    higher_tick: u64,
    max_premium: u64,
    min_quantity: u64,
    max_cost: u64,
): u64 {
    let QueueTest { fx, market, account, desk, queue, .. } = q;
    let (expiry_market, config, oracle_registry, pyth, bs) = market.market_parts_mut();
    let (wrapper, root) = account.account_parts_mut();
    let (clock, ctx) = fx.clock_and_ctx();
    let auth = account::generate_auth(ctx);
    queue.enqueue_exact_amount(
        expiry_market,
        wrapper,
        auth,
        desk,
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

public fun enqueue_cost(
    q: &mut QueueTest,
    lower_tick: u64,
    higher_tick: u64,
    max_cost: u64,
    min_quantity: u64,
): u64 {
    let QueueTest { fx, market, account, desk, queue, .. } = q;
    let (expiry_market, config, oracle_registry, pyth, bs) = market.market_parts_mut();
    let (wrapper, root) = account.account_parts_mut();
    let (clock, ctx) = fx.clock_and_ctx();
    let auth = account::generate_auth(ctx);
    queue.enqueue_exact_cost(
        expiry_market,
        wrapper,
        auth,
        desk,
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

public fun enqueue_sell(
    q: &mut QueueTest,
    record_id: u64,
    close_quantity: u64,
    min_probability: u64,
    min_proceeds: u64,
): u64 {
    let QueueTest { fx, market, account, desk, queue, .. } = q;
    let (expiry_market, config, oracle_registry, pyth, bs) = market.market_parts_mut();
    let (wrapper, root) = account.account_parts_mut();
    let (clock, ctx) = fx.clock_and_ctx();
    let auth = account::generate_auth(ctx);
    queue.enqueue_redeem_open(
        expiry_market,
        wrapper,
        auth,
        desk,
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

// === Commit, resolve, refunds, settlement ===

public fun commit(q: &mut QueueTest, updates: vector<TestUpdate>) {
    let QueueTest { fx, market, desk, queue, .. } = q;
    let (expiry_market, config, _, _, _) = market.market_parts_mut();
    let (clock, ctx) = fx.clock_and_ctx();
    queue.commit_for_testing(expiry_market, desk, config, updates, clock, ctx);
}

/// Move the clock to `tick_ms` and commit the 200 ms update stamped and
/// generated there at `spot`.
public fun commit_at(q: &mut QueueTest, tick_ms: u64, spot: u64) {
    q.set_clock(tick_ms);
    q.commit(vector[price_update(tick_ms, spot)]);
}

public fun resolve(q: &mut QueueTest, max_orders: u64): u64 {
    let QueueTest { fx, market, desk, queue, .. } = q;
    let (expiry_market, config, _, _, _) = market.market_parts_mut();
    let (clock, ctx) = fx.clock_and_ctx();
    queue.resolve(expiry_market, desk, config, max_orders, clock, ctx)
}

public fun refund(q: &mut QueueTest, max_orders: u64): u64 {
    let QueueTest { fx, market, desk, queue, .. } = q;
    let (expiry_market, config, _, _, _) = market.market_parts_mut();
    let (clock, ctx) = fx.clock_and_ctx();
    queue.refund(expiry_market, desk, config, max_orders, clock, ctx)
}

/// Admin-refund `record_ids` with the fixture's `AdminCap`.
public fun admin_refund(q: &mut QueueTest, record_ids: vector<u64>) {
    let QueueTest { fx, market, desk, queue, .. } = q;
    let (expiry_market, config, _, _, _) = market.market_parts_mut();
    let (admin_cap, clock, ctx) = fx.admin_parts();
    queue.admin_refund(expiry_market, admin_cap, desk, config, record_ids, clock, ctx);
}

public fun cleanup(q: &mut QueueTest, record_ids: vector<u64>) {
    let QueueTest { fx, market, desk, queue, .. } = q;
    queue.cleanup(helpers::market(market), desk, record_ids, fx.clock());
}

public fun settle_step(q: &mut QueueTest): u8 {
    let QueueTest { fx, market, desk, queue, .. } = q;
    let (expiry_market, config, _, _, _) = market.market_parts_mut();
    let (clock, ctx) = fx.clock_and_ctx();
    queue.settle_step(expiry_market, desk, config, clock, ctx)
}

/// Settle the market at its expiry from an exact Pyth observation of `spot`.
public fun settle_market(q: &mut QueueTest, spot: u64) {
    let expiry = q.market().expiry();
    q.set_clock(expiry);
    q.fx.insert_exact_settlement_spot_bundle(&mut q.market, spot);
    assert!(q.fx.try_settle_bundle(&mut q.market));
}

public fun load_pricer(q: &mut QueueTest): Pricer {
    q.fx.load_pricer_bundle(&q.market)
}

public fun quote_redeem_open(
    q: &mut QueueTest,
    pricer: &Pricer,
    record_id: u64,
    close_quantity: u64,
): RedeemQuote {
    let QueueTest { fx, market, account, queue, .. } = q;
    let (wrapper, _) = account.account_parts_mut();
    queue.quote_redeem_open(
        helpers::market(market),
        wrapper,
        pricer,
        record_id,
        close_quantity,
        fx.clock(),
    )
}

/// `quote_redeem_open` against a live pricer loaded on a separate clock at
/// `timestamp_ms`, which also prices the fee.
public fun quote_redeem_open_at(
    q: &mut QueueTest,
    record_id: u64,
    close_quantity: u64,
    timestamp_ms: u64,
): RedeemQuote {
    let QueueTest { fx, market, account, queue, .. } = q;
    let ctx = fx.scenario_mut().ctx();
    let mut quote_clock = clock::create_for_testing(ctx);
    quote_clock.set_for_testing(timestamp_ms);
    let expiry_market = helpers::market(market);
    let pricer = expiry_market.load_live_pricer(
        helpers::config(market),
        helpers::oracle_registry(market),
        helpers::pyth(market),
        helpers::bs_values(market),
        helpers::bs_svi(market),
        &quote_clock,
        ctx,
    );
    let (wrapper, _) = account.account_parts_mut();
    let quote = queue.quote_redeem_open(
        expiry_market,
        wrapper,
        &pricer,
        record_id,
        close_quantity,
        &quote_clock,
    );
    quote_clock.destroy_for_testing();
    quote
}

// === Updates ===

/// A usable 200 ms update for the fixture feed, stamped and generated at
/// `envelope_ms`.
public fun price_update(envelope_ms: u64, spot: u64): TestUpdate {
    update_on(CHANNEL_200MS, envelope_ms, spot)
}

public fun update_on(channel: u8, envelope_ms: u64, spot: u64): TestUpdate {
    update_with(channel, envelope_ms * US_PER_MS, envelope_ms * US_PER_MS, spot)
}

/// One feed priced at `spot` with an explicit µs envelope and generation time.
public fun update_with(channel: u8, envelope_us: u64, generation_us: u64, spot: u64): TestUpdate {
    let feed_id = test_constants::pyth_feed_id();
    queue::new_test_update(
        channel,
        envelope_us,
        vector[feed_id],
        vector[
            option::some(
                lazer_price::new_for_testing(feed_id, channel, envelope_us, generation_us, spot),
            ),
        ],
    )
}

/// An update that carries the fixture feed with no price at that tick.
public fun empty_update(channel: u8, envelope_ms: u64): TestUpdate {
    queue::new_test_update(
        channel,
        envelope_ms * US_PER_MS,
        vector[test_constants::pyth_feed_id()],
        vector[option::none()],
    )
}

// === Invariants ===

/// Sum of budget, order fee, and reserved subsidy over the unfinished records.
public fun escrow_sum(q: &QueueTest): u64 {
    let (_, next_id, _, _) = q.queue.queue_heads();
    let mut sum = 0;
    next_id.do!(|record_id| {
        q.queue.order(record_id).do!(|view| {
            if (order_queue::is_unfinished(view.status())) {
                let escrow = view.escrow();
                sum = sum + escrow.budget() + escrow.order_fee() + escrow.subsidy_reserved();
            };
        });
    });
    sum
}

/// USDC every record escrows.
public fun funds_sum(q: &QueueTest): u64 {
    let (_, next_id, _, _) = q.queue.queue_heads();
    let mut sum = 0;
    next_id.do!(|record_id| q.queue.order(record_id).do!(|view| sum = sum + view.funds()));
    sum
}

/// Sum of cash need over the unfinished records.
public fun cash_need_sum(q: &QueueTest): u64 {
    let (_, next_id, _, _) = q.queue.queue_heads();
    let mut sum = 0;
    next_id.do!(|record_id| {
        q.queue.order(record_id).do!(|view| {
            if (order_queue::is_unfinished(view.status())) sum = sum + view.escrow().cash_need();
        });
    });
    sum
}

/// The escrowed USDC is exactly the unfinished records' budget, fee, and
/// reserved subsidy, and Predict's waiting cash need is exactly their summed
/// cash need.
public fun assert_invariants(q: &QueueTest) {
    assert_eq!(q.funds_sum(), q.escrow_sum());
    let (waiting_cash_need, _) = q.ledger();
    assert_eq!(waiting_cash_need, q.cash_need_sum());
}

public fun assert_backed(q: &QueueTest) {
    helpers::assert_market_backed_bundle(&q.market);
}
