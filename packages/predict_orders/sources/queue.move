// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// One expiry market's delayed-execution queue, `MarketQueue`, and its flows:
/// placement of queued mints and early sells, commit of verified Pyth Lazer
/// prices, resolve at the committed tick, the deadline and admin refunds, the
/// settlement drain and payout walk, cleanup, and the queue reads.
///
/// Every money-moving step runs inside one of Predict's order-flow primitives,
/// which check their own gates and bindings when they run: admission
/// (`admit_mint`, `admit_sell`), `commit`, `try_fill`, `release`, and
/// `try_pay_settled`. The queue owns what Predict leaves to the companion: τ and
/// the deadline, the stuck gate, capacities and per-account caps, cohort order,
/// the exact-or-backup tick choice, escrow custody, refund routing, and the
/// queue events. Each record holds Predict's receipt for its order and that
/// order's own escrow, so a refund pays exactly that record's escrow.
///
/// A queued fill never enters the account: it stays an Open record until
/// `enqueue_redeem_open` sells it or the settlement payout walk pays it.
module deepbook_predict_orders::queue;

use account::account::{AccountWrapper, Auth};
use deepbook_predict::{
    admin::AdminCap,
    expiry_market::{ExpiryMarket, OrderReceipt, RedeemQuote},
    predict_account,
    pricing::Pricer,
    protocol_config::ProtocolConfig
};
use deepbook_predict_math::{lazer_price::{Self, LazerPrice}, math as pmath};
use deepbook_predict_orders::{
    delayed_execution_config::{Self, DelayedExecutionPolicy},
    desk::OrderDesk,
    order_flow,
    order_queue::{Self, OrderBook, OrderRequest, OrderTiming, OrderView, HeldPosition},
    queue_events
};
use propbook::{
    block_scholes_store::{BlockScholesSVIStore, BlockScholesValueStore},
    pyth_feed::PythFeed,
    registry::OracleRegistry
};
use pyth_lazer::update::Update;
use sui::{accumulator::AccumulatorRoot, balance::{Self, Balance}, clock::Clock, derived_object};
use usdc::usdc::USDC;

const EWrongDesk: u64 = 0;
const EWrongMarket: u64 = 1;
const EQueueStuck: u64 = 2;
const EQueueFull: u64 = 3;
const EAccountOrderCap: u64 = 4;
const EPastCutoff: u64 = 5;
const EMintCostCapRequired: u64 = 6;
const EFeeNotCovered: u64 = 7;
const EBelowMinSell: u64 = 8;
const ERecordNotOpen: u64 = 9;
const ENotRecordOwner: u64 = 10;
const EMarketNotSettled: u64 = 11;
const EMarketNotExpired: u64 = 12;

// `settle_step` phases. Never renumbered after publish.
const PHASE_DRAIN: u8 = 0;
const PHASE_PAY: u8 = 1;
const PHASE_DONE: u8 = 2;

/// One market's queue under one desk, shared at the ID derived from the desk
/// and the market (`queue_id`). Trading takes it mutably, so calls on one
/// market's queue serialize here and never on the desk.
public struct MarketQueue has key {
    id: UID,
    desk_id: ID,
    expiry_market_id: ID,
    book: OrderBook,
    /// Set by the `settle_step` call that emits `MarketPayoutsCompleted`.
    payouts_completed: bool,
}

#[test_only]
/// Stands in for one verified Lazer update in `commit_for_testing`, since a
/// real `Update` has no Move test constructor: its channel and envelope, and
/// per feed the price `lazer_price::from_update` would decode.
public struct TestUpdate has copy, drop {
    channel: u8,
    envelope_us: u64,
    feed_ids: vector<u32>,
    prices: vector<Option<LazerPrice>>,
}

// === Public Functions ===

// --- Reads ---
// For SDK, keeper, and devInspect reads.

public fun phase_drain(): u8 { PHASE_DRAIN }

public fun phase_pay(): u8 { PHASE_PAY }

public fun phase_done(): u8 { PHASE_DONE }

/// Return the ID of `expiry_market_id`'s queue under `desk_id`, whether or not
/// it exists yet. For PTB construction.
public fun queue_id(desk_id: ID, expiry_market_id: ID): ID {
    derived_object::derive_address(desk_id, expiry_market_id).to_id()
}

public fun id(queue: &MarketQueue): ID { queue.id.to_inner() }

public fun desk_id(queue: &MarketQueue): ID { queue.desk_id }

public fun expiry_market_id(queue: &MarketQueue): ID { queue.expiry_market_id }

/// Return one record, or `none` for a missing or deleted record ID.
public fun order(queue: &MarketQueue, record_id: u64): Option<OrderView> {
    queue.book.view(record_id)
}

/// Return `(resolve_head, next_id, last_tau_ms, last_committed_tau_ms)`.
/// `resolve_head` is a lower bound on the first unfinished record.
public fun queue_heads(queue: &MarketQueue): (u64, u64, u64, u64) {
    let book = &queue.book;
    (book.resolve_head(), book.next_id(), book.last_tau_ms(), book.last_committed_tau_ms())
}

/// Return `(payout_cursor, next_id, payouts_completed)`. The settlement payout
/// walk is finished once `payouts_completed` is set.
public fun payout_progress(queue: &MarketQueue): (u64, u64, bool) {
    (queue.book.payout_cursor(), queue.book.next_id(), queue.payouts_completed)
}

/// Return `(cohort count, oldest uncommitted τ, oldest uncommitted τ above
/// last_committed_tau_ms)`. The third value is the cohort the stuck gate's first
/// rule watches.
public fun waiting_cohorts(queue: &MarketQueue): (u64, Option<u64>, Option<u64>) {
    let book = &queue.book;
    (
        book.cohort_count(),
        book.oldest_uncommitted_tau(),
        book.oldest_uncommitted_tau_above_committed(),
    )
}

/// Whether placement would refuse a new order as stuck right now (both rules of
/// the stuck gate). Drives the app's "pricing delayed" banner.
public fun queue_stuck(queue: &MarketQueue, desk: &OrderDesk, clock: &Clock): bool {
    queue.book.is_stuck(desk.policy_ref().stuck_threshold_ms(), clock.timestamp_ms())
}

