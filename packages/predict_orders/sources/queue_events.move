// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Delayed-execution queue events moved out of `deepbook_predict::order_events`
/// for the companion package port. Not yet ported. Per the split design these
/// events originate at the companion package. `OrderMinted` and
/// `LiveOrderRedeemed` stay Predict events, emitted by Predict's fills. The
/// queue events (`OrderEnqueued`, `QueuedOrderFilled`, `QueuedOrderRefunded`)
/// carry the market's post-call cash, required cash, and waiting cash need, so
/// the keeper tracks spare cash from events alone.
module deepbook_predict_orders::queue_events;

use deepbook_predict::pricing::VolSnapshot;
use deepbook_predict_orders::order_queue::{OrderRequest, HeldPosition, OrderTiming};
use sui::event;

/// Emitted when a mint or early sell joins the delayed-execution queue.
public struct OrderEnqueued has copy, drop, store {
    expiry_market_id: ID,
    record_id: u64,
    account_id: ID,
    /// An `order_queue` kind code.
    kind: u8,
    request: OrderRequest,
    /// The position a sell moved into the record; zero for a mint.
    position: HeldPosition,
    timing: OrderTiming,
    vol: VolSnapshot,
    budget: u64,
    order_fee: u64,
    /// The order's worst-case cash need, added to the waiting total.
    cash_need: u64,
    subsidy_bound: u64,
    builder_code_id: Option<ID>,
    referrer_account_id: Option<ID>,
    /// The Open record a sell took its position from. `none` for a mint.
    source_record_id: Option<u64>,
    /// The market's cash, required cash, and waiting cash need after the call.
    market_cash: u64,
    required_cash: u64,
    waiting_cash_need: u64,
}

/// Emitted when commit attaches a Pyth Lazer price to one cohort. Price and
/// exponent are magnitude and sign, so the layout does not depend on Pyth's
/// integer types.
public struct CohortCommitted has copy, drop, store {
    expiry_market_id: ID,
    tau_ms: u64,
    /// The update's envelope in ms: τ, or a later backup tick.
    tick_ms: u64,
    first_record_id: u64,
    last_record_id: u64,
    price_magnitude: u64,
    price_is_negative: bool,
    exponent_magnitude: u16,
    exponent_is_negative: bool,
    /// The feed's own update time, in µs.
    generation_us: u64,
    pyth_source_id: u32,
    pyth_channel: u8,
    /// The transaction sender, so monitoring sees commits by third parties.
    sender: address,
    onchain_timestamp_ms: u64,
}

/// Emitted when resolve fills a queued order, next to the unchanged
/// `OrderMinted` or `LiveOrderRedeemed`.
public struct QueuedOrderFilled has copy, drop, store {
    /// The market's cash, required cash, and waiting cash need after the call.
    market_cash: u64,
    required_cash: u64,
    waiting_cash_need: u64,
    expiry_market_id: ID,
    record_id: u64,
    account_id: ID,
    kind: u8,
    /// Filled quantity (mint) or closed quantity (sell).
    quantity: u64,
    /// Cost paid (mint) or proceeds (sell).
    amount: u64,
    trading_fee: u64,
    builder_fee: u64,
    referral_fee: u64,
    order_fee: u64,
    /// Reserved fee subsidy the fill used.
    subsidy_used: u64,
    inventory_impact: u64,
    tau_ms: u64,
    tick_ms: u64,
    /// The position the record now holds: a mint's new position or a partial
    /// sell's replacement; zero after a full close.
    position: HeldPosition,
    sender: address,
    onchain_timestamp_ms: u64,
}

/// Emitted after every call to the shared refund routine. `sender` is `@0x0`
/// when `try_settle`, which has no transaction context, refunded the order.
public struct QueuedOrderRefunded has copy, drop, store {
    /// The market's cash, required cash, and waiting cash need after the call.
    market_cash: u64,
    required_cash: u64,
    waiting_cash_need: u64,
    expiry_market_id: ID,
    record_id: u64,
    account_id: ID,
    kind: u8,
    /// An `order_queue` reason code.
    reason: u8,
    escrow_returned: u64,
    order_fee_returned: u64,
    subsidy_returned: u64,
    /// True when a sell's position went back to its Open record.
    position_returned: bool,
    sender: address,
    onchain_timestamp_ms: u64,
}

/// Emitted next to `QueuedOrderRefunded` when escrow held less than the record
/// was owed. `owed` is budget plus order fee plus reserved subsidy; `paid` is
/// what escrow covered.
public struct EscrowShortfall has copy, drop, store {
    expiry_market_id: ID,
    record_id: u64,
    owed: u64,
    paid: u64,
    onchain_timestamp_ms: u64,
}

/// Emitted when `cleanup` deletes at least one finished record.
public struct QueuedOrdersCleaned has copy, drop, store {
    expiry_market_id: ID,
    record_ids: vector<u64>,
    onchain_timestamp_ms: u64,
}

/// Emitted when settlement moves leftover queue escrow into market cash.
public struct QueueEscrowSwept has copy, drop, store {
    expiry_market_id: ID,
    amount: u64,
    onchain_timestamp_ms: u64,
}

