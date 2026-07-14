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
module deepbook_predict::expiry_market;

use account::{account::{Account, AccountWrapper, Auth}, account_registry::AccountRegistry};
use deepbook_predict::{
    admin::AdminCap,
    config_events,
    constants,
    ewma::{Self, EwmaState},
    ewma_config::EwmaConfig,
    expiry_cash::{Self, ExpiryCash},
    order::{Self, Order},
    order_events,
    predict_account,
    pricing::{Self, Pricer},
    protocol_config::ProtocolConfig,
    strike_exposure::{Self, MintTerms, StrikeExposure},
    strike_exposure_config,
    valuation_mark::{Self, ValuationMark}
};
use dusdc::dusdc::DUSDC;
use fixed_math::math;
use propbook::{
    block_scholes_forward_feed::BlockScholesForwardFeed,
    block_scholes_spot_feed::BlockScholesSpotFeed,
    block_scholes_svi_feed::BlockScholesSVIFeed,
    pyth_feed::PythFeed,
    registry::OracleRegistry
};
use sui::{accumulator::AccumulatorRoot, balance::{Self, Balance}, clock::Clock, coin::Coin};

const EMintPaused: u64 = 0;
const EFullCloseRequired: u64 = 1;
const EMarketNotSettled: u64 = 2;
const EWrongPythFeed: u64 = 3;
const EMintCostAboveMax: u64 = 4;
const EMintProbabilityAboveMax: u64 = 5;
const EMintQuantityBelowMin: u64 = 6;
const EWrongPricer: u64 = 7;
const EReferenceTickObservationMissing: u64 = 8;
const EReferenceTickTimestampMismatch: u64 = 9;
const EMintRedeemSameTimestamp: u64 = 10;
const ERedeemProbabilityBelowMin: u64 = 11;
const ERedeemProceedsBelowMin: u64 = 12;
const EValuationMarkMissing: u64 = 13;

/// Per-expiry market state.
public struct ExpiryMarket has key {
    id: UID,
    /// Propbook underlying this market was created for.
    propbook_underlying_id: u32,
    expiry: u64,
    /// Terminal settlement price once exact Propbook expiry data has been recorded.
    settlement_price: Option<u64>,
    /// DUSDC custody, payout backing, and unresolved rebate reserve basis.
    cash: ExpiryCash,
    /// Sponsor-funded DUSDC available to subsidize this market's taker fees.
    fee_incentive_balance: Balance<DUSDC>,
    /// Exposure lifecycle state for this expiry's strike ticks.
    strike_exposure: StrikeExposure,
    /// Smoothed gas-price stats backing the congestion trade penalty.
    ewma: EwmaState,
    /// When true, new mints on this expiry abort. Other flows stay available.
    /// Admin sets/unsets it (version-gated); a `PauseCap` holder can force it
    /// true one-way through the registry (ungated kill switch).
    mint_paused: bool,
    /// Stored valuation mark the pool flush reads (`None` until first refresh).
    valuation_mark: Option<ValuationMark>,
}

/// Read-only all-in cost quote for a prospective live mint, in DUSDC base units.
/// `trading_fee` is the post-stake-discount fee before the sponsor subsidy, and
/// `all_in_cost` is the exact account withdrawal the same-state mint would make:
/// `net_premium + (trading_fee - fee_incentive_subsidy) + builder_fee + penalty_fee`.
public struct MintQuote has copy, drop {
    entry_probability: u64,
    net_premium: u64,
    trading_fee: u64,
    fee_incentive_subsidy: u64,
    builder_fee: u64,
    penalty_fee: u64,
    all_in_cost: u64,
}

// === Public Functions ===

/// Return the expiry market object ID.
public fun id(market: &ExpiryMarket): ID {
    market.id.to_inner()
}

/// Return the Propbook underlying this market was created for.
public fun propbook_underlying_id(market: &ExpiryMarket): u32 {
    market.propbook_underlying_id
}

/// Return the expiry timestamp in milliseconds.
public fun expiry(market: &ExpiryMarket): u64 {
    market.expiry
}

/// Return the recorded settlement price. Aborts if the market is not settled.
public fun settlement_price(market: &ExpiryMarket): u64 {
    market.settlement_price.destroy_some()
}

/// Return whether terminal settlement has been recorded for this market.
/// Public read for SDK/devInspect settlement-state checks.
public fun is_settled(market: &ExpiryMarket): bool {
    market.settlement_price.is_some()
}

/// Return the recorded settlement price, or `none` while the market is live.
/// Non-aborting companion to `settlement_price` for SDK/devInspect reads.
public fun try_settlement_price(market: &ExpiryMarket): Option<u64> {
    market.settlement_price
}

/// Return DUSDC currently held by this expiry.
public fun cash_balance(market: &ExpiryMarket): u64 {
    market.cash.balance()
}

/// Return DUSDC reserved for unresolved trading loss rebates.
public fun rebate_reserve(market: &ExpiryMarket): u64 {
    market.cash.rebate_reserve()
}

/// Return sponsor-funded DUSDC available to subsidize this market's taker fees.
public fun fee_incentive_balance(market: &ExpiryMarket): u64 {
    market.fee_incentive_balance.value()
}

/// Return the trading loss rebate rate snapshotted for this expiry.
public fun trading_loss_rebate_rate(market: &ExpiryMarket): u64 {
    market.cash.trading_loss_rebate_rate()
}

/// Return the liquidation LTV snapshotted for this expiry.
public fun liquidation_ltv(market: &ExpiryMarket): u64 {
    market.strike_exposure.liquidation_ltv()
}

/// Return the max admission leverage snapshotted for this expiry.
public fun max_admission_leverage(market: &ExpiryMarket): u64 {
    market.strike_exposure.max_admission_leverage()
}

/// Return the backing-buffer lambda snapshotted for this expiry.
public fun backing_buffer_lambda(market: &ExpiryMarket): u64 {
    market.strike_exposure.backing_buffer_lambda()
}

