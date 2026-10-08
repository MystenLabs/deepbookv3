// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Per-expiry Predict market.
///
/// An ExpiryMarket is the hot shared object for one expiry. It owns trade
/// execution, strike exposure state, and an embedded expiry-cash custody
/// component, plus local sponsor-funded fee incentives. Live oracle validation is
/// delegated to `pricing::load_live_pricer`; this module owns market flow policy
/// and then passes loaded `Pricer` snapshots into exposure business logic.
/// Pool-wide PLP accounting and profit accounting remain outside this module.
///
/// It also owns the delayed-execution flows over the market's `OrderBook` (a
/// dynamic field created by the first queued order): queued placement, commit of
/// signed Pyth Lazer prices, resolve at the committed tick, refunds, cleanup, and
/// the settlement refund and payout phases. A queued fill never enters the
/// account: it stays an Open record until `enqueue_redeem_open` sells it or
/// `try_settle` pays it. `order_queue` owns the book's state and records; this
/// module owns the flow gates, the pricing, and every queue event.
module deepbook_predict::expiry_market;

use account::{account::{Account, AccountWrapper, Auth}, account_registry::AccountRegistry};
use deepbook_predict::{
    admin::AdminCap,
    config_events,
    constants,
    ewma::{Self, EwmaState},
    expiry_cash::{Self, ExpiryCash},
    order,
    order_events,
    order_queue::{Self, OrderBook, QueuedOrder},
    predict_account,
    pricing::{Self, Pricer, FrozenPricer, RangePrice},
    protocol_config::ProtocolConfig,
    range_codec,
    strike_exposure::{Self, LiveCloseTerms, MintRange, MintTerms, StrikeExposure},
    strike_exposure_config
};
use fixed_math::math;
use propbook::{
    block_scholes_store::{BlockScholesSVIStore, BlockScholesValueStore},
    pyth_feed::PythFeed,
    registry::OracleRegistry
};
use pyth_lazer::{i16::I16 as LazerI16, i64::I64 as LazerI64};
use sui::{
    accumulator::AccumulatorRoot,
    balance::{Self, Balance},
    clock::Clock,
    coin::Coin,
    dynamic_field as df,
    vec_map
};
use usdc::usdc::USDC;

use fun df::add as UID.add;
use fun df::borrow as UID.borrow;
use fun df::borrow_mut as UID.borrow_mut;
use fun df::exists as UID.exists_;

const EMintPaused: u64 = 0;
const EMarketNotSettled: u64 = 1;
#[allow(unused_const)]
const EMintCostAboveMax: u64 = 2;
#[allow(unused_const)]
const EMintProbabilityAboveMax: u64 = 3;
const EWrongPricer: u64 = 4;
const EReferenceTickObservationMissing: u64 = 5;
#[allow(unused_const)]
const EMintRedeemSameTimestamp: u64 = 6;
#[allow(unused_const)]
const ERedeemProbabilityBelowMin: u64 = 7;
#[allow(unused_const)]
const ERedeemProceedsBelowMin: u64 = 8;
const EMintCostCapRequired: u64 = 9;
const EMarketNotPendingValuation: u64 = 10;
#[allow(unused_const)]
const EMintCostAboveMaxPayout: u64 = 11;
const ENotSettledRedeemKeeper: u64 = 12;
const EDelayedExecutionRequired: u64 = 13;
const EQueueStuck: u64 = 14;
const EQueueFull: u64 = 15;
const EAccountOrderCap: u64 = 16;
const EPastCutoff: u64 = 17;
const EFeeNotCovered: u64 = 18;
const EOrderFailsLimits: u64 = 19;
const EInsufficientMarketCash: u64 = 20;
const EBelowMinSell: u64 = 21;
const ERecordNotOpen: u64 = 22;
const ENotRecordOwner: u64 = 23;
const EGenerationAfterEnvelope: u64 = 24;
const EPythFeedMissing: u64 = 25;
const EPythPropertyNotRequested: u64 = 26;
const EUpdateDoesNotMatchQueue: u64 = 27;

/// Per-expiry market state.
public struct ExpiryMarket has key {
    id: UID,
    /// Propbook underlying this market was created for.
    propbook_underlying_id: u32,
    expiry: u64,
    /// USDC custody and payout backing.
    cash: ExpiryCash,
    /// Sponsor-funded USDC available to subsidize this market's taker fees.
    fee_incentive_balance: Balance<USDC>,
    /// Exposure lifecycle state for this expiry's strike ticks.
    strike_exposure: StrikeExposure,
    /// Smoothed gas-price stats backing the congestion trade penalty.
    ewma: EwmaState,
    /// When true, new mints on this expiry abort. Other flows stay available.
    /// Admin sets/unsets it (version-gated); a `PauseCap` holder can force it
    /// true one-way through the registry (ungated kill switch).
    mint_paused: bool,
    /// `Some` from the flush's snapshot stage until this market's `value_expiry`
    /// (or lazily discarded once the stamp goes stale — see `ValuationStamp`).
    /// Trading is never gated on it and never touches it: the cash rows are
    /// captured eagerly here at the snapshot instant, and the payout tree
    /// captures its own boundary shadows as trades first touch each node.
    valuation_stamp: Option<ValuationStamp>,
}

/// One flush's snapshot stamp: the cash rows NAV reads, captured eagerly at the
/// snapshot instant (the book side lives in the payout tree's own snapshot,
/// activated with this stamp). Current only while `flush_seq`'s flush is in
/// flight; a stale stamp is lazily discarded by the next trade, so abort never
/// visits stamped markets.
public struct ValuationStamp has drop, store {
    flush_seq: u64,
    /// `cash.balance()` at the snapshot instant.
    snapshot_cash: u64,
    /// `cash.inventory_impact_reserve()` at the snapshot instant.
    snapshot_impact_reserve: u64,
}

/// Read-only all-in cost quote for a prospective live mint, in USDC base units.
/// `quantity` is the exact requested quantity, the premium-budget fill, or the
/// all-in-budget fill. `trading_fee` is the trading fee before the sponsor subsidy, and
/// `all_in_cost` is the resulting account withdrawal:
/// `premium + (trading_fee - fee_incentive_subsidy) + builder_fee + penalty_fee
/// + inventory_impact_charge`. Inventory impact is isolated from every ordinary
/// fee policy because it is escrowed for risk-reducing live closes. Quote
/// construction aborts when `all_in_cost` exceeds `quantity`, the position's
/// maximum settlement payout.
public struct MintQuote has copy, drop {
    quantity: u64,
    entry_probability: u64,
    premium: u64,
    trading_fee: u64,
    fee_incentive_subsidy: u64,
    builder_fee: u64,
    penalty_fee: u64,
    inventory_impact_charge: u64,
    all_in_cost: u64,
}

/// Read-only quote for a prospective early sell, in USDC base units, for SDK
/// slippage sizing. `proceeds` is what the trader would receive before the order
/// fee: `redeem value + inventory_impact_rebate - trading_fee - builder_fee`.
/// Queued sells pay no congestion penalty, so the quote carries none.
public struct RedeemQuote has copy, drop {
    close_quantity: u64,
    probability: u64,
    proceeds: u64,
    trading_fee: u64,
    builder_fee: u64,
    inventory_impact_rebate: u64,
}

/// One verified Pyth Lazer update, decoded to the fields commit reads. `commit`
/// maps every `pyth_lazer::update::Update` through `decode_update` and hands the
/// result to `commit_decoded`, which holds every matching rule. Lazer's `Option`
/// layers are kept as they are: an outer `none` means the property was not
/// requested, an inner `none` means it was requested but empty.
public struct LazerTick has copy, drop {
    /// `update.timestamp()`, in µs.
    envelope_us: u64,
    /// Lazer channel id: `2` is `fixed_rate@50ms`, `3` is `fixed_rate@200ms`.
    channel: u8,
    feeds: vector<LazerTickFeed>,
}

/// One feed of a `LazerTick`, in Lazer's own types.
public struct LazerTickFeed has copy, drop {
    feed_id: u32,
    price: Option<Option<LazerI64>>,
    exponent: Option<LazerI16>,
    /// The feed's own update time, in µs.
    feed_update_timestamp_us: Option<Option<u64>>,
}

// === Public Functions ===

/// Return the market object ID for external discovery and PTB construction.
public fun id(market: &ExpiryMarket): ID {
    market.id.to_inner()
}

/// Return the Propbook underlying for SDK and devInspect market reads.
public fun propbook_underlying_id(market: &ExpiryMarket): u32 {
    market.propbook_underlying_id
}

/// Return the expiry timestamp for SDK and devInspect market reads.
public fun expiry(market: &ExpiryMarket): u64 {
    market.expiry
}

/// Return the recorded settlement price. Aborts if the market is not settled.
public fun settlement_price(market: &ExpiryMarket): u64 {
    market.strike_exposure.settlement_price()
}

/// Return whether terminal settlement has been recorded for this market.
/// Public read for SDK/devInspect settlement-state checks.
public fun is_settled(market: &ExpiryMarket): bool {
    market.strike_exposure.is_settled()
}

/// Return the recorded settlement price, or `none` while the market is live.
/// Non-aborting companion to `settlement_price` for SDK/devInspect reads.
public fun try_settlement_price(market: &ExpiryMarket): Option<u64> {
    market.strike_exposure.try_settlement_price()
}

/// Return expiry USDC custody for SDK and devInspect state reads.
public fun cash_balance(market: &ExpiryMarket): u64 {
    market.cash.balance()
}

/// Return the isolated inventory-impact escrow for SDK and devInspect state
/// reads.
public fun inventory_impact_reserve(market: &ExpiryMarket): u64 {
    market.cash.inventory_impact_reserve()
}

/// Return local fee incentives for SDK and devInspect state reads.
public fun fee_incentive_balance(market: &ExpiryMarket): u64 {
    market.fee_incentive_balance.value()
}

/// Return the snapshotted backing-buffer lambda for SDK and devInspect reads.
public fun backing_buffer_lambda(market: &ExpiryMarket): u64 {
    market.strike_exposure.backing_buffer_lambda()
}

/// Return the snapshotted fee-ramp window for SDK and devInspect reads.
public fun expiry_fee_window_ms(market: &ExpiryMarket): u64 {
    market.strike_exposure.expiry_fee_window_ms()
}

/// Return the snapshotted fee-ramp multiplier for SDK and devInspect reads.
public fun expiry_fee_max_multiplier(market: &ExpiryMarket): u64 {
    market.strike_exposure.expiry_fee_max_multiplier()
}

/// Return this market's immutable maximum marginal inventory-impact rate for SDK
/// and devInspect state reads.
public fun inventory_impact_max_rate(market: &ExpiryMarket): u64 {
    market.strike_exposure.inventory_impact_max_rate()
}

/// Return the immutable USDC scale of this market's inventory-impact curve for
/// SDK and devInspect state reads.
public fun inventory_impact_scale(market: &ExpiryMarket): u64 {
    market.strike_exposure.inventory_impact_scale()
}

/// Return the strike tick size for SDK and devInspect range construction. Raw
/// strikes are `tick * tick_size`.
public fun tick_size(market: &ExpiryMarket): u64 {
    market.strike_exposure.tick_size()
}

/// Return the admission-grid step for SDK and devInspect range construction.
public fun admission_tick_size(market: &ExpiryMarket): u64 {
    market.strike_exposure.admission_tick_size()
}

/// Return the admitted reference tick for SDK and devInspect range construction.
public fun reference_tick(market: &ExpiryMarket): Option<u64> {
    market.strike_exposure.reference_tick()
}

/// Return the reference observation timestamp for SDK and devInspect reads.
public fun reference_tick_source_timestamp_ms(market: &ExpiryMarket): u64 {
    market.strike_exposure.reference_tick_source_timestamp_ms()
}

/// Return payout reserve or settled liability for external accounting observability.
public fun payout_liability(market: &ExpiryMarket): u64 {
    market.strike_exposure.payout_liability()
}

/// Return required expiry cash for external accounting observability.
public fun required_cash(market: &ExpiryMarket): u64 {
    market.cash.required_cash(market.payout_liability())
}

/// Load a PTB-local live pricing snapshot for this market.
///
/// The returned `Pricer` is bound to `market.id()` and can be passed into live
/// mint, redeem, and NAV functions in the same transaction.
///
/// Aborts `pricing::EOracleWrittenInThisTransaction` when any observation that
/// feeds the returned forward or SVI was written in this transaction (RP-24).
/// Independently submitted refresh-then-trade PTBs are unaffected: the guard
/// compares observation `writer_digest` to `tx_context::digest()`, not sender
/// identity, and does not prohibit reads of older observations.
public fun load_live_pricer(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    clock: &Clock,
    ctx: &TxContext,
): Pricer {
    pricing::load_live_pricer(
        config.pricing_config(),
        propbook_registry,
        pyth,
        bs_values,
        bs_svi,
        market.id(),
        market.propbook_underlying_id,
        market.expiry,
        clock,
        ctx,
    )
}

/// Return whether this market is snapshotted into the in-flight flush and still
/// awaiting its `value_expiry`. For SDK, keeper, and devInspect reads. It gates
/// nothing: settlement and trading both run regardless — the frozen mark is
/// settlement-invariant, so a stamped market settles the instant it expires. Do
/// not defer a settlement attempt on this read.
public fun is_pending_valuation(market: &ExpiryMarket, config: &ProtocolConfig): bool {
    market.valuation_stamp.is_some()
        && config.is_current_flush(market.valuation_stamp.borrow().flush_seq)
}

/// Return live marked NAV as free expiry cash minus the exposure book's marked
/// liability, floored at zero. This read requires a market-bound pre-expiry
/// `Pricer`; an expired but unsettled market cannot be valued through this path.
/// Public for PTB composition and devInspect pool valuation.
public fun current_nav(market: &ExpiryMarket, pricer: &Pricer): u64 {
    market.assert_pricer_bound(pricer);
    let liability = market.strike_exposure.live_marked_liability(pricer);
    // Marked liability and free cash are computed through different rounded
    // aggregates; negative marked NAV is represented as zero.
    market.cash.free_cash().saturating_sub(liability)
}

/// Retired with instant trading: always aborts `EDelayedExecutionRequired`.
/// Queue records are priced through `quote_redeem_open`.
public fun live_order_value(_market: &ExpiryMarket, _pricer: &Pricer, _order_id: u256): u64 {
    abort EDelayedExecutionRequired
}

/// Return one settled order's terminal payout. This function does not prove
/// account ownership of `order_id`. Public for SDK, PTB, and devInspect position
/// valuation.
public fun settled_order_payout(market: &ExpiryMarket, order_id: u256): u64 {
    assert!(market.is_settled(), EMarketNotSettled);
    let order = order::from_order_id(order_id);
    market.strike_exposure.settled_order_payout(&order)
}

/// Return the market mint-pause state for SDK and devInspect reads.
public fun mint_paused(market: &ExpiryMarket): bool {
    market.mint_paused
}

/// Retired with instant trading: always aborts `EDelayedExecutionRequired`.
public fun quote_mint(
    _market: &ExpiryMarket,
    _config: &ProtocolConfig,
    _pricer: &Pricer,
    _lower_tick: u64,
    _higher_tick: u64,
    _max_premium: u64,
    _min_quantity: u64,
    _exact_quantity: bool,
    _clock: &Clock,
    _ctx: &mut TxContext,
): MintQuote {
    abort EDelayedExecutionRequired
}

/// Retired with instant trading: always aborts `EDelayedExecutionRequired`.
public fun quote_mint_for_account(
    _market: &ExpiryMarket,
    _wrapper: &AccountWrapper,
    _config: &ProtocolConfig,
    _pricer: &Pricer,
    _lower_tick: u64,
    _higher_tick: u64,
    _max_premium: u64,
    _min_quantity: u64,
    _exact_quantity: bool,
    _root: &AccumulatorRoot,
    _clock: &Clock,
    _ctx: &mut TxContext,
): MintQuote {
    abort EDelayedExecutionRequired
}

