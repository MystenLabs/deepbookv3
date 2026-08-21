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
    range_codec,
    strike_exposure::{Self, MintTerms, StrikeExposure},
    strike_exposure_config
};
use dusdc::dusdc::DUSDC;
use fixed_math::math;
use propbook::{
    block_scholes_store::{BlockScholesSVIStore, BlockScholesValueStore},
    pyth_feed::PythFeed,
    registry::OracleRegistry
};
use sui::{accumulator::AccumulatorRoot, balance::{Self, Balance}, clock::Clock, coin::Coin};

const EMintPaused: u64 = 0;
const EMarketNotSettled: u64 = 1;
const EMintCostAboveMax: u64 = 2;
const EMintProbabilityAboveMax: u64 = 3;
const EWrongPricer: u64 = 4;
const EReferenceTickObservationMissing: u64 = 5;
const EMintRedeemSameTimestamp: u64 = 6;
const ERedeemProbabilityBelowMin: u64 = 7;
const ERedeemProceedsBelowMin: u64 = 8;
const EMintCostCapRequired: u64 = 9;

/// Per-expiry market state.
public struct ExpiryMarket has key {
    id: UID,
    /// Propbook underlying this market was created for.
    propbook_underlying_id: u32,
    expiry: u64,
    /// DUSDC custody and payout backing.
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
}

/// Read-only all-in cost quote for a prospective live mint, in DUSDC base units.
/// `quantity` is the exact requested quantity or the conservatively budget-sized
/// fill. `trading_fee` is the trading fee before the sponsor subsidy, and
/// `all_in_cost` is the resulting account withdrawal:
/// `premium + (trading_fee - fee_incentive_subsidy) + builder_fee + penalty_fee
/// + inventory_impact_charge`. Inventory impact is isolated from every ordinary
/// fee policy because it is escrowed for risk-reducing live closes. `referral_fee`
/// is split from the trader-paid trading fee and penalty and does not increase
/// `all_in_cost`.
public struct MintQuote has copy, drop {
    quantity: u64,
    entry_probability: u64,
    premium: u64,
    trading_fee: u64,
    fee_incentive_subsidy: u64,
    builder_fee: u64,
    penalty_fee: u64,
    referral_fee: u64,
    inventory_impact_charge: u64,
    all_in_cost: u64,
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

/// Return expiry DUSDC custody for SDK and devInspect state reads.
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

/// Return the immutable DUSDC scale of this market's inventory-impact curve for
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

/// Return one live order's full-close range value before fees. Requires a
/// market-bound `Pricer` and does not prove account ownership of `order_id`.
/// Public for SDK, PTB, and devInspect position valuation.
public fun live_order_value(market: &ExpiryMarket, pricer: &Pricer, order_id: u256): u64 {
    market.assert_pricer_bound(pricer);
    let order = order::from_order_id(order_id);
    market.strike_exposure.live_order_value(pricer, &order)
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

/// Quote the all-in cost of a mint request for an anonymous taker (no builder
/// code) without mutating any market state.
/// Exact-quantity mode uses `min_quantity`; budget mode conservatively sizes a
/// lot-rounded fill under `max_premium`. The quote applies live-mint and admission
/// gates but does not preflight account balance, slippage caps, or exposure-index
/// capacity. Its penalty uses the current pre-update EWMA state. Public for SDK
/// and devInspect pre-trade pricing.
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
    ctx: &mut TxContext,
): MintQuote {
    market.assert_live_mint_allowed(config, pricer);
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
        false,
        config.referral_fee_rate(),
        penalty_fee,
        clock,
    )
}

