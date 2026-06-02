// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Per-expiry Predict market.
///
/// An ExpiryMarket is the hot shared object for one expiry. It owns the
/// expiry-local DUSDC cash, strike exposure state, rebate reserve basis, trade execution,
/// pool NAV production, and storage cleanup state. Pool-wide PLP accounting and
/// profit accounting remain outside this module.
module deepbook_predict::expiry_market;

use deepbook::math;
use deepbook_predict::{
    claim_events,
    constants,
    market_oracle::{MarketOracle, MarketOracleCap},
    order::{Self, Order},
    order_events,
    predict_manager::PredictManager,
    pricing,
    pricing_config::PricingConfig,
    protocol_config::ProtocolConfig,
    pyth_source::PythSource,
    strike_exposure::{Self, StrikeExposure}
};
use dusdc::dusdc::DUSDC;
use sui::{balance::{Self, Balance}, clock::Clock, vec_set::VecSet};

const EWrongMarketOracle: u64 = 0;
const EWrongPythSource: u64 = 1;
const EValuationExceedsCash: u64 = 2;
const EInsufficientCash: u64 = 3;
const EPackageVersionDisabled: u64 = 4;
const EMintPaused: u64 = 5;
const EUnresolvedTradingFeesUnderflow: u64 = 6;
const EFullCloseRequired: u64 = 7;

/// Per-expiry market state.
public struct ExpiryMarket has key {
    id: UID,
    market_oracle_id: ID,
    pyth_lazer_feed_id: u32,
    expiry: u64,
    /// DUSDC backing payout liability, rebate reserve, and residual expiry NAV.
    cash_balance: Balance<DUSDC>,
    /// Trading-fee basis whose rebate eligibility has not been resolved.
    unresolved_trading_fees_paid: u64,
    /// Fraction of aggregate expiry trading fees reserved for loss rebates.
    trading_loss_rebate_rate: u64,
    /// Frozen per-expiry trade-fee ramp window.
    expiry_fee_window_ms: u64,
    /// Frozen per-expiry trade-fee ramp max multiplier.
    expiry_fee_max_multiplier: u64,
    /// Exposure lifecycle state for this expiry's oracle grid.
    strike_exposure: StrikeExposure,
    /// Mirror of `ProtocolConfig.allowed_versions`; synced permissionlessly.
    allowed_versions: VecSet<u64>,
}

// === Public Functions ===

/// Return the expiry market object ID.
public fun id(market: &ExpiryMarket): ID {
    market.id.to_inner()
}

/// Return the market oracle this expiry market is paired with.
public fun market_oracle_id(market: &ExpiryMarket): ID {
    market.market_oracle_id
}

/// Return the Pyth Lazer feed id snapshotted at market creation.
public fun pyth_lazer_feed_id(market: &ExpiryMarket): u32 {
    market.pyth_lazer_feed_id
}

/// Return the expiry timestamp in milliseconds.
public fun expiry(market: &ExpiryMarket): u64 {
    market.expiry
}

/// Return DUSDC currently held by this expiry.
public fun cash_balance(market: &ExpiryMarket): u64 {
    market.cash_balance.value()
}

/// Return DUSDC reserved for unresolved trading loss rebates.
public fun rebate_reserve(market: &ExpiryMarket): u64 {
    math::mul(market.unresolved_trading_fees_paid, market.trading_loss_rebate_rate)
}

/// Return the trading loss rebate rate snapshotted for this expiry.
public fun trading_loss_rebate_rate(market: &ExpiryMarket): u64 {
    market.trading_loss_rebate_rate
}

/// Return the terminal floor-index premium snapshotted for this expiry.
public fun max_expiry_floor_premium(market: &ExpiryMarket): u64 {
    market.strike_exposure.max_expiry_floor_premium()
}

/// Return the liquidation LTV snapshotted for this expiry.
public fun liquidation_ltv(market: &ExpiryMarket): u64 {
    market.strike_exposure.liquidation_ltv()
}

/// Return the trade-fee ramp window snapshotted for this expiry.
public fun expiry_fee_window_ms(market: &ExpiryMarket): u64 {
    market.expiry_fee_window_ms
}