/// Return the trade-fee ramp window snapshotted for this expiry.
public fun expiry_fee_window_ms(market: &ExpiryMarket): u64 {
    market.strike_exposure.expiry_fee_window_ms()
}

/// Return the trade-fee ramp max multiplier snapshotted for this expiry.
public fun expiry_fee_max_multiplier(market: &ExpiryMarket): u64 {
    market.strike_exposure.expiry_fee_max_multiplier()
}

/// Return the strike tick size snapshotted for this expiry. Raw strikes are
/// derived off-chain / by the SDK as `tick * tick_size`.
public fun tick_size(market: &ExpiryMarket): u64 {
    market.strike_exposure.tick_size()
}

/// Return the coarser raw-price step that new finite mint boundaries must align to.
public fun admission_tick_size(market: &ExpiryMarket): u64 {
    market.strike_exposure.admission_tick_size()
}

/// Return the reference fine-grid tick admitted for this expiry, if it has been set.
public fun reference_tick(market: &ExpiryMarket): Option<u64> {
    market.strike_exposure.reference_tick()
}

/// Return the exact Propbook Pyth source timestamp used to derive `reference_tick`.
public fun reference_tick_source_timestamp_ms(market: &ExpiryMarket): u64 {
    market.strike_exposure.reference_tick_source_timestamp_ms()
}

/// Return buffered live reserve, or exact remaining settled payout liability once materialized.
public fun payout_liability(market: &ExpiryMarket): u64 {
    market.strike_exposure.payout_liability()
}

/// Return cash required to cover payout liability plus unresolved rebate reserve.
public fun required_cash(market: &ExpiryMarket): u64 {
    market.cash.required_cash(market.payout_liability())
}

/// Load a PTB-local live pricing snapshot for this market.
///
/// The returned `Pricer` is bound to `market.id()` and can be passed into live
/// mint, redeem, liquidation, and NAV functions in the same transaction.
public fun load_live_pricer(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_spot: &BlockScholesSpotFeed,
    bs_forward: &BlockScholesForwardFeed,
    bs_svi: &BlockScholesSVIFeed,
    clock: &Clock,
): Pricer {
    pricing::load_live_pricer(
        config.pricing_config(),
        propbook_registry,
        pyth,
        bs_spot,
        bs_forward,
        bs_svi,
        market.id(),
        market.propbook_underlying_id,
        market.expiry,
        clock,
    )
}

/// Return this expiry market's exact live NAV: free cash minus the exact
/// per-order live liability, floored at zero. This is structurally the live
/// primitive for a market-bound `Pricer`; an empty or order-free live market
/// returns free cash (zero liability).
///
/// A pure read with no backing assert: backing is owned by the payout-tree reserve
/// and proven on every trade, and the `max(0, ·)` cash floor marks a degenerate
/// (underwater) market at 0 — the correct per-market limited-recourse value, never
/// negative. `load_live_pricer` binds the propbook feeds to this market's current
/// Propbook registry mapping, rejects a past-expiry market, and gates oracle freshness.
///
/// A past-expiry market that has not settled cannot produce this pricer. There is
/// no solvency-safe NAV for an unsettled past-expiry market: the flush uses one
/// mark for both supply and withdraw, so the mark must equal the
/// settlement-dependent true value. Flows that branch on settlement call
/// `ensure_settled` first, using Propbook's exact Pyth timestamp at expiry; if no
/// exact spot exists yet, the live-pricing liveness abort remains the correct
/// failure mode.
public fun current_nav(market: &ExpiryMarket, pricer: &Pricer): u64 {
    market.assert_pricer_bound(pricer);
    let liability = market.strike_exposure.exact_live_liability(pricer);
    // Floor at 0 for this single-market READ only. A market can legitimately owe
    // more than it holds (a backing lambda below 1 admits transient shortfalls
    // that pool rebalancing later refills), so an unfloored per-market value is
    // meaningful — which is why the flush no longer consumes this function: it
    // aggregates raw `flushable_atoms` and nets shortfalls at the pool level.
    // Here the floor only keeps a devInspect/SDK read total-ordered at zero.
    market.cash.free_cash().saturating_sub(liability)
}

/// Return the live holder value of one order, gross of fees.
///
/// Already-liquidated and currently-liquidatable orders return zero; otherwise
/// this returns the order's current range value net of its static floor. Public
/// read for SDK/devInspect and external Move composition; callers must already
/// know the order belongs to the position they are valuing.
public fun order_value(market: &ExpiryMarket, pricer: &Pricer, order_id: u256): u64 {
    market.assert_pricer_bound(pricer);
    let order = order::from_order_id(order_id);
    market.strike_exposure.order_value(pricer, &order)
}

/// Return whether minting is currently paused on this expiry market.
public fun mint_paused(market: &ExpiryMarket): bool {
    market.mint_paused
}

/// Quote the all-in cost of `mint_exact_quantity` for an anonymous taker (no
/// stake discount, no builder code) without mutating any market state. Applies
/// the same live-mint gates and admission asserts as the mint path, so a quote
/// aborts exactly when the mint-side terms computation would; it does not
/// preflight account balance, slippage caps, or exposure-index capacity.
/// `penalty_fee` is computed from the pre-trade EWMA stats exactly as the mint
/// path computes its charge, so it matches a same-state, same-gas-price mint;
/// across transactions it can still drift (different gas price, or trades
/// folding observations in between). Public read for SDK/devInspect pre-trade
/// pricing.
public fun quote_mint(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    leverage: u64,
    clock: &Clock,
    ctx: &TxContext,
): MintQuote {
    market.assert_live_mint_allowed(config, pricer);
    let terms = market
        .strike_exposure
        .quote_mint_terms(pricer, lower_tick, higher_tick, quantity, leverage);
    let builder_code_id: Option<ID> = option::none();
    let penalty_fee = market.ewma.penalty_fee(config.ewma_config(), quantity, ctx);
    market.compute_mint_quote(config, &terms, 0, &builder_code_id, penalty_fee, clock)
}

