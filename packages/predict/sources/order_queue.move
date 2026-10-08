// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Per-market queue of delayed-execution orders: queued mints and early sells
/// that fill at Pyth's signed price for their τ, or are refunded.
///
/// One `OrderBook` lives under each `ExpiryMarket` UID once its first order is
/// placed. This module owns the book and its records (`QueuedOrder` and its
/// parts), the status, kind, and refund-reason codes, τ and deadline planning,
/// the stuck check, the counters and cohort spans, the escrowed USDC, the
/// payout-tree pins, the cash-need formulas, the one refund routine every
/// finishing path shares, and the walker primitives.
///
/// It emits no events: `order_events` imports this module's types, so the
/// `expiry_market` caller emits from the facts these functions return. Pricing,
/// fills, and every flow gate stay in `expiry_market`.
module deepbook_predict::order_queue;

use deepbook_predict::{
    constants,
    delayed_execution_config::{Self, DelayedExecutionPolicy},
    expiry_cash::ExpiryCash,
    pricing::VolSnapshot,
    strike_exposure::StrikeExposure
};
use fixed_math::math;
use sui::{balance::{Self, Balance}, table::{Self, Table}, vec_map::{Self, VecMap}};
use usdc::usdc::USDC;

// === Codes ===
// Stored in `QueuedOrder` and emitted in events. Never renumbered after publish;
// new codes append.

const STATUS_PENDING: u8 = 0;
const STATUS_COMMITTED: u8 = 1;
const STATUS_OPEN: u8 = 2;
const STATUS_REFUNDED: u8 = 3;
const STATUS_CLOSED: u8 = 4;
/// Reserved: nothing sets it at launch. A record holding it counts as
/// unfinished and is refunded with its stored reason.
const STATUS_REFUND_DUE: u8 = 5;

const KIND_EXACT_QUANTITY: u8 = 0;
const KIND_EXACT_AMOUNT: u8 = 1;
const KIND_EXACT_COST: u8 = 2;
/// Reserved: never used by v4, which sells only Open records
/// (`KIND_REDEEM_OPEN`). Kept so no later kind reuses 3.
const KIND_REDEEM_LIVE: u8 = 3;
const KIND_REDEEM_OPEN: u8 = 4;

/// The order missed its own limits at the tick. Order fee kept.
const REASON_LIMITS: u8 = 1;
/// The order failed mint admission or could not be priced at the tick. Order
/// fee kept.
const REASON_ADMISSION: u8 = 2;
/// Reserved, unused in v4.
const REASON_NO_PRICE: u8 = 3;
/// A pinned payout-tree node was missing at the fill (backstop). Fee returned.
const REASON_MISSING_NODE: u8 = 4;
/// The order reached its deadline unfilled. Fee returned.
const REASON_DEADLINE: u8 = 5;
/// Reserved, unused in v4.
const REASON_FREEZE: u8 = 6;
/// Admin refund. Fee returned.
const REASON_ADMIN: u8 = 7;
/// The market's cash could not cover the fill. Fee returned.
const REASON_NO_CASH: u8 = 8;

/// Every deadline falls at least this long before expiry: the placement
/// cutoff is `expiry - max(no_trade_window_ms, stall_timeout_ms + this)`.
public(package) macro fun deadline_expiry_margin_ms(): u64 { 5_000 }

/// Dynamic-field key of a market's `OrderBook` under its `ExpiryMarket` UID.
public struct OrderBookKey() has copy, drop, store;

/// One market's delayed-execution queue. Created by the market's first enqueue
/// (that trader pays its storage); a market without one reads as empty.
public struct OrderBook has store {
    /// One record per order, keyed by a sequential record ID. Records stay
    /// after they finish until `cleanup` deletes them.
    orders: Table<u64, QueuedOrder>,
    next_id: u64,
    /// Lower bound on the first unfinished record: the first span's `first_id`,
    /// or `next_id` when no span remains.
    resolve_head: u64,
    /// Where the next `try_settle` payout call resumes after settlement. Only
    /// moves forward, and never past `next_id`.
    payout_cursor: u64,
    /// One span per cohort (orders sharing one τ) that still has an unfinished
    /// order, in τ order. Inline, so `value_expiry` loads no extra object.
    cohorts: vector<CohortSpan>,
    /// Keep τ and the deadline non-decreasing along record IDs.
    last_tau_ms: u64,
    /// Newest τ any commit has priced. Never decreases; no new order gets a τ at
    /// or below it.
    last_committed_tau_ms: u64,
    last_deadline_ms: u64,
    /// The newest order's Pyth channel. A channel change forces the next τ
    /// strictly past `last_tau_ms`, so one cohort never mixes channels.
    last_channel: u8,
    /// Waiting orders per payout-tree tick (tick -> count). A pinned node is
    /// never pruned, so a resolve fill never creates one.
    pins: VecMap<u64, u64>,
    /// Unfinished orders per account. A row is created by the account's first
    /// enqueue in this market and never deleted.
    per_account: Table<ID, u64>,
    /// Unfinished mints and sells, against the policy capacities.
    pending_mints: u64,
    pending_sells: u64,
    /// Sum of unfinished orders' cash needs. `rebalance_expiry_cash` funds a live
    /// market to at least required cash plus this, and never sweeps below it.
    waiting_cash_need: u64,
    /// Every unfinished order's budget, order fee, and reserved subsidy. Outside
    /// market cash, NAV, and backing.
    escrow: Balance<USDC>,
}

