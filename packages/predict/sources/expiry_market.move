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
/// It also owns the order-flow primitives an order-flow companion package
/// drives. `admit_mint` and `admit_sell` admit one queued order, pin a mint's
/// boundary nodes, record the order's cash need in the market's
/// `OrderFlowLedger`, and issue or advance its `OrderReceipt`. `commit` stores
/// the bounded Pyth price the order fills at, `try_fill` fills or refunds it,
/// `release` takes it out without filling, and `try_pay_settled` pays a
/// queue-held position after settlement. A queued fill never enters the
/// account: its position stays in the receipt. Admission, commit, and fill need
/// an allowlisted companion witness; release and the settled payout need only
/// the receipt. The queue itself, its escrow, its policy, and its events live in
/// the companion.
///
/// Mainnet USDC is a regulated coin: Sui aborts a transaction that sends it to
/// an address on its deny list, or to anyone while it is globally paused. So the
/// fill, the fee routing, and the settled payout read `sui::deny_list` first and
/// never send to such an address. A fill for a denied receive address is
/// refused, a denied builder or referrer's fee stays in market cash, and a
/// denied winner's payout is skipped for a later `try_pay_settled`.
module deepbook_predict::expiry_market;

use account::{account::{Account, AccountWrapper, Auth}, account_registry::AccountRegistry};
use deepbook_predict::{
    admin::AdminCap,
    config_events,
    constants,
    ewma::{Self, EwmaState},
    expiry_cash::{Self, ExpiryCash},
    order::{Self, Order},
    order_events,
    predict_account,
    pricing::{Self, Pricer, FrozenPricer, RangePrice, VolSnapshot},
    protocol_config::ProtocolConfig,
    range_codec,
    strike_exposure::{Self, LiveCloseTerms, MintRange, MintTerms, StrikeExposure}
};
use deepbook_predict_math::{lazer_price::{Self, LazerPrice}, math as pmath};
use fixed_math::math;
use propbook::{
    block_scholes_store::{BlockScholesSVIStore, BlockScholesValueStore},
    pyth_feed::PythFeed,
    registry::OracleRegistry
};
use sui::{
    accumulator::AccumulatorRoot,
    balance::{Self, Balance},
    clock::Clock,
    coin,
    deny_list::DenyList,
    dynamic_field as df,
    vec_map::{Self, VecMap}
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
const EOrderFailsLimits: u64 = 14;
const EInsufficientMarketCash: u64 = 15;
const EInvalidOrderTiming: u64 = 16;
const EInvalidOrderTerms: u64 = 17;
const EWrongMarket: u64 = 18;
const EWrongStage: u64 = 19;
const ENotRecordOwner: u64 = 20;
const EEscrowMismatch: u64 = 21;
const EWrongPrice: u64 = 22;

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

/// Predict's record of one order the order-flow companion queued, from its
/// admission until a fill, release, full close, or settled payout consumes it.
/// It can be neither copied nor dropped, and only this module builds, changes,
/// or unpacks one, so each admission's pins and cash need leave the market's
/// ledger exactly once and each position is closed or paid once.
///
/// `stage` is a `constants::receipt_stage_*` code: a mint admitted, an open
/// position, or a sell of that position admitted. Admission writes the parties,
/// request, timing, snapshot, and escrow terms; `commit` the price and the
/// reserved subsidy; a mint fill the position. Every transition writes every
/// field group (`to_open` for the open stage): the open stage keeps the parties,
/// range, last snapshot, and position and zeroes the kind, request, timing,
/// channel, escrow, and price, and a sell admission rewrites that open receipt
/// in place, so a sell cannot detach from its position and nothing from one
/// stage reaches the next. A sell refund restores the open position whole and a
/// partial close leaves `held_quantity` less the closed quantity. `budget` caps
/// a mint's all-in cost, and a fill requires escrow of at least `budget +
/// order_fee + subsidy_reserved`.
public struct OrderReceipt has store {
    expiry_market_id: ID,
    stage: u8,
    /// A `constants` mint kind, or `order_kind_sell` once a sell is admitted.
    kind: u8,
    /// The account's snapshot at the last admission.
    parties: OrderParties,
    lower_tick: u64,
    higher_tick: u64,
    /// The exact mint quantity, or the sell's close quantity.
    quantity: u64,
    max_premium: u64,
    min_quantity: u64,
    max_probability: u64,
    min_probability: u64,
    min_proceeds: u64,
    /// Earliest Pyth generation time the order may price at.
    tau_ms: u64,
    /// At or past it the order is refunded, never filled.
    deadline_ms: u64,
    /// The Lazer channel τ was planned on; the committed price must come from it.
    channel: u8,
    vol: VolSnapshot,
    budget: u64,
    order_fee: u64,
    /// Worst-case market cash the fill can consume. Counted in the ledger's
    /// `waiting_cash_need` while the order is admitted.
    cash_need: u64,
    /// The t₀ quote's pre-subsidy trading fee, capped at `budget`. Bounds the
    /// subsidy `commit` reserves.
    subsidy_bound: u64,
    subsidy_rate: u64,
    subsidy_reserved: u64,
    /// The committed Pyth price, 1e9-normalized; `0` until `commit`.
    spot: u64,
    /// The committed update's envelope, in ms. The fill prices at it.
    tick_ms: u64,
    /// The committed feed's own update time, in µs.
    generation_us: u64,
    /// The open position's order ID; `0` until the mint fills.
    order_id: u256,
    /// Stable economic-position handle, constant across partial closes.
    root_id: u256,
    opened_at_ms: u64,
    /// The open position's size, the quantity `order_id` names. The request's
    /// `quantity` is the mint or close quantity, so a sell admission never
    /// overwrites the size it closes.
    held_quantity: u64,
}

/// The account an order-flow receipt belongs to, snapshotted at each admission.
/// Grouped so a receipt stays within Sui's 32-field struct limit, and so a sell
/// admission replaces the party snapshot whole.
public struct OrderParties has copy, drop, store {
    account_id: ID,
    owner: address,
    /// Sell proceeds and the settled payout go only here.
    receive_address: address,
    referrer_account_id: Option<ID>,
    referrer_receive_address: Option<address>,
    builder_code_id: Option<ID>,
}

/// Dynamic-field key of a market's `OrderFlowLedger` under its UID.
public struct OrderFlowLedgerKey() has copy, drop, store;

/// What the admitted orders of one market hold. Created by the market's first
/// admission, so that trader pays its storage.
public struct OrderFlowLedger has store {
    /// Admitted mints per payout-tree tick (tick -> count). A pinned node is
    /// never pruned, so a fill never creates one.
    pins: VecMap<u64, u64>,
    /// Sum of the admitted orders' cash needs. `rebalance_expiry_cash` funds a
    /// live market to at least required cash plus this.
    waiting_cash_need: u64,
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
        config.pricing_cfg(),
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
        && config.is_cur_flush(market.valuation_stamp.borrow().flush_seq)
}

/// Return live marked NAV as free expiry cash minus the exposure book's marked
/// liability, floored at zero. This read requires a market-bound pre-expiry
/// `Pricer`; an expired but unsettled market cannot be valued through this path.
/// Public for PTB composition and devInspect pool valuation.
public fun current_nav(market: &ExpiryMarket, pricer: &Pricer): u64 {
    market.chk_pricer(pricer);
    let liability = market.strike_exposure.marked_liab(pricer);
    // Marked liability and free cash are computed through different rounded
    // aggregates; negative marked NAV is represented as zero.
    market.cash.free_cash().saturating_sub(liability)
}

/// Return one live order's full-close range value before fees. Requires a
/// market-bound `Pricer` and does not prove account ownership of `order_id`.
/// Public for SDK, PTB, and devInspect position valuation.
public fun live_order_value(market: &ExpiryMarket, pricer: &Pricer, order_id: u256): u64 {
    market.chk_pricer(pricer);
    let order = order::from_id(order_id);
    market.strike_exposure.live_order_value(pricer, &order)
}

/// Return one settled order's terminal payout. This function does not prove
/// account ownership of `order_id`. Public for SDK, PTB, and devInspect position
/// valuation.
public fun settled_order_payout(market: &ExpiryMarket, order_id: u256): u64 {
    assert!(market.is_settled(), EMarketNotSettled);
    let order = order::from_id(order_id);
    market.strike_exposure.settled_order_payout(&order)
}

/// Return the market mint-pause state for SDK and devInspect reads.
public fun mint_paused(market: &ExpiryMarket): bool {
    market.mint_paused
}

/// Quote a prospective mint at a market-bound `Pricer`, priced like a queued
/// fill at the clock, for SDK and devInspect previews. `exact_quantity` quotes
/// `min_quantity` exactly; otherwise the largest quantity whose premium fits
/// `max_premium`, at least `min_quantity`. No builder fee. The fee subsidy is
/// the configured rate capped by the market's incentive balance, and
/// `penalty_fee` is always 0. Gated only on the pricer binding (`EWrongPricer`)
/// and `now < expiry` (`EInvalidOrderTiming`). Aborts `EOrderFailsLimits` when
/// the mint would be refused at the clock.
public fun quote_mint(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    max_premium: u64,
    min_quantity: u64,
    exact_quantity: bool,
    clock: &Clock,
    _ctx: &mut TxContext,
): MintQuote {
    market.quote_now(
        config,
        pricer,
        if (exact_quantity) constants::mint_kind_exact_quantity!()
        else constants::mint_kind_exact_amount!(),
        lower_tick,
        higher_tick,
        max_premium,
        min_quantity,
        std::u64::max_value!(),
        &option::none(),
        clock,
    )
}

/// `quote_mint` for the wrapper's account: `max_premium` is capped at the
/// account's balance and the account's builder fee is charged.
public fun quote_mint_for_account(
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
    _ctx: &mut TxContext,
): MintQuote {
    let account = wrapper.load_account();
    market.quote_now(
        config,
        pricer,
        if (exact_quantity) constants::mint_kind_exact_quantity!()
        else constants::mint_kind_exact_amount!(),
        lower_tick,
        higher_tick,
        max_premium.min(account.balance<USDC>(root, clock)),
        min_quantity,
        std::u64::max_value!(),
        &predict_account::builder_code_id(account),
        clock,
    )
}

/// Quote the largest mint whose all-in cost fits `min(max_cost, account
/// balance)`, at least `min_quantity`, for the wrapper's account, priced like a
/// queued exact-cost fill at the clock. Charges the account's builder fee, and
/// otherwise prices and gates like `quote_mint`.
public fun quote_mint_exact_cost_for_account(
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
    _ctx: &mut TxContext,
): MintQuote {
    let account = wrapper.load_account();
    market.quote_now(
        config,
        pricer,
        constants::mint_kind_exact_cost!(),
        lower_tick,
        higher_tick,
        0,
        min_quantity,
        max_cost.min(account.balance<USDC>(root, clock)),
        &predict_account::builder_code_id(account),
        clock,
    )
}

// === Order-Flow Reads ===

/// Return `(waiting_cash_need, payout_tree_node_count, min_entry_probability)`:
/// the summed cash need of the market's admitted orders, above required cash,
/// that `rebalance_expiry_cash` keeps a live market funded with; the payout
/// tree's node count, pinned zero nodes included, which sizes the keeper's fill
/// batches; and the snapshotted minimum entry probability the SDK computes a
/// queued mint's cash need from. For SDK, keeper, and devInspect reads.
public fun order_flow_state(market: &ExpiryMarket): (u64, u64, u64) {
    (market.wait_need(), market.strike_exposure.tree_nodes(), market.strike_exposure.min_prob())
}

/// Return a receipt's `(expiry_market_id, stage, account_id, order_id,
/// pyth_source_id, cash_need, subsidy_bound, vol)`. For the order-flow
/// companion's queue events and Lazer decoding, and devInspect reads of queue
/// records.
public fun receipt_info(receipt: &OrderReceipt): (ID, u8, ID, u256, u32, u64, u64, VolSnapshot) {
    (
        receipt.expiry_market_id,
        receipt.stage,
        receipt.parties.account_id,
        receipt.order_id,
        receipt.vol.pyth_source_id(),
        receipt.cash_need,
        receipt.subsidy_bound,
        receipt.vol,
    )
}

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

// === Order-Flow Quotes ===

/// Quote an early sell of `close_quantity` of an open receipt's position at a
/// market-bound `Pricer` and the clock, charging `builder_code_id`'s builder
/// fee: the close a sell fill prices, without the trader's floors. `proceeds`
/// is before the order fee. Changes nothing. Aborts on the pricer binding
/// (`EWrongPricer`), another market's receipt (`EWrongMarket`), a receipt that
/// is not open (`EWrongStage`), `now >= expiry` (`EInvalidOrderTiming`), or a
/// close that cannot be priced (`EOrderFailsLimits`). Public for the order-flow
/// companion's sell preview and SDK reads.
public fun quote_close(
    market: &ExpiryMarket,
    pricer: &Pricer,
    receipt: &OrderReceipt,
    close_quantity: u64,
    builder_code_id: Option<ID>,
    clock: &Clock,
): RedeemQuote {
    market.chk_pricer(pricer);
    assert!(receipt.expiry_market_id == market.id(), EWrongMarket);
    assert!(receipt.stage == constants::receipt_stage_open!(), EWrongStage);
    let now = clock.timestamp_ms();
    assert!(now < market.expiry, EInvalidOrderTiming);
    let (_, quote, reason) = market.price_close(
        pricer,
        &order::from_id(receipt.order_id),
        close_quantity,
        0,
        0,
        &builder_code_id,
        now,
    );
    assert!(reason == 0, EOrderFailsLimits);
    quote
}

/// Retired by delayed execution: always aborts `EDelayedExecutionRequired`.
/// Mints are queued through the order-flow companion.
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
/// Mints are queued through the order-flow companion.
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
/// Mints are queued through the order-flow companion.
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
/// Early sells of queue-held positions go through the order-flow companion;
/// account-held positions exit through `redeem_settled` after settlement.
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
    market.chk_settled(config);
    market.rdm_settled(
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
    market.chk_settled(config);
    assert!(config.is_keeper(ctx.sender()), ENotSettledRedeemKeeper);
    let auth = predict_account::generate_auth_as_app(account_registry);
    market.rdm_settled(
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
    config.chk_version();

    let source_timestamp_ms = market.strike_exposure.reference_tick_source_timestamp_ms();
    let spot = pricing::exact_spot(
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
        config_events::ref_tick_set(
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
    config.chk_version();
    market.mint_paused = paused;
    config_events::mkt_paused(market.id(), paused);
}

/// Settle from Propbook's exact positive Pyth spot at expiry, or from the exact Block Scholes
/// minute-boundary spot when Pyth remains unavailable after the compiled grace period.
/// Permissionless and idempotent; missing or unusable observations leave the market unsettled.
///
/// Settlement reads nothing from the order-flow queue. Every admission's deadline is at least
/// `constants::deadline_expiry_margin_ms!()` before expiry, so at expiry a waiting order can
/// only be released, and the settled liability already covers every queue-held position,
/// which lives in the payout tree. The companion drains and pays its queue afterwards.
public fun try_settle(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    clock: &Clock,
): bool {
    config.chk_version();
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
    market.reconcile(config);
    if (market.is_settled()) return true;
    let now = clock.timestamp_ms();
    if (now < market.expiry) return false;

    let pyth_spot = pricing::exact_spot(
        propbook_registry,
        pyth,
        market.propbook_underlying_id,
        market.expiry,
    );
    let (settlement_price, settlement_source) = if (pyth_spot.is_some()) {
        (pyth_spot.destroy_some(), constants::settlement_source_pyth!())
    } else {
        if (now - market.expiry < constants::settlement_fallback_grace_ms!()) return false;
        let block_scholes_spot = pricing::bs_spot_at(
            propbook_registry,
            bs_values,
            market.propbook_underlying_id,
            market.expiry,
        );
        if (block_scholes_spot.is_none()) return false;
        (block_scholes_spot.destroy_some(), constants::settlement_source_block_scholes!())
    };
    market.strike_exposure.set_settled(settlement_price);
    // Live-close rebates are no longer reachable after settlement. Release the
    // residual inventory-impact escrow so the settled sweep returns it to LPs.
    market.cash.free_impact();
    config_events::mkt_settled(
        market.id(),
        market.propbook_underlying_id,
        market.expiry,
        settlement_price,
        settlement_source,
        now,
    );
    true
}

// === Order-Flow Primitives ===
// Driven by an order-flow companion package. Admission, commit, and fill take
// the companion's witness `W`, which `protocol_config::set_order_flow` must have
// allowlisted. `release` and `try_pay_settled` need only the receipt.

/// Admit one queued mint for the order-flow companion and return its receipt.
///
/// `kind` is a `constants` mint kind. The companion has already taken `budget +
/// order_fee` from the account and escrows it. `budget` caps the fill's all-in
/// cost; the companion sets it to `min(max_cost, balance - order_fee)`, and to
/// at most `quantity` for an exact-quantity mint. The order prices at a Pyth
/// price on Lazer channel `channel`, generated at or after `tau_ms`, and must
/// fill before `deadline_ms`.
///
/// Aborts unless `W` is allowlisted, the version and cutover gates pass, trading
/// and this market's mints are unpaused, and the snapshot stage is closed. The
/// timing must fit (`EInvalidOrderTiming`): `channel` a supported fixed-rate
/// channel (`lazer_price::channel_fixed_rate_*`), `tau_ms` on its grid, at most one of
/// its ticks before now, and before `deadline_ms`, τ before the no-trade window,
/// and the deadline at least
/// `constants::deadline_expiry_margin_ms!()` before expiry. Then
/// `svi_max_age_ms` must be within `constants::max_svi_max_age_ms!()` and `kind`
/// a mint kind (`EInvalidOrderTerms`), the volatility snapshot must load,
/// `budget` must be positive (`EMintCostCapRequired`), the order must pass its
/// own limits at the clock without subsidy (`EOrderFailsLimits`), and its cash
/// need must fit the market's spare cash (`EInsufficientMarketCash`). Admission
/// then pins both boundary nodes, creating them under the node cap, and adds the
/// cash need to the ledger.
public fun admit_mint<W: drop>(
    _w: W,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    account: &mut Account,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    kind: u8,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    max_premium: u64,
    min_quantity: u64,
    max_probability: u64,
    budget: u64,
    order_fee: u64,
    svi_max_age_ms: u64,
    channel: u8,
    tau_ms: u64,
    deadline_ms: u64,
    clock: &Clock,
    ctx: &TxContext,
): OrderReceipt {
    config.chk_flow<W>();
    let (vol, pricer) = market.admit_gates(
        config,
        true,
        propbook_registry,
        pyth,
        bs_values,
        bs_svi,
        svi_max_age_ms,
        channel,
        tau_ms,
        deadline_ms,
        clock,
        ctx,
    );
    assert!(budget > 0, EMintCostCapRequired);
    let builder_code_id = predict_account::builder_code_id(account);
    // The t₀ dry run is the fill's own predicate at the clock without subsidy,
    // so admission refuses exactly what a fill would refund on the same inputs.
    let (_, quote, _, reason) = market.price_mint(
        &pricer,
        kind,
        lower_tick,
        higher_tick,
        quantity,
        max_premium,
        min_quantity,
        budget,
        max_probability,
        &builder_code_id,
        0,
        0,
        clock.timestamp_ms(),
    );
    assert!(reason == 0, EOrderFailsLimits);
    // A fill pays at least `min_entry_probability` per contract into market
    // cash (`pmath::need_qty` and `need_budget`). A premium-budget fill buys no
    // more than `max_premium` allows, so a large budget does not inflate its need.
    let p = market.strike_exposure.min_prob();
    let cash_need = if (kind == constants::mint_kind_exact_quantity!()) {
        pmath::need_qty(quantity, p)
    } else if (kind == constants::mint_kind_exact_amount!()) {
        pmath::need_budget(max_premium.min(budget), p)
    } else {
        pmath::need_budget(budget, p)
    };
    // Only this order's own need, against cash above required cash: one that
    // misses at its tick never touches cash, and the fill checks cash again.
    assert!(cash_need <= market.cash.balance() - market.required_cash(), EInsufficientMarketCash);
    // Pinning both boundary nodes now means a fill never creates one.
    market.strike_exposure.ensure_nodes(lower_tick, higher_tick);
    let ledger = market.ledger_mut();
    pin(&mut ledger.pins, lower_tick);
    pin(&mut ledger.pins, higher_tick);
    ledger.waiting_cash_need = ledger.waiting_cash_need + cash_need;
    let zero = 0;
    OrderReceipt {
        expiry_market_id: market.id(),
        stage: constants::receipt_stage_mint!(),
        kind,
        parties: parties(account, builder_code_id),
        lower_tick,
        higher_tick,
        quantity,
        max_premium,
        min_quantity,
        max_probability,
        min_probability: zero,
        min_proceeds: zero,
        tau_ms,
        deadline_ms,
        channel,
        vol,
        budget,
        order_fee,
        cash_need,
        // Bounds the subsidy a commit reserves, so one order cannot soak up the
        // market's incentives.
        subsidy_bound: quote.trading_fee.min(budget),
        subsidy_rate: zero,
        subsidy_reserved: zero,
        spot: zero,
        tick_ms: zero,
        generation_us: zero,
        order_id: (zero as u256),
        root_id: (zero as u256),
        opened_at_ms: zero,
        held_quantity: zero,
    }
}

/// Admit an early sell of `close_quantity` of an open receipt's position: the
/// receipt moves to the sell stage in place, with the sell's request, the
/// account's current owner and builder code, a fresh volatility snapshot, τ, the
/// deadline, and no price. The companion escrows `order_fee` and owns the
/// minimum-sell checks.
///
/// Open during the trading pause and a market mint pause. Aborts unless `W` is
/// allowlisted, the version, cutover, and snapshot-stage gates and
/// `admit_mint`'s timing and SVI-age checks pass, the receipt is this market's
/// (`EWrongMarket`), open (`EWrongStage`), and `account`'s (`ENotRecordOwner`),
/// the volatility snapshot loads, and the close passes its own floors at the
/// clock (`EOrderFailsLimits`). Then adds the sell's cash need,
/// `ceil(close_quantity * (1 - backing_buffer_lambda)) + 1`, to the ledger: a
/// close lowers payout liability by at least `lambda * close_quantity` and pays
/// at most `close_quantity`. There is no spare-cash check. The keeper funds the
/// market before τ, and the fill refunds a sell the market cannot cover.
public fun admit_sell<W: drop>(
    _w: W,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    account: &mut Account,
    receipt: &mut OrderReceipt,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    close_quantity: u64,
    min_probability: u64,
    min_proceeds: u64,
    order_fee: u64,
    svi_max_age_ms: u64,
    channel: u8,
    tau_ms: u64,
    deadline_ms: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    config.chk_flow<W>();
    let (vol, pricer) = market.admit_gates(
        config,
        false,
        propbook_registry,
        pyth,
        bs_values,
        bs_svi,
        svi_max_age_ms,
        channel,
        tau_ms,
        deadline_ms,
        clock,
        ctx,
    );
    assert!(receipt.expiry_market_id == market.id(), EWrongMarket);
    // Canonical open: every move into the open stage goes through `to_open`,
    // and the position's size is the one its order ID names.
    assert!(receipt.stage == constants::receipt_stage_open!(), EWrongStage);
    let held = order::from_id(receipt.order_id);
    assert!(held.quantity() == receipt.held_quantity, EWrongStage);
    assert!(receipt.parties.account_id == account.account_id(), ENotRecordOwner);
    let builder_code_id = predict_account::builder_code_id(account);
    let (_, _, reason) = market.price_close(
        &pricer,
        &held,
        close_quantity,
        min_probability,
        min_proceeds,
        &builder_code_id,
        clock.timestamp_ms(),
    );
    assert!(reason == 0, EOrderFailsLimits);
    let cash_need = pmath::need_sell(
        close_quantity,
        market.strike_exposure.backing_buffer_lambda(),
    );
    let ledger = market.ledger_mut();
    ledger.waiting_cash_need = ledger.waiting_cash_need + cash_need;
    // Canonical open already zeroes the mint limits, the budget, the subsidy,
    // and the price, so only the sell column is written. The position group
    // stays, so a refund restores it whole.
    receipt.stage = constants::receipt_stage_sell!();
    receipt.kind = constants::order_kind_sell!();
    receipt.parties = parties(account, builder_code_id);
    receipt.quantity = close_quantity;
    receipt.min_probability = min_probability;
    receipt.min_proceeds = min_proceeds;
    receipt.tau_ms = tau_ms;
    receipt.deadline_ms = deadline_ms;
    receipt.channel = channel;
    receipt.vol = vol;
    receipt.order_fee = order_fee;
    receipt.cash_need = cash_need;
}

/// Commit the Pyth price an admitted order fills at: a `LazerPrice`, which only
/// the `deepbook_predict_math` library builds, from a Pyth-verified Lazer
/// update. Stores the spot, the envelope time (the tick the fill prices at),
/// and the feed's generation time. For a mint it also reserves the fee subsidy,
/// `min(subsidy_bound * fee_incentive_subsidy_rate, incentives left)`, records
/// the rate and amount, and returns the reservation for the companion to escrow
/// with the order. A sell returns a zero balance.
///
/// The price must be the receipt's: its Pyth feed and channel, an envelope at
/// exactly τ or one tick of that channel later (the backup tick), a generation
/// time between τ and the envelope, an envelope at or before now, and a
/// pricing-safe spot (`EWrongPrice`). Aborts unless `W` is allowlisted, the
/// version gate passes, the receipt is this market's (`EWrongMarket`), admitted
/// with no price yet (`EWrongStage`), and before its deadline
/// (`EInvalidOrderTiming`).
public fun commit<W: drop>(
    _w: W,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    receipt: &mut OrderReceipt,
    price: &LazerPrice,
    clock: &Clock,
): Balance<USDC> {
    config.chk_flow<W>();
    config.chk_version();
    assert!(receipt.expiry_market_id == market.id(), EWrongMarket);
    let is_mint = receipt.stage == constants::receipt_stage_mint!();
    assert!(
        (is_mint || receipt.stage == constants::receipt_stage_sell!()) && receipt.spot == 0,
        EWrongStage,
    );
    let now = clock.timestamp_ms();
    assert!(now < receipt.deadline_ms, EInvalidOrderTiming);
    chk_price(receipt, price, now);
    receipt.spot = price.spot();
    receipt.tick_ms = price.envelope_us() / 1000;
    receipt.generation_us = price.generation_us();
    if (!is_mint) return balance::zero();
    let rate = config.fee_incentive_subsidy_rate();
    let amount = math::mul_down(receipt.subsidy_bound, rate).min(market
        .fee_incentive_balance
        .value());
    receipt.subsidy_rate = rate;
    receipt.subsidy_reserved = amount;
    market.fee_incentive_balance.split(amount)
}

/// Fill or refund one committed order at its committed price and consume or
/// return its receipt. `escrow` is the order's escrowed budget, order fee, and
/// reserved subsidy. Returns `(reason, receipt to keep, escrow left over,
/// quantity, amount, trading_fee, builder_fee, referral_fee, subsidy_used,
/// inventory_impact)`. The amounts are zero on a refund. For a mint `amount` is
/// the all-in cost and `inventory_impact` the charge; for a sell `amount` is the
/// proceeds and `inventory_impact` the rebate.
///
/// Aborts only on a companion bookkeeping error: `W` not allowlisted, the
/// version, freeze, or snapshot-stage gate, another market's receipt
/// (`EWrongMarket`), a receipt not admitted or without a price (`EWrongStage`),
/// or `escrow` below `budget + order_fee + subsidy_reserved` (`EEscrowMismatch`).
/// Every market condition returns a refund reason instead, `0` for a fill: 5 at
/// or past the deadline, which also covers expiry and settlement; 9 when USDC
/// sent to the receipt's receive address would abort the transaction (`denied`:
/// the address is on USDC's deny list for the current epoch, or USDC is
/// globally paused), so nothing is sent there; 2 when no `Pricer` exists at the
/// tick; then the fill's own 1 (the order's limits), 2 (admission), 4 (a pinned
/// node is missing, a backstop), and 8 (the market's cash after the fill would
/// not cover its required cash).
///
/// A mint fill pays the premium, the trading fee net of the referral share, the
/// used subsidy, the order fee, and the inventory-impact charge into market
/// cash, sends the builder and referral fees, returns unused subsidy to the
/// incentive balance, emits `OrderMinted` with no congestion penalty, and
/// returns the receipt open. A sell fill pays the proceeds (redeem value plus
/// inventory-impact rebate, less the trading and builder fees) to the receipt's
/// receive address, keeps the trading and order fees in market cash, emits
/// `LiveOrderRedeemed`, and returns the receipt open with the replacement
/// position of a partial close, or consumes it on a full close. A builder or
/// referral fee whose recipient is denied stays in market cash instead, and the
/// events still report it as charged. A refund keeps the order fee in market
/// cash for reasons 1 and 2, returns the reserved subsidy to the incentive
/// balance, prunes a mint's emptied unpinned nodes, returns the rest of the
/// escrow, and returns a sell's receipt open or consumes a mint's. Every outcome
/// takes the order out of the ledger.
public fun try_fill<W: drop>(
    _w: W,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    mut receipt: OrderReceipt,
    mut escrow: Balance<USDC>,
    deny_list: &DenyList,
    clock: &Clock,
    ctx: &TxContext,
): (u8, Option<OrderReceipt>, Balance<USDC>, u64, u64, u64, u64, u64, u64, u64) {
    config.chk_flow<W>();
    config.chk_version();
    config.chk_no_snap();
    market.reconcile(config);
    assert!(receipt.expiry_market_id == market.id(), EWrongMarket);
    let is_mint = receipt.stage == constants::receipt_stage_mint!();
    assert!(
        (is_mint || receipt.stage == constants::receipt_stage_sell!()) && receipt.spot > 0,
        EWrongStage,
    );
    assert!(
        escrow.value() >= receipt.budget + receipt.order_fee + receipt.subsidy_reserved,
        EEscrowMismatch,
    );
    let now = clock.timestamp_ms();
    // Admission put the deadline at least `deadline_expiry_margin_ms` before
    // expiry and settlement needs `now >= expiry`, so this also refuses an
    // expired or settled market.
    let mut reason = constants::fill_reason_deadline!();
    if (now < receipt.deadline_ms) {
        // Refused before anything moves, so a fill never sends USDC where the
        // send would abort the transaction.
        reason = constants::fill_reason_recipient_denied!();
        if (!denied(deny_list, receipt.parties.receive_address, ctx)) {
            let pricer = pricing::pricer_at(
                &receipt.vol,
                receipt.spot,
                receipt.generation_us / 1000,
                receipt.tick_ms,
                market.id(),
                market.expiry,
            );
            reason = constants::fill_reason_admission!();
            if (pricer.is_some() && is_mint) {
                let (fill_reason, quote, referral_fee) = market.fill_mint(
                    config,
                    &mut receipt,
                    pricer.borrow(),
                    &mut escrow,
                    deny_list,
                    now,
                    ctx,
                );
                if (fill_reason == 0) {
                    // Allocation first, then the pins go, so the filled nodes hold
                    // the order.
                    market.unwind(&receipt, false);
                    return (
                        0,
                        option::some(to_open(receipt)),
                        escrow,
                        quote.quantity,
                        quote.all_in_cost,
                        quote.trading_fee,
                        quote.builder_fee,
                        referral_fee,
                        quote.fee_incentive_subsidy,
                        quote.inventory_impact_charge,
                    )
                };
                reason = fill_reason;
            } else if (pricer.is_some()) {
                let (fill_reason, remainder, quote) = market.fill_close(
                    &mut receipt,
                    pricer.borrow(),
                    &mut escrow,
                    deny_list,
                    now,
                    ctx,
                );
                if (fill_reason == 0) {
                    market.unwind(&receipt, false);
                    let kept = if (remainder) {
                        option::some(to_open(receipt))
                    } else {
                        drop_receipt(receipt);
                        option::none()
                    };
                    return (
                        0,
                        kept,
                        escrow,
                        quote.close_quantity,
                        quote.proceeds,
                        quote.trading_fee,
                        quote.builder_fee,
                        0,
                        0,
                        quote.inventory_impact_rebate,
                    )
                };
                reason = fill_reason;
            };
        };
    };
    let kept = market.refund_order(config, receipt, &mut escrow, reason, true);
    let zero = 0;
    (reason, kept, escrow, zero, zero, zero, zero, zero, zero, zero)
}

/// Take an admitted order out without filling it: the companion's deadline,
/// admin, and settlement-drain refunds release their receipt here. `escrow` is
/// the order's escrowed budget, order fee, and reserved subsidy, and `reason`
/// the refund's `constants::fill_reason_*` code. The order fee follows
/// `try_fill`'s refund rule: reasons 1 and 2 keep it in market cash, and every
/// other reason leaves it in the escrow returned. Returns the reservation to the
/// incentive balance, subtracts the exact cash need from the ledger, and unpins
/// a mint's boundary ticks, pruning emptied, unpinned, unretained nodes only
/// when `prune` and the market is unsettled. Returns a sell's receipt open,
/// still holding its position, or `none` for a mint's, which it consumes, and
/// the rest of the escrow.
///
/// Needs no allowlisting and checks only the version floor, so the drain works
/// while the protocol is frozen and after the witness is removed. Keeping an
/// order fee moves market cash, so like a fill it aborts inside the keeper's
/// snapshot stage (`ESnapshotInProgress`). Aborts on another market's receipt
/// (`EWrongMarket`), a receipt not admitted (`EWrongStage`), or `escrow` below
/// `budget + order_fee + subsidy_reserved` (`EEscrowMismatch`).
public fun release(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    receipt: OrderReceipt,
    mut escrow: Balance<USDC>,
    reason: u8,
    prune: bool,
): (Option<OrderReceipt>, Balance<USDC>) {
    config.chk_floor();
    assert!(receipt.expiry_market_id == market.id(), EWrongMarket);
    assert!(
        receipt.stage == constants::receipt_stage_mint!()
            || receipt.stage == constants::receipt_stage_sell!(),
        EWrongStage,
    );
    assert!(
        escrow.value() >= receipt.budget + receipt.order_fee + receipt.subsidy_reserved,
        EEscrowMismatch,
    );
    let kept = market.refund_order(config, receipt, &mut escrow, reason, prune);
    (kept, escrow)
}

/// Pay an open receipt's settled payout, zero for a loser, to its receive
/// address and consume the receipt. Returns the payout and `none`. When the
/// payout is above market cash or above the settled liability left, or a
/// nonzero payout's receive address is denied (`try_fill`'s reason 9: on
/// USDC's deny list for the current epoch, or USDC globally paused), changes
/// nothing and returns that payout with the receipt, so the companion's payout
/// walk moves on and a later call pays it once the cause clears. Needs no
/// allowlisting and checks only the version floor. Aborts on another market's
/// receipt (`EWrongMarket`), a receipt that is not open (`EWrongStage`), or an
/// unsettled market (`EMarketNotSettled`).
public fun try_pay_settled(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    receipt: OrderReceipt,
    deny_list: &DenyList,
    ctx: &TxContext,
): (u64, Option<OrderReceipt>) {
    config.chk_floor();
    assert!(receipt.expiry_market_id == market.id(), EWrongMarket);
    assert!(receipt.stage == constants::receipt_stage_open!(), EWrongStage);
    assert!(market.is_settled(), EMarketNotSettled);
    let order = order::from_id(receipt.order_id);
    let payout = market.strike_exposure.settled_order_payout(&order);
    // Every check runs before `try_settled` moves the liability, its own check
    // last, so a skip changes nothing.
    if (
        payout > market.cash.balance()
            || (payout > 0 && denied(deny_list, receipt.parties.receive_address, ctx))
            || market.strike_exposure.try_settled(&order).is_none()
    ) {
        return (payout, option::some(receipt))
    };
    if (payout > 0) {
        balance::send_funds(market.cash.pay_out(payout), receipt.parties.receive_address);
    };
    drop_receipt(receipt);
    (payout, option::none())
}

// === Public-Package Functions ===

/// Force `mint_paused = true` through the registry's `PauseCap` path. This cannot
/// unpause and does not apply the package-version gate.
public(package) fun pause_mint(market: &mut ExpiryMarket) {
    market.mint_paused = true;
    config_events::mkt_paused(market.id(), true);
}

/// Receive pool-provided cash without interpreting pool allocation policy.
public(package) fun recv_cash(market: &mut ExpiryMarket, cash: Balance<USDC>) {
    market.cash.receive(cash);
    market.chk_backed();
}

/// Receive sponsor-funded fee incentives allocated by the pool vault.
public(package) fun recv_incent(market: &mut ExpiryMarket, incentives: Balance<USDC>) {
    market.fee_incentive_balance.join(incentives);
}

/// Stamp this market for the flush freezing it: capture the two cash rows (this
/// call IS the snapshot instant) and activate the tree snapshot. A surviving
/// stamp being replaced is stale by construction — `begin_val` bumped the
/// ordinal, and a current-flush double-stamp is rejected upstream.
public(package) fun stamp_val(market: &mut ExpiryMarket, flush_seq: u64) {
    market.valuation_stamp =
        option::some(ValuationStamp {
            flush_seq,
            snapshot_cash: market.cash.balance(),
            snapshot_impact_reserve: market.cash.inventory_impact_reserve(),
        });
    market.strike_exposure.start_snap(flush_seq);
}

/// Retire the stamp once its valuation is folded, consuming the tree snapshot
/// with it (purging retained husks — this generation's or a stale one's). Later
/// trades are invisible to the folded figure: as-of-snapshot semantics.
public(package) fun clear_stamp(market: &mut ExpiryMarket) {
    market.valuation_stamp = option::none();
    // A husk a live admission pins survives: its fill inserts over it. The
    // ledger is borrowed through the UID so the exposure borrow stays disjoint.
    let no_pins = vec_map::empty<u64, u64>();
    let pins = if (market.id.exists_(OrderFlowLedgerKey())) {
        let ledger: &OrderFlowLedger = market.id.borrow(OrderFlowLedgerKey());
        &ledger.pins
    } else {
        &no_pins
    };
    market.strike_exposure.drop_snap(pins);
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
    market.chk_pricer(&pricer);
    // Defensive, structurally unreachable: the only caller is `plp::value_expiry`
    // on a frozen-live market, which its own flush's snapshot stage stamped, and
    // the stamp cannot go stale while that flush is still in flight (unit-tests
    // rule 4: documented in lieu of a bypass test).
    assert!(market.valuation_stamp.is_some(), EMarketNotPendingValuation);
    let stamp = market.valuation_stamp.borrow();
    let snapshot_free_cash = stamp.snapshot_cash.saturating_sub(stamp.snapshot_impact_reserve);
    let liability = market.strike_exposure.frozen_liab(&pricer, stamp.flush_seq);
    snapshot_free_cash.saturating_sub(liability)
}

/// Return the summed cash need of the market's admitted orders, which
/// `rebalance_expiry_cash` keeps a live market funded with above required cash.
public(package) fun wait_need(market: &ExpiryMarket): u64 {
    if (!market.id.exists_(OrderFlowLedgerKey())) return 0;
    let ledger: &OrderFlowLedger = market.id.borrow(OrderFlowLedgerKey());
    ledger.waiting_cash_need
}

/// Release all unused local fee incentives back to the pool reserve.
public(package) fun free_incent(market: &mut ExpiryMarket): Balance<USDC> {
    let amount = market.fee_incentive_balance.value();
    if (amount == 0) return balance::zero();
    market.fee_incentive_balance.split(amount)
}

/// Release pool cash while preserving expiry-local payout backing.
public(package) fun release_cash(market: &mut ExpiryMarket, amount: u64): Balance<USDC> {
    if (amount == 0) {
        return balance::zero()
    };
    let payout_liability = market.payout_liability();
    let released_cash = market.cash.free_surplus(amount, payout_liability);
    market.chk_backed();
    released_cash
}

/// Release settled cash above payout liability and the impact escrow.
public(package) fun free_settled(market: &mut ExpiryMarket): Balance<USDC> {
    let settled_liability = market.payout_liability();
    let reserved_cash = market.cash.required_cash(settled_liability);
    market.cash.chk_backing(settled_liability);

    let returned_cash_amount = market.cash.balance() - reserved_cash;
    market.release_cash(returned_cash_amount)
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
    let strike_exposure_config = config.se_snapshot();
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

#[test_only]
/// Non-production fixture: take USDC out of market cash with no liability
/// change. The only way to reach the payout walk's skip branch, which
/// production never reaches because backing keeps cash at or above the settled
/// liability. Public so the order-flow companion's settlement tests reach it.
public fun take_market_cash_for_testing(market: &mut ExpiryMarket, amount: u64): Balance<USDC> {
    market.cash.pay_out(amount)
}

#[test_only]
/// A receipt's stage, kind, request quantity, held quantity, escrow terms
/// (budget, order fee, cash need, reserved subsidy), committed spot and tick,
/// τ, deadline, and channel, for the canonical-stage checks.
public(package) fun receipt_state_for_testing(
    receipt: &OrderReceipt,
): (u8, u8, u64, u64, u64, u64, u64, u64, u64, u64, u64, u64, u8) {
    (
        receipt.stage,
        receipt.kind,
        receipt.quantity,
        receipt.held_quantity,
        receipt.budget,
        receipt.order_fee,
        receipt.cash_need,
        receipt.subsidy_reserved,
        receipt.spot,
        receipt.tick_ms,
        receipt.tau_ms,
        receipt.deadline_ms,
        receipt.channel,
    )
}

// === Private Functions ===

// --- Valuation stamp bookkeeping ---

/// Lazily discard a stale stamp (aborted or superseded flush), deactivating the
/// tree snapshot with it. Not walked here (trade path): a stale generation's
/// husks fall out at the next consumed snapshot.
fun reconcile(market: &mut ExpiryMarket, config: &ProtocolConfig) {
    if (market.valuation_stamp.is_none()) return;
    let stamp_seq = market.valuation_stamp.borrow().flush_seq;
    if (!config.is_cur_flush(stamp_seq)) {
        market.valuation_stamp = option::none();
        market.strike_exposure.stop_snap();
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
    config.chk_trading();
    assert!(!market.mint_paused, EMintPaused);
}

// Trade flows are deliberately NOT gated on the whole-flush valuation lock: a
// snapshotted market's state is captured (stamp cash + tree shadows), so trades
// run unrecorded and unbudgeted while it awaits its `value_expiry`. They ARE
// blocked while the atomic snapshot stage is open (`chk_no_snap`),
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
    config.chk_version();
    config.chk_no_snap();
    market.chk_pricer(pricer);
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
    pricer.assert_pyth_spot_fresh(config.pricing_cfg(), clock);
}

fun chk_settled(market: &ExpiryMarket, config: &ProtocolConfig) {
    config.chk_version();
    config.chk_no_snap();
    assert!(market.is_settled(), EMarketNotSettled);
}

fun chk_pricer(market: &ExpiryMarket, pricer: &Pricer) {
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
    market.reconcile(config);
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
/// and the impact charge is monotone (`mint_impact`). The probe
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
    let mut hi = range.qty_for_prem(max_cost) / lot;
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
            range.range_px(),
            quantity,
            range.range_prem(quantity),
            market.strike_exposure.mint_impact(range, quantity),
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
    order_events::minted(
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
    let builder_fee = bldr_fee_amt(builder_code_id, trading_fee, quantity);
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
    pay_builder(builder_code_id, builder_fee_payment);
    let referral_fee_payment = payment.split(referral_fee);
    pay_referral(referrer_receive_address, referral_fee_payment);
    // The remaining fee, sponsor subsidy, premium, penalty and inventory impact
    // land in the same custody; the impact amount is earmarked separately once
    // its cash has arrived.
    payment.join(market.fee_incentive_balance.split(quote.fee_incentive_subsidy));
    market.cash.receive(payment);
    market.cash.add_impact(quote.inventory_impact_charge);

    market.chk_backed();
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
    market.reconcile(config);
    wrapper.settle<USDC>(root, clock);
    let account = wrapper.load_account_mut(auth);
    let order = order::from_id(order_id);
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

    let redeem_amount = terms.redeem_amt();
    let range_probability = terms.close_prob();
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
    let builder_fee_amount = bldr_fee_amt(
        &builder_code_id,
        fee_amount,
        close_quantity,
    ).min(redeem_amount - fee_amount);
    let penalty_amount = penalty_amount.min(redeem_amount - fee_amount - builder_fee_amount);
    let inventory_impact_rebate = terms.rebate();
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
    // Boundaries a live admission pins survive the close.
    let no_pins = vec_map::empty<u64, u64>();
    let pins = if (market.id.exists_(OrderFlowLedgerKey())) {
        let ledger: &OrderFlowLedger = market.id.borrow(OrderFlowLedgerKey());
        &ledger.pins
    } else {
        &no_pins
    };
    let replacement_order = market.strike_exposure.apply_close(terms, pins);
    let position_root_id = predict_account::remove_pos(
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
    order_events::redeemed(
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

fun rdm_settled(
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
    let order = order::from_id(order_id);

    let position_root_id = predict_account::remove_pos(
        account,
        market.id(),
        order.id(),
        ctx,
    );
    let payout_amount = market.strike_exposure.settle_close(&order);
    // A settled losing position pays nothing; the settled redeem is
    // permissionless, so guard the amount before dispensing rather than
    // splitting/depositing a 0 coin.
    if (payout_amount > 0) {
        let payout = market.cash.pay_out(payout_amount);
        account.deposit<USDC>(payout.into_coin(ctx));
    };
    market.chk_backed();

    order_events::settled_rdm(
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
    let mut payout = market.cash.pay_out(redeem_amount - penalty_amount);
    payout.join(market.cash.pay_rebate(inventory_impact_rebate));
    let fee = payout.split(fee_amount);
    let builder_fee = payout.split(builder_fee_amount);
    market.cash.receive(fee);
    pay_builder(builder_code_id, builder_fee);
    market.chk_backed();
    account.deposit<USDC>(payout.into_coin(ctx));
}

// --- Order flow ---

/// The gates, timing checks, and volatility snapshot both admissions share,
/// after the caller's witness check. Returns the snapshot and the t₀ `Pricer`
/// the dry run prices with; the `Pricer` never leaves the admission.
fun admit_gates(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    is_mint: bool,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    svi_max_age_ms: u64,
    channel: u8,
    tau_ms: u64,
    deadline_ms: u64,
    clock: &Clock,
    ctx: &TxContext,
): (VolSnapshot, Pricer) {
    config.chk_version();
    config.chk_cutover();
    if (is_mint) {
        config.chk_trading();
        assert!(!market.mint_paused, EMintPaused);
    };
    config.chk_no_snap();
    market.reconcile(config);
    let expiry = market.expiry;
    // τ sits on a supported channel's grid and at most one of its ticks before
    // now. A deadline at least the margin before expiry means no admitted order
    // can fill once the market expires, so settlement never waits for the queue.
    let tick_ms = lazer_price::channel_tick_ms!(channel);
    assert!(
        (
            channel == lazer_price::channel_fixed_rate_50ms!()
                || channel == lazer_price::channel_fixed_rate_200ms!()
        )
            && tau_ms % tick_ms == 0
            && clock.timestamp_ms() <= tau_ms + tick_ms
            && tau_ms < deadline_ms
            && tau_ms + config.no_trade_window_ms() < expiry
            && deadline_ms + constants::deadline_expiry_margin_ms!() <= expiry,
        EInvalidOrderTiming,
    );
    assert!(svi_max_age_ms <= constants::max_svi_max_age_ms!(), EInvalidOrderTerms);
    pricing::load_vol(
        config.pricing_cfg(),
        propbook_registry,
        pyth,
        bs_values,
        bs_svi,
        market.id(),
        market.propbook_underlying_id,
        expiry,
        svi_max_age_ms,
        clock,
        ctx,
    )
}

/// The quote core behind the published mint previews, at tick `now` with the
/// configured subsidy rate capped by the market's incentive balance.
fun quote_now(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    pricer: &Pricer,
    kind: u8,
    lower_tick: u64,
    higher_tick: u64,
    max_premium: u64,
    min_quantity: u64,
    cost_cap: u64,
    builder_code_id: &Option<ID>,
    clock: &Clock,
): MintQuote {
    market.chk_pricer(pricer);
    let now = clock.timestamp_ms();
    assert!(now < market.expiry, EInvalidOrderTiming);
    let (_, quote, _, reason) = market.price_mint(
        pricer,
        kind,
        lower_tick,
        higher_tick,
        min_quantity,
        max_premium,
        min_quantity,
        cost_cap,
        std::u64::max_value!(),
        builder_code_id,
        config.fee_incentive_subsidy_rate(),
        market.fee_incentive_balance.value(),
        now,
    );
    assert!(reason == 0, EOrderFailsLimits);
    quote
}

/// Fill a committed mint at its tick `pricer` and return `0`, its quote, and
/// the referral fee, recording the new position in `receipt`. Otherwise return
/// the refund reason before anything moves: 1, 2, 4, or 8 (see `try_fill`). The
/// fill pays from `escrow`. No congestion penalty applies.
fun fill_mint(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    receipt: &mut OrderReceipt,
    pricer: &Pricer,
    escrow: &mut Balance<USDC>,
    deny_list: &DenyList,
    now_ms: u64,
    ctx: &TxContext,
): (u8, MintQuote, u64) {
    let tick_ms = receipt.tick_ms;
    let (terms, quote, liability_after, reason) = market.price_mint(
        pricer,
        receipt.kind,
        receipt.lower_tick,
        receipt.higher_tick,
        receipt.quantity,
        receipt.max_premium,
        receipt.min_quantity,
        receipt.budget,
        receipt.max_probability,
        &receipt.parties.builder_code_id,
        receipt.subsidy_rate,
        receipt.subsidy_reserved,
        tick_ms,
    );
    if (reason != 0) return (reason, quote, 0);
    if (!market.strike_exposure.nodes_exist(receipt.lower_tick, receipt.higher_tick)) {
        return (constants::fill_reason_missing_node!(), quote, 0)
    };
    let referral_fee = if (receipt.parties.referrer_receive_address.is_some()) {
        math::mul_down(quote.trading_fee - quote.fee_incentive_subsidy, config.referral_fee_rate())
    } else {
        0
    };
    // The non-aborting form of `chk_backed` on the post-fill state. The
    // trader's builder fee leaves with the escrow it came from, so market cash
    // gains the premium, the impact charge, the whole trading fee (subsidy
    // included) net of the referral, and the order fee. A fee kept for a denied
    // recipient only adds to that.
    let cash_after =
        market.cash.balance() + quote.premium + quote.inventory_impact_charge
        + quote.trading_fee - referral_fee + receipt.order_fee;
    let required_after =
        liability_after + market.cash.inventory_impact_reserve() + quote.inventory_impact_charge;
    if (cash_after < required_after) return (constants::fill_reason_no_cash!(), quote, 0);

    let mut payment = escrow.split(quote.all_in_cost);
    let builder = receipt.parties.builder_code_id.map!(|id| id.to_address());
    pay_fee(&mut payment, quote.builder_fee, builder, deny_list, ctx);
    pay_fee(&mut payment, referral_fee, receipt.parties.referrer_receive_address, deny_list, ctx);
    payment.join(escrow.split(quote.fee_incentive_subsidy));
    payment.join(escrow.split(receipt.order_fee));
    market.cash.receive(payment);
    market.cash.add_impact(quote.inventory_impact_charge);
    market
        .fee_incentive_balance
        .join(escrow.split(receipt.subsidy_reserved - quote.fee_incentive_subsidy));
    let minted_order = market.strike_exposure.allocate(terms.destroy_some());
    market.chk_backed();
    order_events::minted(
        market.id(),
        receipt.parties.account_id,
        receipt.parties.owner,
        receipt.parties.builder_code_id,
        receipt.parties.referrer_account_id,
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
    let order_id = minted_order.id();
    receipt.order_id = order_id;
    receipt.root_id = order_id;
    receipt.opened_at_ms = tick_ms;
    receipt.held_quantity = quote.quantity;
    (0, quote, referral_fee)
}

/// Close a committed sell's position at its tick `pricer` and return `0`,
/// whether a partial close left a remainder (recorded in `receipt` as its
/// replacement order), and the quote. Otherwise return the refund reason before
/// anything moves: 2 when the close cannot be priced, 1 below its floors, 8 when
/// the market's cash after the close would not cover its required cash.
/// Boundaries an admitted mint pins survive the close.
fun fill_close(
    market: &mut ExpiryMarket,
    receipt: &mut OrderReceipt,
    pricer: &Pricer,
    escrow: &mut Balance<USDC>,
    deny_list: &DenyList,
    now_ms: u64,
    ctx: &TxContext,
): (u8, bool, RedeemQuote) {
    let position_order = order::from_id(receipt.order_id);
    let close_quantity = receipt.quantity;
    let (terms, quote, reason) = market.price_close(
        pricer,
        &position_order,
        close_quantity,
        receipt.min_probability,
        receipt.min_proceeds,
        &receipt.parties.builder_code_id,
        receipt.tick_ms,
    );
    if (reason != 0) return (reason, false, quote);
    let terms = terms.destroy_some();
    let redeem_amount = terms.redeem_amt();
    let liability_after = market
        .strike_exposure
        .liab_closed(
            position_order.lower_tick(),
            position_order.higher_tick(),
            close_quantity,
        );
    // The non-aborting form of `chk_backed` on the post-close state:
    // cash loses the redeem value and the rebate and keeps the trading and order
    // fees, while the rebate also leaves the impact reserve, so it cancels.
    if (
        market.cash.balance() + quote.trading_fee + receipt.order_fee
            < liability_after + market.cash.inventory_impact_reserve() + redeem_amount
    ) return (constants::fill_reason_no_cash!(), false, quote);

    let replacement_order = {
        let ledger: &OrderFlowLedger = market.id.borrow(OrderFlowLedgerKey());
        market.strike_exposure.apply_close(terms, &ledger.pins)
    };
    market.cash.receive(escrow.split(receipt.order_fee));
    let mut payout = market.cash.pay_out(redeem_amount);
    payout.join(market.cash.pay_rebate(quote.inventory_impact_rebate));
    // The builder fee leaves with the trading fee's split, so a denied builder's
    // fee stays in market cash and never reaches the trader.
    let mut fees = payout.split(quote.trading_fee + quote.builder_fee);
    let builder = receipt.parties.builder_code_id.map!(|id| id.to_address());
    pay_fee(&mut fees, quote.builder_fee, builder, deny_list, ctx);
    market.cash.receive(fees);
    if (payout.value() > 0) {
        balance::send_funds(payout, receipt.parties.receive_address);
    } else {
        payout.destroy_zero();
    };
    market.chk_backed();

    let replacement_order_id = replacement_order.map!(|replacement| replacement.id());
    order_events::redeemed(
        market.id(),
        receipt.parties.account_id,
        receipt.parties.owner,
        receipt.parties.builder_code_id,
        &position_order,
        pricer,
        receipt.root_id,
        close_quantity,
        replacement_order_id,
        redeem_amount,
        quote.trading_fee,
        quote.builder_fee,
        0,
        quote.inventory_impact_rebate,
        now_ms,
    );
    let remainder = replacement_order_id.is_some();
    if (remainder) {
        receipt.order_id = replacement_order_id.destroy_some();
        receipt.held_quantity = receipt.held_quantity - close_quantity;
    };
    (0, remainder, quote)
}

/// The provenance `commit` requires of a `LazerPrice`: the receipt's Pyth feed
/// and channel, an envelope at exactly τ or one channel tick later, `τ <=
/// generation <= envelope <= now`, and a pricing-safe spot. The one place these
/// checks live.
fun chk_price(receipt: &OrderReceipt, price: &LazerPrice, now_ms: u64) {
    let tau_us = receipt.tau_ms * 1000;
    let envelope_us = price.envelope_us();
    let generation_us = price.generation_us();
    assert!(
        price.feed_id() == receipt.vol.pyth_source_id()
            && price.channel() == receipt.channel
            && (
                envelope_us == tau_us
                    || envelope_us == tau_us + lazer_price::channel_tick_ms!(receipt.channel) * 1000
            )
            && tau_us <= generation_us
            && generation_us <= envelope_us
            && envelope_us <= now_ms * 1000
            && pricing::safe_spot(price.spot()),
        EWrongPrice,
    );
}

/// Take an admitted order out of the ledger: subtract its exact cash need and,
/// for a mint, unpin its boundary ticks, pruning each emptied, unpinned,
/// unretained node when `prune` and the market is unsettled.
fun unwind(market: &mut ExpiryMarket, receipt: &OrderReceipt, prune: bool) {
    let prune = prune && !market.is_settled();
    let ledger: &mut OrderFlowLedger = market.id.borrow_mut(OrderFlowLedgerKey());
    ledger.waiting_cash_need = ledger.waiting_cash_need - receipt.cash_need;
    if (receipt.stage != constants::receipt_stage_mint!()) return;
    unpin(&mut ledger.pins, receipt.lower_tick);
    unpin(&mut ledger.pins, receipt.higher_tick);
    if (prune) {
        market.strike_exposure.prune_node(receipt.lower_tick, &ledger.pins);
        market.strike_exposure.prune_node(receipt.higher_tick, &ledger.pins);
    };
}

/// The refund every unfilled order takes, from `try_fill` or `release`: keep
/// the order fee in market cash for reasons 1 and 2 (a cash move, so never
/// inside the keeper's snapshot stage), return the reserved subsidy to the
/// incentive balance, and take the order out of the ledger. Both come out of
/// `escrow`, which keeps the rest for the trader. Returns a sell's receipt open
/// and consumes a mint's.
fun refund_order(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    receipt: OrderReceipt,
    escrow: &mut Balance<USDC>,
    reason: u8,
    prune: bool,
): Option<OrderReceipt> {
    if (
        reason == constants::fill_reason_limits!()
            || reason == constants::fill_reason_admission!()
    ) {
        config.chk_no_snap();
        market.cash.receive(escrow.split(receipt.order_fee));
    };
    market.fee_incentive_balance.join(escrow.split(receipt.subsidy_reserved));
    market.unwind(&receipt, prune);
    reopen(receipt)
}

/// After a refund or a release: a sell's receipt returns to canonical open,
/// still holding its position, and a mint's is consumed.
fun reopen(receipt: OrderReceipt): Option<OrderReceipt> {
    if (receipt.stage == constants::receipt_stage_mint!()) {
        drop_receipt(receipt);
        return option::none()
    };
    option::some(to_open(receipt))
}

/// The canonical open stage: the parties, the range, the last snapshot, and
/// the position (`order_id`, `root_id`, `opened_at_ms`, `held_quantity`) stay,
/// and the kind and every request, timing, channel, escrow, and price field is
/// zero. Every move into the open stage goes through here, after the unwind
/// accounting has read the fields it clears, so nothing from an earlier stage
/// reaches the next sell.
fun to_open(receipt: OrderReceipt): OrderReceipt {
    let OrderReceipt {
        expiry_market_id,
        parties,
        lower_tick,
        higher_tick,
        vol,
        order_id,
        root_id,
        opened_at_ms,
        held_quantity,
        ..,
    } = receipt;
    let zero = 0;
    OrderReceipt {
        expiry_market_id,
        stage: constants::receipt_stage_open!(),
        kind: (zero as u8),
        parties,
        lower_tick,
        higher_tick,
        quantity: zero,
        max_premium: zero,
        min_quantity: zero,
        max_probability: zero,
        min_probability: zero,
        min_proceeds: zero,
        tau_ms: zero,
        deadline_ms: zero,
        channel: (zero as u8),
        vol,
        budget: zero,
        order_fee: zero,
        cash_need: zero,
        subsidy_bound: zero,
        subsidy_rate: zero,
        subsidy_reserved: zero,
        spot: zero,
        tick_ms: zero,
        generation_us: zero,
        order_id,
        root_id,
        opened_at_ms,
        held_quantity,
    }
}

fun drop_receipt(receipt: OrderReceipt) {
    let OrderReceipt { .. } = receipt;
}

/// The account's party snapshot for a receipt, with the builder code the
/// caller already read for the dry run.
fun parties(account: &Account, builder_code_id: Option<ID>): OrderParties {
    OrderParties {
        account_id: account.account_id(),
        owner: account.owner(),
        receive_address: account.receive_address(),
        referrer_account_id: account.referrer_account_id(),
        referrer_receive_address: account.referrer_receive_address(),
        builder_code_id,
    }
}

/// Borrow the market's `OrderFlowLedger`, creating it on the first admission.
fun ledger_mut(market: &mut ExpiryMarket): &mut OrderFlowLedger {
    if (!market.id.exists_(OrderFlowLedgerKey())) {
        market
            .id
            .add(
                OrderFlowLedgerKey(),
                OrderFlowLedger { pins: vec_map::empty(), waiting_cash_need: 0 },
            );
    };
    market.id.borrow_mut(OrderFlowLedgerKey())
}

/// Count one more admitted mint on `tick`. The open sentinels `0` and
/// `pos_inf_tick` have no tree node, so they are never pinned.
fun pin(pins: &mut VecMap<u64, u64>, tick: u64) {
    if (tick == 0 || tick == constants::pos_inf_tick!()) return;
    if (pins.contains(&tick)) {
        let count = pins.get_mut(&tick);
        *count = *count + 1;
    } else {
        pins.insert(tick, 1);
    };
}

/// Count one fewer admitted mint on `tick`, removing the entry at zero. A tick
/// with no entry is left alone.
fun unpin(pins: &mut VecMap<u64, u64>, tick: u64) {
    if (!pins.contains(&tick)) return;
    let count = *pins.get(&tick);
    if (count > 1) {
        *pins.get_mut(&tick) = count - 1;
    } else {
        let (_, _) = pins.remove(&tick);
    };
}

// --- Tick-time quotes ---

/// Price a queued mint at a tick against its own limits. Returns the terms (or
/// `none`), the quote, the payout liability after the fill, and the refund
/// reason (`0` with terms). Admission's dry run, the fill, and the published
/// mint previews share it, so admission refuses exactly what a fill would
/// refund on the same inputs. Aborts `EInvalidOrderTerms` unless `kind` is a
/// mint kind.
///
/// Reason 2 when the range cannot be priced or leaves the entry band, misses the
/// minimum premium, or costs more than its maximum payout. Reason 1 when the
/// size is zero or below `min_quantity`, an exact-quantity order's probability is
/// above its `max_probability`, or the all-in cost is above `cost_cap`. The
/// liability comes from the range's own pre-mint book reads.
fun price_mint(
    market: &ExpiryMarket,
    pricer: &Pricer,
    kind: u8,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    max_premium: u64,
    min_quantity: u64,
    cost_cap: u64,
    max_probability: u64,
    builder_code_id: &Option<ID>,
    subsidy_rate: u64,
    subsidy_cap: u64,
    tick_ms: u64,
): (Option<MintTerms>, MintQuote, u64, u8) {
    assert!(kind <= constants::mint_kind_exact_cost!(), EInvalidOrderTerms);
    let range = market.strike_exposure.try_mint_rng(pricer, lower_tick, higher_tick);
    if (range.is_none()) {
        return (option::none(), empty_mint_q(), 0, constants::fill_reason_admission!())
    };
    let range = range.destroy_some();
    let exact_quantity = kind == constants::mint_kind_exact_quantity!();
    let quantity = if (exact_quantity) {
        quantity
    } else if (kind == constants::mint_kind_exact_amount!()) {
        range.qty_for_prem(max_premium)
    } else {
        market.cost_qty_at(
            &range,
            builder_code_id,
            cost_cap,
            subsidy_rate,
            subsidy_cap,
            tick_ms,
        )
    };
    let min_quantity = if (exact_quantity) quantity else min_quantity;
    let liability_after = market.strike_exposure.liab_minted(&range, quantity);
    let (terms, reason) = market.strike_exposure.try_terms(range, quantity, min_quantity);
    if (terms.is_none()) return (terms, empty_mint_q(), 0, reason);

    let quote = {
        let terms = terms.borrow();
        market.mint_q_at(
            terms.mint_price(),
            terms.quantity(),
            terms.premium(),
            terms.inventory_impact_charge(),
            builder_code_id,
            subsidy_rate,
            subsidy_cap,
            tick_ms,
        )
    };
    if (quote.is_none()) {
        return (option::none(), empty_mint_q(), 0, constants::fill_reason_admission!())
    };
    let quote = quote.destroy_some();
    // Same order as the live mint: probability cap, payout bound, then cost cap.
    if (exact_quantity && quote.entry_probability > max_probability) {
        return (option::none(), quote, 0, constants::fill_reason_limits!())
    };
    if (quote.all_in_cost > quote.quantity) {
        return (option::none(), quote, 0, constants::fill_reason_admission!())
    };
    if (quote.all_in_cost > cost_cap) {
        return (option::none(), quote, 0, constants::fill_reason_limits!())
    };
    (terms, quote, liability_after, 0)
}

/// Size an all-in-budget mint over `range` at a tick: `quote_exact_cost_terms`'
/// search, probed by `mint_q_at`, which is what the fill charges. The
/// largest lot-rounded quantity whose all-in cost fits `max_cost`, stepped down
/// only when that fill would cost more than its maximum payout (that bound is
/// not monotone in quantity, so it is never part of the budget search). Returns
/// the budget fill when no smaller fill clears the payout bound, which the caller
/// then refunds on that bound.
fun cost_qty_at(
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
    let mut hi = range.qty_for_prem(max_cost) / lot;
    while (lo < hi) {
        let mid = (lo + hi + 1) / 2;
        let cost = market.cost_at_tick(
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
            || market.cost_at_tick(
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
        let cost = market.cost_at_tick(
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
fun cost_at_tick(
    market: &ExpiryMarket,
    range: &MintRange,
    builder_code_id: &Option<ID>,
    quantity: u64,
    subsidy_rate: u64,
    subsidy_cap: u64,
    tick_ms: u64,
): u64 {
    market
        .mint_q_at(
            range.range_px(),
            quantity,
            range.range_prem(quantity),
            market.strike_exposure.mint_impact(range, quantity),
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
fun mint_q_at(
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
    let trading_fee = market.strike_exposure.fee_at(market.expiry, price, quantity, tick_ms);
    let fee_incentive_subsidy = math::mul_down(trading_fee, subsidy_rate).min(subsidy_cap);
    let builder_fee = bldr_fee_amt(builder_code_id, trading_fee, quantity);
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

/// Price a queued sell at a tick against its own floors. Returns the close terms
/// (or `none`), the quote, and the refund reason (`0` with terms): 2 when the
/// close cannot be priced, 1 below `min_probability` or `min_proceeds`.
/// Admission's dry run, the fill, and `quote_close` share it.
fun price_close(
    market: &ExpiryMarket,
    pricer: &Pricer,
    order: &Order,
    close_quantity: u64,
    min_probability: u64,
    min_proceeds: u64,
    builder_code_id: &Option<ID>,
    tick_ms: u64,
): (Option<LiveCloseTerms>, RedeemQuote, u8) {
    let terms = market.strike_exposure.try_close(pricer, order, close_quantity);
    if (terms.is_none()) {
        return (terms, empty_rdm_q(close_quantity), constants::fill_reason_admission!())
    };
    let quote = market.rdm_q_at(
        terms.borrow(),
        builder_code_id,
        close_quantity,
        tick_ms,
    );
    if (quote.probability < min_probability || quote.proceeds < min_proceeds) {
        return (option::none(), quote, constants::fill_reason_limits!())
    };
    (terms, quote, 0)
}

/// Price a live close's fees at `tick_ms`: the trading fee capped at the redeem
/// value and the builder fee at what remains, as `redeem_live` charged, with no
/// congestion penalty. Shared by queued sells and `quote_close`.
fun rdm_q_at(
    market: &ExpiryMarket,
    terms: &LiveCloseTerms,
    builder_code_id: &Option<ID>,
    close_quantity: u64,
    tick_ms: u64,
): RedeemQuote {
    let redeem_amount = terms.redeem_amt();
    let trading_fee = market
        .strike_exposure
        .fee_at(market.expiry, terms.close_price(), close_quantity, tick_ms)
        .min(redeem_amount);
    let builder_fee = bldr_fee_amt(builder_code_id, trading_fee, close_quantity).min(
        redeem_amount - trading_fee,
    );
    let inventory_impact_rebate = terms.rebate();
    RedeemQuote {
        close_quantity,
        probability: terms.close_prob(),
        proceeds: redeem_amount + inventory_impact_rebate - trading_fee - builder_fee,
        trading_fee,
        builder_fee,
        inventory_impact_rebate,
    }
}

/// The quote returned beside a reason when a mint is refunded before it could
/// be quoted.
fun empty_mint_q(): MintQuote {
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
fun empty_rdm_q(close_quantity: u64): RedeemQuote {
    RedeemQuote {
        close_quantity,
        probability: 0,
        proceeds: 0,
        trading_fee: 0,
        builder_fee: 0,
        inventory_impact_rebate: 0,
    }
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

fun bldr_fee_amt(builder_code_id: &Option<ID>, fee_amount: u64, quantity: u64): u64 {
    if (builder_code_id.is_some()) {
        pmath::builder_fee(
            fee_amount,
            quantity,
            constants::builder_fee_multiplier!(),
            constants::max_builder_fee_rate!(),
        )
    } else {
        0
    }
}

/// Send `amount` of `from` to `recipient`, unless the send would abort the
/// transaction (`denied`): then the fee stays in `from`, which the caller moves
/// into market cash. `recipient` is read only for a nonzero fee.
fun pay_fee(
    from: &mut Balance<USDC>,
    amount: u64,
    recipient: Option<address>,
    deny_list: &DenyList,
    ctx: &TxContext,
) {
    if (amount == 0) return;
    let recipient = recipient.destroy_some();
    if (!denied(deny_list, recipient, ctx)) balance::send_funds(from.split(amount), recipient);
}

/// Whether USDC sent to `recipient` would abort this transaction. Sui refuses
/// a regulated coin to an address on its deny list, and to every address while
/// the coin is globally paused, both read for the current epoch, as the
/// transaction's own check reads them. Never true for an unregulated USDC.
fun denied(deny_list: &DenyList, recipient: address, ctx: &TxContext): bool {
    coin::deny_list_v2_contains_current_epoch<USDC>(deny_list, recipient, ctx)
        || coin::deny_list_v2_is_global_pause_enabled_current_epoch<USDC>(deny_list, ctx)
}

#[test_only]
fun pay_builder(builder_code_id: Option<ID>, fee: Balance<USDC>) {
    if (fee.value() == 0) {
        fee.destroy_zero();
        return
    };
    let builder_code_id = builder_code_id.destroy_some();
    balance::send_funds(fee, builder_code_id.to_address());
}

#[test_only]
fun pay_referral(referrer_receive_address: Option<address>, fee: Balance<USDC>) {
    if (fee.value() == 0) {
        fee.destroy_zero();
        return
    };
    balance::send_funds(fee, referrer_receive_address.destroy_some());
}

fun chk_backed(market: &ExpiryMarket) {
    market.cash.chk_backing(market.payout_liability());
    assert!(
        market.cash.inventory_impact_reserve()
            >= market.strike_exposure.impact_pot(),
    );
}

// === Test-Only: retired instant-trading paths ===
// The bodies the retired public functions had, kept so tests can still seed
// account-held positions and exercise the legacy pricing.

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
    market.reconcile(config);
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