/// Return `(pending_mints, pending_sells)`, the unfinished orders counted against
/// the policy capacities.
public fun pending_counts(queue: &MarketQueue): (u64, u64) {
    (queue.book.pending_mints(), queue.book.pending_sells())
}

/// Return the unfinished queued orders `account_id` holds in this queue.
public fun waiting_orders(queue: &MarketQueue, account_id: ID): u64 {
    queue.book.account_waiting(account_id)
}

/// Return τ of the oldest cohort with an unfinished order, for monitoring.
public fun oldest_unfinished_tau_ms(queue: &MarketQueue): Option<u64> {
    queue.book.oldest_unfinished_tau()
}

/// Quote an early sell of `close_quantity` from the Open record `record_id` at a
/// live `Pricer`, with the wrapper account's builder code, through Predict's
/// `quote_close`: the close a queued sell fills, with the trading fee at the
/// clock instead of a committed tick. `proceeds` is before the order fee.
/// Changes nothing. Aborts `ERecordNotOpen` for a missing or non-Open record,
/// and otherwise as `quote_close` does. Does not check that the account owns
/// the record. For SDK and devInspect pricing before `enqueue_redeem_open`.
public fun quote_redeem_open(
    queue: &MarketQueue,
    market: &ExpiryMarket,
    wrapper: &AccountWrapper,
    pricer: &Pricer,
    record_id: u64,
    close_quantity: u64,
    clock: &Clock,
): RedeemQuote {
    assert!(queue.expiry_market_id == market.id(), EWrongMarket);
    queue.assert_open(record_id);
    market.quote_close(
        pricer,
        queue.book.receipt(record_id),
        close_quantity,
        predict_account::builder_code_id(wrapper.load_account()),
        clock,
    )
}

// --- Queue creation ---

/// Create and share `market`'s queue under `desk`. Permissionless; the caller
/// pays its storage. The queue's ID is derived from the desk and the market, so
/// a second call for the same market aborts.
public fun create_and_share(desk: &mut OrderDesk, market: &ExpiryMarket, ctx: &mut TxContext): ID {
    desk.assert_version();
    let expiry_market_id = market.id();
    let desk_id = desk.id();
    let queue = MarketQueue {
        id: derived_object::claim(desk.uid_mut(), expiry_market_id),
        desk_id,
        expiry_market_id,
        book: order_queue::new_book(ctx),
        payouts_completed: false,
    };
    let queue_id = queue.id();
    transfer::share_object(queue);
    queue_id
}

// --- Placement ---

/// Place a queued mint for an exact quantity, priced later at Pyth's signed
/// price for its τ. `max_cost` caps the all-in withdrawal and is mandatory;
/// `max_probability` caps the entry probability at τ. Escrows the budget,
/// `min(max_cost, quantity, available - order_fee)`, and the order fee, and
/// returns the new record ID.
///
/// Aborts, charging nothing, when the queue refuses the order: the desk floor,
/// another desk's or market's queue (`EWrongDesk`, `EWrongMarket`), a stuck or
/// full queue (`EQueueStuck`, `EQueueFull`, `EAccountOrderCap`), τ at or past
/// the cutoff (`EPastCutoff`), an unlimited or zero `max_cost`
/// (`EMintCostCapRequired`), or a balance not above the order fee
/// (`EFeeNotCovered`). Then Predict's `admit_mint` applies its gates, the
/// order's own limits at the clock, and the market's spare cash.
public fun enqueue_exact_quantity(
    queue: &mut MarketQueue,
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    desk: &OrderDesk,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    max_cost: u64,
    max_probability: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    let request = order_queue::new_request(
        lower_tick,
        higher_tick,
        quantity,
        0,
        0,
        max_cost,
        max_probability,
        0,
        0,
    );
    queue.enqueue_mint(
        market,
        wrapper,
        auth,
        desk,
        config,
        propbook_registry,
        pyth,
        bs_values,
        bs_svi,
        order_queue::kind_exact_quantity(),
        request,
        root,
        clock,
        ctx,
    )
}

/// Place a queued premium-budget mint: sized at τ under `max_premium`, at least
/// `min_quantity`, with the all-in withdrawal capped by the mandatory `max_cost`.
/// Escrows `min(max_cost, available - order_fee)` and the order fee. Refuses
/// orders like `enqueue_exact_quantity`. Returns the new record ID.
public fun enqueue_exact_amount(
    queue: &mut MarketQueue,
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    desk: &OrderDesk,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    lower_tick: u64,
    higher_tick: u64,
    max_premium: u64,
    min_quantity: u64,
    max_cost: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    let request = order_queue::new_request(
        lower_tick,
        higher_tick,
        0,
        max_premium,
        min_quantity,
        max_cost,
        0,
        0,
        0,
    );
    queue.enqueue_mint(
        market,
        wrapper,
        auth,
        desk,
        config,
        propbook_registry,
        pyth,
        bs_values,
        bs_svi,
        order_queue::kind_exact_amount(),
        request,
        root,
        clock,
        ctx,
    )
}

/// Place a queued all-in-budget mint: sized at τ so the all-in cost fits
/// `max_cost`, at least `min_quantity`. Escrows `min(max_cost, available -
/// order_fee)` and the order fee. `max_cost` is mandatory here too: the
/// unlimited value is refused. Refuses orders like `enqueue_exact_quantity`.
/// Returns the new record ID.
public fun enqueue_exact_cost(
    queue: &mut MarketQueue,
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    desk: &OrderDesk,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    lower_tick: u64,
    higher_tick: u64,
    max_cost: u64,
    min_quantity: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    let request = order_queue::new_request(
        lower_tick,
        higher_tick,
        0,
        0,
        min_quantity,
        max_cost,
        0,
        0,
        0,
    );
    queue.enqueue_mint(
        market,
        wrapper,
        auth,
        desk,
        config,
        propbook_registry,
        pyth,
        bs_values,
        bs_svi,
        order_queue::kind_exact_cost(),
        request,
        root,
        clock,
        ctx,
    )
}

