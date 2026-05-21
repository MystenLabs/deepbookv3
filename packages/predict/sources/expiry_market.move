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
    leverage_book::{Self, LeverageBook},
    leverage_config,
    market_oracle::MarketOracle,
    predict_manager::PredictManager,
    predict_order_id,
    pricing,
    protocol_config::ProtocolConfig,
    pyth_source::PythSource,
    strike_exposure::{Self, StrikeExposure}
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

/// Per-expiry market state.
public struct ExpiryMarket has key {
    id: UID,
    market_oracle_id: ID,
    pyth_lazer_feed_id: u32,
    expiry: u64,
    /// Settlement loss rebate rate snapshotted from fee config at creation.
    settlement_loss_rebate_rate: u64,
    /// Terminal borrow premium snapshotted from leverage config at creation.
    max_expiry_borrow_fee: u64,
    /// Active risk budget assigned by the pool.
    allocated_capital: u64,
    /// LP-owned DUSDC backing this expiry's liability.
    lp_cash_balance: Balance<DUSDC>,
    /// Borrow fees extracted from leveraged order repayments.
    borrow_fee_balance: Balance<DUSDC>,
    /// Unified fee cash used for settlement loss rebates until compaction.
    fee_balance: Balance<DUSDC>,
    /// Exposure lifecycle state for this expiry's oracle grid.
    strike_exposure: StrikeExposure,
    /// Brute-force active/liquidated index for leveraged orders.
    leverage_book: LeverageBook,
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

/// Return the settlement loss rebate rate snapshotted for this expiry.
public fun settlement_loss_rebate_rate(market: &ExpiryMarket): u64 {
    market.settlement_loss_rebate_rate
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
/// Requires the protocol valuation lock and first removes underwater leveraged
/// orders so valuation sees only live positions.
public fun read_valuation(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
): ExpiryValuation {
    config.assert_valuation_in_progress();
    market.liquidate(config, market_oracle, pyth, clock);
    let (option_value, rebate_liability) = market.current_liabilities(
        config,
        market_oracle,
        pyth,
        clock,
    );
    let lp_cash_balance = market.lp_cash_balance.value();
    let active_debt_amount = if (market.is_compacted()) {
        0
    } else {
        let (debt_amount, _) = market.active_debt_terms_at_ms(clock.timestamp_ms());
        debt_amount
    };
    let lp_assets = lp_cash_balance + active_debt_amount + market.borrow_fee_balance.value();
    let fee_balance = market.fee_balance.value();
    assert!(lp_assets >= option_value, EValuationExceedsCash);
    assert!(fee_balance >= rebate_liability, EInsufficientFeeBalance);
    let lp_fee_surplus = lp_fee_surplus_value(config, fee_balance - rebate_liability);
    ExpiryValuation {
        expiry_market_id: market.id(),
        value: lp_assets - option_value + lp_fee_surplus,
    }
}

/// Remove underwater leveraged orders from this expiry market.
public fun liquidate(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
) {
    market.assert_market_oracle(market_oracle);
    market.assert_pyth_feed(pyth);
    if (market.is_compacted()) return;

    market_oracle.assert_not_pending_settlement(clock);
    if (market_oracle.is_settled()) {
        let expiry = market.expiry;
        market.liquidate_settled_orders(market_oracle.settlement_price(), expiry);
    } else {
        market.liquidate_live_orders(config, market_oracle, pyth, clock);
    };
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
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    config.assert_not_valuation_in_progress();
    assert!(predict_order_id::expiry_ms(order_id) == market.expiry, EWrongOrderExpiry);
    if (market.leverage_book.is_liquidated(order_id)) {
        market.redeem_liquidated_internal(manager, order_id, quantity);
        return
    };

    if (!market.is_compacted()) {
        market.liquidate(config, market_oracle, pyth, clock);
        if (market.leverage_book.is_liquidated(order_id)) {
            market.redeem_liquidated_internal(manager, order_id, quantity);
            return
        };
    };

    if (market.is_compacted()) {
        market.redeem_compacted_internal(manager, order_id, quantity, ctx);
    } else if (market_oracle.is_settled()) {
        market.redeem_settled_internal(manager, market_oracle, order_id, quantity, ctx);
    } else {
        market.redeem_live_internal(
            config,
            manager,
            market_oracle,
            pyth,
            order_id,
            quantity,
            clock,
            ctx,
        );
    }
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
        settlement_loss_rebate_rate: config.fee_config().settlement_loss_rebate_rate(),
        max_expiry_borrow_fee: config.leverage_config().max_expiry_borrow_fee(),
        allocated_capital,
        lp_cash_balance: allocation,
        borrow_fee_balance: balance::zero(),
        fee_balance: balance::zero(),
        strike_exposure: strike_exposure::new(tick_size, min_strike, max_strike, ctx),
        leverage_book: leverage_book::new(ctx),
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
/// expiry, leaves only settlement loss rebate liability in the fee balance, and
/// returns all other cash to the pool.
public(package) fun compact_settled(
    market: &mut ExpiryMarket,
    market_oracle: &MarketOracle,
): (Balance<DUSDC>, Balance<DUSDC>) {
    market.assert_market_oracle(market_oracle);
    assert!(!market.is_compacted(), EMarketCompacted);

    let settlement = market_oracle.settlement_price();
    let expiry = market.expiry;
    market.liquidate_settled_orders(settlement, expiry);
    let (settled_liability, losing_fee_basis) = market.strike_exposure.settled_values(settlement);
    let (active_debt_amount, active_borrow_fee_amount) = market.active_debt_terms_at_ms(expiry);
    let net_settled_liability = settled_liability - active_debt_amount;
    let rebate_liability = market.rebate_liability(losing_fee_basis);
    assert!(market.lp_cash_balance.value() >= net_settled_liability, EInsufficientLpCash);
    assert!(market.fee_balance.value() >= rebate_liability, EInsufficientFeeBalance);
    assert!(market.allocated_capital >= net_settled_liability, EAllocationBelowMaxPayout);

    let compacted_payout_liability = market.strike_exposure.compact(settlement, rebate_liability);
    assert!(compacted_payout_liability == settled_liability, ECompactedLiabilityMismatch);
    market.strike_exposure.decrease_compacted_liabilities(active_debt_amount, 0);
    market.extract_borrow_fee(active_borrow_fee_amount);
    let returned_cash_amount = market.lp_cash_balance.value() - net_settled_liability;
    let mut returned_cash = market.lp_cash_balance.split(returned_cash_amount);
    let borrow_fee_balance = market.borrow_fee_balance.value();
    returned_cash.join(market.borrow_fee_balance.split(borrow_fee_balance));
    let returned_fee_amount = market.fee_balance.value() - rebate_liability;
    let returned_fees = market.fee_balance.split(returned_fee_amount);

    market.allocated_capital = 0;
    market.assert_cash_backing();

    (returned_cash, returned_fees)
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
    market.assert_pyth_feed(pyth);
    market_oracle.assert_not_pending_settlement(clock);

    if (market.is_compacted()) {
        let (_, payout_liability, rebate_liability) = market.strike_exposure.compacted_values();
        return (payout_liability, rebate_liability)
    };

    if (market_oracle.is_settled()) {
        let settlement = market_oracle.settlement_price();
        let (settled_value, losing_fee_basis) = market.strike_exposure.settled_values(settlement);
        (settled_value, market.rebate_liability(losing_fee_basis))
    } else {
        let (live_value, max_losing_fee_basis) = market
            .strike_exposure
            .live_values(
                config.pricing_config(),
                market_oracle,
                pyth,
                clock,
            );
        (live_value, market.rebate_liability(max_losing_fee_basis))
    }
}

fun assert_pyth_feed(market: &ExpiryMarket, pyth: &PythSource) {
    assert!(market.pyth_lazer_feed_id == pyth.feed_id(), EWrongPythSource);
}

fun assert_valid_quantity(quantity: u64) {
    assert!(quantity > 0, EZeroQuantity);
    assert!(quantity % constants::position_lot_size!() == 0, EInvalidQuantity);
}

fun assert_cash_backing(market: &ExpiryMarket) {
    assert!(market.lp_cash_balance.value() >= market.max_payout(), EInsufficientLpCash);
}

fun rebate_liability(market: &ExpiryMarket, losing_fee_basis: u64): u64 {
    math::mul(losing_fee_basis, market.settlement_loss_rebate_rate)
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

fun lp_fee_surplus_value(config: &ProtocolConfig, fee_surplus: u64): u64 {
    math::mul(fee_surplus, config.fee_config().lp_fee_share())
}

fun active_debt_terms_at_ms(market: &ExpiryMarket, now_ms: u64): (u64, u64) {
    let mut total_debt = 0;
    let mut total_fee = 0;
    let mut order_ids = market.leverage_book.active_order_ids();
    while (!order_ids.is_empty()) {
        let order_id = order_ids.pop_back();
        let (_, borrowed_principal, _) = market.leverage_book.order_terms(order_id);
        let (debt_amount, borrow_fee_amount) = leverage_config::debt_terms(
            market.max_expiry_borrow_fee,
            market.expiry,
            predict_order_id::inserted_at_ms(order_id),
            now_ms,
            borrowed_principal,
        );
        total_debt = total_debt + debt_amount;
        total_fee = total_fee + borrow_fee_amount;
    };
    order_ids.destroy_empty();
    (total_debt, total_fee)
}

fun order_debt_terms(
    market: &ExpiryMarket,
    order_id: u256,
    quantity: u64,
    now_ms: u64,
): (u64, u64) {
    if (!predict_order_id::is_leveraged_order(order_id)) return (0, 0);

    let borrowed_principal = market.leverage_book.borrowed_principal_to_remove(order_id, quantity);
    let (debt_amount, borrow_fee_amount) = leverage_config::debt_terms(
        market.max_expiry_borrow_fee,
        market.expiry,
        predict_order_id::inserted_at_ms(order_id),
        now_ms,
        borrowed_principal,
    );
    (debt_amount, borrow_fee_amount)
}

fun extract_borrow_fee(market: &mut ExpiryMarket, amount: u64) {
    if (amount == 0) return;
    let borrow_fee = market.lp_cash_balance.split(amount);
    market.borrow_fee_balance.join(borrow_fee);
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

    let order_id = market
        .strike_exposure
        .new_order_id(market.expiry, min_strike, max_strike, leverage, clock);

    // Quote before recording exposure so the fee basis stored with the position
    // matches the exact fee charged for this mint.
    let (fair_price, price_fee_rate) = market
        .strike_exposure
        .quote_live_order(
            config.pricing_config(),
            market_oracle,
            pyth,
            clock,
            order_id,
        );
    pricing::assert_mint_ask_price(config.pricing_config(), fair_price + price_fee_rate);
    let principal_amount = math::mul(fair_price, quantity);
    let equity_amount = predict_order_id::equity_amount(principal_amount, leverage);
    let borrowed_principal = principal_amount - equity_amount;
    let fee_amount = math::mul(price_fee_rate, quantity);
    let builder_code_id = manager.builder_code_id();
    let builder_fee_amount = builder_fee_amount(&builder_code_id, fee_amount, quantity);
    let payment_amount = equity_amount + fee_amount + builder_fee_amount;

    market.strike_exposure.insert_order(order_id, quantity, fee_amount);
    if (predict_order_id::is_leveraged_order(order_id)) {
        market.leverage_book.insert_order(order_id, quantity, borrowed_principal, fee_amount);
    };
    assert!(market.allocated_capital >= market.max_payout(), EAllocationBelowMaxPayout);

    manager.increase_position(market.id(), order_id, quantity, fee_amount);
    let mut payment = manager.withdraw(payment_amount, ctx).into_balance();
    let builder_fee_payment = payment.split(builder_fee_amount);
    let fee_payment = payment.split(fee_amount);
    market.fee_balance.join(fee_payment);
    send_builder_fee(builder_code_id, builder_fee_payment);
    market.emit_fee_accrued(fee_amount, builder_fee_amount, builder_code_id);
    market.lp_cash_balance.join(payment);
    market.assert_cash_backing();
    event::emit(OrderMinted {
        expiry_market_id: market.id(),
        predict_manager_id: manager.id(),
        order_id,
        min_strike,
        max_strike,
        quantity,
        leverage,
        inserted_at_ms: predict_order_id::inserted_at_ms(order_id),
    });
    order_id
}

fun redeem_live_internal(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    order_id: u256,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    manager.assert_owner(ctx);
    market.assert_pyth_feed(pyth);
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
    let (debt_amount, borrow_fee_amount) = market.order_debt_terms(
        order_id,
        quantity,
        clock.timestamp_ms(),
    );
    let redeemable_principal = principal_amount - debt_amount;
    let fee_amount = math::mul(price_fee_rate, quantity).min(redeemable_principal);
    let builder_code_id = manager.builder_code_id();
    let builder_fee_amount = builder_fee_amount(&builder_code_id, fee_amount, quantity).min(
        redeemable_principal - fee_amount,
    );

    let removed_fee_basis = manager.decrease_position(market.id(), order_id, quantity);
    if (predict_order_id::is_leveraged_order(order_id)) {
        market.leverage_book.decrease_order(order_id, quantity);
    };
    market.strike_exposure.remove_order(order_id, quantity, removed_fee_basis);
    market.extract_borrow_fee(borrow_fee_amount);

    let mut payout = market.dispense_lp_cash(redeemable_principal);
    let fee = payout.split(fee_amount);
    let builder_fee = payout.split(builder_fee_amount);
    market.fee_balance.join(fee);
    send_builder_fee(builder_code_id, builder_fee);
    market.emit_fee_accrued(fee_amount, builder_fee_amount, builder_code_id);
    market.assert_cash_backing();
    manager.deposit(payout.into_coin(ctx), ctx);
}

fun redeem_settled_internal(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    order_id: u256,
    quantity: u64,
    ctx: &mut TxContext,
) {
    assert_valid_quantity(quantity);

    let settlement = market_oracle.settlement_price();
    let (order_price, payout_amount, current_liability) = {
        let exposure = &market.strike_exposure;
        let (current_liability, _) = exposure.settled_values(settlement);
        let order_price = exposure.settled_order_price(settlement, order_id);
        let payout_amount = math::mul(order_price, quantity);
        (order_price, payout_amount, current_liability)
    };
    assert!(current_liability >= payout_amount, ESettledLiabilityUnderflow);

    let (debt_amount, borrow_fee_amount) = market.order_debt_terms(
        order_id,
        quantity,
        market.expiry,
    );
    let net_payout_amount = payout_amount - debt_amount;
    let removed_fee_basis = manager.decrease_position(market.id(), order_id, quantity);
    if (predict_order_id::is_leveraged_order(order_id)) {
        market.leverage_book.decrease_order(order_id, quantity);
    };
    let rebate = if (!predict_order_id::is_leveraged_order(order_id) && order_price == 0) {
        market.rebate_liability(removed_fee_basis)
    } else {
        0
    };
    assert!(market.fee_balance.value() >= rebate, EInsufficientFeeBalance);

    market.strike_exposure.remove_order(order_id, quantity, removed_fee_basis);
    market.extract_borrow_fee(borrow_fee_amount);
    let mut payout = market.dispense_lp_cash(net_payout_amount);
    payout.join(market.dispense_fee_cash(rebate));
    manager.deposit_permissionless(payout.into_coin(ctx), ctx);
}

fun redeem_compacted_internal(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    order_id: u256,
    quantity: u64,
    ctx: &mut TxContext,
) {
    assert_valid_quantity(quantity);

    let (settlement, current_payout_liability, current_rebate_liability) = market
        .strike_exposure
        .compacted_values();
    let order_price = market.strike_exposure.settled_order_price(settlement, order_id);
    let gross_payout_amount = math::mul(order_price, quantity);
    let (debt_amount, _) = market.order_debt_terms(order_id, quantity, market.expiry);
    let payout_amount = gross_payout_amount - debt_amount;
    assert!(market.lp_cash_balance.value() >= current_payout_liability, EInsufficientLpCash);

    let removed_fee_basis = manager.decrease_position(market.id(), order_id, quantity);
    if (predict_order_id::is_leveraged_order(order_id)) {
        market.leverage_book.decrease_order(order_id, quantity);
    };
    let rebate = if (!predict_order_id::is_leveraged_order(order_id) && order_price == 0) {
        market.rebate_liability(removed_fee_basis)
    } else {
        0
    };
    assert!(market.fee_balance.value() >= current_rebate_liability, EInsufficientFeeBalance);

    market.strike_exposure.decrease_compacted_liabilities(payout_amount, rebate);
    let mut payout = market.dispense_lp_cash(payout_amount);
    payout.join(market.dispense_fee_cash(rebate));
    manager.deposit_permissionless(payout.into_coin(ctx), ctx);
}

fun redeem_liquidated_internal(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    order_id: u256,
    quantity: u64,
) {
    assert_valid_quantity(quantity);
    manager.decrease_position(market.id(), order_id, quantity);
    market.leverage_book.decrease_liquidated_order(order_id, quantity);
}

fun liquidate_live_orders(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
) {
    let order_ids = market.leverage_book.active_order_ids();
    let mut i = 0;
    while (i < order_ids.length()) {
        let order_id = order_ids[i];
        if (market.leverage_book.is_active(order_id)) {
            let (quantity, borrowed_principal, _) = market.leverage_book.order_terms(order_id);
            let (debt_amount, _) = leverage_config::debt_terms(
                market.max_expiry_borrow_fee,
                market.expiry,
                predict_order_id::inserted_at_ms(order_id),
                clock.timestamp_ms(),
                borrowed_principal,
            );
            let position_value = market.live_order_value(
                config,
                market_oracle,
                pyth,
                clock,
                order_id,
                quantity,
            );
            if (position_value <= debt_amount) {
                market.liquidate_order(order_id, position_value, debt_amount);
            };
        };
        i = i + 1;
    };
}

fun liquidate_settled_orders(market: &mut ExpiryMarket, settlement: u64, now_ms: u64) {
    let order_ids = market.leverage_book.active_order_ids();
    let mut i = 0;
    while (i < order_ids.length()) {
        let order_id = order_ids[i];
        if (market.leverage_book.is_active(order_id)) {
            let (quantity, borrowed_principal, _) = market.leverage_book.order_terms(order_id);
            let (debt_amount, _) = leverage_config::debt_terms(
                market.max_expiry_borrow_fee,
                market.expiry,
                predict_order_id::inserted_at_ms(order_id),
                now_ms,
                borrowed_principal,
            );
            let position_value = math::mul(
                market.strike_exposure.settled_order_price(settlement, order_id),
                quantity,
            );
            if (position_value <= debt_amount) {
                market.liquidate_order(order_id, position_value, debt_amount);
            };
        };
        i = i + 1;
    };
}

fun liquidate_order(
    market: &mut ExpiryMarket,
    order_id: u256,
    position_value: u64,
    debt_amount: u64,
) {
    let (quantity, borrowed_principal, fee_basis) = market.leverage_book.liquidate_order(order_id);
    market.strike_exposure.remove_order(order_id, quantity, fee_basis);
    let principal_recovered = position_value.min(borrowed_principal);
    let borrow_fee_recovered = position_value - principal_recovered;
    market.extract_borrow_fee(borrow_fee_recovered);
    event::emit(OrderLiquidated {
        expiry_market_id: market.id(),
        order_id,
        quantity,
        borrowed_principal,
        debt_amount,
        borrow_fee_recovered,
        position_value,
    });
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
