// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// One market's queue of delayed-execution orders: queued mints and early sells
/// that fill at Pyth's signed price for their τ, or are refunded.
///
/// This module owns the `OrderBook` a `MarketQueue` holds and its records
/// (`QueuedOrder` and its parts): the status, kind, and refund-reason codes, τ
/// and deadline planning, the stuck check, the counters and cohort spans, and
/// the walker primitives. A record holds Predict's `OrderReceipt` for its order
/// and that order's own escrow `Balance<USDC>` in one table row, so a refund
/// pays exactly that record's escrow and a record that still holds a receipt
/// cannot be deleted. Predict owns the payout-tree pins and the waiting cash
/// need. The `queue` module owns the flow gates, every Predict call, and every
/// queue event.
module deepbook_predict_orders::order_queue;

use deepbook_predict::expiry_market::OrderReceipt;
use deepbook_predict_orders::delayed_execution_config::DelayedExecutionPolicy;
use sui::{balance::Balance, table::{Self, Table}};
use usdc::usdc::USDC;

const ERecordNotOpen: u64 = 0;

// === Codes ===
// Stored in records and emitted in events. Never renumbered after publish; new
// codes append. The kind and fill-reason codes equal Predict's
// `constants::mint_kind_*`, `order_kind_sell`, and `fill_reason_*`.

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
/// Reserved: never used, which sells only Open records (`KIND_REDEEM_OPEN`).
/// Kept so no later kind reuses 3.
const KIND_REDEEM_LIVE: u8 = 3;
const KIND_REDEEM_OPEN: u8 = 4;

/// The order missed its own limits at the tick. Order fee kept.
const REASON_LIMITS: u8 = 1;
/// The order failed mint admission or could not be priced at the tick. Order
/// fee kept.
const REASON_ADMISSION: u8 = 2;
/// Reserved, unused.
const REASON_NO_PRICE: u8 = 3;
/// A pinned payout-tree node was missing at the fill (backstop). Fee returned.
const REASON_MISSING_NODE: u8 = 4;
/// The order reached its deadline unfilled. Fee returned.
const REASON_DEADLINE: u8 = 5;
/// Reserved, unused.
const REASON_FREEZE: u8 = 6;
/// Admin refund. Fee returned.
const REASON_ADMIN: u8 = 7;
/// The market's cash could not cover the fill. Fee returned.
const REASON_NO_CASH: u8 = 8;