/// Place a queued early sell of `close_quantity` of an Open record's position.
/// `record_id` is the record's queue ID, not the position's order ID. The source
/// record must belong to this account (`ENotRecordOwner`) and be Open
/// (`ERecordNotOpen`, also for a missing ID). It is marked Closed and its
/// receipt and whole position move into the new record until the sell fills or
/// refunds. `min_probability` and `min_proceeds` are the close-side floors at τ.
/// Returns the new record ID.
///
/// Escrows only the order fee, so a balance equal to it is enough. Refuses a
/// sell below `min_sell_quantity` or one leaving a remainder below it
/// (`EBelowMinSell`), and otherwise like `enqueue_exact_quantity`. Predict's
/// `admit_sell` is open during the trading pause and a market mint pause and has
/// no spare-cash check: the keeper funds the market before τ, and resolve
/// refunds a sell the market still cannot cover.
public fun enqueue_redeem_open(
    queue: &mut MarketQueue,
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    desk: &OrderDesk,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    record_id: u64,
    close_quantity: u64,
    min_probability: u64,
    min_proceeds: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    let policy = *desk.policy_ref();
    let account_id = wrapper.load_account().account_id();
    let timing = queue.begin_enqueue(market, desk, config, &policy, false, account_id, clock);
    // Status, not the record ID against `resolve_head`: records finish out of
    // order, so only the status says whether this one holds a position.
    queue.assert_open(record_id);
    let source = queue.book.view(record_id).destroy_some();
    assert!(source.account_id() == account_id, ENotRecordOwner);
    let (lower_tick, higher_tick, held_quantity) = pmath::order_terms(
        source.position().order_id(),
    );
    let min_sell_quantity = policy.min_sell_quantity();
    assert!(close_quantity >= min_sell_quantity, EBelowMinSell);
    // A partial sell leaves a sellable remainder. A close above the held
    // quantity fails Predict's dry run instead.
    assert!(
        close_quantity >= held_quantity || held_quantity - close_quantity >= min_sell_quantity,
        EBelowMinSell,
    );

    wrapper.settle<USDC>(root, clock);
    let account = wrapper.load_account_mut(auth);
    let order_fee = policy.order_fee();
    assert!(account.balance<USDC>(root, clock) >= order_fee, EFeeNotCovered);
    let (mut receipt, position) = queue.book.close_open_record(record_id);
    order_flow::admit_sell(
        market,
        config,
        account,
        &mut receipt,
        propbook_registry,
        pyth,
        bs_values,
        bs_svi,
        close_quantity,
        min_probability,
        min_proceeds,
        order_fee,
        policy.svi_max_age_ms(),
        timing.pyth_channel(),
        timing.tau_ms(),
        timing.deadline_ms(),
        clock,
        ctx,
    );
    let funds = if (order_fee > 0) {
        account.withdraw<USDC>(order_fee, ctx).into_balance()
    } else {
        balance::zero()
    };
    let request = order_queue::new_request(
        lower_tick,
        higher_tick,
        close_quantity,
        0,
        0,
        0,
        0,
        min_probability,
        min_proceeds,
    );
    let builder_code_id = predict_account::builder_code_id(account);
    let referrer_account_id = account.referrer_account_id();
    let receive_address = account.receive_address();
    queue.place(
        market,
        order_queue::kind_redeem_open(),
        request,
        account_id,
        receive_address,
        timing,
        0,
        order_fee,
        position,
        receipt,
        funds,
        builder_code_id,
        referrer_account_id,
        option::some(record_id),
        clock,
    )
}

// --- Commit and resolve ---

/// Attach verified Pyth Lazer prices to the waiting cohorts whose τ they match.
/// Permissionless. Each update must come from the Pyth Lazer verifier earlier
/// in the same PTB; their order in `updates` does not matter. An update that
/// matches no waiting cohort is skipped.
///
/// Matching reads only the inline cohort list and picks at most one update per
/// waiting cohort before its deadline: the one stamped exactly its τ on its
/// channel, or else, once the price buffer is above zero and now is at least
/// `gap_wait_ms` past τ, the one stamped one tick of the cohort's own channel
/// later. Each matched cohort then commits whole or not at all: one price per
/// feed is decoded through `lazer_price::from_update`, every Pending order is
/// checked against it before any is written, and an empty price, a price
/// generated before τ, or an envelope after now leaves the cohort for a later
/// commit or its deadline refund. The decode aborts on an update that lacks an
/// order's feed or one of its properties, because the caller passed the wrong
/// update. Each committed mint escrows the subsidy Predict reserves for it.
///
/// Uses Lazer's v1 `Update`, which Pyth marked deprecated on Mainnet but still
/// serves; v2 arrives with a later library constructor.
#[allow(deprecated_usage)]
public fun commit(
    queue: &mut MarketQueue,
    market: &mut ExpiryMarket,
    desk: &OrderDesk,
    config: &ProtocolConfig,
    updates: vector<Update>,
    clock: &Clock,
    ctx: &TxContext,
) {
    let channels = updates.map_ref!(|update| channel_of(update));
    let envelopes_us = updates.map_ref!(|update| update.timestamp());
    commit_updates!(
        queue,
        market,
        desk,
        config,
        &channels,
        &envelopes_us,
        |index, feed_id| lazer_price::from_update(&updates[index], feed_id),
        clock,
        ctx.sender(),
    );
}

