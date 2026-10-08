// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Fixtures and event readers for the delayed-execution commit, resolve, and
/// early-sell quote flow tests.
///
/// The queue events carry no getters, so the readers decode them from their BCS
/// bytes into local views in field order. A layout change in `order_events`
/// therefore breaks these readers loudly instead of passing silently.
#[test_only]
module deepbook_predict::commit_resolve_test_helpers;

use deepbook_predict::{
    expiry_market::LazerTick,
    flow_test_helpers::{Self as helpers, Fixture, Trader, MarketBundle, AccountBundle},
    order_events::{CohortCommitted, QueuedOrderFilled, QueuedOrderRefunded},
    order_queue::QueuedOrder,
    queue_test_helpers,
    test_constants
};
use std::bcs;
use sui::{bcs as sui_bcs, event};

/// Pyth Lazer's `fixed_rate@200ms` channel id, the policy's default channel.
const CHANNEL_200MS: u8 = 3;
/// Every fixture price carries exponent `-9`, so the raw Lazer price is already
/// at Predict's 1e9 scale.
const NEG_EXPONENT_9: u16 = 9;
const US_PER_MS: u64 = 1_000;

public fun channel_200ms(): u8 { CHANNEL_200MS }

/// A usable `fixed_rate@200ms` update for the fixture's Pyth feed, stamped
/// `envelope_ms` and generated at the envelope itself.
public fun price_tick(envelope_ms: u64, spot: u64): LazerTick {
    queue_test_helpers::lazer_tick(
        envelope_ms,
        CHANNEL_200MS,
        test_constants::pyth_feed_id(),
        spot,
        NEG_EXPONENT_9,
        envelope_ms * US_PER_MS,
    )
}

/// `queue_test_helpers::setup_queue_market` at the default expiry and live
/// price, except that the market holds exactly `cash`. Market creation moves no
/// cash, so the seed is the whole balance.
public fun setup_queue_market_with_cash(cash: u64): (Fixture, ID, Trader) {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let trader = fx.create_funded_manager(test_constants::mint_deposit());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.seed_market_cash(helpers::market_mut(&mut market), cash);
    std::unit_test::assert_eq!(helpers::market(&market).cash_balance(), cash);
    helpers::return_market_bundle(market);
    fx.scenario_mut().next_tx(test_constants::admin());
    fx.init_delayed_execution();
    fx.cutover();
    (fx, expiry_id, trader)
}

/// Start a transaction as `trader` and take the market and account bundles.
public fun enter(fx: &mut Fixture, expiry_id: ID, trader: &Trader): (MarketBundle, AccountBundle) {
    fx.scenario_mut().next_tx(trader.owner());
    (fx.take_market_bundle(expiry_id), fx.take_account_bundle(trader))
}

