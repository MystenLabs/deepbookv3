// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Per-expiry Predict market.
///
/// An ExpiryMarket is the hot shared object for one expiry. It owns the
/// expiry-local DUSDC allocation, strike matrix, fee reserve, trade execution,
/// valuation witness, and settlement compaction state. Pool-wide PLP
/// accounting and allocation coordination remain outside this module.
module deepbook_predict::expiry_market;

use deepbook::math;
use deepbook_predict::{
    constants,
    fee_reserve::{Self, FeeReserve},
    market_oracle::MarketOracle,
    predict_manager::PredictManager,
    pricing,
    protocol_config::ProtocolConfig,
    pyth_source::PythSource,
    range_key::{Self, RangeKey},
    strike_matrix::{Self, StrikeMatrix}
};
use dusdc::dusdc::DUSDC;
use sui::{balance::Balance, clock::Clock, event};

const EWrongMarketOracle: u64 = 0;
const EWrongPythSource: u64 = 1;
const EValuationExceedsCash: u64 = 2;
const EAllocationBelowMaxPayout: u64 = 3;
const EZeroQuantity: u64 = 5;
const EMarketCompacted: u64 = 6;
const EMarketNotCompacted: u64 = 7;
const EInsufficientLpCash: u64 = 8;
const ECompactedLiabilityUnderflow: u64 = 9;
const EZeroAllocatedCapital: u64 = 10;
const EInvalidTickSize: u64 = 11;
const EInvalidStrikeGrid: u64 = 12;
const ESettledLiabilityUnderflow: u64 = 16;