/// Retired with instant trading: always aborts `EDelayedExecutionRequired`.
public fun quote_mint_exact_cost_for_account(
    _market: &ExpiryMarket,
    _wrapper: &AccountWrapper,
    _config: &ProtocolConfig,
    _pricer: &Pricer,
    _lower_tick: u64,
    _higher_tick: u64,
    _max_cost: u64,
    _min_quantity: u64,
    _root: &AccumulatorRoot,
    _clock: &Clock,
    _ctx: &mut TxContext,
): MintQuote {
    abort EDelayedExecutionRequired
}

// === Delayed Execution: Queue Reads ===
// Shared (S0). For the SDK, the keeper, and devInspect. A market without an
// `OrderBook` reads as an empty queue.

/// Return one queue record, or `none` for a missing or deleted record ID.
public fun queued_order(market: &ExpiryMarket, record_id: u64): Option<QueuedOrder> {
    if (!market.has_order_book()) return option::none();
    market.order_book().try_order(record_id)
}

/// Return `(resolve_head, next_id, last_tau_ms, last_committed_tau_ms)`.
/// `resolve_head` is a lower bound on the first unfinished record.
public fun queue_heads(market: &ExpiryMarket): (u64, u64, u64, u64) {
    if (!market.has_order_book()) return (0, 0, 0, 0);
    let book = market.order_book();
    (book.resolve_head(), book.next_id(), book.last_tau_ms(), book.last_committed_tau_ms())
}

/// Return `(payout_cursor, next_id)`. The settlement payout walk is finished once
/// the two are equal.
public fun payout_progress(market: &ExpiryMarket): (u64, u64) {
    if (!market.has_order_book()) return (0, 0);
    let book = market.order_book();
    (book.payout_cursor(), book.next_id())
}

/// Return `(cohort count, oldest uncommitted τ, oldest uncommitted τ above
/// last_committed_tau_ms)`. The third value is the cohort the stuck gate's first
/// rule watches.
public fun waiting_cohorts(market: &ExpiryMarket): (u64, Option<u64>, Option<u64>) {
    if (!market.has_order_book()) return (0, option::none(), option::none());
    let book = market.order_book();
    (
        book.cohort_count(),
        book.oldest_uncommitted_tau(),
        book.oldest_uncommitted_tau_above_committed(),
    )
}

/// Whether enqueue would refuse a new order as stuck right now (both rules of
/// the stuck gate). Drives the app's "pricing delayed" banner. Aborts
/// `protocol_config::EPolicyNotInitialized` for a market with a queue before the
/// policy exists.
public fun queue_stuck(market: &ExpiryMarket, config: &ProtocolConfig, clock: &Clock): bool {
    if (!market.has_order_book()) return false;
    market.order_book().is_stuck(config.policy().stuck_threshold_ms(), clock.timestamp_ms())
}

/// Return `(pending_mints, pending_sells)`, the unfinished orders counted against
/// the policy capacities.
public fun pending_counts(market: &ExpiryMarket): (u64, u64) {
    if (!market.has_order_book()) return (0, 0);
    let book = market.order_book();
    (book.pending_mints(), book.pending_sells())
}

/// Return the unfinished queued orders `account_id` holds in this market.
public fun waiting_orders(market: &ExpiryMarket, account_id: ID): u64 {
    if (!market.has_order_book()) return 0;
    market.order_book().account_waiting(account_id)
}

/// Return τ of the oldest cohort with an unfinished order, for monitoring.
public fun oldest_unfinished_tau_ms(market: &ExpiryMarket): Option<u64> {
    if (!market.has_order_book()) return option::none();
    market.order_book().oldest_unfinished_tau()
}

/// Return market cash above required cash: the largest cash need a new queued
/// mint may have right now. Cash backing keeps cash at or above required cash.
public fun spare_cash(market: &ExpiryMarket): u64 {
    market.cash.balance() - market.required_cash()
}

/// Return the summed cash need of the market's unfinished queued orders.
/// `rebalance_expiry_cash` keeps a live market at required cash plus this.
public fun waiting_cash_need(market: &ExpiryMarket): u64 {
    if (!market.has_order_book()) return 0;
    market.order_book().waiting_cash_need()
}

/// Return the payout tree's node count, pinned zero nodes included. The keeper
/// sizes its resolve batches from it.
public fun payout_tree_node_count(market: &ExpiryMarket): u64 {
    market.strike_exposure.payout_node_count()
}

/// Return the market's snapshotted minimum entry probability. The SDK computes a
/// queued mint's cash need from it.
public fun min_entry_probability(market: &ExpiryMarket): u64 {
    market.strike_exposure.min_entry_probability()
}

// ===== region E2-public (reads): early-sell quote (owner: E2) =====

/// Quote an early sell of `close_quantity` from the Open record `record_id` at a
/// live `Pricer`, with the wrapper account's builder code. Prices the close the
/// way a queued sell fills, with the trading fee at the clock instead of a
/// committed tick. `proceeds` is before the order fee. Changes nothing. It has
/// no version, freeze, trade-window, or Pyth-freshness gate, only the pricer
/// binding (`EWrongPricer`). Aborts `ERecordNotOpen` for a missing or non-Open
/// record, and otherwise like the live close math. Does not check that the
/// account owns the record. Public for SDK and devInspect pricing before
/// `enqueue_redeem_open`.
public fun quote_redeem_open(
    market: &ExpiryMarket,
    wrapper: &AccountWrapper,
    _config: &ProtocolConfig,
    pricer: &Pricer,
    record_id: u64,
    close_quantity: u64,
    clock: &Clock,
): RedeemQuote {
    market.assert_pricer_bound(pricer);
    let record = market.queued_order(record_id);
    assert!(
        record.is_some() && record.borrow().status() == order_queue::status_open(),
        ERecordNotOpen,
    );
    let order = order::from_order_id(record.destroy_some().position().order_id());
    let terms = market.strike_exposure.quote_live_close(pricer, &order, close_quantity);
    let builder_code_id = predict_account::builder_code_id(wrapper.load_account());
    market.redeem_quote_at_tick(&terms, &builder_code_id, close_quantity, clock.timestamp_ms())
}

// ===== end region E2-public (reads) =====

// === MintQuote Getters ===

/// Return the sized quantity for SDK and devInspect quote consumers.
public fun quantity(quote: &MintQuote): u64 {
    quote.quantity
}

/// Return the quoted range probability for SDK and devInspect consumers.
public fun entry_probability(quote: &MintQuote): u64 {
    quote.entry_probability
}

/// Return the quoted premium for SDK and devInspect consumers.
public fun premium(quote: &MintQuote): u64 {
    quote.premium
}

/// Return the quoted trading fee before subsidy for SDK and devInspect consumers.
public fun trading_fee(quote: &MintQuote): u64 {
    quote.trading_fee
}

/// Return the sponsor-funded portion of the quoted fee for SDK and devInspect consumers.
public fun fee_incentive_subsidy(quote: &MintQuote): u64 {
    quote.fee_incentive_subsidy
}

/// Return the quoted builder fee for SDK and devInspect consumers.
public fun builder_fee(quote: &MintQuote): u64 {
    quote.builder_fee
}

/// Return the quoted EWMA congestion surcharge for SDK and devInspect consumers.
public fun penalty_fee(quote: &MintQuote): u64 {
    quote.penalty_fee
}

/// Return the separate inventory-impact charge for SDK and devInspect quote
/// consumers.
public fun inventory_impact_charge(quote: &MintQuote): u64 {
    quote.inventory_impact_charge
}

/// Return the total quoted account withdrawal for SDK and devInspect consumers.
public fun all_in_cost(quote: &MintQuote): u64 {
    quote.all_in_cost
}

// === RedeemQuote Getters ===
// Public for SDK and devInspect quote consumers; prefixed so they do not clash
// with the `MintQuote` getters.

public fun redeem_close_quantity(quote: &RedeemQuote): u64 {
    quote.close_quantity
}

public fun redeem_probability(quote: &RedeemQuote): u64 {
    quote.probability
}

public fun redeem_proceeds(quote: &RedeemQuote): u64 {
    quote.proceeds
}

public fun redeem_trading_fee(quote: &RedeemQuote): u64 {
    quote.trading_fee
}

public fun redeem_builder_fee(quote: &RedeemQuote): u64 {
    quote.builder_fee
}

public fun redeem_inventory_impact_rebate(quote: &RedeemQuote): u64 {
    quote.inventory_impact_rebate
}

/// Retired by delayed execution: always aborts `EDelayedExecutionRequired`.
/// Use `enqueue_exact_quantity`.
public fun mint_exact_quantity(
    _market: &mut ExpiryMarket,
    _wrapper: &mut AccountWrapper,
    _auth: Auth,
    _config: &ProtocolConfig,
    _pricer: &Pricer,
    _lower_tick: u64,
    _higher_tick: u64,
    _quantity: u64,
    _max_cost: u64,
    _max_probability: u64,
    _root: &AccumulatorRoot,
    _clock: &Clock,
    _ctx: &mut TxContext,
): u256 {
    abort EDelayedExecutionRequired
}

/// Retired by delayed execution: always aborts `EDelayedExecutionRequired`.
/// Use `enqueue_exact_amount`.
public fun mint_exact_amount(
    _market: &mut ExpiryMarket,
    _wrapper: &mut AccountWrapper,
    _auth: Auth,
    _config: &ProtocolConfig,
    _pricer: &Pricer,
    _lower_tick: u64,
    _higher_tick: u64,
    _max_premium: u64,
    _min_quantity: u64,
    _max_cost: u64,
    _root: &AccumulatorRoot,
    _clock: &Clock,
    _ctx: &mut TxContext,
): u256 {
    abort EDelayedExecutionRequired
}

/// Retired by delayed execution: always aborts `EDelayedExecutionRequired`.
/// Use `enqueue_exact_cost`.
public fun mint_exact_cost(
    _market: &mut ExpiryMarket,
    _wrapper: &mut AccountWrapper,
    _auth: Auth,
    _config: &ProtocolConfig,
    _pricer: &Pricer,
    _lower_tick: u64,
    _higher_tick: u64,
    _max_cost: u64,
    _min_quantity: u64,
    _root: &AccumulatorRoot,
    _clock: &Clock,
    _ctx: &mut TxContext,
): u256 {
    abort EDelayedExecutionRequired
}

/// Retired by delayed execution: always aborts `EDelayedExecutionRequired`.
/// Early sells go through `enqueue_redeem_open`; account-held positions exit
/// through `redeem_settled` after settlement.
public fun redeem_live(
    _market: &mut ExpiryMarket,
    _wrapper: &mut AccountWrapper,
    _auth: Auth,
    _config: &ProtocolConfig,
    _pricer: &Pricer,
    _order_id: u256,
    _close_quantity: u64,
    _min_probability: u64,
    _min_proceeds: u64,
    _root: &AccumulatorRoot,
    _clock: &Clock,
    _ctx: &mut TxContext,
): Option<u256> {
    abort EDelayedExecutionRequired
}

/// Redeem a settled order you hold account authority over.
///
/// The market must be settled already; this flow does not run live pricing.
/// Explicit owner auth remains available when Predict app automation is deauthorized;
/// another authorized app may also supply valid account auth.
public fun redeem_settled(
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    order_id: u256,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    market.assert_settled_flow_allowed(config);
    market.redeem_settled_with_auth(
        wrapper,
        auth,
        order_id,
        root,
        clock,
        ctx,
    )
}

/// Redeem a settled order without account-owner authority, as an allowlisted keeper.
///
/// Despite the name, only a sender admin has added through
/// `protocol_config::add_settled_redeem_keeper` may call this; the allowlist
/// starts empty. The payout still goes to the order's account. This keeper path
/// uses Predict app-auth from the account registry, so
/// `deauthorize_app<PredictApp>` also disables it. Owners can still use
/// `redeem_settled` with owner auth to redeem their own settled positions.
public fun redeem_settled_permissionless(
    market: &mut ExpiryMarket,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    config: &ProtocolConfig,
    order_id: u256,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    market.assert_settled_flow_allowed(config);
    assert!(config.is_settled_redeem_keeper(ctx.sender()), ENotSettledRedeemKeeper);
    let auth = predict_account::generate_auth_as_app(account_registry);
    market.redeem_settled_with_auth(
        wrapper,
        auth,
        order_id,
        root,
        clock,
        ctx,
    )
}

/// Set this expiry's reference fine-grid tick from the exact previous-window
/// Propbook Pyth observation. The source observation must be inserted into the
/// feed at `reference_tick_source_timestamp_ms` before this call, and the
/// normalized spot is floored to the market's `tick_size`. Not gated on the
/// valuation lock: the reference tick shapes mint admission only, and a mint it
/// admits mid-flush is invisible to the captured snapshot like any other.
public fun set_reference_tick(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    clock: &Clock,
): u64 {
    config.assert_version();

    let source_timestamp_ms = market.strike_exposure.reference_tick_source_timestamp_ms();
    let spot = pricing::load_exact_spot(
        propbook_registry,
        pyth,
        market.propbook_underlying_id,
        source_timestamp_ms,
    );
    assert!(spot.is_some(), EReferenceTickObservationMissing);

    let spot = spot.destroy_some();
    let tick_size = market.strike_exposure.tick_size();
    let tick = range_codec::grid_tick(spot, tick_size);
    if (market.strike_exposure.set_reference_tick(tick)) {
        config_events::emit_reference_tick_set(
            market.id(),
            market.propbook_underlying_id,
            source_timestamp_ms,
            spot,
            tick,
            clock.timestamp_ms(),
        );
    };
    tick
}

/// Set whether new mints are paused on this expiry market. Admin-only and
/// version-gated. A `PauseCap` holder can force-engage the pause one-way under a
/// version freeze via `registry::pause_expiry_market_mint_pause_cap`.
public fun set_mint_paused(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    _admin_cap: &AdminCap,
    paused: bool,
) {
    config.assert_version();
    market.mint_paused = paused;
    config_events::emit_expiry_market_mint_paused_updated(market.id(), paused);
}

/// Settle an expired market and pay its Open queue records, one phase per call.
/// Permissionless, and never aborts because of a queued order.
///
/// 1. Refund phase: while queued orders are still waiting, refund them (reason
///    5; a RefundDue order keeps its stored reason) visiting at most the
///    policy's `settle_refund_batch` records, refunded or not, and return false.
///    These refunds skip node pruning and report `sender` `@0x0`.
/// 2. Settle phase: settle from Propbook's exact positive Pyth spot at expiry, or
///    from the exact Block Scholes minute-boundary spot when Pyth remains
///    unavailable after the compiled grace period; missing or unusable
///    observations leave the market unsettled. Then close the queue and move any
///    leftover queue escrow into market cash (`QueueEscrowSwept`). This call pays
///    nothing.
/// 3. Payout phase: from the payout cursor, visit at most the policy's
///    `settle_payout_batch` records. Each Open record is paid its settled payout
///    from market cash (zero for a loser), marked Closed, and reported with
///    `OpenRecordSettled`. A record the market cannot pay stays Open with
///    `OpenRecordPayoutSkipped`. Other records and deleted IDs count as visited.
///
/// Before the policy exists the compiled default batch sizes apply. Emits
/// `MarketPayoutsCompleted` once: from the call that moves the payout cursor to
/// the last record, or from the settling call of a market without a queue.
/// Returns true once the market is settled and the payout walk is complete;
/// keepers stop on that event or `payout_progress`.
public fun try_settle(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    clock: &Clock,
): bool {
    config.assert_version();
    // Settlement is never blocked by a flush. A market snapshotted by the in-flight
    // flush carries a valuation stamp, but the frozen mark is settlement-invariant:
    // `value_expiry`/`snapshot_nav` read only the stamp's frozen cash rows, the frozen
    // pricer, and the payout tree's frozen shadow, none of which settlement mutates.
    // So a market settles the instant it reaches expiry — even mid-flush, before its
    // `value_expiry` — and the flush still folds its frozen pre-expiry mark. The
    // reconcile is ordinary first-entry housekeeping: it only clears a stamp left by a
    // superseded or ended flush, never a current one. The snapshot stage still refuses
    // to stamp an already expired-unsettled market, so settle-first is the resolution
    // there.
    market.reconcile_stale_valuation_stamp(config);
    let now = clock.timestamp_ms();
    if (market.is_settled()) return market.pay_open_records(config, now);
    if (now < market.expiry) return false;
    if (market.has_order_book() && market.order_book().oldest_unfinished_tau().is_some()) {
        // Every deadline is at least 5 s before expiry, so every waiting order is
        // due: walk all cohorts. No pruning keeps each refund at about two objects.
        let batch = config
            .delayed_execution_policy()
            .map!(|policy| policy.settle_refund_batch())
            .destroy_or!(deepbook_predict::config_constants::default_settle_refund_batch!());
        market.refund_walk(std::u64::max_value!(), batch, false, @0x0, now);
        return false
    };

    let pyth_spot = pricing::load_exact_spot(
        propbook_registry,
        pyth,
        market.propbook_underlying_id,
        market.expiry,
    );
    let (settlement_price, settlement_source) = if (pyth_spot.is_some()) {
        (pyth_spot.destroy_some(), constants::settlement_source_pyth!())
    } else {
        if (now - market.expiry < constants::settlement_fallback_grace_ms!()) return false;
        let block_scholes_spot = pricing::load_exact_block_scholes_spot(
            propbook_registry,
            bs_values,
            market.propbook_underlying_id,
            market.expiry,
        );
        if (block_scholes_spot.is_none()) return false;
        (block_scholes_spot.destroy_some(), constants::settlement_source_block_scholes!())
    };
    market.strike_exposure.record_settlement(settlement_price);
    // Live-close rebates are no longer reachable after settlement. Release the
    // residual inventory-impact escrow so the settled sweep returns it to LPs.
    market.cash.release_inventory_impact_reserve();
    config_events::emit_market_settled(
        market.id(),
        market.propbook_underlying_id,
        market.expiry,
        settlement_price,
        settlement_source,
        now,
    );
    market.close_queue_at_settlement(now)
}

