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
    pricing,
    protocol_config::ProtocolConfig,
    strike_exposure::{Self, StrikeExposure}
};
use dusdc::dusdc::DUSDC;
use fixed_math::math;
use propbook::{block_scholes_feed::BlockScholesFeed, pyth_feed::PythFeed, registry::OracleRegistry};
use sui::{accumulator::AccumulatorRoot, balance::{Self, Balance}, clock::Clock, coin::Coin};

const EMintPaused: u64 = 0;
const EFullCloseRequired: u64 = 1;
const EMarketNotSettled: u64 = 2;
const EWrongPythFeed: u64 = 3;

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

/// Return the terminal floor index snapshotted for this expiry.
public fun terminal_floor_index(market: &ExpiryMarket): u64 {
    market.strike_exposure.terminal_floor_index()
}

/// Return the liquidation LTV snapshotted for this expiry.
public fun liquidation_ltv(market: &ExpiryMarket): u64 {
    market.strike_exposure.liquidation_ltv()
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

/// Return buffered live reserve, or exact remaining settled payout liability once materialized.
public fun payout_liability(market: &ExpiryMarket): u64 {
    market.strike_exposure.payout_liability()
}

/// Return this expiry market's exact live NAV: free cash minus the exact
/// per-order live liability, floored at zero. This is structurally the live
/// primitive — a past-expiry or stale market aborts here, and an empty or
/// order-free live market returns free cash (zero liability).
///
/// A pure read with no backing assert: backing is owned by the payout-tree reserve
/// and proven on every trade, and the `max(0, ·)` cash floor marks a degenerate
/// (underwater) market at 0 — the correct per-market limited-recourse value, never
/// negative. `pricing::load_live_pricer` binds the passed propbook feeds to this
/// market's current Propbook registry mapping, rejects a past-expiry market, and
/// gates surface freshness.
///
/// A past-expiry market that has not settled aborts here. There is no solvency-safe
/// NAV for an unsettled past-expiry market: the flush uses one mark for both supply
/// and withdraw, so the mark must equal the settlement-dependent true value. Flows
/// that branch on settlement call `ensure_settled` first, using Propbook's exact
/// Pyth timestamp at expiry; if no exact spot exists yet, the live-pricing liveness
/// abort remains the correct failure mode.
public fun current_nav(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    clock: &Clock,
): u64 {
    let pricer = market.load_live_pricer(config, propbook_registry, pyth, bs, clock);
    let liability = market.strike_exposure.exact_live_liability(&pricer, clock);
    // Floor at 0 rather than abort: a degenerate underwater market marks at 0, and
    // partial-close `walk_linear` survivors can leave residual ulp dust that makes
    // liability exceed free cash by ~1-2 ulp/order, biasing the supply mark down by
    // that dust. Intentional per ROUNDING_POLICY R1/R2 (liveness; the supply mark
    // never *over*-counts TRUE, so incumbents are never diluted).
    market.cash.free_cash().saturating_sub(liability)
}

/// Return whether minting is currently paused on this expiry market.
public fun mint_paused(market: &ExpiryMarket): bool {
    market.mint_paused
}

/// Mint a live position interval against this expiry market.
///
/// Requires the running package version to be at or above the protocol version
/// watermark, per-market mint pause to be off, trading globally enabled, a valid
/// account owner auth, a live fresh oracle, enough expiry cash to back the post-mint
/// max payout and rebate reserve, and leveraged floor terms below this expiry's
/// liquidation LTV at terminal. Leveraged mints must also satisfy leverage tier
/// policy and be above the current liquidation threshold at entry. Mint fees are
/// paid by routing a withdraw through the loaded account. The position's strike
/// range is the tick pair `(lower_tick, higher_tick]` (`lower_tick = 0` is
/// `-inf`, `higher_tick = pos_inf_tick` is `+inf`); the SDK converts raw strikes
/// to ticks. Returns the minted order ID for future order-scoped flows.
public fun mint(
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    leverage: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    wrapper.settle<DUSDC>(root, clock);
    let account = wrapper.load_account_mut(auth);
    market.mint_internal(
        account,
        config,
        propbook_registry,
        pyth,
        bs,
        lower_tick,
        higher_tick,
        quantity,
        leverage,
        clock,
        ctx,
    )
}

/// Redeem an order you hold account authority over. Works in any
/// order state: a live order is priced and closed (partial or full); a settled
/// or already-liquidated order is fully closed. Returns
/// `(closed_order_id, replacement_order_id)`; a replacement is
/// present only when a live partial close leaves quantity open.
public fun redeem(
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    order_id: u256,
    close_quantity: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): (u256, Option<u256>) {
    wrapper.settle<DUSDC>(root, clock);
    let account = wrapper.load_account_mut(auth);
    market.redeem_internal(
        account,
        config,
        propbook_registry,
        pyth,
        bs,
        order_id,
        close_quantity,
        clock,
        ctx,
    )
}

/// Permissionlessly redeem a settled order without account-owner authority. The
/// market must be settled already; this flow does not run live pricing or new
/// liquidation. Liquidated tombstones clear with zero payout. Requires a full close.
public fun redeem_settled(
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
    config.assert_version();
    config.assert_not_valuation_in_progress();
    let redeemed_order = order::from_order_id(order_id);
    assert!(close_quantity == redeemed_order.quantity(), EFullCloseRequired);
    wrapper.settle<DUSDC>(root, clock);
    let auth = predict_account::generate_auth_as_app(account_registry);
    let account = wrapper.load_account_mut(auth);
    assert!(market.ensure_settled(propbook_registry, pyth, clock), EMarketNotSettled);

    market.redeem_settled_internal(
        account,
        &redeemed_order,
        ctx,
    );
    (redeemed_order.id(), option::none())
}

/// Run one bounded liquidation pass over active leveraged orders.
///
/// The liquidation book selects up to `budget` candidates and returns the
/// number of orders liquidated. It does not touch accounts; users clear
/// their liquidated position later through `redeem`, receiving no payout.
public fun liquidate(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    budget: u64,
    clock: &Clock,
): u64 {
    config.assert_version();
    config.assert_not_valuation_in_progress();
    let pricer = market.load_live_pricer(config, propbook_registry, pyth, bs, clock);
    market
        .strike_exposure
        .liquidate_live_orders(
            &pricer,
            budget,
            clock,
        )
}

/// Try to liquidate one active leveraged order by ID.
public fun liquidate_order(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    order_id: u256,
    clock: &Clock,
): bool {
    config.assert_version();
    config.assert_not_valuation_in_progress();
    let pricer = market.load_live_pricer(config, propbook_registry, pyth, bs, clock);

    let order = order::from_order_id(order_id);
    market.strike_exposure.liquidate_live_order(&pricer, &order, clock)
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
    assert!(
        propbook_registry
            .propbook_pyth_id_for_underlying(market.propbook_underlying_id)
            .contains(&pyth.id()),
        EWrongPythFeed,
    );

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
    let reserved_cash = settled_liability + market.cash.rebate_reserve();
    market.cash.assert_backing(settled_liability);

    let returned_cash_amount = market.cash.balance() - reserved_cash;
    (market.release_pool_cash(returned_cash_amount), settlement_price)
}

/// Create and share a zero-cash expiry market for one Propbook underlying.
///
/// The market snapshots the underlying, tick size, and per-market config and
/// starts with zero expiry cash; it needs no live spot at creation (strikes are
/// absolute ticks, so there is no grid to center). Current oracle object IDs stay
/// in Propbook and are resolved on every priced flow.
public(package) fun create_and_share(
    config: &ProtocolConfig,
    propbook_underlying_id: u32,
    expiry: u64,
    tick_size: u64,
    ctx: &mut TxContext,
): ID {
    let id = object::new(ctx);
    let expiry_market_id = id.to_inner();
    let cash_config = config.expiry_cash_config_snapshot();
    let strike_exposure_config = config.strike_exposure_config_snapshot();
    config_events::emit_market_config_snapshot(
        expiry_market_id,
        &strike_exposure_config,
        &cash_config,
    );
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
            strike_exposure_config,
            ctx,
        ),
        ewma: ewma::new(ctx),
        mint_paused: false,
    };
    transfer::share_object(market);
    expiry_market_id
}