/// One waiting cohort: every order sharing one τ, which shares its deadline and
/// Pyth channel too. Covers the record IDs `first_id..end_id`.
public struct CohortSpan has copy, drop, store {
    tau_ms: u64,
    deadline_ms: u64,
    /// Lower bound on the cohort's first unfinished record. A walker that stops
    /// inside the span moves it to the first record it did not visit.
    first_id: u64,
    /// Exclusive.
    end_id: u64,
    pyth_channel: u8,
    /// Set once commit attaches the cohort's price. A committed span never grows.
    committed: bool,
    /// Pending, Committed, and RefundDue orders left in the cohort.
    unfinished: u64,
}

/// One queued order. Every field exists from enqueue and is zero until used, so
/// keeper rewrites never grow the record.
public struct QueuedOrder has copy, drop, store {
    /// A `STATUS_*` code. Only moves forward, except that a refunded sell
    /// returns to Open holding its position.
    status: u8,
    /// A `KIND_*` code.
    kind: u8,
    request: OrderRequest,
    parties: OrderParties,
    timing: OrderTiming,
    vol: VolSnapshot,
    escrow: OrderEscrow,
    /// The position the record holds: a sell's position from enqueue, or a
    /// filled mint's new position. Zero otherwise.
    position: HeldPosition,
    price: CommittedPrice,
    result: OrderResult,
}

/// The trader's terms, fixed at enqueue. `quantity` is the exact mint quantity
/// or the sell's close quantity. `max_probability` applies to exact-quantity
/// mints; `min_probability` and `min_proceeds` apply to sells.
public struct OrderRequest has copy, drop, store {
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    max_premium: u64,
    min_quantity: u64,
    max_cost: u64,
    max_probability: u64,
    min_probability: u64,
    min_proceeds: u64,
}

/// Everything resolve and the refunds need without loading the account,
/// snapshotted at enqueue.
public struct OrderParties has copy, drop, store {
    account_id: ID,
    owner: address,
    /// The wrapper's address. Refunds, sell proceeds, and settled payouts go
    /// here through `balance::send_funds`.
    receive_address: address,
    referrer_account_id: Option<ID>,
    referrer_receive_address: Option<address>,
    builder_code_id: Option<ID>,
}

/// The order's clock, fixed at enqueue.
public struct OrderTiming has copy, drop, store {
    /// t₀, the Sui clock of the enqueue transaction.
    placed_at_ms: u64,
    /// τ itself: a price generated before it never commits the order.
    earliest_price_ms: u64,
    /// The channel tick the order is priced on.
    tau_ms: u64,
    /// At or past it the order is refunded, never filled.
    deadline_ms: u64,
    /// `expiry - max(no_trade_window_ms, stall_timeout_ms + 5_000)`; enqueue
    /// requires τ below it.
    cutoff_ms: u64,
    /// The policy channel at enqueue. Commit accepts only updates on it.
    pyth_channel: u8,
}

/// The USDC the order locked, and its fee subsidy.
public struct OrderEscrow has copy, drop, store {
    /// USDC locked for the premium and fees. Sells lock none.
    budget: u64,
    /// Flat fee charged at enqueue.
    order_fee: u64,
    /// The t₀ quote's pre-subsidy trading fee, capped at what the budget could
    /// pay. Bounds the subsidy commit reserves.
    subsidy_bound: u64,
    /// Set at commit; the reserved amount sits in the book's escrow.
    subsidy_rate: u64,
    subsidy_reserved: u64,
    /// Worst-case cash the market could add from its own cash to fill the order.
    cash_need: u64,
}

/// A position a record holds. `order_id` is the packed position ID.
public struct HeldPosition has copy, drop, store {
    order_id: u256,
    root_id: u256,
    opened_at_ms: u64,
}

/// The verified Pyth price commit attached. Zero until commit.
public struct CommittedPrice has copy, drop, store {
    /// Pyth price normalized to 1e9.
    spot: u64,
    /// The update's envelope in ms: τ, or a later backup tick. Resolve prices at it.
    tick_ms: u64,
    /// The feed's own update time, in µs.
    generation_us: u64,
}

/// How the order finished. Zero until resolve or a refund finishes it.
public struct OrderResult has copy, drop, store {
    /// `0` for a fill, or a `REASON_*` code.
    reason: u8,
    /// Filled quantity (mint) or closed quantity (sell).
    quantity: u64,
    /// Cost paid (mint) or proceeds (sell). Zero on a refund.
    amount: u64,
    /// Sui clock of the finishing transaction.
    finished_at_ms: u64,
}

/// What the shared refund routine paid out, for the caller's
/// `QueuedOrderRefunded` and `EscrowShortfall` events. `owed` is the record's
/// budget plus order fee plus reserved subsidy; `shortfall` is the part escrow
/// could not pay.
public struct RefundOutcome has copy, drop {
    escrow_returned: u64,
    order_fee_returned: u64,
    subsidy_returned: u64,
    position_returned: bool,
    owed: u64,
    shortfall: u64,
}