/// Quote the all-in cost of `mint_exact_quantity` for one account, reading the
/// account's builder code and current `active_stake` as-is. An un-rolled stake
/// from a prior epoch quotes a smaller discount than the mint (which rolls
/// first) would apply, so the quote can only overstate cost. Same gates,
/// admission aborts, and EWMA-peek semantics as `quote_mint`. Public read for
/// SDK/devInspect pre-trade pricing.
public fun quote_mint_for_account(
    market: &ExpiryMarket,
    wrapper: &AccountWrapper,
    config: &ProtocolConfig,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    leverage: u64,
    clock: &Clock,
    ctx: &TxContext,
): MintQuote {
    market.assert_live_mint_allowed(config, pricer);
    let account = wrapper.load_account();
    let terms = market
        .strike_exposure
        .quote_mint_terms(pricer, lower_tick, higher_tick, quantity, leverage);
    let builder_code_id = predict_account::builder_code_id(account);
    let penalty_fee = market.ewma.penalty_fee(config.ewma_config(), quantity, ctx);
    market.compute_mint_quote(
        config,
        &terms,
        predict_account::active_stake(account),
        &builder_code_id,
        penalty_fee,
        clock,
    )
}

// === MintQuote Getters ===

public fun entry_probability(quote: &MintQuote): u64 {
    quote.entry_probability
}

public fun net_premium(quote: &MintQuote): u64 {
    quote.net_premium
}

public fun trading_fee(quote: &MintQuote): u64 {
    quote.trading_fee
}

public fun fee_incentive_subsidy(quote: &MintQuote): u64 {
    quote.fee_incentive_subsidy
}

public fun builder_fee(quote: &MintQuote): u64 {
    quote.builder_fee
}

public fun penalty_fee(quote: &MintQuote): u64 {
    quote.penalty_fee
}

public fun all_in_cost(quote: &MintQuote): u64 {
    quote.all_in_cost
}

/// Mint an exact live position quantity against this expiry market.
///
/// Requires the running package version to be at or above the protocol version
/// watermark, per-market mint pause to be off, trading globally enabled, a valid
/// account owner auth, a market-bound live `Pricer`, and enough expiry cash to
/// back the post-mint max payout and rebate reserve. Leverage is continuous (any
/// `L >= 1`); the derived static barrier `b = floor_shares/quantity` must sit
/// below the at-entry liquidation threshold so the order is not instantly
/// knockable. Mint fees are paid by routing a withdraw through the loaded account.
/// The position's strike range is the tick pair `(lower_tick, higher_tick]`
/// (`lower_tick = 0` is
/// `-inf`, `higher_tick = pos_inf_tick` is `+inf`); the SDK converts raw
/// strikes to ticks. `max_cost` caps the all-in DUSDC withdrawal, while
/// `max_probability` caps the quoted per-contract probability before fees.
/// Callers can pass `std::u64::max_value!()` for either uncapped guard. Returns
/// the minted order ID for future order-scoped flows.
public fun mint_exact_quantity(
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    leverage: u64,
    max_cost: u64,
    max_probability: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    market.assert_live_mint_allowed(config, pricer);
    wrapper.settle<DUSDC>(root, clock);
    let account = wrapper.load_account_mut(auth);
    let active_stake = predict_account::roll_active_stake(account, ctx);
    let removed_live_value = market
        .strike_exposure
        .liquidate_live_orders(
            pricer,
            config.trade_liquidation_budget(),
        );
    market.mark_liability_removed(removed_live_value);

    market.mint_prepared_exact_quantity(
        account,
        config,
        pricer,
        active_stake,
        lower_tick,
        higher_tick,
        quantity,
        leverage,
        max_cost,
        max_probability,
        clock,
        ctx,
    )
}

/// Mint the largest lot-rounded live position whose net premium fits inside
/// `amount`, aborting if the resulting quantity is below `min_quantity`.
///
/// Fees, builder fees, and EWMA congestion penalties are charged on top of
/// `amount`. The sizing budget is first capped to the account's available DUSDC
/// after settlement; fees still require additional available DUSDC at payment
/// time. Any unspent premium dust remains in the account because order quantity
/// must be an integer number of `position_lot_size` lots.
public fun mint_exact_amount(
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    amount: u64,
    min_quantity: u64,
    leverage: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    market.assert_live_mint_allowed(config, pricer);
    wrapper.settle<DUSDC>(root, clock);
    let amount = amount.min(wrapper.load_account().balance<DUSDC>(root, clock));
    let account = wrapper.load_account_mut(auth);
    let active_stake = predict_account::roll_active_stake(account, ctx);
    let removed_live_value = market
        .strike_exposure
        .liquidate_live_orders(
            pricer,
            config.trade_liquidation_budget(),
        );
    market.mark_liability_removed(removed_live_value);

    let quantity = market.max_mint_quantity_for_amount(
        pricer,
        lower_tick,
        higher_tick,
        amount,
        leverage,
    );
    assert!(quantity >= min_quantity, EMintQuantityBelowMin);
    market.mint_prepared_exact_quantity(
        account,
        config,
        pricer,
        active_stake,
        lower_tick,
        higher_tick,
        quantity,
        leverage,
        std::u64::max_value!(),
        std::u64::max_value!(),
        clock,
        ctx,
    )
}