/// Return the trade-fee ramp max multiplier snapshotted for this expiry.
public fun expiry_fee_max_multiplier(market: &ExpiryMarket): u64 {
    market.expiry_fee_max_multiplier
}

/// Return the minimum strike snapshotted for this expiry's oracle grid.
public fun min_strike(market: &ExpiryMarket): u64 {
    market.strike_exposure.min_strike()
}

/// Return the strike tick size snapshotted for this expiry's oracle grid.
public fun tick_size(market: &ExpiryMarket): u64 {
    market.strike_exposure.tick_size()
}

/// Return the maximum strike snapshotted for this expiry's oracle grid.
public fun max_strike(market: &ExpiryMarket): u64 {
    market.strike_exposure.max_strike()
}

/// Return conservative max-live backing, or remaining settled payout liability once materialized.
public fun payout_liability(market: &ExpiryMarket): u64 {
    market.strike_exposure.payout_liability()
}

/// Return this market's mirrored set of allowed package versions.
public fun allowed_versions(market: &ExpiryMarket): VecSet<u64> {
    market.allowed_versions
}

/// Mint a live position interval against this expiry market.
///
/// Requires the package version to be allowed for this market, expiry mint
/// pause to be off, trading globally enabled, manager ownership, a live fresh
/// oracle, enough expiry cash to back the post-mint max payout and rebate reserve,
/// and leveraged floor terms below this expiry's liquidation LTV at terminal.
/// Leveraged mints must also satisfy leverage tier policy and be above the current
/// liquidation threshold at entry.
/// Returns the minted order ID for future order-scoped flows.
public fun mint(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    lower_strike: u64,
    higher_strike: u64,
    quantity: u64,
    leverage: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    market.assert_version_allowed();
    assert!(!market.expiry_mint_paused(config), EMintPaused);
    config.assert_trading_allowed();
    market.mint_internal(
        manager,
        config,
        market_oracle,
        pyth,
        lower_strike,
        higher_strike,
        quantity,
        leverage,
        clock,
        ctx,
    )
}

