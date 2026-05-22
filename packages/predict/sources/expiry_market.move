// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Per-expiry Predict market.
///
/// An ExpiryMarket is the hot shared object for one expiry. It owns the
/// expiry-local DUSDC allocation, strike exposure state, fee balance, trade execution,
/// valuation witness, and settlement compaction state. Pool-wide PLP
/// accounting and allocation coordination remain outside this module.
module deepbook_predict::expiry_market;

use deepbook::math;
use deepbook_predict::{
    constants,
    market_oracle::MarketOracle,
    predict_manager::PredictManager,
    predict_order_id,
    pricing,
    protocol_config::ProtocolConfig,
    pyth_source::PythSource,
    strike_exposure::{Self, LiquidatedOrder, StrikeExposure}
};
use dusdc::dusdc::DUSDC;
use sui::{balance::{Self, Balance}, clock::Clock, event};

const EWrongMarketOracle: u64 = 0;
const EWrongPythSource: u64 = 1;
const EValuationExceedsCash: u64 = 2;
const EAllocationBelowMaxPayout: u64 = 3;
const EZeroQuantity: u64 = 5;
const EMarketCompacted: u64 = 6;
const EInsufficientLpCash: u64 = 8;
const EZeroAllocatedCapital: u64 = 10;
const EInvalidTickSize: u64 = 11;
const EInvalidStrikeGrid: u64 = 12;
const EWrongOrderExpiry: u64 = 13;
const ESettledLiabilityUnderflow: u64 = 16;
const ECompactedLiabilityMismatch: u64 = 17;
const EInsufficientFeeBalance: u64 = 18;
const EInvalidQuantity: u64 = 20;
const EMarketNotCompacted: u64 = 21;
const EInvalidPartialQuantity: u64 = 22;
const EInsufficientPartialRedeemValue: u64 = 23;
const EOrderNotLive: u64 = 24;

const REDEEM_STATE_LIQUIDATED: u8 = 0;
const REDEEM_STATE_LIVE: u8 = 1;
const REDEEM_STATE_SETTLED: u8 = 2;
const REDEEM_STATE_COMPACTED: u8 = 3;