// === Public Functions ===
// Code getters, so the SDK and indexer never hard-code numbers.

public fun status_pending(): u8 { STATUS_PENDING }

public fun status_committed(): u8 { STATUS_COMMITTED }

public fun status_open(): u8 { STATUS_OPEN }

public fun status_refunded(): u8 { STATUS_REFUNDED }

public fun status_closed(): u8 { STATUS_CLOSED }

public fun status_refund_due(): u8 { STATUS_REFUND_DUE }

public fun kind_exact_quantity(): u8 { KIND_EXACT_QUANTITY }

public fun kind_exact_amount(): u8 { KIND_EXACT_AMOUNT }

public fun kind_exact_cost(): u8 { KIND_EXACT_COST }

public fun kind_redeem_live(): u8 { KIND_REDEEM_LIVE }

public fun kind_redeem_open(): u8 { KIND_REDEEM_OPEN }

public fun reason_limits(): u8 { REASON_LIMITS }

public fun reason_admission(): u8 { REASON_ADMISSION }

public fun reason_no_price(): u8 { REASON_NO_PRICE }

public fun reason_missing_node(): u8 { REASON_MISSING_NODE }

public fun reason_deadline(): u8 { REASON_DEADLINE }

public fun reason_freeze(): u8 { REASON_FREEZE }

public fun reason_admin(): u8 { REASON_ADMIN }

public fun reason_no_cash(): u8 { REASON_NO_CASH }

// === QueuedOrder Getters ===
// Public for SDK and devInspect reads of `expiry_market::queued_order`.

public fun status(order: &QueuedOrder): u8 { order.status }

public fun kind(order: &QueuedOrder): u8 { order.kind }

public fun request(order: &QueuedOrder): OrderRequest { order.request }

public fun parties(order: &QueuedOrder): OrderParties { order.parties }

public fun timing(order: &QueuedOrder): OrderTiming { order.timing }

public fun vol(order: &QueuedOrder): VolSnapshot { order.vol }

public fun escrow(order: &QueuedOrder): OrderEscrow { order.escrow }

public fun position(order: &QueuedOrder): HeldPosition { order.position }

public fun price(order: &QueuedOrder): CommittedPrice { order.price }

public fun result(order: &QueuedOrder): OrderResult { order.result }

public fun lower_tick(request: &OrderRequest): u64 { request.lower_tick }

public fun higher_tick(request: &OrderRequest): u64 { request.higher_tick }

public fun quantity(request: &OrderRequest): u64 { request.quantity }

public fun max_premium(request: &OrderRequest): u64 { request.max_premium }

public fun min_quantity(request: &OrderRequest): u64 { request.min_quantity }

public fun max_cost(request: &OrderRequest): u64 { request.max_cost }

public fun max_probability(request: &OrderRequest): u64 { request.max_probability }

public fun min_probability(request: &OrderRequest): u64 { request.min_probability }

public fun min_proceeds(request: &OrderRequest): u64 { request.min_proceeds }

public fun account_id(parties: &OrderParties): ID { parties.account_id }

public fun owner(parties: &OrderParties): address { parties.owner }

public fun receive_address(parties: &OrderParties): address { parties.receive_address }

public fun referrer_account_id(parties: &OrderParties): Option<ID> {
    parties.referrer_account_id
}

public fun referrer_receive_address(parties: &OrderParties): Option<address> {
    parties.referrer_receive_address
}

public fun builder_code_id(parties: &OrderParties): Option<ID> { parties.builder_code_id }

public fun placed_at_ms(timing: &OrderTiming): u64 { timing.placed_at_ms }

public fun earliest_price_ms(timing: &OrderTiming): u64 { timing.earliest_price_ms }

public fun tau_ms(timing: &OrderTiming): u64 { timing.tau_ms }

public fun deadline_ms(timing: &OrderTiming): u64 { timing.deadline_ms }

public fun cutoff_ms(timing: &OrderTiming): u64 { timing.cutoff_ms }

public fun pyth_channel(timing: &OrderTiming): u8 { timing.pyth_channel }

public fun budget(escrow: &OrderEscrow): u64 { escrow.budget }

public fun order_fee(escrow: &OrderEscrow): u64 { escrow.order_fee }

public fun subsidy_bound(escrow: &OrderEscrow): u64 { escrow.subsidy_bound }

public fun subsidy_rate(escrow: &OrderEscrow): u64 { escrow.subsidy_rate }

public fun subsidy_reserved(escrow: &OrderEscrow): u64 { escrow.subsidy_reserved }

public fun cash_need(escrow: &OrderEscrow): u64 { escrow.cash_need }

public fun order_id(position: &HeldPosition): u256 { position.order_id }

public fun root_id(position: &HeldPosition): u256 { position.root_id }

public fun opened_at_ms(position: &HeldPosition): u64 { position.opened_at_ms }

public fun spot(price: &CommittedPrice): u64 { price.spot }

public fun tick_ms(price: &CommittedPrice): u64 { price.tick_ms }

public fun generation_us(price: &CommittedPrice): u64 { price.generation_us }