/// Quote the all-in cost of a mint request for one account, reading its builder
/// code and referral attribution. Budget mode caps premium by total account
/// balance, including unsettled accumulator funds. Public for SDK and devInspect
/// pre-trade pricing.
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
    ctx: &mut TxContext,
): MintQuote {
    market.assert_live_mint_allowed(config, pricer);
    let account = wrapper.load_account();
    let max_premium = max_premium.min(account.balance<DUSDC>(root, clock));
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
        account.referrer_receive_address().is_some(),
        config.referral_fee_rate(),
        penalty_fee,
        clock,
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

/// Return the quoted fee routed to the referrer without increasing account cost.
public fun referral_fee(quote: &MintQuote): u64 {
    quote.referral_fee
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

/// Mint an exact live position quantity against this expiry market.
///
/// Requires the running package version to be at or above the protocol version
/// watermark, per-market mint pause to be off, trading globally enabled, valid
/// owner or authorized-app account auth, a market-bound live `Pricer`, and enough
/// expiry cash to back the post-mint max payout. Mint fees are paid by routing a
/// withdraw through the loaded account.
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
    max_cost: u64,
    max_probability: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    market.assert_live_mint_allowed(config, pricer);
    wrapper.settle<DUSDC>(root, clock);
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

/// Mint a conservatively sized lot-rounded position whose premium does not
/// exceed `max_premium`. The result may be one lot below the largest fitting
/// quantity and must meet `min_quantity`.
///
/// Fees, builder fees, and EWMA congestion penalties are charged on top of
/// `max_premium`, so `max_cost` — not `max_premium` — bounds the all-in DUSDC
/// withdrawal (`premium + trader-paid fee + builder_fee + EWMA penalty`).
/// `max_cost` is required: unlike `mint_exact_quantity`'s guards there is no
/// value that disables it, because the budget shape exists to bound spend. The
/// sizing budget is first capped to the account's available DUSDC after
/// settlement; fees still require additional available DUSDC at payment time.
/// Any unspent premium dust remains in the account because order quantity must
/// be an integer number of `position_lot_size` lots.
public fun mint_exact_amount(
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
    market.assert_live_mint_allowed(config, pricer);
    assert!(max_cost > 0, EMintCostCapRequired);
    wrapper.settle<DUSDC>(root, clock);
    let max_premium = max_premium.min(wrapper.load_account().balance<DUSDC>(root, clock));
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

/// Redeem a live order you hold account authority over.
///
/// A live order is priced and closed (partial or full). Settled orders must use
/// `redeem_settled`.
/// Returns a replacement order ID only when a partial close leaves quantity open.
///
/// Two close-side slippage floors, the mirror of mint's `max_probability` /
/// `max_cost` pair; pass `0` to disable either. `min_probability` floors the
/// quoted per-contract range probability (same units as mint's `max_probability`).
/// `min_proceeds` floors the all-in net DUSDC credited to the account
/// (`redeem_amount` minus trading fee, builder fee, and EWMA penalty), the mirror
/// of mint's all-in `max_cost`.
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
): Option<u256> {
    market.assert_live_flow_allowed(config, pricer);
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
    order_id: u256,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    market.assert_settled_flow_allowed(config);
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
/// normalized spot is floored to the market's `tick_size`.
public fun set_reference_tick(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    clock: &Clock,
): u64 {
    config.assert_version();
    config.assert_not_valuation_in_progress();

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

/// Settle from Propbook's exact positive normalized Pyth spot at expiry and
/// materialize terminal payout liability. Permissionless and idempotent; a missing
/// or non-normalizable observation leaves the market unsettled.
public fun try_settle(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    clock: &Clock,
): bool {
    config.assert_version();
    if (market.is_settled()) return true;
    if (clock.timestamp_ms() < market.expiry) return false;

    let spot = pricing::load_exact_spot(
        propbook_registry,
        pyth,
        market.propbook_underlying_id,
        market.expiry,
    );
    if (spot.is_none()) return false;
    let settlement_price = spot.destroy_some();
    market.strike_exposure.record_settlement(settlement_price);
    // Live-close rebates are no longer reachable after settlement. Release the
    // residual inventory-impact escrow so the settled sweep returns it to LPs.
    market.cash.release_inventory_impact_reserve();
    config_events::emit_market_settled(
        market.id(),
        market.propbook_underlying_id,
        market.expiry,
        settlement_price,
        clock.timestamp_ms(),
    );
    true
}

// === Public-Package Functions ===

/// Force `mint_paused = true` through the registry's `PauseCap` path. This cannot
/// unpause and does not apply the package-version gate.
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

/// Release all unused local fee incentives back to the pool reserve.
public(package) fun release_fee_incentives(market: &mut ExpiryMarket): Balance<DUSDC> {
    let amount = market.fee_incentive_balance.value();
    if (amount == 0) return balance::zero();
    market.fee_incentive_balance.split(amount)
}

/// Release pool cash while preserving expiry-local payout backing.
public(package) fun release_pool_cash(market: &mut ExpiryMarket, amount: u64): Balance<DUSDC> {
    if (amount == 0) {
        return balance::zero()
    };
    let payout_liability = market.payout_liability();
    let released_cash = market.cash.release_surplus(amount, payout_liability);
    market.assert_cash_backing();
    released_cash
}

/// Release settled cash above payout liability and the impact escrow.
public(package) fun release_settled_pool_cash(market: &mut ExpiryMarket): Balance<DUSDC> {
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
    };
    transfer::share_object(market);
    expiry_market_id
}

// === Private Functions ===

// --- Gates: the first call of every public entry ---
fun assert_live_mint_allowed(market: &ExpiryMarket, config: &ProtocolConfig, pricer: &Pricer) {
    market.assert_live_flow_allowed(config, pricer);
    config.assert_trading_allowed();
    assert!(!market.mint_paused, EMintPaused);
}

fun assert_live_flow_allowed(market: &ExpiryMarket, config: &ProtocolConfig, pricer: &Pricer) {
    config.assert_version();
    config.assert_not_valuation_in_progress();
    market.assert_pricer_bound(pricer);
}

fun assert_settled_flow_allowed(market: &ExpiryMarket, config: &ProtocolConfig) {
    config.assert_version();
    config.assert_not_valuation_in_progress();
    assert!(market.is_settled(), EMarketNotSettled);
}

fun assert_pricer_bound(market: &ExpiryMarket, pricer: &Pricer) {
    assert!(pricer.expiry_market_id() == market.id(), EWrongPricer);
}

// --- Mint flow ---
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
    // Same pre-fold penalty the quotes compute; ewma_penalty folds after charging.
    let penalty_amount = market.ewma_penalty(config.ewma_config(), terms.quantity(), clock, ctx);
    let builder_code_id = predict_account::builder_code_id(account);
    let referrer_account_id = account.referrer_account_id();
    let referrer_receive_address = account.referrer_receive_address();
    let quote = market.compute_mint_quote(
        &terms,
        &builder_code_id,
        referrer_receive_address.is_some(),
        config.referral_fee_rate(),
        penalty_amount,
        clock,
    );
    assert!(quote.all_in_cost <= max_cost, EMintCostAboveMax);

    let minted_order = market.strike_exposure.allocate_mint_order(terms);
    market.settle_mint_payment(
        account,
        &minted_order,
        &quote,
        builder_code_id,
        referrer_receive_address,
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
        quote.referral_fee,
        quote.inventory_impact_charge,
        clock.timestamp_ms(),
    );
    minted_order.id()
}

/// Assemble the cost decomposition shared by mint quotes and execution.
fun compute_mint_quote(
    market: &ExpiryMarket,
    terms: &MintTerms,
    builder_code_id: &Option<ID>,
    has_referrer: bool,
    referral_fee_rate: u64,
    penalty_fee: u64,
    clock: &Clock,
): MintQuote {
    let entry_probability = terms.entry_probability();
    let quantity = terms.quantity();
    let trading_fee = market
        .strike_exposure
        .trading_fee(market.expiry, entry_probability, quantity, clock);
    let fee_incentive_subsidy = market.fee_incentive_subsidy_amount(trading_fee);
    let builder_fee = builder_fee_amount(builder_code_id, trading_fee, quantity);
    let referral_fee = if (has_referrer) {
        let referral_fee_basis = trading_fee - fee_incentive_subsidy + penalty_fee;
        math::mul_down(referral_fee_basis, referral_fee_rate)
    } else {
        0
    };
    let premium = terms.premium();
    let inventory_impact_charge = terms.inventory_impact_charge();
    let all_in_cost =
        premium
        + (trading_fee - fee_incentive_subsidy)
        + builder_fee
        + penalty_fee
        + inventory_impact_charge;

    MintQuote {
        quantity,
        entry_probability,
        premium,
        trading_fee,
        fee_incentive_subsidy,
        builder_fee,
        penalty_fee,
        referral_fee,
        inventory_impact_charge,
        all_in_cost,
    }
}

fun fee_incentive_subsidy_amount(market: &ExpiryMarket, fee_amount: u64): u64 {
    math::mul_down(fee_amount, constants::fee_incentive_subsidy_rate!()).min(market
        .fee_incentive_balance
        .value())
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
fun settle_mint_payment(
    market: &mut ExpiryMarket,
    account: &mut Account,
    order: &Order,
    quote: &MintQuote,
    builder_code_id: Option<ID>,
    referrer_receive_address: Option<address>,
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
    let mut payment = account.withdraw<DUSDC>(quote.all_in_cost, ctx).into_balance();
    let builder_fee_payment = payment.split(quote.builder_fee);
    send_builder_fee(builder_code_id, builder_fee_payment);
    let referral_fee_payment = payment.split(quote.referral_fee);
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
    wrapper.settle<DUSDC>(root, clock);
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
            range_probability,
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
    let replacement_order = market.strike_exposure.process_live_close(terms);
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
    wrapper.settle<DUSDC>(root, clock);
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
        account.deposit<DUSDC>(payout.into_coin(ctx));
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
    account.deposit<DUSDC>(payout.into_coin(ctx));
}

// --- Shared by the mint and redeem flows ---
/// Compute the congestion surcharge from pre-trade EWMA state, then fold the
/// current gas price into the estimate.
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

fun builder_fee_amount(builder_code_id: &Option<ID>, fee_amount: u64, quantity: u64): u64 {
    if (builder_code_id.is_some()) {
        math::mul_down(fee_amount, constants::builder_fee_multiplier!()).min(
            math::mul_down(quantity, constants::max_builder_fee_rate!()),
        )
    } else {
        0
    }
}

fun send_builder_fee(builder_code_id: Option<ID>, fee: Balance<DUSDC>) {
    if (fee.value() == 0) {
        fee.destroy_zero();
        return
    };
    let builder_code_id = builder_code_id.destroy_some();
    balance::send_funds(fee, builder_code_id.to_address());
}

fun send_referral_fee(referrer_receive_address: Option<address>, fee: Balance<DUSDC>) {
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
