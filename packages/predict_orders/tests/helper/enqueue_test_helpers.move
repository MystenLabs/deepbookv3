// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Bring-ups and steps shared by the queued-placement (`enqueue_*`) flow tests:
/// a queue market whose trader already holds a pre-cutover position, a queue
/// market with an exact amount of expiry cash, the commit and resolve that turn a
/// queued mint into an Open record, and an exact account balance for the fee
/// boundary.
#[test_only]
module deepbook_predict::enqueue_test_helpers;

use account::account;
use deepbook_predict::{
    flow_test_helpers::{Self as helpers, Fixture, Trader, MarketBundle, AccountBundle},
    order_queue,
    queue_test_helpers as queue,
    test_constants
};
use std::unit_test::{assert_eq, destroy};
use usdc::usdc::USDC;

/// Pyth Lazer `fixed_rate@200ms`, the policy's default channel.
const CHANNEL_200MS: u8 = 3;
/// Lazer exponent `-9`, so a price magnitude reads directly at Predict's 1e9 scale.
const NEG_EXPONENT_9: u16 = 9;

/// The default-price live market at `expiry_ms`, where alice minted `quantity`
/// over `(strike_tick, +inf]` through the immediate path while the watermark still
/// named the previous version, then the policy and the cutover. Returns
/// `(fixture, expiry_id, alice, order_id)`; the position opened at
/// `test_constants::now_ms()` with itself as root.
public fun setup_queue_market_with_position(
    expiry_ms: u64,
    quantity: u64,
): (Fixture, ID, Trader, u256) {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        expiry_ms,
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        quantity,
    );
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.init_delayed_execution();
    fx.cutover();
    (fx, expiry_id, trader, order_id)
}

/// A default-price live market at `expiry_ms` holding exactly `cash` of expiry
/// cash and no position, so its spare cash is `cash`; alice funded with
/// `mint_deposit`; then the policy and the cutover. Returns
/// `(fixture, expiry_id, alice)`.
public fun setup_queue_market_with_cash(expiry_ms: u64, cash: u64): (Fixture, ID, Trader) {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(expiry_ms);
    let trader = fx.create_funded_manager(test_constants::mint_deposit());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.seed_market_cash(market.market_mut(), cash);
    // The bring-up itself: a fresh market from an empty pool starts with no cash
    // and no liability, so the seed is all of it.
    assert_eq!(market.market().cash_balance(), cash);
    assert_eq!(market.market().required_cash(), 0);
    helpers::return_market_bundle(market);
    fx.init_delayed_execution();
    fx.cutover();
    (fx, expiry_id, trader)
}

/// Commit the cohort at `tau_ms` with one Lazer tick at the default live price,
/// generated exactly at τ, then resolve up to `max_orders` records. The caller
/// sets the clock at or past τ and before the cohort's deadline.
public fun commit_and_resolve(
    fx: &mut Fixture,
    market: &mut MarketBundle,
    tau_ms: u64,
    max_orders: u64,
): u64 {
    commit_cohort(fx, market, tau_ms);
    queue::resolve(fx, market, max_orders)
}

/// Commit the cohort at `tau_ms` only, with one Lazer tick at the default live
/// price generated exactly at τ.
public fun commit_cohort(fx: &mut Fixture, market: &mut MarketBundle, tau_ms: u64) {
    let tick = queue::lazer_tick(
        tau_ms,
        CHANNEL_200MS,
        test_constants::pyth_feed_id(),
        test_constants::default_live_price(),
        NEG_EXPONENT_9,
        tau_ms * 1000,
    );
    queue::commit_decoded(fx, market, vector[tick]);
}

/// Enqueue `trader`'s exact-quantity mint over `(strike_tick, +inf]` at the
/// current clock, move the clock to `fill_at_ms`, then commit its cohort and
/// resolve it, so the record is Open. Returns the record ID. The order's τ must
/// lie at or before `fill_at_ms`, inside its deadline.
public fun fill_exact_quantity(
    fx: &mut Fixture,
    expiry_id: ID,
    trader: &Trader,
    quantity: u64,
    max_cost: u64,
    fill_at_ms: u64,
): u64 {
    fx.scenario_mut().next_tx(trader.owner());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(trader);
    let record_id = queue::enqueue_exact_quantity(
        fx,
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        quantity,
        max_cost,
        std::u64::max_value!(),
    );
    let tau_ms = market.market().queued_order(record_id).destroy_some().timing().tau_ms();
    fx.set_clock_for_testing(fill_at_ms);
    commit_and_resolve(fx, &mut market, tau_ms, 1);
    assert_eq!(
        market.market().queued_order(record_id).destroy_some().status(),
        order_queue::status_open(),
    );
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    record_id
}

/// Withdraw the bundled account's USDC down to exactly `remaining`, with owner
/// auth from the current sender.
public fun withdraw_down_to(fx: &mut Fixture, account: &mut AccountBundle, remaining: u64) {
    let balance = fx.account_balance_bundle<USDC>(account);
    let (wrapper, root) = account.account_parts_mut();
    let (clock, ctx) = fx.clock_and_ctx();
    let auth = account::generate_auth(ctx);
    let coin = account::withdraw_funds<USDC>(wrapper, auth, balance - remaining, root, clock, ctx);
    destroy(coin);
}