/// Fill or refund committed orders in τ order, visiting at most `max_orders`
/// records. Permissionless. Returns how many orders it finished.
///
/// Walks the cohorts in τ order and loads only committed or overdue ones; a
/// cohort still waiting for its price is skipped without loading a record.
/// Every record visited counts against `max_orders`, finished or missing ones
/// included, so one call stays inside Sui's per-transaction object limit. An
/// order at or past its deadline is refunded (reason 5), never filled. A
/// committed order goes to Predict's `try_fill`, which fills it or returns the
/// refund reason (1, 2, 4, or 8); the queue returns the escrow Predict hands
/// back to the trader. Returns 0 on a settled market, whose waiting orders the
/// settlement drain refunds.
public fun resolve(
    queue: &mut MarketQueue,
    market: &mut ExpiryMarket,
    desk: &OrderDesk,
    config: &ProtocolConfig,
    max_orders: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    queue.assert_bound(desk, market);
    if (market.is_settled()) return 0;

    let now_ms = clock.timestamp_ms();
    let sender = ctx.sender();
    // Spans are only dropped by `advance_heads` below, so indices stay stable.
    let cohort_count = queue.book.cohort_count();
    let mut visited = 0;
    let mut finished = 0;
    let mut index = 0;
    while (index < cohort_count && visited < max_orders) {
        let span = queue.book.cohort(index);
        let mut unfinished = span.span_unfinished();
        if (unfinished > 0 && (span.span_committed() || now_ms >= span.span_deadline_ms())) {
            let end_id = span.span_end_id();
            let mut record_id = span.span_first_id();
            while (unfinished > 0 && record_id < end_id && visited < max_orders) {
                visited = visited + 1;
                if (queue.resolve_record(market, config, record_id, clock, sender, now_ms)) {
                    finished = finished + 1;
                    unfinished = unfinished - 1;
                };
                record_id = record_id + 1;
            };
            // Every record before `record_id` has finished, so a later walk can
            // start there without loading them again.
            if (unfinished > 0 && record_id < end_id) {
                queue.book.set_cohort_first_id(index, record_id);
            };
        };
        index = index + 1;
    };
    queue.book.advance_heads();
    finished
}

// --- Refunds and cleanup ---

/// Refund waiting orders at or past their deadline (reason 5), visiting at most
/// `max_orders` records, refunded or not. It walks the cohorts in τ order and
/// stops at the first one not yet due, since deadlines never decrease along the
/// queue. Permissionless, and available while Predict is frozen or this
/// companion's witness is disabled: Predict's `release` checks only its version
/// floor. Returns how many orders it refunded: `0`, without aborting, when none
/// is due.
public fun refund(
    queue: &mut MarketQueue,
    market: &mut ExpiryMarket,
    desk: &OrderDesk,
    config: &ProtocolConfig,
    max_orders: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    queue.assert_bound(desk, market);
    let now_ms = clock.timestamp_ms();
    queue.refund_walk(market, config, now_ms, max_orders, true, true, ctx.sender(), now_ms)
}

/// Refund the listed waiting orders at once (reason 7), wherever they sit in
/// the queue. Predict's `AdminCap` only, and available while Predict is frozen.
/// Missing and finished IDs are skipped.
public fun admin_refund(
    queue: &mut MarketQueue,
    market: &mut ExpiryMarket,
    _admin_cap: &AdminCap,
    desk: &OrderDesk,
    config: &ProtocolConfig,
    record_ids: vector<u64>,
    clock: &Clock,
    ctx: &TxContext,
) {
    queue.assert_bound(desk, market);
    let now_ms = clock.timestamp_ms();
    let sender = ctx.sender();
    record_ids.do!(|record_id| {
        queue.release_record(
            market,
            config,
            record_id,
            order_queue::reason_admin(),
            true,
            true,
            sender,
            now_ms,
        );
    });
    queue.book.advance_heads();
}

/// Delete Refunded and Closed records of a settled market. Permissionless; the
/// storage rebate goes to the caller. Missing IDs, other statuses, and records
/// still holding a receipt or escrow are skipped; `QueuedOrdersCleaned` is
/// emitted only when a record was deleted. Takes `&Clock` only to stamp the
/// event.
public fun cleanup(
    queue: &mut MarketQueue,
    market: &ExpiryMarket,
    desk: &OrderDesk,
    record_ids: vector<u64>,
    clock: &Clock,
) {
    queue.assert_bound(desk, market);
    assert!(market.is_settled(), EMarketNotSettled);
    let book = &mut queue.book;
    let mut cleaned = vector[];
    record_ids.do!(|record_id| {
        if (book.remove_finished_record(record_id)) cleaned.push_back(record_id);
    });
    if (cleaned.is_empty()) return;
    queue_events::emit_queued_orders_cleaned(
        queue.expiry_market_id,
        cleaned,
        clock.timestamp_ms(),
    );
}

// --- Settlement ---

/// Run one bounded settlement phase on this queue and return the phase it
/// reached. Permissionless; aborts `EMarketNotExpired` before expiry.
///
/// - DRAIN, while unfinished orders remain: refund them in τ order with reason
///   5, visiting at most the policy's `settle_refund_batch` records, refunded
///   or not. No pruning and no account rows, so each refund loads one record.
///   Runs before and after Predict settles, and while Predict is frozen.
/// - PAY, once nothing is unfinished and Predict has settled the market: from
///   the payout cursor, visit at most `settle_payout_batch` records. Each Open
///   record is paid its settled payout through `try_pay_settled` (zero for a
///   loser), marked Closed, and reported with `OpenRecordSettled`. A record the
///   market cannot pay stays Open with `OpenRecordPayoutSkipped`. Before Predict
///   settles, a PAY call changes nothing.
/// - DONE: the call whose walk reaches the last record emits
///   `MarketPayoutsCompleted`; later calls change nothing.
///
/// The keeper sends one call per transaction until it returns `phase_done()`.
public fun settle_step(
    queue: &mut MarketQueue,
    market: &mut ExpiryMarket,
    desk: &OrderDesk,
    config: &ProtocolConfig,
    clock: &Clock,
    ctx: &TxContext,
): u8 {
    queue.assert_bound(desk, market);
    let now_ms = clock.timestamp_ms();
    assert!(now_ms >= market.expiry(), EMarketNotExpired);
    if (queue.payouts_completed) return PHASE_DONE;
    let policy = desk.policy_ref();
    if (queue.book.oldest_unfinished_tau().is_some()) {
        // Every deadline is at least 5 s before expiry, so every waiting order is
        // due: walk all cohorts.
        queue.refund_walk(
            market,
            config,
            std::u64::max_value!(),
            policy.settle_refund_batch(),
            false,
            false,
            ctx.sender(),
            now_ms,
        );
        return if (queue.book.oldest_unfinished_tau().is_some()) PHASE_DRAIN else PHASE_PAY
    };
    if (!market.is_settled()) return PHASE_PAY;

    queue.book.settle_queue();
    let payout_cursor = queue.book.payout_cursor();
    let next_id = queue.book.next_id();
    let end_id = payout_cursor + policy.settle_payout_batch().min(next_id - payout_cursor);
    let mut record_id = payout_cursor;
    while (record_id < end_id) {
        queue.pay_open_record(market, config, record_id, now_ms);
        record_id = record_id + 1;
    };
    queue.book.set_payout_cursor(end_id);
    if (end_id < next_id) return PHASE_PAY;
    queue.payouts_completed = true;
    queue_events::emit_market_payouts_completed(queue.expiry_market_id, now_ms);
    PHASE_DONE
}