public fun reason(result: &OrderResult): u8 { result.reason }

public fun result_quantity(result: &OrderResult): u64 { result.quantity }

public fun result_amount(result: &OrderResult): u64 { result.amount }

public fun finished_at_ms(result: &OrderResult): u64 { result.finished_at_ms }

// === Public-Package Functions ===

// --- Reads ---

public(package) fun book_key(): OrderBookKey { OrderBookKey() }

public(package) fun try_order(book: &OrderBook, record_id: u64): Option<QueuedOrder> {
    if (!book.orders.contains(record_id)) return option::none();
    option::some(book.orders[record_id])
}

public(package) fun next_id(book: &OrderBook): u64 { book.next_id }

public(package) fun resolve_head(book: &OrderBook): u64 { book.resolve_head }

public(package) fun payout_cursor(book: &OrderBook): u64 { book.payout_cursor }

public(package) fun last_tau_ms(book: &OrderBook): u64 { book.last_tau_ms }

public(package) fun last_committed_tau_ms(book: &OrderBook): u64 { book.last_committed_tau_ms }

public(package) fun pending_mints(book: &OrderBook): u64 { book.pending_mints }

public(package) fun pending_sells(book: &OrderBook): u64 { book.pending_sells }

public(package) fun waiting_cash_need(book: &OrderBook): u64 { book.waiting_cash_need }

#[test_only]
public(package) fun escrow_value(book: &OrderBook): u64 { book.escrow.value() }

public(package) fun pins(book: &OrderBook): &VecMap<u64, u64> { &book.pins }

/// Unfinished orders `account_id` holds in this market; `0` without a row.
public(package) fun account_waiting(book: &OrderBook, account_id: ID): u64 {
    if (!book.per_account.contains(account_id)) return 0;
    book.per_account[account_id]
}

public(package) fun cohort_count(book: &OrderBook): u64 { book.cohorts.length() }

public(package) fun cohort(book: &OrderBook, index: u64): CohortSpan { book.cohorts[index] }

/// τ of the oldest cohort that still waits for its price.
public(package) fun oldest_uncommitted_tau(book: &OrderBook): Option<u64> {
    let index = book.cohorts.find_index!(|span| span.unfinished > 0 && !span.committed);
    index.map!(|index| book.cohorts[index].tau_ms)
}

/// τ of the oldest cohort that still waits for its price while no newer cohort
/// has been committed: the cohort the stuck gate's first rule watches.
public(package) fun oldest_uncommitted_tau_above_committed(book: &OrderBook): Option<u64> {
    let last_committed_tau_ms = book.last_committed_tau_ms;
    let index = book
        .cohorts
        .find_index!(
            |span| span.unfinished > 0 && !span.committed && span.tau_ms > last_committed_tau_ms,
        );
    index.map!(|index| book.cohorts[index].tau_ms)
}

/// τ of the oldest cohort with an unfinished order.
public(package) fun oldest_unfinished_tau(book: &OrderBook): Option<u64> {
    let index = book.cohorts.find_index!(|span| span.unfinished > 0);
    index.map!(|index| book.cohorts[index].tau_ms)
}

public(package) fun span_tau_ms(span: &CohortSpan): u64 { span.tau_ms }

public(package) fun span_deadline_ms(span: &CohortSpan): u64 { span.deadline_ms }

public(package) fun span_first_id(span: &CohortSpan): u64 { span.first_id }

public(package) fun span_end_id(span: &CohortSpan): u64 { span.end_id }

public(package) fun span_pyth_channel(span: &CohortSpan): u8 { span.pyth_channel }

public(package) fun span_committed(span: &CohortSpan): bool { span.committed }

public(package) fun span_unfinished(span: &CohortSpan): u64 { span.unfinished }

public(package) fun escrow_returned(outcome: &RefundOutcome): u64 { outcome.escrow_returned }

public(package) fun order_fee_returned(outcome: &RefundOutcome): u64 {
    outcome.order_fee_returned
}

public(package) fun subsidy_returned(outcome: &RefundOutcome): u64 { outcome.subsidy_returned }

public(package) fun position_returned(outcome: &RefundOutcome): bool {
    outcome.position_returned
}

public(package) fun owed(outcome: &RefundOutcome): u64 { outcome.owed }

public(package) fun shortfall(outcome: &RefundOutcome): u64 { outcome.shortfall }

// --- Placement ---

