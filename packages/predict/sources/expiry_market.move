// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Per-expiry Predict market.
///
/// An ExpiryMarket is the hot shared object for one expiry. It owns the
/// expiry-local DUSDC allocation, strike exposure state, fee balance, trade execution,
/// valuation witness, finalized settlement liability, and storage cleanup state. Pool-wide PLP
/// accounting and allocation coordination remain outside this module.
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
const EZeroAllocatedCapital: u64 = 10;
const EInvalidTickSize: u64 = 11;
const EInvalidStrikeGrid: u64 = 12;
const ESettledLiabilityUnderflow: u64 = 16;
const EInsufficientFeeBalance: u64 = 18;
const EPackageVersionDisabled: u64 = 20;
const EMintPaused: u64 = 21;
const EUnresolvedTradingFeesUnderflow: u64 = 23;
const ESettlementNotFinalized: u64 = 24;
const EUnsupportedLeverage: u64 = 25;
const EWrongOrderExpiry: u64 = 26;

/// Per-expiry market state.
public struct ExpiryMarket has key {
    id: UID,
    market_oracle_id: ID,
    pyth_lazer_feed_id: u32,
    expiry: u64,
    /// Trading loss rebate rate snapshotted from fee config at creation.
    trading_loss_rebate_rate: u64,
    /// Terminal borrow premium snapshotted from leverage config at creation.
    max_expiry_borrow_fee: u64,
    /// Active risk budget assigned by the pool.
    allocated_capital: u64,
    /// LP-owned DUSDC backing this expiry's liability.
    lp_cash_balance: Balance<DUSDC>,
    /// Fee cash held until rebate reserve and settled-expiry fee surplus are resolved.
    fee_balance: Balance<DUSDC>,
    /// Trading fees whose rebate eligibility has not been resolved.
    unresolved_trading_fees_paid: u64,
    /// Settled payout liability cached once expiry economics are finalized.
    settled_payout_liability: Option<u64>,
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

/// Return the terminal borrow premium snapshotted for this expiry.
public fun max_expiry_borrow_fee(market: &ExpiryMarket): u64 {
    market.max_expiry_borrow_fee
}

/// Return whether this expiry's settled payout liability has been finalized.
public fun is_settlement_finalized(market: &ExpiryMarket): bool {
    market.settled_payout_liability.is_some()
}

/// Return cached settled payout liability once finalized.
public fun settled_payout_liability(market: &ExpiryMarket): Option<u64> {
    market.settled_payout_liability
}

/// Return live worst-case payout, or remaining settled payout liability after finalization.
public fun max_payout(market: &ExpiryMarket): u64 {
    if (market.settled_payout_liability.is_some()) {
        *market.settled_payout_liability.borrow()
    } else {
        market.strike_exposure.max_payout()
    }
}

/// Return allocated capital not needed for worst-case payout backing.
public fun free_capital(market: &ExpiryMarket): u64 {
    let allocated_capital = market.allocated_capital();
    let max_payout = market.max_payout();
    if (allocated_capital > max_payout) {
        allocated_capital - max_payout
    } else {
        0
    }
}

/// Return DUSDC allocation that can leave while preserving risk and cash backing.
public fun returnable_capital(market: &ExpiryMarket): u64 {
    let max_payout = market.max_payout();
    let risk_free = market.free_capital();
    let lp_cash_balance = market.lp_cash_balance.value();
    let cash_free = if (lp_cash_balance > max_payout) {
        lp_cash_balance - max_payout
    } else {
        0
    };
    risk_free.min(cash_free)
}

/// Return current expiry utilization as max payout over allocated capital.
public(package) fun utilization(market: &ExpiryMarket): u64 {
    let allocated_capital = market.allocated_capital;
    assert!(allocated_capital > 0, EZeroAllocatedCapital);
    math::div(market.max_payout(), allocated_capital)
}

/// Return whether minting is currently paused on this expiry market.
public fun mint_paused(market: &ExpiryMarket): bool {
    market.mint_paused
}

/// Return this market's mirrored set of allowed package versions.
public fun allowed_versions(market: &ExpiryMarket): VecSet<u64> {
    market.allowed_versions
}

/// Refresh this market's mirrored `allowed_versions`. Permissionless: callers
/// pass `registry.allowed_versions()` as the source of truth.
public fun update_allowed_versions(market: &mut ExpiryMarket, allowed_versions: VecSet<u64>) {
    market.allowed_versions = allowed_versions;
}

/// Produce this expiry's valuation witness for a full-pool valuation.
///
/// Requires the protocol valuation lock, aborts while the oracle is expired but
/// unsettled, and does not mutate expiry or oracle state.
public fun read_valuation(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
): ExpiryValuation {
    config.assert_valuation_in_progress();
    let (option_value, rebate_reserve) = market.current_liabilities(
        config,
        market_oracle,
        pyth,
        clock,
    );
    let lp_cash_balance = market.lp_cash_balance.value();
    let fee_balance = market.fee_balance.value();
    assert!(lp_cash_balance >= option_value, EValuationExceedsCash);
    assert!(fee_balance >= rebate_reserve, EInsufficientFeeBalance);
    let lp_fee_surplus = math::mul(
        fee_balance - rebate_reserve,
        config.fee_config().lp_fee_share(),
    );
    ExpiryValuation {
        expiry_market_id: market.id(),
        value: lp_cash_balance - option_value + lp_fee_surplus,
    }
}

/// Mint a live position interval against this expiry market.
///
/// Requires the package version to be allowed for this market, per-market mint
/// pause to be off, trading globally enabled, manager ownership, a live fresh
/// oracle, and enough expiry allocation to back the post-mint max payout.
/// Returns the minted order ID for future order-scoped flows. Only 1x leverage
/// is currently accepted.
public fun mint(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
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
    market.assert_mint_not_paused();
    config.assert_trading_allowed();
    market.mint_internal(
        config,
        manager,
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

/// Redeem a live or settled order.
///
/// Live redeems require manager ownership and fresh oracle data. Settled redeems
/// are permissionless, pay into the manager balance, and use finalized expiry
/// settlement liability.
public fun redeem(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    order_id: u256,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    market.assert_version_allowed();
    config.assert_not_valuation_in_progress();
    market.assert_market_oracle(market_oracle);
    let redeemed_order = order::from_order_id(order_id);
    market.assert_order_matches(&redeemed_order);
    if (market_oracle.is_settled()) {
        market.redeem_settled_internal(manager, market_oracle, &redeemed_order, ctx);
    } else {
        market.redeem_live_internal(
            config,
            manager,
            market_oracle,
            pyth,
            &redeemed_order,
            clock,
            ctx,
        );
    }
}

/// Resolve a manager's aggregate expiry trading-loss rebate after all positions close.
public fun claim_trading_loss_rebate(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    ctx: &mut TxContext,
) {
    market.assert_version_allowed();
    config.assert_not_valuation_in_progress();
    market.ensure_settlement_finalized(market_oracle);

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

// === Public-Package Functions ===

/// Create and share a funded expiry market for one market oracle.
///
/// The market snapshots the Pyth feed ID, initializes strike exposure state, and
/// takes custody of the pool-provided allocation as LP cash.
public(package) fun create_and_share(
    market_oracle_id: ID,
    pyth_lazer_feed_id: u32,
    config: &ProtocolConfig,
    allocation: Balance<DUSDC>,
    expiry: u64,
    min_strike: u64,
    tick_size: u64,
    allowed_versions: VecSet<u64>,
    ctx: &mut TxContext,
): ID {
    assert_valid_strike_grid(min_strike, tick_size);
    let max_strike = min_strike + tick_size * constants::oracle_strike_grid_ticks!();
    let allocated_capital = allocation.value();
    let market = ExpiryMarket {
        id: object::new(ctx),
        market_oracle_id,
        pyth_lazer_feed_id,
        expiry,
        trading_loss_rebate_rate: config.fee_config().trading_loss_rebate_rate(),
        max_expiry_borrow_fee: config.leverage_config().max_expiry_borrow_fee(),
        allocated_capital,
        lp_cash_balance: allocation,
        fee_balance: balance::zero(),
        unresolved_trading_fees_paid: 0,
        settled_payout_liability: option::none(),
        strike_exposure: strike_exposure::new(tick_size, min_strike, max_strike, ctx),
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
/// expiry's current worst-case payout backing.
public(package) fun return_allocation(market: &mut ExpiryMarket, amount: u64): Balance<DUSDC> {
    market.assert_version_allowed();
    assert!(amount <= market.returnable_capital(), EAllocationBelowMaxPayout);

    market.allocated_capital = market.allocated_capital - amount;
    market.lp_cash_balance.split(amount)
}

/// Consume an expiry valuation and return its market ID and value.
public(package) fun unpack(valuation: ExpiryValuation): (ID, u64) {
    let ExpiryValuation {
        expiry_market_id,
        value,
    } = valuation;
    (expiry_market_id, value)
}

/// Assert that strike grid creation parameters are valid.
public(package) fun assert_valid_strike_grid(min_strike: u64, tick_size: u64) {
    assert!(tick_size > 0, EInvalidTickSize);
    assert!(tick_size % constants::oracle_tick_size_unit!() == 0, EInvalidTickSize);
    assert!(min_strike > 0, EInvalidStrikeGrid);
    assert!(min_strike % tick_size == 0, EInvalidStrikeGrid);
    let ticks = constants::oracle_strike_grid_ticks!();
    assert!(ticks > 0, EInvalidStrikeGrid);
    let _max_strike = min_strike + tick_size * ticks;
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

/// Set per-market mint pause (used by AdminCap admin path on registry).
public(package) fun set_mint_paused(market: &mut ExpiryMarket, paused: bool) {
    market.mint_paused = paused;
}

/// Force `mint_paused = true` (used by PauseCap path on registry; one-way).
public(package) fun pause_mint(market: &mut ExpiryMarket) {
    market.mint_paused = true;
}

/// Finalize and cache settled payout liability for this expiry.
public(package) fun ensure_settlement_finalized(
    market: &mut ExpiryMarket,
    market_oracle: &MarketOracle,
): u64 {
    market.assert_market_oracle(market_oracle);
    if (market.settled_payout_liability.is_some()) {
        return *market.settled_payout_liability.borrow()
    };

    let settlement = market_oracle.settlement_price();
    let settled_liability = market.strike_exposure.settled_value(settlement);
    market.settled_payout_liability = option::some(settled_liability);
    settled_liability
}

/// Finalize settlement if needed and destroy live exposure storage.
///
/// This is a structural cleanup only. Surplus LP cash and fee cash remain in the
/// expiry until a pool sweep moves them.
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
    market.ensure_settlement_finalized(market_oracle);
    market.strike_exposure.destroy_live_indexes();
    market.assert_cash_backing();
}

/// Release settled LP and fee surplus derived from finalized settlement liability.
public(package) fun release_settled_surplus(
    market: &mut ExpiryMarket,
    market_oracle: &MarketOracle,
): (u64, Balance<DUSDC>, Balance<DUSDC>) {
    market.assert_version_allowed();
    let settled_liability = market.ensure_settlement_finalized(market_oracle);
    let rebate_reserve = market.aggregate_rebate_reserve();
    assert!(market.lp_cash_balance.value() >= settled_liability, EInsufficientLpCash);
    assert!(market.fee_balance.value() >= rebate_reserve, EInsufficientFeeBalance);

    let allocated_reduction = market.allocated_capital;
    let returned_cash = if (allocated_reduction > 0) {
        assert!(allocated_reduction >= settled_liability, EAllocationBelowMaxPayout);
        market.allocated_capital = 0;
        let returned_cash_amount = market.lp_cash_balance.value() - settled_liability;
        market.lp_cash_balance.split(returned_cash_amount)
    } else {
        balance::zero()
    };
    let returned_fees = market.split_fee_surplus();
    market.assert_cash_backing();

    (allocated_reduction, returned_cash, returned_fees)
}

// === Private Functions ===

fun current_liabilities(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
): (u64, u64) {
    market.assert_market_oracle(market_oracle);
    let rebate_reserve = market.aggregate_rebate_reserve();
    if (market.settled_payout_liability.is_some()) {
        return (*market.settled_payout_liability.borrow(), rebate_reserve)
    };

    if (market_oracle.is_settled()) {
        let settlement = market_oracle.settlement_price();
        let settled_value = market.strike_exposure.settled_value(settlement);
        (settled_value, rebate_reserve)
    } else {
        market.assert_pyth_feed(pyth);
        market_oracle.assert_not_pending_settlement(clock);
        let live_value = market
            .strike_exposure
            .live_value(
                config.pricing_config(),
                market_oracle,
                pyth,
                clock,
            );
        (live_value, rebate_reserve)
    }
}

fun mint_internal(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
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
    market.strike_exposure.assert_valid_order_strikes(lower_strike, higher_strike);
    assert!(leverage == order::leverage_one_x(), EUnsupportedLeverage);

    let (fair_price, fee_rate) = pricing::quote_mint_live_range(
        config.pricing_config(),
        market_oracle,
        pyth,
        clock,
        lower_strike,
        higher_strike,
        market.max_payout(),
        market.allocated_capital,
    );

    let minted_order = market
        .strike_exposure
        .allocate_order(
            market.expiry,
            lower_strike,
            higher_strike,
            quantity,
            leverage,
            fair_price,
            clock,
        );
    let order_id = minted_order.id();
    let quantity = minted_order.quantity();
    let principal_amount = math::mul(minted_order.minted_price(), quantity);
    let fee_amount = math::mul(fee_rate, quantity);
    let builder_code_id = manager.builder_code_id();
    let builder_fee_amount = builder_fee_amount(&builder_code_id, fee_amount, quantity);
    let payment_amount = principal_amount + fee_amount + builder_fee_amount;

    market.strike_exposure.insert_order(&minted_order);
    assert!(market.allocated_capital >= market.max_payout(), EAllocationBelowMaxPayout);

    manager.add_position(market.id(), order_id);
    let mut payment = manager.withdraw(payment_amount, ctx).into_balance();
    let builder_fee_payment = payment.split(builder_fee_amount);
    send_builder_fee(builder_code_id, builder_fee_payment);
    market.emit_fee_accrued(fee_amount, builder_fee_amount, builder_code_id);
    market.receive_trade_payment(manager, payment, fee_amount);
    market.assert_cash_backing();
    order_id
}

fun redeem_live_internal(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    order: &Order,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    manager.assert_owner(ctx);
    market.assert_pyth_feed(pyth);
    config.pricing_config().assert_live_quote_available(market_oracle, pyth, clock);
    manager.remove_position(market.id(), order.id());

    // Live redeem quotes intentionally use post-removal liability for utilization fees.
    let (lower_strike, higher_strike, quantity) = market.strike_exposure.remove_order(order);

    let (principal_amount, fee_amount) = market.quote_live_redeem_amounts(
        config,
        market_oracle,
        pyth,
        lower_strike,
        higher_strike,
        quantity,
        clock,
    );
    let builder_code_id = manager.builder_code_id();
    let builder_fee_amount = builder_fee_amount(&builder_code_id, fee_amount, quantity).min(
        principal_amount - fee_amount,
    );

    let mut payout = market.dispense_lp_cash(principal_amount);
    let fee = payout.split(fee_amount);
    let builder_fee = payout.split(builder_fee_amount);
    market.collect_redeem_fee(manager, fee);
    send_builder_fee(builder_code_id, builder_fee);
    market.emit_fee_accrued(fee_amount, builder_fee_amount, builder_code_id);
    market.assert_cash_backing();
    market.deposit_live_payout(manager, payout, ctx);
}

fun redeem_settled_internal(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    order: &Order,
    ctx: &mut TxContext,
) {
    market.ensure_settlement_finalized(market_oracle);

    let settlement = market_oracle.settlement_price();
    let payout_amount = market.strike_exposure.settled_order_payout(order, settlement);
    manager.remove_position(market.id(), order.id());
    market.decrease_settled_payout_liability(payout_amount);

    let payout = market.dispense_lp_cash(payout_amount);
    market.deposit_permissionless_payout(manager, payout, ctx);
}

fun quote_live_redeem_amounts(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    lower_strike: u64,
    higher_strike: u64,
    quantity: u64,
    clock: &Clock,
): (u64, u64) {
    let (fair_price, fee_rate) = pricing::quote_live_range(
        config.pricing_config(),
        market_oracle,
        pyth,
        clock,
        lower_strike,
        higher_strike,
        market.max_payout(),
        market.allocated_capital,
    );
    let principal_amount = math::mul(fair_price, quantity);
    let fee_amount = math::mul(fee_rate, quantity).min(principal_amount);
    (principal_amount, fee_amount)
}

fun receive_trade_payment(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    mut payment: Balance<DUSDC>,
    fee_amount: u64,
) {
    let payment_amount = payment.value();
    let fee_payment = payment.split(fee_amount);
    market.fee_balance.join(fee_payment);
    market.lp_cash_balance.join(payment);
    manager.record_cash_paid_to_expiry(market.id(), payment_amount);
    market.record_trading_fee_paid(manager, fee_amount);
}

fun collect_redeem_fee(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    fee: Balance<DUSDC>,
) {
    let fee_amount = fee.value();
    market.fee_balance.join(fee);
    market.record_trading_fee_paid(manager, fee_amount);
}

fun deposit_live_payout(
    market: &ExpiryMarket,
    manager: &mut PredictManager,
    payout: Balance<DUSDC>,
    ctx: &mut TxContext,
) {
    manager.record_cash_received_from_expiry(market.id(), payout.value());
    manager.deposit(payout.into_coin(ctx), ctx);
}

fun deposit_permissionless_payout(
    market: &ExpiryMarket,
    manager: &mut PredictManager,
    payout: Balance<DUSDC>,
    ctx: &mut TxContext,
) {
    manager.record_cash_received_from_expiry(market.id(), payout.value());
    manager.deposit_permissionless(payout.into_coin(ctx), ctx);
}

fun record_trading_fee_paid(market: &mut ExpiryMarket, manager: &mut PredictManager, amount: u64) {
    if (amount == 0) return;
    manager.record_trading_fee_paid(market.id(), amount);
    market.unresolved_trading_fees_paid = market.unresolved_trading_fees_paid + amount;
}

fun resolve_trading_fee_basis(market: &mut ExpiryMarket, amount: u64) {
    assert!(market.unresolved_trading_fees_paid >= amount, EUnresolvedTradingFeesUnderflow);
    market.unresolved_trading_fees_paid = market.unresolved_trading_fees_paid - amount;
}

fun decrease_settled_payout_liability(market: &mut ExpiryMarket, amount: u64) {
    let current_liability = market.finalized_settled_payout_liability();
    assert!(current_liability >= amount, ESettledLiabilityUnderflow);
    assert!(market.lp_cash_balance.value() >= current_liability, EInsufficientLpCash);
    let liability = market.settled_payout_liability.borrow_mut();
    *liability = current_liability - amount;
}

fun finalized_settled_payout_liability(market: &ExpiryMarket): u64 {
    assert!(market.settled_payout_liability.is_some(), ESettlementNotFinalized);
    *market.settled_payout_liability.borrow()
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

fun assert_pyth_feed(market: &ExpiryMarket, pyth: &PythSource) {
    assert!(market.pyth_lazer_feed_id == pyth.feed_id(), EWrongPythSource);
}

fun assert_order_matches(market: &ExpiryMarket, order: &Order) {
    assert!(order.expiry_ms() == market.expiry, EWrongOrderExpiry);
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

fun assert_cash_backing(market: &ExpiryMarket) {
    assert!(market.lp_cash_balance.value() >= market.max_payout(), EInsufficientLpCash);
}

fun assert_mint_not_paused(market: &ExpiryMarket) {
    assert!(!market.mint_paused, EMintPaused);
}

fun aggregate_rebate_reserve(market: &ExpiryMarket): u64 {
    math::mul(market.unresolved_trading_fees_paid, market.trading_loss_rebate_rate)
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

fun send_builder_fee(builder_code_id: Option<ID>, fee: Balance<DUSDC>) {
    if (fee.value() == 0) {
        fee.destroy_zero();
        return
    };
    let builder_code_id = builder_code_id.destroy_some();
    balance::send_funds(fee, builder_code_id.to_address());
}