// === Private Functions ===

// --- Placement ---

/// The three queued mints after their request is built: the queue's checks and
/// τ, the escrow terms, Predict's admission, then the escrow withdrawal and the
/// record. `kind` picks the budget rule.
fun enqueue_mint(
    queue: &mut MarketQueue,
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    desk: &OrderDesk,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    kind: u8,
    request: OrderRequest,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    let policy = *desk.policy_ref();
    let account_id = wrapper.load_account().account_id();
    let timing = queue.begin_enqueue(market, desk, config, &policy, true, account_id, clock);
    wrapper.settle<USDC>(root, clock);
    let account = wrapper.load_account_mut(auth);

    let max_cost = request.max_cost();
    assert!(max_cost > 0 && max_cost != std::u64::max_value!(), EMintCostCapRequired);
    let order_fee = policy.order_fee();
    let available = account.balance<USDC>(root, clock);
    assert!(available > order_fee, EFeeNotCovered);
    // A fill never costs more than its quantity, so an exact-quantity budget
    // stops there.
    let budget = max_cost.min(available - order_fee);
    let budget = if (kind == order_queue::kind_exact_quantity()) {
        budget.min(request.quantity())
    } else {
        budget
    };
    let receipt = order_flow::admit_mint(
        market,
        config,
        account,
        propbook_registry,
        pyth,
        bs_values,
        bs_svi,
        kind,
        request.lower_tick(),
        request.higher_tick(),
        request.quantity(),
        request.max_premium(),
        request.min_quantity(),
        request.max_probability(),
        budget,
        order_fee,
        policy.svi_max_age_ms(),
        timing.pyth_channel(),
        timing.tau_ms(),
        timing.deadline_ms(),
        clock,
        ctx,
    );
    let funds = account.withdraw<USDC>(budget + order_fee, ctx).into_balance();
    let builder_code_id = predict_account::builder_code_id(account);
    let referrer_account_id = account.referrer_account_id();
    let receive_address = account.receive_address();
    queue.place(
        market,
        kind,
        request,
        account_id,
        receive_address,
        timing,
        budget,
        order_fee,
        order_queue::empty_position(),
        receipt,
        funds,
        builder_code_id,
        referrer_account_id,
        option::none(),
        clock,
    )
}

/// The queue's own placement checks, in order: the desk floor and the queue's
/// bindings; the stuck, capacity, and per-account checks; then τ and the cutoff
/// on the final τ. Returns the order's timing.
fun begin_enqueue(
    queue: &MarketQueue,
    market: &ExpiryMarket,
    desk: &OrderDesk,
    config: &ProtocolConfig,
    policy: &DelayedExecutionPolicy,
    is_mint: bool,
    account_id: ID,
    clock: &Clock,
): OrderTiming {
    queue.assert_bound(desk, market);
    let now_ms = clock.timestamp_ms();
    let book = &queue.book;
    assert!(!book.is_stuck(policy.stuck_threshold_ms(), now_ms), EQueueStuck);
    let (pending, capacity) = if (is_mint) {
        (book.pending_mints(), policy.mint_capacity())
    } else {
        (book.pending_sells(), policy.sell_capacity())
    };
    assert!(pending < capacity, EQueueFull);
    assert!(book.account_waiting(account_id) < policy.per_account_cap(), EAccountOrderCap);

    // `plan_timing` returns τ after both pushes (a channel change, a committed
    // cohort), so the cutoff binds the τ the order actually gets. It also
    // refuses an expired market: τ is within one tick of `now + delay`, while
    // the cutoff sits at least `stall_timeout_ms + 5_000` before expiry.
    let timing = book.plan_timing(policy, market.expiry(), config.no_trade_window_ms(), now_ms);
    assert!(timing.tau_ms() < timing.cutoff_ms(), EPastCutoff);
    timing
}

/// Store an admitted order with its receipt and escrow, then emit
/// `OrderEnqueued` with the post-call cash figures. Returns the record ID.
fun place(
    queue: &mut MarketQueue,
    market: &ExpiryMarket,
    kind: u8,
    request: OrderRequest,
    account_id: ID,
    receive_address: address,
    timing: OrderTiming,
    budget: u64,
    order_fee: u64,
    position: HeldPosition,
    receipt: OrderReceipt,
    funds: Balance<USDC>,
    builder_code_id: Option<ID>,
    referrer_account_id: Option<ID>,
    source_record_id: Option<u64>,
    clock: &Clock,
): u64 {
    // Predict computed the cash need and the subsidy bound at admission.
    let (_, _, _, _, _, cash_need, subsidy_bound, vol) = receipt.receipt_info();
    let order = order_queue::new_order(
        kind,
        request,
        account_id,
        receive_address,
        timing,
        order_queue::new_escrow(budget, order_fee, subsidy_bound, cash_need),
        position,
        receipt,
        funds,
    );
    let record_id = queue.book.append(order);
    let (market_cash, required_cash, waiting_cash_need) = cash_figures(market);
    queue_events::emit_order_enqueued(
        queue.expiry_market_id,
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
        clock.timestamp_ms(),
    );
    record_id
}

// --- Commit ---