/// Return both bundles and end the scenario.
public fun finish(fx: Fixture, market: MarketBundle, account: AccountBundle) {
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// One record that must exist.
public fun record(market: &MarketBundle, record_id: u64): QueuedOrder {
    helpers::market(market).queued_order(record_id).destroy_some()
}

// === QueuedOrderFilled ===

public struct FillView has copy, drop {
    market_cash: u64,
    required_cash: u64,
    waiting_cash_need: u64,
    expiry_market_id: ID,
    record_id: u64,
    account_id: ID,
    kind: u8,
    quantity: u64,
    amount: u64,
    trading_fee: u64,
    builder_fee: u64,
    referral_fee: u64,
    order_fee: u64,
    subsidy_used: u64,
    inventory_impact: u64,
    tau_ms: u64,
    tick_ms: u64,
    position_order_id: u256,
    position_root_id: u256,
    position_opened_at_ms: u64,
    sender: address,
    onchain_timestamp_ms: u64,
}

/// `QueuedOrderFilled` events emitted in the current transaction, in order.
public fun fills(): vector<FillView> {
    event::events_by_type<QueuedOrderFilled>().map!(|filled| {
        let mut bytes = sui_bcs::new(bcs::to_bytes(&filled));
        FillView {
            market_cash: bytes.peel_u64(),
            required_cash: bytes.peel_u64(),
            waiting_cash_need: bytes.peel_u64(),
            expiry_market_id: bytes.peel_address().to_id(),
            record_id: bytes.peel_u64(),
            account_id: bytes.peel_address().to_id(),
            kind: bytes.peel_u8(),
            quantity: bytes.peel_u64(),
            amount: bytes.peel_u64(),
            trading_fee: bytes.peel_u64(),
            builder_fee: bytes.peel_u64(),
            referral_fee: bytes.peel_u64(),
            order_fee: bytes.peel_u64(),
            subsidy_used: bytes.peel_u64(),
            inventory_impact: bytes.peel_u64(),
            tau_ms: bytes.peel_u64(),
            tick_ms: bytes.peel_u64(),
            position_order_id: bytes.peel_u256(),
            position_root_id: bytes.peel_u256(),
            position_opened_at_ms: bytes.peel_u64(),
            sender: bytes.peel_address(),
            onchain_timestamp_ms: bytes.peel_u64(),
        }
    })
}

public fun market_cash(fill: &FillView): u64 { fill.market_cash }

public fun required_cash(fill: &FillView): u64 { fill.required_cash }

public fun waiting_cash_need(fill: &FillView): u64 { fill.waiting_cash_need }

public fun expiry_market_id(fill: &FillView): ID { fill.expiry_market_id }

public fun record_id(fill: &FillView): u64 { fill.record_id }

public fun account_id(fill: &FillView): ID { fill.account_id }

public fun kind(fill: &FillView): u8 { fill.kind }

public fun quantity(fill: &FillView): u64 { fill.quantity }

public fun amount(fill: &FillView): u64 { fill.amount }

public fun trading_fee(fill: &FillView): u64 { fill.trading_fee }

public fun builder_fee(fill: &FillView): u64 { fill.builder_fee }

public fun referral_fee(fill: &FillView): u64 { fill.referral_fee }

public fun order_fee(fill: &FillView): u64 { fill.order_fee }

public fun subsidy_used(fill: &FillView): u64 { fill.subsidy_used }

public fun inventory_impact(fill: &FillView): u64 { fill.inventory_impact }

public fun tau_ms(fill: &FillView): u64 { fill.tau_ms }

public fun tick_ms(fill: &FillView): u64 { fill.tick_ms }

public fun position_order_id(fill: &FillView): u256 { fill.position_order_id }

public fun position_root_id(fill: &FillView): u256 { fill.position_root_id }

public fun position_opened_at_ms(fill: &FillView): u64 { fill.position_opened_at_ms }

public fun sender(fill: &FillView): address { fill.sender }

public fun onchain_timestamp_ms(fill: &FillView): u64 { fill.onchain_timestamp_ms }

// === QueuedOrderRefunded ===

public struct RefundView has copy, drop {
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

/// `QueuedOrderRefunded` events emitted in the current transaction, in order.
public fun refunds(): vector<RefundView> {
    event::events_by_type<QueuedOrderRefunded>().map!(|refunded| {
        let mut bytes = sui_bcs::new(bcs::to_bytes(&refunded));
        RefundView {
            market_cash: bytes.peel_u64(),
            required_cash: bytes.peel_u64(),
            waiting_cash_need: bytes.peel_u64(),
            expiry_market_id: bytes.peel_address().to_id(),
            record_id: bytes.peel_u64(),
            account_id: bytes.peel_address().to_id(),
            kind: bytes.peel_u8(),
            reason: bytes.peel_u8(),
            escrow_returned: bytes.peel_u64(),
            order_fee_returned: bytes.peel_u64(),
            subsidy_returned: bytes.peel_u64(),
            position_returned: bytes.peel_bool(),
            sender: bytes.peel_address(),
            onchain_timestamp_ms: bytes.peel_u64(),
        }
    })
}

public fun refund_record_id(refund: &RefundView): u64 { refund.record_id }

public fun refund_kind(refund: &RefundView): u8 { refund.kind }

public fun refund_reason(refund: &RefundView): u8 { refund.reason }

public fun refund_escrow_returned(refund: &RefundView): u64 { refund.escrow_returned }

public fun refund_order_fee_returned(refund: &RefundView): u64 { refund.order_fee_returned }

public fun refund_subsidy_returned(refund: &RefundView): u64 { refund.subsidy_returned }

public fun refund_position_returned(refund: &RefundView): bool { refund.position_returned }

public fun refund_sender(refund: &RefundView): address { refund.sender }

public fun refund_market_cash(refund: &RefundView): u64 { refund.market_cash }

// === CohortCommitted ===

public struct CommitView has copy, drop {
    expiry_market_id: ID,
    tau_ms: u64,
    tick_ms: u64,
    first_record_id: u64,
    last_record_id: u64,
    price_magnitude: u64,
    price_is_negative: bool,
    exponent_magnitude: u16,
    exponent_is_negative: bool,
    generation_us: u64,
    pyth_source_id: u32,
    pyth_channel: u8,
    sender: address,
    onchain_timestamp_ms: u64,
}

/// `CohortCommitted` events emitted in the current transaction, in order.
public fun commits(): vector<CommitView> {
    event::events_by_type<CohortCommitted>().map!(|committed| {
        let mut bytes = sui_bcs::new(bcs::to_bytes(&committed));
        CommitView {
            expiry_market_id: bytes.peel_address().to_id(),
            tau_ms: bytes.peel_u64(),
            tick_ms: bytes.peel_u64(),
            first_record_id: bytes.peel_u64(),
            last_record_id: bytes.peel_u64(),
            price_magnitude: bytes.peel_u64(),
            price_is_negative: bytes.peel_bool(),
            exponent_magnitude: bytes.peel_u16(),
            exponent_is_negative: bytes.peel_bool(),
            generation_us: bytes.peel_u64(),
            pyth_source_id: bytes.peel_u32(),
            pyth_channel: bytes.peel_u8(),
            sender: bytes.peel_address(),
            onchain_timestamp_ms: bytes.peel_u64(),
        }
    })
}

public fun commit_market_id(commit: &CommitView): ID { commit.expiry_market_id }

public fun commit_tau_ms(commit: &CommitView): u64 { commit.tau_ms }

public fun commit_tick_ms(commit: &CommitView): u64 { commit.tick_ms }

public fun commit_first_record_id(commit: &CommitView): u64 { commit.first_record_id }

public fun commit_last_record_id(commit: &CommitView): u64 { commit.last_record_id }

public fun commit_price_magnitude(commit: &CommitView): u64 { commit.price_magnitude }

public fun commit_price_is_negative(commit: &CommitView): bool { commit.price_is_negative }

public fun commit_exponent_magnitude(commit: &CommitView): u16 { commit.exponent_magnitude }

public fun commit_exponent_is_negative(commit: &CommitView): bool { commit.exponent_is_negative }

public fun commit_generation_us(commit: &CommitView): u64 { commit.generation_us }

public fun commit_pyth_source_id(commit: &CommitView): u32 { commit.pyth_source_id }

public fun commit_pyth_channel(commit: &CommitView): u8 { commit.pyth_channel }

public fun commit_sender(commit: &CommitView): address { commit.sender }

public fun commit_onchain_timestamp_ms(commit: &CommitView): u64 { commit.onchain_timestamp_ms }