/// Plan a new order's τ, deadline, and cutoff from the book's last τ, last
/// committed τ, last deadline, and last channel. Does not check the cutoff; the
/// caller asserts τ below it on the final τ.
///
/// τ is the policy channel's last tick at or before `now + delay`, never below
/// `last_tau_ms`. Two pushes follow, in order:
/// - Channel switch: when the book's newest order used another channel, τ moves
///   to the first tick of the new channel strictly after `last_tau_ms`, so one
///   cohort never mixes channels.
/// - Committed cohort: a τ at or below `last_committed_tau_ms` moves to the first
///   tick of the channel after it, so no order joins a price already on chain and
///   a committed span never grows.
///
/// An order whose τ equals the last span's τ joins that cohort and takes its
/// stored deadline. Otherwise the deadline is `min(τ + stall, expiry)`, never
/// below `last_deadline_ms`.
public(package) fun plan_timing(
    book: &OrderBook,
    policy: &DelayedExecutionPolicy,
    expiry_ms: u64,
    no_trade_window_ms: u64,
    now_ms: u64,
): OrderTiming {
    let channel = policy.pyth_channel();
    let tick_ms = delayed_execution_config::channel_tick_ms(channel);
    let stall_timeout_ms = policy.stall_timeout_ms();
    let rounded_ms = (now_ms + policy.delay_ms()) / tick_ms * tick_ms;
    let mut tau_ms = rounded_ms.max(book.last_tau_ms);
    if (book.next_id > 0 && book.last_channel != channel) {
        tau_ms = rounded_ms.max(next_tick_after(book.last_tau_ms, tick_ms));
    };
    if (tau_ms <= book.last_committed_tau_ms) {
        tau_ms = next_tick_after(book.last_committed_tau_ms, tick_ms);
    };
    let span_count = book.cohorts.length();
    let deadline_ms = if (span_count > 0 && book.cohorts[span_count - 1].tau_ms == tau_ms) {
        book.cohorts[span_count - 1].deadline_ms
    } else {
        (tau_ms + stall_timeout_ms).min(expiry_ms).max(book.last_deadline_ms)
    };
    // Saturates: a market too close to expiry for any deadline gets cutoff 0,
    // which every τ fails.
    let cutoff_ms = expiry_ms.saturating_sub(no_trade_window_ms.max(
        stall_timeout_ms + deadline_expiry_margin_ms!(),
    ));
    OrderTiming {
        placed_at_ms: now_ms,
        earliest_price_ms: tau_ms,
        tau_ms,
        deadline_ms,
        cutoff_ms,
        pyth_channel: channel,
    }
}

/// Whether placement must refuse new orders: some uncommitted span is at least
/// `stuck_threshold_ms` past its τ with τ above `last_committed_tau_ms`, or two
/// or more uncommitted spans each are.
public(package) fun is_stuck(book: &OrderBook, stuck_threshold_ms: u64, now_ms: u64): bool {
    let mut stale_spans = 0u64;
    let mut index = 0;
    let span_count = book.cohorts.length();
    while (index < span_count) {
        let span = &book.cohorts[index];
        // Spans are in τ order, so no later span is stale either.
        if (span.tau_ms + stuck_threshold_ms > now_ms) break;
        if (span.unfinished > 0 && !span.committed) {
            if (span.tau_ms > book.last_committed_tau_ms) return true;
            stale_spans = stale_spans + 1;
            if (stale_spans >= 2) return true;
        };
        index = index + 1;
    };
    false
}

/// Exact-quantity mint cash need: `ceil(quantity * (1 - min_entry_probability)) + 1`.
/// A fill pays at least `min_entry_probability` per contract into market cash.
public(package) fun cash_need_exact_quantity(quantity: u64, min_entry_probability: u64): u64 {
    math::mul_div_up(
        quantity,
        math::float_scaling!() - min_entry_probability,
        math::float_scaling!(),
    ) + 1
}

/// Budget mint cash need: `ceil((budget + 1) * (1 / min_entry_probability - 1)) + 1`.
/// The `budget + 1` covers premiums rounding down, which lets a fill buy up to
/// `1 / probability` raw units more than `budget / probability`. Exact-amount
/// mints pass `min(max_premium, budget)` as `budget`.
public(package) fun cash_need_budget(budget: u64, min_entry_probability: u64): u64 {
    math::mul_div_up(
        budget + 1,
        math::float_scaling!() - min_entry_probability,
        min_entry_probability,
    ) + 1
}

/// Sell cash need: `ceil(close_quantity * (1 - backing_buffer_lambda)) + 1`.
/// Closing lowers payout liability by at least `lambda * close_quantity` and pays
/// at most `close_quantity`.
public(package) fun cash_need_sell(close_quantity: u64, backing_buffer_lambda: u64): u64 {
    math::mul_div_up(
        close_quantity,
        math::float_scaling!() - backing_buffer_lambda,
        math::float_scaling!(),
    ) + 1
}

public(package) fun new_request(
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    max_premium: u64,
    min_quantity: u64,
    max_cost: u64,
    max_probability: u64,
    min_probability: u64,
    min_proceeds: u64,
): OrderRequest {
    OrderRequest {
        lower_tick,
        higher_tick,
        quantity,
        max_premium,
        min_quantity,
        max_cost,
        max_probability,
        min_probability,
        min_proceeds,
    }
}

public(package) fun new_parties(
    account_id: ID,
    owner: address,
    receive_address: address,
    referrer_account_id: Option<ID>,
    referrer_receive_address: Option<address>,
    builder_code_id: Option<ID>,
): OrderParties {
    OrderParties {
        account_id,
        owner,
        receive_address,
        referrer_account_id,
        referrer_receive_address,
        builder_code_id,
    }
}

