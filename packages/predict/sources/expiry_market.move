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
    predict_manager::{PredictManager, PredictTradeProof},
    pricing,
    protocol_config::ProtocolConfig,
    pyth_source::PythSource,
    range_key::{Self, RangeKey},
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
const EMarketNotCompacted: u64 = 7;
const EInsufficientLpCash: u64 = 8;
const ECompactedLiabilityUnderflow: u64 = 9;
const EZeroAllocatedCapital: u64 = 10;
const EInvalidTickSize: u64 = 11;
const EInvalidStrikeGrid: u64 = 12;
const ESettledLiabilityUnderflow: u64 = 16;
const ECompactedLiabilityMismatch: u64 = 17;
const EInsufficientFeeBalance: u64 = 18;
const ECompactedRebateLiabilityUnderflow: u64 = 19;
const EProofRequiredForLiveRedeem: u64 = 20;

/// Per-expiry market state.
public struct ExpiryMarket has key {
    id: UID,
    market_oracle_id: ID,
    pyth_lazer_feed_id: u32,
    expiry: u64,
    /// Settlement loss rebate rate snapshotted from fee config at creation.
    settlement_loss_rebate_rate: u64,
    /// Active risk budget assigned by the pool.
    allocated_capital: u64,
    /// LP-owned DUSDC backing this expiry's liability.
    lp_cash_balance: Balance<DUSDC>,
    /// Unified fee cash used for settlement loss rebates until compaction.
    fee_balance: Balance<DUSDC>,
    /// Exposure state before compaction; none after compaction.
    strike_exposure: Option<StrikeExposure>,
    /// Post-compaction settlement facts and remaining escrow liabilities.
    compacted_state: Option<CompactedState>,
}