/// Redeem a live order you hold account authority over.
///
/// A live order is priced and closed (partial or full), unless it is currently
/// liquidatable, in which case it is knocked out and fully closed with zero
/// payout. A liquidated tombstone is fully closed with zero payout. Settled
/// orders must use `redeem_settled`.
/// Returns `(closed_order_id, replacement_order_id)`; a replacement is present
/// only when a live partial close leaves quantity open.
///
/// Two close-side slippage floors, the mirror of mint's `max_probability` /
/// `max_cost` pair; pass `0` to disable either. `min_probability` floors the
/// quoted per-contract range probability (same units as mint's `max_probability`).
/// `min_proceeds` floors the all-in net DUSDC credited to the account
/// (`redeem_amount` minus trading fee, builder fee, and EWMA penalty), the mirror
/// of mint's all-in `max_cost`. Both only gate the live-priced path — a liquidated
/// tombstone closes at zero payout regardless, since its value is deterministic,
/// not market-quoted.
public fun redeem_live(
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
): (u256, Option<u256>) {
    market.assert_live_flow_allowed(config, pricer);
    wrapper.settle<DUSDC>(root, clock);
    let account = wrapper.load_account_mut(auth);

    let redeemed_order = order::from_order_id(order_id);
    let swept_live_value = market
        .strike_exposure
        .liquidate_live_orders(pricer, config.trade_liquidation_budget());
    let knocked_out = market.strike_exposure.liquidate_live_order(pricer, &redeemed_order);
    market.mark_liability_removed(swept_live_value + knocked_out.get_with_default(0));
    if (market.strike_exposure.is_liquidated_order(&redeemed_order)) {
        market.redeem_liquidated_order(account, &redeemed_order, close_quantity, ctx);
        return (redeemed_order.id(), option::none())
    };
    let replacement_order_id = market.redeem_live_internal(
        account,
        config,
        pricer,
        &redeemed_order,
        close_quantity,
        min_probability,
        min_proceeds,
        clock,
        ctx,
    );
    (redeemed_order.id(), replacement_order_id)
}

/// Redeem a settled order you hold account authority over.
///
/// The market must be settled already; this flow does not run live pricing or new
/// liquidation. Liquidated tombstones clear with zero payout. Requires a full close.
/// This owner-auth path remains available even when Predict app-auth automation is
/// deauthorized in the account registry.
public fun redeem_settled(
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    order_id: u256,
    close_quantity: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): (u256, Option<u256>) {
    wrapper.settle<DUSDC>(root, clock);
    let account = wrapper.load_account_mut(auth);
    market.redeem_settled_internal(
        account,
        config,
        propbook_registry,
        pyth,
        order_id,
        close_quantity,
        clock,
        ctx,
    )
}

/// Permissionlessly redeem a settled order without account-owner authority.
///
/// This keeper path uses Predict app-auth from the account registry, so
/// `deauthorize_app<PredictApp>` disables this automation. Owners can still use
/// `redeem_settled` with owner auth to redeem their own settled positions.
public fun redeem_settled_permissionless(
    market: &mut ExpiryMarket,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    order_id: u256,
    close_quantity: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): (u256, Option<u256>) {
    wrapper.settle<DUSDC>(root, clock);
    let auth = predict_account::generate_auth_as_app(account_registry);
    let account = wrapper.load_account_mut(auth);
    market.redeem_settled_internal(
        account,
        config,
        propbook_registry,
        pyth,
        order_id,
        close_quantity,
        clock,
        ctx,
    )
}

/// Run one bounded liquidation pass over active leveraged orders.
///
/// The liquidation book selects up to `budget` candidates; each knock-out emits
/// an `OrderLiquidated` event. It does not touch accounts; users clear their
/// liquidated position later through `redeem_live` or `redeem_settled`,
/// receiving no payout.
public fun liquidate(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    pricer: &Pricer,
    budget: u64,
) {
    market.assert_live_flow_allowed(config, pricer);
    let removed_live_value = market.strike_exposure.liquidate_live_orders(pricer, budget);
    market.mark_liability_removed(removed_live_value);
}

/// Try to liquidate one active leveraged order by ID; a knock-out emits an
/// `OrderLiquidated` event, and an ineligible order is a no-op.
public fun liquidate_order(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    pricer: &Pricer,
    order_id: u256,
) {
    market.assert_live_flow_allowed(config, pricer);

    let order = order::from_order_id(order_id);
    let removed = market.strike_exposure.liquidate_live_order(pricer, &order);
    market.mark_liability_removed(removed.get_with_default(0));
}