/// Commit's logic over a batch of verified updates, given each update's channel
/// and envelope and a decode of one feed of one update. `commit` decodes real
/// Lazer updates; `commit_for_testing` stands in for them.
macro fun commit_updates(
    $queue: &mut MarketQueue,
    $market: &mut ExpiryMarket,
    $desk: &OrderDesk,
    $config: &ProtocolConfig,
    $channels: &vector<u8>,
    $envelopes_us: &vector<u64>,
    $price_of: |u64, u32| -> Option<LazerPrice>,
    $clock: &Clock,
    $sender: address,
) {
    let queue = $queue;
    let market = $market;
    let config = $config;
    let clock = $clock;
    let sender = $sender;
    let now_ms = clock.timestamp_ms();
    let (cohort_indices, update_indices) = queue.match_cohorts(
        market,
        $desk,
        $channels,
        $envelopes_us,
        now_ms,
    );
    cohort_indices.length().do!(|i| {
        let index = cohort_indices[i];
        let span = queue.book.cohort(index);
        let tau_ms = span.span_tau_ms();
        // One decode per feed in the cohort, checked for every Pending order
        // before any is written.
        let mut feed_ids = vector[];
        let mut prices = vector[];
        let mut usable = true;
        let mut record_id = span.span_first_id();
        while (usable && record_id < span.span_end_id()) {
            queue.book.pending_feed(record_id).do!(|feed_id| {
                let mut slot = feed_ids.find_index!(|id| *id == feed_id);
                if (slot.is_none()) {
                    feed_ids.push_back(feed_id);
                    prices.push_back($price_of(update_indices[i], feed_id));
                    slot.fill(feed_ids.length() - 1);
                };
                usable = price_fits(&prices[slot.destroy_some()], tau_ms, now_ms);
            });
            record_id = record_id + 1;
        };
        if (usable && !feed_ids.is_empty()) {
            queue.commit_cohort(market, config, index, &feed_ids, &prices, clock, sender);
        };
    });
}

/// Pick, for each waiting cohort before its deadline, the update that prices
/// it, as parallel vectors of cohort and update indices. Reads only the inline
/// cohort list. Nothing matches on a settled market.
fun match_cohorts(
    queue: &MarketQueue,
    market: &ExpiryMarket,
    desk: &OrderDesk,
    channels: &vector<u8>,
    envelopes_us: &vector<u64>,
    now_ms: u64,
): (vector<u64>, vector<u64>) {
    queue.assert_bound(desk, market);
    let mut cohort_indices = vector[];
    let mut update_indices = vector[];
    if (market.is_settled()) return (cohort_indices, update_indices);
    let policy = desk.policy_ref();
    let buffer_ms = policy.pyth_price_buffer_ms();
    let gap_wait_ms = policy.gap_wait_ms();
    let book = &queue.book;
    book.cohort_count().do!(|index| {
        let span = book.cohort(index);
        if (
            !span.span_committed() && span.span_unfinished() > 0 && now_ms < span.span_deadline_ms()
        ) {
            let tau_ms = span.span_tau_ms();
            let channel = span.span_pyth_channel();
            let mut update = find_update(channels, envelopes_us, channel, tau_ms);
            // The buffer only switches the backup on: a cohort has one admissible
            // backup, one tick of its own channel after τ, whatever the policy
            // channel is now.
            if (update.is_none() && buffer_ms > 0 && now_ms >= tau_ms + gap_wait_ms) {
                update =
                    find_update(
                        channels,
                        envelopes_us,
                        channel,
                        tau_ms + delayed_execution_config::channel_tick_ms(channel),
                    );
            };
            update.do!(|update_index| {
                cohort_indices.push_back(index);
                update_indices.push_back(update_index);
            });
        };
    });
    (cohort_indices, update_indices)
}

/// The first update on `channel` stamped exactly `tick_ms`.
fun find_update(
    channels: &vector<u8>,
    envelopes_us: &vector<u64>,
    channel: u8,
    tick_ms: u64,
): Option<u64> {
    let mut index = 0;
    while (index < channels.length()) {
        if (channels[index] == channel && envelopes_us[index] == tick_ms * 1000) {
            return option::some(index)
        };
        index = index + 1;
    };
    option::none()
}

/// The checks Predict's `commit` makes that the cohort's price can still fail
/// after matching: a price exists, generated at or after τ, with its envelope
/// at or before now. Checked across the cohort first so a commit never aborts
/// halfway through it.
fun price_fits(price: &Option<LazerPrice>, tau_ms: u64, now_ms: u64): bool {
    if (price.is_none()) return false;
    let price = price.borrow();
    price.generation_us() >= tau_ms * 1000 && price.envelope_us() <= now_ms * 1000
}

/// Commit every Pending order of a checked cohort at its feed's price, escrow
/// each mint's reserved subsidy, mark the cohort committed, and emit
/// `CohortCommitted` with the first order's price.
fun commit_cohort(
    queue: &mut MarketQueue,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    index: u64,
    feed_ids: &vector<u32>,
    prices: &vector<Option<LazerPrice>>,
    clock: &Clock,
    sender: address,
) {
    let span = queue.book.cohort(index);
    let mut first_price = option::none();
    let mut record_id = span.span_first_id();
    while (record_id < span.span_end_id()) {
        queue.book.pending_feed(record_id).do!(|feed_id| {
            let slot = feed_ids.find_index!(|id| *id == feed_id).destroy_some();
            let price = *prices[slot].borrow();
            let subsidy = order_flow::commit(
                market,
                config,
                queue.book.receipt_mut(record_id),
                &price,
                clock,
            );
            queue
                .book
                .commit_order(
                    record_id,
                    order_queue::new_committed_price(
                        price.spot(),
                        price.envelope_us() / 1000,
                        price.generation_us(),
                    ),
                    subsidy,
                );
            if (first_price.is_none()) first_price.fill(price);
        });
        record_id = record_id + 1;
    };
    queue.book.mark_cohort_committed(index);
    let price = first_price.destroy_some();
    queue_events::emit_cohort_committed(
        queue.expiry_market_id,
        span.span_tau_ms(),
        price.envelope_us() / 1000,
        span.span_first_id(),
        span.span_end_id() - 1,
        price.spot(),
        price.generation_us(),
        price.feed_id(),
        span.span_pyth_channel(),
        sender,
        clock.timestamp_ms(),
    );
}