/// Settlement facts retained after strike exposure state is compacted.
public struct CompactedState has copy, drop, store {
    settlement: u64,
    payout_liability: u64,
    rebate_liability: u64,
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

/// Return the settlement loss rebate rate snapshotted for this expiry.
public fun settlement_loss_rebate_rate(market: &ExpiryMarket): u64 {
    market.settlement_loss_rebate_rate
}

/// Return the expiry-local worst-case payout.
public fun max_payout(market: &ExpiryMarket): u64 {
    if (market.is_compacted()) {
        market.compacted_state.borrow().payout_liability
    } else {
        market.strike_exposure.borrow().max_payout()
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

/// Return true once strike exposure state has been compacted after settlement.
public fun is_compacted(market: &ExpiryMarket): bool {
    market.compacted_state.is_some()
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
    let (option_value, rebate_liability) = market.current_liabilities(
        config,
        market_oracle,
        pyth,
        clock,
    );
    let lp_cash_balance = market.lp_cash_balance.value();
    let fee_balance = market.fee_balance.value();
    assert!(lp_cash_balance >= option_value, EValuationExceedsCash);
    assert!(fee_balance >= rebate_liability, EInsufficientFeeBalance);
    let lp_fee_surplus = lp_fee_surplus_value(config, fee_balance - rebate_liability);
    ExpiryValuation {
        expiry_market_id: market.id(),
        value: lp_cash_balance - option_value + lp_fee_surplus,
    }
}

/// Mint a live position interval against this expiry market.
///
/// Requires trading to be allowed, a `PredictTradeProof` for the manager, a live
/// fresh oracle, and enough expiry allocation to back the post-mint max
/// payout. Mint fees are paid by routing a withdraw through the manager's
/// trade proof, so the proof must be present even for owner-initiated mints.
public fun mint(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    proof: &PredictTradeProof,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    config.assert_trading_allowed();
    market.mint_internal(config, manager, proof, market_oracle, pyth, key, quantity, clock, ctx);
}

/// Redeem a live, settled, or compacted position interval.
///
/// `proof` must be `some` for live redeems (needed to route the fee withdraw
/// through the manager). Settled and compacted redeems are permissionless;
/// pass `none` from a keeper without a cap. `PredictTradeProof` has `drop`,
/// so the proof is consumed by value and silently dropped on paths that
/// don't need it.
public fun redeem(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    proof: Option<PredictTradeProof>,
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
    } else {
        market.assert_market_oracle(market_oracle);
        if (market_oracle.is_settled()) {
            market.redeem_settled_internal(manager, market_oracle, key, quantity, ctx);
        } else {
            assert!(proof.is_some(), EProofRequiredForLiveRedeem);
            let live_proof = proof.destroy_some();
            market.redeem_live_internal(
                config,
                manager,
                &live_proof,
                market_oracle,
                pyth,
                key,
                quantity,
                clock,
                ctx,
            );
        }
    }
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
        allocated_capital,
        lp_cash_balance: allocation,
        fee_balance: balance::zero(),
        strike_exposure: option::some(strike_exposure::new(ctx, tick_size, min_strike, max_strike)),
        compacted_state: option::none(),
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
    market.assert_not_compacted();

    let settlement = pricing::settlement_price(market_oracle);
    let (settled_liability, losing_fee_basis) = market
        .strike_exposure
        .borrow()
        .settled_values(settlement);
    let rebate_liability = market.rebate_liability(losing_fee_basis);
    assert!(market.lp_cash_balance.value() >= settled_liability, EInsufficientLpCash);
    assert!(market.fee_balance.value() >= rebate_liability, EInsufficientFeeBalance);
    assert!(market.allocated_capital >= settled_liability, EAllocationBelowMaxPayout);

    let exposure = market.strike_exposure.extract();
    let compacted_payout_liability = exposure.into_settled_liability(settlement);
    assert!(compacted_payout_liability == settled_liability, ECompactedLiabilityMismatch);
    let returned_cash_amount = market.lp_cash_balance.value() - settled_liability;
    let returned_cash = market.lp_cash_balance.split(returned_cash_amount);
    let returned_fee_amount = market.fee_balance.value() - rebate_liability;
    let returned_fees = market.fee_balance.split(returned_fee_amount);

    market.allocated_capital = 0;
    market.compacted_state =
        option::some(CompactedState {
            settlement,
            payout_liability: settled_liability,
            rebate_liability,
        });
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
        let compacted_state = market.compacted_state.borrow();
        return (compacted_state.payout_liability, compacted_state.rebate_liability)
    };

    let strike_exposure = market.strike_exposure.borrow();
    if (market_oracle.is_settled()) {
        let settlement = pricing::settlement_price(market_oracle);
        let (settled_value, losing_fee_basis) = strike_exposure.settled_values(settlement);
        (settled_value, market.rebate_liability(losing_fee_basis))
    } else {
        let (minted_min_strike, minted_max_strike) = strike_exposure.minted_strike_range();
        if (minted_min_strike == 0 && minted_max_strike == 0) return (0, 0);

        let (grid_min, grid_tick, grid_max) = strike_exposure.strike_grid();
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
        let (live_value, max_losing_fee_basis) = strike_exposure.live_values(&curve);
        (live_value, market.rebate_liability(max_losing_fee_basis))
    }
}

fun mint_internal(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    proof: &PredictTradeProof,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    manager.validate_proof(proof);
    market.assert_market_oracle(market_oracle);
    market.assert_pyth_feed(pyth);
    market_oracle.assert_pyth_source(pyth);
    market_oracle.assert_active(clock);
    pricing::assert_live_oracle_fresh(config.pricing_config(), market_oracle, clock);
    market.assert_range_key_matches(&key);
    market.assert_not_compacted();
    assert_nonzero_quantity(quantity);

    // Quote before recording exposure so the fee basis stored with the position
    // matches the exact fee charged for this mint.
    let (principal_amount, fee_amount) = market.quote_mint_amounts(
        config,
        market_oracle,
        pyth,
        key,
        quantity,
        clock,
    );
    let builder_code_id = manager.builder_code_id();
    let builder_fee_amount = builder_fee_amount(&builder_code_id, fee_amount, quantity);
    let payment_amount = principal_amount + fee_amount + builder_fee_amount;

    market
        .strike_exposure
        .borrow_mut()
        .insert_range(
            key.lower_strike(),
            key.higher_strike(),
            quantity,
            fee_amount,
        );
    assert!(market.allocated_capital >= market.max_payout(), EAllocationBelowMaxPayout);

    manager.increase_position(key, quantity, fee_amount);
    let mut payment = manager.withdraw_with_proof(proof, payment_amount, ctx).into_balance();
    let builder_fee_payment = payment.split(builder_fee_amount);
    let fee_payment = payment.split(fee_amount);
    market.fee_balance.join(fee_payment);
    send_builder_fee(builder_code_id, builder_fee_payment);
    market.emit_fee_accrued(fee_amount, builder_fee_amount, builder_code_id);
    market.lp_cash_balance.join(payment);
    market.assert_cash_backing();
}

fun redeem_live_internal(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    proof: &PredictTradeProof,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    key: RangeKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    manager.validate_proof(proof);
    market.assert_pyth_feed(pyth);
    market_oracle.assert_pyth_source(pyth);
    market_oracle.assert_active(clock);
    pricing::assert_live_oracle_fresh(config.pricing_config(), market_oracle, clock);
    market.assert_range_key_matches(&key);
    market.assert_not_compacted();
    assert_nonzero_quantity(quantity);
    let removed_fee_basis = manager.decrease_position(key, quantity);

    // Live redeem quotes intentionally use post-removal liability for utilization fees.
    market
        .strike_exposure
        .borrow_mut()
        .remove_range(
            key.lower_strike(),
            key.higher_strike(),
            quantity,
            removed_fee_basis,
        );

    let (principal_amount, fee_amount) = market.quote_live_redeem_amounts(
        config,
        market_oracle,
        pyth,
        key,
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
    market.fee_balance.join(fee);
    send_builder_fee(builder_code_id, builder_fee);
    market.emit_fee_accrued(fee_amount, builder_fee_amount, builder_code_id);
    market.assert_cash_backing();
    manager.deposit_with_proof(proof, payout.into_coin(ctx), ctx);
}

fun redeem_settled_internal(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    key: RangeKey,
    quantity: u64,
    ctx: &mut TxContext,
) {
    market.assert_range_key_matches(&key);
    market.assert_not_compacted();
    assert_nonzero_quantity(quantity);

    let settlement = pricing::settlement_price(market_oracle);
    let payout_amount = pricing::settled_range_payout(settlement, &key, quantity);
    let (current_liability, _) = market.strike_exposure.borrow().settled_values(settlement);
    assert!(current_liability >= payout_amount, ESettledLiabilityUnderflow);
    assert!(market.lp_cash_balance.value() >= current_liability, EInsufficientLpCash);

    let removed_fee_basis = manager.decrease_position(key, quantity);
    let rebate = if (range_loses(settlement, &key)) {
        market.rebate_liability(removed_fee_basis)
    } else {
        0
    };
    assert!(market.fee_balance.value() >= rebate, EInsufficientFeeBalance);

    market
        .strike_exposure
        .borrow_mut()
        .remove_range(
            key.lower_strike(),
            key.higher_strike(),
            quantity,
            removed_fee_basis,
        );
    let mut payout = market.dispense_lp_cash(payout_amount);
    payout.join(market.dispense_fee_cash(rebate));
    manager.deposit_permissionless(payout.into_coin(ctx), ctx);
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

    let (settlement, current_payout_liability, current_rebate_liability) = {
        let compacted_state = market.compacted_state.borrow();
        (
            compacted_state.settlement,
            compacted_state.payout_liability,
            compacted_state.rebate_liability,
        )
    };
    let payout_amount = pricing::settled_range_payout(settlement, &key, quantity);
    assert!(current_payout_liability >= payout_amount, ECompactedLiabilityUnderflow);
    assert!(market.lp_cash_balance.value() >= current_payout_liability, EInsufficientLpCash);

    let removed_fee_basis = manager.decrease_position(key, quantity);
    let rebate = if (range_loses(settlement, &key)) {
        market.rebate_liability(removed_fee_basis)
    } else {
        0
    };
    assert!(current_rebate_liability >= rebate, ECompactedRebateLiabilityUnderflow);
    assert!(market.fee_balance.value() >= current_rebate_liability, EInsufficientFeeBalance);

    let compacted_state = market.compacted_state.borrow_mut();
    compacted_state.payout_liability = current_payout_liability - payout_amount;
    compacted_state.rebate_liability = current_rebate_liability - rebate;
    let mut payout = market.dispense_lp_cash(payout_amount);
    payout.join(market.dispense_fee_cash(rebate));
    manager.deposit_permissionless(payout.into_coin(ctx), ctx);
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

fun dispense_fee_cash(market: &mut ExpiryMarket, amount: u64): Balance<DUSDC> {
    assert!(market.fee_balance.value() >= amount, EInsufficientFeeBalance);
    market.fee_balance.split(amount)
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

fun assert_not_compacted(market: &ExpiryMarket) {
    assert!(!market.is_compacted(), EMarketCompacted);
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

fun send_builder_fee(builder_code_id: Option<ID>, fee: Balance<DUSDC>) {
    if (fee.value() == 0) {
        fee.destroy_zero();
        return
    };
    let builder_code_id = builder_code_id.destroy_some();
    balance::send_funds(fee, builder_code_id.to_address());
}

fun lp_fee_surplus_value(config: &ProtocolConfig, fee_surplus: u64): u64 {
    math::mul(fee_surplus, config.fee_config().lp_fee_share())
}

fun range_loses(settlement: u64, key: &RangeKey): bool {
    !(settlement > key.lower_strike() && settlement <= key.higher_strike())
}