// ===== region E1-public: queued placement (owner: E1) =====

/// Place a queued mint for an exact quantity, priced later at Pyth's signed
/// price for its τ. Replaces `mint_exact_quantity` once the cutover is reached.
/// `max_cost` caps the all-in withdrawal and is mandatory; `max_probability` caps
/// the entry probability at τ. Escrows the budget, `min(max_cost, quantity,
/// available - order_fee)`, and the order fee, and returns the new record ID.
///
/// Aborts, charging nothing, when a gate or check refuses the order: the version
/// and cutover gates, the trading and mint pauses, the snapshot stage, a stuck
/// or full queue (`EQueueStuck`, `EQueueFull`, `EAccountOrderCap`), τ at or past
/// the cutoff (`EPastCutoff`), the volatility snapshot, an unlimited or zero
/// `max_cost` (`EMintCostCapRequired`), a balance not above the order fee
/// (`EFeeNotCovered`), an order that already fails its own limits at t₀
/// (`EOrderFailsLimits`), or a cash need above the market's spare cash
/// (`EInsufficientMarketCash`).
public fun enqueue_exact_quantity(
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    auth: Auth,
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
    market.enqueue_mint(
        wrapper,
        auth,
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
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    auth: Auth,
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
    market.enqueue_mint(
        wrapper,
        auth,
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
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    auth: Auth,
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
    market.enqueue_mint(
        wrapper,
        auth,
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
/// (`ERecordNotOpen`, also for a missing ID). It is marked Closed and its whole
/// position moves into the new record until the sell fills or refunds.
/// `min_probability` and `min_proceeds` are the close-side floors at τ. Returns
/// the new record ID.
///
/// Open during the trading pause and a market mint pause. Escrows only the order
/// fee, so a balance equal to it is enough. Refuses a sell below
/// `min_sell_quantity` or one leaving a remainder below it (`EBelowMinSell`).
/// There is no spare-cash check: the keeper funds the market before τ, and
/// resolve refunds a sell the market still cannot cover.
public fun enqueue_redeem_open(
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    auth: Auth,
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
    let account_id = wrapper.load_account().account_id();
    let (policy, timing) = market.begin_enqueue(config, false, account_id, clock, ctx);
    // Status, not the record ID against `resolve_head`: records finish out of
    // order, so only the status says whether this one holds a position.
    let source = market.order_book().try_order(record_id);
    assert!(
        source.is_some() && source.borrow().status() == order_queue::status_open(),
        ERecordNotOpen,
    );
    let source = source.destroy_some();
    assert!(source.parties().account_id() == account_id, ENotRecordOwner);
    market.enqueue_sell(
        wrapper,
        auth,
        config,
        propbook_registry,
        pyth,
        bs_values,
        bs_svi,
        policy,
        timing,
        source.position().order_id(),
        record_id,
        close_quantity,
        min_probability,
        min_proceeds,
        root,
        clock,
        ctx,
    )
}

// ===== end region E1-public =====

// ===== region E2-public: commit and resolve (owner: E2) =====

/// Attach verified Pyth Lazer prices to the waiting cohorts whose τ they match.
/// Permissionless. Each update must come from the current Pyth Lazer package's
/// verifier earlier in the same PTB; their order in `updates` does not matter.
/// An update that matches no waiting cohort is skipped.
///
/// Uses Lazer's v1 `Update`, which Pyth marked deprecated on Mainnet but still
/// serves; v2 arrives with a later upgrade.
#[allow(deprecated_usage)]
public fun commit(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    updates: vector<pyth_lazer::update::Update>,
    clock: &Clock,
    ctx: &TxContext,
) {
    let ticks = updates.map_ref!(|update| decode_update(update));
    market.commit_decoded(config, ticks, clock, ctx.sender());
}

/// Fill or refund committed orders in τ order from the market's own cash,
/// visiting at most `max_orders` records. Permissionless. An order the market's
/// cash cannot cover is refunded with reason 8. Returns how many orders it
/// finished.
///
/// Walks the cohorts in τ order and loads only committed or overdue ones; a
/// cohort still waiting for its price is skipped without loading a record.
/// Every record visited counts against `max_orders`, finished or missing ones
/// included, so one call stays inside Sui's per-transaction object limit. An
/// order at or past its deadline is refunded (reason 5), never filled. Returns
/// 0 on a settled market, whose waiting orders `try_settle` refunds.
public fun resolve(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    max_orders: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    config.assert_version();
    config.policy();
    config.assert_snapshot_not_in_progress();
    market.reconcile_stale_valuation_stamp(config);
    if (market.is_settled() || !market.has_order_book()) return 0;

    let now_ms = clock.timestamp_ms();
    let sender = ctx.sender();
    // Sampled once for the whole walk.
    let referral_fee_rate = config.referral_fee_rate();
    // Spans are only dropped by `advance_heads` below, so indices stay stable.
    let cohort_count = market.order_book().cohort_count();
    let mut visited = 0;
    let mut finished = 0;
    let mut index = 0;
    while (index < cohort_count && visited < max_orders) {
        let span = market.order_book().cohort(index);
        let mut unfinished = span.span_unfinished();
        if (unfinished > 0 && (span.span_committed() || now_ms >= span.span_deadline_ms())) {
            let end_id = span.span_end_id();
            let mut record_id = span.span_first_id();
            while (unfinished > 0 && record_id < end_id && visited < max_orders) {
                visited = visited + 1;
                if (market.resolve_record(record_id, referral_fee_rate, sender, now_ms)) {
                    finished = finished + 1;
                    unfinished = unfinished - 1;
                };
                record_id = record_id + 1;
            };
            // Every record before `record_id` has finished, so a later walk can
            // start there without loading them again.
            if (unfinished > 0 && record_id < end_id) {
                market.order_book_mut().set_cohort_first_id(index, record_id);
            };
        };
        index = index + 1;
    };
    market.order_book_mut().advance_heads();
    finished
}

// ===== end region E2-public =====

// ===== region E3-public: refunds, cleanup (owner: E3) =====

/// Refund waiting orders at or past their deadline (reason 5), visiting at most
/// `max_orders` records, refunded or not. It walks the cohorts in τ order and
/// stops at the first one not yet due, since deadlines never decrease along the
/// queue. A RefundDue order keeps its stored reason. Permissionless, and
/// available under the emergency freeze. Returns how many orders it refunded:
/// `0`, without aborting, when none is due.
public fun refund(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    max_orders: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    config.assert_version_floor();
    if (!market.has_order_book()) return 0;
    let now_ms = clock.timestamp_ms();
    market.refund_walk(now_ms, max_orders, true, ctx.sender(), now_ms)
}

/// Refund the listed waiting orders at once (reason 7; a RefundDue order keeps
/// its stored reason), wherever they sit in the queue. Admin-only, and available
/// under the emergency freeze. Missing and finished IDs are skipped.
public fun admin_refund(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    _admin_cap: &AdminCap,
    record_ids: vector<u64>,
    clock: &Clock,
    ctx: &TxContext,
) {
    config.assert_version_floor();
    if (!market.has_order_book()) return;
    let now_ms = clock.timestamp_ms();
    let sender = ctx.sender();
    record_ids.do!(|record_id| {
        market.refund_record(record_id, order_queue::reason_admin(), true, sender, now_ms);
    });
    market.order_book_mut().advance_heads();
}

/// Delete Refunded and Closed records of a settled market. Permissionless; the
/// storage rebate goes to the caller. Missing IDs and other statuses are
/// skipped; `QueuedOrdersCleaned` is emitted only when a record was deleted.
/// Takes `&Clock` only to stamp the event.
public fun cleanup(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    record_ids: vector<u64>,
    clock: &Clock,
    _ctx: &TxContext,
) {
    config.assert_version_floor();
    assert!(market.is_settled(), EMarketNotSettled);
    if (!market.has_order_book()) return;
    let expiry_market_id = market.id();
    let book = market.order_book_mut();
    let mut cleaned = vector[];
    record_ids.do!(|record_id| {
        if (book.remove_finished_record(record_id)) cleaned.push_back(record_id);
    });
    if (cleaned.is_empty()) return;
    order_events::emit_queued_orders_cleaned(expiry_market_id, cleaned, clock.timestamp_ms());
}

// ===== end region E3-public =====

// === Public-Package Functions ===

/// Force `mint_paused = true` through the registry's `PauseCap` path. This cannot
/// unpause and does not apply the package-version gate.
public(package) fun pause_mint(market: &mut ExpiryMarket) {
    market.mint_paused = true;
    config_events::emit_expiry_market_mint_paused_updated(market.id(), true);
}

/// Receive pool-provided cash without interpreting pool allocation policy.
public(package) fun receive_pool_cash(market: &mut ExpiryMarket, cash: Balance<USDC>) {
    market.cash.receive(cash);
    market.assert_cash_backing();
}

/// Receive sponsor-funded fee incentives allocated by the pool vault.
public(package) fun receive_fee_incentives(market: &mut ExpiryMarket, incentives: Balance<USDC>) {
    market.fee_incentive_balance.join(incentives);
}

/// Stamp this market for the flush freezing it: capture the two cash rows (this
/// call IS the snapshot instant) and activate the tree snapshot. A surviving
/// stamp being replaced is stale by construction — `begin_valuation` bumped the
/// ordinal, and a current-flush double-stamp is rejected upstream.
public(package) fun stamp_for_valuation(market: &mut ExpiryMarket, flush_seq: u64) {
    market.valuation_stamp =
        option::some(ValuationStamp {
            flush_seq,
            snapshot_cash: market.cash.balance(),
            snapshot_impact_reserve: market.cash.inventory_impact_reserve(),
        });
    market.strike_exposure.activate_valuation_snapshot(flush_seq);
}

/// Retire the stamp once its valuation is folded, consuming the tree snapshot
/// with it (purging retained husks — this generation's or a stale one's). Later
/// trades are invisible to the folded figure: as-of-snapshot semantics.
public(package) fun clear_valuation_stamp(market: &mut ExpiryMarket) {
    market.valuation_stamp = option::none();
    // A husk a waiting order pins survives: its resolve fill inserts over it.
    // The book is borrowed through the UID so the exposure borrow stays disjoint.
    let no_pins = vec_map::empty<u64, u64>();
    let pins = if (market.has_order_book()) {
        let book: &OrderBook = market.id.borrow(order_queue::book_key());
        book.pins()
    } else {
        &no_pins
    };
    market.strike_exposure.release_valuation_snapshot(pins);
}

/// NAV at the flush's snapshot instant: `current_nav`'s exact shape over values
/// captured AT that instant — the stamp's cash copy predates every
/// post-snapshot mutation and the tree captures each node before its first, so
/// the zero floors are exact (backing keeps the pre-floor value above zero up
/// to P-13's rounding dust).
public(package) fun snapshot_nav(market: &ExpiryMarket, frozen: &FrozenPricer): u64 {
    // Thaw to a transient, non-`store` `Pricer` for the frozen walk; it cannot
    // outlive this transaction, so it can never reach a trade path.
    let pricer = frozen.thaw();
    market.assert_pricer_bound(&pricer);
    // Defensive, structurally unreachable: the only caller is `plp::value_expiry`
    // on a frozen-live market, which its own flush's snapshot stage stamped, and
    // the stamp cannot go stale while that flush is still in flight (unit-tests
    // rule 4: documented in lieu of a bypass test).
    assert!(market.valuation_stamp.is_some(), EMarketNotPendingValuation);
    let stamp = market.valuation_stamp.borrow();
    let snapshot_free_cash = stamp.snapshot_cash.saturating_sub(stamp.snapshot_impact_reserve);
    let liability = market.strike_exposure.frozen_marked_liability(&pricer, stamp.flush_seq);
    snapshot_free_cash.saturating_sub(liability)
}

/// Release all unused local fee incentives back to the pool reserve.
public(package) fun release_fee_incentives(market: &mut ExpiryMarket): Balance<USDC> {
    let amount = market.fee_incentive_balance.value();
    if (amount == 0) return balance::zero();
    market.fee_incentive_balance.split(amount)
}

/// Release pool cash while preserving expiry-local payout backing.
public(package) fun release_pool_cash(market: &mut ExpiryMarket, amount: u64): Balance<USDC> {
    if (amount == 0) {
        return balance::zero()
    };
    let payout_liability = market.payout_liability();
    let released_cash = market.cash.release_surplus(amount, payout_liability);
    market.assert_cash_backing();
    released_cash
}

/// Release settled cash above payout liability and the impact escrow.
public(package) fun release_settled_pool_cash(market: &mut ExpiryMarket): Balance<USDC> {
    let settled_liability = market.payout_liability();
    let reserved_cash = market.cash.required_cash(settled_liability);
    market.cash.assert_backing(settled_liability);

    let returned_cash_amount = market.cash.balance() - reserved_cash;
    market.release_pool_cash(returned_cash_amount)
}

/// Create and share a zero-cash expiry market for one Propbook underlying.
///
/// The market snapshots the underlying, accounting/admission tick sizes, and per-market config and
/// starts with zero expiry cash; it needs no live spot at creation (strikes are absolute ticks, so
/// there is no grid to center). Current oracle bindings stay in Propbook and are resolved on every
/// priced flow.
public(package) fun create_and_share(
    config: &ProtocolConfig,
    propbook_underlying_id: u32,
    expiry: u64,
    tick_size: u64,
    admission_tick_size: u64,
    reference_tick_source_timestamp_ms: u64,
    inventory_impact_scale: u64,
    ctx: &mut TxContext,
): ID {
    let id = object::new(ctx);
    let expiry_market_id = id.to_inner();
    let strike_exposure_config = config.strike_exposure_config_snapshot();
    let market = ExpiryMarket {
        id,
        propbook_underlying_id,
        expiry,
        cash: expiry_cash::new(),
        fee_incentive_balance: balance::zero(),
        strike_exposure: strike_exposure::new(
            expiry_market_id,
            strike_exposure_config,
            tick_size,
            admission_tick_size,
            reference_tick_source_timestamp_ms,
            inventory_impact_scale,
            ctx,
        ),
        ewma: ewma::new(ctx),
        mint_paused: false,
        valuation_stamp: option::none(),
    };
    transfer::share_object(market);
    expiry_market_id
}

// ===== region E-package: commit over decoded updates, test seams (owner: E2) =====

/// Commit's logic over decoded Lazer updates: every gate, the cohort matching,
/// and the per-cohort commit. `commit` decodes and delegates here; tests drive
/// it directly, because a real Lazer `Update` has no Move test constructor.
///
/// Two passes. The first reads only the inline cohort list and picks at most one
/// update per waiting cohort: the update stamped exactly its τ on its channel,
/// or else, once the price buffer is above zero and now is at least `gap_wait_ms`
/// past τ, the update stamped one tick of the cohort's own channel later. The
/// second commits each matched cohort whole or not at all, loading only matched
/// cohorts' records. A cohort at or past its deadline is never committed.
public(package) fun commit_decoded(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    ticks: vector<LazerTick>,
    clock: &Clock,
    sender: address,
) {
    config.assert_version();
    let policy = config.policy();
    let buffer_ms = policy.pyth_price_buffer_ms();
    let gap_wait_ms = policy.gap_wait_ms();
    // `try_settle` already refunded every waiting order.
    if (market.is_settled()) return;
    // Every comparison reads the envelope in ms, so a fractional one is malformed.
    ticks.do_ref!(|tick| assert!(tick.envelope_us % 1000 == 0, EUpdateDoesNotMatchQueue));
    if (!market.has_order_book()) return;

    let now_ms = clock.timestamp_ms();
    let mut cohort_indices = vector[];
    let mut tick_indices = vector[];
    let book = market.order_book();
    book.cohort_count().do!(|index| {
        let span = book.cohort(index);
        if (
            !span.span_committed() && span.span_unfinished() > 0 && now_ms < span.span_deadline_ms()
        ) {
            matching_tick_index(&ticks, &span, buffer_ms, gap_wait_ms, now_ms).do!(|tick_index| {
                cohort_indices.push_back(index);
                tick_indices.push_back(tick_index);
            });
        };
    });
    if (cohort_indices.is_empty()) return;

    // Sampled once: the rate is a dynamic-field read.
    let subsidy_rate = config.fee_incentive_subsidy_rate();
    cohort_indices.length().do!(|i| {
        market.commit_cohort(
            cohort_indices[i],
            &ticks[tick_indices[i]],
            subsidy_rate,
            sender,
            now_ms,
        );
    });
}

#[test_only]
public(package) fun new_lazer_tick_for_testing(
    envelope_us: u64,
    channel: u8,
    feeds: vector<LazerTickFeed>,
): LazerTick {
    LazerTick { envelope_us, channel, feeds }
}

#[test_only]
public(package) fun new_lazer_tick_feed_for_testing(
    feed_id: u32,
    price: Option<Option<LazerI64>>,
    exponent: Option<LazerI16>,
    feed_update_timestamp_us: Option<Option<u64>>,
): LazerTickFeed {
    LazerTickFeed { feed_id, price, exponent, feed_update_timestamp_us }
}

#[test_only]
/// The queue's escrow balance, for the escrow invariant in queue tests.
public(package) fun queue_escrow_for_testing(market: &ExpiryMarket): u64 {
    if (!market.has_order_book()) return 0;
    market.order_book().escrow_value()
}

#[test_only]
/// Non-production fixture: add USDC to the queue's escrow outside any order.
/// The only way to reach settlement's leftover-escrow sweep, which production
/// never reaches because escrow holds exactly the unfinished orders' funds.
public(package) fun add_queue_escrow_for_testing(market: &mut ExpiryMarket, funds: Balance<USDC>) {
    market.order_book_mut().deposit_escrow(funds);
}

#[test_only]
/// Non-production fixture: take USDC out of market cash with no liability
/// change. The only way to reach the payout walk's skip branch, which
/// production never reaches because backing keeps cash at or above the settled
/// liability.
public(package) fun take_market_cash_for_testing(
    market: &mut ExpiryMarket,
    amount: u64,
): Balance<USDC> {
    market.cash.pay_authorized(amount)
}

// ===== end region E-package =====

// === Private Functions ===

// --- Valuation stamp bookkeeping ---

/// Lazily discard a stale stamp (aborted or superseded flush), deactivating the
/// tree snapshot with it. Not walked here (trade path): a stale generation's
/// husks fall out at the next consumed snapshot.
fun reconcile_stale_valuation_stamp(market: &mut ExpiryMarket, config: &ProtocolConfig) {
    if (market.valuation_stamp.is_none()) return;
    let stamp_seq = market.valuation_stamp.borrow().flush_seq;
    if (!config.is_current_flush(stamp_seq)) {
        market.valuation_stamp = option::none();
        market.strike_exposure.deactivate_valuation_snapshot();
    };
}

// --- Gates: the first call of every public entry ---
#[test_only]
fun assert_live_mint_allowed(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    pricer: &Pricer,
    clock: &Clock,
) {
    market.assert_live_flow_allowed(config, pricer, clock);
    config.assert_trading_allowed();
    assert!(!market.mint_paused, EMintPaused);
}

// Trade flows are deliberately NOT gated on the whole-flush valuation lock: a
// snapshotted market's state is captured (stamp cash + tree shadows), so trades
// run unrecorded and unbudgeted while it awaits its `value_expiry`. They ARE
// blocked while the atomic snapshot stage is open (`assert_snapshot_not_in_progress`),
// so the keeper cannot compose a mint or redeem into its own snapshot PTB, where a
// mid-stamp cash move would skew the figures the seal freezes. That stage is one
// PTB, so this never blocks a trade in any other transaction.
#[test_only]
fun assert_live_flow_allowed(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    pricer: &Pricer,
    clock: &Clock,
) {
    config.assert_version();
    config.assert_snapshot_not_in_progress();
    market.assert_pricer_bound(pricer);
    // Shared by every live mint, quote, and live redeem, so the pre-expiry block
    // lands once here. Settlement and settled redemption take other paths and stay
    // open, so the window delays a close rather than stranding the position.
    config.assert_trade_window_open(market.expiry, clock);
    // A live trade, open or close, moves pool cash at the pricer's mark, so every
    // live flow (quotes included, so they refuse what their mint would) refuses the
    // Block Scholes-forward fallback a stale or unavailable Pyth spot selects: the
    // fallback would price the trade on the lower-frequency Block Scholes forward
    // and let it land on either side of the source switch. A gap in Pyth updates
    // therefore delays a live close as well as a mint; the position still exits
    // through settlement and `redeem_settled`. Valuation reads (`current_nav`,
    // `live_order_value`, the flush snapshot) do not pass through here and keep the
    // fallback, so the flush does not stall on a stale or unavailable Pyth spot,
    // and a client previewing a close through `live_order_value` gets a value
    // while the close itself aborts.
    pricer.assert_pyth_spot_fresh(config.pricing_config(), clock);
}

fun assert_settled_flow_allowed(market: &ExpiryMarket, config: &ProtocolConfig) {
    config.assert_version();
    config.assert_snapshot_not_in_progress();
    assert!(market.is_settled(), EMarketNotSettled);
}

fun assert_pricer_bound(market: &ExpiryMarket, pricer: &Pricer) {
    assert!(pricer.expiry_market_id() == market.id(), EWrongPricer);
}

// --- Mint flow ---
#[test_only]
fun mint_prepared(
    market: &mut ExpiryMarket,
    account: &mut Account,
    config: &ProtocolConfig,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    max_premium: u64,
    min_quantity: u64,
    exact_quantity: bool,
    max_cost: u64,
    max_probability: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    market.reconcile_stale_valuation_stamp(config);
    let terms = market
        .strike_exposure
        .quote_mint_terms(
            pricer,
            lower_tick,
            higher_tick,
            max_premium,
            min_quantity,
            exact_quantity,
        );
    assert!(terms.entry_probability() <= max_probability, EMintProbabilityAboveMax);
    let builder_code_id = predict_account::builder_code_id(account);
    market.mint_with_terms(account, config, pricer, terms, builder_code_id, max_cost, clock, ctx)
}

/// Size the largest lot-rounded quantity whose all-in cost fits `max_cost`, step
/// down if that fill would cost more than it could ever pay out, then admit it.
///
/// The budget search is exact. Every all-in term is nondecreasing in quantity
/// while the pre-trade price, fee incentives, EWMA state, and book are fixed:
/// premium and each fee leg are `mul_down` of a quantity-independent rate; the
/// trader-paid fee is
/// `fee - min(mul_down(fee, fee_incentive_subsidy_rate), incentives)`, whose
/// subsidy grows at most one unit per fee unit because the configured rate is
/// capped below one; the builder fee is a `min` of
/// nondecreasing terms; the penalty's firing condition is quantity-independent;
/// and the impact charge is monotone (`mint_range_inventory_impact`). The probe
/// is the helper the charge uses, and the premium-only fit bounds the domain from
/// above because every other term is nonnegative.
///
/// The maximum-payout bound (`all_in_cost <= quantity`) is deliberately NOT part
/// of that search. It is not monotone in quantity: cost and quantity both rise,
/// and the independent floors in each cost term let `cost(q) <= q` flip from
/// false back to true at a larger lot wherever unit cost sits within rounding of
/// one. A binary search over it would discard admissible fills. So the bound is
/// consulted only after the budget fill is known, and only if that fill breaches
/// it — which a rising marginal impact rate or an exhausted sponsor subsidy can
/// cause on a budget the account can afford. The step-down search runs strictly
/// below the budget fill, so every candidate already fits `max_cost`. A positive
/// result clears the payout bound, but maximality is not guaranteed because that
/// predicate is not monotone. It can miss a larger admissible fill, including one
/// meeting `min_quantity`, so the final admission can still abort. When the
/// search finds no smaller fill, the budget fill is admitted so the caller sees
/// `EMintCostAboveMaxPayout` rather than an empty fill's admission error.
/// `compute_mint_quote` still enforces the bound on whatever is admitted.
#[test_only]
fun quote_exact_cost_terms(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    builder_code_id: &Option<ID>,
    max_cost: u64,
    min_quantity: u64,
    clock: &Clock,
    ctx: &TxContext,
): MintTerms {
    let range = market.strike_exposure.quote_mint_range(pricer, lower_tick, higher_tick);
    let lot = constants::position_lot_size!();
    // Sampled once: the rate is a dynamic-field read that no probe should repeat.
    let subsidy_rate = config.fee_incentive_subsidy_rate();

    let mut lo = 0;
    let mut hi = range.max_quantity_for_premium(max_cost) / lot;
    while (lo < hi) {
        let mid = (lo + hi + 1) / 2;
        let cost = market.all_in_cost_at(
            config,
            &range,
            builder_code_id,
            mid * lot,
            subsidy_rate,
            clock,
            ctx,
        );
        if (cost <= max_cost) {
            lo = mid
        } else {
            hi = mid - 1
        }
    };
    let budget_lots = lo;

    let budget_quantity = budget_lots * lot;
    let lots = if (
        budget_lots == 0
            || market.all_in_cost_at(
                config,
                &range,
                builder_code_id,
                budget_quantity,
                subsidy_rate,
                clock,
                ctx,
            ) <= budget_quantity
    ) {
        budget_lots
    } else {
        let mut lo = 0;
        let mut hi = budget_lots - 1;
        while (lo < hi) {
            let mid = (lo + hi + 1) / 2;
            let quantity = mid * lot;
            let cost = market.all_in_cost_at(
                config,
                &range,
                builder_code_id,
                quantity,
                subsidy_rate,
                clock,
                ctx,
            );
            if (cost <= quantity) {
                lo = mid
            } else {
                hi = mid - 1
            }
        };
        if (lo == 0) budget_lots else lo
    };
    market.strike_exposure.mint_terms(range, lots * lot, min_quantity)
}

/// All-in cost of minting `quantity` over `range`, computed by the helper the mint
/// charges with (`mint_quote_at`) against pre-trade state, without admission.
#[test_only]
fun all_in_cost_at(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    range: &MintRange,
    builder_code_id: &Option<ID>,
    quantity: u64,
    fee_incentive_subsidy_rate: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    market
        .mint_quote_at(
            range.mint_range_price(),
            quantity,
            range.mint_range_premium(quantity),
            market.strike_exposure.mint_range_inventory_impact(range, quantity),
            builder_code_id,
            market.ewma.penalty_fee(config.ewma_config(), quantity, ctx),
            fee_incentive_subsidy_rate,
            clock,
        )
        .all_in_cost
}

/// Charge and record one admitted mint: price its fees and congestion penalty
/// against pre-trade state, enforce the all-in `max_cost`, fold the EWMA, route
/// the referral share, allocate the order, settle payment, and emit `OrderMinted`.
/// `builder_code_id` is the caller's single read of the account's attribution.
#[test_only]
fun mint_with_terms(
    market: &mut ExpiryMarket,
    account: &mut Account,
    config: &ProtocolConfig,
    pricer: &Pricer,
    terms: MintTerms,
    builder_code_id: Option<ID>,
    max_cost: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    let penalty_amount = market.ewma.penalty_fee(config.ewma_config(), terms.quantity(), ctx);
    let referrer_account_id = account.referrer_account_id();
    let referrer_receive_address = account.referrer_receive_address();
    let quote = market.compute_mint_quote(
        &terms,
        &builder_code_id,
        penalty_amount,
        config.fee_incentive_subsidy_rate(),
        clock,
    );
    assert!(quote.all_in_cost <= max_cost, EMintCostAboveMax);
    market.ewma.update(config.ewma_config(), clock, ctx);
    let referral_fee = if (referrer_receive_address.is_some()) {
        let referral_fee_basis =
            quote.trading_fee - quote.fee_incentive_subsidy + quote.penalty_fee;
        math::mul_down(referral_fee_basis, config.referral_fee_rate())
    } else {
        0
    };

    let minted_order = market.strike_exposure.allocate_mint_order(terms);
    market.settle_mint_payment(
        account,
        &minted_order,
        &quote,
        builder_code_id,
        referrer_receive_address,
        referral_fee,
        clock,
        ctx,
    );
    order_events::emit_order_minted(
        market.id(),
        account.account_id(),
        account.owner(),
        builder_code_id,
        referrer_account_id,
        &minted_order,
        pricer,
        quote.entry_probability,
        quote.premium,
        quote.trading_fee,
        quote.fee_incentive_subsidy,
        quote.builder_fee,
        quote.penalty_fee,
        referral_fee,
        quote.inventory_impact_charge,
        clock.timestamp_ms(),
    );
    minted_order.id()
}

/// Assemble the cost decomposition shared by mint quotes and execution.
#[test_only]
fun compute_mint_quote(
    market: &ExpiryMarket,
    terms: &MintTerms,
    builder_code_id: &Option<ID>,
    penalty_fee: u64,
    fee_incentive_subsidy_rate: u64,
    clock: &Clock,
): MintQuote {
    let quote = market.mint_quote_at(
        terms.mint_price(),
        terms.quantity(),
        terms.premium(),
        terms.inventory_impact_charge(),
        builder_code_id,
        penalty_fee,
        fee_incentive_subsidy_rate,
        clock,
    );
    assert!(quote.all_in_cost <= quote.quantity, EMintCostAboveMaxPayout);
    quote
}

/// Sum one mint's fee components and all-in cost from its quantity-dependent
/// inputs, without admission or the maximum-payout bound. The single home of the
/// all-in sum: execution reaches it through `compute_mint_quote`, and the all-in
/// budget search probes candidate quantities with it directly.
#[test_only]
fun mint_quote_at(
    market: &ExpiryMarket,
    price: &RangePrice,
    quantity: u64,
    premium: u64,
    inventory_impact_charge: u64,
    builder_code_id: &Option<ID>,
    penalty_fee: u64,
    fee_incentive_subsidy_rate: u64,
    clock: &Clock,
): MintQuote {
    let trading_fee = market.strike_exposure.trading_fee(market.expiry, price, quantity, clock);
    let fee_incentive_subsidy = market.fee_incentive_subsidy_amount(
        trading_fee,
        fee_incentive_subsidy_rate,
    );
    let builder_fee = builder_fee_amount(builder_code_id, trading_fee, quantity);
    let all_in_cost =
        premium
        + (trading_fee - fee_incentive_subsidy)
        + builder_fee
        + penalty_fee
        + inventory_impact_charge;

    MintQuote {
        quantity,
        entry_probability: price.probability(),
        premium,
        trading_fee,
        fee_incentive_subsidy,
        builder_fee,
        penalty_fee,
        inventory_impact_charge,
        all_in_cost,
    }
}

#[test_only]
fun fee_incentive_subsidy_amount(
    market: &ExpiryMarket,
    fee_amount: u64,
    fee_incentive_subsidy_rate: u64,
): u64 {
    math::mul_down(fee_amount, fee_incentive_subsidy_rate).min(market.fee_incentive_balance.value())
}

/// Settle a mint payment per a computed quote: withdraw `all_in_cost` from the
/// account, route the builder and referral fees, join the subsidized trading fee,
/// and keep the remainder in expiry cash. The caller owns the all-in `max_cost` guard and the
/// quote derivation (`compute_mint_quote`), and passes its single
/// `builder_code_id` read so the fee amount and the routing destination cannot
/// come from different reads. The EWMA penalty, net of the referral split, rides
/// into expiry cash as surplus and earns no builder cut.
/// Fee incentives subsidize only the trader-paid portion of the trading fee;
/// the referral is split before that sponsor balance joins, so incentives do not
/// fund the referral payment.
#[test_only]
fun settle_mint_payment(
    market: &mut ExpiryMarket,
    account: &mut Account,
    order: &order::Order,
    quote: &MintQuote,
    builder_code_id: Option<ID>,
    referrer_receive_address: Option<address>,
    referral_fee: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    predict_account::add_position(
        account,
        market.id(),
        order.id(),
        order.id(),
        clock.timestamp_ms(),
        ctx,
    );
    let mut payment = account.withdraw<USDC>(quote.all_in_cost, ctx).into_balance();
    let builder_fee_payment = payment.split(quote.builder_fee);
    send_builder_fee(builder_code_id, builder_fee_payment);
    let referral_fee_payment = payment.split(referral_fee);
    send_referral_fee(referrer_receive_address, referral_fee_payment);
    // The remaining fee, sponsor subsidy, premium, penalty and inventory impact
    // land in the same custody; the impact amount is earmarked separately once
    // its cash has arrived.
    payment.join(market.fee_incentive_balance.split(quote.fee_incentive_subsidy));
    market.cash.receive(payment);
    market.cash.credit_inventory_impact_reserve(quote.inventory_impact_charge);

    market.assert_cash_backing();
}

// --- Redeem flow ---
#[test_only]
fun redeem_live_with_auth(
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    pricer: &Pricer,
    order_id: u256,
    close_quantity: u64,
    min_probability: u64,
    min_proceeds: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): Option<u256> {
    market.reconcile_stale_valuation_stamp(config);
    wrapper.settle<USDC>(root, clock);
    let account = wrapper.load_account_mut(auth);
    let order = order::from_order_id(order_id);
    let terms = market.strike_exposure.quote_live_close(pricer, &order, close_quantity);

    // Block an atomic mint -> oracle-update -> redeem: reject closing a position
    // in the same timestamp it was opened. A single transaction reads one
    // `Clock`, so equal timestamps mean the mint and redeem are in the same tx.
    // The open time is carried forward across partial closes, so seasoned
    // positions stay closable.
    let opened_at_ms = predict_account::position_opened_at_ms(
        account,
        market.id(),
        order.id(),
    );
    assert!(clock.timestamp_ms() != opened_at_ms, EMintRedeemSameTimestamp);
    // Charge against the pre-trade EWMA distribution, then fold this gas price.
    let penalty_amount = market.ewma_penalty(config.ewma_config(), close_quantity, clock, ctx);

    let redeem_amount = terms.redeem_amount();
    let range_probability = terms.range_probability();
    // Close-side slippage floor: reject if the quoted per-contract probability
    // has slipped below the caller's bound. `0` disables.
    assert!(range_probability >= min_probability, ERedeemProbabilityBelowMin);
    // Cap the fee at the payout it is charged against: an expiry-ramped fee can
    // exceed a deep out-of-the-money redeem, and a close must never cost more
    // than it releases.
    let fee_amount = market
        .strike_exposure
        .trading_fee(
            market.expiry,
            terms.close_price(),
            close_quantity,
            clock,
        )
        .min(redeem_amount);

    // The redeem payment decomposition, computed in full before any cash moves:
    // builder fee and penalty are each clamped at the payout remaining after the
    // prior deductions, so every subtraction below is exact. The single
    // `builder_code_id` read feeds the fee amount, the routing destination, and
    // the event, so they cannot come from different reads.
    let builder_code_id = predict_account::builder_code_id(account);
    let builder_fee_amount = builder_fee_amount(
        &builder_code_id,
        fee_amount,
        close_quantity,
    ).min(redeem_amount - fee_amount);
    let penalty_amount = penalty_amount.min(redeem_amount - fee_amount - builder_fee_amount);
    let inventory_impact_rebate = terms.inventory_impact_rebate();
    // Close-side all-in slippage floor: the net credited to the account is
    // `redeem_amount` plus inventory rebate, minus fee, builder fee, and
    // penalty. `0` disables. Mirror of mint's `max_cost`.
    assert!(
        redeem_amount + inventory_impact_rebate
            - fee_amount
            - builder_fee_amount
            - penalty_amount >= min_proceeds,
        ERedeemProceedsBelowMin,
    );

    // Apply book and account-position mutations only after all close policy
    // checks. Any later abort rolls back the earlier EWMA update.
    // Boundaries a waiting order pins survive the close.
    let no_pins = vec_map::empty<u64, u64>();
    let pins = if (market.has_order_book()) {
        let book: &OrderBook = market.id.borrow(order_queue::book_key());
        book.pins()
    } else {
        &no_pins
    };
    let replacement_order = market.strike_exposure.process_live_close(terms, pins);
    let position_root_id = predict_account::remove_position(
        account,
        market.id(),
        order.id(),
        ctx,
    );
    let replacement_order_id = replacement_order.map!(|replacement| {
        let replacement_order_id = replacement.id();
        predict_account::add_position(
            account,
            market.id(),
            replacement_order_id,
            position_root_id,
            opened_at_ms,
            ctx,
        );
        replacement_order_id
    });
    market.settle_live_redeem_payment(
        account,
        redeem_amount,
        fee_amount,
        builder_fee_amount,
        penalty_amount,
        inventory_impact_rebate,
        builder_code_id,
        ctx,
    );
    order_events::emit_live_order_redeemed(
        market.id(),
        account.account_id(),
        account.owner(),
        builder_code_id,
        &order,
        pricer,
        position_root_id,
        close_quantity,
        replacement_order_id,
        redeem_amount,
        fee_amount,
        builder_fee_amount,
        penalty_amount,
        inventory_impact_rebate,
        clock.timestamp_ms(),
    );
    replacement_order_id
}

fun redeem_settled_with_auth(
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    order_id: u256,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    wrapper.settle<USDC>(root, clock);
    let account = wrapper.load_account_mut(auth);
    let order = order::from_order_id(order_id);

    let position_root_id = predict_account::remove_position(
        account,
        market.id(),
        order.id(),
        ctx,
    );
    let payout_amount = market.strike_exposure.process_settled_close(&order);
    // A settled losing position pays nothing; the settled redeem is
    // permissionless, so guard the amount before dispensing rather than
    // splitting/depositing a 0 coin.
    if (payout_amount > 0) {
        let payout = market.cash.pay_authorized(payout_amount);
        account.deposit<USDC>(payout.into_coin(ctx));
    };
    market.assert_cash_backing();

    order_events::emit_settled_order_redeemed(
        market.id(),
        account.account_id(),
        account.owner(),
        &order,
        position_root_id,
        payout_amount,
        clock.timestamp_ms(),
    );
}

/// Settle a live redeem per an already-computed payment decomposition: pay out
/// `redeem_amount`, route the fee and builder fee, and credit the account with
/// the remainder plus the isolated inventory-impact rebate. The caller owns the
/// decomposition and the `min_proceeds` guard.
///
/// The EWMA penalty is withheld from the payout and kept in expiry cash
/// as surplus.
#[test_only]
fun settle_live_redeem_payment(
    market: &mut ExpiryMarket,
    account: &mut Account,
    redeem_amount: u64,
    fee_amount: u64,
    builder_fee_amount: u64,
    penalty_amount: u64,
    inventory_impact_rebate: u64,
    builder_code_id: Option<ID>,
    ctx: &mut TxContext,
) {
    // The penalty stays in expiry cash, so it is never withdrawn: pay out net of it.
    let mut payout = market.cash.pay_authorized(redeem_amount - penalty_amount);
    payout.join(market.cash.pay_inventory_impact_rebate(inventory_impact_rebate));
    let fee = payout.split(fee_amount);
    let builder_fee = payout.split(builder_fee_amount);
    market.cash.receive(fee);
    send_builder_fee(builder_code_id, builder_fee);
    market.assert_cash_backing();
    account.deposit<USDC>(payout.into_coin(ctx));
}

// ===== region E1-private: queued placement (owner: E1) =====

/// The three queued mints after their request is built: steps 1 to 6 through
/// `begin_enqueue`, then the volatility snapshot, the static checks, the t₀ dry
/// run, the spare-cash check, and the placement. `kind` picks the budget and the
/// cash-need formula.
fun enqueue_mint(
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    kind: u8,
    request: order_queue::OrderRequest,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    let account_id = wrapper.load_account().account_id();
    let (policy, timing) = market.begin_enqueue(config, true, account_id, clock, ctx);
    let (vol, pricer) = market.load_vol_snapshot(
        config,
        propbook_registry,
        pyth,
        bs_values,
        bs_svi,
        policy.svi_max_age_ms(),
        clock,
        ctx,
    );
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
    let min_entry_probability = market.strike_exposure.min_entry_probability();
    let cash_need = if (kind == order_queue::kind_exact_quantity()) {
        order_queue::cash_need_exact_quantity(request.quantity(), min_entry_probability)
    } else if (kind == order_queue::kind_exact_amount()) {
        // A premium-budget fill buys no more than `max_premium` allows, so a
        // large `max_cost` does not inflate its need.
        order_queue::cash_need_budget(request.max_premium().min(budget), min_entry_probability)
    } else {
        order_queue::cash_need_budget(budget, min_entry_probability)
    };
    let parties = order_parties(account);

    // The t₀ dry run is resolve's own predicate at tick `now` without subsidy,
    // so enqueue refuses exactly what resolve would refund on the same inputs.
    let probe = order_queue::new_order(
        kind,
        request,
        parties,
        timing,
        vol,
        order_queue::new_escrow(budget, order_fee, 0, cash_need),
        order_queue::empty_position(),
    );
    let (terms, quote, _, _) = market.quote_queued_mint(
        &probe,
        &pricer,
        0,
        0,
        clock.timestamp_ms(),
    );
    assert!(terms.is_some(), EOrderFailsLimits);
    // Bounds the subsidy commit reserves, so one order cannot soak up the
    // market's incentives.
    let subsidy_bound = quote.trading_fee.min(budget);
    // Only this order's own need: one that misses at τ never touches cash, and
    // resolve checks again before each fill.
    assert!(cash_need <= market.spare_cash(), EInsufficientMarketCash);

    let funds = account.withdraw<USDC>(budget + order_fee, ctx).into_balance();
    // Pinning both boundary nodes now means a resolve fill never creates one.
    market.strike_exposure.ensure_mint_nodes(request.lower_tick(), request.higher_tick());
    let order = order_queue::new_order(
        kind,
        request,
        parties,
        timing,
        vol,
        order_queue::new_escrow(budget, order_fee, subsidy_bound, cash_need),
        order_queue::empty_position(),
    );
    market.append_order(order, funds, option::none())
}

/// The queued sell after `begin_enqueue` and the source checks: the volatility
/// snapshot, the fee and minimum-sell checks, the t₀ dry run, then the Open
/// record `source_record_id` is marked Closed and its position, `order_id`,
/// moves into the new record.
fun enqueue_sell(
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    policy: deepbook_predict::delayed_execution_config::DelayedExecutionPolicy,
    timing: order_queue::OrderTiming,
    order_id: u256,
    source_record_id: u64,
    close_quantity: u64,
    min_probability: u64,
    min_proceeds: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    let (vol, pricer) = market.load_vol_snapshot(
        config,
        propbook_registry,
        pyth,
        bs_values,
        bs_svi,
        policy.svi_max_age_ms(),
        clock,
        ctx,
    );
    wrapper.settle<USDC>(root, clock);
    let account = wrapper.load_account_mut(auth);

    let order_fee = policy.order_fee();
    // A sell escrows only the order fee, so a balance equal to it is enough.
    assert!(account.balance<USDC>(root, clock) >= order_fee, EFeeNotCovered);
    let held = order::from_order_id(order_id);
    let min_sell_quantity = policy.min_sell_quantity();
    assert!(close_quantity >= min_sell_quantity, EBelowMinSell);
    // A partial sell leaves a sellable remainder. A close above the held
    // quantity fails the dry run instead.
    assert!(
        close_quantity >= held.quantity() || held.quantity() - close_quantity >= min_sell_quantity,
        EBelowMinSell,
    );

    let kind = order_queue::kind_redeem_open();
    let request = order_queue::new_request(
        held.lower_tick(),
        held.higher_tick(),
        close_quantity,
        0,
        0,
        0,
        0,
        min_probability,
        min_proceeds,
    );
    // Sells skip the spare-cash check. The need still enters the waiting total,
    // so the keeper funds the market before τ; resolve refunds a sell the market
    // cannot cover.
    let cash_need = order_queue::cash_need_sell(
        close_quantity,
        market.strike_exposure.backing_buffer_lambda(),
    );
    let escrow = order_queue::new_escrow(0, order_fee, 0, cash_need);
    let parties = order_parties(account);

    // The dry run prices only the held order ID; the root and open time move
    // with the position below.
    let probe = order_queue::new_order(
        kind,
        request,
        parties,
        timing,
        vol,
        escrow,
        order_queue::new_held_position(order_id, 0, 0),
    );
    let (terms, _, _) = market.quote_queued_close(&probe, &pricer, clock.timestamp_ms());
    assert!(terms.is_some(), EOrderFailsLimits);

    let funds = if (order_fee > 0) {
        account.withdraw<USDC>(order_fee, ctx).into_balance()
    } else {
        balance::zero()
    };
    let position = market.order_book_mut().close_open_record(source_record_id);
    let order = order_queue::new_order(kind, request, parties, timing, vol, escrow, position);
    market.append_order(order, funds, option::some(source_record_id))
}

/// Steps 1 to 6 of every enqueue, in order: the version and cutover gates and
/// the policy; for mints the trading and mint pauses; the snapshot stage and
/// stale-stamp reconcile; the market's book (created by its first order); the
/// stuck, capacity, and per-account checks; then τ and the cutoff on the final
/// τ. Returns the policy and the order's timing.
fun begin_enqueue(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    is_mint: bool,
    account_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
): (deepbook_predict::delayed_execution_config::DelayedExecutionPolicy, order_queue::OrderTiming) {
    config.assert_version();
    config.assert_cutover_reached();
    let policy = *config.policy();
    if (is_mint) {
        config.assert_trading_allowed();
        assert!(!market.mint_paused, EMintPaused);
    };
    config.assert_snapshot_not_in_progress();
    market.reconcile_stale_valuation_stamp(config);
    market.ensure_order_book(ctx);

    let now_ms = clock.timestamp_ms();
    let expiry = market.expiry;
    let book = market.order_book();
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
    // refuses a settled or expired market: settlement needs `now >= expiry`,
    // and τ is within one tick of `now + delay`, while the cutoff sits at least
    // `stall_timeout_ms + 5_000` before expiry.
    let timing = book.plan_timing(&policy, expiry, config.no_trade_window_ms(), now_ms);
    assert!(timing.tau_ms() < timing.cutoff_ms(), EPastCutoff);
    (policy, timing)
}

/// The order's volatility snapshot and the t₀ `Pricer` its dry run prices with.
/// The `Pricer` never leaves the enqueue.
fun load_vol_snapshot(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    svi_max_age_ms: u64,
    clock: &Clock,
    ctx: &TxContext,
): (pricing::VolSnapshot, Pricer) {
    pricing::load_vol_snapshot(
        config.pricing_config(),
        propbook_registry,
        pyth,
        bs_values,
        bs_svi,
        market.id(),
        market.propbook_underlying_id,
        market.expiry,
        svi_max_age_ms,
        clock,
        ctx,
    )
}

/// The account facts a queued order snapshots, so resolve and the refunds never
/// load the account.
fun order_parties(account: &Account): order_queue::OrderParties {
    order_queue::new_parties(
        account.account_id(),
        account.owner(),
        account.receive_address(),
        account.referrer_account_id(),
        account.referrer_receive_address(),
        predict_account::builder_code_id(account),
    )
}

/// Store a placed order and its escrowed funds, then emit `OrderEnqueued` with
/// the post-call cash figures. Returns the record ID.
fun append_order(
    market: &mut ExpiryMarket,
    order: QueuedOrder,
    funds: Balance<USDC>,
    source_record_id: Option<u64>,
): u64 {
    let book = market.order_book_mut();
    book.deposit_escrow(funds);
    let record_id = book.append(order);
    let waiting_cash_need = book.waiting_cash_need();
    let (market_cash, required_cash) = market.cash_figures();
    let escrow = order.escrow();
    let parties = order.parties();
    order_events::emit_order_enqueued(
        market.id(),
        record_id,
        parties.account_id(),
        order.kind(),
        order.request(),
        order.position(),
        order.timing(),
        order.vol(),
        escrow.budget(),
        escrow.order_fee(),
        escrow.cash_need(),
        escrow.subsidy_bound(),
        parties.builder_code_id(),
        parties.referrer_account_id(),
        source_record_id,
        market_cash,
        required_cash,
        waiting_cash_need,
    );
    record_id
}

// ===== end region E1-private =====

// ===== region E2-private: tick-time quotes and decode (owner: E2) =====

// --- Commit ---

/// Pick the update that prices `span`, as an index into `ticks`: the one
/// stamped exactly τ on the cohort's channel. Otherwise, with a nonzero price
/// buffer and now at least `gap_wait_ms` past τ, the one stamped exactly one
/// tick of the cohort's own stored channel later. The buffer only switches that
/// backup on: a cohort has one admissible backup whatever the policy channel is
/// now, so a caller holding several later ticks has no price to choose.
fun matching_tick_index(
    ticks: &vector<LazerTick>,
    span: &order_queue::CohortSpan,
    buffer_ms: u64,
    gap_wait_ms: u64,
    now_ms: u64,
): Option<u64> {
    let tau_ms = span.span_tau_ms();
    let channel = span.span_pyth_channel();
    let exact = ticks.find_index!(
        |tick| tick.channel == channel && tick.envelope_us / 1000 == tau_ms,
    );
    if (exact.is_some() || buffer_ms == 0 || now_ms < tau_ms + gap_wait_ms) return exact;
    let backup_ms = tau_ms + deepbook_predict::delayed_execution_config::channel_tick_ms(channel);
    ticks.find_index!(|tick| tick.channel == channel && tick.envelope_us / 1000 == backup_ms)
}

/// Commit one matched cohort at `tick`, or leave it waiting. Every Pending
/// record is priced before any is written, so the cohort commits whole or not
/// at all: an empty, unusable, or too-early price leaves it for its deadline
/// refund (reason 5). A missing feed or an unrequested property aborts instead,
/// because the caller passed an update the queue cannot read. Each committed
/// mint reserves `min(subsidy_rate * subsidy_bound, incentives left)`.
fun commit_cohort(
    market: &mut ExpiryMarket,
    index: u64,
    tick: &LazerTick,
    subsidy_rate: u64,
    sender: address,
    now_ms: u64,
) {
    let span = market.order_book().cohort(index);
    let mut record_ids = vector[];
    let mut prices = vector[];
    // `some(subsidy bound)` for a mint, `none` for a sell.
    let mut subsidy_bounds = vector[];
    let mut first_feed = option::none();
    let mut usable = true;
    let mut record_id = span.span_first_id();
    while (record_id < span.span_end_id()) {
        let order = market.order_book().try_order(record_id);
        // A record refunded mid-queue (`admin_refund`) is no longer Pending.
        if (order.is_some() && order.borrow().status() == order_queue::status_pending()) {
            let order = order.destroy_some();
            let feed = tick.requested_feed(order.vol().pyth_source_id());
            let price = tick.committed_price(&feed, order.timing().earliest_price_ms());
            if (price.is_some()) {
                record_ids.push_back(record_id);
                prices.push_back(price.destroy_some());
                subsidy_bounds.push_back(if (is_mint_kind(order.kind()))
                    option::some(order.escrow().subsidy_bound()) else option::none());
            } else {
                usable = false;
            };
            if (first_feed.is_none()) first_feed.fill(feed);
        };
        record_id = record_id + 1;
    };
    if (!usable || first_feed.is_none()) return;

    let book: &mut OrderBook = market.id.borrow_mut(order_queue::book_key());
    record_ids.length().do!(|i| {
        let record_id = record_ids[i];
        book.commit_order(record_id, prices[i]);
        subsidy_bounds[i].do!(|subsidy_bound| {
            let amount = math::mul_down(subsidy_bound, subsidy_rate).min(market
                .fee_incentive_balance
                .value());
            book.reserve_subsidy(
                record_id,
                subsidy_rate,
                market.fee_incentive_balance.split(amount),
            );
        });
    });
    book.mark_cohort_committed(index);

    // Every committed record priced, so the first feed carries a price and time.
    let feed = first_feed.destroy_some();
    let (price_magnitude, price_is_negative) = lazer_i64_parts(feed.price.borrow().borrow());
    let (exponent_magnitude, exponent_is_negative) = lazer_i16_parts(feed.exponent.borrow());
    order_events::emit_cohort_committed(
        market.id(),
        span.span_tau_ms(),
        tick.envelope_us / 1000,
        span.span_first_id(),
        span.span_end_id() - 1,
        price_magnitude,
        price_is_negative,
        exponent_magnitude,
        exponent_is_negative,
        *feed.feed_update_timestamp_us.borrow().borrow(),
        feed.feed_id,
        span.span_pyth_channel(),
        sender,
        now_ms,
    );
}

/// The feed `feed_id` of `tick`. Aborts unless it is present and carries the
/// price, exponent, and update-time properties: commit needs all three, so their
/// absence means the caller requested the wrong update, not that Pyth had a gap.
fun requested_feed(tick: &LazerTick, feed_id: u32): LazerTickFeed {
    let index = tick.feeds.find_index!(|feed| feed.feed_id == feed_id);
    assert!(index.is_some(), EPythFeedMissing);
    let feed = tick.feeds[index.destroy_some()];
    assert!(
        feed.price.is_some() && feed.exponent.is_some() && feed.feed_update_timestamp_us.is_some(),
        EPythPropertyNotRequested,
    );
    feed
}

/// The price `feed` gives an order whose earliest valid price time is
/// `earliest_price_ms`, or `none` when the order must not commit on it: an empty
/// price or update time, a price generated before `earliest_price_ms`, or one
/// that does not normalize to a pricing-safe spot. Aborts when the feed claims
/// an update time after the envelope that carries it.
fun committed_price(
    tick: &LazerTick,
    feed: &LazerTickFeed,
    earliest_price_ms: u64,
): Option<order_queue::CommittedPrice> {
    let generation_us = *feed.feed_update_timestamp_us.borrow();
    if (generation_us.is_none()) return option::none();
    let generation_us = generation_us.destroy_some();
    assert!(generation_us <= tick.envelope_us, EGenerationAfterEnvelope);
    let price = *feed.price.borrow();
    if (price.is_none() || generation_us < earliest_price_ms * 1000) return option::none();

    let (magnitude, is_negative) = lazer_i64_parts(price.borrow());
    let (exponent_magnitude, exponent_is_negative) = lazer_i16_parts(feed.exponent.borrow());
    pricing::normalize_lazer_spot(
        magnitude,
        is_negative,
        exponent_magnitude,
        exponent_is_negative,
    ).map!(|spot| order_queue::new_committed_price(spot, tick.envelope_us / 1000, generation_us))
}

// --- Resolve ---

/// Finish one record if it can finish now, returning whether it did. A record at
/// or past its deadline is refunded with reason 5 whatever its cohort, a
/// RefundDue one with its stored reason, and a Committed one is filled or
/// refunded with the reason its fill failed on (2 when no Pricer exists at its
/// tick). Missing and finished records,
/// and Pending ones before their deadline, are left alone.
fun resolve_record(
    market: &mut ExpiryMarket,
    record_id: u64,
    referral_fee_rate: u64,
    sender: address,
    now_ms: u64,
): bool {
    let order = market.order_book().try_order(record_id);
    if (order.is_none()) return false;
    let order = order.destroy_some();
    let status = order.status();
    if (status == order_queue::status_refund_due()) {
        return market.refund_record(record_id, order.result().reason(), true, sender, now_ms)
    };
    if (status != order_queue::status_pending() && status != order_queue::status_committed()) {
        return false
    };
    if (now_ms >= order.timing().deadline_ms()) {
        return market.refund_record(record_id, order_queue::reason_deadline(), true, sender, now_ms)
    };
    if (status == order_queue::status_pending()) return false;
    // The order's own snapshot, re-anchored on its committed price and rolled to
    // its tick. `none` at or past expiry or on a zero forward.
    let price = order.price();
    let pricer = pricing::pricer_at(
        &order.vol(),
        price.spot(),
        price.generation_us() / 1000,
        price.tick_ms(),
        market.id(),
        market.expiry,
    );
    let reason = if (pricer.is_none()) {
        order_queue::reason_admission()
    } else if (is_mint_kind(order.kind())) {
        market.fill_queued_mint(
            record_id,
            &order,
            &pricer.destroy_some(),
            referral_fee_rate,
            sender,
            now_ms,
        )
    } else {
        market.fill_queued_sell(record_id, &order, &pricer.destroy_some(), sender, now_ms)
    };
    if (reason != 0) {
        market.refund_record(record_id, reason, true, sender, now_ms);
    };
    true
}

/// Fill a Committed mint at its tick `pricer` and return `0`, or return the
/// reason it must be refunded with, before anything moves: 2 (admission), 1 (its
/// own limits), 4 (a pinned node is missing, a backstop placement makes
/// unreachable), or 8 (the market's cash after the fill would not cover its
/// required cash).
///
/// The fill pays from escrow. Market cash takes the premium, the trading fee net
/// of the referral share, the used subsidy, the order fee, and the
/// inventory-impact charge (into its reserve). Builder and referral fees go out,
/// unused subsidy returns to the incentive balance, and unused budget returns to
/// the trader. No congestion penalty applies.
fun fill_queued_mint(
    market: &mut ExpiryMarket,
    record_id: u64,
    order: &QueuedOrder,
    pricer: &Pricer,
    referral_fee_rate: u64,
    sender: address,
    now_ms: u64,
): u8 {
    let tick_ms = order.price().tick_ms();
    let escrow = order.escrow();
    let (terms, quote, liability_after, reason) = market.quote_queued_mint(
        order,
        pricer,
        escrow.subsidy_rate(),
        escrow.subsidy_reserved(),
        tick_ms,
    );
    if (reason != 0) return reason;
    let request = order.request();
    if (!market.strike_exposure.has_mint_nodes(request.lower_tick(), request.higher_tick())) {
        return order_queue::reason_missing_node()
    };
    let parties = order.parties();
    let referral_fee = if (parties.referrer_receive_address().is_some()) {
        math::mul_down(quote.trading_fee - quote.fee_incentive_subsidy, referral_fee_rate)
    } else {
        0
    };
    // The non-aborting form of `assert_cash_backing` on the post-fill state. The
    // trader's builder fee leaves with the escrow it came from, so market cash
    // gains the premium, the impact charge, the whole trading fee (subsidy
    // included) net of the referral, and the order fee.
    let cash_after =
        market.cash.balance() + quote.premium + quote.inventory_impact_charge
        + quote.trading_fee - referral_fee + escrow.order_fee();
    let required_after =
        liability_after + market.cash.inventory_impact_reserve() + quote.inventory_impact_charge;
    if (cash_after < required_after) return order_queue::reason_no_cash();

    let mut funds = market.order_book_mut().withdraw_order_escrow(record_id);
    let mut payment = funds.split(quote.all_in_cost);
    send_builder_fee(parties.builder_code_id(), payment.split(quote.builder_fee));
    send_referral_fee(parties.referrer_receive_address(), payment.split(referral_fee));
    payment.join(funds.split(quote.fee_incentive_subsidy));
    payment.join(funds.split(escrow.order_fee()));
    market.cash.receive(payment);
    market.cash.credit_inventory_impact_reserve(quote.inventory_impact_charge);
    market
        .fee_incentive_balance
        .join(funds.split(escrow.subsidy_reserved() - quote.fee_incentive_subsidy));
    send_or_destroy(funds, parties.receive_address());
    let minted_order = market.strike_exposure.allocate_mint_order_existing(terms.destroy_some());
    market.assert_cash_backing();

    let position = order_queue::new_held_position(minted_order.id(), minted_order.id(), tick_ms);
    market
        .order_book_mut()
        .finish_fill(
            record_id,
            order_queue::status_open(),
            position,
            quote.quantity,
            quote.all_in_cost,
            now_ms,
        );
    order_events::emit_order_minted(
        market.id(),
        parties.account_id(),
        parties.owner(),
        parties.builder_code_id(),
        parties.referrer_account_id(),
        &minted_order,
        pricer,
        quote.entry_probability,
        quote.premium,
        quote.trading_fee,
        quote.fee_incentive_subsidy,
        quote.builder_fee,
        0,
        referral_fee,
        quote.inventory_impact_charge,
        now_ms,
    );
    market.emit_queued_fill(
        record_id,
        order,
        quote.quantity,
        quote.all_in_cost,
        quote.trading_fee,
        quote.builder_fee,
        referral_fee,
        quote.fee_incentive_subsidy,
        quote.inventory_impact_charge,
        position,
        sender,
        now_ms,
    );
    0
}

/// Fill a Committed sell at its tick `pricer` and return `0`, or return the
/// reason it must be refunded with, before anything moves: 2 when the close
/// cannot be priced, 1 below its own floors, 8 when the market's cash after the
/// close would not cover its required cash. A refunded sell returns to Open
/// holding its position. A fill pays redeem value plus the
/// inventory-impact rebate, less the trading and builder fees, to the trader;
/// the trading fee and the order fee stay in market cash. Boundaries a waiting
/// mint pins survive the close.
fun fill_queued_sell(
    market: &mut ExpiryMarket,
    record_id: u64,
    order: &QueuedOrder,
    pricer: &Pricer,
    sender: address,
    now_ms: u64,
): u8 {
    let tick_ms = order.price().tick_ms();
    let (terms, quote, reason) = market.quote_queued_close(order, pricer, tick_ms);
    if (reason != 0) return reason;
    let terms = terms.destroy_some();
    let held = order.position();
    let position_order = order::from_order_id(held.order_id());
    let close_quantity = quote.close_quantity;
    let redeem_amount = terms.redeem_amount();
    let order_fee = order.escrow().order_fee();
    let liability_after = market
        .strike_exposure
        .close_liability_after(
            position_order.lower_tick(),
            position_order.higher_tick(),
            close_quantity,
        );
    // The non-aborting form of `assert_cash_backing` on the post-close state:
    // cash loses the redeem value and the rebate and keeps the trading and order
    // fees, while the rebate also leaves the impact reserve, so it cancels.
    if (
        market.cash.balance() + quote.trading_fee + order_fee
            < liability_after + market.cash.inventory_impact_reserve() + redeem_amount
    ) return order_queue::reason_no_cash();

    let replacement_order = {
        let book: &OrderBook = market.id.borrow(order_queue::book_key());
        market.strike_exposure.process_live_close(terms, book.pins())
    };
    let mut funds = market.order_book_mut().withdraw_order_escrow(record_id);
    market.cash.receive(funds.split(order_fee));
    let mut payout = market.cash.pay_authorized(redeem_amount);
    payout.join(market.cash.pay_inventory_impact_rebate(quote.inventory_impact_rebate));
    market.cash.receive(payout.split(quote.trading_fee));
    let parties = order.parties();
    send_builder_fee(parties.builder_code_id(), payout.split(quote.builder_fee));
    // A sell escrows only its order fee, so any other escrow is the trader's.
    payout.join(funds);
    send_or_destroy(payout, parties.receive_address());
    market.assert_cash_backing();

    let replacement_order_id = replacement_order.map!(|replacement| replacement.id());
    let (status, position) = if (replacement_order_id.is_some()) {
        (
            order_queue::status_open(),
            order_queue::new_held_position(
                *replacement_order_id.borrow(),
                held.root_id(),
                held.opened_at_ms(),
            ),
        )
    } else {
        (order_queue::status_closed(), order_queue::empty_position())
    };
    market
        .order_book_mut()
        .finish_fill(record_id, status, position, close_quantity, quote.proceeds, now_ms);
    order_events::emit_live_order_redeemed(
        market.id(),
        parties.account_id(),
        parties.owner(),
        parties.builder_code_id(),
        &position_order,
        pricer,
        held.root_id(),
        close_quantity,
        replacement_order_id,
        redeem_amount,
        quote.trading_fee,
        quote.builder_fee,
        0,
        quote.inventory_impact_rebate,
        now_ms,
    );
    market.emit_queued_fill(
        record_id,
        order,
        close_quantity,
        quote.proceeds,
        quote.trading_fee,
        quote.builder_fee,
        0,
        0,
        quote.inventory_impact_rebate,
        position,
        sender,
        now_ms,
    );
    0
}

/// Emit `QueuedOrderFilled` for one fill, with the market's post-fill cash
/// figures and waiting cash need.
fun emit_queued_fill(
    market: &ExpiryMarket,
    record_id: u64,
    order: &QueuedOrder,
    quantity: u64,
    amount: u64,
    trading_fee: u64,
    builder_fee: u64,
    referral_fee: u64,
    subsidy_used: u64,
    inventory_impact: u64,
    position: order_queue::HeldPosition,
    sender: address,
    now_ms: u64,
) {
    let (market_cash, required_cash) = market.cash_figures();
    order_events::emit_queued_order_filled(
        market_cash,
        required_cash,
        market.order_book().waiting_cash_need(),
        market.id(),
        record_id,
        order.parties().account_id(),
        order.kind(),
        quantity,
        amount,
        trading_fee,
        builder_fee,
        referral_fee,
        order.escrow().order_fee(),
        subsidy_used,
        inventory_impact,
        order.timing().tau_ms(),
        order.price().tick_ms(),
        position,
        sender,
        now_ms,
    );
}

// --- Tick-time quotes ---

/// Quote a queued mint at a tick against its own limits. Returns the terms (or
/// `none`), the quote, the payout liability after the fill, and the refund
/// reason (`0` with terms). The enqueue dry run and resolve share it, so enqueue
/// rejects exactly what resolve would refund on the same inputs.
///
/// Reason 2 when the range cannot be priced or leaves the entry band, misses the
/// minimum premium, or costs more than its maximum payout. Reason 1 when the
/// size is zero or below `min_quantity`, an exact-quantity order's probability is
/// above its `max_probability`, or the all-in cost is above `min(max_cost,
/// budget)`. The liability comes from the range's own pre-mint book reads.
fun quote_queued_mint(
    market: &ExpiryMarket,
    order: &QueuedOrder,
    pricer: &Pricer,
    subsidy_rate: u64,
    subsidy_cap: u64,
    tick_ms: u64,
): (Option<MintTerms>, MintQuote, u64, u8) {
    let request = order.request();
    let builder_code_id = order.parties().builder_code_id();
    let cost_cap = request.max_cost().min(order.escrow().budget());
    let range = market
        .strike_exposure
        .try_quote_mint_range(pricer, request.lower_tick(), request.higher_tick());
    if (range.is_none()) {
        return (option::none(), empty_mint_quote(), 0, order_queue::reason_admission())
    };
    let range = range.destroy_some();
    let exact_quantity = order.kind() == order_queue::kind_exact_quantity();
    let quantity = if (exact_quantity) {
        request.quantity()
    } else if (order.kind() == order_queue::kind_exact_amount()) {
        range.max_quantity_for_premium(request.max_premium())
    } else {
        market.exact_cost_quantity_at_tick(
            &range,
            &builder_code_id,
            cost_cap,
            subsidy_rate,
            subsidy_cap,
            tick_ms,
        )
    };
    let min_quantity = if (exact_quantity) quantity else request.min_quantity();
    let liability_after = market.strike_exposure.mint_liability_after(&range, quantity);
    let (terms, reason) = market.strike_exposure.try_mint_terms(range, quantity, min_quantity);
    if (terms.is_none()) return (terms, empty_mint_quote(), 0, reason);

    let quote = {
        let terms = terms.borrow();
        market.mint_quote_at_tick(
            terms.mint_price(),
            terms.quantity(),
            terms.premium(),
            terms.inventory_impact_charge(),
            &builder_code_id,
            subsidy_rate,
            subsidy_cap,
            tick_ms,
        )
    };
    if (quote.is_none()) {
        return (option::none(), empty_mint_quote(), 0, order_queue::reason_admission())
    };
    let quote = quote.destroy_some();
    // Same order as the live mint: probability cap, payout bound, then cost cap.
    if (exact_quantity && quote.entry_probability > request.max_probability()) {
        return (option::none(), quote, 0, order_queue::reason_limits())
    };
    if (quote.all_in_cost > quote.quantity) {
        return (option::none(), quote, 0, order_queue::reason_admission())
    };
    if (quote.all_in_cost > cost_cap) {
        return (option::none(), quote, 0, order_queue::reason_limits())
    };
    (terms, quote, liability_after, 0)
}

/// Size an all-in-budget mint over `range` at a tick: `quote_exact_cost_terms`'
/// search, probed by `mint_quote_at_tick`, which is what the fill charges. The
/// largest lot-rounded quantity whose all-in cost fits `max_cost`, stepped down
/// only when that fill would cost more than its maximum payout (that bound is
/// not monotone in quantity, so it is never part of the budget search). Returns
/// the budget fill when no smaller fill clears the payout bound, which the caller
/// then refunds on that bound.
fun exact_cost_quantity_at_tick(
    market: &ExpiryMarket,
    range: &MintRange,
    builder_code_id: &Option<ID>,
    max_cost: u64,
    subsidy_rate: u64,
    subsidy_cap: u64,
    tick_ms: u64,
): u64 {
    let lot = constants::position_lot_size!();
    let mut lo = 0;
    let mut hi = range.max_quantity_for_premium(max_cost) / lot;
    while (lo < hi) {
        let mid = (lo + hi + 1) / 2;
        let cost = market.all_in_cost_at_tick(
            range,
            builder_code_id,
            mid * lot,
            subsidy_rate,
            subsidy_cap,
            tick_ms,
        );
        if (cost <= max_cost) {
            lo = mid
        } else {
            hi = mid - 1
        }
    };
    let budget_quantity = lo * lot;
    if (
        lo == 0
            || market.all_in_cost_at_tick(
                range,
                builder_code_id,
                budget_quantity,
                subsidy_rate,
                subsidy_cap,
                tick_ms,
            ) <= budget_quantity
    ) return budget_quantity;

    let mut hi = lo - 1;
    let mut lo = 0;
    while (lo < hi) {
        let mid = (lo + hi + 1) / 2;
        let quantity = mid * lot;
        let cost = market.all_in_cost_at_tick(
            range,
            builder_code_id,
            quantity,
            subsidy_rate,
            subsidy_cap,
            tick_ms,
        );
        if (cost <= quantity) {
            lo = mid
        } else {
            hi = mid - 1
        }
    };
    if (lo == 0) budget_quantity else lo * lot
}

/// All-in cost of minting `quantity` over `range` at a tick, from the helper the
/// fill charges with. A quote that cannot be built never fits a budget.
fun all_in_cost_at_tick(
    market: &ExpiryMarket,
    range: &MintRange,
    builder_code_id: &Option<ID>,
    quantity: u64,
    subsidy_rate: u64,
    subsidy_cap: u64,
    tick_ms: u64,
): u64 {
    market
        .mint_quote_at_tick(
            range.mint_range_price(),
            quantity,
            range.mint_range_premium(quantity),
            market.strike_exposure.mint_range_inventory_impact(range, quantity),
            builder_code_id,
            subsidy_rate,
            subsidy_cap,
            tick_ms,
        )
        .map!(|quote| quote.all_in_cost)
        .destroy_or!(std::u64::max_value!())
}

/// `mint_quote_at` at a committed tick: no congestion penalty, the trading fee
/// at `tick_ms`, and the subsidy capped by both `subsidy_rate` and the reserved
/// `subsidy_cap`. Like `mint_quote_at` it applies neither admission nor the
/// maximum-payout bound. `none` at or past expiry, where the fee ramp is
/// undefined.
fun mint_quote_at_tick(
    market: &ExpiryMarket,
    price: &RangePrice,
    quantity: u64,
    premium: u64,
    inventory_impact_charge: u64,
    builder_code_id: &Option<ID>,
    subsidy_rate: u64,
    subsidy_cap: u64,
    tick_ms: u64,
): Option<MintQuote> {
    if (tick_ms >= market.expiry) return option::none();
    let trading_fee = market
        .strike_exposure
        .trading_fee_at(market.expiry, price, quantity, tick_ms);
    let fee_incentive_subsidy = math::mul_down(trading_fee, subsidy_rate).min(subsidy_cap);
    let builder_fee = builder_fee_amount(builder_code_id, trading_fee, quantity);
    option::some(MintQuote {
        quantity,
        entry_probability: price.probability(),
        premium,
        trading_fee,
        fee_incentive_subsidy,
        builder_fee,
        penalty_fee: 0,
        inventory_impact_charge,
        all_in_cost: premium
            + (trading_fee - fee_incentive_subsidy)
            + builder_fee
            + inventory_impact_charge,
    })
}

/// Quote a queued sell at a tick against its own floors. Returns the close terms
/// (or `none`), the quote, and the refund reason (`0` with terms): 2 when the
/// close cannot be priced, 1 below `min_probability` or `min_proceeds`.
fun quote_queued_close(
    market: &ExpiryMarket,
    order: &QueuedOrder,
    pricer: &Pricer,
    tick_ms: u64,
): (Option<LiveCloseTerms>, RedeemQuote, u8) {
    let request = order.request();
    let close_quantity = request.quantity();
    let position_order = order::from_order_id(order.position().order_id());
    let terms = market
        .strike_exposure
        .try_quote_live_close(pricer, &position_order, close_quantity);
    if (terms.is_none()) {
        return (terms, empty_redeem_quote(close_quantity), order_queue::reason_admission())
    };
    let builder_code_id = order.parties().builder_code_id();
    let quote = market.redeem_quote_at_tick(
        terms.borrow(),
        &builder_code_id,
        close_quantity,
        tick_ms,
    );
    if (quote.probability < request.min_probability() || quote.proceeds < request.min_proceeds()) {
        return (option::none(), quote, order_queue::reason_limits())
    };
    (terms, quote, 0)
}

/// Price a live close's fees at `tick_ms`: the trading fee capped at the redeem
/// value and the builder fee at what remains, as `redeem_live` charges, with no
/// congestion penalty. Shared by queued sells and `quote_redeem_open`.
fun redeem_quote_at_tick(
    market: &ExpiryMarket,
    terms: &LiveCloseTerms,
    builder_code_id: &Option<ID>,
    close_quantity: u64,
    tick_ms: u64,
): RedeemQuote {
    let redeem_amount = terms.redeem_amount();
    let trading_fee = market
        .strike_exposure
        .trading_fee_at(market.expiry, terms.close_price(), close_quantity, tick_ms)
        .min(redeem_amount);
    let builder_fee = builder_fee_amount(builder_code_id, trading_fee, close_quantity).min(
        redeem_amount - trading_fee,
    );
    let inventory_impact_rebate = terms.inventory_impact_rebate();
    RedeemQuote {
        close_quantity,
        probability: terms.range_probability(),
        proceeds: redeem_amount + inventory_impact_rebate - trading_fee - builder_fee,
        trading_fee,
        builder_fee,
        inventory_impact_rebate,
    }
}

/// The quote returned beside a reason when a mint is refunded before it could
/// be quoted.
fun empty_mint_quote(): MintQuote {
    MintQuote {
        quantity: 0,
        entry_probability: 0,
        premium: 0,
        trading_fee: 0,
        fee_incentive_subsidy: 0,
        builder_fee: 0,
        penalty_fee: 0,
        inventory_impact_charge: 0,
        all_in_cost: 0,
    }
}

/// The quote returned beside a reason when a sell is refunded before it could
/// be quoted.
fun empty_redeem_quote(close_quantity: u64): RedeemQuote {
    RedeemQuote {
        close_quantity,
        probability: 0,
        proceeds: 0,
        trading_fee: 0,
        builder_fee: 0,
        inventory_impact_rebate: 0,
    }
}

// --- Shared by commit and resolve ---

/// Whether `kind` is one of the three queued mint kinds.
fun is_mint_kind(kind: u8): bool {
    kind == order_queue::kind_exact_quantity()
        || kind == order_queue::kind_exact_amount()
        || kind == order_queue::kind_exact_cost()
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

/// `(magnitude, is_negative)` of a Lazer `I64`.
fun lazer_i64_parts(value: &LazerI64): (u64, bool) {
    let is_negative = value.get_is_negative();
    let magnitude = if (is_negative) {
        value.get_magnitude_if_negative()
    } else {
        value.get_magnitude_if_positive()
    };
    (magnitude, is_negative)
}

/// `(magnitude, is_negative)` of a Lazer `I16`.
fun lazer_i16_parts(value: &LazerI16): (u16, bool) {
    let is_negative = value.get_is_negative();
    let magnitude = if (is_negative) {
        value.get_magnitude_if_negative()
    } else {
        value.get_magnitude_if_positive()
    };
    (magnitude, is_negative)
}

/// Flatten one verified Lazer update into a `LazerTick`, keeping every `Option`
/// layer. No validation happens here.
#[allow(deprecated_usage)]
fun decode_update(update: &pyth_lazer::update::Update): LazerTick {
    let channel = update.channel();
    // Lazer's v1 channel enum has one more variant, real-time (id 1), which no
    // cohort is placed on.
    let channel = if (channel.is_fixed_rate_50ms()) {
        deepbook_predict::delayed_execution_config::pyth_channel_fixed_rate_50ms!()
    } else if (channel.is_fixed_rate_200ms()) {
        deepbook_predict::delayed_execution_config::pyth_channel_fixed_rate_200ms!()
    } else {
        1
    };
    LazerTick {
        envelope_us: update.timestamp(),
        channel,
        feeds: update
            .feeds_ref()
            .map_ref!(
                |feed| LazerTickFeed {
                    feed_id: feed.feed_id(),
                    price: feed.price(),
                    exponent: feed.exponent(),
                    feed_update_timestamp_us: feed.feed_update_timestamp(),
                },
            ),
    }
}

// ===== end region E2-private =====

// ===== region E3-private: refunds, cleanup, settlement phases (owner: E3) =====

/// Refund waiting orders cohort by cohort in τ order, through the cohorts whose
/// deadline is at or before `due_by_ms`, visiting at most `max_orders` records,
/// refunded or not. Every visited record has finished afterwards, so a walk that
/// stops inside a cohort moves that cohort's `first_id` to the first record it
/// did not visit. `advance_heads` runs once at the end so cohort indices stay
/// stable during the walk. The caller checks the book exists. Returns how many
/// orders it refunded.
fun refund_walk(
    market: &mut ExpiryMarket,
    due_by_ms: u64,
    max_orders: u64,
    prune: bool,
    sender: address,
    now_ms: u64,
): u64 {
    let reason = order_queue::reason_deadline();
    let cohort_count = market.order_book().cohort_count();
    let mut visited = 0;
    let mut refunded = 0;
    let mut index = 0;
    while (index < cohort_count && visited < max_orders) {
        let span = market.order_book().cohort(index);
        // Deadlines never decrease along the queue, so no later cohort is due.
        if (span.span_deadline_ms() > due_by_ms) break;
        let first_id = span.span_first_id();
        let end_id = span.span_end_id();
        let mut unfinished = span.span_unfinished();
        let mut record_id = first_id;
        while (record_id < end_id && unfinished > 0 && visited < max_orders) {
            visited = visited + 1;
            if (market.refund_record(record_id, reason, prune, sender, now_ms)) {
                refunded = refunded + 1;
                unfinished = unfinished - 1;
            };
            record_id = record_id + 1;
        };
        // A cohort with nothing left is dropped by `advance_heads` instead.
        if (unfinished > 0 && record_id > first_id) {
            market.order_book_mut().set_cohort_first_id(index, record_id);
        };
        index = index + 1;
    };
    market.order_book_mut().advance_heads();
    refunded
}

/// Close the queue in the settling call: `resolve_head` to `next_id`, no
/// cohorts left, and any leftover escrow into market cash. Escrow holds only
/// unfinished orders' funds and none remain by now, so a leftover means
/// bookkeeping drift; it is swept and reported rather than stranded. Emits
/// `MarketPayoutsCompleted` when nothing is left to pay, which is the case only
/// for a market without a queue (a queue holds at least one record). Returns
/// whether the payout walk is complete.
fun close_queue_at_settlement(market: &mut ExpiryMarket, now_ms: u64): bool {
    let expiry_market_id = market.id();
    if (market.has_order_book()) {
        let book: &mut OrderBook = market.id.borrow_mut(order_queue::book_key());
        book.settle_queue();
        let leftover = book.withdraw_all_escrow();
        let amount = leftover.value();
        market.cash.receive(leftover);
        if (amount > 0) order_events::emit_queue_escrow_swept(expiry_market_id, amount, now_ms);
    };
    let (payout_cursor, next_id) = market.payout_progress();
    if (payout_cursor < next_id) return false;
    order_events::emit_market_payouts_completed(expiry_market_id, now_ms);
    true
}

/// The payout phase of a settled market: from the payout cursor, visit at most
/// the policy's `settle_payout_batch` records (compiled default before the
/// policy exists), paying each Open one. Stores where it stopped and emits
/// `MarketPayoutsCompleted` from the call that reaches `next_id`. Returns
/// whether the walk is complete.
fun pay_open_records(market: &mut ExpiryMarket, config: &ProtocolConfig, now_ms: u64): bool {
    let (payout_cursor, next_id) = market.payout_progress();
    if (payout_cursor == next_id) return true;
    let batch = config
        .delayed_execution_policy()
        .map!(|policy| policy.settle_payout_batch())
        .destroy_or!(deepbook_predict::config_constants::default_settle_payout_batch!());
    let end_id = payout_cursor + batch.min(next_id - payout_cursor);
    let mut record_id = payout_cursor;
    while (record_id < end_id) {
        market.pay_open_record(record_id, now_ms);
        record_id = record_id + 1;
    };
    market.order_book_mut().set_payout_cursor(end_id);
    if (end_id < next_id) return false;
    order_events::emit_market_payouts_completed(market.id(), now_ms);
    true
}

/// Pay one record of the payout walk if it is Open: its settled payout (zero
/// for a loser) goes from market cash to its receive address, and the record
/// is marked Closed with `OpenRecordSettled`. Deleted IDs and other statuses are
/// skipped. Never aborts: the walk is the only payout path for Open records, so
/// a record the market cannot pay (payout above market cash or above the settled
/// liability left) stays Open with `OpenRecordPayoutSkipped` for a later upgrade
/// to pay, and the walk moves on.
fun pay_open_record(market: &mut ExpiryMarket, record_id: u64, now_ms: u64) {
    let record = market.order_book().try_order(record_id);
    if (record.is_none()) return;
    let record = record.destroy_some();
    if (record.status() != order_queue::status_open()) return;
    let parties = record.parties();
    let order_id = record.position().order_id();
    let position = order::from_order_id(order_id);
    let payout = market.strike_exposure.settled_order_payout(&position);
    // Checked before the liability moves, so a skip changes nothing.
    let released = if (payout <= market.cash.balance()) {
        market.strike_exposure.try_process_settled_close(&position)
    } else {
        option::none()
    };
    if (released.is_none()) {
        order_events::emit_open_record_payout_skipped(
            market.id(),
            record_id,
            parties.account_id(),
            order_id,
            payout,
            now_ms,
        );
        return
    };
    market.order_book_mut().close_open_record(record_id);
    if (payout > 0) {
        balance::send_funds(market.cash.pay_authorized(payout), parties.receive_address());
    };
    order_events::emit_open_record_settled(
        market.id(),
        record_id,
        parties.account_id(),
        order_id,
        payout,
        now_ms,
    );
}

// ===== end region E3-private =====

// --- Delayed execution: shared queue helpers (S0; E agents do not edit) ---

fun has_order_book(market: &ExpiryMarket): bool {
    market.id.exists_(order_queue::book_key())
}

/// Borrow the market's `OrderBook`. The caller checks `has_order_book` first.
fun order_book(market: &ExpiryMarket): &OrderBook {
    market.id.borrow(order_queue::book_key())
}

/// Mutably borrow the market's `OrderBook`. This borrows the whole market; a
/// flow that also needs `strike_exposure`, `cash`, or `fee_incentive_balance`
/// borrows `market.id` directly so the field borrows stay disjoint.
fun order_book_mut(market: &mut ExpiryMarket): &mut OrderBook {
    market.id.borrow_mut(order_queue::book_key())
}

/// Create the market's `OrderBook` on its first queued order; the placing trader
/// pays its storage. Only placement calls it, so keeper paths never create one.
fun ensure_order_book(market: &mut ExpiryMarket, ctx: &mut TxContext) {
    if (market.has_order_book()) return;
    market.id.add(order_queue::book_key(), order_queue::new_book(ctx));
}

/// `(market cash, required cash)`, sampled after a transition for the queue events.
fun cash_figures(market: &ExpiryMarket): (u64, u64) {
    (market.cash.balance(), market.required_cash())
}

/// Refund one record through the shared refund routine, then emit its
/// `QueuedOrderRefunded`, plus `EscrowShortfall` when escrow ran short. Returns
/// whether it refunded a record: a missing or finished one is skipped. `sender`
/// is `@0x0` from `try_settle`, which has no transaction context. The caller
/// owns the book's existence and `advance_heads`.
fun refund_record(
    market: &mut ExpiryMarket,
    record_id: u64,
    reason: u8,
    prune: bool,
    sender: address,
    now_ms: u64,
): bool {
    let expiry_market_id = market.id();
    let book: &mut OrderBook = market.id.borrow_mut(order_queue::book_key());
    let outcome = book.refund_order(
        &mut market.strike_exposure,
        &mut market.cash,
        &mut market.fee_incentive_balance,
        record_id,
        reason,
        prune,
        now_ms,
    );
    if (outcome.is_none()) return false;
    let outcome = outcome.destroy_some();
    // A RefundDue record keeps its stored reason, so the event reads the record.
    let order = book.try_order(record_id).destroy_some();
    let waiting_cash_need = book.waiting_cash_need();
    let (market_cash, required_cash) = market.cash_figures();
    order_events::emit_queued_order_refunded(
        market_cash,
        required_cash,
        waiting_cash_need,
        expiry_market_id,
        record_id,
        order.parties().account_id(),
        order.kind(),
        order.result().reason(),
        outcome.escrow_returned(),
        outcome.order_fee_returned(),
        outcome.subsidy_returned(),
        outcome.position_returned(),
        sender,
        now_ms,
    );
    if (outcome.shortfall() > 0) {
        order_events::emit_escrow_shortfall(
            expiry_market_id,
            record_id,
            outcome.owed(),
            outcome.owed() - outcome.shortfall(),
            now_ms,
        );
    };
    true
}

// --- Shared by the mint and redeem flows ---
/// Compute the congestion surcharge from pre-trade EWMA state, then fold the
/// current gas price into the estimate.
#[test_only]
fun ewma_penalty(
    market: &mut ExpiryMarket,
    config: &deepbook_predict::ewma_config::EwmaConfig,
    quantity: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    let penalty = market.ewma.penalty_fee(config, quantity, ctx);
    market.ewma.update(config, clock, ctx);
    penalty
}

fun builder_fee_amount(builder_code_id: &Option<ID>, fee_amount: u64, quantity: u64): u64 {
    if (builder_code_id.is_some()) {
        math::mul_down(fee_amount, constants::builder_fee_multiplier!()).min(
            math::mul_down(quantity, constants::max_builder_fee_rate!()),
        )
    } else {
        0
    }
}

fun send_builder_fee(builder_code_id: Option<ID>, fee: Balance<USDC>) {
    if (fee.value() == 0) {
        fee.destroy_zero();
        return
    };
    let builder_code_id = builder_code_id.destroy_some();
    balance::send_funds(fee, builder_code_id.to_address());
}

fun send_referral_fee(referrer_receive_address: Option<address>, fee: Balance<USDC>) {
    if (fee.value() == 0) {
        fee.destroy_zero();
        return
    };
    balance::send_funds(fee, referrer_receive_address.destroy_some());
}

fun assert_cash_backing(market: &ExpiryMarket) {
    market.cash.assert_backing(market.payout_liability());
    assert!(
        market.cash.inventory_impact_reserve()
            >= market.strike_exposure.inventory_impact_potential(),
    );
}

// === Test-Only: retired instant-trading paths ===
// The bodies the retired public functions had, kept so tests can still seed
// account-held positions and exercise the legacy pricing.

#[test_only]
public fun live_order_value_for_testing(market: &ExpiryMarket, pricer: &Pricer, order_id: u256): u64 {
    market.assert_pricer_bound(pricer);
    let order = order::from_order_id(order_id);
    market.strike_exposure.live_order_value(pricer, &order)
}

#[test_only]
public fun quote_mint_for_testing(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    max_premium: u64,
    min_quantity: u64,
    exact_quantity: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): MintQuote {
    market.assert_live_mint_allowed(config, pricer, clock);
    let terms = market
        .strike_exposure
        .quote_mint_terms(
            pricer,
            lower_tick,
            higher_tick,
            max_premium,
            min_quantity,
            exact_quantity,
        );
    let builder_code_id: Option<ID> = option::none();
    let penalty_fee = market.ewma.penalty_fee(config.ewma_config(), terms.quantity(), ctx);
    market.compute_mint_quote(
        &terms,
        &builder_code_id,
        penalty_fee,
        config.fee_incentive_subsidy_rate(),
        clock,
    )
}

#[test_only]
public fun quote_mint_for_account_for_testing(
    market: &ExpiryMarket,
    wrapper: &AccountWrapper,
    config: &ProtocolConfig,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    max_premium: u64,
    min_quantity: u64,
    exact_quantity: bool,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): MintQuote {
    market.assert_live_mint_allowed(config, pricer, clock);
    let account = wrapper.load_account();
    let max_premium = max_premium.min(account.balance<USDC>(root, clock));
    let terms = market
        .strike_exposure
        .quote_mint_terms(
            pricer,
            lower_tick,
            higher_tick,
            max_premium,
            min_quantity,
            exact_quantity,
        );
    let builder_code_id = predict_account::builder_code_id(account);
    let penalty_fee = market.ewma.penalty_fee(config.ewma_config(), terms.quantity(), ctx);
    market.compute_mint_quote(
        &terms,
        &builder_code_id,
        penalty_fee,
        config.fee_incentive_subsidy_rate(),
        clock,
    )
}

#[test_only]
public fun quote_mint_exact_cost_for_account_for_testing(
    market: &ExpiryMarket,
    wrapper: &AccountWrapper,
    config: &ProtocolConfig,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    max_cost: u64,
    min_quantity: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): MintQuote {
    market.assert_live_mint_allowed(config, pricer, clock);
    let account = wrapper.load_account();
    let max_cost = max_cost.min(account.balance<USDC>(root, clock));
    let builder_code_id = predict_account::builder_code_id(account);
    let terms = market.quote_exact_cost_terms(
        config,
        pricer,
        lower_tick,
        higher_tick,
        &builder_code_id,
        max_cost,
        min_quantity,
        clock,
        ctx,
    );
    let penalty_fee = market.ewma.penalty_fee(config.ewma_config(), terms.quantity(), ctx);
    market.compute_mint_quote(
        &terms,
        &builder_code_id,
        penalty_fee,
        config.fee_incentive_subsidy_rate(),
        clock,
    )
}

#[test_only]
public fun mint_exact_quantity_for_testing(
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    max_cost: u64,
    max_probability: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    assert!(config.version_watermark() < constants::current_version!(), EDelayedExecutionRequired);
    market.assert_live_mint_allowed(config, pricer, clock);
    wrapper.settle<USDC>(root, clock);
    let account = wrapper.load_account_mut(auth);
    market.mint_prepared(
        account,
        config,
        pricer,
        lower_tick,
        higher_tick,
        0,
        quantity,
        true,
        max_cost,
        max_probability,
        clock,
        ctx,
    )
}

#[test_only]
public fun mint_exact_amount_for_testing(
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    max_premium: u64,
    min_quantity: u64,
    max_cost: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    assert!(config.version_watermark() < constants::current_version!(), EDelayedExecutionRequired);
    market.assert_live_mint_allowed(config, pricer, clock);
    assert!(max_cost > 0, EMintCostCapRequired);
    wrapper.settle<USDC>(root, clock);
    let max_premium = max_premium.min(wrapper.load_account().balance<USDC>(root, clock));
    let account = wrapper.load_account_mut(auth);
    market.mint_prepared(
        account,
        config,
        pricer,
        lower_tick,
        higher_tick,
        max_premium,
        min_quantity,
        false,
        max_cost,
        // `min_quantity` against `max_premium` already bounds the price paid per
        // contract, so the budget shape carries no separate probability cap.
        std::u64::max_value!(),
        clock,
        ctx,
    )
}

#[test_only]
public fun mint_exact_cost_for_testing(
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    max_cost: u64,
    min_quantity: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    assert!(config.version_watermark() < constants::current_version!(), EDelayedExecutionRequired);
    market.assert_live_mint_allowed(config, pricer, clock);
    wrapper.settle<USDC>(root, clock);
    let max_cost = max_cost.min(wrapper.load_account().balance<USDC>(root, clock));
    let account = wrapper.load_account_mut(auth);
    market.reconcile_stale_valuation_stamp(config);
    let builder_code_id = predict_account::builder_code_id(account);
    let terms = market.quote_exact_cost_terms(
        config,
        pricer,
        lower_tick,
        higher_tick,
        &builder_code_id,
        max_cost,
        min_quantity,
        clock,
        ctx,
    );
    market.mint_with_terms(account, config, pricer, terms, builder_code_id, max_cost, clock, ctx)
}

#[test_only]
public fun redeem_live_for_testing(
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    pricer: &Pricer,
    order_id: u256,
    close_quantity: u64,
    min_probability: u64,
    min_proceeds: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): Option<u256> {
    assert!(config.version_watermark() < constants::current_version!(), EDelayedExecutionRequired);
    market.assert_live_flow_allowed(config, pricer, clock);
    market.redeem_live_with_auth(
        wrapper,
        auth,
        config,
        pricer,
        order_id,
        close_quantity,
        min_probability,
        min_proceeds,
        root,
        clock,
        ctx,
    )
}