/// One market's delayed-execution queue state.
public struct OrderBook has store {
    /// One record per order, keyed by a sequential record ID. Records stay
    /// after they finish until `cleanup` deletes them.
    orders: Table<u64, QueuedOrder>,
    next_id: u64,
    /// Lower bound on the first unfinished record: the first span's `first_id`,
    /// or `next_id` when no span remains.
    resolve_head: u64,
    /// Where the next settlement payout call resumes. Only moves forward, and
    /// never past `next_id`.
    payout_cursor: u64,
    /// One span per cohort (orders sharing one τ) that still has an unfinished
    /// order, in τ order. Inline, so a walk loads no extra object to find them.
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
    /// Unfinished orders per account. A row is created by the account's first
    /// placement in this market and never deleted.
    per_account: Table<ID, u64>,
    /// Unfinished mints and sells, against the policy capacities.
    pending_mints: u64,
    pending_sells: u64,
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

/// One queued order with Predict's receipt for it and its escrow.
public struct QueuedOrder has store {
    /// A `STATUS_*` code. Only moves forward, except that a refunded or partly
    /// filled sell returns to Open holding its position.
    status: u8,
    /// A `KIND_*` code.
    kind: u8,
    request: OrderRequest,
    account_id: ID,
    /// The account's receive address. Refunds and returned escrow go here.
    receive_address: address,
    timing: OrderTiming,
    escrow: OrderEscrow,
    /// The position the record holds: a sell's position from placement, or a
    /// filled mint's new position. Zero otherwise.
    position: HeldPosition,
    price: CommittedPrice,
    result: OrderResult,
    /// Predict's receipt: admitted while the order waits, open while the record
    /// holds a position, `none` once the order is refunded or fully closed.
    receipt: Option<OrderReceipt>,
    /// The order's escrow: its budget, order fee, and reserved subsidy while it
    /// waits, zero once it finishes.
    funds: Balance<USDC>,
}

/// A copyable view of one record, without its receipt and escrow. What the
/// queue reads return.
public struct OrderView has copy, drop {
    status: u8,
    kind: u8,
    request: OrderRequest,
    account_id: ID,
    receive_address: address,
    timing: OrderTiming,
    escrow: OrderEscrow,
    position: HeldPosition,
    price: CommittedPrice,
    result: OrderResult,
    /// The receipt's Predict stage (`constants::receipt_stage_*`), `0` when the
    /// record holds none.
    receipt_stage: u8,
    /// USDC the record escrows now.
    funds: u64,
}

/// The trader's terms, fixed at placement. `quantity` is the exact mint quantity
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

/// The order's clock, fixed at placement.
public struct OrderTiming has copy, drop, store {
    /// t₀, the Sui clock of the placement transaction.
    placed_at_ms: u64,
    /// τ itself: a price generated before it never commits the order.
    earliest_price_ms: u64,
    /// The channel tick the order is priced on.
    tau_ms: u64,
    /// At or past it the order is refunded, never filled.
    deadline_ms: u64,
    /// `expiry - max(no_trade_window_ms, stall_timeout_ms + 5_000)`; placement
    /// requires τ below it.
    cutoff_ms: u64,
    /// The policy channel at placement. Commit accepts only updates on it.
    pyth_channel: u8,
}

/// The order's escrow terms.
public struct OrderEscrow has copy, drop, store {
    /// USDC locked for the premium and fees, and the fill's all-in cost cap.
    /// Sells lock none.
    budget: u64,
    /// Flat fee charged at placement.
    order_fee: u64,
    /// The admission dry run's pre-subsidy trading fee, capped at the budget.
    /// Bounds the subsidy commit reserves.
    subsidy_bound: u64,
    /// The incentives commit reserved for the order, held with its escrow.
    subsidy_reserved: u64,
    /// Worst-case market cash the fill can consume, counted in Predict's
    /// waiting cash need while the order waits.
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
    /// The update's envelope in ms: τ, or a later backup tick. The fill prices
    /// at it.
    tick_ms: u64,
    /// The feed's own update time, in µs.
    generation_us: u64,
}

/// How the order finished. Zero until a fill or a refund finishes it.
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

// === OrderView Getters ===
// Public for SDK and devInspect reads of `queue::order`.

public fun status(view: &OrderView): u8 { view.status }

public fun kind(view: &OrderView): u8 { view.kind }

public fun request(view: &OrderView): OrderRequest { view.request }

public fun account_id(view: &OrderView): ID { view.account_id }

public fun receive_address(view: &OrderView): address { view.receive_address }

public fun timing(view: &OrderView): OrderTiming { view.timing }

public fun escrow(view: &OrderView): OrderEscrow { view.escrow }

public fun position(view: &OrderView): HeldPosition { view.position }

public fun price(view: &OrderView): CommittedPrice { view.price }

public fun result(view: &OrderView): OrderResult { view.result }

public fun receipt_stage(view: &OrderView): u8 { view.receipt_stage }

public fun funds(view: &OrderView): u64 { view.funds }

public fun lower_tick(request: &OrderRequest): u64 { request.lower_tick }

public fun higher_tick(request: &OrderRequest): u64 { request.higher_tick }

public fun quantity(request: &OrderRequest): u64 { request.quantity }

public fun max_premium(request: &OrderRequest): u64 { request.max_premium }

public fun min_quantity(request: &OrderRequest): u64 { request.min_quantity }

public fun max_cost(request: &OrderRequest): u64 { request.max_cost }

public fun max_probability(request: &OrderRequest): u64 { request.max_probability }

public fun min_probability(request: &OrderRequest): u64 { request.min_probability }

public fun min_proceeds(request: &OrderRequest): u64 { request.min_proceeds }

public fun placed_at_ms(timing: &OrderTiming): u64 { timing.placed_at_ms }

public fun earliest_price_ms(timing: &OrderTiming): u64 { timing.earliest_price_ms }

public fun tau_ms(timing: &OrderTiming): u64 { timing.tau_ms }

public fun deadline_ms(timing: &OrderTiming): u64 { timing.deadline_ms }

public fun cutoff_ms(timing: &OrderTiming): u64 { timing.cutoff_ms }

public fun pyth_channel(timing: &OrderTiming): u8 { timing.pyth_channel }

public fun budget(escrow: &OrderEscrow): u64 { escrow.budget }

public fun order_fee(escrow: &OrderEscrow): u64 { escrow.order_fee }

public fun subsidy_bound(escrow: &OrderEscrow): u64 { escrow.subsidy_bound }

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

public(package) fun next_id(book: &OrderBook): u64 { book.next_id }

public(package) fun resolve_head(book: &OrderBook): u64 { book.resolve_head }

public(package) fun payout_cursor(book: &OrderBook): u64 { book.payout_cursor }

public(package) fun last_tau_ms(book: &OrderBook): u64 { book.last_tau_ms }

public(package) fun last_committed_tau_ms(book: &OrderBook): u64 { book.last_committed_tau_ms }

public(package) fun pending_mints(book: &OrderBook): u64 { book.pending_mints }

public(package) fun pending_sells(book: &OrderBook): u64 { book.pending_sells }

/// Unfinished orders `account_id` holds in this market; `0` without a row.
public(package) fun account_waiting(book: &OrderBook, account_id: ID): u64 {
    if (!book.per_account.contains(account_id)) return 0;
    book.per_account[account_id]
}

/// A copy of one record's fields, or `none` for a missing or deleted ID.
public(package) fun view(book: &OrderBook, record_id: u64): Option<OrderView> {
    if (!book.orders.contains(record_id)) return option::none();
    let record = &book.orders[record_id];
    option::some(OrderView {
        status: record.status,
        kind: record.kind,
        request: record.request,
        account_id: record.account_id,
        receive_address: record.receive_address,
        timing: record.timing,
        escrow: record.escrow,
        position: record.position,
        price: record.price,
        result: record.result,
        receipt_stage: if (record.receipt.is_some()) {
            let (_, stage, _, _, _, _, _, _) = record.receipt.borrow().receipt_info();
            stage
        } else {
            0
        },
        funds: record.funds.value(),
    })
}

/// The Pyth feed of a Pending record's receipt, or `none` for any other record.
/// Commit decodes one price per feed.
public(package) fun pending_feed(book: &OrderBook, record_id: u64): Option<u32> {
    if (!book.orders.contains(record_id)) return option::none();
    let record = &book.orders[record_id];
    if (record.status != STATUS_PENDING) return option::none();
    let (_, _, _, _, feed_id, _, _, _) = record.receipt.borrow().receipt_info();
    option::some(feed_id)
}

/// The record's receipt. Aborts if the record holds none.
public(package) fun receipt(book: &OrderBook, record_id: u64): &OrderReceipt {
    book.orders[record_id].receipt.borrow()
}

public(package) fun receipt_mut(book: &mut OrderBook, record_id: u64): &mut OrderReceipt {
    book.orders[record_id].receipt.borrow_mut()
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

/// Whether `kind` is one of the three mint kinds; the others are sells.
public(package) fun is_mint(kind: u8): bool {
    kind == KIND_EXACT_QUANTITY || kind == KIND_EXACT_AMOUNT || kind == KIND_EXACT_COST
}

/// Pending, Committed, and RefundDue records still wait to fill or refund.
public(package) fun is_unfinished(status: u8): bool {
    status == STATUS_PENDING || status == STATUS_COMMITTED || status == STATUS_REFUND_DUE
}

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
    let tick_ms = deepbook_predict_orders::delayed_execution_config::channel_tick_ms(channel);
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
        stall_timeout_ms + deepbook_predict::constants::deadline_expiry_margin_ms!(),
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

/// Escrow terms at placement; commit records the reserved subsidy later.
public(package) fun new_escrow(
    budget: u64,
    order_fee: u64,
    subsidy_bound: u64,
    cash_need: u64,
): OrderEscrow {
    OrderEscrow { budget, order_fee, subsidy_bound, subsidy_reserved: 0, cash_need }
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

/// Build a Pending record holding an admitted receipt and its escrow.
public(package) fun new_order(
    kind: u8,
    request: OrderRequest,
    account_id: ID,
    receive_address: address,
    timing: OrderTiming,
    escrow: OrderEscrow,
    position: HeldPosition,
    receipt: OrderReceipt,
    funds: Balance<USDC>,
): QueuedOrder {
    QueuedOrder {
        status: STATUS_PENDING,
        kind,
        request,
        account_id,
        receive_address,
        timing,
        escrow,
        position,
        price: CommittedPrice { spot: 0, tick_ms: 0, generation_us: 0 },
        result: OrderResult { reason: 0, quantity: 0, amount: 0, finished_at_ms: 0 },
        receipt: option::some(receipt),
        funds,
    }
}

/// Create an empty book.
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
        per_account: table::new(ctx),
        pending_mints: 0,
        pending_sells: 0,
    }
}

/// Store a new record and return its ID: append a new span or extend the last
/// one, raise the counters and the account's row (created on its first order),
/// and advance the `last_*` fields.
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
    } else {
        book.pending_sells = book.pending_sells + 1;
    };
    let account_id = order.account_id;
    if (book.per_account.contains(account_id)) {
        let waiting = &mut book.per_account[account_id];
        *waiting = *waiting + 1;
    } else {
        book.per_account.add(account_id, 1);
    };
    book.last_tau_ms = book.last_tau_ms.max(timing.tau_ms);
    book.last_deadline_ms = book.last_deadline_ms.max(timing.deadline_ms);
    book.last_channel = timing.pyth_channel;
    book.orders.add(record_id, order);
    record_id
}