/// Escrow terms at enqueue; commit sets the subsidy rate and reservation later.
public(package) fun new_escrow(
    budget: u64,
    order_fee: u64,
    subsidy_bound: u64,
    cash_need: u64,
): OrderEscrow {
    OrderEscrow {
        budget,
        order_fee,
        subsidy_bound,
        subsidy_rate: 0,
        subsidy_reserved: 0,
        cash_need,
    }
}

public(package) fun new_held_position(
    order_id: u256,
    root_id: u256,
    opened_at_ms: u64,
): HeldPosition {
    HeldPosition { order_id, root_id, opened_at_ms }
}

public(package) fun empty_position(): HeldPosition {
    HeldPosition { order_id: 0, root_id: 0, opened_at_ms: 0 }
}

public(package) fun new_committed_price(
    spot: u64,
    tick_ms: u64,
    generation_us: u64,
): CommittedPrice {
    CommittedPrice { spot, tick_ms, generation_us }
}

/// Build a Pending record with a zero price and result.
public(package) fun new_order(
    kind: u8,
    request: OrderRequest,
    parties: OrderParties,
    timing: OrderTiming,
    vol: VolSnapshot,
    escrow: OrderEscrow,
    position: HeldPosition,
): QueuedOrder {
    QueuedOrder {
        status: STATUS_PENDING,
        kind,
        request,
        parties,
        timing,
        vol,
        escrow,
        position,
        price: CommittedPrice { spot: 0, tick_ms: 0, generation_us: 0 },
        result: OrderResult { reason: 0, quantity: 0, amount: 0, finished_at_ms: 0 },
    }
}

/// Create an empty book. Called once per market, by its first enqueue.
public(package) fun new_book(ctx: &mut TxContext): OrderBook {
    OrderBook {
        orders: table::new(ctx),
        next_id: 0,
        resolve_head: 0,
        payout_cursor: 0,
        cohorts: vector[],
        last_tau_ms: 0,
        last_committed_tau_ms: 0,
        last_deadline_ms: 0,
        last_channel: 0,
        pins: vec_map::empty(),
        per_account: table::new(ctx),
        pending_mints: 0,
        pending_sells: 0,
        waiting_cash_need: 0,
        escrow: balance::zero(),
    }
}

/// Store a new record and return its ID: append a new span or extend the last
/// one, raise the counters and the account's row (created on its first order),
/// add the cash need, advance the `last_*` fields, and pin a mint's ticks.
///
/// `order.timing` must come from `plan_timing` on this book: its τ is never
/// below the last span's, and a τ equal to it never lands on a committed span.
public(package) fun append(book: &mut OrderBook, order: QueuedOrder): u64 {
    let record_id = book.next_id;
    book.next_id = record_id + 1;
    let timing = order.timing;
    let span_count = book.cohorts.length();
    if (span_count > 0 && book.cohorts[span_count - 1].tau_ms == timing.tau_ms) {
        let last = &mut book.cohorts[span_count - 1];
        last.end_id = record_id + 1;
        last.unfinished = last.unfinished + 1;
    } else {
        book
            .cohorts
            .push_back(CohortSpan {
                tau_ms: timing.tau_ms,
                deadline_ms: timing.deadline_ms,
                first_id: record_id,
                end_id: record_id + 1,
                pyth_channel: timing.pyth_channel,
                committed: false,
                unfinished: 1,
            });
    };
    if (is_mint(order.kind)) {
        book.pending_mints = book.pending_mints + 1;
        pin_tick(&mut book.pins, order.request.lower_tick);
        pin_tick(&mut book.pins, order.request.higher_tick);
    } else {
        book.pending_sells = book.pending_sells + 1;
    };
    let account_id = order.parties.account_id;
    if (book.per_account.contains(account_id)) {
        let waiting = &mut book.per_account[account_id];
        *waiting = *waiting + 1;
    } else {
        book.per_account.add(account_id, 1);
    };
    book.waiting_cash_need = book.waiting_cash_need + order.escrow.cash_need;
    book.last_tau_ms = book.last_tau_ms.max(timing.tau_ms);
    book.last_deadline_ms = book.last_deadline_ms.max(timing.deadline_ms);
    book.last_channel = timing.pyth_channel;
    book.orders.add(record_id, order);
    record_id
}

public(package) fun deposit_escrow(book: &mut OrderBook, funds: Balance<USDC>) {
    book.escrow.join(funds);
}

/// Move an Open record's position out and mark the record Closed, zeroing its
/// copy (`enqueue_redeem_open`). The caller checks status and owner.
/// The order already finished, so no counter or span changes.
public(package) fun close_open_record(book: &mut OrderBook, record_id: u64): HeldPosition {
    let record = &mut book.orders[record_id];
    let position = record.position;
    record.position = empty_position();
    record.status = STATUS_CLOSED;
    position
}

// --- Commit ---

/// Attach a committed price to a Pending record; any other status is left alone.
public(package) fun commit_order(book: &mut OrderBook, record_id: u64, price: CommittedPrice) {
    let record = &mut book.orders[record_id];
    if (record.status != STATUS_PENDING) return;
    record.status = STATUS_COMMITTED;
    record.price = price;
}

