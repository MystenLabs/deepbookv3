// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Per-expiry Predict market.
///
/// An ExpiryMarket is the hot shared object for one expiry. It owns the
/// expiry-local DUSDC allocation, strike exposure state, fee balance, trade execution,
/// valuation witness, and storage cleanup state. Pool-wide PLP accounting and
/// allocation coordination remain outside this module.
module deepbook_predict::expiry_market;

use deepbook::math;
use deepbook_predict::{
    constants,
    market_oracle::{MarketOracle, MarketOracleCap},
    order::{Self, Order},
    predict_manager::PredictManager,
    pricing,
    pricing_config::PricingConfig,
    protocol_config::ProtocolConfig,
    pyth_source::PythSource,
    strike_exposure::{Self, StrikeExposure}
};
use dusdc::dusdc::DUSDC;
use sui::{balance::{Self, Balance}, clock::Clock, event, vec_set::VecSet};

use fun pricing::assert_live_quote_available as PricingConfig.assert_live_quote_available;

const EWrongMarketOracle: u64 = 0;
const EWrongPythSource: u64 = 1;
const EValuationExceedsCash: u64 = 2;
const EAllocationBelowMaxPayout: u64 = 3;
const EInsufficientLpCash: u64 = 8;
const EInsufficientFeeBalance: u64 = 18;
const EPackageVersionDisabled: u64 = 20;
const EMintPaused: u64 = 21;
const EUnresolvedTradingFeesUnderflow: u64 = 23;
const EFullCloseRequired: u64 = 27;

/// Per-expiry market state.
public struct ExpiryMarket has key {
    id: UID,
    market_oracle_id: ID,
    pyth_lazer_feed_id: u32,
    expiry: u64,
    /// Trading loss rebate rate snapshotted from fee config at creation.
    trading_loss_rebate_rate: u64,
    /// Active risk budget assigned by the pool.
    allocated_capital: u64,
    /// LP-owned DUSDC backing this expiry's liability.
    lp_cash_balance: Balance<DUSDC>,
    /// Fee cash held until rebate reserve and settled-expiry fee surplus are resolved.
    fee_balance: Balance<DUSDC>,
    /// Trading fees whose rebate eligibility has not been resolved.
    unresolved_trading_fees_paid: u64,
    /// Exposure lifecycle state for this expiry's oracle grid.
    strike_exposure: StrikeExposure,
    /// Mirror of `ProtocolConfig.allowed_versions`; synced permissionlessly.
    allowed_versions: VecSet<u64>,
    /// When true, `mint` aborts. Other flows (redeem, settle, cleanup) unaffected.
    mint_paused: bool,
}

/// Transaction-local valuation produced by an expiry market.
public struct ExpiryValuation {
    /// Expiry market that produced this valuation.
    expiry_market_id: ID,
    /// LP NAV contribution for this expiry.
    value: u64,
}

/// Emitted whenever a trade fee is accrued for an expiry market.
public struct FeeAccrued has copy, drop, store {
    expiry_market_id: ID,
    total_fee: u64,
    builder_fee: u64,
    builder_code_id: Option<ID>,
}