/// Move an Open record's receipt and position out and mark the record Closed:
/// the source of an early sell. Aborts `ERecordNotOpen` for a missing or
/// non-Open record. The order already finished, so no counter or span changes.
public(package) fun close_open_record(
    book: &mut OrderBook,
    record_id: u64,
): (OrderReceipt, HeldPosition) {
    assert!(
        book.orders.contains(record_id) && book.orders[record_id].status == STATUS_OPEN,
        ERecordNotOpen,
    );
    let record = &mut book.orders[record_id];
    let position = record.position;
    record.position = empty_position();
    record.status = STATUS_CLOSED;
    (record.receipt.extract(), position)
}

/// Take an Open record's receipt for the settled payout. The caller either
/// marks the record paid (`finish_payout`) or puts the receipt back
/// (`restore_receipt`).
public(package) fun take_open_receipt(book: &mut OrderBook, record_id: u64): OrderReceipt {
    book.orders[record_id].receipt.extract()
}

public(package) fun restore_receipt(book: &mut OrderBook, record_id: u64, receipt: OrderReceipt) {
    book.orders[record_id].receipt.fill(receipt);
}

/// Mark a paid Open record Closed, holding no position. The result keeps the
/// fill that opened it; `OpenRecordSettled` carries the payout.
public(package) fun finish_payout(book: &mut OrderBook, record_id: u64) {
    let record = &mut book.orders[record_id];
    record.status = STATUS_CLOSED;
    record.position = empty_position();
}