/// Record a committed mint's subsidy rate and move the reserved incentives
/// into escrow. The reservation adds to the record's, so escrow always equals
/// the unfinished records' budget, fee, and reserved subsidy.
public(package) fun reserve_subsidy(
    book: &mut OrderBook,
    record_id: u64,
    rate: u64,
    reserved: Balance<USDC>,
) {
    let record = &mut book.orders[record_id];
    record.escrow.subsidy_rate = rate;
    record.escrow.subsidy_reserved = record.escrow.subsidy_reserved + reserved.value();
    book.escrow.join(reserved);
}

/// Mark a cohort committed and raise `last_committed_tau_ms` to its τ if higher.
public(package) fun mark_cohort_committed(book: &mut OrderBook, index: u64) {
    let span = &mut book.cohorts[index];
    span.committed = true;
    let tau_ms = span.tau_ms;
    book.last_committed_tau_ms = book.last_committed_tau_ms.max(tau_ms);
}

// --- Resolve and walkers ---

/// Withdraw one record's whole escrow (budget, order fee, reserved subsidy) for
/// its fill. Escrow covering every unfinished record is an invariant, so a
/// short escrow aborts here rather than filling.
public(package) fun withdraw_order_escrow(book: &mut OrderBook, record_id: u64): Balance<USDC> {
    let escrow = book.orders[record_id].escrow;
    book.escrow.split(escrow.budget + escrow.order_fee + escrow.subsidy_reserved)
}

/// Finish a filled record: set its status, position, and result; drop the
/// counters, the account's row, the cash need, and its span's `unfinished`
/// once; unpin a mint's ticks. The caller fills only an unfinished record, once.
public(package) fun finish_fill(
    book: &mut OrderBook,
    record_id: u64,
    new_status: u8,
    position: HeldPosition,
    quantity: u64,
    amount: u64,
    now_ms: u64,
) {
    let order = book.orders[record_id];
    book.release_order(record_id, &order);
    let record = &mut book.orders[record_id];
    record.status = new_status;
    record.position = position;
    record.result = OrderResult { reason: 0, quantity, amount, finished_at_ms: now_ms };
}

/// The one refund routine every finishing path shares. Pays the record's escrow
/// back, at most what escrow holds and never aborting: the budget to the trader,
/// the order fee to the trader (reasons 3 to 8) or to market cash (reasons 1 and
/// 2), the reserved subsidy to `incentives`. Unpins a mint's ticks and prunes
/// them only when `prune` (false from `try_settle`). A mint becomes Refunded; a
/// sell returns to Open holding its position. Drops every counter once. A
/// RefundDue record keeps its stored reason. `none` for a missing or finished
/// record.
public(package) fun refund_order(
    book: &mut OrderBook,
    exposure: &mut StrikeExposure,
    cash: &mut ExpiryCash,
    incentives: &mut Balance<USDC>,
    record_id: u64,
    reason: u8,
    prune: bool,
    now_ms: u64,
): Option<RefundOutcome> {
    if (!book.orders.contains(record_id)) return option::none();
    let order = book.orders[record_id];
    if (!is_unfinished(order.status)) return option::none();
    let reason = if (order.status == STATUS_REFUND_DUE) order.result.reason else reason;
    let keeps_fee = reason == REASON_LIMITS || reason == REASON_ADMISSION;

    // Pay in seniority order from what escrow holds, so any shortfall lands on
    // the incentive balance and market cash before the trader.
    let escrow = order.escrow;
    let mut available = book.escrow.value();
    let budget_paid = escrow.budget.min(available);
    available = available - budget_paid;
    let fee_refunded = if (keeps_fee) 0 else escrow.order_fee.min(available);
    available = available - fee_refunded;
    let subsidy_paid = escrow.subsidy_reserved.min(available);
    available = available - subsidy_paid;
    let fee_kept = if (keeps_fee) escrow.order_fee.min(available) else 0;

    let trader_paid = budget_paid + fee_refunded;
    if (trader_paid > 0) {
        balance::send_funds(book.escrow.split(trader_paid), order.parties.receive_address);
    };
    if (subsidy_paid > 0) {
        incentives.join(book.escrow.split(subsidy_paid));
    };
    if (fee_kept > 0) cash.receive(book.escrow.split(fee_kept));

    book.release_order(record_id, &order);
    let sell = !is_mint(order.kind);
    if (prune && !sell) {
        let request = order.request;
        if (has_tree_node(request.lower_tick)) {
            exposure.prune_if_unpinned(request.lower_tick, &book.pins);
        };
        if (has_tree_node(request.higher_tick)) {
            exposure.prune_if_unpinned(request.higher_tick, &book.pins);
        };
    };

    // A sell's record keeps the position it took at enqueue, so the trader can
    // sell it again or settlement pays it.
    let record = &mut book.orders[record_id];
    record.status = if (sell) STATUS_OPEN else STATUS_REFUNDED;
    record.result = OrderResult { reason, quantity: 0, amount: 0, finished_at_ms: now_ms };

    let owed = escrow.budget + escrow.order_fee + escrow.subsidy_reserved;
    option::some(RefundOutcome {
        escrow_returned: budget_paid,
        order_fee_returned: fee_refunded,
        subsidy_returned: subsidy_paid,
        position_returned: sell,
        owed,
        shortfall: owed - (trader_paid + subsidy_paid + fee_kept),
    })
}