/// Lazer's v1 channel as `lazer_price` numbers it: a fixed-rate channel's id,
/// or `1` for real-time, on which no cohort is placed.
#[allow(deprecated_usage)]
fun channel_of(update: &Update): u8 {
    let channel = update.channel();
    if (channel.is_fixed_rate_50ms()) {
        lazer_price::channel_fixed_rate_50ms!()
    } else if (channel.is_fixed_rate_200ms()) {
        lazer_price::channel_fixed_rate_200ms!()
    } else {
        1
    }
}

// --- Resolve ---

/// Finish one record if it can finish now, returning whether it did. A record at
/// or past its deadline is refunded with reason 5 whatever its cohort, a
/// RefundDue one with its stored reason, and a Committed one is filled or
/// refunded with the reason Predict's fill returns. Missing and finished
/// records, and Pending ones before their deadline, are left alone.
fun resolve_record(
    queue: &mut MarketQueue,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    record_id: u64,
    clock: &Clock,
    sender: address,
    now_ms: u64,
): bool {
    let view = queue.book.view(record_id);
    if (view.is_none()) return false;
    let view = view.destroy_some();
    let status = view.status();
    if (
        status == order_queue::status_refund_due()
            || (order_queue::is_unfinished(status) && now_ms >= view.timing().deadline_ms())
    ) {
        return queue.release_record(
            market,
            config,
            record_id,
            order_queue::reason_deadline(),
            true,
            true,
            sender,
            now_ms,
        )
    };
    if (status != order_queue::status_committed()) return false;
    queue.fill_record(market, config, record_id, &view, clock, sender, now_ms);
    true
}

/// Hand a Committed record's receipt and escrow to Predict's `try_fill`, return
/// the escrow it hands back to the trader, and record the outcome: the position
/// a fill leaves (a mint's new position, a partial sell's replacement, or none
/// after a full close) with `QueuedOrderFilled`, or the refund with
/// `QueuedOrderRefunded`.
fun fill_record(
    queue: &mut MarketQueue,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    record_id: u64,
    view: &OrderView,
    clock: &Clock,
    sender: address,
    now_ms: u64,
) {
    let (receipt, funds) = queue.book.take_order(record_id);
    let (
        reason,
        kept,
        change,
        quantity,
        amount,
        trading_fee,
        builder_fee,
        referral_fee,
        subsidy_used,
        inventory_impact,
    ) = order_flow::try_fill(market, config, receipt, funds, clock);
    let returned = change.value();
    send_or_destroy(change, view.receive_address());
    if (reason != 0) {
        // Predict keeps the order fee for reasons 1 and 2 and returns the rest of
        // the budget and fee with the escrow it hands back.
        let order_fee_returned = if (
            reason == order_queue::reason_limits() || reason == order_queue::reason_admission()
        ) {
            0
        } else {
            view.escrow().order_fee()
        };
        queue.finish_refund(
            market,
            record_id,
            view,
            kept,
            reason,
            returned - order_fee_returned,
            order_fee_returned,
            true,
            sender,
            now_ms,
        );
        return
    };
    let position = if (kept.is_none()) {
        order_queue::empty_position()
    } else {
        let (_, _, _, order_id, _, _, _, _) = kept.borrow().receipt_info();
        if (order_queue::is_mint(view.kind())) {
            order_queue::new_held_position(order_id, order_id, view.price().tick_ms())
        } else {
            let held = view.position();
            order_queue::new_held_position(order_id, held.root_id(), held.opened_at_ms())
        }
    };
    let status = if (kept.is_some()) order_queue::status_open() else order_queue::status_closed();
    queue.book.finish_order(record_id, status, kept, position, 0, quantity, amount, true, now_ms);
    let (market_cash, required_cash, waiting_cash_need) = cash_figures(market);
    queue_events::emit_queued_order_filled(
        market_cash,
        required_cash,
        waiting_cash_need,
        queue.expiry_market_id,
        record_id,
        view.account_id(),
        view.kind(),
        quantity,
        amount,
        trading_fee,
        builder_fee,
        referral_fee,
        view.escrow().order_fee(),
        subsidy_used,
        inventory_impact,
        view.timing().tau_ms(),
        view.price().tick_ms(),
        position,
        sender,
        now_ms,
    );
}

// --- Refunds ---

/// Refund waiting orders cohort by cohort in τ order, through the cohorts whose
/// deadline is at or before `due_by_ms`, visiting at most `max_orders` records,
/// refunded or not. Every visited record has finished afterwards, so a walk that
/// stops inside a cohort moves that cohort's `first_id` to the first record it
/// did not visit. `advance_heads` runs once at the end so cohort indices stay
/// stable during the walk. Returns how many orders it refunded.
fun refund_walk(
    queue: &mut MarketQueue,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    due_by_ms: u64,
    max_orders: u64,
    prune: bool,
    count_account: bool,
    sender: address,
    now_ms: u64,
): u64 {
    let reason = order_queue::reason_deadline();
    let cohort_count = queue.book.cohort_count();
    let mut visited = 0;
    let mut refunded = 0;
    let mut index = 0;
    while (index < cohort_count && visited < max_orders) {
        let span = queue.book.cohort(index);
        // Deadlines never decrease along the queue, so no later cohort is due.
        if (span.span_deadline_ms() > due_by_ms) break;
        let first_id = span.span_first_id();
        let end_id = span.span_end_id();
        let mut unfinished = span.span_unfinished();
        let mut record_id = first_id;
        while (record_id < end_id && unfinished > 0 && visited < max_orders) {
            visited = visited + 1;
            if (
                queue.release_record(
                    market,
                    config,
                    record_id,
                    reason,
                    prune,
                    count_account,
                    sender,
                    now_ms,
                )
            ) {
                refunded = refunded + 1;
                unfinished = unfinished - 1;
            };
            record_id = record_id + 1;
        };
        // A cohort with nothing left is dropped by `advance_heads` instead.
        if (unfinished > 0 && record_id > first_id) {
            queue.book.set_cohort_first_id(index, record_id);
        };
        index = index + 1;
    };
    queue.book.advance_heads();
    refunded
}