/// Emitted when an expiry trading-loss rebate is resolved for one manager.
public struct TradingLossRebateClaimed has copy, drop, store {
    expiry_market_id: ID,
    predict_manager_id: ID,
    trading_fees_paid: u64,
    cash_paid_to_expiry: u64,
    cash_received_from_expiry: u64,
    rebate_amount: u64,
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

/// Return the DUSDC capital currently allocated to this expiry.
public fun allocated_capital(market: &ExpiryMarket): u64 {
    market.allocated_capital
}

/// Return LP-owned DUSDC currently held by this expiry.
public fun lp_cash_balance(market: &ExpiryMarket): u64 {
    market.lp_cash_balance.value()
}

/// Return DUSDC fees held by this expiry.
public fun fee_balance(market: &ExpiryMarket): u64 {
    market.fee_balance.value()
}

/// Return trading fees whose rebate eligibility has not been resolved.
public fun unresolved_trading_fees_paid(market: &ExpiryMarket): u64 {
    market.unresolved_trading_fees_paid
}

/// Return the trading loss rebate rate snapshotted for this expiry.
public fun trading_loss_rebate_rate(market: &ExpiryMarket): u64 {
    market.trading_loss_rebate_rate
}

/// Return the terminal floor-index premium snapshotted for this expiry.
public fun max_expiry_floor_premium(market: &ExpiryMarket): u64 {
    market.strike_exposure.max_expiry_floor_premium()
}

/// Return conservative max-live backing, or remaining settled payout liability once materialized.
public fun payout_liability(market: &ExpiryMarket): u64 {
    market.strike_exposure.payout_liability()
}

/// Return DUSDC allocation that can leave while preserving risk and cash backing.
///
/// Live markets use conservative max-live backing; settled markets use remaining
/// materialized payout liability.
public fun returnable_capital(market: &ExpiryMarket): u64 {
    let payout_liability = market.payout_liability();
    let allocated_capital = market.allocated_capital();
    let risk_free = if (allocated_capital > payout_liability) {
        allocated_capital - payout_liability
    } else {
        0
    };
    let lp_cash_balance = market.lp_cash_balance.value();
    let cash_free = if (lp_cash_balance > payout_liability) {
        lp_cash_balance - payout_liability
    } else {
        0
    };
    risk_free.min(cash_free)
}

/// Return whether minting is currently paused on this expiry market.
public fun mint_paused(market: &ExpiryMarket): bool {
    market.mint_paused
}

/// Return this market's mirrored set of allowed package versions.
public fun allowed_versions(market: &ExpiryMarket): VecSet<u64> {
    market.allowed_versions
}

/// Produce this expiry's valuation witness for a full-pool valuation.
///
/// If the oracle is settled, this also caches terminal payout liability in
/// strike exposure. It does not destroy live indexes; privileged compaction owns that.
public fun produce_valuation(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
): ExpiryValuation {
    market.assert_version_allowed();
    config.assert_valuation_in_progress();
    let (position_liability, rebate_reserve) = market.current_nav_terms(
        config,
        market_oracle,
        pyth,
        clock,
    );
    let lp_cash_balance = market.lp_cash_balance.value();
    let fee_balance = market.fee_balance.value();
    assert!(lp_cash_balance >= position_liability, EValuationExceedsCash);
    let position_value = lp_cash_balance - position_liability;
    assert!(fee_balance >= rebate_reserve, EInsufficientFeeBalance);
    let lp_fee_surplus = math::mul(
        fee_balance - rebate_reserve,
        config.fee_config().lp_fee_share(),
    );
    ExpiryValuation {
        expiry_market_id: market.id(),
        value: position_value + lp_fee_surplus,
    }
}

/// Refresh this market's mirrored `allowed_versions`. Permissionless: callers
/// pass `registry.allowed_versions()` as the source of truth.
public fun update_allowed_versions(market: &mut ExpiryMarket, allowed_versions: VecSet<u64>) {
    market.allowed_versions = allowed_versions;
}

/// Mint a live position interval against this expiry market.
///
/// Requires the package version to be allowed for this market, per-market mint
/// pause to be off, trading globally enabled, manager ownership, a live fresh
/// oracle, and enough expiry allocation to back the post-mint max payout.
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
    assert!(!market.mint_paused, EMintPaused);
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
/// Live redeems can close part or all of an order; if quantity remains, the
/// Returns `(closed_order_id, replacement_order_id)`. A replacement ID is present
/// only when a live partial close leaves remaining quantity open. Settled
/// redeems require full order quantity and return no replacement.
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
    if (market_oracle.is_settled()) {
        assert!(close_quantity == redeemed_order.quantity(), EFullCloseRequired);
        market.redeem_settled_internal(manager, market_oracle, &redeemed_order, ctx);
        (redeemed_order.id(), option::none())
    } else {
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

/// Resolve a manager's aggregate expiry trading-loss rebate after all positions close.
public fun claim_trading_loss_rebate(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    ctx: &mut TxContext,
) {
    market.assert_version_allowed();
    config.assert_not_valuation_in_progress();
    market.materialize_settled_liability(market_oracle);

    let (
        trading_fees_paid,
        cash_paid_to_expiry,
        cash_received_from_expiry,
    ) = manager.resolve_expiry_summary(market.id());
    if (trading_fees_paid == 0 && cash_paid_to_expiry == 0 && cash_received_from_expiry == 0) {
        return
    };

    market.resolve_trading_fee_basis(trading_fees_paid);
    let trading_loss = if (cash_paid_to_expiry > cash_received_from_expiry) {
        cash_paid_to_expiry - cash_received_from_expiry
    } else {
        0
    };
    let max_rebate = math::mul(trading_fees_paid, market.trading_loss_rebate_rate);
    let rebate_amount = trading_loss.min(max_rebate);

    if (rebate_amount > 0) {
        let payout = market.dispense_fee_cash(rebate_amount);
        manager.deposit_permissionless(payout.into_coin(ctx), ctx);
    };

    event::emit(TradingLossRebateClaimed {
        expiry_market_id: market.id(),
        predict_manager_id: manager.id(),
        trading_fees_paid,
        cash_paid_to_expiry,
        cash_received_from_expiry,
        rebate_amount,
    });
}

/// Cache terminal liability if needed, then destroy live exposure indexes.
///
/// This is cap-gated because index destruction returns storage rebates. Surplus
/// LP cash and fee cash remain in the expiry until a pool sweep moves them.
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

/// Consume an expiry valuation and return its market ID and value.
public(package) fun unpack(valuation: ExpiryValuation): (ID, u64) {
    let ExpiryValuation {
        expiry_market_id,
        value,
    } = valuation;
    (expiry_market_id, value)
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

/// Create and share a funded expiry market for one market oracle.
///
/// The market snapshots the Pyth feed ID, initializes strike exposure state, and
/// takes custody of the pool-provided allocation as LP cash.
public(package) fun create_and_share(
    config: &ProtocolConfig,
    allocation: Balance<DUSDC>,
    allowed_versions: VecSet<u64>,
    market_oracle_id: ID,
    pyth_lazer_feed_id: u32,
    expiry: u64,
    min_strike: u64,
    tick_size: u64,
    ctx: &mut TxContext,
): ID {
    let allocated_capital = allocation.value();
    let market = ExpiryMarket {
        id: object::new(ctx),
        market_oracle_id,
        pyth_lazer_feed_id,
        expiry,
        trading_loss_rebate_rate: config.fee_config().trading_loss_rebate_rate(),
        allocated_capital,
        lp_cash_balance: allocation,
        fee_balance: balance::zero(),
        unresolved_trading_fees_paid: 0,
        strike_exposure: strike_exposure::new(
            expiry,
            min_strike,
            tick_size,
            config.leverage_config().max_expiry_floor_premium(),
            ctx,
        ),
        allowed_versions,
        mint_paused: false,
    };
    let id = market.id();
    transfer::share_object(market);
    id
}

/// Add pool-provided DUSDC to this live expiry's allocation and LP cash.
public(package) fun receive_allocation(market: &mut ExpiryMarket, allocation: Balance<DUSDC>) {
    market.assert_version_allowed();
    let amount = allocation.value();
    market.allocated_capital = market.allocated_capital + amount;
    market.lp_cash_balance.join(allocation);
}

/// Return free DUSDC allocation from this expiry to the pool.
///
/// Aborts if the requested amount would reduce allocation or cash below the
/// expiry's payout backing requirement.
public(package) fun return_allocation(market: &mut ExpiryMarket, amount: u64): Balance<DUSDC> {
    market.assert_version_allowed();
    assert!(amount <= market.returnable_capital(), EAllocationBelowMaxPayout);

    market.allocated_capital = market.allocated_capital - amount;
    market.lp_cash_balance.split(amount)
}

/// Set per-market mint pause (used by AdminCap admin path on registry).
public(package) fun set_mint_paused(market: &mut ExpiryMarket, paused: bool) {
    market.mint_paused = paused;
}

/// Force `mint_paused = true` (used by PauseCap path on registry; one-way).
public(package) fun pause_mint(market: &mut ExpiryMarket) {
    market.mint_paused = true;
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

/// Release settled LP and fee surplus derived from materialized settlement liability.
public(package) fun release_settled_surplus(
    market: &mut ExpiryMarket,
    market_oracle: &MarketOracle,
): (u64, Balance<DUSDC>, Balance<DUSDC>) {
    market.assert_version_allowed();
    let settled_liability = market.materialize_settled_liability(market_oracle);
    let rebate_reserve = market.aggregate_rebate_reserve();
    assert!(market.lp_cash_balance.value() >= settled_liability, EInsufficientLpCash);
    assert!(market.fee_balance.value() >= rebate_reserve, EInsufficientFeeBalance);

    let allocated_reduction = market.allocated_capital;
    if (allocated_reduction > 0) {
        assert!(allocated_reduction >= settled_liability, EAllocationBelowMaxPayout);
        market.allocated_capital = 0;
    };
    let returned_cash_amount = market.lp_cash_balance.value() - settled_liability;
    let returned_cash = market.lp_cash_balance.split(returned_cash_amount);
    let returned_fees = market.split_fee_surplus();
    market.assert_cash_backing();

    (allocated_reduction, returned_cash, returned_fees)
}

// === Private Functions ===

fun current_nav_terms(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
): (u64, u64) {
    market.assert_market_oracle(market_oracle);
    let rebate_reserve = market.aggregate_rebate_reserve();
    if (market_oracle.is_settled()) {
        let settled_liability = market.materialize_settled_liability(market_oracle);
        (settled_liability, rebate_reserve)
    } else {
        market.assert_pyth_feed(pyth);
        market_oracle.assert_not_pending_settlement(clock);
        // TODO(liquidation): Leveraged valuation is not safe until the health flow
        // enforces that every active floor-bearing order is individually above its
        // current floor before this aggregate NAV path is used.
        let live_position_liability = market
            .strike_exposure
            .live_position_liability(
                config.pricing_config(),
                market_oracle,
                pyth,
                clock,
            );
        (live_position_liability, rebate_reserve)
    }
}

fun aggregate_rebate_reserve(market: &ExpiryMarket): u64 {
    math::mul(market.unresolved_trading_fees_paid, market.trading_loss_rebate_rate)
}

fun assert_pyth_feed(market: &ExpiryMarket, pyth: &PythSource) {
    assert!(market.pyth_lazer_feed_id == pyth.feed_id(), EWrongPythSource);
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

fun assert_allocation_backing(market: &ExpiryMarket) {
    assert!(market.allocated_capital >= market.payout_liability(), EAllocationBelowMaxPayout);
}

fun assert_cash_backing(market: &ExpiryMarket) {
    assert!(market.lp_cash_balance.value() >= market.payout_liability(), EInsufficientLpCash);
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
    market.assert_market_oracle(market_oracle);
    market.assert_pyth_feed(pyth);

    let (minted_order, fee_amount) = market
        .strike_exposure
        .allocate_mint_order(
            config.pricing_config(),
            market_oracle,
            pyth,
            lower_strike,
            higher_strike,
            quantity,
            leverage,
            clock,
        );

    market.assert_allocation_backing();
    market.settle_mint_payment(manager, &minted_order, fee_amount, ctx);
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
    market.assert_pyth_feed(pyth);
    config.pricing_config().assert_live_quote_available(market_oracle, pyth, clock);
    manager.remove_position(market.id(), order.id());

    let (resulting_order, net_redeem_amount, fee_amount) = market
        .strike_exposure
        .close_and_quote_live_order(
            config.pricing_config(),
            market_oracle,
            pyth,
            order,
            close_quantity,
            clock,
        );

    let replacement_order_id = if (resulting_order.id() == order.id()) {
        option::none()
    } else {
        let replacement_order_id = resulting_order.id();
        manager.add_position(market.id(), replacement_order_id);
        option::some(replacement_order_id)
    };

    market.settle_live_redeem_payment(
        manager,
        net_redeem_amount,
        fee_amount,
        close_quantity,
        ctx,
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
}

fun settle_mint_payment(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    order: &Order,
    fee_amount: u64,
    ctx: &mut TxContext,
) {
    let quantity = order.quantity();
    let user_contribution = order.user_contribution();
    let builder_code_id = manager.builder_code_id();
    let builder_fee_amount = builder_fee_amount(&builder_code_id, fee_amount, quantity);
    let withdraw_amount = user_contribution + fee_amount + builder_fee_amount;

    manager.add_position(market.id(), order.id());
    let mut payment = manager.withdraw(withdraw_amount, ctx).into_balance();
    let builder_fee_payment = payment.split(builder_fee_amount);
    send_builder_fee(builder_code_id, builder_fee_payment);
    let payment_amount = payment.value();
    let fee_payment = payment.split(fee_amount);
    market.collect_trade_fee(manager, fee_payment);
    market.lp_cash_balance.join(payment);
    manager.record_cash_paid_to_expiry(market.id(), payment_amount);

    market.assert_cash_backing();
    market.emit_fee_accrued(fee_amount, builder_fee_amount, builder_code_id);
}

fun settle_live_redeem_payment(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    net_redeem_amount: u64,
    fee_amount: u64,
    redeemed_quantity: u64,
    ctx: &mut TxContext,
) {
    let builder_code_id = manager.builder_code_id();
    let builder_fee_amount = builder_fee_amount(
        &builder_code_id,
        fee_amount,
        redeemed_quantity,
    ).min(
        net_redeem_amount - fee_amount,
    );

    let mut payout = market.dispense_lp_cash(net_redeem_amount);
    let fee = payout.split(fee_amount);
    let builder_fee = payout.split(builder_fee_amount);
    market.collect_trade_fee(manager, fee);
    send_builder_fee(builder_code_id, builder_fee);

    market.assert_cash_backing();
    deposit_live_payout(manager, market, payout, ctx);
    market.emit_fee_accrued(fee_amount, builder_fee_amount, builder_code_id);
}

fun settle_settled_redeem_payment(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    payout_amount: u64,
    ctx: &mut TxContext,
) {
    let payout = market.dispense_lp_cash(payout_amount);
    deposit_permissionless_payout(manager, market, payout, ctx);

    market.assert_cash_backing();
}

fun collect_trade_fee(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    fee: Balance<DUSDC>,
) {
    let fee_amount = fee.value();
    market.fee_balance.join(fee);
    if (fee_amount == 0) return;
    manager.record_trading_fee_paid(market.id(), fee_amount);
    market.unresolved_trading_fees_paid = market.unresolved_trading_fees_paid + fee_amount;
}

fun deposit_live_payout(
    manager: &mut PredictManager,
    market: &ExpiryMarket,
    payout: Balance<DUSDC>,
    ctx: &mut TxContext,
) {
    manager.record_cash_received_from_expiry(market.id(), payout.value());
    manager.deposit(payout.into_coin(ctx), ctx);
}

fun deposit_permissionless_payout(
    manager: &mut PredictManager,
    market: &ExpiryMarket,
    payout: Balance<DUSDC>,
    ctx: &mut TxContext,
) {
    manager.record_cash_received_from_expiry(market.id(), payout.value());
    manager.deposit_permissionless(payout.into_coin(ctx), ctx);
}

fun resolve_trading_fee_basis(market: &mut ExpiryMarket, amount: u64) {
    assert!(market.unresolved_trading_fees_paid >= amount, EUnresolvedTradingFeesUnderflow);
    market.unresolved_trading_fees_paid = market.unresolved_trading_fees_paid - amount;
}

fun split_fee_surplus(market: &mut ExpiryMarket): Balance<DUSDC> {
    let rebate_reserve = market.aggregate_rebate_reserve();
    let fee_balance = market.fee_balance.value();
    assert!(fee_balance >= rebate_reserve, EInsufficientFeeBalance);
    market.fee_balance.split(fee_balance - rebate_reserve)
}

fun dispense_lp_cash(market: &mut ExpiryMarket, amount: u64): Balance<DUSDC> {
    assert!(market.lp_cash_balance.value() >= amount, EInsufficientLpCash);
    market.lp_cash_balance.split(amount)
}

fun dispense_fee_cash(market: &mut ExpiryMarket, amount: u64): Balance<DUSDC> {
    assert!(market.fee_balance.value() >= amount, EInsufficientFeeBalance);
    market.fee_balance.split(amount)
}

fun emit_fee_accrued(
    market: &ExpiryMarket,
    total_fee: u64,
    builder_fee: u64,
    builder_code_id: Option<ID>,
) {
    if (total_fee == 0 && builder_fee == 0) return;

    event::emit(FeeAccrued {
        expiry_market_id: market.id(),
        total_fee,
        builder_fee,
        builder_code_id,
    });
}

fun send_builder_fee(builder_code_id: Option<ID>, fee: Balance<DUSDC>) {
    if (fee.value() == 0) {
        fee.destroy_zero();
        return
    };
    let builder_code_id = builder_code_id.destroy_some();
    balance::send_funds(fee, builder_code_id.to_address());
}