/// Per-expiry market state.
public struct ExpiryMarket has key {
    id: UID,
    market_oracle_id: ID,
    pyth_lazer_feed_id: u32,
    expiry: u64,
    /// Terminal borrow premium snapshotted from leverage config at creation.
    max_expiry_borrow_fee: u64,
    /// Active risk budget assigned by the pool.
    allocated_capital: u64,
    /// LP-owned DUSDC backing this expiry's liability.
    lp_cash_balance: Balance<DUSDC>,
    /// Borrow fees extracted from leveraged order repayments.
    borrow_fee_balance: Balance<DUSDC>,
    /// Unified fee cash, with aggregate rebate reserve tracked separately.
    fee_balance: Balance<DUSDC>,
    /// Unclaimed trading fees backing aggregate expiry trading loss rebates.
    unclaimed_rebate_trading_fees: u64,
    /// Exposure lifecycle state for this expiry's oracle grid.
    strike_exposure: StrikeExposure,
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

/// Emitted when a new order is minted.
public struct OrderMinted has copy, drop, store {
    expiry_market_id: ID,
    predict_manager_id: ID,
    order_id: u256,
    min_strike: u64,
    max_strike: u64,
    quantity: u64,
    leverage: u64,
    inserted_at_ms: u64,
    fair_price: u64,
    price_fee_rate: u64,
    equity_amount: u64,
    borrowed_principal: u64,
    fee_amount: u64,
    builder_fee_amount: u64,
    builder_code_id: Option<ID>,
}

/// Emitted when a leveraged order is removed by expiry-market liquidation.
public struct OrderLiquidated has copy, drop, store {
    expiry_market_id: ID,
    order_id: u256,
    quantity: u64,
    borrowed_principal: u64,
    debt_amount: u64,
    borrow_fee_recovered: u64,
    position_value: u64,
}

/// Emitted when a live order is partially redeemed by replacing the remaining quantity.
public struct OrderPartiallyRedeemed has copy, drop, store {
    expiry_market_id: ID,
    predict_manager_id: ID,
    old_order_id: u256,
    new_order_id: u256,
    closed_quantity: u64,
    remaining_quantity: u64,
    net_payout_amount: u64,
    old_debt_amount: u64,
    old_borrow_fee_amount: u64,
    fair_price: u64,
    price_fee_rate: u64,
    replacement_equity_amount: u64,
    replacement_borrowed_principal: u64,
    fee_amount: u64,
    builder_fee_amount: u64,
    builder_code_id: Option<ID>,
}

/// Emitted when an order is fully removed from a manager.
///
/// `redeem_state` is 0 for liquidated, 1 for live, 2 for settled, and 3 for compacted.
public struct OrderRedeemed has copy, drop, store {
    expiry_market_id: ID,
    predict_manager_id: ID,
    order_id: u256,
    redeem_state: u8,
    quantity: u64,
    gross_payout_amount: u64,
    debt_amount: u64,
    borrow_fee_amount: u64,
    fee_amount: u64,
    builder_fee_amount: u64,
    builder_code_id: Option<ID>,
    net_payout_amount: u64,
}

/// Emitted when a manager claims its aggregate expiry trading loss rebate.
public struct ExpiryRebateClaimed has copy, drop, store {
    expiry_market_id: ID,
    predict_manager_id: ID,
    trading_fees_paid: u64,
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

/// Return extracted borrow fees held by this expiry.
public fun borrow_fee_balance(market: &ExpiryMarket): u64 {
    market.borrow_fee_balance.value()
}

/// Return DUSDC fees held by this expiry.
public fun fee_balance(market: &ExpiryMarket): u64 {
    market.fee_balance.value()
}

/// Return the terminal borrow premium snapshotted for this expiry.
public fun max_expiry_borrow_fee(market: &ExpiryMarket): u64 {
    market.max_expiry_borrow_fee
}

/// Return the expiry-local worst-case payout.
public fun max_payout(market: &ExpiryMarket): u64 {
    market.strike_exposure.max_payout()
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

/// Return true once strike exposure state has been compacted after settlement.
public fun is_compacted(market: &ExpiryMarket): bool {
    market.strike_exposure.is_compacted()
}

/// Produce this expiry's valuation witness for a full-pool valuation.
///
/// Requires the protocol valuation lock and values the current expiry state.
public fun read_valuation(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
): ExpiryValuation {
    config.assert_valuation_in_progress();
    let option_value = market.current_liability(
        config,
        market_oracle,
        pyth,
        clock,
    );
    let lp_cash_balance = market.lp_cash_balance.value();
    let active_debt_amount = if (market.is_compacted()) {
        0
    } else {
        let (debt_amount, _) = market
            .strike_exposure
            .active_debt_terms_at_ms(
                market.expiry,
                market.max_expiry_borrow_fee,
                clock.timestamp_ms(),
            );
        debt_amount
    };
    let lp_assets = lp_cash_balance + active_debt_amount + market.borrow_fee_balance.value();
    let fee_balance = market.fee_balance.value();
    let rebate_reserve = market.aggregate_rebate_reserve();
    assert!(lp_assets >= option_value, EValuationExceedsCash);
    assert!(fee_balance >= rebate_reserve, EInsufficientFeeBalance);
    let lp_fee_surplus = math::mul(
        fee_balance - rebate_reserve,
        config.fee_config().lp_fee_share(),
    );
    ExpiryValuation {
        expiry_market_id: market.id(),
        value: lp_assets - option_value + lp_fee_surplus,
    }
}

/// Remove underwater leveraged orders from this expiry market.
///
/// Live liquidation validates and uses Pyth; settled liquidation only needs the terminal price.
public fun liquidate(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
) {
    config.assert_not_valuation_in_progress();
    market.assert_market_oracle(market_oracle);
    if (market.is_compacted()) return;

    market_oracle.assert_not_pending_settlement(clock);
    let liquidated_orders = if (market_oracle.is_settled()) {
        market
            .strike_exposure
            .liquidate_settled_orders(
                market_oracle.settlement_price(),
                market.expiry,
                market.max_expiry_borrow_fee,
            )
    } else {
        market.assert_pyth_feed(pyth);
        market
            .strike_exposure
            .liquidate_live_orders(
                config.pricing_config(),
                market_oracle,
                pyth,
                clock,
                market.expiry,
                market.max_expiry_borrow_fee,
            )
    };
    market.record_liquidated_orders(liquidated_orders);
}

/// Mint a live position interval against this expiry market.
///
/// Requires trading to be allowed, manager ownership, a live fresh oracle, and
/// enough expiry allocation to back the post-mint max payout. Returns the
/// minted order ID used for future redeems.
public fun mint(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    min_strike: u64,
    max_strike: u64,
    quantity: u64,
    leverage: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    config.assert_trading_allowed();
    market.mint_internal(
        config,
        manager,
        market_oracle,
        pyth,
        min_strike,
        max_strike,
        quantity,
        leverage,
        clock,
        ctx,
    )
}

/// Redeem a live, settled, or compacted position interval by order ID.
///
/// Live redeems require manager ownership and fresh oracle data. Settled and
/// compacted redeems are permissionless and pay into the manager balance.
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
    config.assert_not_valuation_in_progress();
    let redeem_state = market.prepare_full_redeem_state(
        market_oracle,
        pyth,
        order_id,
        clock,
    );

    if (redeem_state == REDEEM_STATE_LIQUIDATED) {
        market.redeem_liquidated_internal(manager, order_id);
    } else if (redeem_state == REDEEM_STATE_COMPACTED) {
        market.redeem_compacted_internal(manager, order_id, ctx);
    } else if (redeem_state == REDEEM_STATE_SETTLED) {
        market.redeem_settled_internal(manager, market_oracle, order_id, ctx);
    } else {
        market.redeem_live_internal(
            config,
            manager,
            market_oracle,
            pyth,
            order_id,
            clock,
            ctx,
        );
    }
}

/// Partially redeem a live order by fully closing it and opening a fresh replacement.
///
/// The old order's full borrow debt is settled, the remaining quantity receives a
/// fresh order ID, and only the net close value is paid into the manager.
public fun redeem_partial(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    order_id: u256,
    close_quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    config.assert_not_valuation_in_progress();
    manager.assert_owner(ctx);
    market.prepare_partial_live_redeem(
        config,
        manager,
        market_oracle,
        pyth,
        order_id,
        clock,
    );
    market.redeem_partial_live_internal(
        config,
        manager,
        market_oracle,
        pyth,
        order_id,
        close_quantity,
        clock,
        ctx,
    )
}

/// Close every remaining order for this manager after settlement and claim expiry trading loss rebate.
public fun close_all_and_claim_rebate(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    ctx: &mut TxContext,
) {
    config.assert_not_valuation_in_progress();
    market.assert_market_oracle(market_oracle);

    let expiry_market_id = market.id();
    if (!market.is_compacted()) {
        market_oracle.settlement_price();
        market.strike_exposure.assert_settled_liquidation_complete();
    };

    let mut order_ids = manager.active_order_ids(expiry_market_id);
    while (!order_ids.is_empty()) {
        let order_id = order_ids.pop_back();
        assert!(predict_order_id::expiry_ms(order_id) == market.expiry, EWrongOrderExpiry);
        if (market.strike_exposure.is_liquidated(order_id)) {
            market.redeem_liquidated_internal(manager, order_id);
        } else if (market.is_compacted()) {
            market.redeem_compacted_internal(manager, order_id, ctx);
        } else {
            market.redeem_settled_internal(manager, market_oracle, order_id, ctx);
        };
    };
    order_ids.destroy_empty();

    let (trading_fees_paid, rebate) = manager.claim_expiry_rebate(expiry_market_id);
    market.release_rebate_trading_fees(trading_fees_paid);
    if (rebate > 0) {
        let rebate = market.dispense_fee_cash(rebate);
        manager.deposit_permissionless(rebate.into_coin(ctx), ctx);
    };
    market.emit_expiry_rebate_claimed(manager, trading_fees_paid, rebate);
}

// === Public-Package Functions ===

/// Return allocation utilization as max payout over allocated capital.
public(package) fun allocation_utilization(market: &ExpiryMarket): u64 {
    let allocated_capital = market.allocated_capital;
    assert!(allocated_capital > 0, EZeroAllocatedCapital);
    math::div(market.max_payout(), allocated_capital)
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
        max_expiry_borrow_fee: config.leverage_config().max_expiry_borrow_fee(),
        allocated_capital,
        lp_cash_balance: allocation,
        borrow_fee_balance: balance::zero(),
        fee_balance: balance::zero(),
        unclaimed_rebate_trading_fees: 0,
        strike_exposure: strike_exposure::new(tick_size, min_strike, max_strike, ctx),
    };
    let id = market.id();
    transfer::share_object(market);
    id
}

/// Add pool-provided DUSDC to this live expiry's allocation and LP cash.
public(package) fun receive_allocation(market: &mut ExpiryMarket, allocation: Balance<DUSDC>) {
    assert!(!market.is_compacted(), EMarketCompacted);
    let amount = allocation.value();
    market.allocated_capital = market.allocated_capital + amount;
    market.lp_cash_balance.join(allocation);
}

/// Return free DUSDC allocation from this expiry to the pool.
///
/// Aborts if the requested amount would reduce allocation or cash below the
/// expiry's current worst-case payout backing.
public(package) fun return_allocation(market: &mut ExpiryMarket, amount: u64): Balance<DUSDC> {
    assert!(amount <= market.returnable_capital(), EAllocationBelowMaxPayout);

    market.allocated_capital = market.allocated_capital - amount;
    market.lp_cash_balance.split(amount)
}

/// Compact settled expiry state and return surplus cash to the pool.
///
/// Consumes strike exposure state, leaves only settled liability backing in the
/// expiry, and leaves fee cash for the pool-coordinated sweep path.
public(package) fun compact_settled(
    market: &mut ExpiryMarket,
    market_oracle: &MarketOracle,
): Balance<DUSDC> {
    market.assert_market_oracle(market_oracle);
    assert!(!market.is_compacted(), EMarketCompacted);

    let settlement = market_oracle.settlement_price();
    market.strike_exposure.assert_settled_liquidation_complete();
    let settled_liability = market.strike_exposure.settled_liability(settlement);
    let (active_debt_amount, active_borrow_fee_amount) = market
        .strike_exposure
        .active_debt_terms_at_ms(
            market.expiry,
            market.max_expiry_borrow_fee,
            market.expiry,
        );
    let net_settled_liability = settled_liability - active_debt_amount;
    let aggregate_rebate_reserve = market.aggregate_rebate_reserve();
    assert!(market.lp_cash_balance.value() >= net_settled_liability, EInsufficientLpCash);
    assert!(market.fee_balance.value() >= aggregate_rebate_reserve, EInsufficientFeeBalance);
    assert!(market.allocated_capital >= net_settled_liability, EAllocationBelowMaxPayout);

    let compacted_payout_liability = market.strike_exposure.compact(settlement);
    assert!(compacted_payout_liability == settled_liability, ECompactedLiabilityMismatch);
    market.strike_exposure.decrease_compacted_liabilities(active_debt_amount);
    // Compaction extracts active borrow fees once; compacted redeems consume net liability.
    market.extract_borrow_fee(active_borrow_fee_amount);
    let returned_cash_amount = market.lp_cash_balance.value() - net_settled_liability;
    let mut returned_cash = market.lp_cash_balance.split(returned_cash_amount);
    let borrow_fee_balance = market.borrow_fee_balance.value();
    returned_cash.join(market.borrow_fee_balance.split(borrow_fee_balance));

    market.allocated_capital = 0;
    market.assert_cash_backing();

    returned_cash
}

/// Return compacted fee surplus above the current aggregate rebate reserve.
public(package) fun sweep_compacted_fee_surplus(market: &mut ExpiryMarket): Balance<DUSDC> {
    assert!(market.is_compacted(), EMarketNotCompacted);
    let aggregate_rebate_reserve = market.aggregate_rebate_reserve();
    assert!(market.fee_balance.value() >= aggregate_rebate_reserve, EInsufficientFeeBalance);
    let fee_surplus = market.fee_balance.value() - aggregate_rebate_reserve;
    market.fee_balance.split(fee_surplus)
}

// === Private Functions ===

fun current_liability(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
): u64 {
    market.assert_market_oracle(market_oracle);
    if (market.is_compacted()) {
        let (_, payout_liability) = market.strike_exposure.compacted_values();
        return payout_liability
    };

    market_oracle.assert_not_pending_settlement(clock);
    if (market_oracle.is_settled()) {
        let settlement = market_oracle.settlement_price();
        market.strike_exposure.settled_liability(settlement)
    } else {
        market.assert_pyth_feed(pyth);
        market
            .strike_exposure
            .live_values(
                config.pricing_config(),
                market_oracle,
                pyth,
                clock,
            )
    }
}

// Return the full redeem branch without running a full liquidation sweep.
fun prepare_full_redeem_state(
    market: &ExpiryMarket,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    order_id: u256,
    clock: &Clock,
): u8 {
    assert!(predict_order_id::expiry_ms(order_id) == market.expiry, EWrongOrderExpiry);
    if (market.strike_exposure.is_liquidated(order_id)) return REDEEM_STATE_LIQUIDATED;
    if (market.is_compacted()) return REDEEM_STATE_COMPACTED;

    market.assert_market_oracle(market_oracle);
    market_oracle.assert_not_pending_settlement(clock);

    if (market_oracle.is_settled()) {
        market.strike_exposure.assert_settled_liquidation_complete();
        REDEEM_STATE_SETTLED
    } else {
        market.assert_pyth_feed(pyth);
        REDEEM_STATE_LIVE
    }
}

// Partial redeem can only execute the live close-and-replace branch, so reject
// a liquidatable target and require the explicit public liquidation flow first.
fun prepare_partial_live_redeem(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    manager: &PredictManager,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    order_id: u256,
    clock: &Clock,
) {
    assert!(predict_order_id::expiry_ms(order_id) == market.expiry, EWrongOrderExpiry);
    assert!(!market.is_compacted(), EOrderNotLive);
    assert!(!market.strike_exposure.is_liquidated(order_id), EOrderNotLive);
    market.assert_market_oracle(market_oracle);
    market.assert_pyth_feed(pyth);
    market_oracle.assert_active(clock);

    let quantity = predict_order_id::quantity(order_id);
    assert_valid_quantity(quantity);
    assert!(manager.position(market.id(), order_id) == quantity, EOrderNotLive);

    if (predict_order_id::is_leveraged_order(order_id)) {
        assert!(market.strike_exposure.is_active_leveraged_order(order_id), EOrderNotLive);
        let position_value = market.live_order_value(
            config,
            market_oracle,
            pyth,
            clock,
            order_id,
            quantity,
        );
        let (debt_amount, _) = market
            .strike_exposure
            .order_debt_terms_at_ms(
                market.expiry,
                market.max_expiry_borrow_fee,
                order_id,
                clock.timestamp_ms(),
            );
        assert!(position_value > debt_amount, EOrderNotLive);
    };
}

fun assert_pyth_feed(market: &ExpiryMarket, pyth: &PythSource) {
    assert!(market.pyth_lazer_feed_id == pyth.feed_id(), EWrongPythSource);
}

fun assert_valid_quantity(quantity: u64) {
    assert!(quantity > 0, EZeroQuantity);
    assert!(quantity % constants::position_lot_size!() == 0, EInvalidQuantity);
}

fun assert_valid_partial_quantity(close_quantity: u64, order_quantity: u64) {
    assert_valid_quantity(close_quantity);
    assert!(close_quantity < order_quantity, EInvalidPartialQuantity);
}

fun assert_cash_backing(market: &ExpiryMarket) {
    assert!(market.lp_cash_balance.value() >= market.max_payout(), EInsufficientLpCash);
}

fun aggregate_rebate_reserve(market: &ExpiryMarket): u64 {
    math::mul(
        market.unclaimed_rebate_trading_fees,
        constants::expiry_trading_loss_rebate_rate!(),
    )
}

fun record_pool_trading_fee(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    fee_amount: u64,
) {
    manager.record_trading_fee_paid(market.id(), fee_amount);
    market.unclaimed_rebate_trading_fees = market.unclaimed_rebate_trading_fees + fee_amount;
}

fun release_rebate_trading_fees(market: &mut ExpiryMarket, fee_amount: u64) {
    assert!(market.unclaimed_rebate_trading_fees >= fee_amount, EInsufficientFeeBalance);
    market.unclaimed_rebate_trading_fees = market.unclaimed_rebate_trading_fees - fee_amount;
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

fun extract_borrow_fee(market: &mut ExpiryMarket, amount: u64) {
    if (amount == 0) return;
    let borrow_fee = market.lp_cash_balance.split(amount);
    market.borrow_fee_balance.join(borrow_fee);
}

fun record_liquidated_orders(
    market: &mut ExpiryMarket,
    liquidated_orders: vector<LiquidatedOrder>,
) {
    let mut liquidated_orders = liquidated_orders;
    let mut borrow_fee_recovered = 0;
    while (!liquidated_orders.is_empty()) {
        let order = liquidated_orders.pop_back();
        let (
            order_id,
            quantity,
            borrowed_principal,
            debt_amount,
            order_borrow_fee_recovered,
            position_value,
        ) = strike_exposure::unpack_liquidated_order(order);
        borrow_fee_recovered = borrow_fee_recovered + order_borrow_fee_recovered;
        event::emit(OrderLiquidated {
            expiry_market_id: market.id(),
            order_id,
            quantity,
            borrowed_principal,
            debt_amount,
            borrow_fee_recovered: order_borrow_fee_recovered,
            position_value,
        });
    };
    liquidated_orders.destroy_empty();
    market.extract_borrow_fee(borrow_fee_recovered);
}

fun quote_mint_strikes(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
    min_strike: u64,
    max_strike: u64,
): (u64, u64) {
    let (fair_price, price_fee_rate) = market
        .strike_exposure
        .quote_live_strikes(
            config.pricing_config(),
            market_oracle,
            pyth,
            clock,
            min_strike,
            max_strike,
        );
    pricing::assert_mint_ask_price(config.pricing_config(), fair_price + price_fee_rate);
    (fair_price, price_fee_rate)
}

fun order_principal_terms(order_id: u256): (u64, u64) {
    let principal_amount = predict_order_id::principal_amount(order_id);
    let equity_amount = predict_order_id::equity_amount(
        principal_amount,
        predict_order_id::leverage(order_id),
    );
    let borrowed_principal = predict_order_id::borrowed_principal(order_id);
    (equity_amount, borrowed_principal)
}

fun insert_live_order_state(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    order_id: u256,
) {
    market.strike_exposure.insert_order(order_id);
    assert!(market.allocated_capital >= market.max_payout(), EAllocationBelowMaxPayout);
    manager.increase_position(market.id(), order_id);
}

fun remove_live_order_state(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    order_id: u256,
    borrow_fee_amount: u64,
) {
    manager.remove_position(market.id(), order_id);
    market.strike_exposure.remove_order(order_id);
    market.extract_borrow_fee(borrow_fee_amount);
}

fun settle_mint_payment(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    builder_code_id: Option<ID>,
    equity_amount: u64,
    fee_amount: u64,
    builder_fee_amount: u64,
    ctx: &mut TxContext,
) {
    manager.record_cash_paid_to_expiry(market.id(), equity_amount + fee_amount);
    market.record_pool_trading_fee(manager, fee_amount);
    let payment_amount = equity_amount + fee_amount + builder_fee_amount;
    let mut payment = manager.withdraw(payment_amount, ctx).into_balance();
    let builder_fee_payment = payment.split(builder_fee_amount);
    let fee_payment = payment.split(fee_amount);
    market.fee_balance.join(fee_payment);
    send_builder_fee(builder_code_id, builder_fee_payment);
    market.emit_fee_accrued(fee_amount, builder_fee_amount, builder_code_id);
    market.lp_cash_balance.join(payment);
    market.assert_cash_backing();
}

fun live_redeem_fee_terms(
    manager: &PredictManager,
    price_fee_rate: u64,
    fee_quantity: u64,
    available_amount: u64,
): (Option<ID>, u64, u64) {
    let fee_amount = math::mul(price_fee_rate, fee_quantity).min(available_amount);
    let builder_code_id = manager.builder_code_id();
    let builder_fee_amount = builder_fee_amount(&builder_code_id, fee_amount, fee_quantity).min(
        available_amount - fee_amount,
    );
    (builder_code_id, fee_amount, builder_fee_amount)
}

fun settle_live_redeem_payout(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    builder_code_id: Option<ID>,
    payout_amount: u64,
    fee_amount: u64,
    builder_fee_amount: u64,
    ctx: &mut TxContext,
): u64 {
    let mut payout = market.dispense_lp_cash(payout_amount);
    let fee = payout.split(fee_amount);
    let builder_fee = payout.split(builder_fee_amount);
    market.fee_balance.join(fee);
    send_builder_fee(builder_code_id, builder_fee);
    market.emit_fee_accrued(fee_amount, builder_fee_amount, builder_code_id);
    market.assert_cash_backing();
    market.record_pool_trading_fee(manager, fee_amount);
    let net_payout_amount = payout.value();
    manager.record_cash_received_from_expiry(market.id(), net_payout_amount);
    manager.deposit(payout.into_coin(ctx), ctx);
    net_payout_amount
}

fun emit_order_minted(
    market: &ExpiryMarket,
    manager: &PredictManager,
    order_id: u256,
    min_strike: u64,
    max_strike: u64,
    quantity: u64,
    leverage: u64,
    fair_price: u64,
    price_fee_rate: u64,
    equity_amount: u64,
    borrowed_principal: u64,
    fee_amount: u64,
    builder_fee_amount: u64,
    builder_code_id: Option<ID>,
) {
    event::emit(OrderMinted {
        expiry_market_id: market.id(),
        predict_manager_id: manager.id(),
        order_id,
        min_strike,
        max_strike,
        quantity,
        leverage,
        inserted_at_ms: predict_order_id::inserted_at_ms(order_id),
        fair_price,
        price_fee_rate,
        equity_amount,
        borrowed_principal,
        fee_amount,
        builder_fee_amount,
        builder_code_id,
    });
}

fun emit_order_redeemed(
    market: &ExpiryMarket,
    manager: &PredictManager,
    order_id: u256,
    redeem_state: u8,
    quantity: u64,
    gross_payout_amount: u64,
    debt_amount: u64,
    borrow_fee_amount: u64,
    fee_amount: u64,
    builder_fee_amount: u64,
    builder_code_id: Option<ID>,
    net_payout_amount: u64,
) {
    event::emit(OrderRedeemed {
        expiry_market_id: market.id(),
        predict_manager_id: manager.id(),
        order_id,
        redeem_state,
        quantity,
        gross_payout_amount,
        debt_amount,
        borrow_fee_amount,
        fee_amount,
        builder_fee_amount,
        builder_code_id,
        net_payout_amount,
    });
}

fun emit_order_partially_redeemed(
    market: &ExpiryMarket,
    manager: &PredictManager,
    old_order_id: u256,
    new_order_id: u256,
    closed_quantity: u64,
    remaining_quantity: u64,
    net_payout_amount: u64,
    old_debt_amount: u64,
    old_borrow_fee_amount: u64,
    fair_price: u64,
    price_fee_rate: u64,
    replacement_equity_amount: u64,
    replacement_borrowed_principal: u64,
    fee_amount: u64,
    builder_fee_amount: u64,
    builder_code_id: Option<ID>,
) {
    event::emit(OrderPartiallyRedeemed {
        expiry_market_id: market.id(),
        predict_manager_id: manager.id(),
        old_order_id,
        new_order_id,
        closed_quantity,
        remaining_quantity,
        net_payout_amount,
        old_debt_amount,
        old_borrow_fee_amount,
        fair_price,
        price_fee_rate,
        replacement_equity_amount,
        replacement_borrowed_principal,
        fee_amount,
        builder_fee_amount,
        builder_code_id,
    });
}

fun emit_expiry_rebate_claimed(
    market: &ExpiryMarket,
    manager: &PredictManager,
    trading_fees_paid: u64,
    rebate_amount: u64,
) {
    event::emit(ExpiryRebateClaimed {
        expiry_market_id: market.id(),
        predict_manager_id: manager.id(),
        trading_fees_paid,
        rebate_amount,
    });
}

fun mint_internal(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    min_strike: u64,
    max_strike: u64,
    quantity: u64,
    leverage: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    manager.assert_owner(ctx);
    market.assert_market_oracle(market_oracle);
    market.assert_pyth_feed(pyth);
    assert_valid_quantity(quantity);

    let (fair_price, price_fee_rate) = market.quote_mint_strikes(
        config,
        market_oracle,
        pyth,
        clock,
        min_strike,
        max_strike,
    );
    let order_id = market
        .strike_exposure
        .new_order_id(
            market.expiry,
            min_strike,
            max_strike,
            quantity,
            leverage,
            fair_price,
            clock,
        );
    let builder_code_id = manager.builder_code_id();
    let (equity_amount, borrowed_principal) = order_principal_terms(order_id);
    let fee_amount = math::mul(price_fee_rate, quantity);
    let builder_fee_amount = builder_fee_amount(&builder_code_id, fee_amount, quantity);

    market.insert_live_order_state(manager, order_id);
    market.settle_mint_payment(
        manager,
        builder_code_id,
        equity_amount,
        fee_amount,
        builder_fee_amount,
        ctx,
    );
    market.emit_order_minted(
        manager,
        order_id,
        min_strike,
        max_strike,
        quantity,
        leverage,
        fair_price,
        price_fee_rate,
        equity_amount,
        borrowed_principal,
        fee_amount,
        builder_fee_amount,
        builder_code_id,
    );
    order_id
}

fun redeem_live_internal(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    order_id: u256,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    manager.assert_owner(ctx);
    market.assert_pyth_feed(pyth);
    let quantity = predict_order_id::quantity(order_id);
    assert_valid_quantity(quantity);

    let (fair_price, price_fee_rate) = market
        .strike_exposure
        .quote_live_order(
            config.pricing_config(),
            market_oracle,
            pyth,
            clock,
            order_id,
        );
    let principal_amount = math::mul(fair_price, quantity);
    let (debt_amount, borrow_fee_amount) = market
        .strike_exposure
        .order_debt_terms_at_ms(
            market.expiry,
            market.max_expiry_borrow_fee,
            order_id,
            clock.timestamp_ms(),
        );
    if (predict_order_id::is_leveraged_order(order_id)) {
        assert!(principal_amount > debt_amount, EOrderNotLive);
    };
    let redeemable_principal = principal_amount - debt_amount;
    let (builder_code_id, fee_amount, builder_fee_amount) = live_redeem_fee_terms(
        manager,
        price_fee_rate,
        quantity,
        redeemable_principal,
    );

    market.remove_live_order_state(manager, order_id, borrow_fee_amount);
    let net_payout_amount = market.settle_live_redeem_payout(
        manager,
        builder_code_id,
        redeemable_principal,
        fee_amount,
        builder_fee_amount,
        ctx,
    );
    market.emit_order_redeemed(
        manager,
        order_id,
        REDEEM_STATE_LIVE,
        quantity,
        principal_amount,
        debt_amount,
        borrow_fee_amount,
        fee_amount,
        builder_fee_amount,
        builder_code_id,
        net_payout_amount,
    );
}

fun redeem_partial_live_internal(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    order_id: u256,
    close_quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    let old_quantity = predict_order_id::quantity(order_id);
    assert_valid_quantity(old_quantity);
    assert_valid_partial_quantity(close_quantity, old_quantity);
    let remaining_quantity = old_quantity - close_quantity;
    assert_valid_quantity(remaining_quantity);

    let (fair_price, price_fee_rate) = market
        .strike_exposure
        .quote_live_order(
            config.pricing_config(),
            market_oracle,
            pyth,
            clock,
            order_id,
        );
    let old_principal_amount = math::mul(fair_price, old_quantity);
    let (old_debt_amount, old_borrow_fee_amount) = market
        .strike_exposure
        .order_debt_terms_at_ms(
            market.expiry,
            market.max_expiry_borrow_fee,
            order_id,
            clock.timestamp_ms(),
        );
    let old_equity_value = old_principal_amount - old_debt_amount;
    let new_order_id = market
        .strike_exposure
        .replacement_order_id(market.expiry, order_id, remaining_quantity, fair_price, clock);
    let (replacement_equity_amount, replacement_borrowed_principal) = order_principal_terms(
        new_order_id,
    );
    assert!(old_equity_value >= replacement_equity_amount, EInsufficientPartialRedeemValue);
    let available_payout_amount = old_equity_value - replacement_equity_amount;
    let (builder_code_id, fee_amount, builder_fee_amount) = live_redeem_fee_terms(
        manager,
        price_fee_rate,
        close_quantity,
        available_payout_amount,
    );

    market.remove_live_order_state(manager, order_id, old_borrow_fee_amount);
    market.insert_live_order_state(manager, new_order_id);

    let net_payout_amount = market.settle_live_redeem_payout(
        manager,
        builder_code_id,
        available_payout_amount,
        fee_amount,
        builder_fee_amount,
        ctx,
    );
    market.emit_order_partially_redeemed(
        manager,
        order_id,
        new_order_id,
        close_quantity,
        remaining_quantity,
        net_payout_amount,
        old_debt_amount,
        old_borrow_fee_amount,
        fair_price,
        price_fee_rate,
        replacement_equity_amount,
        replacement_borrowed_principal,
        fee_amount,
        builder_fee_amount,
        builder_code_id,
    );
    new_order_id
}

fun redeem_settled_internal(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    order_id: u256,
    ctx: &mut TxContext,
) {
    let quantity = predict_order_id::quantity(order_id);
    assert_valid_quantity(quantity);

    let settlement = market_oracle.settlement_price();
    let (payout_amount, current_liability) = {
        let exposure = &market.strike_exposure;
        let current_liability = exposure.settled_liability(settlement);
        let order_price = exposure.settled_order_price(settlement, order_id);
        let payout_amount = math::mul(order_price, quantity);
        (payout_amount, current_liability)
    };
    assert!(current_liability >= payout_amount, ESettledLiabilityUnderflow);

    let (debt_amount, borrow_fee_amount) = market
        .strike_exposure
        .order_debt_terms_at_ms(
            market.expiry,
            market.max_expiry_borrow_fee,
            order_id,
            market.expiry,
        );
    if (predict_order_id::is_leveraged_order(order_id)) {
        assert!(payout_amount > debt_amount, EOrderNotLive);
    };
    let net_payout_amount = payout_amount - debt_amount;
    manager.remove_position(market.id(), order_id);
    market.strike_exposure.remove_order(order_id);
    market.extract_borrow_fee(borrow_fee_amount);
    let payout = market.dispense_lp_cash(net_payout_amount);
    manager.record_cash_received_from_expiry(market.id(), payout.value());
    manager.deposit_permissionless(payout.into_coin(ctx), ctx);
    market.emit_order_redeemed(
        manager,
        order_id,
        REDEEM_STATE_SETTLED,
        quantity,
        payout_amount,
        debt_amount,
        borrow_fee_amount,
        0,
        0,
        option::none(),
        net_payout_amount,
    );
}

fun redeem_compacted_internal(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    order_id: u256,
    ctx: &mut TxContext,
) {
    let quantity = predict_order_id::quantity(order_id);
    assert_valid_quantity(quantity);

    let (settlement, current_payout_liability) = market.strike_exposure.compacted_values();
    let order_price = market.strike_exposure.settled_order_price(settlement, order_id);
    let gross_payout_amount = math::mul(order_price, quantity);
    let (debt_amount, borrow_fee_amount) = market
        .strike_exposure
        .order_debt_terms_at_ms(
            market.expiry,
            market.max_expiry_borrow_fee,
            order_id,
            market.expiry,
        );
    // Borrow fees for compacted orders were already extracted during compaction.
    if (predict_order_id::is_leveraged_order(order_id)) {
        assert!(gross_payout_amount > debt_amount, EOrderNotLive);
    };
    let payout_amount = gross_payout_amount - debt_amount;
    assert!(market.lp_cash_balance.value() >= current_payout_liability, EInsufficientLpCash);

    manager.remove_position(market.id(), order_id);
    market.strike_exposure.remove_compacted_order(order_id, payout_amount);
    let payout = market.dispense_lp_cash(payout_amount);
    manager.record_cash_received_from_expiry(market.id(), payout.value());
    manager.deposit_permissionless(payout.into_coin(ctx), ctx);
    market.emit_order_redeemed(
        manager,
        order_id,
        REDEEM_STATE_COMPACTED,
        quantity,
        gross_payout_amount,
        debt_amount,
        borrow_fee_amount,
        0,
        0,
        option::none(),
        payout_amount,
    );
}

fun redeem_liquidated_internal(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    order_id: u256,
) {
    let quantity = predict_order_id::quantity(order_id);
    assert_valid_quantity(quantity);
    manager.remove_position(market.id(), order_id);
    market.strike_exposure.remove_liquidated_order(order_id);
    market.emit_order_redeemed(
        manager,
        order_id,
        REDEEM_STATE_LIQUIDATED,
        quantity,
        0,
        0,
        0,
        0,
        0,
        option::none(),
        0,
    );
}

fun live_order_value(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
    order_id: u256,
    quantity: u64,
): u64 {
    let (fair_price, _) = market
        .strike_exposure
        .quote_live_order(
            config.pricing_config(),
            market_oracle,
            pyth,
            clock,
            order_id,
        );
    math::mul(fair_price, quantity)
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