/// Redeem live or settled order quantity.
///
/// Live redeems can close part or all of an order. Settled and liquidated-order
/// redeems require a full close and return no replacement. Returns
/// `(closed_order_id, replacement_order_id)`.
public fun redeem(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    order_id: u256,
    close_quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (u256, Option<u256>) {
    market.assert_version_allowed();
    config.assert_not_valuation_in_progress();
    market.assert_market_oracle(market_oracle);
    let redeemed_order = order::from_order_id(order_id);
    if (market.strike_exposure.is_liquidated_order(&redeemed_order)) {
        market.redeem_liquidated_order(manager, &redeemed_order, close_quantity);
        return (redeemed_order.id(), option::none())
    };

    if (market_oracle.is_settled()) {
        assert!(close_quantity == redeemed_order.quantity(), EFullCloseRequired);
        market.redeem_settled_internal(manager, market_oracle, &redeemed_order, ctx);
        (redeemed_order.id(), option::none())
    } else {
        market.run_liquidation_pass(
            config.pricing_config(),
            market_oracle,
            pyth,
            config.risk_config().trade_liquidation_budget(),
            clock,
        );
        if (market.strike_exposure.is_liquidated_order(&redeemed_order)) {
            market.redeem_liquidated_order(manager, &redeemed_order, close_quantity);
            return (redeemed_order.id(), option::none())
        };
        let replacement_order_id = market.redeem_live_internal(
            manager,
            config,
            market_oracle,
            pyth,
            &redeemed_order,
            close_quantity,
            clock,
            ctx,
        );
        (redeemed_order.id(), replacement_order_id)
    }
}

/// Run one bounded liquidation pass over active leveraged orders.
///
/// The liquidation book selects up to `budget` candidates and returns the
/// number of orders liquidated. It does not touch PredictManagers; users clear
/// their liquidated position later through `redeem`, receiving no payout.
public fun liquidate(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    budget: u64,
    clock: &Clock,
): u64 {
    market.assert_version_allowed();
    config.assert_not_valuation_in_progress();
    market.run_liquidation_pass(config.pricing_config(), market_oracle, pyth, budget, clock)
}

/// Cache terminal liability if needed, then destroy live exposure indexes.
///
/// This is cap-gated because index destruction returns storage rebates. Settled
/// pool cash remains in the expiry until PLP rebalancing receives it.
public fun compact_storage(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    cap: &MarketOracleCap,
) {
    market.assert_version_allowed();
    config.assert_not_valuation_in_progress();
    market.assert_market_oracle(market_oracle);
    market_oracle.assert_authorized_cap(cap);
    market.materialize_settled_liability(market_oracle);
    market.strike_exposure.destroy_live_indexes();
    market.assert_cash_backing();
}

// === Public-Package Functions ===

/// Overwrite this market's mirrored `allowed_versions`. The only authorized
/// caller is `registry::sync_expiry_market_allowed_versions`, which reads the
/// source of truth from `Registry`.
public(package) fun set_allowed_versions(market: &mut ExpiryMarket, allowed_versions: VecSet<u64>) {
    market.allowed_versions = allowed_versions;
}

/// Assert that a market oracle belongs to this expiry market.
public(package) fun assert_market_oracle(market: &ExpiryMarket, market_oracle: &MarketOracle) {
    assert!(market.market_oracle_id == market_oracle.id(), EWrongMarketOracle);
}

/// Abort if the running package version is not allowed for this market.
public(package) fun assert_version_allowed(market: &ExpiryMarket) {
    assert!(
        market.allowed_versions.contains(&constants::current_version!()),
        EPackageVersionDisabled,
    );
}

/// Create and share a zero-cash expiry market for one market oracle.
///
/// `ProtocolConfig` stamps the per-expiry config row. The market snapshots the
/// Pyth feed ID into its own binding state and initializes structural strike
/// exposure state with zero expiry cash. Pool funding only enters through PLP
/// rebalancing.
public(package) fun create_and_share(
    config: &mut ProtocolConfig,
    allowed_versions: VecSet<u64>,
    market_oracle_id: ID,
    pyth: &PythSource,
    expiry: u64,
    preallocated_ticks: u64,
    ctx: &mut TxContext,
): (ID, u64, u64) {
    let id = object::new(ctx);
    let expiry_market_id = id.to_inner();
    let snapshot = config.stamp_expiry_entry(
        expiry,
        expiry_market_id,
        market_oracle_id,
        pyth.feed_id(),
        pyth.spot(),
    );
    let min_strike = snapshot.min_strike();
    let tick_size = snapshot.tick_size();
    let market = ExpiryMarket {
        id,
        market_oracle_id,
        pyth_lazer_feed_id: pyth.feed_id(),
        expiry,
        cash_balance: balance::zero(),
        unresolved_trading_fees_paid: 0,
        trading_loss_rebate_rate: snapshot.trading_loss_rebate_rate(),
        expiry_fee_window_ms: snapshot.expiry_fee_window_ms(),
        expiry_fee_max_multiplier: snapshot.expiry_fee_max_multiplier(),
        strike_exposure: strike_exposure::new(
            expiry_market_id,
            expiry,
            min_strike,
            tick_size,
            snapshot.max_expiry_floor_premium(),
            snapshot.liquidation_ltv(),
            preallocated_ticks,
            ctx,
        ),
        allowed_versions,
    };
    transfer::share_object(market);
    (expiry_market_id, min_strike, tick_size)
}

/// Cache terminal payout liability in strike exposure if it has not already been cached.
public(package) fun materialize_settled_liability(
    market: &mut ExpiryMarket,
    market_oracle: &MarketOracle,
): u64 {
    market.assert_market_oracle(market_oracle);
    let settlement = pricing::settlement_price(market_oracle);
    market.strike_exposure.materialize_settled_liability(settlement)
}

/// Return current pool-owned NAV.
public(package) fun pool_nav(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
): u64 {
    market.assert_version_allowed();
    config.assert_valuation_in_progress();
    market.assert_market_oracle(market_oracle);
    market.assert_pyth_feed(pyth);
    market_oracle.assert_active(clock);
    let position_liability = market
        .strike_exposure
        .valuation_liability(
            config.pricing_config(),
            market_oracle,
            pyth,
            clock,
        );
    let required_cash = position_liability + market.rebate_reserve();
    let cash_balance = market.cash_balance.value();
    assert!(cash_balance >= required_cash, EValuationExceedsCash);
    cash_balance - required_cash
}

/// Run one expiry-local liquidation pass with the caller-selected budget.
public(package) fun run_liquidation_pass(
    market: &mut ExpiryMarket,
    pricing_config: &PricingConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    budget: u64,
    clock: &Clock,
): u64 {
    market.assert_version_allowed();
    market.assert_market_oracle(market_oracle);
    market.assert_pyth_feed(pyth);
    market_oracle.assert_active(clock);
    market
        .strike_exposure
        .liquidate_live_orders(
            pricing_config,
            market_oracle,
            pyth,
            budget,
            clock,
        )
}

/// Resolve one manager's trading-loss rebate and return unclaimed rebate reserve.
public(package) fun claim_trading_loss_rebate(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    ctx: &mut TxContext,
): Balance<DUSDC> {
    market.assert_version_allowed();
    market.materialize_settled_liability(market_oracle);

    let (trading_fees_paid, gross_profit) = manager.resolve_expiry_summary(market.id());
    if (trading_fees_paid == 0 && gross_profit == 0) {
        return balance::zero()
    };

    market.resolve_trading_fee_basis(trading_fees_paid);
    let resolved_rebate_reserve = math::mul(
        trading_fees_paid,
        market.trading_loss_rebate_rate(),
    );
    let eligible_rebate = if (resolved_rebate_reserve > gross_profit) {
        resolved_rebate_reserve - gross_profit
    } else {
        0
    };

    // Active staking decides the manager's share of the eligible rebate.
    manager.update_stake(ctx);
    let rebate_amount = config
        .stake_config()
        .rebate_amount(eligible_rebate, manager.active_stake());

    if (rebate_amount > 0) {
        let payout = market.dispense_cash(rebate_amount);
        manager.deposit_permissionless(payout.into_coin(ctx), ctx);
    };
    let residual_rebate_reserve = resolved_rebate_reserve - rebate_amount;
    let residual_rebate_cash = market.dispense_cash(residual_rebate_reserve);
    market.assert_cash_backing();

    claim_events::emit_trading_loss_rebate_claimed(
        market.id(),
        manager.id(),
        trading_fees_paid,
        gross_profit,
        eligible_rebate,
        rebate_amount,
    );
    residual_rebate_cash
}

/// Release settled pool cash above terminal payout liability and rebate reserve.
public(package) fun release_settled_pool_cash(
    market: &mut ExpiryMarket,
    market_oracle: &MarketOracle,
): Balance<DUSDC> {
    market.assert_version_allowed();
    let settled_liability = market.materialize_settled_liability(market_oracle);
    let rebate_reserve = market.rebate_reserve();
    let reserved_cash = settled_liability + rebate_reserve;
    assert!(market.cash_balance.value() >= reserved_cash, EInsufficientCash);

    let returned_cash_amount = market.cash_balance.value() - reserved_cash;
    market.release_pool_cash(returned_cash_amount)
}

/// Receive pool-provided cash without interpreting pool allocation policy.
public(package) fun receive_pool_cash(market: &mut ExpiryMarket, cash: Balance<DUSDC>) {
    market.assert_version_allowed();
    market.cash_balance.join(cash);
    market.assert_cash_backing();
}

/// Release pool cash while preserving expiry-local payout and rebate backing.
public(package) fun release_pool_cash(market: &mut ExpiryMarket, amount: u64): Balance<DUSDC> {
    market.assert_version_allowed();
    if (amount == 0) {
        return balance::zero()
    };
    let required_cash = market.payout_liability() + market.rebate_reserve();
    assert!(market.cash_balance.value() >= required_cash + amount, EInsufficientCash);
    let released_cash = market.cash_balance.split(amount);
    market.assert_cash_backing();
    released_cash
}

// === Private Functions ===

fun assert_pyth_feed(market: &ExpiryMarket, pyth: &PythSource) {
    assert!(market.pyth_lazer_feed_id == pyth.feed_id(), EWrongPythSource);
}

fun expiry_mint_paused(market: &ExpiryMarket, config: &ProtocolConfig): bool {
    config.assert_expiry_market_binding(market.expiry, market.id());
    config.expiry_mint_paused(market.expiry)
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

fun redeem_liquidated_order(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    order: &Order,
    close_quantity: u64,
) {
    assert!(close_quantity == order.quantity(), EFullCloseRequired);
    manager.remove_position(market.id(), order.id());
    market.strike_exposure.clear_liquidated_order(order);
    order_events::emit_liquidated_order_redeemed(market.id(), manager, order);
}

fun assert_cash_backing(market: &ExpiryMarket) {
    let required_cash = market.payout_liability() + market.rebate_reserve();
    assert!(market.cash_balance.value() >= required_cash, EInsufficientCash);
}

fun mint_internal(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    lower_strike: u64,
    higher_strike: u64,
    quantity: u64,
    leverage: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    manager.assert_owner(ctx);
    manager.update_stake(ctx);
    market.assert_market_oracle(market_oracle);
    market.assert_pyth_feed(pyth);
    market.run_liquidation_pass(
        config.pricing_config(),
        market_oracle,
        pyth,
        config.risk_config().trade_liquidation_budget(),
        clock,
    );
    let entry_probability = pricing::live_range_probability(
        config.pricing_config(),
        market_oracle,
        pyth,
        lower_strike,
        higher_strike,
        clock,
    );
    order::assert_mint_leverage_tier(entry_probability, leverage);
    let fee_rate = pricing::assert_mint_fee_rate(
        config.pricing_config(),
        market_oracle,
        market.expiry_fee_window_ms,
        market.expiry_fee_max_multiplier,
        entry_probability,
        clock,
    );
    let fee_amount = math::mul(fee_rate, quantity);

    let minted_order = market
        .strike_exposure
        .allocate_mint_order(
            lower_strike,
            higher_strike,
            quantity,
            leverage,
            entry_probability,
            clock,
        );
    let fee_amount = config
        .stake_config()
        .fee_amount_after_discount(fee_amount, manager.active_stake());

    let builder_fee_amount = market.settle_mint_payment(manager, &minted_order, fee_amount, ctx);
    order_events::emit_order_minted(
        market.id(),
        manager,
        &minted_order,
        lower_strike,
        higher_strike,
        fee_amount,
        builder_fee_amount,
    );
    minted_order.id()
}

fun redeem_live_internal(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    order: &Order,
    close_quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Option<u256> {
    manager.assert_owner(ctx);
    manager.update_stake(ctx);
    market.assert_pyth_feed(pyth);
    let strikes = market.strike_exposure.order_strikes(order);
    let range_probability = pricing::live_range_probability(
        config.pricing_config(),
        market_oracle,
        pyth,
        strikes.lower(),
        strikes.higher(),
        clock,
    );
    let fee_rate = pricing::fee_rate(
        config.pricing_config(),
        market_oracle,
        market.expiry_fee_window_ms,
        market.expiry_fee_max_multiplier,
        range_probability,
        clock,
    );

    manager.remove_position(market.id(), order.id());
    let (resulting_order, redeem_amount) = market
        .strike_exposure
        .close_live_order(order, close_quantity, range_probability, clock);
    let fee_amount = math::mul(fee_rate, close_quantity).min(redeem_amount);
    let fee_amount = config
        .stake_config()
        .fee_amount_after_discount(fee_amount, manager.active_stake());

    let replacement_order_id = if (resulting_order.id() == order.id()) {
        option::none()
    } else {
        let replacement_order_id = resulting_order.id();
        manager.add_position(market.id(), replacement_order_id);
        option::some(replacement_order_id)
    };

    let builder_fee_amount = market.settle_live_redeem_payment(
        manager,
        redeem_amount,
        fee_amount,
        close_quantity,
        ctx,
    );

    order_events::emit_live_order_redeemed(
        market.id(),
        manager,
        order,
        close_quantity,
        replacement_order_id,
        redeem_amount,
        fee_amount,
        builder_fee_amount,
    );
    replacement_order_id
}

fun redeem_settled_internal(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    order: &Order,
    ctx: &mut TxContext,
) {
    manager.remove_position(market.id(), order.id());
    market.materialize_settled_liability(market_oracle);

    let settlement = pricing::settlement_price(market_oracle);
    let payout_amount = market.strike_exposure.close_settled_order(order, settlement);
    market.settle_settled_redeem_payment(manager, payout_amount, ctx);

    order_events::emit_settled_order_redeemed(
        market.id(),
        manager,
        order,
        settlement,
        payout_amount,
    );
}

fun settle_mint_payment(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    order: &Order,
    fee_amount: u64,
    ctx: &mut TxContext,
): u64 {
    let quantity = order.quantity();
    let user_contribution = order.user_contribution();
    let builder_code_id = manager.builder_code_id();
    let builder_fee_amount = builder_fee_amount(&builder_code_id, fee_amount, quantity);
    let withdraw_amount = user_contribution + fee_amount + builder_fee_amount;

    manager.add_position(market.id(), order.id());
    let mut payment = manager.withdraw(withdraw_amount, ctx).into_balance();
    let builder_fee_payment = payment.split(builder_fee_amount);
    send_builder_fee(builder_code_id, builder_fee_payment);
    let fee_payment = payment.split(fee_amount);
    market.collect_trade_fee(manager, fee_payment);
    market.cash_balance.join(payment);
    manager.record_gross_paid_to_expiry(market.id(), user_contribution);

    market.assert_cash_backing();
    builder_fee_amount
}

/// Settle a live redeem and return the builder fee paid.
fun settle_live_redeem_payment(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    redeem_amount: u64,
    fee_amount: u64,
    redeemed_quantity: u64,
    ctx: &mut TxContext,
): u64 {
    let builder_code_id = manager.builder_code_id();
    let builder_fee_amount = builder_fee_amount(
        &builder_code_id,
        fee_amount,
        redeemed_quantity,
    ).min(
        redeem_amount - fee_amount,
    );

    let mut payout = market.dispense_cash(redeem_amount);
    let fee = payout.split(fee_amount);
    let builder_fee = payout.split(builder_fee_amount);
    market.collect_trade_fee(manager, fee);
    send_builder_fee(builder_code_id, builder_fee);

    market.assert_cash_backing();
    deposit_live_payout(manager, market, payout, redeem_amount, ctx);
    builder_fee_amount
}

fun settle_settled_redeem_payment(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    payout_amount: u64,
    ctx: &mut TxContext,
) {
    let payout = market.dispense_cash(payout_amount);
    deposit_permissionless_payout(manager, market, payout, ctx);

    market.assert_cash_backing();
}

fun collect_trade_fee(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    fee: Balance<DUSDC>,
) {
    let fee_amount = fee.value();
    market.cash_balance.join(fee);
    if (fee_amount == 0) return;
    manager.record_trading_fee_paid(market.id(), fee_amount);
    market.unresolved_trading_fees_paid = market.unresolved_trading_fees_paid + fee_amount;
}

fun deposit_live_payout(
    manager: &mut PredictManager,
    market: &ExpiryMarket,
    payout: Balance<DUSDC>,
    gross_received_amount: u64,
    ctx: &mut TxContext,
) {
    manager.record_gross_received_from_expiry(market.id(), gross_received_amount);
    manager.deposit(payout.into_coin(ctx), ctx);
}

fun deposit_permissionless_payout(
    manager: &mut PredictManager,
    market: &ExpiryMarket,
    payout: Balance<DUSDC>,
    ctx: &mut TxContext,
) {
    manager.record_gross_received_from_expiry(market.id(), payout.value());
    manager.deposit_permissionless(payout.into_coin(ctx), ctx);
}

fun resolve_trading_fee_basis(market: &mut ExpiryMarket, amount: u64) {
    assert!(market.unresolved_trading_fees_paid >= amount, EUnresolvedTradingFeesUnderflow);
    market.unresolved_trading_fees_paid = market.unresolved_trading_fees_paid - amount;
}

fun dispense_cash(market: &mut ExpiryMarket, amount: u64): Balance<DUSDC> {
    assert!(market.cash_balance.value() >= amount, EInsufficientCash);
    market.cash_balance.split(amount)
}

fun send_builder_fee(builder_code_id: Option<ID>, fee: Balance<DUSDC>) {
    if (fee.value() == 0) {
        fee.destroy_zero();
        return
    };
    let builder_code_id = builder_code_id.destroy_some();
    balance::send_funds(fee, builder_code_id.to_address());
}