/// Per-expiry market state.
public struct ExpiryMarket has key {
    id: UID,
    market_oracle_id: ID,
    pyth_lazer_feed_id: u32,
    expiry: u64,
    /// Active risk budget assigned by the pool.
    allocated_capital: u64,
    /// LP-owned DUSDC backing this expiry's liability.
    lp_cash_balance: Balance<DUSDC>,
    /// Dense exposure state before compaction; none after compaction.
    strike_matrix: Option<StrikeMatrix>,
    fee_reserve: FeeReserve,
    /// Settlement price retained after dense strike state is compacted.
    compacted_settlement: Option<u64>,
    /// Remaining settled redeem liability after compaction.
    compacted_liability: u64,
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
    lp_fee: u64,
    protocol_fee: u64,
    insurance_fee: u64,
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

/// Return the expiry-local worst-case payout.
public fun max_payout(market: &ExpiryMarket): u64 {
    if (market.is_compacted()) {
        market.compacted_liability
    } else {
        market.strike_matrix.borrow().max_payout()
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

/// Return true once the dense strike matrix has been compacted after settlement.
public fun is_compacted(market: &ExpiryMarket): bool {
    market.compacted_settlement.is_some()
}

/// Construct a range key for this expiry market.
public fun range_key(market: &ExpiryMarket, lower_strike: u64, higher_strike: u64): RangeKey {
    range_key::new(market.market_oracle_id, lower_strike, higher_strike)
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
    let option_value = market.current_option_value(config, market_oracle, pyth, clock);
    let lp_cash_balance = market.lp_cash_balance.value();
    assert!(lp_cash_balance >= option_value, EValuationExceedsCash);
    ExpiryValuation {
        expiry_market_id: market.id(),
        value: lp_cash_balance - option_value,
    }
}

/// Mint a live position interval against this expiry market.
///
/// Requires trading to be allowed, manager ownership, a live fresh oracle, and
/// enough expiry allocation to back the post-mint max payout.
public fun mint(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    config.assert_trading_allowed();
    market.mint_internal(config, manager, market_oracle, pyth, key, quantity, clock, ctx);
}

/// Redeem a live, settled, or compacted position interval.
///
/// Live redeems require manager ownership and fresh oracle data. Settled and
/// compacted redeems are permissionless and pay into the manager balance.
public fun redeem(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    config.assert_not_valuation_in_progress();
    if (market.is_compacted()) {
        market.redeem_compacted_internal(manager, key, quantity, ctx);
    } else if (market_oracle.is_settled()) {
        market.redeem_settled_internal(manager, market_oracle, key, quantity, ctx);
    } else {
        market.redeem_live_internal(
            config,
            manager,
            market_oracle,
            pyth,
            key,
            quantity,
            clock,
            ctx,
        );
    }
}

// === Public-Package Functions ===

/// Create and share a funded expiry market for one market oracle.
///
/// The market snapshots the Pyth feed ID, initializes dense strike state, and
/// takes custody of the pool-provided allocation as LP cash.
public(package) fun create_and_share(
    market_oracle_id: ID,
    pyth: &PythSource,
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
        pyth_lazer_feed_id: pyth.feed_id(),
        expiry,
        allocated_capital,
        lp_cash_balance: allocation,
        strike_matrix: option::some(strike_matrix::new(ctx, tick_size, min_strike, max_strike)),
        fee_reserve: fee_reserve::new(config.fee_config()),
        compacted_settlement: option::none(),
        compacted_liability: 0,
    };
    let id = market.id();
    transfer::share_object(market);
    id
}

/// Add pool-provided DUSDC to this live expiry's allocation and LP cash.
public(package) fun receive_allocation(market: &mut ExpiryMarket, allocation: Balance<DUSDC>) {
    market.assert_not_compacted();
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

/// Consume an expiry valuation and return its market ID and value.
public(package) fun unpack_valuation(valuation: ExpiryValuation): (ID, u64) {
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

/// Compact settled expiry state and return surplus cash to the pool.
///
/// Consumes dense strike state, leaves only settled liability backing in the
/// expiry, and returns surplus LP cash plus protocol/insurance fee balances.
public(package) fun compact_settled(
    market: &mut ExpiryMarket,
    market_oracle: &MarketOracle,
): (Balance<DUSDC>, Balance<DUSDC>, Balance<DUSDC>) {
    market.assert_market_oracle(market_oracle);
    market.assert_not_compacted();

    let settlement = pricing::settlement_price(market_oracle);
    let settled_liability = market.strike_matrix.borrow().settled_value(settlement);
    assert!(market.lp_cash_balance.value() >= settled_liability, EInsufficientLpCash);
    assert!(market.allocated_capital >= settled_liability, EAllocationBelowMaxPayout);

    let matrix = market.strike_matrix.extract();
    let _settled_liability = strike_matrix::into_settled_liability(matrix, settlement);
    let returned_cash_amount = market.lp_cash_balance.value() - settled_liability;
    let returned_cash = market.lp_cash_balance.split(returned_cash_amount);
    let (protocol_fees, insurance_fees) = market.fee_reserve.take_fee_balances();

    market.allocated_capital = 0;
    market.compacted_liability = settled_liability;
    market.compacted_settlement = option::some(settlement);
    market.assert_cash_backing();

    (returned_cash, protocol_fees, insurance_fees)
}

// === Private Functions ===

fun current_option_value(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
): u64 {
    market.assert_market_oracle(market_oracle);
    market.assert_pyth_feed(pyth);
    market_oracle.assert_not_pending_settlement(clock);

    if (market.is_compacted()) return market.compacted_liability;

    let strike_matrix = market.strike_matrix.borrow();
    if (market_oracle.is_settled()) {
        strike_matrix.settled_value(pricing::settlement_price(market_oracle))
    } else {
        let (minted_min_strike, minted_max_strike) = strike_matrix.minted_strike_range();
        if (minted_min_strike == 0 && minted_max_strike == 0) return 0;

        let (grid_min, grid_tick, grid_max) = strike_matrix.strike_grid();
        let curve = pricing::build_live_curve(
            config.pricing_config(),
            market_oracle,
            pyth,
            clock,
            grid_min,
            grid_tick,
            grid_max,
            minted_min_strike,
            minted_max_strike,
        );
        strike_matrix.live_value(&curve)
    }
}

fun mint_internal(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    manager.assert_owner(ctx);
    market.assert_market_oracle(market_oracle);
    market.assert_pyth_feed(pyth);
    market_oracle.assert_pyth_source(pyth);
    market_oracle.assert_active(clock);
    pricing::assert_live_oracle_fresh(config.pricing_config(), market_oracle, clock);
    market.assert_range_key_matches(&key);
    market.assert_not_compacted();
    assert_nonzero_quantity(quantity);

    // Mint quotes intentionally use post-insert liability for utilization fees.
    market
        .strike_matrix
        .borrow_mut()
        .insert_range(
            key.lower_strike(),
            key.higher_strike(),
            quantity,
        );
    market.assert_capacity_backing();

    let (principal_amount, fee_amount) = market.quote_mint_amounts(
        config,
        market_oracle,
        pyth,
        key,
        quantity,
        clock,
    );
    let payment_amount = principal_amount + fee_amount;

    manager.increase_position(key, quantity);
    let mut payment = manager.withdraw(payment_amount, ctx).into_balance();
    let fee_payment = payment.split(fee_amount);
    let (lp_fee, total_fee, lp_fee_amount, protocol_fee, insurance_fee) = market
        .fee_reserve
        .accrue_fee(fee_payment);
    market.emit_fee_accrued(total_fee, lp_fee_amount, protocol_fee, insurance_fee);
    market.lp_cash_balance.join(payment);
    market.lp_cash_balance.join(lp_fee);
    market.assert_cash_backing();
}

fun redeem_live_internal(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    manager.assert_owner(ctx);
    market.assert_market_oracle(market_oracle);
    market.assert_pyth_feed(pyth);
    market_oracle.assert_pyth_source(pyth);
    market_oracle.assert_active(clock);
    pricing::assert_live_oracle_fresh(config.pricing_config(), market_oracle, clock);
    market.assert_range_key_matches(&key);
    market.assert_not_compacted();
    assert_nonzero_quantity(quantity);
    manager.assert_can_decrease_position(key, quantity);

    // Live redeem quotes intentionally use post-removal liability for utilization fees.
    market
        .strike_matrix
        .borrow_mut()
        .remove_range(
            key.lower_strike(),
            key.higher_strike(),
            quantity,
        );

    let (principal_amount, fee_amount) = market.quote_live_redeem_amounts(
        config,
        market_oracle,
        pyth,
        key,
        quantity,
        clock,
    );

    manager.decrease_position(key, quantity);
    let mut payout = market.dispense_lp_cash(principal_amount);
    let fee = payout.split(fee_amount);
    let (lp_fee, total_fee, lp_fee_amount, protocol_fee, insurance_fee) = market
        .fee_reserve
        .accrue_fee(fee);
    market.emit_fee_accrued(total_fee, lp_fee_amount, protocol_fee, insurance_fee);
    market.lp_cash_balance.join(lp_fee);
    market.assert_cash_backing();
    manager.deposit(payout.into_coin(ctx), ctx);
}

fun redeem_settled_internal(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    key: RangeKey,
    quantity: u64,
    ctx: &mut TxContext,
) {
    market.assert_market_oracle(market_oracle);
    market.assert_range_key_matches(&key);
    market.assert_not_compacted();
    assert_nonzero_quantity(quantity);

    let settlement = pricing::settlement_price(market_oracle);
    let payout_amount = pricing::settled_range_payout(settlement, &key, quantity);
    manager.assert_can_decrease_position(key, quantity);
    let current_liability = market.strike_matrix.borrow().settled_value(settlement);
    assert!(current_liability >= payout_amount, ESettledLiabilityUnderflow);
    assert!(market.lp_cash_balance.value() >= current_liability, EInsufficientLpCash);

    manager.decrease_position(key, quantity);
    market
        .strike_matrix
        .borrow_mut()
        .remove_range(
            key.lower_strike(),
            key.higher_strike(),
            quantity,
        );
    let payout = market.dispense_lp_cash(payout_amount).into_coin(ctx);
    manager.deposit_permissionless(payout, ctx);
}

fun redeem_compacted_internal(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    key: RangeKey,
    quantity: u64,
    ctx: &mut TxContext,
) {
    market.assert_range_key_matches(&key);
    assert!(market.is_compacted(), EMarketNotCompacted);
    assert_nonzero_quantity(quantity);

    let settlement = market.compacted_settlement.borrow();
    let payout_amount = pricing::settled_range_payout(*settlement, &key, quantity);
    assert!(market.compacted_liability >= payout_amount, ECompactedLiabilityUnderflow);
    manager.assert_can_decrease_position(key, quantity);
    assert!(market.lp_cash_balance.value() >= market.compacted_liability, EInsufficientLpCash);

    manager.decrease_position(key, quantity);
    market.compacted_liability = market.compacted_liability - payout_amount;
    let payout = market.dispense_lp_cash(payout_amount).into_coin(ctx);
    manager.deposit_permissionless(payout, ctx);
}

fun quote_mint_amounts(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
): (u64, u64) {
    let (fair_price, fee_rate) = pricing::quote_mint_live_range(
        config.pricing_config(),
        market_oracle,
        pyth,
        clock,
        &key,
        market.max_payout(),
        market.allocated_capital,
    );
    (math::mul(fair_price, quantity), math::mul(fee_rate, quantity))
}

fun quote_live_redeem_amounts(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
): (u64, u64) {
    let (fair_price, fee_rate) = pricing::quote_live_range(
        config.pricing_config(),
        market_oracle,
        pyth,
        clock,
        &key,
        market.max_payout(),
        market.allocated_capital,
    );
    let principal_amount = math::mul(fair_price, quantity);
    let fee_amount = math::mul(fee_rate, quantity).min(principal_amount);
    (principal_amount, fee_amount)
}

fun dispense_lp_cash(market: &mut ExpiryMarket, amount: u64): Balance<DUSDC> {
    assert!(market.lp_cash_balance.value() >= amount, EInsufficientLpCash);
    market.lp_cash_balance.split(amount)
}

fun assert_pyth_feed(market: &ExpiryMarket, pyth: &PythSource) {
    assert!(market.pyth_lazer_feed_id == pyth.feed_id(), EWrongPythSource);
}

fun assert_range_key_matches(market: &ExpiryMarket, key: &RangeKey) {
    assert!(key.oracle_id() == market.market_oracle_id, EWrongMarketOracle);
}

fun assert_nonzero_quantity(quantity: u64) {
    assert!(quantity > 0, EZeroQuantity);
}

fun emit_fee_accrued(
    market: &ExpiryMarket,
    total_fee: u64,
    lp_fee: u64,
    protocol_fee: u64,
    insurance_fee: u64,
) {
    if (total_fee == 0) return;

    event::emit(FeeAccrued {
        expiry_market_id: market.id(),
        total_fee,
        lp_fee,
        protocol_fee,
        insurance_fee,
    });
}

fun assert_capacity_backing(market: &ExpiryMarket) {
    assert!(market.allocated_capital >= market.max_payout(), EAllocationBelowMaxPayout);
}

fun assert_cash_backing(market: &ExpiryMarket) {
    assert!(market.lp_cash_balance.value() >= market.max_payout(), EInsufficientLpCash);
}

fun assert_not_compacted(market: &ExpiryMarket) {
    assert!(!market.is_compacted(), EMarketCompacted);
}