/// Move a span's `first_id` up to the first record a walker did not visit. It
/// only moves forward and never past the span's end.
public(package) fun set_cohort_first_id(book: &mut OrderBook, index: u64, first_id: u64) {
    let span = &mut book.cohorts[index];
    span.first_id = span.first_id.max(first_id.min(span.end_id));
}

/// Drop spans whose `unfinished` reached zero and reset `resolve_head` to the
/// first span's `first_id`, or `next_id` when none remain. Loads no record.
public(package) fun advance_heads(book: &mut OrderBook) {
    if (book.cohorts.any!(|span| span.unfinished == 0)) {
        let cohorts = book.cohorts;
        book.cohorts = cohorts.filter!(|span| span.unfinished > 0);
    };
    book.resolve_head = if (book.cohorts.is_empty()) book.next_id else book.cohorts[0].first_id;
}

// --- Settlement and cleanup ---

/// Close the queue at settlement: `resolve_head = next_id` and no spans left.
/// The caller has refunded every unfinished order first.
public(package) fun settle_queue(book: &mut OrderBook) {
    book.resolve_head = book.next_id;
    book.cohorts = vector[];
}

public(package) fun withdraw_all_escrow(book: &mut OrderBook): Balance<USDC> {
    book.escrow.withdraw_all()
}

/// Move the payout cursor forward to `cursor`, never past `next_id`. A lower
/// `cursor` leaves it unchanged.
public(package) fun set_payout_cursor(book: &mut OrderBook, cursor: u64) {
    book.payout_cursor = book.payout_cursor.max(cursor.min(book.next_id));
}

/// Delete a Refunded or Closed record. Returns whether it deleted one.
public(package) fun remove_finished_record(book: &mut OrderBook, record_id: u64): bool {
    if (!book.orders.contains(record_id)) return false;
    let status = book.orders[record_id].status;
    if (status != STATUS_REFUNDED && status != STATUS_CLOSED) return false;
    book.orders.remove(record_id);
    true
}

// === Private Functions ===

/// The first tick of a `tick_ms` grid strictly after `time_ms`.
fun next_tick_after(time_ms: u64, tick_ms: u64): u64 {
    (time_ms / tick_ms + 1) * tick_ms
}

/// Pending, Committed, and RefundDue records still wait to fill or refund.
fun is_unfinished(status: u8): bool {
    status == STATUS_PENDING || status == STATUS_COMMITTED || status == STATUS_REFUND_DUE
}

/// Drop everything a finishing order held: its pending count, its account's
/// waiting count (only if the row exists), its cash need, its span's
/// `unfinished`, and a mint's pins. Each drop saturates, so a finishing path
/// never aborts here. Spans stay in place until `advance_heads`, so a walker's
/// span indices stay stable.
fun release_order(book: &mut OrderBook, record_id: u64, order: &QueuedOrder) {
    if (is_mint(order.kind)) {
        book.pending_mints = book.pending_mints.saturating_sub(1);
        unpin_tick(&mut book.pins, order.request.lower_tick);
        unpin_tick(&mut book.pins, order.request.higher_tick);
    } else {
        book.pending_sells = book.pending_sells.saturating_sub(1);
    };
    let account_id = order.parties.account_id;
    if (book.per_account.contains(account_id)) {
        let waiting = &mut book.per_account[account_id];
        *waiting = (*waiting).saturating_sub(1);
    };
    book.waiting_cash_need = book.waiting_cash_need.saturating_sub(order.escrow.cash_need);
    // Spans cover disjoint, increasing ID ranges and an unfinished record's span
    // is never removed, so the first span ending after the record holds it.
    let span_index = book.cohorts.find_index!(|span| record_id < span.end_id);
    if (span_index.is_some()) {
        let span = &mut book.cohorts[span_index.destroy_some()];
        span.unfinished = span.unfinished.saturating_sub(1);
    };
}

/// Whether `kind` is one of the three mint kinds; the others are sells.
fun is_mint(kind: u8): bool {
    kind == KIND_EXACT_QUANTITY || kind == KIND_EXACT_AMOUNT || kind == KIND_EXACT_COST
}

/// Count one more waiting mint on `tick`.
fun pin_tick(pins: &mut VecMap<u64, u64>, tick: u64) {
    if (!has_tree_node(tick)) return;
    if (pins.contains(&tick)) {
        let count = pins.get_mut(&tick);
        *count = *count + 1;
    } else {
        pins.insert(tick, 1);
    };
}

/// Whether a range boundary at `tick` has a payout-tree node to pin or prune.
/// The open sentinels 0 and `pos_inf_tick` never do.
fun has_tree_node(tick: u64): bool {
    tick != 0 && tick != constants::pos_inf_tick!()
}

/// Count one fewer waiting mint on `tick`, removing the entry at zero. A tick
/// with no entry is left alone.
fun unpin_tick(pins: &mut VecMap<u64, u64>, tick: u64) {
    if (!pins.contains(&tick)) return;
    let count = *pins.get(&tick);
    if (count > 1) {
        *pins.get_mut(&tick) = count - 1;
    } else {
        let (_, _) = pins.remove(&tick);
    };
}