/// Emitted when the `try_settle` payout walk pays an Open record, with
/// `payout` 0 for a loser.
public struct OpenRecordSettled has copy, drop, store {
    expiry_market_id: ID,
    record_id: u64,
    account_id: ID,
    order_id: u256,
    payout: u64,
    onchain_timestamp_ms: u64,
}

/// Emitted when the `try_settle` payout walk cannot pay an Open record. The
/// record stays Open.
public struct OpenRecordPayoutSkipped has copy, drop, store {
    expiry_market_id: ID,
    record_id: u64,
    account_id: ID,
    order_id: u256,
    payout: u64,
    onchain_timestamp_ms: u64,
}

/// Emitted once per market, by the `try_settle` call that finishes the payout
/// walk (or by the settling call of a market without a queue).
public struct MarketPayoutsCompleted has copy, drop, store {
    expiry_market_id: ID,
    onchain_timestamp_ms: u64,
}

// === Public-Package Functions ===

public(package) fun emit_order_enqueued(
    expiry_market_id: ID,
    record_id: u64,
    account_id: ID,
    kind: u8,
    request: OrderRequest,
    position: HeldPosition,
    timing: OrderTiming,
    vol: VolSnapshot,
    budget: u64,
    order_fee: u64,
    cash_need: u64,
    subsidy_bound: u64,
    builder_code_id: Option<ID>,
    referrer_account_id: Option<ID>,
    source_record_id: Option<u64>,
    market_cash: u64,
    required_cash: u64,
    waiting_cash_need: u64,
) {
    event::emit(OrderEnqueued {
        expiry_market_id,
        record_id,
        account_id,
        kind,
        request,
        position,
        timing,
        vol,
        budget,
        order_fee,
        cash_need,
        subsidy_bound,
        builder_code_id,
        referrer_account_id,
        source_record_id,
        market_cash,
        required_cash,
        waiting_cash_need,
    });
}

public(package) fun emit_cohort_committed(
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
) {
    event::emit(CohortCommitted {
        expiry_market_id,
        tau_ms,
        tick_ms,
        first_record_id,
        last_record_id,
        price_magnitude,
        price_is_negative,
        exponent_magnitude,
        exponent_is_negative,
        generation_us,
        pyth_source_id,
        pyth_channel,
        sender,
        onchain_timestamp_ms,
    });
}

public(package) fun emit_queued_order_filled(
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
    position: HeldPosition,
    sender: address,
    onchain_timestamp_ms: u64,
) {
    event::emit(QueuedOrderFilled {
        market_cash,
        required_cash,
        waiting_cash_need,
        expiry_market_id,
        record_id,
        account_id,
        kind,
        quantity,
        amount,
        trading_fee,
        builder_fee,
        referral_fee,
        order_fee,
        subsidy_used,
        inventory_impact,
        tau_ms,
        tick_ms,
        position,
        sender,
        onchain_timestamp_ms,
    });
}

public(package) fun emit_queued_order_refunded(
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
) {
    event::emit(QueuedOrderRefunded {
        market_cash,
        required_cash,
        waiting_cash_need,
        expiry_market_id,
        record_id,
        account_id,
        kind,
        reason,
        escrow_returned,
        order_fee_returned,
        subsidy_returned,
        position_returned,
        sender,
        onchain_timestamp_ms,
    });
}

public(package) fun emit_escrow_shortfall(
    expiry_market_id: ID,
    record_id: u64,
    owed: u64,
    paid: u64,
    onchain_timestamp_ms: u64,
) {
    event::emit(EscrowShortfall { expiry_market_id, record_id, owed, paid, onchain_timestamp_ms });
}

public(package) fun emit_queued_orders_cleaned(
    expiry_market_id: ID,
    record_ids: vector<u64>,
    onchain_timestamp_ms: u64,
) {
    event::emit(QueuedOrdersCleaned { expiry_market_id, record_ids, onchain_timestamp_ms });
}

public(package) fun emit_queue_escrow_swept(
    expiry_market_id: ID,
    amount: u64,
    onchain_timestamp_ms: u64,
) {
    event::emit(QueueEscrowSwept { expiry_market_id, amount, onchain_timestamp_ms });
}

public(package) fun emit_open_record_settled(
    expiry_market_id: ID,
    record_id: u64,
    account_id: ID,
    order_id: u256,
    payout: u64,
    onchain_timestamp_ms: u64,
) {
    event::emit(OpenRecordSettled {
        expiry_market_id,
        record_id,
        account_id,
        order_id,
        payout,
        onchain_timestamp_ms,
    });
}

public(package) fun emit_open_record_payout_skipped(
    expiry_market_id: ID,
    record_id: u64,
    account_id: ID,
    order_id: u256,
    payout: u64,
    onchain_timestamp_ms: u64,
) {
    event::emit(OpenRecordPayoutSkipped {
        expiry_market_id,
        record_id,
        account_id,
        order_id,
        payout,
        onchain_timestamp_ms,
    });
}

public(package) fun emit_market_payouts_completed(expiry_market_id: ID, onchain_timestamp_ms: u64) {
    event::emit(MarketPayoutsCompleted { expiry_market_id, onchain_timestamp_ms });
}