/// Set this expiry's reference fine-grid tick from the exact previous-window
/// Propbook Pyth observation. The source observation must be inserted into the
/// feed at `reference_tick_source_timestamp_ms` before this call, and the
/// normalized spot is floored to the market's `tick_size`.
public fun set_reference_tick(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
): u64 {
    config.assert_version();
    market.assert_pyth_bound(propbook_registry, pyth);

    let source_timestamp_ms = market.strike_exposure.reference_tick_source_timestamp_ms();
    let read = pyth.normalized_spot_at(source_timestamp_ms);
    assert!(read.is_some(), EReferenceTickObservationMissing);
    let read = read.destroy_some();
    assert!(
        read.read_source_timestamp_ms() == source_timestamp_ms,
        EReferenceTickTimestampMismatch,
    );

    let spot = read.read_value();
    let tick_size = market.strike_exposure.tick_size();
    let tick = spot / tick_size;
    if (market.strike_exposure.set_reference_tick(tick)) {
        config_events::emit_reference_tick_set(
            market.id(),
            market.propbook_underlying_id,
            source_timestamp_ms,
            spot,
            tick,
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

// === Public-Package Functions ===

/// Ensure terminal settlement has been recorded if Propbook has an exact Pyth spot
/// at this market's expiry timestamp. Returns whether the market is settled after
/// the attempt. This is the canonical passive settlement gate used immediately
/// before settlement-dependent branching.
public(package) fun ensure_settled(
    market: &mut ExpiryMarket,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    clock: &Clock,
): bool {
    if (market.is_settled()) return true;
    if (clock.timestamp_ms() < market.expiry) return false;
    market.assert_pyth_bound(propbook_registry, pyth);

    let read = pyth.normalized_spot_at(market.expiry);
    if (read.is_none()) return false;
    let settlement_price = read.destroy_some().read_value();
    market.settlement_price = option::some(settlement_price);
    config_events::emit_market_settled(
        market.id(),
        market.propbook_underlying_id,
        market.expiry,
        settlement_price,
        clock.timestamp_ms(),
    );
    true
}

/// Return this market's live free cash (DUSDC custody net of the rebate
/// reserve) — always current, no gate needed; cash moves never stale it.
public(package) fun free_cash(market: &ExpiryMarket): u64 {
    market.cash.free_cash()
}

/// Return the stored mark's current liability: the refresh walk's number plus
/// trade write-through since. The payout tree is never walked here — that is
/// the point: the walk ran in the refresh that stored the mark, and this read
/// loads no per-order objects. Deliberately unclamped against cash — a market
/// can legitimately owe more than it holds (a backing lambda below 1 admits
/// transient shortfalls backstopped by pool rebalancing) — and deliberately a
/// dumb fact: whether the mark is fresh enough and its drift acceptable is
/// judged by `plp`, which aggregates across markets.
public(package) fun marked_liability(market: &ExpiryMarket): u64 {
    assert!(market.valuation_mark.is_some(), EValuationMarkMissing);
    market.valuation_mark.borrow().liability()
}

/// Return the landing time of the refresh that computed the stored mark.
public(package) fun mark_computed_at_ms(market: &ExpiryMarket): u64 {
    assert!(market.valuation_mark.is_some(), EValuationMarkMissing);
    market.valuation_mark.borrow().computed_at_ms()
}

/// Measure the stored mark's potential oracle drift against the live inputs in
/// `pricer`: the worst-case single-contract price move since the walk, as a
/// fraction of full payout in FLOAT_SCALING (`valuation_mark::drift`). A
/// measurement, not a judgment — dollarization by this market's open interest
/// and the aggregate enforcement land with the `plp` aggregation fill-in.
public(package) fun mark_drift(market: &ExpiryMarket, pricer: &Pricer): u64 {
    market.assert_pricer_bound(pricer);
    assert!(market.valuation_mark.is_some(), EValuationMarkMissing);
    market.valuation_mark.borrow().drift(pricer)
}

/// Recompute this market's exact per-order live liability and store it as the
/// valuation mark the pool flush reads, replacing any prior mark. Returns the
/// stored liability.
public(package) fun record_valuation_mark(
    market: &mut ExpiryMarket,
    pricer: &Pricer,
    clock: &Clock,
): u64 {
    market.assert_pricer_bound(pricer);
    let liability = market.strike_exposure.exact_live_liability(pricer);
    market.valuation_mark = option::some(valuation_mark::new(liability, pricer, clock));
    liability
}

/// Force `mint_paused = true`. Reserved for `PauseCap` holders going through
/// `registry::pause_expiry_market_mint_pause_cap`; cannot unpause. Deliberately
/// not version-gated so the kill switch survives a version freeze.
public(package) fun pause_mint(market: &mut ExpiryMarket) {
    market.mint_paused = true;
    config_events::emit_expiry_market_mint_paused_updated(market.id(), true);
}

/// Receive pool-provided cash without interpreting pool allocation policy.
public(package) fun receive_pool_cash(market: &mut ExpiryMarket, cash: Balance<DUSDC>) {
    market.cash.receive(cash);
    market.assert_cash_backing();
}

/// Receive sponsor-funded fee incentives allocated by the pool vault.
public(package) fun receive_fee_incentives(market: &mut ExpiryMarket, incentives: Balance<DUSDC>) {
    market.fee_incentive_balance.join(incentives);
}

/// Resolve one account's settled trading-loss rebate. Returns the unearned residual
/// rebate-reserve cash and the rebate amount paid to the account.
public(package) fun claim_trading_loss_rebate(
    market: &mut ExpiryMarket,
    account: &mut Account,
    config: &ProtocolConfig,
    ctx: &mut TxContext,
): (Balance<DUSDC>, u64) {
    assert!(market.is_settled(), EMarketNotSettled);
    market.materialize_settled_liability();

    let summary = predict_account::resolve_expiry_summary(account, market.id());
    let trading_fees_paid = summary.fees_paid();
    let gross_profit = summary.gross_profit();
    if (trading_fees_paid == 0) {
        return (balance::zero(), 0)
    };

    let resolved_rebate_reserve = market
        .cash
        .resolve_rebate_reserve_for_fee_basis(trading_fees_paid);
    let eligible_rebate = resolved_rebate_reserve.saturating_sub(gross_profit);
    let active_stake = predict_account::roll_active_stake(account, ctx);
    let rebate_amount = config.stake_config().rebate_amount(eligible_rebate, active_stake);

    if (rebate_amount > 0) {
        let payout = market.cash.pay_authorized(rebate_amount);
        account.deposit<DUSDC>(payout.into_coin(ctx));
    };

    let residual_rebate_reserve = resolved_rebate_reserve - rebate_amount;
    let residual_cash = if (residual_rebate_reserve > 0) {
        market.cash.pay_authorized(residual_rebate_reserve)
    } else {
        balance::zero()
    };
    market.assert_cash_backing();
    (residual_cash, rebate_amount)
}

/// Release all unused local fee incentives back to the pool reserve.
public(package) fun release_fee_incentives(market: &mut ExpiryMarket): Balance<DUSDC> {
    let amount = market.fee_incentive_balance.value();
    if (amount == 0) return balance::zero();
    market.fee_incentive_balance.split(amount)
}

/// Release pool cash while preserving expiry-local payout and rebate backing.
public(package) fun release_pool_cash(market: &mut ExpiryMarket, amount: u64): Balance<DUSDC> {
    if (amount == 0) {
        return balance::zero()
    };
    let payout_liability = market.payout_liability();
    let released_cash = market.cash.release_surplus(amount, payout_liability);
    market.assert_cash_backing();
    released_cash
}

/// Materialize this expiry's settled payout liability and release every unit of
/// cash above it back to the pool. Used by the settled-market sweep, which then
/// deactivates the expiry and materializes its profit.
/// Returns the released cash and the terminal settlement price used for event
/// emission by the pool.
public(package) fun release_settled_pool_cash(market: &mut ExpiryMarket): (Balance<DUSDC>, u64) {
    let settlement_price = market.settlement_price();
    let settled_liability = market.materialize_settled_liability();
    let reserved_cash = market.cash.required_cash(settled_liability);
    market.cash.assert_backing(settled_liability);

    let returned_cash_amount = market.cash.balance() - reserved_cash;
    (market.release_pool_cash(returned_cash_amount), settlement_price)
}

/// Create and share a zero-cash expiry market for one Propbook underlying.
///
/// The market snapshots the underlying, accounting/admission tick sizes, and
/// per-market config and starts with zero expiry cash; it needs no live spot at
/// creation (strikes are absolute ticks, so there is no grid to center). Current
/// oracle object IDs stay in Propbook and are resolved on every priced flow.
public(package) fun create_and_share(
    config: &ProtocolConfig,
    propbook_underlying_id: u32,
    expiry: u64,
    tick_size: u64,
    admission_tick_size: u64,
    reference_tick_source_timestamp_ms: u64,
    ctx: &mut TxContext,
): ID {
    let id = object::new(ctx);
    let expiry_market_id = id.to_inner();
    let cash_config = config.expiry_cash_config_snapshot();
    let strike_exposure_config = config.strike_exposure_config_snapshot();
    let market = ExpiryMarket {
        id,
        propbook_underlying_id,
        expiry,
        settlement_price: option::none(),
        cash: expiry_cash::new(cash_config),
        fee_incentive_balance: balance::zero(),
        strike_exposure: strike_exposure::new(
            expiry_market_id,
            expiry,
            tick_size,
            admission_tick_size,
            reference_tick_source_timestamp_ms,
            strike_exposure_config,
            ctx,
        ),
        ewma: ewma::new(ctx),
        mint_paused: false,
        valuation_mark: option::none(),
    };
    transfer::share_object(market);
    expiry_market_id
}

// === Private Functions ===

/// Cache terminal payout liability in strike exposure if it has not already been cached.
fun materialize_settled_liability(market: &mut ExpiryMarket): u64 {
    let settlement = market.settlement_price();
    market.strike_exposure.materialize_settled_liability(settlement)
}

fun builder_fee_amount(builder_code_id: &Option<ID>, fee_amount: u64, quantity: u64): u64 {
    if (builder_code_id.is_some()) {
        math::mul(fee_amount, constants::builder_fee_multiplier!()).min(
            math::mul(quantity, constants::max_builder_fee_rate!()),
        )
    } else {
        0
    }
}

fun fee_incentive_subsidy_amount(market: &ExpiryMarket, fee_amount: u64): u64 {
    math::mul(fee_amount, constants::fee_incentive_subsidy_rate!()).min(market
        .fee_incentive_balance
        .value())
}

fun redeem_liquidated_order(
    market: &mut ExpiryMarket,
    account: &mut Account,
    order: &Order,
    close_quantity: u64,
    ctx: &mut TxContext,
) {
    assert!(close_quantity == order.quantity(), EFullCloseRequired);
    let position_root_id = predict_account::remove_position(
        account,
        market.id(),
        order.id(),
        ctx,
    );
    market.strike_exposure.clear_liquidated_order(order);
    order_events::emit_liquidated_order_redeemed(
        market.id(),
        account.account_id(),
        account.owner(),
        order,
        position_root_id,
    );
}

fun assert_cash_backing(market: &ExpiryMarket) {
    market.cash.assert_backing(market.payout_liability());
}

fun assert_pyth_bound(market: &ExpiryMarket, propbook_registry: &OracleRegistry, pyth: &PythFeed) {
    assert!(
        propbook_registry
            .propbook_pyth_id_for_underlying(market.propbook_underlying_id)
            .contains(&pyth.id()),
        EWrongPythFeed,
    );
}

fun assert_live_flow_allowed(market: &ExpiryMarket, config: &ProtocolConfig, pricer: &Pricer) {
    config.assert_version();
    market.assert_pricer_bound(pricer);
}

fun assert_live_mint_allowed(market: &ExpiryMarket, config: &ProtocolConfig, pricer: &Pricer) {
    config.assert_version();
    market.assert_pricer_bound(pricer);
    config.assert_trading_allowed();
    assert!(!market.mint_paused, EMintPaused);
}

fun assert_pricer_bound(market: &ExpiryMarket, pricer: &Pricer) {
    assert!(pricer.expiry_market_id() == market.id(), EWrongPricer);
}

/// Write a mint's bit-exact liability delta through to the stored valuation mark.
/// The marginal live liability of a freshly admitted order at its own pricer is
/// exactly `net_premium` (`entry_value - floor`); no-op until the first refresh
/// establishes a mark.
fun mark_liability_added(market: &mut ExpiryMarket, amount: u64) {
    if (market.valuation_mark.is_some()) {
        market.valuation_mark.borrow_mut().add_liability(amount);
    };
}

/// Write a liability decrease through to the stored valuation mark: a live
/// redeem's `redeem_amount`, or the live value a liquidation pass removed.
/// No-op until the first refresh establishes a mark.
fun mark_liability_removed(market: &mut ExpiryMarket, amount: u64) {
    if (market.valuation_mark.is_some()) {
        market.valuation_mark.borrow_mut().remove_liability(amount);
    };
}

/// Return the congestion surcharge (in DUSDC) for `quantity` from the pre-trade
/// EWMA stats, then fold the current gas price into the estimate. Penalty before
/// fold on every trade path (mint and live redeem): the trade's gas is judged
/// against the prior distribution rather than one already containing it, which
/// for mint additionally makes the charge equal what the quote functions compute
/// for the same state and gas price. Deliberate ordering divergence from
/// DeepBook core, which folds first — registered in
/// `predeploy/response-policies.md` (RP-9).
fun ewma_penalty(
    market: &mut ExpiryMarket,
    config: &EwmaConfig,
    quantity: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    let penalty = market.ewma.penalty_fee(config, quantity, ctx);
    market.ewma.update(config, clock, ctx);
    penalty
}

/// Assemble the mint cost decomposition from priced terms. The single home of
/// the mint payment formula: quotes return it as-is and the mint path settles
/// exactly these amounts, so a quote's `all_in_cost` matches the debit of a
/// same-state mint by construction.
fun compute_mint_quote(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    terms: &MintTerms,
    active_stake: u64,
    builder_code_id: &Option<ID>,
    penalty_fee: u64,
    clock: &Clock,
): MintQuote {
    let entry_probability = terms.entry_probability();
    let quantity = terms.quantity();
    let raw_fee_amount = market.strike_exposure.trading_fee(entry_probability, quantity, clock);
    let trading_fee = config.stake_config().fee_amount_after_discount(raw_fee_amount, active_stake);
    let fee_incentive_subsidy = market.fee_incentive_subsidy_amount(trading_fee);
    let builder_fee = builder_fee_amount(builder_code_id, trading_fee, quantity);
    let net_premium = terms.net_premium();
    let all_in_cost =
        net_premium + (trading_fee - fee_incentive_subsidy) + builder_fee + penalty_fee;

    MintQuote {
        entry_probability,
        net_premium,
        trading_fee,
        fee_incentive_subsidy,
        builder_fee,
        penalty_fee,
        all_in_cost,
    }
}

fun mint_prepared_exact_quantity(
    market: &mut ExpiryMarket,
    account: &mut Account,
    config: &ProtocolConfig,
    pricer: &Pricer,
    active_stake: u64,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    leverage: u64,
    max_cost: u64,
    max_probability: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    let terms = market
        .strike_exposure
        .quote_mint_terms(pricer, lower_tick, higher_tick, quantity, leverage);
    assert!(terms.entry_probability() <= max_probability, EMintProbabilityAboveMax);
    // Same pre-fold penalty the quotes compute; ewma_penalty folds after charging.
    let penalty_amount = market.ewma_penalty(config.ewma_config(), quantity, clock, ctx);
    let builder_code_id = predict_account::builder_code_id(account);
    let quote = market.compute_mint_quote(
        config,
        &terms,
        active_stake,
        &builder_code_id,
        penalty_amount,
        clock,
    );
    assert!(quote.all_in_cost <= max_cost, EMintCostAboveMax);

    let leverage = terms.leverage();
    let minted_order = market.strike_exposure.allocate_mint_order(terms);
    market.settle_mint_payment(account, &minted_order, &quote, builder_code_id, clock, ctx);
    market.mark_liability_added(quote.net_premium);
    order_events::emit_order_minted(
        market.id(),
        account.account_id(),
        account.owner(),
        builder_code_id,
        &minted_order,
        leverage,
        quote.entry_probability,
        quote.net_premium,
        quote.trading_fee,
        quote.fee_incentive_subsidy,
        quote.builder_fee,
        quote.penalty_fee,
    );
    minted_order.id()
}

fun max_mint_quantity_for_amount(
    market: &ExpiryMarket,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    amount: u64,
    leverage: u64,
): u64 {
    let entry_probability = market
        .strike_exposure
        .quote_mint_entry_probability(
            pricer,
            lower_tick,
            higher_tick,
            leverage,
        );
    let quantity = strike_exposure_config::max_quantity_for_net_premium(
        entry_probability,
        amount,
        leverage,
    );
    let lots = (quantity / constants::position_lot_size!()).min(order::max_quantity_lots());
    lots * constants::position_lot_size!()
}

fun redeem_live_internal(
    market: &mut ExpiryMarket,
    account: &mut Account,
    config: &ProtocolConfig,
    pricer: &Pricer,
    order: &Order,
    close_quantity: u64,
    min_probability: u64,
    min_proceeds: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Option<u256> {
    // Block an atomic mint -> oracle-update -> redeem: reject closing a position in
    // the same timestamp it was opened. A single transaction reads one `Clock`, so
    // equal timestamps mean the mint and redeem are in the same tx. The open time is
    // carried forward across partial closes, so seasoned positions stay closable.
    let opened_at_ms = predict_account::position_opened_at_ms(account, market.id(), order.id());
    assert!(clock.timestamp_ms() != opened_at_ms, EMintRedeemSameTimestamp);

    let active_stake = predict_account::roll_active_stake(account, ctx);
    let position_root_id = predict_account::remove_position(
        account,
        market.id(),
        order.id(),
        ctx,
    );

    let close_quote = market
        .strike_exposure
        .close_and_quote_live_order(pricer, order, close_quantity);
    let resulting_order = close_quote.resulting_order();
    let redeem_amount = close_quote.redeem_amount();
    let range_probability = close_quote.range_probability();
    // Close-side slippage floor: reject if the quoted per-contract probability has
    // slipped below the caller's bound. `0` disables.
    assert!(range_probability >= min_probability, ERedeemProbabilityBelowMin);
    let fee_amount = market
        .strike_exposure
        .trading_fee(
            range_probability,
            close_quantity,
            clock,
        )
        .min(redeem_amount);
    let fee_amount = config.stake_config().fee_amount_after_discount(fee_amount, active_stake);
    let penalty_amount = market.ewma_penalty(config.ewma_config(), close_quantity, clock, ctx);

    let replacement_order_id = if (resulting_order.id() == order.id()) {
        option::none()
    } else {
        let replacement_order_id = resulting_order.id();
        predict_account::add_position(
            account,
            market.id(),
            replacement_order_id,
            position_root_id,
            opened_at_ms,
            ctx,
        );
        option::some(replacement_order_id)
    };

    let builder_code_id = predict_account::builder_code_id(account);
    let (builder_fee_amount, penalty_amount) = market.settle_live_redeem_payment(
        account,
        redeem_amount,
        fee_amount,
        penalty_amount,
        close_quantity,
        ctx,
    );
    // Close-side all-in slippage floor: the net credited to the account is
    // `redeem_amount` minus the (post-clamp) fee, builder fee, and penalty that
    // `settle_live_redeem_payment` just deducted. Subtraction is exact — each
    // deduction is clamped at or below the running remainder inside settle. `0`
    // disables. Mirror of mint's `max_cost`.
    assert!(
        redeem_amount - fee_amount - builder_fee_amount - penalty_amount >= min_proceeds,
        ERedeemProceedsBelowMin,
    );
    market.mark_liability_removed(redeem_amount);

    order_events::emit_live_order_redeemed(
        market.id(),
        account.account_id(),
        account.owner(),
        builder_code_id,
        order,
        position_root_id,
        close_quantity,
        replacement_order_id,
        redeem_amount,
        fee_amount,
        builder_fee_amount,
        penalty_amount,
    );
    replacement_order_id
}

fun redeem_settled_internal(
    market: &mut ExpiryMarket,
    account: &mut Account,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    order_id: u256,
    close_quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (u256, Option<u256>) {
    config.assert_version();
    let redeemed_order = order::from_order_id(order_id);
    assert!(close_quantity == redeemed_order.quantity(), EFullCloseRequired);
    assert!(market.ensure_settled(propbook_registry, pyth, clock), EMarketNotSettled);

    if (market.strike_exposure.is_liquidated_order(&redeemed_order)) {
        market.redeem_liquidated_order(account, &redeemed_order, redeemed_order.quantity(), ctx);
        return (redeemed_order.id(), option::none())
    };

    let position_root_id = predict_account::remove_position(
        account,
        market.id(),
        redeemed_order.id(),
        ctx,
    );
    market.materialize_settled_liability();

    let settlement = market.settlement_price();
    let payout_amount = market.strike_exposure.close_settled_order(&redeemed_order, settlement);
    market.settle_settled_redeem_payment(account, payout_amount, ctx);

    order_events::emit_settled_order_redeemed(
        market.id(),
        account.account_id(),
        account.owner(),
        &redeemed_order,
        position_root_id,
        settlement,
        payout_amount,
    );
    (redeemed_order.id(), option::none())
}

/// Settle a mint payment per a computed quote: withdraw `all_in_cost` from the
/// account, route the builder fee and the subsidized trading fee, and keep the
/// remainder in expiry cash. The caller owns the all-in `max_cost` guard and the
/// quote derivation (`compute_mint_quote`), and passes its single
/// `builder_code_id` read so the fee amount and the routing destination cannot
/// come from different reads. The EWMA penalty rides into expiry cash as
/// surplus: it is not part of the rebate fee basis and earns no builder cut.
/// Fee incentives subsidize only the trader-paid portion of the trading fee;
/// the expiry still collects the full fee amount.
fun settle_mint_payment(
    market: &mut ExpiryMarket,
    account: &mut Account,
    order: &Order,
    quote: &MintQuote,
    builder_code_id: Option<ID>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let trader_fee_amount = quote.trading_fee - quote.fee_incentive_subsidy;

    predict_account::add_position(
        account,
        market.id(),
        order.id(),
        order.id(),
        clock.timestamp_ms(),
        ctx,
    );
    predict_account::record_gross_paid_to_expiry(account, market.id(), quote.net_premium, ctx);
    let mut payment = account.withdraw<DUSDC>(quote.all_in_cost, ctx).into_balance();
    let builder_fee_payment = payment.split(quote.builder_fee);
    send_builder_fee(builder_code_id, builder_fee_payment);
    let mut fee_payment = payment.split(trader_fee_amount);
    fee_payment.join(market.fee_incentive_balance.split(quote.fee_incentive_subsidy));
    market.collect_trade_fee(account, fee_payment, trader_fee_amount, ctx);
    // Remaining balance is the net premium plus the penalty surplus.
    market.cash.receive(payment);

    market.assert_cash_backing();
}

/// Settle a live redeem and return the builder fee and penalty actually applied.
///
/// The EWMA penalty is withheld from the payout and kept in expiry cash
/// as surplus. Like the trading fee it comes out of `redeem_amount`, so it is
/// capped at the payout left after the fee and builder cut.
fun settle_live_redeem_payment(
    market: &mut ExpiryMarket,
    account: &mut Account,
    redeem_amount: u64,
    fee_amount: u64,
    penalty_amount: u64,
    redeemed_quantity: u64,
    ctx: &mut TxContext,
): (u64, u64) {
    let builder_code_id = predict_account::builder_code_id(account);
    let builder_fee_amount = builder_fee_amount(
        &builder_code_id,
        fee_amount,
        redeemed_quantity,
    ).min(
        redeem_amount - fee_amount,
    );
    let penalty_amount = penalty_amount.min(redeem_amount - fee_amount - builder_fee_amount);

    let mut payout = market.cash.pay_authorized(redeem_amount);
    let fee = payout.split(fee_amount);
    let builder_fee = payout.split(builder_fee_amount);
    predict_account::record_gross_received_from_expiry(account, market.id(), redeem_amount, ctx);
    market.collect_trade_fee(account, fee, fee_amount, ctx);
    send_builder_fee(copy builder_code_id, builder_fee);
    // Penalty surplus stays in expiry cash rather than flowing to the redeemer.
    market.cash.receive(payout.split(penalty_amount));

    market.assert_cash_backing();
    account.deposit<DUSDC>(payout.into_coin(ctx));
    (builder_fee_amount, penalty_amount)
}

fun settle_settled_redeem_payment(
    market: &mut ExpiryMarket,
    account: &mut Account,
    payout_amount: u64,
    ctx: &mut TxContext,
) {
    predict_account::record_gross_received_from_expiry(account, market.id(), payout_amount, ctx);
    // A settled losing position pays nothing; `redeem_settled` is permissionless,
    // so guard the amount before dispensing rather than splitting/depositing a 0 coin.
    if (payout_amount > 0) {
        let payout = market.cash.pay_authorized(payout_amount);
        account.deposit<DUSDC>(payout.into_coin(ctx));
    };

    market.assert_cash_backing();
}

fun collect_trade_fee(
    market: &mut ExpiryMarket,
    account: &mut Account,
    fee: Balance<DUSDC>,
    trader_fee_amount: u64,
    ctx: &mut TxContext,
) {
    market.cash.collect_trade_fee(fee, trader_fee_amount);
    predict_account::record_trading_fee_paid(account, market.id(), trader_fee_amount, ctx);
}

fun send_builder_fee(builder_code_id: Option<ID>, fee: Balance<DUSDC>) {
    if (fee.value() == 0) {
        fee.destroy_zero();
        return
    };
    let builder_code_id = builder_code_id.destroy_some();
    balance::send_funds(fee, builder_code_id.to_address());
}