// === Private Functions ===

fun is_settled(market: &ExpiryMarket): bool {
    market.settlement_price.is_some()
}

fun settlement_price(market: &ExpiryMarket): u64 {
    market.settlement_price.destroy_some()
}

/// Cache terminal payout liability in strike exposure if it has not already been cached.
fun materialize_settled_liability(market: &mut ExpiryMarket): u64 {
    let settlement = market.settlement_price();
    market.strike_exposure.materialize_settled_liability(settlement)
}

fun load_live_pricer(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    clock: &Clock,
): pricing::Pricer {
    pricing::load_live_pricer(
        config.pricing_config(),
        propbook_registry,
        market.propbook_underlying_id,
        pyth,
        bs,
        market.expiry,
        clock,
    )
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
    math::mul(fee_amount, constants::fee_incentive_subsidy_rate!())
        .min(fee_amount)
        .min(market.fee_incentive_balance.value())
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

/// Fold the current gas price into this market's EWMA and return the congestion
/// surcharge (in DUSDC) for `quantity`, zero unless the penalty is enabled and
/// gas is a high outlier. Mutates the smoothed estimate on every trade.
fun ewma_penalty(
    market: &mut ExpiryMarket,
    config: &EwmaConfig,
    quantity: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    market.ewma.update(config, clock, ctx);
    market.ewma.penalty_fee(config, quantity, ctx)
}

fun mint_internal(
    market: &mut ExpiryMarket,
    account: &mut Account,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    leverage: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    config.assert_version();
    assert!(!market.mint_paused, EMintPaused);
    config.assert_trading_allowed();
    config.assert_not_valuation_in_progress();
    let pricer = market.load_live_pricer(config, propbook_registry, pyth, bs, clock);
    let active_stake = predict_account::active_stake_mut(account, ctx);
    market
        .strike_exposure
        .liquidate_live_orders(
            &pricer,
            config.trade_liquidation_budget(),
            clock,
        );

    let (minted_order, entry_probability, net_premium) = market
        .strike_exposure
        .allocate_mint_order(
            &pricer,
            lower_tick,
            higher_tick,
            quantity,
            leverage,
            clock,
        );
    let raw_fee_amount = market.strike_exposure.trading_fee(entry_probability, quantity, clock);
    let fee_amount = config.stake_config().fee_amount_after_discount(raw_fee_amount, active_stake);
    let penalty_amount = market.ewma_penalty(config.ewma_config(), quantity, clock, ctx);

    let builder_code_id = predict_account::builder_code_id(account);
    let (builder_fee_amount, fee_incentive_subsidy) = market.settle_mint_payment(
        account,
        &minted_order,
        net_premium,
        fee_amount,
        penalty_amount,
        ctx,
    );
    order_events::emit_order_minted(
        market.id(),
        account.account_id(),
        account.owner(),
        builder_code_id,
        &minted_order,
        leverage,
        entry_probability,
        net_premium,
        fee_amount,
        fee_incentive_subsidy,
        builder_fee_amount,
        penalty_amount,
    );
    minted_order.id()
}

fun redeem_internal(
    market: &mut ExpiryMarket,
    account: &mut Account,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    order_id: u256,
    close_quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (u256, Option<u256>) {
    config.assert_version();
    config.assert_not_valuation_in_progress();
    let redeemed_order = order::from_order_id(order_id);
    if (market.ensure_settled(propbook_registry, pyth, clock)) {
        assert!(close_quantity == redeemed_order.quantity(), EFullCloseRequired);
        market.redeem_settled_internal(account, &redeemed_order, ctx);
        return (redeemed_order.id(), option::none())
    };

    let pricer = market.load_live_pricer(config, propbook_registry, pyth, bs, clock);
    market
        .strike_exposure
        .liquidate_live_orders(
            &pricer,
            config.trade_liquidation_budget(),
            clock,
        );
    if (market.strike_exposure.is_liquidated_order(&redeemed_order)) {
        market.redeem_liquidated_order(account, &redeemed_order, close_quantity, ctx);
        return (redeemed_order.id(), option::none())
    };
    let replacement_order_id = market.redeem_live_internal(
        account,
        config,
        &pricer,
        &redeemed_order,
        close_quantity,
        clock,
        ctx,
    );
    (redeemed_order.id(), replacement_order_id)
}

fun redeem_live_internal(
    market: &mut ExpiryMarket,
    account: &mut Account,
    config: &ProtocolConfig,
    pricer: &pricing::Pricer,
    order: &Order,
    close_quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Option<u256> {
    let active_stake = predict_account::active_stake_mut(account, ctx);
    let position_root_id = predict_account::remove_position(
        account,
        market.id(),
        order.id(),
        ctx,
    );

    let (resulting_order, redeem_amount, range_probability) = market
        .strike_exposure
        .close_and_quote_live_order(
            pricer,
            order,
            close_quantity,
            clock,
        );
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
    order: &Order,
    ctx: &mut TxContext,
) {
    if (market.strike_exposure.is_liquidated_order(order)) {
        market.redeem_liquidated_order(account, order, order.quantity(), ctx);
        return
    };

    let position_root_id = predict_account::remove_position(
        account,
        market.id(),
        order.id(),
        ctx,
    );
    market.materialize_settled_liability();

    let settlement = market.settlement_price();
    let payout_amount = market.strike_exposure.close_settled_order(order, settlement);
    market.settle_settled_redeem_payment(account, payout_amount, ctx);

    order_events::emit_settled_order_redeemed(
        market.id(),
        account.account_id(),
        account.owner(),
        order,
        position_root_id,
        settlement,
        payout_amount,
    );
}

/// Settle a mint payment and return the builder fee and fee incentive subsidy.
///
/// The EWMA penalty is withdrawn alongside the net premium and fees, but rides
/// into expiry cash as surplus: it is not part of the rebate fee basis and
/// earns no builder cut. Fee incentives subsidize only the trader-paid portion
/// of the trading fee; the expiry still collects the full fee amount.
fun settle_mint_payment(
    market: &mut ExpiryMarket,
    account: &mut Account,
    order: &Order,
    net_premium: u64,
    fee_amount: u64,
    penalty_amount: u64,
    ctx: &mut TxContext,
): (u64, u64) {
    let quantity = order.quantity();
    let builder_code_id = predict_account::builder_code_id(account);
    let builder_fee_amount = builder_fee_amount(&builder_code_id, fee_amount, quantity);
    let fee_subsidy_amount = market.fee_incentive_subsidy_amount(fee_amount);
    let trader_fee_amount = fee_amount - fee_subsidy_amount;
    let withdraw_amount = net_premium + trader_fee_amount + builder_fee_amount + penalty_amount;

    predict_account::add_position(account, market.id(), order.id(), order.id(), ctx);
    let mut payment = account.withdraw<DUSDC>(withdraw_amount, ctx).into_balance();
    let builder_fee_payment = payment.split(builder_fee_amount);
    send_builder_fee(copy builder_code_id, builder_fee_payment);
    let mut fee_payment = payment.split(trader_fee_amount);
    fee_payment.join(market.fee_incentive_balance.split(fee_subsidy_amount));
    market.collect_trade_fee(account, fee_payment, trader_fee_amount, ctx);
    // Remaining balance is the net premium plus the penalty surplus.
    market.cash.receive(payment);

    market.assert_cash_backing();
    (builder_fee_amount, fee_subsidy_amount)
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
    market.cash.collect_trade_fee(fee);
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

// === Test-Only Functions ===

#[test_only]
public fun receive_cash_for_testing(market: &mut ExpiryMarket, funds: Coin<DUSDC>) {
    market.cash.receive(funds.into_balance());
}