/// Refund one unfinished record without filling it: Predict's `release` takes
/// back the record's reserved subsidy and its ledger entries, and the budget and
/// order fee go to the trader. A sell's record returns to Open holding its
/// position. A RefundDue record keeps its stored reason. Returns whether it
/// refunded a record: a missing or finished one is skipped. The caller owns
/// `advance_heads`.
fun release_record(
    queue: &mut MarketQueue,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    record_id: u64,
    reason: u8,
    prune: bool,
    count_account: bool,
    sender: address,
    now_ms: u64,
): bool {
    let view = queue.book.view(record_id);
    if (view.is_none()) return false;
    let view = view.destroy_some();
    let status = view.status();
    if (!order_queue::is_unfinished(status)) return false;
    let reason = if (status == order_queue::status_refund_due()) view.result().reason() else reason;
    let (receipt, mut funds) = queue.book.take_order(record_id);
    let subsidy = funds.split(view.escrow().subsidy_reserved());
    let kept = market.release(config, receipt, subsidy, prune);
    let returned = funds.value();
    send_or_destroy(funds, view.receive_address());
    let order_fee = view.escrow().order_fee();
    queue.finish_refund(
        market,
        record_id,
        &view,
        kept,
        reason,
        returned - order_fee,
        order_fee,
        count_account,
        sender,
        now_ms,
    );
    true
}

/// Record a refund: a sell's record, whose receipt came back open, returns to
/// Open with its position; a mint's is Refunded. Emits `QueuedOrderRefunded`.
fun finish_refund(
    queue: &mut MarketQueue,
    market: &ExpiryMarket,
    record_id: u64,
    view: &OrderView,
    kept: Option<OrderReceipt>,
    reason: u8,
    escrow_returned: u64,
    order_fee_returned: u64,
    count_account: bool,
    sender: address,
    now_ms: u64,
) {
    let position_returned = kept.is_some();
    let status = if (position_returned) {
        order_queue::status_open()
    } else {
        order_queue::status_refunded()
    };
    queue
        .book
        .finish_order(
            record_id,
            status,
            kept,
            view.position(),
            reason,
            0,
            0,
            count_account,
            now_ms,
        );
    let (market_cash, required_cash, waiting_cash_need) = cash_figures(market);
    queue_events::emit_queued_order_refunded(
        market_cash,
        required_cash,
        waiting_cash_need,
        queue.expiry_market_id,
        record_id,
        view.account_id(),
        view.kind(),
        reason,
        escrow_returned,
        order_fee_returned,
        view.escrow().subsidy_reserved(),
        position_returned,
        sender,
        now_ms,
    );
}

// --- Settlement ---

/// Pay one record of the payout walk if it is Open: Predict's `try_pay_settled`
/// sends its settled payout (zero for a loser) to the receipt's receive address
/// and consumes the receipt, and the record is marked Closed with
/// `OpenRecordSettled`. Deleted IDs and other statuses are skipped. A record the
/// market cannot pay keeps its receipt and stays Open with
/// `OpenRecordPayoutSkipped` for a later upgrade to pay, and the walk moves on.
fun pay_open_record(
    queue: &mut MarketQueue,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    record_id: u64,
    now_ms: u64,
) {
    let view = queue.book.view(record_id);
    if (view.is_none() || view.borrow().status() != order_queue::status_open()) return;
    let view = view.destroy_some();
    let order_id = view.position().order_id();
    let receipt = queue.book.take_open_receipt(record_id);
    let (payout, kept) = market.try_pay_settled(config, receipt);
    if (kept.is_some()) {
        queue.book.restore_receipt(record_id, kept.destroy_some());
        queue_events::emit_open_record_payout_skipped(
            queue.expiry_market_id,
            record_id,
            view.account_id(),
            order_id,
            payout,
            now_ms,
        );
        return
    };
    kept.destroy_none();
    queue.book.finish_payout(record_id);
    queue_events::emit_open_record_settled(
        queue.expiry_market_id,
        record_id,
        view.account_id(),
        order_id,
        payout,
        now_ms,
    );
}

// --- Shared ---

/// The desk floor, and this queue's desk and market.
fun assert_bound(queue: &MarketQueue, desk: &OrderDesk, market: &ExpiryMarket) {
    desk.assert_version();
    assert!(queue.desk_id == desk.id(), EWrongDesk);
    assert!(queue.expiry_market_id == market.id(), EWrongMarket);
}

fun assert_open(queue: &MarketQueue, record_id: u64) {
    let record = queue.book.view(record_id);
    assert!(
        record.is_some() && record.borrow().status() == order_queue::status_open(),
        ERecordNotOpen,
    );
}

/// `(market cash, required cash, waiting cash need)` after a transition, for
/// the queue events.
fun cash_figures(market: &ExpiryMarket): (u64, u64, u64) {
    let (waiting_cash_need, _, _) = market.order_flow_state();
    (market.cash_balance(), market.required_cash(), waiting_cash_need)
}

/// Send `funds` to `recipient` through its address balance, or drop them when
/// empty.
fun send_or_destroy(funds: Balance<USDC>, recipient: address) {
    if (funds.value() == 0) {
        funds.destroy_zero();
        return
    };
    balance::send_funds(funds, recipient);
}

// === Test-Only Functions ===

#[test_only]
public fun new_test_update(
    channel: u8,
    envelope_us: u64,
    feed_ids: vector<u32>,
    prices: vector<Option<LazerPrice>>,
): TestUpdate {
    TestUpdate { channel, envelope_us, feed_ids, prices }
}

#[test_only]
/// `commit` over `TestUpdate`s. A feed the update does not carry aborts, as
/// `lazer_price::from_update` does.
public fun commit_for_testing(
    queue: &mut MarketQueue,
    market: &mut ExpiryMarket,
    desk: &OrderDesk,
    config: &ProtocolConfig,
    updates: vector<TestUpdate>,
    clock: &Clock,
    ctx: &TxContext,
) {
    let channels = updates.map_ref!(|update| update.channel);
    let envelopes_us = updates.map_ref!(|update| update.envelope_us);
    commit_updates!(
        queue,
        market,
        desk,
        config,
        &channels,
        &envelopes_us,
        |index, feed_id| {
            let update = &updates[index];
            update.prices[update.feed_ids.find_index!(|id| *id == feed_id).destroy_some()]
        },
        clock,
        ctx.sender(),
    );
}