// --- Commit ---

/// Attach a committed price and the reserved subsidy to a Pending record. The
/// subsidy joins the record's escrow.
public(package) fun commit_order(
    book: &mut OrderBook,
    record_id: u64,
    price: CommittedPrice,
    subsidy: Balance<USDC>,
) {
    let record = &mut book.orders[record_id];
    record.status = STATUS_COMMITTED;
    record.price = price;
    record.escrow.subsidy_reserved = subsidy.value();
    record.funds.join(subsidy);
}

/// Mark a cohort committed and raise `last_committed_tau_ms` to its τ if higher.
public(package) fun mark_cohort_committed(book: &mut OrderBook, index: u64) {
    let span = &mut book.cohorts[index];
    span.committed = true;
    let tau_ms = span.tau_ms;
    book.last_committed_tau_ms = book.last_committed_tau_ms.max(tau_ms);
}

// --- Finishing ---

/// Take an unfinished record's receipt and its whole escrow, to fill or refund
/// it.
public(package) fun take_order(
    book: &mut OrderBook,
    record_id: u64,
): (OrderReceipt, Balance<USDC>) {
    let record = &mut book.orders[record_id];
    (record.receipt.extract(), record.funds.withdraw_all())
}

/// Finish an unfinished record once: drop its pending count, its span's
/// `unfinished`, and (with `count_account`) the account's waiting count; then
/// record its status, position, and result, and put back the receipt it keeps.
/// The settlement drain skips the account row, which no placement reads once
/// the market has expired, so each drained record loads one dynamic child.
public(package) fun finish_order(
    book: &mut OrderBook,
    record_id: u64,
    status: u8,
    receipt: Option<OrderReceipt>,
    position: HeldPosition,
    reason: u8,
    quantity: u64,
    amount: u64,
    count_account: bool,
    now_ms: u64,
) {
    let kind = book.orders[record_id].kind;
    let account_id = book.orders[record_id].account_id;
    if (is_mint(kind)) {
        book.pending_mints = book.pending_mints - 1;
    } else {
        book.pending_sells = book.pending_sells - 1;
    };
    if (count_account) {
        let waiting = &mut book.per_account[account_id];
        *waiting = *waiting - 1;
    };
    // Spans cover disjoint, increasing ID ranges and an unfinished record's span
    // is never removed, so the first span ending after the record holds it.
    let span_index = book.cohorts.find_index!(|span| record_id < span.end_id);
    if (span_index.is_some()) {
        let span = &mut book.cohorts[span_index.destroy_some()];
        span.unfinished = span.unfinished - 1;
    };
    let record = &mut book.orders[record_id];
    record.status = status;
    record.position = position;
    record.result = OrderResult { reason, quantity, amount, finished_at_ms: now_ms };
    if (receipt.is_some()) {
        record.receipt.fill(receipt.destroy_some());
    } else {
        receipt.destroy_none();
    };
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

/// Close the queue once nothing is unfinished: `resolve_head = next_id` and no
/// spans left.
public(package) fun settle_queue(book: &mut OrderBook) {
    book.resolve_head = book.next_id;
    book.cohorts = vector[];
}

/// Move the payout cursor forward to `cursor`, never past `next_id`. A lower
/// `cursor` leaves it unchanged.
public(package) fun set_payout_cursor(book: &mut OrderBook, cursor: u64) {
    book.payout_cursor = book.payout_cursor.max(cursor.min(book.next_id));
}

/// Delete a Refunded or Closed record that holds no receipt and no escrow.
/// Returns whether it deleted one.
public(package) fun remove_finished_record(book: &mut OrderBook, record_id: u64): bool {
    if (!book.orders.contains(record_id)) return false;
    let record = &book.orders[record_id];
    if (
        (record.status != STATUS_REFUNDED && record.status != STATUS_CLOSED)
            || record.receipt.is_some()
            || record.funds.value() > 0
    ) return false;
    let QueuedOrder { receipt, funds, .. } = book.orders.remove(record_id);
    receipt.destroy_none();
    funds.destroy_zero();
    true
}

// === Private Functions ===

/// The first tick of a `tick_ms` grid strictly after `time_ms`.
fun next_tick_after(time_ms: u64, tick_ms: u64): u64 {
    (time_ms / tick_ms + 1) * tick_ms
}

// === Test-Only Functions ===

#[test_only]
/// A record with no receipt and no escrow, for the book-level unit tests: only
/// Predict's admission builds a receipt, so book tests that need no market use
/// this instead. Not a production state.
public(package) fun new_order_for_testing(
    kind: u8,
    request: OrderRequest,
    account_id: ID,
    receive_address: address,
    timing: OrderTiming,
    escrow: OrderEscrow,
    position: HeldPosition,
): QueuedOrder {
    QueuedOrder {
        status: STATUS_PENDING,
        kind,
        request,
        account_id,
        receive_address,
        timing,
        escrow,
        position,
        price: CommittedPrice { spot: 0, tick_ms: 0, generation_us: 0 },
        result: OrderResult { reason: 0, quantity: 0, amount: 0, finished_at_ms: 0 },
        receipt: option::none(),
        funds: sui::balance::zero(),
    }
}

#[test_only]
/// Mark an unfinished record RefundDue with `reason`, the reserved status
/// nothing sets at launch, so the tests can drive its refund.
public(package) fun mark_refund_due_for_testing(book: &mut OrderBook, record_id: u64, reason: u8) {
    let record = &mut book.orders[record_id];
    assert!(is_unfinished(record.status));
    record.status = STATUS_REFUND_DUE;
    record.result.reason = reason;
}

#[test_only]
/// Skip `count` record IDs, so the next record joins the last cohort's span
/// with `count` missing records before it. Stands in for the hundreds of
/// visited-but-finished records only a full queue produces.
public(package) fun skip_record_ids_for_testing(book: &mut OrderBook, count: u64) {
    book.next_id = book.next_id + count;
}
