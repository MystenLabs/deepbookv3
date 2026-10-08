// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Readers for the queue events emitted in the current transaction. The events
/// carry no getters, so each reader decodes the BCS bytes into a local view in
/// field order: a layout change in `queue_events` breaks these readers loudly
/// instead of passing silently.
#[test_only]
module deepbook_predict_orders::queue_event_views;

use deepbook_predict_orders::queue_events::{
    CohortCommitted,
    QueuedOrderFilled,
    QueuedOrderRefunded,
    OpenRecordSettled,
    OpenRecordPayoutSkipped,
    MarketPayoutsCompleted,
    QueuedOrdersCleaned,
};
use std::bcs;
use sui::{bcs as sui_bcs, event};

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

public fun refund_market_cash(refund: &RefundView): u64 { refund.market_cash }

public fun refund_waiting_cash_need(refund: &RefundView): u64 { refund.waiting_cash_need }

public fun refund_record_id(refund: &RefundView): u64 { refund.record_id }

public fun refund_account_id(refund: &RefundView): ID { refund.account_id }

public fun refund_kind(refund: &RefundView): u8 { refund.kind }

public fun refund_reason(refund: &RefundView): u8 { refund.reason }

public fun refund_escrow_returned(refund: &RefundView): u64 { refund.escrow_returned }

public fun refund_order_fee_returned(refund: &RefundView): u64 { refund.order_fee_returned }

public fun refund_subsidy_returned(refund: &RefundView): u64 { refund.subsidy_returned }

public fun refund_position_returned(refund: &RefundView): bool { refund.position_returned }

public fun refund_sender(refund: &RefundView): address { refund.sender }

public fun refund_onchain_timestamp_ms(refund: &RefundView): u64 { refund.onchain_timestamp_ms }

// === CohortCommitted ===

public struct CommitView has copy, drop {
    expiry_market_id: ID,
    tau_ms: u64,
    tick_ms: u64,
    first_record_id: u64,
    last_record_id: u64,
    spot: u64,
    generation_us: u64,
    pyth_source_id: u32,
    pyth_channel: u8,
    sender: address,
    onchain_timestamp_ms: u64,
}

public fun commits(): vector<CommitView> {
    event::events_by_type<CohortCommitted>().map!(|committed| {
        let mut bytes = sui_bcs::new(bcs::to_bytes(&committed));
        CommitView {
            expiry_market_id: bytes.peel_address().to_id(),
            tau_ms: bytes.peel_u64(),
            tick_ms: bytes.peel_u64(),
            first_record_id: bytes.peel_u64(),
            last_record_id: bytes.peel_u64(),
            spot: bytes.peel_u64(),
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

public fun commit_spot(commit: &CommitView): u64 { commit.spot }

public fun commit_generation_us(commit: &CommitView): u64 { commit.generation_us }

public fun commit_pyth_source_id(commit: &CommitView): u32 { commit.pyth_source_id }

public fun commit_pyth_channel(commit: &CommitView): u8 { commit.pyth_channel }

public fun commit_sender(commit: &CommitView): address { commit.sender }

public fun commit_onchain_timestamp_ms(commit: &CommitView): u64 { commit.onchain_timestamp_ms }

// === Settlement and cleanup ===

/// `(record_id, account_id, order_id, payout)` of one payout event.
public struct PayoutView has copy, drop {
    expiry_market_id: ID,
    record_id: u64,
    account_id: ID,
    order_id: u256,
    payout: u64,
    onchain_timestamp_ms: u64,
}

public fun settled(): vector<PayoutView> {
    event::events_by_type<OpenRecordSettled>().map!(|paid| peel_payout(bcs::to_bytes(&paid)))
}

public fun skipped(): vector<PayoutView> {
    event::events_by_type<OpenRecordPayoutSkipped>().map!(
        |skipped| peel_payout(bcs::to_bytes(&skipped)),
    )
}

public fun payout_record_id(view: &PayoutView): u64 { view.record_id }

public fun payout_account_id(view: &PayoutView): ID { view.account_id }

public fun payout_order_id(view: &PayoutView): u256 { view.order_id }

public fun payout(view: &PayoutView): u64 { view.payout }

public fun payouts_completed_count(): u64 {
    event::events_by_type<MarketPayoutsCompleted>().length()
}

/// The record IDs of every `QueuedOrdersCleaned` this transaction, in order.
public fun cleaned(): vector<vector<u64>> {
    event::events_by_type<QueuedOrdersCleaned>().map!(|cleaned| {
        let mut bytes = sui_bcs::new(bcs::to_bytes(&cleaned));
        bytes.peel_address();
        bytes.peel_vec_u64()
    })
}

fun peel_payout(raw: vector<u8>): PayoutView {
    let mut bytes = sui_bcs::new(raw);
    PayoutView {
        expiry_market_id: bytes.peel_address().to_id(),
        record_id: bytes.peel_u64(),
        account_id: bytes.peel_address().to_id(),
        order_id: bytes.peel_u256(),
        payout: bytes.peel_u64(),
        onchain_timestamp_ms: bytes.peel_u64(),
    }
}
